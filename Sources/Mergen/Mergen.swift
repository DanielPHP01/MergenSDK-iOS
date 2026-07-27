import UIKit
import os

private let mergenLog = Logger(subsystem: "com.mergen", category: "mergen")

// ─────────────────────────────────────────────────────────────────────────────
// Mergen — public façade for Kyrgyz ID lean-identity verification
//
// Additive MINOR API surface over the existing MergenScanner SDK.
// SemVer: 1.0 → 1.1  (no breaking changes to existing public types).
//
// Minimal integration (2 lines):
// ```swift
// let result = try await Mergen.verify(front: frontImage, back: backImage, license: licenseJson)
// if result.status == .verified { showSuccess(result.verifyId) }
// ```
// ─────────────────────────────────────────────────────────────────────────────

// ── VerifyStatus ─────────────────────────────────────────────────────────────

/**
 Outcome of a `Mergen.verify` call.

 Maps 1-to-1 to the C++ engine's top-level "status" string in the final JSON
 (produced by `MergenEngine::getFinalResultJson` T1 logic).

 | Status          | Meaning                                                                          |
 |-----------------|----------------------------------------------------------------------------------|
 | verified        | MRZ read + checksum OK + verdict SAME → full, MRZ-anchored confirmation.         |
 | verifiedVisual  | Verdict SAME (SAME_DOCUMENT / SAME_WITH_WARNING) + doc# (and PIN for 2008)       |
 |                 | readable, but back MRZ NOT ok → visual cross-check only, no MRZ anchor.          |
 | failedFront     | Front side could not be read (doc# missing / unreadable / quality fail).         |
 | failedBack      | No back side / no MRZ AND sides don't agree (can't establish same-document).     |
 | failed          | Cross-side mismatch (different documents) or other hard failure.                 |
 | unknown         | Forward-compat fallback for future engine versions.                               |
 */
public enum VerifyStatus: String {
    case unknown         = "UNKNOWN"
    case verified        = "VERIFIED"
    /// Visual cross-check only — sides agree on doc# / PIN but MRZ was not readable.
    case verifiedVisual  = "VERIFIED_VISUAL"
    case failedFront     = "FAILED_FRONT"
    case failedBack      = "FAILED_BACK"
    case failed          = "FAILED"

    /// Case-insensitive factory; returns `.unknown` for unrecognised strings.
    public static func fromString(_ s: String) -> VerifyStatus {
        VerifyStatus(rawValue: s.uppercased()) ?? .unknown
    }

    /// True for any successful outcome (full MRZ-anchored or visual-only).
    public var isSuccess: Bool {
        self == .verified || self == .verifiedVisual
    }
}

// ── VerifyResult ─────────────────────────────────────────────────────────────

/**
 Typed result returned by `Mergen.verify`.

 All fields except `status` are optional — absent when the corresponding side
 was not scanned or the field was not read by the engine.

 ### Identity fields (lean mode — doc# + PIN + MRZ only)
 - `docNumber`:    Best-fused doc_number after MRZ↔front cross-validation.
 - `pin`:          Best-fused personal_number (PIN); nil for Front2017/Front2025.
 - `mrzDocNumber`: MRZ-derived doc_number from back side (L1[5..13]); nil if MRZ absent.
 - `mrzPin`:       MRZ-derived personal_number (L1[15..28]); nil if MRZ absent.
 - `mrzFull`:      Canonical MRZ lines joined by '\\n'; nil if MRZ absent.

 ### Authoritative headline values
 - `verifyId`:  Most-confident doc_number after MRZ-as-truth fusion (C++ `verify_id`).
 - `verifyPin`: Most-confident personal_number after fusion (C++ `verify_pin`).

 ### Cross-side verdict
 - `sameDocument`: Same-document verdict from the C++ reconcile() step.

 ### Diagnostics
 - `ocrProdFront`: Raw OCR_PROD JSON for the front side (for logging / diagnostics only).
 - `ocrProdBack`:  Raw OCR_PROD JSON for the back side (for logging / diagnostics only).
 - `frontPhoto`:   Perspective-corrected FRONT crop; nil when front detection failed.
 - `backPhoto`:    Perspective-corrected BACK crop; nil when back detection failed.

 ### Per-side field availability
 - `frontFieldAvailability`: Physical field availability for the detected front version.
 - `backFieldAvailability`:  Physical field availability for the detected back version.

 ### UX copy
 - `message`:   Human-readable verdict summary (Russian); nil for `.verified` status.
 - `messageEn`: Human-readable verdict summary (English); nil for `.verified` status.
 */
