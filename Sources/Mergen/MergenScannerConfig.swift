import Foundation
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// SideExpectation — which physical side the scanner should accept.
// ─────────────────────────────────────────────────────────────────────────────

/// Declarative side expectation used with `MergenScannerConfig.expectedSide`.
///
/// When `MergenScannerConfig.enforceSideMatch` is `true` and `expectedSide` is
/// not `.any`, the scanner silently rejects captures whose `CardVersion` does not
/// match the requested side and continues scanning instead of emitting `onFinished`.
///
/// Mirrors Android `SideExpectation`.
public enum SideExpectation {
    /// Accept any card side (default — pre-existing behaviour, no gate applied).
    case any
    /// Only accept front-side captures (Front2008 / Front2017 / Front2025).
    case front
    /// Only accept back-side captures (Back2008 / Back2017 / Back2025).
    case back
}

/// Camera analysis-resolution preset (Phase A / v2.1.0 — §5 of the SDK spec).
///
/// Mirrors the Android `CameraQuality` enum. Platform mapping:
///
/// | Preset      | iOS (sessionPreset) | Android (ResolutionSelector) |
/// |-------------|---------------------|------------------------------|
/// | `.high`     | `.hd1920x1080`      | 1280×960                     |
/// | `.balanced` | `.hd1280x720`       | 1280×720                     |
/// | `.fast`     | `.vga640x480`       | 640×480                      |
///
/// The per-platform **default preserves the pre-v2.1 behaviour exactly**:
/// iOS defaults to `.balanced` (`.hd1280x720` — unchanged), Android defaults
/// to `HIGH` (1280×960 — unchanged).
///
/// ⚠️ `.fast` (and `.high`, which raises the per-frame pixel cost) changes the
/// YOLO/OCR input — validate detection accuracy on target devices before shipping.
public enum CameraQuality {
    /// Highest input resolution. iOS: 1920×1080.
    case high
    /// Good balance of quality and throughput. iOS: 1280×720 (current default).
    case balanced
    /// Lowest latency / battery draw. iOS: 640×480.
    case fast
}

// ─────────────────────────────────────────────────────────────────────────────
// ScanSpeed — convenience preset for `MergenScannerConfig.stabilityFrames`.
// ─────────────────────────────────────────────────────────────────────────────

/// Convenience preset that maps to `MergenScannerConfig.stabilityFrames`.
///
/// Maps to the C++ engine config key `"stability_frames"` (default: 5).
///
/// | Case      | stabilityFrames | Character           |
/// |-----------|-----------------|---------------------|
/// | `.fast`   | 2               | Instant, fewer checks |
/// | `.normal` | 3               | Balanced (recommended for most flows) |
/// | `.thorough` | 5             | Maximum stability (default engine value) |
///
/// Usage:
/// ```swift
/// MergenScannerConfig { $0.scanSpeed = .normal }
/// ```
public enum ScanSpeed {
    /// 2 stability frames — fastest capture, minimum motion checks.
    case fast
    /// 3 stability frames — balanced speed and reliability.
    case normal
    /// 5 stability frames — maximum stability; same as the engine default.
    case thorough

    /// The corresponding `stabilityFrames` value.
    public var stabilityFrames: Int {
        switch self {
        case .fast:     return 2
        case .normal:   return 3
        case .thorough: return 5
        }
    }
}

/// Engine-level configuration for the ID Card Scanner.
///
/// Visual styling is intentionally separated into `ScannerStyle`.
/// This struct contains only detection parameters and license info.
///
/// ```swift
/// let config = MergenScannerConfig {
///     $0.detectionThreshold = 0.6
///     $0.stabilityFrames    = 7
/// }
/// ```
public struct MergenScannerConfig {

    /// Minimum YOLO confidence to consider a card detected [0..1].
    public var detectionThreshold: Float = 0.5
    /// Minimum quality score to trigger capture [0..1].
    public var qualityThreshold: Float = 0.7
    /// Consecutive stable frames required before capture.
    ///
    /// Maps directly to the C++ engine config key `"stability_frames"`. Default: `5`.
    /// Use `scanSpeed` for a convenience preset instead of setting this directly.
    public var stabilityFrames: Int = 5

