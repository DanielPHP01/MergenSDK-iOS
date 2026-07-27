import Foundation
import UIKit
import SwiftUI
import os

private let sdkLog = Logger(subsystem: "com.mergen", category: "engine")

/**
 * Clean wrapper around the native C++ engine.
 */
class MergenEngine {
    private var nativeHandle: Int64 = 0
    private let config: MergenScannerConfig
    
    init(config: MergenScannerConfig) {
        self.config = config
        initializeEngine()
    }
    
    private func initializeEngine() {
        #if targetEnvironment(simulator) && arch(arm64)
        sdkLog.info("MergenEngine: running on arm64 Simulator — native engine disabled.")
        #else
        let assetsPath = copyAssetsToDocuments()
        // Propagate lean_identity_fields, stabilityFrames, thresholds to C++ engine.
        // Previously hardcoded to "{}" — so Mergen.verify's leanFields/stabilityFrames
        // were silently dropped. toEngineJson() produces the full JSON the C++ layer reads.
        let configJson = config.toEngineJson()
        let licenseJson = config.licenseKey ?? ""

        nativeHandle = native_init_from_path(configJson, assetsPath, licenseJson)

        if nativeHandle == 0 {
            sdkLog.error("Failed to initialize MergenEngine — handle is 0 (license invalid or models missing)")
        }
        #endif
    }
    