public struct VerifyResult {
    public let status:       VerifyStatus
    public let message:      String?
    public let messageEn:    String?

    // ── Authoritative headline values (MRZ-as-truth fusion) ──────
    /// Most-confident doc_number after cross-validation. Empty string when unavailable.
    public let verifyId:     String
    /// Most-confident personal_number (PIN) after cross-validation. Empty when unavailable.
    public let verifyPin:    String

    // ── Identity fields ───────────────────────────────────────────
    public let docNumber:    String?
    public let pin:          String?
    public let mrzDocNumber: String?
    public let mrzPin:       String?
    public let mrzFull:      String?

    // ── MRZ anchor flag ──────────────────────────────────────────
    /// `true` when the back MRZ was successfully read and its checksum validated.
    /// `false` for `.verifiedVisual` results (visual cross-check only, no MRZ anchor).
    public let mrzConfirmed: Bool

    // ── Cross-side verdict ────────────────────────────────────────
    public let sameDocument: SameDocumentVerdict

    // ── Per-field confidence / badge ──────────────────────────────
    /// Confidence badge for the fused doc_number headline.
    public let docBadge:     ConfidenceBadge
    /// Confidence badge for the fused personal_number headline.
    public let pinBadge:     ConfidenceBadge

    // ── Field availability ────────────────────────────────────────
    public let frontFieldAvailability: FieldAvailability?
    public let backFieldAvailability:  FieldAvailability?

    // ── Raw diagnostics (not for primary business logic) ─────────
    public let ocrProdFront: String?
    public let ocrProdBack:  String?
    public let frontPhoto:   UIImage?
    public let backPhoto:    UIImage?

    // ── Per-field visual ↔ MRZ comparison ─────────────────────────────────────
    /// Ordered list of per-field visual vs MRZ comparisons from the engine's
    /// `mrz_match` block. Contains one entry per field where a visual value
    /// and/or MRZ value was available (typically doc_number + personal_number).
    /// Empty when MRZ was not read or engine version predates mrz_match.
    ///
    /// Cross-platform parity: mirrors Android `VerifyResult.mrzMatch: List<FieldCompare>`.
    public let mrzMatch: [MrzMatch]

    // ── Internal memberwise init ───────────────────────────────────────────────
    // `internal` (not `public`) so that adding new stored properties in future
    // MINOR releases does not break client code that calls this init by position.
    // Clients receive `VerifyResult` exclusively via `Mergen.verify`,
    // `Mergen.verifyCards`, or the public `VerifyResult.failed(...)` factory.
    internal init(
        status:                 VerifyStatus,
        message:                String?,
        messageEn:              String?,
        verifyId:               String,
        verifyPin:              String,
        docNumber:              String?,
        pin:                    String?,
        mrzDocNumber:           String?,
        mrzPin:                 String?,
        mrzFull:                String?,
        mrzConfirmed:           Bool,
        sameDocument:           SameDocumentVerdict,
        docBadge:               ConfidenceBadge,
        pinBadge:               ConfidenceBadge,
        frontFieldAvailability: FieldAvailability?,
        backFieldAvailability:  FieldAvailability?,
        ocrProdFront:           String?,
        ocrProdBack:            String?,
        frontPhoto:             UIImage?,
        backPhoto:              UIImage?,
        mrzMatch:               [MrzMatch] = []
    ) {
        self.status                 = status
        self.message                = message
        self.messageEn              = messageEn
        self.verifyId               = verifyId
        self.verifyPin              = verifyPin
        self.docNumber              = docNumber
        self.pin                    = pin
        self.mrzDocNumber           = mrzDocNumber
        self.mrzPin                 = mrzPin
        self.mrzFull                = mrzFull
        self.mrzConfirmed           = mrzConfirmed
        self.sameDocument           = sameDocument
        self.docBadge               = docBadge
        self.pinBadge               = pinBadge
        self.frontFieldAvailability = frontFieldAvailability
        self.backFieldAvailability  = backFieldAvailability
        self.ocrProdFront           = ocrProdFront
        self.ocrProdBack            = ocrProdBack
        self.frontPhoto             = frontPhoto
        self.backPhoto              = backPhoto
        self.mrzMatch               = mrzMatch
    }

