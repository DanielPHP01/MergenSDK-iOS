import SwiftUI
import UIKit
import Foundation
import os

private let mergenScanLog = Logger(subsystem: "com.mergen", category: "mergen.scan")

// ─────────────────────────────────────────────────────────────────────────────
// MIDSide — which physical side of the document is being scanned.
//
// This is a declarative/UX hint passed by the caller; the engine auto-classifies
// the actual card version from pixel content and may return Front2008/2017/2025
// regardless of which MIDSide was declared. Pass the declaration through to
// MergenScanResult so the caller can track scan order.
// ─────────────────────────────────────────────────────────────────────────────

/// The intended scanning side (front or back) declared by the caller.
///
/// The C++ engine auto-classifies the physical card version from pixel content,
/// so this value is a declarative UX hint — it does not constrain engine behaviour.
public enum MIDSide {
    case front
    case back
}

// ─────────────────────────────────────────────────────────────────────────────
// MergenScanResult — result of a single completed MergenScanView scan.
// ─────────────────────────────────────────────────────────────────────────────

/// Result returned by `MergenScanView.onResult` after a successful single-side scan.
///
/// Pass `front` and `back` results to `Mergen.verifyCards(front:back:license:)` to
/// perform cross-side identity verification.
public struct MergenScanResult {
    /// The scan-side declaration the caller passed to `MergenScanView`.
    public let side: MIDSide

    /// Card layout version string detected by the engine, e.g. `"Front2025"`, `"Back2017"`.
    /// `"unknown"` when the classifier did not fire (poor quality / unrecognised card).
    public let version: String

    /// Personal identification number read from the card, if available.
    /// Populated from OCR `personal_number` field or MRZ-derived PIN.
    /// `nil` for Front2017/Front2025 cards which carry no printed PIN.
    public let pin: String?

    /// MRZ lines joined by `"\n"`. `nil` when no MRZ was detected (front sides).
    public let mrz: String?

    /// Perspective-corrected card crop captured by the engine.
    /// `nil` when capture quality was insufficient.
    public let croppedPhoto: UIImage?

    /// Opaque per-side JSON blob from `native_get_side_result_json`.
    /// Internal use only — passed to `Mergen.verifyCards` via `compareSides`.
    internal let sideJson: String

    /// Full camera frame (≤2048px long-edge) captured at the moment of finalization.
    /// `nil` for gallery-sourced results or when the engine did not produce an original frame.
    /// TODO(DEBUG-ARCHIVE): Used by ScanArchiver for field-data collection; harmless in release
    /// but not needed by client apps — consider removing from public API after archive tooling
    /// is extracted into a separate module.
    public var originalPhoto: UIImage? = nil

    /// Tech-JSON blob from `native_get_final_result_json`, populated by ScanFinalizer.
    /// Contains the `identity_v2` block when identity reconciliation was enabled.
    /// `nil` when absent or the engine returned `"{}"`.
    /// TODO(DEBUG-ARCHIVE): Used by ScanArchiver for field-data collection.
    public var finalJson: String? = nil