    // Copies a bundle resource to the models directory, skipping if sizes match.
    // Returns silently if the resource is not found in the bundle (file is optional).
    private func copyModelIfNeeded(
        from bundle: Bundle, resource: String, ext: String, to directory: URL
    ) {
        guard let srcPath = bundle.path(forResource: resource, ofType: ext) else { return }
        let destName = "\(resource).\(ext)"
        let destPath = directory.appendingPathComponent(destName)
        let fm = FileManager.default
        let srcSize  = (try? fm.attributesOfItem(atPath: srcPath)[.size]       as? Int) ?? 0
        let destSize = (try? fm.attributesOfItem(atPath: destPath.path)[.size] as? Int) ?? 0
        // Re-copy unless the destination matches the bundle source by size AND its AES header.
        // A size-only check (the previous behaviour) missed re-encrypted models: re-encryption
        // keeps the byte count identical but rewrites the 32-byte salt + 12-byte nonce + ciphertext,
        // so a stale, undecryptable copy survived in Documents after a model/key update → the engine
        // loaded old-key bytes and threw "V16/CRNN/classifier decrypt failed". Comparing the 44-byte
        // AES header (salt+nonce, random per encryption) is cheap — no full-file read — and changes
        // on every re-encryption, so an SDK update always refreshes the on-device copy.
        func aesHeader(_ path: String) -> Data {
            guard let fh = FileHandle(forReadingAtPath: path) else { return Data() }
            defer { try? fh.close() }
            return (try? fh.read(upToCount: 44)) ?? Data()
        }
        if srcSize > 0, destSize == srcSize, aesHeader(srcPath) == aesHeader(destPath.path) {
            sdkLog.debug("model up-to-date: \(destName, privacy: .public) (\(destSize, privacy: .public) bytes)")
            return
        }
        try? fm.removeItem(at: destPath)
        do {
            try fm.copyItem(atPath: srcPath, toPath: destPath.path)
            sdkLog.info("model copied: \(destName, privacy: .public) (\(srcSize, privacy: .public) bytes)")
        } catch {
            sdkLog.error("model copy failed: \(destName, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        }
    }

    private func copyAssetsToDocuments() -> String {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelsDir = documentsPath.appendingPathComponent("idcard_scanner_models")

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: modelsDir.path) {
            try? fileManager.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        }

        // Models ship under OBFUSCATED names (m1..m10 + m*_dict.txt) inside the SDK module bundle
        // Resources, AES-256-GCM encrypted. LEAN-ONLY bundle: m3/m6/m8 removed (not loaded by
        // lean path); m9.ort removed (device loads m9.onnx; .ort has NHWC nodes incompatible with
        // this ORT build). This list MUST stay in sync with xcframework_output/Package.swift
        // `resources:` AND the C++ model_loader's expected mN names — a stale/renamed entry copies
        // nothing (forResource returns nil) and leaves YOLO unable to load → engine init fails
        // ("nothing scans"). Real-name map: docs/MODEL_MAP.md.
        //
        // This mirrors the Android copy list in MergenScanner.copyAssetFile(...) exactly (parity).
        let bundledModels: [(resource: String, ext: String)] = [
            // m1/m9/m2 retired from the bundle (2026-07-10): m15 unified replaces m1+m9,
            // m14 lean-FD replaces m2 in lean mode. Restore entries to re-ship.
            ("m4.onnx", "encrypted"),   // OCR rec v16 (structured-field routing)
            ("m4_dict", "txt"),
            ("m5.ort",  "encrypted"),   // text detector (DB-net)
            ("m7.onnx", "encrypted"),   // MRZ CRNN (primary)
            ("m7_dict", "txt"),
            ("m12.onnx", "encrypted"),  // DocsaidLab MRZ det (lean-only, m12)
            ("m13.onnx", "encrypted"),  // DocsaidLab MRZ rec (lean-only, m13)
            ("m14.onnx", "encrypted"),  // FD-lean v2 — 3-class lean FieldDetector (default active)
            ("m15.onnx", "encrypted"),  // unified detector — m1+m9 replacement (use_unified_detector)
        ]
        for m in bundledModels {
            copyModelIfNeeded(from: Bundle.module, resource: m.resource, ext: m.ext, to: modelsDir)
        }

        return modelsDir.path
    }
    
    func processFrame(image: UIImage) -> FrameResult {
        #if targetEnvironment(simulator) && arch(arm64)
        return FrameResult()
        #else
        guard nativeHandle != 0 else { return FrameResult() }

        // RC-5 fix: apply EXIF/imageOrientation before extracting pixels.
        // image.cgImage returns RAW pixels WITHOUT applying imageOrientation — photos
        // captured by the camera (and most gallery photos) carry a Rotate90CW tag that
        // UIImage renders correctly but cgImage exposes as-is (rotated 90° relative to
        // the visual content). Feeding rotated pixels to C++ YOLO causes missed detections.
        // UIGraphicsImageRenderer re-renders the UIImage respecting its transform, so the
        // resulting CGImage pixels are always in the canonical "up" orientation.
        let normalizedImage: UIImage
        if image.imageOrientation == .up {
            normalizedImage = image
        } else {
            // Pixel-preserving re-render (scale = 1 at the image's PIXEL size):
            // the default renderer format uses the DEVICE scale (3x on modern
            // iPhones), silently tripling the pixel count of every EXIF-rotated
            // input with bicubic interpolation; the engine then downscales it
            // again — the double resample wrecked sharpness (device measurement:
            // laplacian 183 at capture -> 14 after the round trip).
            let pixelSize = CGSize(width:  image.size.width  * image.scale,
                                   height: image.size.height * image.scale)
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.scale  = 1
            fmt.opaque = true
            let renderer = UIGraphicsImageRenderer(size: pixelSize, format: fmt)
            normalizedImage = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: pixelSize))
            }
        }

        guard let cgImage = normalizedImage.cgImage else { return FrameResult() }

        let width = cgImage.width
        let height = cgImage.height

        // Pixel data extraction: RGBA with non-premultiplied alpha so that
        // cv::COLOR_RGBA2BGR in the C++ bridge yields the same BGR values as
        // cv::imread (which returns BGR without alpha).
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: height * width * 4)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 4 * width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return FrameResult()
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var resultData = [Int32](repeating: 0, count: 26)
        native_process_frame(nativeHandle, &pixelData, Int32(width), Int32(height), &resultData)
        
        // Map native result array to FrameResult struct
        // (Similar to NativeBridge.swift but cleaner)
        // For simplicity, let's assume FrameResult is defined as in the demo.
        
        let status = resultData[0]
        let state = resultData[1]
        let isFinished = resultData[2] == 1
        let isPassed = resultData[3] == 1
        let progress = Float(resultData[4]) / 100.0
        let hasCard = resultData[5] == 1
        
        let cardBbox = CGRect(
            x: CGFloat(resultData[6]),
            y: CGFloat(resultData[7]),
            width: CGFloat(resultData[8] - resultData[6]),
            height: CGFloat(resultData[9] - resultData[7])
        )
        
        // ... (rest of the mapping)

        var result = FrameResult()
        result.status      = StatusCode(rawValue: Int(status)) ?? .ok
        result.state       = EngineState(rawValue: Int(state)) ?? .idle
        result.isFinished  = isFinished
        result.isPassed    = isPassed
        result.progress    = progress
        result.messageHint = getHint(state: state)
        result.cardBbox    = cardBbox
        result.hasCard     = hasCard
        result.confidence  = Float(resultData[10]) / 1000.0
        result.imageWidth  = Int(resultData[11])
        result.imageHeight = Int(resultData[12])
        result.cardVersion  = CardVersion(rawValue: Int(resultData[13])) ?? .unknown
        result.isFlipped    = resultData[14] == 1
        if resultData.count >= 19 {
            result.smoothedBbox = CGRect(
                x:      CGFloat(resultData[15]) / 100.0,
                y:      CGFloat(resultData[16]) / 100.0,
                width:  CGFloat(resultData[17] - resultData[15]) / 100.0,
                height: CGFloat(resultData[18] - resultData[16]) / 100.0
            )
        } else {
            result.smoothedBbox = result.cardBbox
        }
        if resultData.count >= 20 {
            result.cardIsStill = resultData[19] == 1
        }
        if resultData.count >= 21 {
            result.stillCaptureWanted = resultData[20] == 1
        }
        if resultData.count >= 24 {
            result.isGlared = resultData[21] == 1
            result.isDark   = resultData[22] == 1
            result.isBlurry = resultData[23] == 1
        }
        if resultData.count >= 26 {
            result.probeSeq         = Int(resultData[24])
            result.probeLastVerdict = Int(resultData[25])
        }
        if result.cardIsStill {
            result.messageTitle = "Замрите"
            result.messageHint  = "Держите карту неподвижно"
        }
        return result
        #endif // !targetEnvironment(simulator) || arch(x86_64)
    }

    /// Still-photo capture entry (v2.1 still-capture flow).
    ///
    /// Feeds ONE high-resolution still (AVCapturePhotoOutput) through the SAME
    /// capture pipeline as the CAPTURED-state block, WITHOUT touching the video
    /// tracking state — the preview overlay keeps coasting on video frames.
    /// Call only after a frame result carried `stillCaptureWanted == true`.
    ///
    /// Returns `nil` on simulator, when the engine is not initialized, or when
    /// the linked xcframework predates the `native_process_still_frame` symbol
    /// (graceful fallback — the caller resumes the video rescan loop).
    ///
    /// NOTE: the returned bbox fields are in STILL-photo pixel coordinates —
    /// never map them into the video preview overlay.
    func processStillFrame(image: UIImage) -> FrameResult? {
        #if targetEnvironment(simulator) && arch(arm64)
        return nil
        #else
        guard nativeHandle != 0 else { return nil }

        // Same orientation normalization as processFrame(image:) — cgImage exposes
        // RAW pixels without applying imageOrientation (camera stills carry EXIF
        // rotation), and YOLO needs canonical "up" pixels.
        let normalizedImage: UIImage
        if image.imageOrientation == .up {
            normalizedImage = image
        } else {
            // Pixel-preserving re-render (scale = 1 at the image's PIXEL size):
            // the default renderer format uses the DEVICE scale (3x on modern
            // iPhones), silently tripling the pixel count of every EXIF-rotated
            // input with bicubic interpolation; the engine then downscales it
            // again — the double resample wrecked sharpness (device measurement:
            // laplacian 183 at capture -> 14 after the round trip).
            let pixelSize = CGSize(width:  image.size.width  * image.scale,
                                   height: image.size.height * image.scale)
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.scale  = 1
            fmt.opaque = true
            let renderer = UIGraphicsImageRenderer(size: pixelSize, format: fmt)
            normalizedImage = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: pixelSize))
            }
        }
        guard let cgImage = normalizedImage.cgImage else { return nil }

        let width  = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: height * width * 4)
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 4 * width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var raw = [Int32](repeating: 0, count: 26)
        native_process_still_frame(nativeHandle, &pixelData, Int32(width), Int32(height), &raw)

        var result = FrameResult()
        result.status       = StatusCode(rawValue: Int(raw[0])) ?? .ok
        result.state        = EngineState(rawValue: Int(raw[1])) ?? .idle
        result.isFinished   = raw[2] == 1
        result.isPassed     = raw[3] == 1
        result.progress     = Float(raw[4]) / 100.0
        result.hasCard      = raw[5] == 1
        result.cardBbox     = CGRect(
            x:      CGFloat(raw[6]),
            y:      CGFloat(raw[7]),
            width:  CGFloat(raw[8] - raw[6]),
            height: CGFloat(raw[9] - raw[7])
        )
        result.confidence   = Float(raw[10]) / 1000.0
        result.imageWidth   = Int(raw[11])
        result.imageHeight  = Int(raw[12])
        result.cardVersion  = CardVersion(rawValue: Int(raw[13])) ?? .unknown
        result.isFlipped    = raw[14] == 1
        result.smoothedBbox = CGRect(
            x:      CGFloat(raw[15]) / 100.0,
            y:      CGFloat(raw[16]) / 100.0,
            width:  CGFloat(raw[17] - raw[15]) / 100.0,
            height: CGFloat(raw[18] - raw[16]) / 100.0
        )
        result.cardIsStill        = raw[19] == 1
        result.stillCaptureWanted = raw[20] == 1
        if raw.count >= 24 {
            result.isGlared = raw[21] == 1
            result.isDark   = raw[22] == 1
            result.isBlurry = raw[23] == 1
        }
        if raw.count >= 26 {
            result.probeSeq         = Int(raw[24])
            result.probeLastVerdict = Int(raw[25])
        }
        return result
        #endif
    }

    private func getHint(state: Int32) -> String {
        switch state {
        case 0: return "Наведите на документ"
        case 1: return ""
        case 2: return ""
        case 3: return ""
        default: return "Наведите на документ"
        }
    }
    
    // ── Zero-copy BGRA frame processing (AVFoundation path) ──

    /// Fast optical-flow track-only path (<1 ms). Skips YOLO, returns last known bbox.
    /// Returns nil on simulator or when the engine is not initialised.
    func processFrameTrackOnly(_ pixelBuffer: CVPixelBuffer) -> FrameResult? {
        #if targetEnvironment(simulator) && arch(arm64)
        return nil
        #else
        guard nativeHandle != 0 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let w           = CVPixelBufferGetWidth(pixelBuffer)
        let h           = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var raw = [Int32](repeating: 0, count: 26)
        native_process_frame_track_only_bgra(
            nativeHandle,
            base.assumingMemoryBound(to: UInt8.self),
            Int32(w), Int32(h), Int32(bytesPerRow),
            &raw
        )

        var result = FrameResult()
        result.status      = StatusCode(rawValue: Int(raw[0])) ?? .ok
        result.state       = EngineState(rawValue: Int(raw[1])) ?? .idle
        result.isFinished  = raw[2] == 1
        result.isPassed    = raw[3] == 1
        result.progress    = Float(raw[4]) / 100.0
        result.hasCard     = raw[5] == 1
        result.cardBbox    = CGRect(
            x:      CGFloat(raw[6]),
            y:      CGFloat(raw[7]),
            width:  CGFloat(raw[8] - raw[6]),
            height: CGFloat(raw[9] - raw[7])
        )
        result.confidence  = Float(raw[10]) / 1000.0
        result.imageWidth  = Int(raw[11])
        result.imageHeight = Int(raw[12])
        result.cardVersion = CardVersion(rawValue: Int(raw[13])) ?? .unknown
        result.isFlipped   = raw[14] == 1
        result.smoothedBbox = CGRect(
            x:      CGFloat(raw[15]) / 100.0,
            y:      CGFloat(raw[16]) / 100.0,
            width:  CGFloat(raw[17] - raw[15]) / 100.0,
            height: CGFloat(raw[18] - raw[16]) / 100.0
        )
        result.cardIsStill = raw[19] == 1
        if raw.count >= 24 {
            result.isGlared = raw[21] == 1
            result.isDark   = raw[22] == 1
            result.isBlurry = raw[23] == 1
        }
        if raw.count >= 26 {
            result.probeSeq         = Int(raw[24])
            result.probeLastVerdict = Int(raw[25])
        }
        return result
        #endif
    }

    func processFrameBuffer(_ pixelBuffer: CVPixelBuffer) -> FrameResult? {
        #if targetEnvironment(simulator) && arch(arm64)
        return nil
        #else
        guard nativeHandle != 0 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let w           = CVPixelBufferGetWidth(pixelBuffer)
        let h           = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var raw = [Int32](repeating: 0, count: 26)
        native_process_frame_bgra(
            nativeHandle,
            base.assumingMemoryBound(to: UInt8.self),
            Int32(w), Int32(h), Int32(bytesPerRow),
            &raw
        )

        let state = raw[1]
        var result = FrameResult()
        result.status      = StatusCode(rawValue: Int(raw[0])) ?? .ok
        result.state       = EngineState(rawValue: Int(state)) ?? .idle
        result.isFinished  = raw[2] == 1
        result.isPassed    = raw[3] == 1
        result.progress    = Float(raw[4]) / 100.0
        result.messageHint = getHint(state: state)
        result.cardBbox    = CGRect(
            x:      CGFloat(raw[6]),
            y:      CGFloat(raw[7]),
            width:  CGFloat(raw[8] - raw[6]),
            height: CGFloat(raw[9] - raw[7])
        )
        result.hasCard     = raw[5] == 1
        result.confidence  = Float(raw[10]) / 1000.0
        result.imageWidth  = Int(raw[11])
        result.imageHeight = Int(raw[12])
        result.cardVersion  = CardVersion(rawValue: Int(raw[13])) ?? .unknown
        result.isFlipped    = raw[14] == 1
        if raw.count >= 19 {
            result.smoothedBbox = CGRect(
                x:      CGFloat(raw[15]) / 100.0,
                y:      CGFloat(raw[16]) / 100.0,
                width:  CGFloat(raw[17] - raw[15]) / 100.0,
                height: CGFloat(raw[18] - raw[16]) / 100.0
            )
        } else {
            result.smoothedBbox = result.cardBbox
        }
        if raw.count >= 20 {
            result.cardIsStill = raw[19] == 1
        }
        if raw.count >= 21 {
            result.stillCaptureWanted = raw[20] == 1
        }
        if raw.count >= 24 {
            result.isGlared = raw[21] == 1
            result.isDark   = raw[22] == 1
            result.isBlurry = raw[23] == 1
        }
        if raw.count >= 26 {
            result.probeSeq         = Int(raw[24])
            result.probeLastVerdict = Int(raw[25])
        }
        if result.cardIsStill {
            result.messageTitle = "Замрите"
            result.messageHint  = "Держите карту неподвижно"
        }
        return result
        #endif
    }

    // CIContext is thread-safe for createCGImage calls.
    // Allocating a new CIContext per call (~50-100 ms Metal init on A9) is avoided by
    // sharing a single instance for the lifetime of the engine.
    private static let sharedCIContext: CIContext = CIContext(options: nil)

    func imageFromBuffer(_ pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = MergenEngine.sharedCIContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Returns the perspective-corrected card crop (JPEG) captured by the last
    /// CAPTURED/FINISHED_SUCCESS frame. Returns nil if no capture yet or on simulator.
    func getLastCroppedCardImage() -> UIImage? {
        #if targetEnvironment(simulator) && arch(arm64)
        return nil
        #else
        guard nativeHandle != 0 else { return nil }
        var ptr: UnsafeMutablePointer<UInt8>? = nil
        var size: Int32 = 0
        let ok = native_get_cropped_card_jpeg(nativeHandle, &ptr, &size)
        guard ok == 1, let ptr = ptr, size > 0 else { return nil }
        defer { native_free_buffer(ptr) }
        return UIImage(data: Data(bytes: ptr, count: Int(size)))
        #endif
    }

    /// Returns detected text fields from the last captured crop.
    /// Returns an empty array on simulator or if no capture has occurred.
    func getDetectedFields() -> [(fieldId: Int, rawClassId: Int, bbox: CGRect, confidence: Float)] {
        #if targetEnvironment(simulator) && arch(arm64)
        return []
        #else
        guard nativeHandle != 0 else { return [] }
        let kMaxFields = 32
        var buffer = [NativeDetectedField](
            repeating: NativeDetectedField(fieldId: 0, rawClassId: 0, x: 0, y: 0, w: 0, h: 0, confidence: 0),
            count: kMaxFields
        )
        let count = native_get_detected_fields(nativeHandle, &buffer, Int32(kMaxFields))
        guard count > 0 else { return [] }
        return (0..<Int(count)).map { i in
            let f = buffer[i]
            return (
                fieldId:    Int(f.fieldId),
                rawClassId: Int(f.rawClassId),
                bbox:       CGRect(x: CGFloat(f.x), y: CGFloat(f.y),
                                   width: CGFloat(f.w), height: CGFloat(f.h)),
                confidence: f.confidence
            )
        }
        #endif
    }

    /// Per-field accumulator progress JSON (multi-frame voting state).
    /// Format: `{"accumulated_frames":N,"fields":[{"name":...,"guess":...,"confidence":0.8,"confident":true}]}`
    func getFieldProgressJson() -> String {
        #if targetEnvironment(simulator) && arch(arm64)
        return "{}"
        #else
        guard nativeHandle != 0 else { return "{}" }
        guard let cStr = native_get_field_progress_json(nativeHandle) else { return "{}" }
        defer { free(cStr) }
        return String(cString: cStr)
        #endif
    }

    /// Returns the opaque per-side result blob from C++ as a JSON string.
    ///
    /// Must be called AFTER a single-side capture (FrameResult.isFinished) and BEFORE
    /// `reset()` / `beginNextSide()` — the C++ side state is wiped on reset.
    /// Returns `"{}"` on simulator or if no capture has occurred.
    /// The bridge allocates the string with `strdup()`; this wrapper copies+frees it.
    func getSideResultJson() -> String {
        #if targetEnvironment(simulator) && arch(arm64)
        return "{}"
        #else
        guard nativeHandle != 0 else { return "{}" }
        guard let cStr = native_get_side_result_json(nativeHandle) else { return "{}" }
        defer { free(cStr) }
        return String(cString: cStr)
        #endif
    }

    /// Stateless cross-side comparison.  Accepts the two per-side blobs produced by
    /// `getSideResultJson()` and returns the verify-result JSON.
    ///
    /// SECURITY: `license` is forwarded to the C bridge which performs RSA-PSS-SHA256
    /// verification before compareSides executes. An invalid/expired license returns "{}".
    ///
    /// The bridge allocates the result with `strdup()`; this wrapper copies+frees it.
    static func compareSides(front: String, back: String, strict: Bool, license: String) -> String {
        #if targetEnvironment(simulator) && arch(arm64)
        return "{}"
        #else
        guard let cStr = native_compare_sides(front, back, strict ? 1 : 0, license) else { return "{}" }
        defer { free(cStr) }
        return String(cString: cStr)
        #endif
    }

    /// Returns the normalized center (cx, cy) of the OCR field with the lowest accumulator
    /// confidence (below 0.5) within the 1280×800 perspective-corrected card crop.
    ///
    /// Both cx and cy are in [0, 1] relative to the crop dimensions.
    /// Returns nil when all fields are already confident or no OCR frames accumulated yet.
    /// Use this during smart re-scan to point `focusPointOfInterest` at the weakest area.
    func getWeakFieldCenter() -> CGPoint? {
        #if targetEnvironment(simulator) && arch(arm64)
        return nil
        #else
        guard nativeHandle != 0 else { return nil }
        var cx: Float = 0
        var cy: Float = 0
        guard native_get_weak_field_center(nativeHandle, &cx, &cy) != 0 else { return nil }
        return CGPoint(x: CGFloat(cx), y: CGFloat(cy))
        #endif
    }

    /// Feed an external OCR result (e.g. from iOS Vision) as extra votes in the accumulator.
    func addExternalOCR(_ json: String) {
        #if !targetEnvironment(simulator) || arch(x86_64)
        guard nativeHandle != 0 else { return }
        json.withCString { cstr in
            native_add_external_ocr(nativeHandle, cstr)
        }
        #endif
    }

    /// Returns OCR result from the last captured card by calling C++ native_get_ocr_result.
    /// Parses the returned JSON string into MergenOCRResult.
    /// Returns nil on simulator or if C++ returned no meaningful OCR data.
    /// Returns the final resolved scan result as a JSON string, including the
    /// `identity_v2` block when `enable_identity_reconciliation=true` in C++.
    /// Returns `"{}"` on simulator or if no capture has occurred.
    /// The caller MUST NOT free the returned String — the C bridge allocates with
    /// `strdup()` and this wrapper frees via `defer { free(cStr) }`.
    func getFinalResultJson() -> String {
        #if targetEnvironment(simulator) && arch(arm64)
        return "{}"
        #else
        guard nativeHandle != 0 else { return "{}" }
        guard let cStr = native_get_final_result_json(nativeHandle) else { return "{}" }
        defer { free(cStr) }
        return String(cString: cStr)
        #endif
    }

    func getOCRResult() -> MergenOCRResult? {
        #if targetEnvironment(simulator) && arch(arm64)
        return nil
        #else
        guard nativeHandle != 0 else { return nil }
        guard let cStr = native_get_ocr_result(nativeHandle) else { return nil }
        defer { free(cStr) }
        let jsonString = String(cString: cStr)
        guard jsonString != "{}",
              let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }

        var ocr = MergenOCRResult()
        ocr.lastName       = dict["last_name"]
        ocr.firstName      = dict["first_name"]
        ocr.lastNameLat    = dict["last_name_lat"]
        ocr.firstNameLat   = dict["first_name_lat"]
        ocr.patronymic     = dict["patronymic"]
        ocr.gender         = dict["gender"]
        ocr.nationality    = dict["nationality"]
        ocr.birthDate      = dict["birth_date"]
        ocr.docNumber      = dict["doc_number"]
        ocr.expiryDate     = dict["expiry_date"]
        ocr.birthPlace     = dict["birth_place"]
        ocr.issuedBy       = dict["issued_by"]
        ocr.issueDate      = dict["issue_date"]
        ocr.personalNumber = dict["personal_number"]
        ocr.mrzLine1       = dict["mrz_line1"]
        ocr.mrzLine2       = dict["mrz_line2"]
        ocr.mrzLine3       = dict["mrz_line3"]
        // Return nil if C++ produced no useful fields
        let hasData = [ocr.lastName, ocr.firstName, ocr.docNumber, ocr.mrzLine1]
            .contains { $0 != nil && !($0!.isEmpty) }
        return hasData ? ocr : nil
        #endif
    }

    /// Block until YOLO + all capture models have finished loading, or until timeout.
    ///
    /// The C++ engine constructor returns in <1 ms while models load asynchronously
    /// in parallel background threads (~1–2 s on device).  Must be called on a
    /// background thread (it sleeps in 10 ms increments via native_await_models_ready).
    ///
    /// - Parameter timeoutMs: Maximum wait in milliseconds. Default 10 000 (10 s).
    /// - Returns: `true` when models are ready; `false` on timeout or init failure.
    @discardableResult
    func awaitModelsReady(timeoutMs: Int64 = 10_000) -> Bool {
        #if targetEnvironment(simulator) && arch(arm64)
        return true   // arm64 simulator never loads real models
        #else
        guard nativeHandle != 0 else { return false }
        return native_await_models_ready(nativeHandle, timeoutMs) == 1
        #endif
    }

    func reset() {
        #if !targetEnvironment(simulator) || arch(x86_64)
        if nativeHandle != 0 { native_reset(nativeHandle) }
        #endif
    }

    /// Soft-reset between the front and back sides in a two-sided gallery flow.
    ///
    /// Unlike `reset()`, `beginNextSide()` preserves the IdentitySession accumulator
    /// so that cross-side `identity_v2` merge (doc#/PIN/MRZ) remains intact.
    /// On simulator this is a no-op — native models are not loaded.
    func beginNextSide() {
        #if !targetEnvironment(simulator) || arch(x86_64)
        if nativeHandle != 0 { native_begin_next_side(nativeHandle) }
        #endif
    }

    /// Enable or disable static-image (gallery/verify) optimisations on an
    /// already-constructed engine: geometry cache, TTA diversity, fast still-capture.
    ///
    /// Call once BEFORE feeding gallery frames and reset to false after the last frame
    /// so the pooled engine — which the live camera may reuse — never inherits static mode.
    ///
    /// NOT concurrently safe with `processFrame`. Mirrors Android `setStaticImageMode`.
    /// No-op on arm64 simulator or when the engine is not initialised.
    func setStaticImageMode(_ enable: Bool) {
        #if !targetEnvironment(simulator) || arch(x86_64)
        if nativeHandle != 0 { native_set_static_image_mode(nativeHandle, enable ? 1 : 0) }
        #endif
    }

    /// Pushes a full-config JSON string to the already-running C++ engine.
    ///
    /// The C++ `parseConfig` re-reads ALL keys from the JSON (with defaults for
    /// absent keys), so callers MUST supply a complete JSON produced by
    /// `MergenScannerConfig.toEngineJson()` — never a partial/sparse object.
    /// Passing a partial JSON would silently reset absent flags (e.g. `use_unified_detector`
    /// → false), which would alter engine behaviour in unexpected ways.
    ///
    /// No-op on arm64 simulator or when the engine was not successfully initialised.
    func updateConfig(_ config: MergenScannerConfig) {
        #if !targetEnvironment(simulator) || arch(x86_64)
        guard nativeHandle != 0 else { return }
        let json = config.toEngineJson()
        native_update_config(nativeHandle, json)
        #endif
    }

    func destroy() {
        #if !targetEnvironment(simulator) || arch(x86_64)
        if nativeHandle != 0 {
            native_destroy(nativeHandle)
            nativeHandle = 0
        }
        #endif
    }
    
    deinit {
        destroy()
    }
}

