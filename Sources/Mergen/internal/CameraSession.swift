import AVFoundation
import UIKit
import Foundation
import os

/// Owns all AVFoundation lifecycle concerns: session setup, video output wiring,
/// preview layer, point-of-interest autofocus, and teardown.
///
/// Frames are delivered via [onFrame] on [processingQueue] (the same serial queue
/// that the controller uses for YOLO routing — caller must own and pass it in).
/// Focus requests are also dispatched on the calling thread (processingQueue),
/// because AVCaptureDevice configuration is thread-safe.
///
/// Thread safety:
/// - [setup()] must be called from the main thread (AVCaptureSession setup).
/// - [triggerFocusIfNeeded] / [triggerWeakFieldFocusIfNeeded] may be called from
///   processingQueue — they access AVCaptureDevice directly, which is thread-safe.
/// - [stopRunning] / [startRunning] route through processingQueue.
/// - [isClosed] is accessed ONLY from processingQueue (no lock needed on a serial queue).
///   It is set to `true` at the very start of [teardown()] and checked at the top of
///   [captureOutput(_:didOutput:from:)] so that any frames still queued in the
///   system's camera delivery machinery after [stopRunning()] are silently dropped.
private let cameraLog = Logger(subsystem: "com.mergen", category: "camera")

internal final class CameraSession: NSObject {

    // ── Output ────────────────────────────────────────────────

    /// Called on [processingQueue] for every delivered sample buffer.
    var onFrame: ((CMSampleBuffer, TimeInterval) -> Void)?

    // ── AVFoundation objects ──────────────────────────────────

    private(set) var captureSession: AVCaptureSession?
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    private var captureDevice: AVCaptureDevice?

    // ── Still-photo output (v2.1 still-capture flow) ──────────
    //
    // Bound alongside the video data output.  Used at most once per side to snap
    // a full-quality still (proper exposure, no motion blur) at the capture
    // moment.  Created in setup(); nil'd in teardown() together with the session.
    private var photoOutput: AVCapturePhotoOutput?

    /// Strong references to in-flight AVCapturePhotoCaptureDelegate objects,
    /// keyed by AVCapturePhotoSettings.uniqueID.  Belt-and-braces retention for
    /// the duration of the capture; entries are removed in the completion.
    /// Accessed only on processingQueue.
    private var inFlightPhotoDelegates: [Int64: StillPhotoDelegate] = [:]

    // ── Teardown gate (processingQueue-only) ──────────────────
    //
    // Set to `true` at the very start of teardown(), before the sample-buffer
    // delegate is removed and before stopRunning().  This ensures that frames
    // delivered by AVFoundation after stopRunning() (a documented race: the
    // system may flush 1–2 extra buffers) are silently dropped in
    // captureOutput(_:didOutput:from:) without touching onFrame or the engine.
    //
    // Reset to `false` inside setup() so that the next appearance rebuilds
    // a clean delivery path.
    //
    // Accessed only from processingQueue — no lock needed (serial queue).
    private var isClosed: Bool = false

    // ── Focus throttling ──────────────────────────────────────

    /// Monotonic timestamp of the last card-center focus request (processingQueue).
    private var lastFocusTime: TimeInterval = 0
    /// Monotonic timestamp of the last weak-field focus request (processingQueue).
    private var lastWeakFocusTime: TimeInterval = 0
    /// Normalised (0…1) POI set on the previous focus trigger (processingQueue).
    /// Used to suppress redundant triggers when the card centre hasn't shifted >5 %.
    private var lastFocusPoint: CGPoint = CGPoint(x: -1, y: -1)

    // ── Queue refs ────────────────────────────────────────────

    /// The serial queue on which frames are delivered and on which
    /// this session's frame counter / in-flight guard live.
    private let processingQueue: DispatchQueue
    /// Lazy CIContext used by the controller fallback path.
    /// Stored here since CIContext creation is expensive and belongs with the session.
    let fallbackCIContext: CIContext = CIContext(options: nil)