    /// `true` when the scan captured enough per-side engine data to use the fast
    /// `Mergen.verifyCards` path (calls `nativeCompareSides`, ~1 ms, no re-OCR).
    /// `false` when the snapshot blob is absent or empty — fall back to `Mergen.verify`.
    public var hasSideSnapshot: Bool {
        let t = sideJson.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t != "{}"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MergenScanView — single-side live camera scan wrapped as a SwiftUI View.
// ─────────────────────────────────────────────────────────────────────────────

/// A SwiftUI view that runs a single-side live camera scan and returns a
/// `MergenScanResult` when the card is successfully captured.
///
/// Wraps `MergenScannerView` and manages the license, style, and result wiring.
/// The SDK draws only the bounding box; the caller can render custom overlay UI
/// via `onState`.
///
/// **Minimal usage:**
/// ```swift
/// MergenScanView(side: .front, license: licenseJson) { result in
///     frontResult = result
/// }
/// ```
///
/// **With custom state overlay:**
/// ```swift
/// MergenScanView(
///     side: .back,
///     license: licenseJson,
///     bboxColor: "00E676FF",
///     bboxStyle: .cornersOnly,
///     onState: { state in
///         DispatchQueue.main.async { self.hint = state.messageHint }
///     }
/// ) { result in
///     backResult = result
/// }
/// ```
///
/// - Parameters:
///   - side:      Declarative scan-side hint (`front` or `back`). Passed through to `MergenScanResult`; does not constrain the engine.
///   - license:   License JSON string. When `nil`, the SDK reads `license.json` from the main bundle.
///   - bboxColor: 8-digit RGBA hex string (e.g. `"00E676FF"`) for the bbox colour. Uses the style default when `nil`.
///   - bboxStyle: Bounding-box draw style. Default: `.cornersOnly`.
///   - onState:   Optional per-frame state callback. Called on the **main thread** with each `ScannerFrameState`. Use for hint labels or custom overlays.
///   - onResult:  Called once on the **main thread** when a side is successfully captured.
public struct MergenScanView: View {

    private let side:          MIDSide
    private let licenseKey:    String
    private let configuration: MergenScannerConfig
    private let style:         ScannerStyle
    private let onState:       ((ScannerFrameState) -> Void)?
    private let onResult:      (MergenScanResult) -> Void

    /// Primary initialiser.
    ///
    /// - Parameters:
    ///   - side:          Declarative scan-side hint. Passed through to `MergenScanResult`.
    ///   - license:       License JSON. Falls back to `license.json` in the main bundle.
    ///   - configuration: Engine settings.  Pass a `MergenScannerConfig` with
    ///                    `enforceSideMatch`, `expectedSide`, `expectedGeneration` set to
    ///                    enable the side/generation gate. **Default: `.init()` — gate off.**
    ///   - bboxColor:     8-digit RGBA hex string for the bbox colour.
    ///   - bboxStyle:     Bounding-box draw style. Default: `.cornersOnly`.
    ///   - strokeWidth:   Width of the bbox stroke in points. Default: `3` (matches `ScannerStyle` default).
    ///   - cornerLength:         Length of each corner bracket arm in points. Default: `28`.
    ///   - showGuideFrame:       Draw the static card-guide frame with dimmed surroundings;
    ///                           captures outside the guide are discarded. Forwarded to
    ///                           `ScannerStyle.showGuideFrame`. Default: `false`.
    ///   - progressBottomInset:  Extra bottom offset for the progress bar in points.
    ///                           Increase when an overlay button sits above the safe area
    ///                           bottom so the bar renders below the button. Default: `0`.
    ///   - onState:       Optional per-frame state callback (main thread).
    ///   - onResult:      Called once on the main thread when the card is captured.
    public init(
        side:                MIDSide,
        license:             String?              = nil,
        configuration:       MergenScannerConfig  = .init(),
        bboxColor:           String?              = nil,
        bboxStyle:           BBoxDrawStyle        = .cornersOnly,
        strokeWidth:         CGFloat              = 3,
        cornerLength:        CGFloat              = 28,
        showGuideFrame:      Bool                 = false,
        progressBottomInset: CGFloat              = 0,
        onState:             ((ScannerFrameState) -> Void)? = nil,
        onResult:            @escaping (MergenScanResult) -> Void
    ) {
        self.side     = side
        self.onState  = onState
        self.onResult = onResult

        // Resolve license: caller-provided > main bundle license.json.
        let resolvedLicense: String
        if let provided = license, !provided.trimmingCharacters(in: .whitespaces).isEmpty {
            resolvedLicense = provided
        } else if let bundleUrl = Bundle.main.url(forResource: "license", withExtension: "json"),
                  let loaded   = try? String(contentsOf: bundleUrl, encoding: .utf8),
                  !loaded.trimmingCharacters(in: .whitespaces).isEmpty {
            resolvedLicense = loaded
        } else {
            resolvedLicense = ""
            mergenScanLog.error("MergenScanView: no license provided and license.json not found in main bundle")
        }
        self.licenseKey = resolvedLicense

        // Inject the resolved license into the configuration so the pool key is
        // consistent (MergenEnginePool keys on licenseKey + leanIdentityFields).
        var cfg = configuration
        cfg.licenseKey = resolvedLicense
        self.configuration = cfg

        // Build style from bboxColor + bboxStyle + explicit stroke/corner dims.
        self.style = ScannerStyle { s in
            s.bboxDrawStyle       = bboxStyle
            s.strokeWidth         = strokeWidth
            s.cornerLength        = cornerLength
            s.showGuideFrame      = showGuideFrame
            s.progressBottomInset = progressBottomInset
            if let hex = bboxColor, let color = Self.colorFromHex(hex) {
                s.colorIdle      = color
                s.colorDetecting = color
                s.colorSuccess   = color
            }
        }
    }

    public var body: some View {
        let capturedSide = side
        let capturedOnState = onState
        let capturedOnResult = onResult
        let capturedConfig = configuration

        // When the caller observes frame state (to draw its OWN overlay), forward it and
        // suppress the built-in overlay. Otherwise use MergenScannerView's default
        // style-based overlay so the bbox actually renders — previously a customOverlay
        // returning EmptyView() was always supplied, which suppressed the default overlay
        // AND drew nothing, so bboxColor/bboxStyle had no visible effect.
        if let onState = capturedOnState {
            MergenScannerView(
                licenseKey:    licenseKey,
                configuration: capturedConfig,
                style:         style,
                onFinished: { result in
                    capturedOnResult(Self.buildScanResult(from: result, side: capturedSide))
                },
                customOverlay: { state in
                    onState(state)
                    return EmptyView()
                }
            )
        } else {
            MergenScannerView(
                licenseKey:    licenseKey,
                configuration: capturedConfig,
                style:         style,
                onFinished: { result in
                    capturedOnResult(Self.buildScanResult(from: result, side: capturedSide))
                }
            )
        }
    }

    // ── Helpers ───────────────────────────────────────────────

    /// Maps an `MergenIdResult` to a `MergenScanResult`.
    ///
    /// Extracts `pin` and `mrz` from OCR fields first, then falls back to parsing
    /// `sideResultJson` so that lean-mode results (where OCR is populated sparsely)
    /// still surface the correct values.
    internal static func buildScanResult(
        from result: MergenIdResult,
        side: MIDSide
    ) -> MergenScanResult {
        // ── Version string ─────────────────────────────────────
        let version: String = {
            switch result.cardVersion {
            case .front2008: return "Front2008"
            case .front2017: return "Front2017"
            case .front2025: return "Front2025"
            case .back2008:  return "Back2008"
            case .back2017:  return "Back2017"
            case .back2025:  return "Back2025"
            case .unknown:   return "unknown"
            }
        }()

        // ── Side JSON blob ─────────────────────────────────────
        // sideResultJson is populated by ScanFinalizer.finalizeAndDeliver()
        // before the engine is reset, so it always reflects the just-completed side.
        let sideJson = result.sideResultJson ?? "{}"

        // ── PIN ────────────────────────────────────────────────
        // Priority: C++ OCR personal_number > sideJson "personal_number" > sideJson "mrz_pin_value"
        var pin: String? = result.ocrResult?.personalNumber.flatMap { $0.isEmpty ? nil : $0 }
        if pin == nil {
            pin = stringFromJson(sideJson, key: "personal_number")
                ?? stringFromJson(sideJson, key: "mrz_pin_value")
        }

        // ── MRZ ────────────────────────────────────────────────
        // Join non-empty MRZ lines from OCR first, then fall back to sideJson.
        var mrz: String? = {
            let lines: [String] = [
                result.ocrResult?.mrzLine1,
                result.ocrResult?.mrzLine2,
                result.ocrResult?.mrzLine3,
            ].compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }()
        if mrz == nil {
            let l1 = stringFromJson(sideJson, key: "mrz_line1")
            let l2 = stringFromJson(sideJson, key: "mrz_line2")
            let l3 = stringFromJson(sideJson, key: "mrz_line3")
            let lines = [l1, l2, l3].compactMap { $0 }
            if !lines.isEmpty { mrz = lines.joined(separator: "\n") }
        }

        return MergenScanResult(
            side:          side,
            version:       version,
            pin:           pin,
            mrz:           mrz,
            croppedPhoto:  result.croppedImage,
            sideJson:      sideJson,
            originalPhoto: result.originalImage,
            finalJson:     result.finalJson
        )
    }

    /// Extracts a non-empty String value for `key` from a minimal JSON object string.
    /// Uses lightweight JSONSerialization — no regex dependency.
    private static func stringFromJson(_ json: String, key: String) -> String? {
        guard json != "{}",
              let data   = json.data(using: .utf8),
              let dict   = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value  = dict[key] as? String,
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Parses an 8-character RGBA hex string (`"RRGGBBAA"`) into a SwiftUI `Color`.
    /// Also accepts 6-character RGB (`"RRGGBB"`, alpha assumed 1.0).
    /// Returns `nil` for malformed strings.
    private static func colorFromHex(_ hex: String) -> Color? {
        let clean = hex.trimmingCharacters(in: .alphanumerics.inverted)
        let scanner = Scanner(string: clean)
        var value: UInt64 = 0
        guard scanner.scanHexInt64(&value) else { return nil }

        let r, g, b, a: Double
        switch clean.count {
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >>  8) & 0xFF) / 255
            a = Double( value        & 0xFF) / 255
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >>  8) & 0xFF) / 255
            b = Double( value        & 0xFF) / 255
            a = 1.0
        default:
            return nil
        }
        return Color(red: r, green: g, blue: b, opacity: a)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mergen.verifyCards — cross-side identity verification from live scan results.
// ─────────────────────────────────────────────────────────────────────────────

extension Mergen {