    // ── Public static factory for error / failure results ─────────────────────
    /// Creates a typed failure `VerifyResult` that callers can construct without
    /// knowing the internal field layout.
    ///
    /// Use this in error handlers instead of calling the internal memberwise init:
    /// ```swift
    /// catch {
    ///     return .failed(message: error.localizedDescription,
    ///                    messageEn: error.localizedDescription,
    ///                    frontPhoto: front, backPhoto: back)
    /// }
    /// ```
    public static func failed(
        message:    String,
        messageEn:  String,
        frontPhoto: UIImage? = nil,
        backPhoto:  UIImage? = nil
    ) -> VerifyResult {
        VerifyResult(
            status:                 .failed,
            message:                message,
            messageEn:              messageEn,
            verifyId:               "",
            verifyPin:              "",
            docNumber:              nil,
            pin:                    nil,
            mrzDocNumber:           nil,
            mrzPin:                 nil,
            mrzFull:                nil,
            mrzConfirmed:           false,
            sameDocument:           .unknown,
            docBadge:               .unknown,
            pinBadge:               .unknown,
            frontFieldAvailability: nil,
            backFieldAvailability:  nil,
            ocrProdFront:           nil,
            ocrProdBack:            nil,
            frontPhoto:             frontPhoto,
            backPhoto:              backPhoto,
            mrzMatch:               []
        )
    }
}

// ── MergenConfig ─────────────────────────────────────────────────────────────

/**
 Runtime configuration for a `Mergen.verify` call.

 All settings have production-safe defaults — override only what you need.
 Construct via closure:
 ```swift
 try await Mergen.verify(front: f, back: b, license: lic) {
     $0.strictSameDocument = true
 }
 ```

 - `leanFields`:          Read only doc# + PIN + MRZ. Dramatically reduces latency. Default: **true**.
 - `strictSameDocument`:  When `true`, downgrade `.verified` to `.failed` only on a true
                          `.mismatch` or irresolvable `.unknown`/`.singleSide` verdict.
                          `.sameWithWarning` (1-edit distance, same document) is **never**
                          downgraded — it counts as verified in both strict and non-strict mode.
                          Default: **false**.
 - `debugLogging`:        Emit verbose console output. Default: **false**.
 - `diagnosticCallback`: Optional closure called from the gallery thread with a diagnostic
                         line (step name + value). Use in debug/test only to populate an
                         on-screen banner without waiting for the full result. Default: **nil**.
                         Called on an arbitrary background thread — do NOT touch UIKit directly;
                         dispatch to main if needed (e.g. via `DispatchQueue.main.async`).
 */
public struct MergenConfig {
    public var leanFields:         Bool = true
    public var strictSameDocument: Bool = false
    /// Gallery feed budget per side.
    /// MUST be > C++ kTimeoutFrames (10) so the engine's timeout-capture path fires
    /// on static images that cannot satisfy the `card_is_still` motion gate.
    /// Default: **15** (previous default of 4 caused empty results — timeout never fired).
    public var retryBudget:        Int  = 15
    public var debugLogging:       Bool = false
    /// Optional step-by-step diagnostic callback for on-screen debug banners.
    /// Called on a background thread; dispatch to main if you need to update UI.
    public var diagnosticCallback: ((String) -> Void)? = nil

    /// **Experimental.** When `true`, the engine loads m15 (YOLOv8n-pose, nc=6)
    /// instead of m1 + m9.  Maps to `MergenScannerConfig.useUnifiedDetector`.
    /// Default: **false**.
    public var useUnifiedDetector: Bool = false

    public init() {}

    mutating func validate() {
        retryBudget = min(max(retryBudget, 2), 30)
    }
}

// ── Mergen facade ─────────────────────────────────────────────────────────────

/**
 Mergen — lightweight façade for two-sided Kyrgyz ID verification.

 Wraps the `MergenEngine` lifecycle, two-sided gallery processing, and JSON
 parsing so the caller needs **zero JSON parsing and zero engine lifecycle management**.

 ### Thread safety
 `verify` is an `async` function safe to call from any async context.
 All heavy work runs on a detached `Task` (non-main actor).

 ### Engine lifecycle
 `verify` reuses a shared `ScannerEngineController` via `MergenEnginePool` — models
 are loaded **once** per license and kept warm across calls.  Call `Mergen.warmUp(license:)`
 at app launch (e.g. via `MergenModelPreloader`) to eliminate the first-call latency.

 ### Errors
 - `MergenError.licenseEmpty`     — license string is empty.
 - `MergenError.engineInitFailed` — native engine init returned handle 0.
 */