    /// Convenience accessor that sets `stabilityFrames` via a `ScanSpeed` preset.
    ///
    /// ```swift
    /// MergenScannerConfig { $0.scanSpeed = .normal }
    /// ```
    ///
    /// Reading back returns the preset whose `stabilityFrames` matches the current
    /// value, or `nil` when the value was set to a non-preset number directly.
    public var scanSpeed: ScanSpeed? {
        get {
            switch stabilityFrames {
            case ScanSpeed.fast.stabilityFrames:     return .fast
            case ScanSpeed.normal.stabilityFrames:   return .normal
            case ScanSpeed.thorough.stabilityFrames: return .thorough
            default:                                  return nil
            }
        }
        set {
            if let preset = newValue {
                stabilityFrames = preset.stabilityFrames
            }
        }
    }
    /// Automatically finalise when stability threshold is met.
    public var autoCapture: Bool = true
    /// License JSON. When `nil` the SDK looks for `license.json` in the main bundle.
    public var licenseKey: String? = nil
    /// Read only doc_number, personal_number (PIN), and MRZ — skip names, dates, issued_by etc.
    /// Dramatically reduces latency and noise. Use for lean identity-verify flows.
    /// Maps to C++ engine config key `"lean_identity_fields"`.
    /// Default: `false` (full OCR).
    public var leanIdentityFields: Bool = false

    /// When `true` AND the device has < 3 GB RAM, the camera session preset drops
    /// to `.vga640x480` (640×480) instead of the configured `cameraQuality` preset.
    ///
    /// **Default: `false` — OFF.** Must NOT be enabled in production without prior
    /// on-device YOLO detection-accuracy validation at 640×480 on the target weak
    /// device class (A9/A10). Set to `true` only after confirming detection rate is
    /// acceptable at the lower resolution.
    ///
    /// Strong devices (≥ 3 GB) always use the configured `cameraQuality` preset
    /// regardless of this flag.
    ///
    /// Prefer `cameraQuality = .fast` for an unconditional low-resolution session;
    /// this flag remains as the tier-conditional variant.
    public var lowResOnWeakDevice: Bool = false

    /// Enables the SDK's point-of-interest autofocus triggers (card-center AF and
    /// weak-field AF during smart re-scan) plus the continuous-AF configuration
    /// applied at session setup.
    ///
    /// `false` disables all SDK-initiated focus/metering configuration — the camera
    /// falls back to the platform's default AF behaviour. Use when the host app
    /// manages focus itself or on devices where repeated AF hunting hurts UX.
    ///
    /// Mirrors Android `MergenScannerConfig.autofocusEnabled`.
    /// Default: `true` (pre-v2.1 behaviour, backward-compatible).
    public var autofocusEnabled: Bool = true

    /// Camera analysis-resolution preset. See `CameraQuality` for the exact mapping.
    /// Default: `.high` = `.hd1920x1080` — maximises OCR sharpness and eliminates
    /// digit-stroke softness (8/9/0 substitutions) on upscaled crops.
    /// The `lowResOnWeakDevice` override still applies on < 3 GB devices.
    public var cameraQuality: CameraQuality = .high

    /// Still-photo capture at the capture moment (v2.1 still-capture flow).
    ///
    /// When `true` (default), the moment the engine's first capture attempt on a
    /// video frame fails to converge (smart-rescan gate blocks the finish), the
    /// SDK snaps ONE real photo via `AVCapturePhotoOutput` — full-quality still
    /// with a proper exposure and no motion blur (gallery-grade input) — and runs
    /// the OCR/MRZ pass on it INSTEAD of chewing further motion-blurred video
    /// frames.  The camera preview keeps running while the photo is processed.
    ///
    /// Net effect: sharper reads AND a faster finish on hard cards (one good
    /// frame replaces the multi-frame rescan loop, ~200–600 ms photo latency vs
    /// several ~300 ms video OCR passes).  The instant-capture arms (Arm C MRZ
    /// checksum / Arm C-front) still short-circuit BEFORE any photo is taken —
    /// easy cards never pay the photo cost.
    ///
    /// Set `false` to disable on devices where `AVCapturePhotoOutput` misbehaves;
    /// the SDK then falls back to the pre-v2.1 video-only rescan loop.
    ///
    /// Mirrors Android `MergenScannerConfig.useStillCapture`.
    public var useStillCapture: Bool = true