    // ── Init ──────────────────────────────────────────────────

    /// When `true` AND device RAM < 3 GB, camera uses `.vga640x480` instead of `.hd1280x720`.
    /// **Must default to `false`** — requires on-device YOLO accuracy validation before enabling.
    var lowResOnWeakDevice: Bool = false

    /// Gates SDK-initiated AF configuration (continuous AF at setup + POI triggers).
    /// Default `true` = pre-v2.1 behaviour. Set from `MergenScannerConfig.autofocusEnabled`.
    var autofocusEnabled: Bool = true

    /// Analysis resolution preset. Always overwritten from `MergenScannerConfig.cameraQuality`
    /// by `ScannerEngineController.init` before `setup()` is called.
    /// The field-level default here is a safety fallback only (should never be read).
    var cameraQuality: CameraQuality = .high

    /// Desired torch state (Phase A1). Written on processingQueue via `setTorch(_:)`;
    /// re-applied after `startRunning()` (a stopped session drops the torch) and
    /// reset in `teardown()`.
    private var torchEnabled: Bool = false

    init(processingQueue: DispatchQueue) {
        self.processingQueue = processingQueue
        super.init()
    }

    // ── Setup ─────────────────────────────────────────────────

    /// Configures and builds the AVCaptureSession.
    /// Must be called from the main thread.
    /// Does NOT call startRunning() — the controller does that after engine init.
    ///
    /// Idempotent: if the session is already configured (non-nil captureSession),
    /// this is a no-op. This is critical for the front→back scan transition in
    /// MergenVerifyView: the pooled ScannerEngineController is reused across both
    /// sides, so prepare() is called twice on the same CameraSession. Without this
    /// guard a second AVCaptureSession + previewLayer would be allocated, leaving
    /// the preview UI view attached to the OLD stopped session → black preview.
    func setup() {
        guard captureSession == nil else { return }
        // Reset the closed gate so the new delivery path is fully open.
        processingQueue.sync { self.isClosed = false }
        let session = AVCaptureSession()
        // Resolution from the CameraQuality preset (.balanced = .hd1280x720 = pre-v2.1
        // default). The tier-adaptive `lowResOnWeakDevice` override still applies:
        // weak devices (<3 GB) may drop to .vga640x480 ONLY when that flag is `true`
        // (default false; requires on-device YOLO accuracy validation at 640×480).
        let basePreset: AVCaptureSession.Preset
        switch cameraQuality {
        case .high:     basePreset = .hd1920x1080
        case .balanced: basePreset = .hd1280x720
        case .fast:     basePreset = .vga640x480
        }
        let isWeakDevice = ProcessInfo.processInfo.physicalMemory < 3_000_000_000
        session.sessionPreset = (lowResOnWeakDevice && isWeakDevice) ? .vga640x480 : basePreset
        captureSession = session

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input  = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }

        // Enable continuous autofocus with near-range restriction (ID cards are close to camera).
        // Gated by config.autofocusEnabled (Phase A2) — `false` keeps the platform default AF.
        if autofocusEnabled {
            try? device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            device.unlockForConfiguration()
        }
        captureDevice = device

        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: processingQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        // Lock to portrait orientation.
        if let conn = output.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if conn.isVideoRotationAngleSupported(90) {
                    conn.videoRotationAngle = 90
                }
            } else {
                if conn.isVideoOrientationSupported {
                    conn.videoOrientation = .portrait
                }
            }
        }

        // ── Still-photo output (v2.1 still-capture flow) ─────────────────────
        // Added alongside the video output.  The active (video) format on modern
        // hardware supports high-resolution stills (e.g. 4032×3024 even with a
        // 1080p session preset) — request the smallest supported photo dimension
        // whose long edge is ≥ 2048 px (the gallery-path cap: the still is
        // downscaled to 2048 before OCR anyway, so bigger stills only add
        // capture + decode latency).  Falls back to the largest supported size.
        let photo = AVCapturePhotoOutput()
        if session.canAddOutput(photo) {
            session.addOutput(photo)
            let dims = device.activeFormat.supportedMaxPhotoDimensions
            let target = dims
                .filter { max($0.width, $0.height) >= 2048 }
                .min { max($0.width, $0.height) < max($1.width, $1.height) }
                ?? dims.max { max($0.width, $0.height) < max($1.width, $1.height) }
            if let target { photo.maxPhotoDimensions = target }
            // Portrait rotation — pixel orientation matches the video frames.
            if let conn = photo.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if conn.isVideoRotationAngleSupported(90) {
                        conn.videoRotationAngle = 90
                    }
                } else if conn.isVideoOrientationSupported {
                    conn.videoOrientation = .portrait
                }
            }
            photoOutput = photo
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer
        // NOTE: startRunning() is called externally (from ScannerEngineController.prepare())
        // after the C++ engine finishes loading so frames are not dropped before YOLO is ready.
    }

    // ── Session control ───────────────────────────────────────

    func startRunning() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession?.startRunning()
            // Re-apply the desired torch state — a stopped session drops the torch
            // (Phase A1: torch persists across background/foreground pauses).
            if self.torchEnabled { self.applyTorchLocked(true) }
        }
    }

    func stopRunning() {
        processingQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
        }
    }

    // ── Torch (Phase A1) ──────────────────────────────────────

    /// Enables/disables the torch (flashlight). Safe to call from any thread —
    /// routed through processingQueue. The desired state persists across
    /// stop/start cycles and is reset in `teardown()`.
    /// No-op on devices without a torch (state is still stored).
    func setTorch(_ enabled: Bool) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.torchEnabled = enabled
            self.applyTorchLocked(enabled)
        }
    }

    /// Must be called on processingQueue. AVCaptureDevice configuration is thread-safe.
    private func applyTorchLocked(_ enabled: Bool) {
        guard let device = captureDevice, device.hasTorch else { return }
        try? device.lockForConfiguration()
        if enabled {
            if device.isTorchModeSupported(.on), device.isTorchAvailable {
                device.torchMode = .on
            }
        } else if device.isTorchModeSupported(.off) {
            device.torchMode = .off
        }
        device.unlockForConfiguration()
    }

    /// Stops the capture session and tears down all AVFoundation objects so that
    /// the next [setup()] call unconditionally rebuilds a fresh session.
    ///
    /// Call this when the scanning view disappears — it ensures that when the view
    /// reappears (e.g. back-side scan after front-side scan in the verify flow)
    /// the camera preview is always re-opened fresh, eliminating the "laggy back
    /// camera" issue caused by reusing a warm, stale AVCaptureSession.
    ///
    /// The engine (MergenEngine / ONNX models) is NOT affected — only the camera
    /// pipeline is torn down.  Model loading remains pooled and instant on the
    /// next prepare() call.
    ///
    /// Teardown order (critical — must not be reordered):
    ///   1. Set `isClosed = true` on processingQueue so queued frames are dropped.
    ///   2. Remove the sample-buffer delegate (nil) on processingQueue — prevents
    ///      AVFoundation from delivering any more frames after this point.
    ///   3. Call stopRunning() — stops the capture graph.
    ///   4. Nil all AVFoundation objects on the main thread — safe because the
    ///      delegate has already been removed and isClosed prevents onFrame calls.
    func teardown() {
        processingQueue.async { [weak self] in
            guard let self else { return }

            // Step 1: close the frame-delivery gate immediately so any frames
            // that arrive between now and stopRunning() are silently dropped.
            self.isClosed = true

            // Phase A1: reset the desired torch state — teardown is a hard stop.
            // The hardware torch turns off with the session; this keeps the sticky
            // flag from re-lighting it on the next setup()/startRunning() cycle.
            self.torchEnabled = false

            // Step 2: remove the sample buffer delegate BEFORE stopRunning().
            // AVFoundation may flush 1-2 extra buffers after stopRunning(); removing
            // the delegate here guarantees captureOutput is never called again.
            if let session = self.captureSession {
                for output in session.outputs {
                    if let videoOutput = output as? AVCaptureVideoDataOutput {
                        videoOutput.setSampleBufferDelegate(nil, queue: nil)
                    }
                }
            }

            // Step 3: stop the capture graph.
            self.captureSession?.stopRunning()

            // In-flight photo captures die with the stopped session; AVFoundation
            // retains the delegate itself until each capture completes, and the
            // completion drops the frame via the isClosed gate. Clearing here just
            // releases our belt-and-braces references early.
            self.inFlightPhotoDelegates.removeAll()

            // Step 4: nil AVFoundation objects on the main thread.
            // isClosed = true already prevents any onFrame calls, so the main-thread
            // hop here is safe — no frame can slip through between step 2 and here.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.captureSession    = nil
                self.previewLayer      = nil
                self.captureDevice     = nil
                self.photoOutput       = nil
                self.lastFocusTime     = 0
                self.lastWeakFocusTime = 0
                self.lastFocusPoint    = CGPoint(x: -1, y: -1)
            }
        }
    }

    // ── Still-photo capture (v2.1 still-capture flow) ─────────

    /// Snaps ONE still photo through the bound AVCapturePhotoOutput.
    ///
    /// No flash is fired (`flashMode = .off`) — the torch, when the caller
    /// enabled it, is an independent light source and keeps illuminating the
    /// scene during the still exposure.
    ///
    /// The completion is invoked on [processingQueue] with a UIImage decoded
    /// from the photo's file representation (EXIF orientation preserved — the
    /// engine wrapper normalizes it), or `nil` on any failure / teardown so the
    /// caller can resume the video rescan loop.
    func capturePhoto(_ completion: @escaping (UIImage?) -> Void) {
        processingQueue.async { [weak self] in
            guard let self, !self.isClosed,
                  let output = self.photoOutput,
                  self.captureSession?.isRunning == true else {
                completion(nil)
                return
            }

            // ── Wait for AF convergence before triggering the shutter ──────────
            // Without this, the still fires while the camera is mid-hunt after a
            // POI trigger → blurry crop.  Timeout 800 ms (P99 AF convergence on
            // A11+ is <400 ms; A9 may need up to 600 ms).  On timeout we shoot
            // anyway — the sharpness gate in processStillPhoto will handle it.
            // Thread.sleep is safe here: processingQueue is serial, stillInFlight
            // is already true, so AVFoundation discards late video frames
            // (alwaysDiscardsLateVideoFrames = true) rather than queuing them.
            let focusDeadline = CACurrentMediaTime() + 0.800
            var focusWaitMs   = 0
            while let device = self.captureDevice,
                  device.isAdjustingFocus,
                  CACurrentMediaTime() < focusDeadline {
                Thread.sleep(forTimeInterval: 0.020)
                focusWaitMs += 20
            }
            let focusLocked = !(self.captureDevice?.isAdjustingFocus ?? false)
            cameraLog.info("[focus] waited \(focusWaitMs, privacy: .public) ms for lock — locked=\(focusLocked, privacy: .public)")

            // JPEG keeps decode cheap and universally supported; the still is
            // downscaled to the 2048 gallery cap before OCR anyway.
            let settings = AVCapturePhotoSettings(
                format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.flashMode = .off
            settings.maxPhotoDimensions = output.maxPhotoDimensions

            let id = settings.uniqueID
            let delegate = StillPhotoDelegate { [weak self] image in
                guard let self else {
                    completion(nil)
                    return
                }
                self.processingQueue.async {
                    self.inFlightPhotoDelegates[id] = nil
                    // Drop the photo when the session closed while in flight.
                    completion(self.isClosed ? nil : image)
                }
            }
            self.inFlightPhotoDelegates[id] = delegate
            output.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // ── Point-of-interest autofocus ───────────────────────────

    /// Focuses and exposes on the detected card center.
    ///
    /// Throttled to once per [FOCUS_INTERVAL] seconds AND only when the normalised
    /// card centre has shifted more than 5 % of the frame — avoids interrupting
    /// a converging focus cycle while still re-aiming quickly when the card moves.
    ///
    /// Uses `.continuousAutoFocus` so the camera keeps tracking the designated
    /// region between triggers.  `.autoFocus` (single-shot) was the previous mode:
    /// it locked after one pass and never readjusted if the initial lock missed,
    /// which was the root cause of blurry iOS crops (10-14× less sharp than Android).
    ///
    /// Must be called from processingQueue — AVCaptureDevice config is thread-safe.
    func triggerFocusIfNeeded(bbox: CGRect, imageSize: CGSize) {
        guard autofocusEnabled else { return }   // A2: gated by config.autofocusEnabled
        let now = CACurrentMediaTime()
        guard now - lastFocusTime >= FOCUS_INTERVAL,
              let device = captureDevice,
              imageSize.width > 0, imageSize.height > 0,
              device.isFocusPointOfInterestSupported else { return }
        let focusPoint = CGPoint(
            x: bbox.midX / imageSize.width,
            y: bbox.midY / imageSize.height
        )
        // Displacement gate: only re-aim when bbox centre moved >5 % of frame.
        // Cards held steady must not restart continuous-AF hunting on every trigger.
        let shift = hypot(focusPoint.x - lastFocusPoint.x,
                          focusPoint.y - lastFocusPoint.y)
        guard lastFocusPoint.x < 0 || shift > 0.05 else { return }
        lastFocusPoint = focusPoint
        try? device.lockForConfiguration()
        device.focusPointOfInterest = focusPoint
        // continuousAutoFocus: camera continuously tracks the designated region.
        // This replaces the old .autoFocus (single-shot) that locked after one pass
        // and produced blurry stills when the initial lock landed at the wrong distance.
        device.focusMode = .continuousAutoFocus
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = focusPoint
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()
        lastFocusTime = now
        cameraLog.info("[focus] point=(\(String(format: "%.2f", focusPoint.x), privacy: .public),\(String(format: "%.2f", focusPoint.y), privacy: .public)) restriction=near shift=\(String(format: "%.2f", shift), privacy: .public)")
    }

    /// Focuses on the OCR field with the lowest accumulator confidence within the card area.
    /// Throttled to once per [FOCUS_INTERVAL] seconds (independent of card-center focus).
    /// [weakCenter] is a crop-normalised CGPoint from [MergenEngine.getWeakFieldCenter()].
    /// Must be called from processingQueue.
    func triggerWeakFieldFocusIfNeeded(
        cardBbox: CGRect,
        imageSize: CGSize,
        weakCenter: CGPoint
    ) {
        guard autofocusEnabled else { return }   // A2: gated by config.autofocusEnabled
        let now = CACurrentMediaTime()
        guard now - lastWeakFocusTime >= FOCUS_INTERVAL,
              let device = captureDevice,
              imageSize.width > 0, imageSize.height > 0,
              device.isFocusPointOfInterestSupported else { return }

        // Map weak field center (crop-normalised) into the card's sensor-space region,
        // then normalise by full image size for AVCaptureDevice.focusPointOfInterest.
        let absX = cardBbox.minX + weakCenter.x * cardBbox.width
        let absY = cardBbox.minY + weakCenter.y * cardBbox.height
        let focusPoint = CGPoint(
            x: absX / imageSize.width,
            y: absY / imageSize.height
        )

        try? device.lockForConfiguration()
        device.focusPointOfInterest = focusPoint
        // Same mode as triggerFocusIfNeeded: continuous tracking on the weak field.
        device.focusMode = .continuousAutoFocus
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = focusPoint
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()
        lastWeakFocusTime = now
        cameraLog.info("[focus] weak-field point=(\(String(format: "%.2f", focusPoint.x), privacy: .public),\(String(format: "%.2f", focusPoint.y), privacy: .public))")
    }

    // ── Constants ─────────────────────────────────────────────

    /// Minimum interval between AF triggers (seconds).
    /// 0.4 s ≈ 2-3 triggers/second — fast enough to follow a moving card,
    /// slow enough to avoid restarting continuousAutoFocus hunt too frequently.
    /// A 5 % displacement gate (in triggerFocusIfNeeded) further suppresses
    /// redundant triggers when the card is held steady.
    private let FOCUS_INTERVAL: TimeInterval = 0.4
}

// ── Still-photo capture delegate ──────────────────────────────
//
// AVCapturePhotoOutput retains its delegate for the duration of the capture,
// but CameraSession additionally keeps a strong reference in
// [inFlightPhotoDelegates] (removed in the completion) as belt-and-braces.
//
// Completion guarantee contract:
//   `completion` is called EXACTLY ONCE regardless of the AVFoundation path taken:
//   - Happy path: `didFinishProcessingPhoto` fires with a valid photo → completion(image).
//   - Error path: `didFinishProcessingPhoto` fires with an error → completion(nil).
//   - Skip path: AVFoundation finishes the capture sequence WITHOUT calling
//     `didFinishProcessingPhoto` (documented AVFoundation behaviour when the session
//     is interrupted, the capture is superseded, or the photo data is unavailable).
//     In this case `didFinishCaptureFor` — the FINAL method in every capture sequence —
//     fires instead, and the idempotency guard ensures completion(nil) is called once.
//
// Idempotency: `completionFired` prevents double-call when both
// `didFinishProcessingPhoto` AND `didFinishCaptureFor` happen to arrive (the former
// fires first; the latter sees the guard and is a no-op).
//
// Thread: callbacks arrive on AVFoundation's internal queue;
// CameraSession re-dispatches completion onto processingQueue.
private final class StillPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (UIImage?) -> Void
    /// Ensures `completion` is called at most once even if AVFoundation fires
    /// both `didFinishProcessingPhoto` and `didFinishCaptureFor`.
    /// Accessed only from AVFoundation's internal queue (serial per capture) — no lock needed.
    private var completionFired = false

    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard !completionFired else { return }
        completionFired = true
        if error != nil {
            completion(nil)
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion(nil)
            return
        }
        completion(image)
    }

    /// Safety net: `didFinishCaptureFor` is the LAST delegate method AVFoundation
    /// calls in every capture sequence — including cases where `didFinishProcessingPhoto`
    /// was skipped (interrupted session, superseded capture, data-unavailable).
    /// If `completion` was not yet called by the processing callback, call it with `nil`
    /// here to unblock the caller (ScannerEngineController) and reset `stillInFlight`.
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        guard !completionFired else { return }
        completionFired = true
        // didFinishProcessingPhoto was skipped — deliver nil so the controller
        // resets stillInFlight and resumes the video YOLO pipeline.
        completion(nil)
    }
}

// ── AVCaptureVideoDataOutputSampleBufferDelegate ──────────────

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // isClosed is set to true at the very start of teardown() — before the
        // delegate is removed and before stopRunning().  This guard drops any frame
        // that AVFoundation flushes after teardown() is called (AVFoundation
        // documents that 1–2 extra buffers may arrive after stopRunning()).
        // Called on processingQueue — no lock needed (serial queue).
        guard !isClosed else { return }

        // Capture the frame arrival time before any processing begins.
        // This timestamp is threaded through to ScannerFrameState and used by
        // BBoxInterpolator to extrapolate the bbox forward by the processing lag.
        let captureTime = CACurrentMediaTime()
        onFrame?(sampleBuffer, captureTime)
    }
}