// C++ declarations (device + x86_64 simulator)
#if !targetEnvironment(simulator) || arch(x86_64)

/// POD layout must match `NativeDetectedField` in ios_bridge.cpp exactly.
struct NativeDetectedField {
    var fieldId:    Int32
    var rawClassId: Int32
    var x, y, w, h: Float
    var confidence: Float
}

@_silgen_name("native_init_from_path")
func native_init_from_path(_ configJson: UnsafePointer<CChar>?, _ assetsPath: UnsafePointer<CChar>?, _ licenseJson: UnsafePointer<CChar>?) -> Int64

/// Re-parses config from a full JSON string on an already-running engine.
/// The JSON MUST be complete (all keys present) because parseConfig replaces
/// every field with its value or its default. A partial JSON silently resets absent flags.
@_silgen_name("native_update_config")
func native_update_config(_ handle: Int64, _ configJson: UnsafePointer<CChar>?)

@_silgen_name("native_process_frame")
func native_process_frame(_ handle: Int64, _ imageData: UnsafePointer<UInt8>?, _ width: Int32, _ height: Int32, _ resultData: UnsafeMutablePointer<Int32>?)

// The four entry points below were historically resolved via dlsym(dlopen(nil))
// with a silent nil fallback. That is unreliable for a statically linked SDK:
// an app executable does not put static-library symbols into its dyld export
// trie, so dlsym returns nil even though the code IS linked in (observed on
// device 2026-07-12: setStaticImageMode / trackOnly / still-capture silently
// degraded to no-ops while every directly-referenced @_silgen_name entry point
// worked — gallery verify then failed on a stale enforce_capture_side).
// Sources and binary ship together in one SPM package, so old-binary/new-source
// skew cannot occur — direct references are safe and fail loudly at app link
// time instead of silently at runtime.
@_silgen_name("native_process_frame_bgra")
func native_process_frame_bgra(_ handle: Int64, _ imageData: UnsafePointer<UInt8>?, _ width: Int32, _ height: Int32, _ bytesPerRow: Int32, _ resultData: UnsafeMutablePointer<Int32>?)