    /// When `true`, the C++ engine classifies the card version (m9 classifier) on
    /// every DETECTING frame — not just at capture time.  This makes the version
    /// known in `FrameResult.cardVersion` while the state is still `.detecting`,
    /// which allows `ScannerEngineController` to react to a wrong-side card
    /// IMMEDIATELY (instant color/message change) rather than waiting for a full
    /// capture cycle (~seconds).
    ///
    /// Enable together with `enforceSideMatch = true` for best UX in two-sided
    /// verify flows: the bbox turns red the moment the wrong side appears and
    /// turns green/normal the moment the correct side appears — no capture required.
    ///
    /// Maps to C++ engine config key `"live_version_probe"`.
    /// **Default: `false` — off.  No existing client is affected.**
    public var liveVersionProbe: Bool = false

    /// Softmax-confidence threshold for the live version probe.
    ///
    /// When the m9/m15 classifier's winning-class confidence is below this value,
    /// the probe reports the version as `.unknown` instead of a concrete side — this
    /// suppresses false "нужна обратная сторона" messages on uncertain frames.
    ///
    /// Valid range: [0.20, 1.0]. **Default: `0.60`** — matches the C++ engine default
    /// (`live_version_probe_conf` in `parseConfig`). Lower values accept more uncertain
    /// classifications (fewer "wrong side" misses but more false positives); higher
    /// values require stronger classifier evidence before flagging the wrong side.
    ///
    /// Maps to C++ engine config key `"live_version_probe_conf"`.
    /// Only meaningful when `liveVersionProbe` is `true`.
    public var liveVersionProbeConf: Double = 0.60

    // ── Side / generation gate (optional, default off) ───────
    //
    // ALL three fields default to their "off" values — no existing client is
    // affected.  The gate fires only when `enforceSideMatch == true`.
    //
    // Design rationale: kept in MergenScannerConfig (not a separate struct)
    // because it is a per-scan engine-level constraint, not a visual style.
    // The same gate is supported on Android via MergenScannerConfig fields.

    /// When `true`, the scanner enforces that a captured card's physical side and
    /// (optionally) generation match `expectedSide` / `expectedGeneration`.
    ///
    /// On mismatch the scanner does NOT emit `onFinished` / `onResult` — it resets
    /// to `detecting` state, paints the bbox in `style.colorFailure` (red) for
    /// ~1.5 s, and continues scanning.  This is the same "same-side re-scan"
    /// pattern used internally by the two-sided verify flow.
    ///
    /// **Default: `false` — gate is fully disabled.  No existing client is affected.**
    public var enforceSideMatch: Bool = false

    /// Which physical side to accept.  Only meaningful when `enforceSideMatch` is `true`.
    ///
    /// - `.any` (default): accept any side — equivalent to gate being off.
    /// - `.front`: accept Front2008 / Front2017 / Front2025 only.
    /// - `.back`:  accept Back2008  / Back2017  / Back2025  only.
    public var expectedSide: SideExpectation = .any

    /// If non-nil, additionally require that the card generation (year component)
    /// matches this string.  Accepted values: `"2008"`, `"2017"`, `"2025"`.
    ///
    /// Only meaningful when `enforceSideMatch` is `true`.  When `nil` (default)
    /// any generation is accepted.
    ///
    /// Example: after scanning the front and detecting `"Front2017"`, pass
    /// `expectedGeneration = "2017"` for the back scan to enforce version consistency.
    public var expectedGeneration: String? = nil

    /// Show the scan-line animation inside the bbox while the engine is in the
    /// ANALYZING transition (card appeared, version probe pending).
    ///
    /// Visible effect: a bouncing horizontal gradient line inside the card rectangle
    /// for ≤400 ms after the card first appears.  Rendered by `ScannerOverlayRenderer`.
    ///
    /// Default: `true` — ON.  Set to `false` to disable (e.g. for custom overlays that
    /// render their own analyzing state).
    ///
    /// Mirrors Android `MergenScannerConfig.showAnalysisAnimation`.
    public var showAnalysisAnimation: Bool = true