public enum Mergen {

    private static let tag = "Mergen"

    /**
     Warms the shared engine for `license` in the background so the first
     scan or `verify` call does not block on cold model loading (~2–5 s on device).

     Must be called on the `@MainActor` (e.g. from `App.init` / `.onAppear` on
     the root view).  Safe to call multiple times with the same arguments —
     subsequent calls are no-ops on the pool.

     **Pool key alignment — pass the same `leanFields` you will use at scan/verify
     time, otherwise `warmUp` pre-warms a different pool slot and a second engine
     is created on first use (defeating the jetsam fix):**

     - For `MergenScannerViewController` / `MergenScannerView` with default config
       (`leanIdentityFields = false`): call `warmUp(license:)` — default `false`
       matches the scanner's default and the pool hits.
     - For `Mergen.verify` with default `MergenConfig` (`leanFields = true`): call
       `warmUp(license: lic, leanFields: true)` so the pre-warmed slot is reused.
     - When both flows run in the same session, call `warmUp` twice with both values
       (the pool keeps only ONE slot, so the second call evicts the first; prefer
       the flow that runs first, or pre-warm only the dominant flow).

     ```swift
     // App.init — dominant flow is live-scan (MergenScannerViewController default):
     Mergen.warmUp(license: licenseJson)              // leanFields = false

     // App.init — dominant flow is gallery verify (Mergen.verify default):
     Mergen.warmUp(license: licenseJson, leanFields: true)
     ```
     */
    @MainActor
    public static func warmUp(license: String, leanFields: Bool = false, useUnifiedDetector: Bool = false) {
        guard !license.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let ctrl = MergenEnginePool.controller(for: license, leanFields: leanFields, useUnifiedDetector: useUnifiedDetector)
        // Warm the ENGINE only — must NOT start the camera. Using prepare() here powered on
        // the camera at app launch (and it stayed on through the gallery flow, which never
        // needs the camera). prepareEngineOnly() loads the models without the AVCaptureSession;
        // the camera is started solely by the live-scan UI's own prepare().
        ctrl.prepareEngineOnly()
    }

    /**
     Pre-warms the engine **and** proactively loads m12/m13 (DocsaidLab MRZ) models.

     Extends `warmUp()`: after Wave-1/2 models are ready, triggers `beginNextSide()` to
     start m12+m13 async loading at app launch — before the first scan needs them.

     **Why this matters:** m12+m13 take ~7 s to initialise on device. Without preload they
     cold-start during the back-side camera scan (inside the CAPTURED state handler), adding
     ~7 s to the back scan and ~5 s to `verify()`.  With `preload()`, model loading runs in
     the background while the user scans the front side, eliminating most of the overlap wait.

     Additionally, after a successful front scan `teardownCamera()` dispatches a proactive
     `native_reset() + beginNextSide()` that runs during the user's flip-card navigation.
     `prepare()` for the back scan awaits this task instead of blocking at camera-start time,
     further reducing the perceived delay.

     **Pool key alignment** (same rule as `warmUp`): pass the same `leanFields` /
     `useUnifiedDetector` values you will use at scan/verify time.

     Must be called on `@MainActor`. Safe to call multiple times — subsequent calls with
     the same arguments are no-ops (`prepareEngineOnly` is idempotent; `scheduleMrzPrewarm`
     triggers `beginNextSide` which is a soft-reset no-op on a warm IDLE engine).

     ```swift
     // ScanViewModel.init() or App.init():
     Mergen.preload(licenseKey: licenseJson, leanFields: true, useUnifiedDetector: true)
     ```
     */
    @MainActor
    public static func preload(licenseKey: String, leanFields: Bool = true, useUnifiedDetector: Bool = false) {
        guard !licenseKey.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let ctrl = MergenEnginePool.controller(for: licenseKey, leanFields: leanFields, useUnifiedDetector: useUnifiedDetector)
        ctrl.prepareEngineOnly()
        ctrl.scheduleMrzPrewarm()
    }