    /// Construct a `MergenScanResult` from a `MergenIdResult` returned by a live scan.
    ///
    /// Use this in client apps (outside the SDK module) where the internal memberwise
    /// initializer of `MergenScanResult` is not accessible. Typical usage in a two-phase
    /// camera flow:
    ///
    /// ```swift
    /// let frontScanResult = Mergen.makeScanResult(idResult: frontIdResult, side: .front)
    /// let backScanResult  = Mergen.makeScanResult(idResult: backIdResult,  side: .back)
    /// let verdict = try await Mergen.verifyCards(front: frontScanResult, back: backScanResult, license: license)
    /// ```
    ///
    /// Version, PIN, MRZ, and the opaque `sideJson` blob are extracted with the exact same
    /// logic `MergenScanView` uses internally (OCR fields first, `sideResultJson` fallback).
    ///
    /// - Parameters:
    ///   - idResult:     `MergenIdResult` from `MergenScannerView`'s `onFinished` callback.
    ///   - side:         Declarative scan-side hint; stored verbatim in `MergenScanResult.side`.
    ///   - croppedPhoto: Override for the card crop image. When `nil`, uses
    ///                   `MergenIdResult.croppedImage` (which may also be nil).
    /// - Returns: A fully populated `MergenScanResult` ready to pass to `verifyCards`.
    public static func makeScanResult(
        idResult:     MergenIdResult,
        side:         MIDSide,
        croppedPhoto: UIImage? = nil
    ) -> MergenScanResult {
        let base = MergenScanView.buildScanResult(from: idResult, side: side)
        guard let override_ = croppedPhoto else { return base }
        return MergenScanResult(
            side:          base.side,
            version:       base.version,
            pin:           base.pin,
            mrz:           base.mrz,
            croppedPhoto:  override_,
            sideJson:      base.sideJson,
            originalPhoto: base.originalPhoto,
            finalJson:     base.finalJson
        )
    }