/// OF-only fast path, same signature as the bgra variant.
@_silgen_name("native_process_frame_track_only_bgra")
func native_process_frame_track_only_bgra(_ handle: Int64, _ imageData: UnsafePointer<UInt8>?, _ width: Int32, _ height: Int32, _ bytesPerRow: Int32, _ resultData: UnsafeMutablePointer<Int32>?)

/// Still-photo capture entry (v2.1 still-capture flow). RGBA input, same
/// signature as native_process_frame.
@_silgen_name("native_process_still_frame")
func native_process_still_frame(_ handle: Int64, _ imageData: UnsafePointer<UInt8>?, _ width: Int32, _ height: Int32, _ resultData: UnsafeMutablePointer<Int32>?)

/// Enables gallery/verify fast-path optimisations (geometry cache, TTA
/// diversity, fast still-capture budget) on an already-constructed engine.
@_silgen_name("native_set_static_image_mode")
func native_set_static_image_mode(_ handle: Int64, _ enable: Int32)

/// Block until YOLO + all capture models are ready, or until timeout_ms elapses.
/// Returns 1 when models are ready; 0 on timeout, init failure, or invalid handle.
/// Must be called on a background thread — sleeps in 10 ms increments internally.
@_silgen_name("native_await_models_ready")
func native_await_models_ready(_ handle: Int64, _ timeout_ms: Int64) -> Int32