    /**
     Verify a Kyrgyz ID document by scanning both sides.

     Runs the full lean-identity pipeline:
     1. Creates an engine with `leanIdentityFields = true` (default via `MergenConfig`).
     2. Feeds `front` + `back` through the two-sided gallery processing pipeline.
     3. Parses `identity_v2` + top-level `status` from the final JSON.
     4. Returns a typed `VerifyResult` — no JSON parsing needed by the caller.

     - Parameters:
       - front:     Photo of the FRONT side of the ID card (perspective-uncorrected).
       - back:      Photo of the BACK side (with MRZ).
       - license:   License JSON string.
       - configure: Optional closure to override `MergenConfig` defaults.
     - Returns: Typed `VerifyResult` with verdict and identity fields.
     - Throws:
       - `MergenError.licenseEmpty`     when `license` is blank.
       - `MergenError.engineInitFailed` when the native engine returns handle 0.
     */
    public static func verify(
        front:     UIImage,
        back:      UIImage,
        license:   String,
        configure: ((inout MergenConfig) -> Void)? = nil
    ) async throws -> VerifyResult {
        guard !license.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MergenError.licenseEmpty
        }

        var cfg = MergenConfig()
        configure?(&cfg)
        cfg.validate()

        if cfg.debugLogging {
            mergenLog.debug("verify start — lean=\(cfg.leanFields, privacy: .public) strict=\(cfg.strictSameDocument, privacy: .public) budget=\(cfg.retryBudget, privacy: .public)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            // ScannerEngineController is @MainActor — obtain / create on main thread.
            // MergenEnginePool.controller(for:) reuses an existing warm controller when
            // the license is unchanged, so models are loaded only once per app session.
            Task { @MainActor in
                let controller = MergenEnginePool.controller(for: license, leanFields: cfg.leanFields, useUnifiedDetector: cfg.useUnifiedDetector)
                let budget   = cfg.retryBudget
                let strict   = cfg.strictSameDocument
                let debug    = cfg.debugLogging
                let tag      = self.tag
                let diagCb   = cfg.diagnosticCallback

                controller.processGalleryTwoSided(
                    front:            front,
                    back:             back,
                    repeatCount:      budget,
                    diagnosticCallback: diagCb
                ) { [controller] scanResult in    // strong-capture controller so it lives until completion fires
                    _ = controller                 // explicit use to silence unused-capture warning
                    let finalJson = scanResult.finalJson
                    // PII GUARD: finalJson carries name/doc#/ПИН/MRZ. Size only unless
                    // `piiTrace` (internal/PiiTrace.swift) is flipped on for local debugging.
                    if debug {
                        if piiTrace {
                            mergenLog.debug("finalJson=\(finalJson?.prefix(500) ?? "nil", privacy: .public)")
                        } else {
                            mergenLog.debug("finalJson \(finalJson?.utf8.count ?? 0, privacy: .public) bytes")
                        }
                    }

                    do {
                        let result = try parseVerifyResult(
                            scanResult: scanResult,
                            finalJson:  finalJson,
                            strict:     strict
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // ── Internal: JSON → VerifyResult ─────────────────────────────

    private static func parseVerifyResult(
        scanResult: MergenIdResult,
        finalJson:  String?,
        strict:     Bool
    ) throws -> VerifyResult {
        // Empty / missing JSON — return a typed FAILED result, not an error throw.
        guard let finalJson, !finalJson.trimmingCharacters(in: .whitespaces).isEmpty,
              finalJson != "{}"
        else {
            return VerifyResult(
                status:                  .failed,
                message:                 "Не удалось получить результат сканирования",
                messageEn:               "Scan result not available",
                verifyId:                "",
                verifyPin:               "",
                docNumber:               nil,
                pin:                     nil,
                mrzDocNumber:            nil,
                mrzPin:                  nil,
                mrzFull:                 nil,
                mrzConfirmed:            false,
                sameDocument:            .unknown,
                docBadge:                .unknown,
                pinBadge:                .unknown,
                frontFieldAvailability:  nil,
                backFieldAvailability:   nil,
                ocrProdFront:            nil,
                ocrProdBack:             nil,
                frontPhoto:              scanResult.croppedImage,
                backPhoto:               scanResult.croppedImageBack
            )
        }

        // Parse identity_v2 block (mirrors Android's parseFusedIdentity).
        let identity = parseFusedIdentity(finalJson)

        // Top-level keys emitted by C++ T1 engine logic.
        guard let data = finalJson.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return VerifyResult(
                status:                  .failed,
                message:                 "Ошибка разбора результата",
                messageEn:               "Failed to parse scan result",
                verifyId:                "",
                verifyPin:               "",
                docNumber:               nil,
                pin:                     nil,
                mrzDocNumber:            nil,
                mrzPin:                  nil,
                mrzFull:                 nil,
                mrzConfirmed:            false,
                sameDocument:            .unknown,
                docBadge:                .unknown,
                pinBadge:                .unknown,
                frontFieldAvailability:  nil,
                backFieldAvailability:   nil,
                ocrProdFront:            nil,
                ocrProdBack:             nil,
                frontPhoto:              scanResult.croppedImage,
                backPhoto:               scanResult.croppedImageBack
            )
        }

        let statusStr    = root["status"]        as? String ?? "UNKNOWN"
        let messageRu    = (root["message_ru"]   as? String)?.nilIfEmpty
        let messageEn    = (root["message_en"]   as? String)?.nilIfEmpty
        let verifyId     = root["verify_id"]     as? String ?? ""
        let verifyPin    = root["verify_pin"]    as? String ?? ""
        // mrz_confirmed: engine emits a top-level bool; default false (safe fallback).
        let mrzConfirmed = root["mrz_confirmed"] as? Bool ?? false

        var status = VerifyStatus.fromString(statusStr)

        // strictSameDocument: downgrade VERIFIED / VERIFIED_VISUAL to FAILED only on a
        // true MISMATCH or when the verdict is unresolvable (UNKNOWN / SINGLE_SIDE).
        // SAME_WITH_WARNING is NOT a genuine discrepancy and is never downgraded.
        if strict, status.isSuccess {
            let verdict = identity?.sameDocument.verdict ?? .unknown
            if verdict == .mismatch || verdict == .unknown || verdict == .singleSide {
                status = .failed
            }
        }

        let lean = identity?.leanVerifyResult

        // Priority: verify_id/verify_pin (C++ MRZ-as-truth, best answer)
        //        → identity_v2 headline snapshots
        //        → lean ocrProd as last resort
        let docNumber = verifyId.nilIfEmpty
            ?? identity?.docNumber?.value.validDocOrNil
            ?? lean?.docNumberFront?.validDocOrNil
            ?? lean?.docNumberBack?.validDocOrNil

        let pin = verifyPin.nilIfEmpty
            ?? identity?.pin?.value.validPinOrNil
            ?? lean?.pinFront?.validPinOrNil
            ?? lean?.pinBack?.validPinOrNil

        // Per-side field availability from parsed sides[].
        let frontSide = identity?.sides.first { $0.side == .front }
        let backSide  = identity?.sides.first { $0.side == .back  }

        // mrz_match — per-field visual ↔ MRZ comparison (mirrors Android's mrzMatch list).
        // Shape: { "doc_number": { "visual_value", "mrz_value", "match", "mrz_checksum_ok" }, … }
        let mrzMatchList: [MrzMatch] = parseMrzMatchBlock(root)

        // Message is suppressed for any successful outcome.
        let suppressMessage = status.isSuccess

        return VerifyResult(
            status:                  status,
            message:                 suppressMessage ? nil : messageRu,
            messageEn:               suppressMessage ? nil : messageEn,
            verifyId:                verifyId,
            verifyPin:               verifyPin,
            docNumber:               docNumber,
            pin:                     pin,
            mrzDocNumber:            lean?.mrzDocNumber,
            mrzPin:                  lean?.mrzPin,
            mrzFull:                 lean?.mrzFull,
            mrzConfirmed:            mrzConfirmed,
            sameDocument:            identity?.sameDocument.verdict ?? .unknown,
            docBadge:                identity?.docNumber?.badge      ?? .unknown,
            pinBadge:                identity?.pin?.badge            ?? .unknown,
            frontFieldAvailability:  frontSide?.fieldAvailability,
            backFieldAvailability:   backSide?.fieldAvailability,
            ocrProdFront:            identity?.ocrProdFrontJson,
            ocrProdBack:             identity?.ocrProdBackJson,
            frontPhoto:              scanResult.croppedImage,
            backPhoto:               scanResult.croppedImageBack,
            mrzMatch:                mrzMatchList
        )
    }
}

// ── parseMrzMatchBlock — shared parser for the top-level "mrz_match" JSON object ──
//
// Parses the `mrz_match` dict emitted by C++ IdentitySession::buildVerifyJson.
// Shape: { "<field_key>": { "visual_value": "...", "mrz_value": "...",
//                           "match": "AGREEMENT"|"MISMATCH"|"MRZ_ONLY"|"VISUAL_ONLY",
//                           "mrz_checksum_ok": true/false } }
// Returns an empty array when the key is absent (forward-compat with older engines).
//
// Internal — callers: parseVerifyResult (Mergen.swift) and
//                      parseVerifyResultFromCompare (MergenScan.swift).
internal func parseMrzMatchBlock(_ root: [String: Any]) -> [MrzMatch] {
    guard let mrzMatchObj = root["mrz_match"] as? [String: Any] else { return [] }
    return mrzMatchObj.keys.sorted().compactMap { fieldKey -> MrzMatch? in
        guard let entry = mrzMatchObj[fieldKey] as? [String: Any] else { return nil }
        // "match" is a MrzMatchKind string from the C++ engine; accept a plain
        // boolean too for older engine builds.
        let match: MatchKind
        switch entry["match"] {
        case let b as Bool:
            match = MatchKind.from(optionalBool: b)
        case let s as String:
            switch s.uppercased() {
            case "AGREEMENT", "TRUE":       match = .matches
            case "MISMATCH", "FALSE":       match = .mismatch
            case "MRZ_ONLY", "VISUAL_ONLY": match = .unavailable
            default:                        match = .unknown
            }
        default:
            match = .unavailable
        }
        return MrzMatch(
            fieldName:     fieldKey,
            visualValue:   entry["visual_value"]    as? String ?? "",
            mrzValue:      entry["mrz_value"]       as? String ?? "",
            match:         match,
            mrzChecksumOk: entry["mrz_checksum_ok"] as? Bool   ?? false
        )
    }
}

// ── MergenError ───────────────────────────────────────────────────────────────

// ── Mergen engine pool (internal) ────────────────────────────────────────────

/// Single-entry cache of a `ScannerEngineController` keyed by license string.
///
/// **Why this matters:**
/// `Mergen.verify` previously created a fresh `ScannerEngineController` — and
/// therefore a fresh `MergenEngine` — on every call.  Model loading takes
/// 2–5 s on device.  `MergenModelPreloader` warmed a *different* handle, so the
/// warm-up had no effect on the verify path.
///
/// Now `Mergen.verify` calls `MergenEnginePool.controller(for:)`, which returns the
/// same `ScannerEngineController` instance across calls with the same license.
/// `processGalleryTwoSided` already contains the engine-reuse guard
/// (`if let existing = self.engine { existing.reset(); eng = existing }`), so
/// models are loaded **once** and reused across all subsequent verify calls.
///
/// Between verify calls the engine state is reset via `beginNextSide()` / `reset()`
/// inside `processGalleryTwoSided` — not via a full re-init.
@MainActor
internal enum MergenEnginePool {
    private static var cachedLicense:           String?
    private static var cachedLeanFields:        Bool?
    private static var cachedUnifiedDetector:   Bool?
    private static var cachedController:        ScannerEngineController?

    /// Returns a shared `ScannerEngineController` for `(license, leanFields, useUnifiedDetector)`.
    ///
    /// A new controller is created only when any key value changes (rare in production).
    /// Keying on all three values prevents mode cross-contamination between pool slots.
    static func controller(for license: String, leanFields: Bool, useUnifiedDetector: Bool = false) -> ScannerEngineController {
        // MEM-TRIM: the pool is about to hold a warm engine — make sure the
        // memory-pressure monitor is watching (idempotent; defined in MergenScan.swift).
        MergenMemoryPressureMonitor.installIfNeeded()
        if let existing = cachedController,
           cachedLicense == license,
           cachedLeanFields == leanFields,
           cachedUnifiedDetector == useUnifiedDetector {
            return existing
        }
        let configuration = MergenScannerConfig {
            $0.licenseKey           = license
            $0.leanIdentityFields   = leanFields
            $0.useUnifiedDetector   = useUnifiedDetector
            $0.stabilityFrames      = 3
        }
        let ctrl = ScannerEngineController(configuration: configuration, style: ScannerStyle())
        cachedLicense          = license
        cachedLeanFields       = leanFields
        cachedUnifiedDetector  = useUnifiedDetector
        cachedController       = ctrl
        return ctrl
    }

    /// MEM-TRIM: drop the pooled warm controller (and thus its `MergenEngine` —
    /// `deinit` → `native_destroy`) in response to a memory-pressure signal.
    ///
    /// Returns `true` when a controller was actually evicted, `false` when there
    /// was nothing to release or a live camera scan is currently using the pooled
    /// controller (`captureSession != nil`). In the latter case eviction would
    /// free NOTHING — the scanner view retains the controller — and would only
    /// cost the next warm start, so we keep the pool entry.
    ///
    /// Deliberately NO automatic re-warm afterwards: re-preloading would
    /// re-inflate the exact footprint the OS just asked us to shed. The pool
    /// stays cold until the next real use (`controller(for:)` recreates on
    /// demand — cold start ~2–6 s on weak devices, a conscious trade-off).
    static func drainForMemoryPressure() -> Bool {
        guard let ctrl = cachedController else { return false }
        guard ctrl.captureSession == nil else { return false }
        cachedController      = nil
        cachedLicense         = nil
        cachedLeanFields      = nil
        cachedUnifiedDetector = nil
        return true
    }
}

/// Errors thrown by `Mergen.verify` and delivered via `ScannerEvent.error` / `onError`.
public enum MergenError: Error, LocalizedError {
    case licenseEmpty
    case engineInitFailed
    /// Camera permission is not granted and `handlePermissionsInternally` is `false` —
    /// the host app must request access before starting the scanner (Phase A7).
    /// Mirrors Android `CameraPermissionDeniedException`.
    case cameraPermissionDenied

    public var errorDescription: String? {
        switch self {
        case .licenseEmpty:     return "Mergen: license JSON is empty — engine will not initialise."
        case .engineInitFailed: return "Mergen: native engine initialisation failed (models corrupt or assets missing)."
        case .cameraPermissionDenied:
            return "Mergen: camera permission not granted. The host app must request camera access before starting the scanner (handlePermissionsInternally = false)."
        }
    }
}

// ── Private helpers ───────────────────────────────────────────────────────────

/// KG document number grammar: 2 uppercase ASCII letters + 7 decimal digits = 9 chars.
/// Mirrors ^[A-Z]{2}\\d{7}$ used as mrzDocGrammarOk_verify in the C++ abstain-gate.
private func isValidKgDocNumber(_ s: String) -> Bool {
    guard s.count == 9 else { return false }
    let ch = Array(s)
    guard ch[0].isUppercase, ch[0].isLetter,
          ch[1].isUppercase, ch[1].isLetter else { return false }
    return ch[2...].allSatisfy { $0.isNumber }
}

/// Date-aware KG PIN validation — mirrors isPINValid() in field_validator.cpp §1148.
/// Returns true for 14-digit strings with a plausible embedded DDMMYYYY date.
private func isValidKgPin(_ s: String) -> Bool {
    guard s.count == 14 else { return false }
    let digits = s.compactMap { $0.wholeNumberValue }
    guard digits.count == 14 else { return false }   // all chars are decimal digits
    func dmy(_ off: Int) -> Bool {
        let dd = digits[off] * 10 + digits[off + 1]
        let mm = digits[off + 2] * 10 + digits[off + 3]
        let yy = digits[off + 4] * 1000 + digits[off + 5] * 100
               + digits[off + 6] * 10  + digits[off + 7]
        return (1...31).contains(dd) && (1...12).contains(mm) && (1900...2100).contains(yy)
    }
    let official = (digits[0] == 1 || digits[0] == 2 || digits[0] == 4) && dmy(1)
    let legacy   = dmy(0)
    return official || legacy
}

private extension String {
    /// Returns `nil` when the string is empty; otherwise returns `self`.
    var nilIfEmpty: String? { isEmpty ? nil : self }
    /// Returns `self` when it passes KG doc-number grammar; otherwise `nil`.
    var validDocOrNil: String? { isValidKgDocNumber(self) ? self : nil }
    /// Returns `self` when it passes date-aware KG PIN validation; otherwise `nil`.
    var validPinOrNil: String? { isValidKgPin(self) ? self : nil }
}