    /// Verify a Kyrgyz ID document from two completed `MergenScanResult` objects.
    ///
    /// This is the **stateless** counterpart to `Mergen.verify(front:back:license:)`.
    /// Instead of feeding raw `UIImage` frames through the engine pipeline, it calls
    /// the stateless C++ `native_compare_sides` function using the opaque per-side blobs
    /// captured by `MergenScanView` at finalization time. This is fast (<1 ms) because
    /// all OCR has already been done during the live camera scan.
    ///
    /// ### Typical usage
    /// ```swift
    /// let result = try await Mergen.verifyCards(
    ///     front: frontResult,
    ///     back:  backResult,
    ///     license: licenseJson
    /// )
    /// if result.status == .verified {
    ///     showSuccess(result.verifyId)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - front:   `MergenScanResult` from a `MergenScanView` scan of the front side.
    ///   - back:    `MergenScanResult` from a `MergenScanView` scan of the back side.
    ///   - license: License JSON string. Must not be empty.
    ///   - strict:  When `true`, applies strict same-document mode: downgrades `.verified`
    ///              to `.failed` on `MISMATCH` or irresolvable `UNKNOWN`/`SINGLE_SIDE`.
    ///              `.sameWithWarning` is never downgraded. Default: `false`.
    /// - Returns: A `VerifyResult` with verdict and fused identity fields.
    /// - Throws:
    ///   - `MergenError.licenseEmpty` when `license` is blank.
    public static func verifyCards(
        front:   MergenScanResult,
        back:    MergenScanResult,
        license: String,
        strict:  Bool = false
    ) async throws -> VerifyResult {
        guard !license.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MergenError.licenseEmpty
        }