@_silgen_name("native_reset")
func native_reset(_ handle: Int64)

/// Soft-reset between front and back scan sides.
/// Preserves the IdentitySession accumulator for cross-side identity_v2 merge.
@_silgen_name("native_begin_next_side")
func native_begin_next_side(_ handle: Int64)

@_silgen_name("native_destroy")
func native_destroy(_ handle: Int64)

/// Returns 1 on success; fills *out_data (caller must free via native_free_buffer).
@_silgen_name("native_get_cropped_card_jpeg")
func native_get_cropped_card_jpeg(
    _ handle: Int64,
    _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ outSize: UnsafeMutablePointer<Int32>?
) -> Int32

@_silgen_name("native_free_buffer")
func native_free_buffer(_ data: UnsafeMutablePointer<UInt8>?)

@_silgen_name("native_get_detected_fields")
func native_get_detected_fields(
    _ handle: Int64,
    _ outFields: UnsafeMutablePointer<NativeDetectedField>?,
    _ maxFields: Int32
) -> Int32

/// Returns OCR results as a JSON C-string allocated with strdup().
/// Caller MUST free the pointer with free() after use.
@_silgen_name("native_get_ocr_result")
func native_get_ocr_result(_ handle: Int64) -> UnsafeMutablePointer<CChar>?