    /// Show contextual capture-tips in the hint area while the card is detected in
    /// the `detecting` state: distance hints ("Поднесите ближе" / "Отодвиньте дальше")
    /// and lighting hints ("Слишком ярко" / "Слишком темно").
    ///
    /// These tips are lower priority than side-gate messages and the ANALYZING window.
    /// They appear only when no higher-priority message is active.
    ///
    /// Default: `true` — ON.
    ///
    /// Mirrors Android `MergenScannerConfig.showCaptureTips`.
    public var showCaptureTips: Bool = true

    /// Automatically enable the flashlight (torch) when the scene is consistently too dark
    /// for reliable OCR.
    ///
    /// When `true` (default), if the engine reports `isDark` on ≥ 8 consecutive YOLO frames
    /// while a card is visible, the SDK turns on the rear flashlight via `AVCaptureDevice`.
    /// The torch turns off automatically when the card is lost for > 30 consecutive frames,
    /// when scanning completes, or when the scanner is dismissed.
    ///
    /// Calling `setFlashlightEnabled(_:)` manually always takes precedence — after an explicit
    /// call the SDK will not fight the user's chosen torch state for the current scan session.
    ///
    /// Mirrors Android `MergenScannerConfig.autoTorch`.
    /// Default: `true` — ON.
    public var autoTorch: Bool = true

    /// Region of interest for detection, normalised to the frame (0...1 in both axes).
    /// `nil` (default) = full frame.
    ///
    /// **v2.1.0: reserved — currently a no-op.** The field exists so integrators can
    /// adopt the API early; detection masking ships with the engine-side plumbing.
    ///
    /// TODO(Phase A4, HIGH): plumb `scan_roi` into the engine config JSON
    /// (`toEngineJson()`), mask detections in C++ (`mergen_engine.cpp`), and apply the
    /// ROI offset in `internal/CoordinateTransformer` on BOTH platforms. Deferred to
    /// avoid touching `src/` in v2.1.0. Mirrors Android `MergenScannerConfig.scanRoi`.
    public var scanRoi: CGRect? = nil

    /// `true` (default): the SDK requests camera access itself where it historically
    /// did (`MergenScannerViewController`) — pre-v2.1 behaviour.
    ///
    /// `false`: the SDK NEVER requests permission. It only checks the authorization
    /// state and, when not authorized, emits
    /// `ScannerEvent.error(MergenError.cameraPermissionDenied)` / `onError` instead
    /// of starting the camera. The host app owns the permission UX (target contract
    /// for SDK v3.0).
    ///
    /// Mirrors Android `MergenScannerConfig.handlePermissionsInternally`.
    public var handlePermissionsInternally: Bool = true

    /// **Experimental.** When `true`, the engine loads m15 (YOLOv8n-pose, nc=6,
    /// INT8-QDQ) instead of m1 + m9.  m15 simultaneously detects the card bounding
    /// box and classifies side/version in a single YOLO forward pass, eliminating
    /// the separate m9 CNN classification call and saving ~8 ms per frame on A14+.
    ///
    /// When m15 is absent on-disk the engine silently falls back to m1 (safe).
    ///
    /// Maps to C++ engine config key `"use_unified_detector"`.
    /// **Default: `false` — off.  No existing client is affected.**
    public var useUnifiedDetector: Bool = false

    /// Maximum number of intra-op parallelism threads for ONNX Runtime.
    ///
    /// When non-nil, passed to the C++ engine as JSON key `"ort_intra_op_cap"`.
    /// The engine calls `SessionOptions::SetIntraOpNumThreads(cap)` for each
    /// ONNX session, capping how many CPU cores ORT uses per operator. ORT
    /// defaults to all available physical cores — on a 6-core device that may
    /// saturate the CPU and starve the main/render thread, causing dropped frames.
    ///
    /// Recommended value: **4** for demo / production apps that also run UI at
    /// 60 fps. This keeps 2 efficiency cores free for Metal / CADisplayLink / SwiftUI.
    ///
    /// `nil` (default) lets ORT choose automatically — matches the pre-v2.1
    /// behaviour, so no existing client is affected.
    ///
    /// Maps to C++ engine config key `"ort_intra_op_cap"`.
    public var ortIntraOpCap: Int? = nil