        // compareSides is a fast synchronous call — no engine lifecycle needed.
        // Run it off the main actor to avoid blocking UI.
        // License is captured by value (String is value type) — safe to use in Task.
        // The C bridge verifies RSA-PSS-SHA256 before executing compareSides.
        let capturedLicense = license
        let compareJson = await Task.detached(priority: .userInitiated) {
            MergenEngine.compareSides(
                front:   front.sideJson,
                back:    back.sideJson,
                strict:  strict,
                license: capturedLicense
            )
        }.value

        return parseVerifyResultFromCompare(
            json:          compareJson,
            frontPhoto:    front.croppedPhoto,
            backPhoto:     back.croppedPhoto,
            frontSideJson: front.sideJson,
            backSideJson:  back.sideJson,
            strict:        strict
        )
    }

    /// Rebuild the diagnostic ocr_prod JSON string the result UI expects from a per-side
    /// `sideJson` (`native_get_side_result_json`). compareSides is stateless and does not
    /// emit the per-side visual blob, so the fast verifyCards path must reconstruct it.
    /// Maps `personal_number`→`pin`, `mrz_doc_value`→`mrz_doc_number`, `mrz_pin_value`→
    /// `mrz_pin`, and joins `mrz_line{1,2,3}`→`mrz_full`. Returns a JSON string carrying
    /// the same keys the result screen parses back out of `VerifyResult.ocrProdFront/Back`
    /// (see `srvParseOcrProd`); nil on parse/serialisation failure.
    ///
    /// NOTE: `VerifyResult.ocrProdFront/Back` is a raw JSON *string* (public contract),
    /// so this must return `String?`, NOT `[String: Any]?`.
    private static func ocrProdJsonFromSideJson(_ sideJson: String) -> String? {
        let trimmed = sideJson.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "{}",
              let data = sideJson.data(using: .utf8),
              let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        func f(_ k: String) -> String { (s[k] as? String) ?? "" }
        let mrzFull = [f("mrz_line1"), f("mrz_line2"), f("mrz_line3")]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let dict: [String: Any] = [
            "side":           f("side"),
            "version":        f("version"),
            "doc_number":     f("doc_number"),
            "pin":            f("personal_number"),
            "mrz_doc_number": f("mrz_doc_value"),
            "mrz_pin":        f("mrz_pin_value"),
            "mrz_full":       mrzFull,
        ]
        guard let out = try? JSONSerialization.data(withJSONObject: dict),
              let jsonStr = String(data: out, encoding: .utf8)
        else { return nil }
        return jsonStr
    }

    // ── Internal: compare JSON → VerifyResult ────────────────────────────────
    //
    // The compare JSON from native_compare_sides uses the SAME top-level keys as
    // the finalJson produced by native_get_final_result_json (by design — both go
    // through the same C++ IdentitySession::buildVerifyJson path).  We reuse all
    // existing enum-from-string helpers already defined on the public types.

    private static func parseVerifyResultFromCompare(
        json:          String,
        frontPhoto:    UIImage?,
        backPhoto:     UIImage?,
        frontSideJson: String,
        backSideJson:  String,
        strict:        Bool
    ) -> VerifyResult {
        guard json != "{}",
              !json.trimmingCharacters(in: .whitespaces).isEmpty,
              let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .failed(
                message:    "Не удалось выполнить верификацию",
                messageEn:  "Verification failed — no result from compare engine",
                frontPhoto: frontPhoto,
                backPhoto:  backPhoto
            )
        }

        // ── Top-level scalar fields ────────────────────────────
        let statusStr    = root["status"]        as? String ?? "UNKNOWN"
        let messageRu    = (root["message_ru"]   as? String).flatMap { $0.isEmpty ? nil : $0 }
        let messageEn    = (root["message_en"]   as? String).flatMap { $0.isEmpty ? nil : $0 }
        let verifyId     = root["verify_id"]     as? String ?? ""
        let verifyPin    = root["verify_pin"]    as? String ?? ""
        let mrzConfirmed = root["mrz_confirmed"] as? Bool   ?? false