/// Returns the final resolved scan result (including identity_v2 when enabled) as a
/// JSON C-string allocated with strdup().
/// Caller MUST free the pointer with free() after use.
/// Returns strdup("{}") on error or if no capture has occurred.
@_silgen_name("native_get_final_result_json")
func native_get_final_result_json(_ handle: Int64) -> UnsafeMutablePointer<CChar>?

@_silgen_name("native_get_field_progress_json")
func native_get_field_progress_json(_ handle: Int64) -> UnsafeMutablePointer<CChar>?

@_silgen_name("native_add_external_ocr")
func native_add_external_ocr(_ handle: Int64, _ json: UnsafePointer<CChar>?)

/// Returns 1 and writes cx/cy ∈ [0,1] (crop-normalised) when a weak field is found;
/// returns 0 when all fields are confident or no OCR data has been accumulated yet.
@_silgen_name("native_get_weak_field_center")
func native_get_weak_field_center(_ handle: Int64,
                                  _ out_cx: UnsafeMutablePointer<Float>,
                                  _ out_cy: UnsafeMutablePointer<Float>) -> Int32

/// Run OCR on a pre-warped (perspective-corrected) card image supplied as raw BGRA pixels.
/// version = -1 triggers auto-classification inside C++.
/// Returns a JSON C-string allocated with strdup(); caller MUST free() the pointer.
/// Returns nil (NULL) on invalid input.
@_silgen_name("native_run_ocr_on_crop_bgra")
func native_run_ocr_on_crop_bgra(
    _ handle: Int64,
    _ bgraData: UnsafePointer<UInt8>?,
    _ width: Int32,
    _ height: Int32,
    _ version: Int32
) -> UnsafeMutablePointer<CChar>?

/// Returns the opaque per-side result JSON allocated with strdup().
/// Call AFTER a single-side capture and BEFORE reset()/beginNextSide().
/// Returns strdup("{}") if no capture has occurred or on error.
/// Caller MUST free() the returned pointer.
@_silgen_name("native_get_side_result_json")
func native_get_side_result_json(_ handle: Int64) -> UnsafeMutablePointer<CChar>?

/// Stateless cross-side comparison.
/// Accepts the two per-side blobs produced by native_get_side_result_json.
/// strict=1 requires strict same-document mode.
/// license_json is RSA-PSS-SHA256 verified by the C bridge before compareSides executes.
/// Returns a verify-result JSON string allocated with strdup(); caller MUST free() it.
@_silgen_name("native_compare_sides")
func native_compare_sides(
    _ front_json:   UnsafePointer<CChar>?,
    _ back_json:    UnsafePointer<CChar>?,
    _ strict:       Int32,
    _ license_json: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?
#endif // !targetEnvironment(simulator) || arch(x86_64)