    // ── Initialisers ──────────────────────────────────────────

    public init() {}

    /// DSL initialiser.
    public init(_ configure: (inout MergenScannerConfig) -> Void) {
        configure(&self)
    }

    // ── Convenience presets ───────────────────────────────────

    /// Strict settings for production high-quality captures.
    public static var strict: MergenScannerConfig {
        MergenScannerConfig {
            $0.detectionThreshold = 0.65
            $0.qualityThreshold   = 0.80
            $0.stabilityFrames    = 8
        }
    }

    /// Relaxed settings for low-end devices or poor lighting.
    public static var relaxed: MergenScannerConfig {
        MergenScannerConfig {
            $0.detectionThreshold = 0.40
            $0.qualityThreshold   = 0.55
            $0.stabilityFrames    = 3
        }
    }

    /// Serialise to JSON expected by the C++ engine.
    ///
    /// Injects `app_id_runtime` (Bundle.main.bundleIdentifier) so the C++ license
    /// validator can perform the A3 app-id binding check without any JNI / C-bridge
    /// signature change.  The field is absent when bundleIdentifier is nil (e.g. in
    /// unit-test hosts that have no bundle), which causes C++ to skip the check —
    /// safe and backward-compatible.
    func toEngineJson() -> String {
        // TODO(Phase A4): emit "scan_roi" here once the C++ engine supports detection
        // masking. Intentionally NOT emitted in v2.1.0 — the field is a reserved no-op.
        // Escape the bundle identifier for JSON safety (bundle ids are restricted to
        // [A-Za-z0-9.-] by Apple convention, but we escape regardless for defence-in-depth).
        let bundleIdJson: String
        if let bid = Bundle.main.bundleIdentifier {
            // Minimal JSON-string escaping: replace backslash then double-quote.
            let escaped = bid.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
            bundleIdJson = "\"\(escaped)\""
        } else {
            bundleIdJson = "null"
        }
        // Capture side-gate: convert Swift SideExpectation → int (0=Any, 1=Front, 2=Back).
        // Sent to C++ only when enforceSideMatch=true so parseConfig can install the gate.
        let expectedSideInt: Int
        switch expectedSide {
        case .front: expectedSideInt = 1
        case .back:  expectedSideInt = 2
        default:     expectedSideInt = 0
        }
        // Build JSON incrementally so optional fields (e.g. ortIntraOpCap) can be
        // appended without breaking the closing brace syntax.
        var json = """
        {
            "detection_threshold": \(detectionThreshold),
            "quality_threshold": \(qualityThreshold),
            "stability_frames": \(stabilityFrames),
            "lean_identity_fields": \(leanIdentityFields ? "true" : "false"),
            "live_version_probe": \(liveVersionProbe ? "true" : "false"),
            "live_version_probe_conf": \(liveVersionProbeConf),
            "use_unified_detector": \(useUnifiedDetector ? "true" : "false"),
            "app_id_runtime": \(bundleIdJson),
            "enforce_capture_side": \(enforceSideMatch ? "true" : "false"),
            "expected_capture_side": \(expectedSideInt)
        """
        // device_tier: always emitted so the C++ engine can select the ORT thread count
        // via ort_session_config.h. Mirrors Android MergenScannerConfig.toEngineJson(detectedTier).
        // JSON key must match Android 1:1: "device_tier" (integer 0/1/2).
        let detectedTier = DeviceTierDetector.detect()
        json += ",\n    \"device_tier\": \(detectedTier)"
        // ort_intra_op_cap: explicit caller override always wins.
        // Tier-0 auto-cap (2 threads) when no override: leaves CPU headroom for
        // Metal / CADisplayLink / UI so the engine does not starve the render thread.
        if let cap = ortIntraOpCap {
            // 4 spaces matches the other keys after de-indentation of the multiline literal.
            json += ",\n    \"ort_intra_op_cap\": \(cap)"
        } else if detectedTier == 0 {
            json += ",\n    \"ort_intra_op_cap\": 2"
        }
        json += "\n}"
        return json
    }
}