        let docNumber    = (root["doc_number"]     as? String).flatMap { $0.isEmpty ? nil : $0 }
        let pin          = (root["pin"]            as? String).flatMap { $0.isEmpty ? nil : $0 }
        let mrzDocNumber = (root["mrz_doc_number"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let mrzPin       = (root["mrz_pin"]        as? String).flatMap { $0.isEmpty ? nil : $0 }
        let mrzFull      = (root["mrz_full"]       as? String).flatMap { $0.isEmpty ? nil : $0 }

        // ── same_document ──────────────────────────────────────
        let sameDocStr = (root["same_document"] as? String) ?? "UNKNOWN"
        let sameDoc    = SameDocumentVerdict.fromString(sameDocStr)
        let sameScore  = root["same_score"] as? Double ?? 0.0
        _ = sameScore // carried in verdict enum; score available when needed

        // ── Confidence badges ──────────────────────────────────
        // compareSides does not emit identity_v2 field detail, so we derive
        // badges from mrzConfirmed as the best available signal.
        let docBadge: ConfidenceBadge = mrzConfirmed ? .confirmed : .probable
        let pinBadge: ConfidenceBadge = mrzConfirmed ? .confirmed : .probable

        // ── Strict mode downgrade ──────────────────────────────
        var status = VerifyStatus.fromString(statusStr)
        if strict, status.isSuccess {
            if sameDoc == .mismatch || sameDoc == .unknown || sameDoc == .singleSide {
                status = .failed
            }
        }

        let suppressMessage = status.isSuccess

        return VerifyResult(
            status:                 status,
            message:                suppressMessage ? nil : messageRu,
            messageEn:              suppressMessage ? nil : messageEn,
            verifyId:               verifyId,
            verifyPin:              verifyPin,
            docNumber:              docNumber ?? verifyId.nilIfEmptyLocal,
            pin:                    pin       ?? verifyPin.nilIfEmptyLocal,
            mrzDocNumber:           mrzDocNumber,
            mrzPin:                 mrzPin,
            mrzFull:                mrzFull,
            mrzConfirmed:           mrzConfirmed,
            sameDocument:           sameDoc,
            docBadge:               docBadge,
            pinBadge:               pinBadge,
            frontFieldAvailability: nil,
            backFieldAvailability:  nil,
            // Fast path (verifyCards): rebuild the per-side visual ocr_prod dict from
            // each side's own sideJson — compareSides is stateless and omits it, which
            // left the result screen's "visual" fields blank.
            ocrProdFront:           ocrProdJsonFromSideJson(frontSideJson),
            ocrProdBack:            ocrProdJsonFromSideJson(backSideJson),
            frontPhoto:             frontPhoto,
            backPhoto:              backPhoto,
            mrzMatch: {
                // Try the native mrz_match block first (future C++ may emit it here).
                // When absent (current normal case for compareSides), synthesize from
                // the top-level scalar fields the compare JSON always provides.
                let fromBlock = parseMrzMatchBlock(root)
                return fromBlock.isEmpty ? synthesizeMrzMatchFromCompare(root) : fromBlock
            }()
        )
    }
}

// ── synthesizeMrzMatchFromCompare ─────────────────────────────────────────────
//
// Builds a [MrzMatch] list from the top-level scalar fields emitted by
// native_compare_sides.  Used when the C++ compare result does not include an
// mrz_match block (the normal case — compareSides skips the full reconcile step).
//
// Compares visual vs MRZ values for doc_number and personal_number:
//   doc_number      : visual = "doc_number"   vs mrz = "mrz_doc_number"
//   personal_number : visual = "pin"          vs mrz = "mrz_pin"
//
// match = .unavailable when either source is empty (cannot compare).
// mrzChecksumOk for doc_number comes from the top-level "mrz_confirmed" flag;
// the compare JSON does not carry per-PIN checksum flags so PIN entry is always false.

private func synthesizeMrzMatchFromCompare(_ root: [String: Any]) -> [MrzMatch] {
    func f(_ k: String) -> String? {
        (root[k] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    let mrzConfirmed = root["mrz_confirmed"] as? Bool ?? false

    var list: [MrzMatch] = []

    // ── doc_number ────────────────────────────────────────────────────────────
    let visualDoc = f("doc_number") ?? f("verify_id")
    let mrzDoc    = f("mrz_doc_number")
    if visualDoc != nil || mrzDoc != nil {
        let kind: MatchKind = {
            guard let v = visualDoc, let m = mrzDoc else { return .unavailable }
            return v.uppercased() == m.uppercased() ? .matches : .mismatch
        }()
        list.append(MrzMatch(
            fieldName:     "doc_number",
            visualValue:   visualDoc ?? "",
            mrzValue:      mrzDoc    ?? "",
            match:         kind,
            mrzChecksumOk: mrzConfirmed
        ))
    }

    // ── personal_number (PIN) ─────────────────────────────────────────────────
    let visualPin = f("pin") ?? f("verify_pin")
    let mrzPin    = f("mrz_pin")
    if visualPin != nil || mrzPin != nil {
        let kind: MatchKind = {
            guard let v = visualPin, let m = mrzPin else { return .unavailable }
            return v == m ? .matches : .mismatch
        }()
        list.append(MrzMatch(
            fieldName:     "personal_number",
            visualValue:   visualPin ?? "",
            mrzValue:      mrzPin    ?? "",
            match:         kind,
            mrzChecksumOk: false   // no per-PIN checksum in compare JSON
        ))
    }

    return list
}

// ── Private helper ────────────────────────────────────────────────────────────

private extension String {
    /// Returns `nil` when the string is empty; otherwise returns `self`.
    /// Local variant — avoids redeclaration conflict with the one in Mergen.swift.
    var nilIfEmptyLocal: String? { isEmpty ? nil : self }
}

// ─────────────────────────────────────────────────────────────────────────────
// MergenMemoryPressureMonitor — MEM-TRIM: warm-pool release on memory pressure.
//
// The warm pool (`MergenEnginePool`) keeps a full engine (all ONNX sessions)
// resident OUTSIDE any active scan — hundreds of MB that make the app a prime
// jetsam victim on 2–3 GB devices. This monitor is installed lazily by
// `MergenEnginePool.controller(for:)` (the single choke point through which
// every pool entry is created: warmUp / preload / verify / scanner views) and
// drops the pooled controller when the OS signals pressure:
//
//   UIApplication.didReceiveMemoryWarningNotification → release on ALL tiers
//   UIApplication.didEnterBackgroundNotification      → release on tier-0 ONLY
//                                                        (weak devices, mirrors
//                                                        Android TRIM_MEMORY_UI_HIDDEN)
//
// Deliberately NO automatic re-preload after a trim-release — see
// `MergenEnginePool.drainForMemoryPressure()`. The next real use cold-inits
// on demand (~2–6 s on weak devices, a conscious trade-off).
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
internal enum MergenMemoryPressureMonitor {

    private static var observers: [NSObjectProtocol] = []
    private static var installed = false

    /// Idempotent — called by `MergenEnginePool.controller(for:)` every time a
    /// pool entry is requested; only the first call registers observers. The
    /// observers live for the process lifetime (the pool is a process-wide
    /// singleton), so they are never removed.
    static func installIfNeeded() {
        guard !installed else { return }
        installed = true

        let center = NotificationCenter.default

        // System memory warning — applies to every device tier.
        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in releasePool(level: "memory-warning") }
        })

        // Tier-0 (weak) devices: also drop the warm pool when the app backgrounds.
        // A backgrounded app holding hundreds of MB of model memory is the #1
        // jetsam driver on 2–3 GB devices. Mirrors Android's TRIM_MEMORY_UI_HIDDEN
        // tier-0 policy.
        if DeviceTierDetector.detect() == 0 {
            observers.append(center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main
            ) { _ in
                Task { @MainActor in releasePool(level: "background-tier0") }
            })
        }

        mergenScanLog.debug("MEM-TRIM: memory-pressure monitor installed (pool-level)")
    }

    private static func releasePool(level: String) {
        guard MergenEnginePool.drainForMemoryPressure() else { return }
        mergenScanLog.warning("MEM-TRIM: pool released (level=\(level, privacy: .public))")
    }
}
