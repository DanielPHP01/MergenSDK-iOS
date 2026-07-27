import AVFoundation
import UIKit
import Combine
import SwiftUI
import os
import Accelerate

private let controllerLog = Logger(subsystem: "com.mergen", category: "controller")
/// OCR diagnostics channel. Structural output (counts, field names, value lengths) is
/// always emitted here; recognised VALUES only when `piiTrace` is flipped on for local
/// debugging — see internal/PiiTrace.swift.
private let ocrTraceControllerLog = Logger(subsystem: "com.mergen", category: "ocrtrace")

/// Thin coordinator: C++ engine + AVFoundation camera pipeline.
///
/// Responsibilities:
/// - Initialises [MergenEngine] on a dedicated 32 MB-stack thread (ONNX safety).
/// - Delegates all AVFoundation lifecycle to [CameraSession].
/// - Routes frames: YOLO every [YOLO_INTERVAL] frames via [yoloQueue],
///   OF tracking on every frame via [processingQueue].
/// - Transforms raw bbox → view-space via [CoordinateTransformer].
/// - Delegates finalization (Vision OCR ensemble + result build) to [ScanFinalizer].
/// - Publishes [frameState] (Combine @Published) to the UI layer.
///
/// [BBoxInterpolator], [CoordinateTransformer], overlay views, and all public API
/// signatures ([MergenScannerView] / [MergenScannerViewController]) are untouched.
@MainActor
internal final class ScannerEngineController: NSObject, ObservableObject {

    // ── Published state ───────────────────────────────────────

    @Published private(set) var frameState: ScannerFrameState = .empty

    // ── Callbacks ─────────────────────────────────────────────

    var onFinished: ((MergenIdResult) -> Void)?
    var onError:    ((Error) -> Void)?
    /// Optional per-event closure (Phase A5). Receives the full ScannerEvent set on @MainActor.
    var onEvent:    ((ScannerEvent) -> Void)?

    // ── Named-event stream (Phase A5) ─────────────────────────

    /// Live AsyncStream continuations — one per `makeEventStream()` consumer.
    /// @MainActor-only access (no lock needed).
    private var eventContinuations: [UUID: AsyncStream<ScannerEvent>.Continuation] = [:]

    /// Creates a NEW independent event stream. Each call returns its own stream;
    /// events are fanned out to every live stream plus the `onEvent` closure.
    /// Streams are hot: events emitted before iteration starts are dropped.
    func makeEventStream() -> AsyncStream<ScannerEvent> {
        AsyncStream { continuation in
            let id = UUID()
            Task { @MainActor [weak self] in
                self?.eventContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.eventContinuations[id] = nil
                }
            }
        }
    }

    /// Fans an event out to `onEvent` and all live AsyncStream consumers (@MainActor).
    private func emitEvent(_ event: ScannerEvent) {
        onEvent?(event)
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    /// Delivers a final result to BOTH the legacy callback and the named-event stream.
    private func deliverFinished(_ result: MergenIdResult) {
        onFinished?(result)
        emitEvent(.success(result))
    }

    /// Delivers an error to BOTH the legacy callback and the named-event stream.
    func deliverError(_ error: Error) {
        onError?(error)
        emitEvent(.error(error))
    }

    // ── Config ────────────────────────────────────────────────

    // `var` (not `let`) so that `applySideGate(config:)` can patch the three
    // side-gate fields at view-appear time on a pooled controller whose init
    // configuration did not carry them (pool creates with default enforceSideMatch=false).
    private var configuration: MergenScannerConfig
    var style: ScannerStyle

    // ── Internal ──────────────────────────────────────────────

    private var engine: MergenEngine?

    /// Serial queue on which sample buffers are delivered and on which
    /// [frameCounter] / [yoloInFlight] are accessed.
    private let processingQueue = DispatchQueue(
        label: "com.mergen.processing",
        qos: .userInteractive
    )
    /// Counts frames delivered by [CameraSession] on [processingQueue].
    /// No lock needed — single serial queue.
    private var frameCounter = 0
    /// Serial queue for YOLO inference — runs in background, never blocks the camera thread.
    private let yoloQueue = DispatchQueue(label: "com.idcard.yolo", qos: .userInitiated)
    /// Guards against queuing multiple concurrent YOLO calls.
    /// Accessed only from processingQueue — no lock needed.
    private var yoloInFlight = false

    // ── Still-photo capture state (v2.1 still-capture flow) ───

    /// True while a still photo is in flight or being OCR'd.  While set, video
    /// frames skip the full YOLO/OCR pipeline (trackOnly keeps the overlay live)
    /// so the engine works on ONE sharp still instead of N blurred video frames.
    /// Accessed only from processingQueue — no lock needed.
    private var stillInFlight = false
    /// One-shot guard: at most one still photo per scan side.
    /// @MainActor-only access (set in the frame-state Task, reset in reset()).
    /// Reset to `false` by the sharpness gate when a blurry still is rejected,
    /// allowing the next `stillCaptureWanted` trigger to fire a fresh capture.
    private var stillCaptureRequested = false

    // ── Sharpness gate (v2.2 focus quality) ──────────────────────────────────
    //
    // Before finalizing a still photo, the sharpness of the cropped card image
    // is measured as the variance of its Laplacian (laplacianVariance()).
    // A blurry crop (< kSharpnessThreshold) is rejected and a new still is
    // requested on the next engine trigger; `stillCaptureRequested` is reset to
    // allow this.  After kSharpnessMaxAttempts rejections the best seen crop is
    // accepted unconditionally — no matter how blurry — so the scan never hangs.
    //
    // Threshold calibration (field data, iPhone 11 Pro):
    //   iOS front unreadable:    34   ← well below threshold
    //   iOS back barely read:    55   ← below threshold
    //   Android front good:     491   ← well above threshold
    //   Target threshold:       130   ← conservative midpoint, ~2× the bad value
    //
    // All four fields are @MainActor-only (mutated inside Task { @MainActor }).
    private var sharpnessAttemptCount  = 0
    private var bestSharpness: Float   = 0
    private var bestSharpnessImage: UIImage?      = nil
    private var bestSharpnessResult: FrameResult? = nil

    private let cameraSession: CameraSession
    private let finalizer = ScanFinalizer()

    /// @Published so SwiftUI re-renders CameraPreviewRepresentable when camera is ready.
    @Published private(set) var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer? { cameraSession.previewLayer }

    // style is @MainActor — its Color members must not be ARC'd on background threads.
    // Only the scalar bboxPaddingFraction is replicated for processingQueue use.
    private var _bboxPaddingFraction: CGFloat = ScannerStyle().bboxPaddingFraction
    private var viewSize: CGSize = .zero
    private var finished = false

    // ── Side-gate state machine (@MainActor) ─────────────────────────────────
    //
    // Replaces the previous ad-hoc combination of:
    //   • `isAnalyzing` Bool + `analyzingTimeoutTask` (ANALYZING window)
    //   • `liveGateMismatch` local per-frame Optional (wrong-side live detect)
    //
    // States:
    //   NORMAL          — no active probe window; use standard color/message logic.
    //   ANALYZING       — card just appeared (or flipped); scan-line animation;
    //                     neutral color while m9 classifies.
    //   REJECT_WRONG_SIDE — red + "Нужна лицевая/обратная сторона"; debounced via
    //                     wrongStreak >= kWrongStreak consecutive wrong-side verdicts.
    //   REJECT_UNKNOWN  — red + "Сканируйте кыргызскую ID-карту"; only after
    //                     unknownStreak >= kUnknownStreak consecutive Unknown probes
    //                     AND the card is still (otherwise stay in ANALYZING).
    //
    // Transitions (probeSeq-gated — only new verdicts advance the machine):
    //   NORMAL / ANALYZING:
    //     correct side    → NORMAL immediately (reset all streaks)
    //     wrong side      → wrongStreak++; if >= kWrongStreak → REJECT_WRONG_SIDE
    //     unknown         → unknownStreak++; if >= kUnknownStreak && cardIsStill → REJECT_UNKNOWN
    //                       else stay in ANALYZING with animation
    //   REJECT_WRONG_SIDE / REJECT_UNKNOWN:
    //     correct side    → correctStreak++; if >= kCorrectStreak → NORMAL + clearSideGateReject
    //                       (Bug A fix: exits reject without waiting for card-absent counter)
    //     wrong/unknown   → correctStreak reset; remain in REJECT
    //     [card absent long enough → sideGateNoCardFrames path → clearSideGateReject (second path)]
    //
    // ANALYZING-trigger conditions (checked once per YOLO frame, before probe logic):
    //   1. Card appears fresh (hasCard false→true) with liveVersionProbe ON
    //   2. FLIP: cardIsStill was true for >= 1 YOLO frames, then isStill=false for
    //      >= kMotionFrames consecutive YOLO frames → enter ANALYZING, clear streaks.
    //      This debounces normal hand-tremor from a genuine flip-and-present gesture.
    //
    // Capture-reject path (beginSideGateReject, called from handleFinished) is NOT
    // part of this SM — it fires on actual isFinished captures with wrong version,
    // without any streak gating (a single wrong-side capture is always rejected).
    //
    // Accessed only on @MainActor — no lock needed.

    private enum SGSMState {
        case normal
        case analyzing
        case rejectWrongSide(title: String)
        case rejectUnknown
    }

    /// Current state of the side-gate state machine.
    private var sgsmState: SGSMState = .normal

    // ── SGSM constants ─────────────────────────────────────────
    private let kWrongStreak       = 3   // consecutive wrong-side probes (card still) → REJECT_WRONG_SIDE
    // iOS-specific escape hatch: cardIsStill is much rarer on iOS than Android
    // (wider sensor → the same hand tremor is more pixels of motion), so a
    // still-only gate can starve the REJECT forever on a handheld phone. A
    // sustained wrong streak (~1 s of probes) locks the reject even in motion —
    // long enough that a mid-flip transient (1-4 verdicts) never triggers it.
    private let kWrongStreakMoving = 6   // consecutive wrong-side probes (moving) → REJECT_WRONG_SIDE
    private let kCorrectStreak     = 2   // consecutive correct probes in REJECT → clear reject
    private let kUnknownStreak     = 4   // consecutive Unknown probes (while still) → REJECT_UNKNOWN
    private let kMotionFrames      = 3   // consecutive not-still YOLO frames → flip detected
    private let kAnalyzingTimeout: TimeInterval = 0.4

    // ── SGSM streak counters ────────────────────────────────────
    private var sgsmWrongStreak    = 0
    private var sgsmCorrectStreak  = 0   // consecutive correct probes (used to exit REJECT)
    private var sgsmUnknownStreak  = 0
    /// Last probe sequence number seen by the SM; used to gate on new verdicts only.
    private var sgsmLastProbeSeq   = 0
    /// How many consecutive YOLO frames the card was NOT still (for flip detection).
    private var sgsmNotStillFrames = 0
    /// Whether the card was still on the previous YOLO frame (for flip edge detection).
    private var sgsmWasStill       = false
    /// Cancellable timeout task for the ANALYZING window.
    private var sgsmTimeoutTask: Task<Void, Never>? = nil

    // ── SGSM helpers ────────────────────────────────────────────

    /// Enters the ANALYZING state and arms the 400 ms timeout.
    private func sgsmBeginAnalyzing() {
        sgsmState         = .analyzing
        sgsmWrongStreak   = 0
        sgsmCorrectStreak = 0
        sgsmUnknownStreak = 0
        // Bug 1 fix: reset sgsmLastProbeSeq so that C++-restarted probe_seq (which
        // restarts from 1 on card-lost / beginNextSide) is immediately detected.
        // Without this, stale sgsmLastProbeSeq (e.g. 7) makes the condition
        // `newSeq > sgsmLastProbeSeq` skip all new verdicts until seq exceeds the
        // old value — ANALYZING times out to NORMAL with zero verdicts processed,
        // leaving the SM stuck in the previous (wrong-side) streak state.
        sgsmLastProbeSeq  = 0
        sgsmTimeoutTask?.cancel()
        sgsmTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(kAnalyzingTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Timeout: revert to NORMAL so normal color/message logic resumes.
            // If no confident verdict arrived in 400 ms (heavy processing / slow m9),
            // the overlay unblocks rather than staying frozen.
            guard let self else { return }
            if case .analyzing = self.sgsmState {
                self.sgsmState = .normal
                self.sgsmTimeoutTask = nil
                controllerLog.debug("side-gate sm: ANALYZING timeout → NORMAL")
            }
        }
    }

    /// Cancels and clears the SGSM, resetting to NORMAL. Used on card-lost, reset(), etc.
    private func sgsmClear() {
        sgsmState         = .normal
        sgsmWrongStreak   = 0
        sgsmCorrectStreak = 0
        sgsmUnknownStreak = 0
        sgsmNotStillFrames = 0
        sgsmWasStill      = false
        sgsmLastProbeSeq  = 0
        sgsmTimeoutTask?.cancel()
        sgsmTimeoutTask   = nil
    }

    // ── Public-facing `isAnalyzing` derived from SGSM ───────────
    //
    // Previously a standalone Bool; now derived from the SM state so the two
    // representations stay in sync without a separate update site.
    private var isAnalyzing: Bool {
        if case .analyzing = sgsmState { return true }
        return false
    }

    // ── Shooting-distance hint: soft gate (hysteresis + debounce) ────────────
    //
    // Fraction of the camera frame area occupied by the detected card bbox.
    // Shown in detecting state only; lower priority than side-gate and ANALYZING.
    // Enter thresholds are strict; exit thresholds sit in a wider band (hysteresis)
    // so the hint doesn't toggle on small movements; a debounce requires the bad
    // state to persist before the hint appears.
    // Mirrors Android ScannerController companion constants 1:1.

    /// Card fills >92 % of the frame → candidate "too close".
    private let kBBoxRatioTooClose:   CGFloat = 0.92
    /// Hysteresis: only clear "too close" once back under 84 %.
    private let kBBoxRatioCloseExit:  CGFloat = 0.84
    /// Card <6 % of the frame → candidate "too far" (too small to read).
    private let kBBoxRatioTooFar:     CGFloat = 0.06
    /// Hysteresis: only clear "too far" once back over 10 %.
    private let kBBoxRatioFarExit:    CGFloat = 0.10
    /// Pixel margin for real edge-clipping (image-pixel space, NOT view points).
    /// Tightened from 3 % of frame dimension to 4 px: a well-sized card merely
    /// near an edge no longer trips it; only a card actually overflowing the frame counts.
    private let kBBoxEdgeMarginPx:    CGFloat = 4
    /// Frames a bad distance must persist before the hint is shown (~0.27 s @30 fps).
    private let kDistanceEnterFrames: Int     = 8
    /// Frames a good distance must persist before an active hint clears (~0.07 s).
    private let kDistanceClearFrames: Int     = 2

    // Distance-hint state machine (@MainActor-only, mutated inside Task { @MainActor }).
    //   distState: committed state — -1 too far, 0 ok, +1 too close.
    private var distState:        Int = 0
    private var distPending:      Int = 0
    private var distPendingCount: Int = 0

    // ── Side/generation gate (@MainActor) ─────────────────────
    //
    // State-driven sticky COLOR reject (replaces the old asyncAfter-1.5 s timer):
    //
    // When `configuration.enforceSideMatch` is true and a capture arrives with a
    // wrong side or generation, we:
    //   1. Do NOT set finished = true (capture is rejected).
    //   2. Set `sideGateRejectActive = true` — this makes the bbox COLOR red.
    //      The POSITION of the bbox is always live (never frozen); only the color
    //      is sticky so the overlay follows the card smoothly.
    //   3. Re-arm the C++ engine immediately (engine.reset()) so the next frame
    //      begins a fresh detection pass.
    //   4. Every YOLO frame while reject is active:
    //      - `hasCard=true`:  card still visible → keep red, reset no-card counter.
    //      - `hasCard=false`: increment `sideGateNoCardFrames`.
    //        When the counter reaches `kSideGateNoCardFramesToClear` the user has
    //        clearly removed the wrong card → clear the reject state automatically.
    //   5. When a SUBSEQUENT capture arrives and PASSES the gate (handleFinished
    //      calls the normal finalize path without hitting the gate branch), the
    //      reject state is already cleared by that point because `finished` is set
    //      to true — the gate branch in handleFinished only fires when the gate
    //      actively rejects the capture.
    //
    // Accessed only on @MainActor — no lock needed.
    private var sideGateRejectActive = false
    /// Message currently injected by the side-gate reject pass.
    /// Cleared together with `sideGateRejectActive`.
    private var sideGateRejectTitle: String = ""
    private var sideGateRejectHint:  String = ""
    /// Last known card bbox (view-space) at the moment of the gate reject.
    /// Held so the bbox stays on screen while the engine is reset and re-detecting.
    private var sideGateLastBBox: CGRect? = nil
    /// Consecutive YOLO frames without a card detected since the last gate reject.
    /// When this reaches `kSideGateNoCardFramesToClear`, the reject is cleared.
    private var sideGateNoCardFrames: Int = 0
    /// How many consecutive no-card YOLO frames before auto-clearing the reject.
    /// At YOLO_INTERVAL=5 and 30 fps → YOLO fires ~6×/s → 12 frames ≈ 2 s.
    // 3 YOLO frames ≈ 0.5 s at 30 fps / YOLO_INTERVAL=5 — Android parity: its counter
    // ticks on EVERY camera frame with GATE_CLEAR_NO_CARD_FRAMES=15 (also ≈ 0.5 s).
    // The previous value 12 was copied from an all-frames design and made the sticky
    // reject linger ~2 s after the card left the frame (4× slower than Android).
    private let kSideGateNoCardFramesToClear = 3

    // ── Derived-event trackers (Phase A5, @MainActor) ─────────

    /// hasCard on the previous published frame — rising edge → .documentDetected.
    private var wasCardVisible = false
    /// hasCard from the most recent FULL (YOLO) frame — written on main in process(),
    /// read on main inside trackOnly()'s publish block: a stale OF track must not
    /// resurrect the bbox after YOLO said "no card". See trackOnly().
    private var lastYoloHasCard = false
    /// Last emitted progress bucket (progress×10) — change → .processing event.
    private var lastProgressBucket = -1

    // ── Lifecycle auto-pause (Phase A6, @MainActor) ───────────

    /// Set on didEnterBackground when the capture session was running, so
    /// willEnterForeground resumes ONLY a session the SDK itself paused.
    private var wasRunningBeforeBackground = false
    /// Notification tokens for background/foreground observers (removed in deinit).
    private var lifecycleObservers: [NSObjectProtocol] = []

    // ── Teardown gate (@MainActor) ────────────────────────────
    //
    // Set to `true` in teardownCamera() and checked in every @MainActor-hopped
    // completion block (process(sampleBuffer:) Task, trackOnly, handleFinished,
    // onFinished) so that callbacks arriving after dismiss are silently dropped.
    //
    // Reset to `false` in reset() so that a subsequent prepare()+onAppear reopens
    // the delivery path for the next scan (e.g. back side in the verify flow).
    //
    // Accessed only on @MainActor — no lock needed.
    private var isClosed: Bool = false

    // ── Auto-torch (@MainActor) ──────────────────────────────────────────────
    //
    // When config.autoTorch == true, tracks consecutive YOLO frames where isDark
    // AND hasCard are both true. After kDarkStreakThreshold consecutive dark-card
    // frames the SDK calls cameraSession.setTorch(true) automatically.
    // The torch is turned back off when the card is absent for kDarkNoCardClearFrames
    // consecutive frames, on teardownCamera(), or when the scan finishes.
    //
    // autoTorchActive is intentionally NOT reset in reset() so the torch persists
    // across the front→back side transition in the verify flow — the scene lighting
    // does not change between sides. prepare() re-applies the torch at camera start.
    //
    // userTorchOverride is set when the caller invokes setFlashlightEnabled(_:)
    // explicitly, preventing the auto-torch logic from fighting manual control.
    // Both flags are cleared in teardownCamera() for a clean next scan session.

    private let kDarkStreakThreshold   = 8    // consecutive dark+card YOLO frames → torch ON
    private let kDarkNoCardClearFrames = 30   // consecutive no-card frames → torch OFF

    // ── Sharpness gate constants ──────────────────────────────────────────────
    /// Minimum Laplacian-variance score to accept a cropped still as "sharp enough".
    /// Field data (iPhone 11 Pro): blurry iOS crops score 34–55; good Android crops
    /// score ~491. 130 is a conservative threshold (~2.4× the worst iOS value).
    private let kSharpnessThreshold: Float = 130.0
    /// Maximum number of blurry-still rejections before accepting the best crop seen.
    /// At ~1 still per 1-2 s of engine cycle, 30 attempts ≈ 30–60 s — effectively
    /// a last-resort fallback so the scan never hangs forever on a dim/blurry scene.
    private let kSharpnessMaxAttempts = 30

    private var darkStreak:       Int  = 0
    private var darkNoCardFrames: Int  = 0
    private var autoTorchActive:  Bool = false
    private var userTorchOverride: Bool = false

    // ── Background engine-reset (@MainActor) ──────────────────────────────────
    //
    // native_reset() can block for up to ~4 s on @MainActor when a prewarm
    // Mrz2Task future is in-flight: clearMrz2Cache() destroys the std::future
    // object whose destructor calls .get(), waiting for the m13 MRZ inference
    // to finish. This freezes the UI and makes the Cancel button unresponsive.
    //
    // Fix: reset() dispatches native_reset() via Task.detached and stores the
    // handle in engineResetTask. prepare() awaits the handle before starting the
    // camera so no video frames reach the engine while it is in a partially-reset
    // (FINISHED_SUCCESS) state.

    private var engineResetTask: Task<Void, Never>? = nil

    // ── Init ──────────────────────────────────────────────────

    init(configuration: MergenScannerConfig, style: ScannerStyle) {
        self.configuration = configuration
        self.style = style
        self.cameraSession = CameraSession(processingQueue: processingQueue)
        super.init()
        // Forward camera flags from config to the camera session.
        // CameraSession reads these once inside setup() before building the AVCaptureSession.
        cameraSession.lowResOnWeakDevice = configuration.lowResOnWeakDevice
        cameraSession.autofocusEnabled   = configuration.autofocusEnabled
        // ── [weak-tier] 720p analysis stream (weak-tier CPU pack) ─────────────
        // Tier-0 devices (<3 GB RAM or ≤4 cores) run the default .high preset
        // (.hd1920x1080) at 255–342% CPU — per-frame pixel-buffer conversion +
        // tracking cost is proportional to pixel count. 720p is 2.25× fewer
        // pixels per frame and the single biggest camera-path CPU lever.
        // ONLY the live video (analysis) output is downgraded:
        //  - Still capture is unaffected: CameraSession's AVCapturePhotoOutput
        //    requests maxPhotoDimensions from the active format (≥2048 long
        //    edge), independent of the session preset.
        //  - Live back-side MRZ (m12) reads from analysis frames and may degrade
        //    slightly at 720p on tier-0; the still-capture verify-from-snapshots
        //    fallback covers this (full-res still → OCR re-read).
        // An explicit .balanced/.fast integrator choice passes through unchanged;
        // only the .high (1080p) preset is capped on tier 0.
        if DeviceTierDetector.detect() == 0 && configuration.cameraQuality == .high {
            cameraSession.cameraQuality = .balanced   // .hd1280x720
            controllerLog.notice("[weak-tier] analysis stream 720p")
        } else {
            cameraSession.cameraQuality = configuration.cameraQuality
        }
        cameraSession.onFrame = { [weak self] sampleBuffer, captureTime in
            self?.deliverFrame(sampleBuffer: sampleBuffer, captureTime: captureTime)
        }

        // ── Lifecycle auto-pause (Phase A6) ───────────────────
        // Pause the capture session when the app backgrounds; resume on foreground
        // ONLY if the SDK itself paused it and the controller wasn't torn down
        // (isClosed) in between. Engine/models are untouched — camera only.
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleDidEnterBackground() }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWillEnterForeground() }
        })
    }

    deinit {
        for token in lifecycleObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func handleDidEnterBackground() {
        guard !isClosed, captureSession != nil else { return }
        wasRunningBeforeBackground = true
        cameraSession.stopRunning()
    }

    private func handleWillEnterForeground() {
        guard wasRunningBeforeBackground else { return }
        wasRunningBeforeBackground = false
        // Respect the teardown gate: if the view disappeared (teardownCamera) while
        // backgrounded, the session is gone and must NOT be restarted here.
        guard !isClosed, captureSession != nil else { return }
        cameraSession.startRunning()
        emitEvent(.cameraReady)
    }

    // ── Setup ─────────────────────────────────────────────────

    func prepare() {
        #if !targetEnvironment(simulator)
        // 0. Permission gate (Phase A7): in check-only mode the SDK never triggers
        //    the system permission prompt. Building the AVCaptureSession below WOULD
        //    trigger it implicitly on first use, so we bail out before any camera
        //    work and report the denial instead. Default (true) = pre-v2.1 behaviour.
        if !configuration.handlePermissionsInternally,
           AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            controllerLog.error("prepare: camera not authorized and handlePermissionsInternally=false — emitting cameraPermissionDenied")
            deliverError(MergenError.cameraPermissionDenied)
            return
        }

        // 1. Setup camera FIRST — preview layer is available immediately.
        cameraSession.setup()
        captureSession = cameraSession.captureSession
        controllerLog.debug("camera setup done, previewLayer: \(self.previewLayer != nil, privacy: .public)")

        // 2a. If the engine was already warmed (warmUp / prepareEngineOnly), reuse it and
        //     just start the camera — no second cold model load.
        if self.engine != nil {
            // If a background engine-reset is still in flight (dispatched by reset()),
            // await it before starting the camera. Video frames on a partially-reset
            // engine (still in FINISHED_SUCCESS state) would spuriously re-trigger
            // handleFinished and corrupt the scan result for the new side.
            let pendingReset = engineResetTask
            engineResetTask = nil
            if let pendingReset {
                Task { @MainActor [weak self] in
                    await pendingReset.value
                    guard let self, !self.isClosed else { return }
                    controllerLog.info("engine reset complete, starting capture session")
                    // Trigger m12/m13 async (re)load immediately after reset completes.
                    // Overlaps MRZ model loading with the card detection phase so the models
                    // are closer to ready when CAPTURED state fires (~4–5 s into back scan).
                    self.engine?.beginNextSide()
                    self.cameraSession.startRunning()
                    // Re-apply auto-torch if it was active before teardown/side transition.
                    if self.autoTorchActive { self.cameraSession.setTorch(true) }
                    self.emitEvent(.cameraReady)
                }
            } else {
                controllerLog.info("engine already warm, starting capture session")
                // Trigger m12/m13 async (re)load so MRZ models warm up during detection.
                engine?.beginNextSide()
                cameraSession.startRunning()
                // Re-apply auto-torch if it was active before teardown/side transition.
                if autoTorchActive { cameraSession.setTorch(true) }
                emitEvent(.cameraReady)
            }
            return
        }

        // 2b. Init engine on a dedicated thread with 32 MB stack.
        //    DispatchQueue background threads default to 512 KB — ONNX Runtime /
        //    model decryption overflow that stack and crash.
        //    Main thread has 8 MB but blocking it freezes UI.
        let cfg = self.configuration
        let engineThread = Thread { [weak self] in
            let eng = MergenEngine(config: cfg)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.engine = eng
                controllerLog.info("engine ready, starting capture session")
                self.cameraSession.startRunning()
                self.emitEvent(.cameraReady)
                DispatchQueue.main.async {
                    controllerLog.debug("capture session running: \(self.captureSession?.isRunning ?? false, privacy: .public)")
                }
            }
        }
        engineThread.name      = "com.mergen.engine-init"
        engineThread.stackSize = 32 * 1024 * 1024   // 32 MB
        engineThread.qualityOfService = .userInitiated
        engineThread.start()
        #endif
    }

    // ── Torch (Phase A1) ──────────────────────────────────────

    /// Torch (flashlight) control. The desired state persists across background/
    /// foreground pauses and resets on `teardownCamera()`.
    ///
    /// Calling this method sets `userTorchOverride`, preventing the auto-torch
    /// logic from fighting the caller's explicit choice for the current session.
    func setFlashlightEnabled(_ enabled: Bool) {
        // Record explicit override — auto-torch will not change the state after this.
        userTorchOverride = true
        cameraSession.setTorch(enabled)
    }

    /// Warm the native engine (models) WITHOUT touching the camera.
    ///
    /// Used by `Mergen.warmUp()` so a model-preload at app launch does NOT power on the
    /// camera. The camera is started ONLY by `prepare()` (the live-scan UI). The gallery
    /// path (`processGalleryTwoSided`) reuses this warmed `engine` and never needs the camera.
    /// Idempotent: a no-op once the engine is loaded.
    func prepareEngineOnly() {
        #if !targetEnvironment(simulator)
        guard engine == nil else { return }
        let cfg = self.configuration
        let engineThread = Thread { [weak self] in
            let eng = MergenEngine(config: cfg)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.engine == nil { self.engine = eng }
            }
        }
        engineThread.name      = "com.mergen.engine-warmup"
        engineThread.stackSize = 32 * 1024 * 1024   // 32 MB
        // .background: warm-up runs at app-launch with no live-scan UI visible,
        // so we deliberately yield to UI/main-thread work. The live-scan prepare()
        // path keeps .userInitiated — this QoS change is confined to prepareEngineOnly().
        engineThread.qualityOfService = .background
        engineThread.start()
        #endif
    }

    /// Schedules m12/m13 (DocsaidLab MRZ) async model reload via `beginNextSide()`.
    ///
    /// Designed for `Mergen.preload()`: triggers m12+m13 loading at app launch so the
    /// models are as warm as possible before the first back-side scan or gallery verify.
    ///
    /// - If the engine is already available, triggers `beginNextSide()` immediately.
    /// - If engine init is still in flight on the warmup thread, polls a background Task
    ///   (0.5 s intervals, up to 20 s) until the engine is set, then awaits Wave-1/2
    ///   readiness (`awaitModelsReady`), then calls `beginNextSide()`.
    ///
    /// Calling `beginNextSide()` on an IDLE engine (fresh, no prior scan) is safe: the
    /// C++ soft-reset is a no-op when there is no accumulated state, and `prewarmMrzScanner2`
    /// simply fires an async mrz2_load_future_ to start session creation.
    ///
    /// Must be called on `@MainActor`.
    func scheduleMrzPrewarm() {
        #if !targetEnvironment(simulator)
        if let eng = engine {
            eng.beginNextSide()
            controllerLog.info("scheduleMrzPrewarm: m12/m13 prewarm triggered (engine already warm)")
            return
        }
        // Engine init in flight on the warmup thread — poll then trigger.
        let isWeakDevice = ProcessInfo.processInfo.physicalMemory < 3_000_000_000
        let timeoutMs: Int64 = isWeakDevice ? 20_000 : 12_000
        Task.detached(priority: .background) { [weak self] in
            for _ in 0..<40 {   // up to 20 s (40 × 0.5 s)
                let eng = await MainActor.run { self?.engine }
                if let eng {
                    _ = eng.awaitModelsReady(timeoutMs: timeoutMs)
                    eng.beginNextSide()
                    controllerLog.info("scheduleMrzPrewarm: m12/m13 prewarm triggered after engine ready")
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 s
            }
            controllerLog.warning("scheduleMrzPrewarm: engine not ready within 20 s — m12/m13 prewarm skipped")
        }
        #endif
    }

    func updateViewSize(_ size: CGSize) { viewSize = size }
    func updateStyle(_ s: ScannerStyle) {
        style = s
        let padding = s.bboxPaddingFraction
        processingQueue.async { self._bboxPaddingFraction = padding }
    }

    /// Patches the side/generation gate fields on a pooled controller.
    ///
    /// **Why this exists:**
    /// `MergenEnginePool.controller(for:leanFields:)` creates the controller once with a
    /// default `MergenScannerConfig` (`enforceSideMatch = false`).  When
    /// `MergenScannerView` / `MergenScanView` later presents with a config that carries
    /// `enforceSideMatch = true`, `expectedSide`, and `expectedGeneration`, those values
    /// never reach the already-cached controller — the gate silently stays off.
    ///
    /// This method injects only the three gate fields; all other config fields (lens,
    /// resolution, lean mode, etc.) are intentionally left unchanged because they were
    /// baked into the pool key at warmUp time.
    ///
    /// **When to call:** `onAppear` of every `MergenScannerView` / `MergenScanView`
    /// presentation.  Calling it again when the same controller is reused for the back
    /// side (front→back transition) updates `expectedSide` / `expectedGeneration` to
    /// match the new scan target — the critical case for the two-sided verify flow.
    ///
    /// Accessing `configuration` is @MainActor-only; `sideGateRejectReason` reads only
    /// these three fields, also @MainActor → no lock needed.
    func applySideGate(config: MergenScannerConfig) {
        let enforce  = config.enforceSideMatch
        let side     = config.expectedSide
        let gen      = config.expectedGeneration
        let lvp      = config.liveVersionProbe
        let animAnal = config.showAnalysisAnimation
        let capTips  = config.showCaptureTips
        configuration.enforceSideMatch      = enforce
        configuration.expectedSide          = side
        configuration.expectedGeneration    = gen
        configuration.liveVersionProbe      = lvp
        configuration.showAnalysisAnimation = animAnal
        configuration.showCaptureTips       = capTips

        // Push the updated live_version_probe (and all other flags) to the C++ engine.
        //
        // Background: MergenEnginePool creates the controller once and may not have
        // `liveVersionProbe=true` in its factory config (the pool key does not include
        // liveVersionProbe because it is a runtime gate, not a model-selection flag).
        // applySideGate() runs on every onAppear — AFTER the engine may already be warm
        // from a pool-HIT.  Without the updateConfig call below, the C++ engine keeps
        // its init-time config (live_version_probe=false) and probe_seq stays 0 forever,
        // so the SGSM never receives verdicts and cycles ANALYZING→timeout→NORMAL.
        //
        // We send the COMPLETE configuration JSON (toEngineJson()) — NOT a partial one —
        // because C++ parseConfig replaces every field with j.value(key, default).
        // A partial JSON would silently reset absent flags (e.g. use_unified_detector→false).
        // `self.configuration` at this point already has all pool-creation values merged
        // with the gate fields patched above, so the full JSON is safe.
        if let eng = engine {
            eng.updateConfig(configuration)
            controllerLog.info("side-gate applied + C++ updateConfig: liveVersionProbe=\(lvp, privacy: .public)")
        } else {
            // Engine not yet warm (warmUp still in-flight or pool-MISS engine thread running).
            // The engine will be initialized with the MergenScannerConfig created by the pool,
            // which does NOT have liveVersionProbe. Schedule a retry on the main queue so that
            // by the time prepare()'s engine-init thread completes and sets self.engine,
            // we can push the config. We observe engine readiness via the cameraReady event,
            // but a simpler approach is a short deferred check.
            //
            // NOTE: this path is rare — the pool-HIT path (engine already warm) is the
            // common case. For pool-MISS, the engine is initialized with configuration
            // from the pool factory which ALREADY carries liveVersionProbe=true when the
            // pool key includes it (see MergenEnginePool fix). This fallback covers the
            // case where applySideGate fires before the engine thread completes.
            controllerLog.warning("side-gate applied to Swift config; engine not yet warm — updateConfig deferred")
        }

        controllerLog.info("""
            side-gate applied: enforce=\(enforce, privacy: .public) \
            side=\(String(describing: side), privacy: .public) \
            gen=\(gen ?? "nil", privacy: .public) \
            liveVersionProbe=\(lvp, privacy: .public) \
            showAnalysisAnimation=\(animAnal, privacy: .public) \
            showCaptureTips=\(capTips, privacy: .public)
            """)
    }

    func reset() {
        finished = false
        isClosed = false   // reopen the delivery gate for the next scan session
        wasCardVisible = false
        lastYoloHasCard = false
        lastProgressBucket = -1
        stillCaptureRequested  = false                    // new side → new photo budget
        sharpnessAttemptCount  = 0                        // new side → fresh sharpness budget
        bestSharpness          = 0
        bestSharpnessImage     = nil
        bestSharpnessResult    = nil
        sideGateRejectActive  = false                     // clear any pending reject visual
        sideGateRejectTitle   = ""
        sideGateRejectHint    = ""
        sideGateLastBBox      = nil
        sideGateNoCardFrames  = 0
        sgsmClear()
        processingQueue.async { self.stillInFlight = false }
        // Dispatch native_reset() to a background thread to avoid blocking @MainActor.
        //
        // The C++ clearMrz2Cache() call inside native_reset() destroys Mrz2Task
        // std::future objects. When an m13 MRZ prewarm inference is in-flight, that
        // destructor calls future.get() and blocks for up to ~4 s. Running this on the
        // main thread freezes the UI and makes the Cancel button unresponsive — the
        // user-visible "cancel lag" reported on device.
        //
        // Safety: prepare() checks engineResetTask and awaits completion before
        // calling cameraSession.startRunning(), so no video frames can reach the
        // engine while it is in a FINISHED_SUCCESS (partially-reset) state.
        // Guard: if teardownCamera() already dispatched a proactive reset+prewarm Task,
        // don't create a second concurrent native_reset().  Two concurrent C++ native_reset()
        // calls on the same engine are a data race.  The proactive task already covers
        // native_reset() + beginNextSide(); prepare() will await it correctly.
        guard engineResetTask == nil else {
            controllerLog.info("reset: proactive reset in flight — reusing existing engineResetTask")
            return
        }
        let _engine = engine
        engineResetTask = Task.detached(priority: .userInitiated) {
            _engine?.reset()
        }
        // Clear synchronously when already on main: onAppear calls reset() during
        // the view's first render pass, and an async Task lands only AFTER SwiftUI
        // has painted the overlay — the previous side's bbox would flash on screen
        // until then. Synchronous clearing guarantees the new side starts blank.
        if Thread.isMainThread {
            frameState = .empty
        } else {
            Task { @MainActor in frameState = .empty }
        }
    }

    func stop() {
        cameraSession.stopRunning()
    }

    /// Stops the camera and tears down the AVCaptureSession so that the next
    /// [prepare()] call rebuilds a fresh session from scratch.
    ///
    /// The engine (MergenEngine / ONNX models) is NOT affected — only the camera
    /// pipeline is released.  Call this instead of [stop()] when the scanning view
    /// is about to disappear and a fresh camera open is desired on the next appear
    /// (e.g. between the front and back sides of the verify flow).
    ///
    /// Idempotent: if `isClosed` is already true (e.g. a second call from
    /// viewWillDisappear after `release()` was already invoked), this is a no-op.
    /// `reset()` reopens `isClosed = false` for the next scan side, so the guard
    /// correctly passes on a subsequent teardown.
    func teardownCamera() {
        // Bug 2 fix: idempotency guard against double-release.
        // closeTapped() calls stop() (queues async stopRunning) then dismiss().
        // viewWillDisappear also calls teardownCamera(). Without this guard,
        // teardown() would be dispatched to processingQueue twice — harmless but
        // the check makes the intent explicit and prevents any future double-nil
        // of AVFoundation objects if the call order changes.
        guard !isClosed else { return }

        // Cancel the pending background engine-reset so its completion Task does
        // not race to call startRunning() on an already-torn-down session.
        // The native_reset() call itself continues in the background harmlessly
        // (Swift Task cancellation is cooperative; the C++ call is not interruptible).
        engineResetTask?.cancel()
        engineResetTask = nil

        // Close the @MainActor delivery gate first so that any Task{} blocks
        // that are already queued but haven't run yet will see isClosed = true
        // and drop their callbacks (onFinished / frameState update).
        isClosed = true
        // A torn-down session must never be auto-resumed by the foreground observer.
        wasRunningBeforeBackground = false

        // Reset auto-torch state so the next fresh scan session starts clean.
        autoTorchActive   = false
        darkStreak        = 0
        darkNoCardFrames  = 0
        userTorchOverride = false

        // Nil the @Published captureSession immediately on @MainActor so that
        // CameraPreviewRepresentable sees the change and stops referencing the
        // stale session before the async stopRunning() fires.
        captureSession = nil
        // Drop the last frame's overlay state (bbox/color/hints) as well: the
        // pooled controller is reused for the next side, and a stale bbox from
        // the previous side would otherwise be the first thing the new camera
        // view renders (visible ~1s until the first fresh frame arrives).
        frameState = .empty
        cameraSession.teardown()

        // Proactive reset: dispatch native_reset() + beginNextSide() now so the
        // heavy reset overlaps with the user's navigation to the back-side camera.
        //
        // native_reset() joins an in-flight mrz2_load_future_ (m12/m13 model load)
        // which can block for up to ~4 s.  Starting it here — during the ~2–5 s the
        // user flips the card and taps 'Camera' — means the back scan's prepare() may
        // find the task already done (zero wait) or only needs to wait for the tail.
        //
        // beginNextSide() after the reset triggers a fresh mrz2_load_future_ so m12+m13
        // start loading in the background as early as possible, further overlapping with
        // the detection phase of the back scan (typically 3–5 s).
        //
        // Guard (finished): only fire after a *successful* scan. Cancelled scans
        // (finished=false) take the normal reset() path on the next onAppear.
        // Guard (engineResetTask): skip if a task is already set (prevents concurrent
        // native_reset() data race; should not happen here, but defensive).
        if finished, engineResetTask == nil {
            let _engine = engine
            engineResetTask = Task.detached(priority: .userInitiated) {
                _engine?.reset()           // C++ → IDLE; joins/clears Mrz2Task
                _engine?.beginNextSide()   // trigger m12+m13 async (re)load
            }
            controllerLog.info("teardownCamera: proactive reset+MRZ-prewarm dispatched")
        }
    }

    // ── Two-sided gallery processing (Mergen flow) ───────────

    /// Process a front + back image pair through the engine and return a merged
    /// [MergenIdResult] whose `finalJson` contains the `identity_v2` block.
    ///
    /// Mirrors `MergenScanner.processGalleryTwoSided(front:back:)` on Android.
    ///
    /// - Parameters:
    ///   - front:              Photo of the FRONT side.
    ///   - back:               Photo of the BACK side (with MRZ).
    ///   - repeatCount:        How many times to re-feed each image to maximise detection recall.
    ///                         Range [2..30]. MUST be > C++ kTimeoutFrames (10) so the engine's
    ///                         timeout-capture path fires on static images that cannot satisfy
    ///                         the `card_is_still` motion gate. Default 15.
    ///   - diagnosticCallback: Optional step-by-step callback for debug banners.
    ///                         Called on the gallery thread (background), NOT main.
    ///   - completion:         Called on the main thread with the merged result.
    func processGalleryTwoSided(
        front:              UIImage,
        back:               UIImage,
        repeatCount:        Int = 15,
        diagnosticCallback: ((String) -> Void)? = nil,
        completion:         @escaping (MergenIdResult) -> Void
    ) {
        let cfg         = self.configuration
        // Budget MUST exceed C++ kTimeoutFrames (10) so the engine's timeout-capture fires
        // on static gallery images that cannot satisfy the card_is_still motion gate
        // (requires 3 consecutive frames with <12 px movement — impossible for a still image
        // on the first pass before OF has a previous-frame reference).
        // Previous default of 4 caused empty results because timeout at frame-10 was unreachable.
        let repeatBudget = min(max(repeatCount, 12), 30)

        let initAndRun = { [weak self] in
            guard let self else { return }

            let diag = diagnosticCallback

            // ── Engine init (32 MB stack thread, same as prepare()) ──
            func makeEngine() -> MergenEngine {
                MergenEngine(config: cfg)
            }

            // Re-use existing engine when available; otherwise spin up a fresh one.
            // Two-sided gallery always resets state between sides.
            let eng: MergenEngine
            if let existing = self.engine {
                existing.reset()
                eng = existing
            } else {
                eng = makeEngine()
                DispatchQueue.main.async { self.engine = eng }
            }

            // ── static_image_mode: gallery-only fast path ───────────────────────────
            // Enables geometry cache / TTA diversity / fast still-capture budget inside
            // the C++ engine.  Cleared via defer on EVERY exit path (models-not-ready
            // early return, normal completion) so the pooled engine — which the live
            // camera path may reuse via the same MergenEnginePool slot — NEVER inherits
            // static mode.  The defer is registered here in `initAndRun`, the same
            // closure scope that owns `eng` and fully encloses BOTH feedImage calls
            // (back + front), so a single defer covers the entire gallery feed regardless
            // of which branch exits.  The live camera path (`process`, `deliverFrame`,
            // `trackOnly`, `prepare`, still-capture) never calls setStaticImageMode, so
            // static mode stays false on the camera path by construction.
            eng.setStaticImageMode(true)
            defer { eng.setStaticImageMode(false) }

            // ── Await model readiness (YOLO + capture models) before feeding frames ──
            // The C++ engine ctor returns in <1 ms while models load asynchronously
            // in background threads (~1–2 s on device).  Gallery paths feed all frames
            // in a tight loop that finishes in <100 ms — far before models are ready —
            // producing empty results (same race as confirmed in Android device logs).
            // Camera path is unaffected (continuous preview gives models time to warm up).
            // Tier-adaptive timeout: A9-class devices (<3 GB) load ONNX models ~2× slower
            // on cold-start; doubling the timeout prevents silent empty results on slow hardware.
            let isWeakDevice = ProcessInfo.processInfo.physicalMemory < 3_000_000_000
            let modelsTimeoutMs: Int64 = isWeakDevice ? 20_000 : 10_000
            let modelsReady = eng.awaitModelsReady(timeoutMs: modelsTimeoutMs)
            diag?("modelsReady=\(modelsReady) timeoutMs=\(modelsTimeoutMs)")
            if !modelsReady {
                controllerLog.error("processGalleryTwoSided: models NOT ready after \(modelsTimeoutMs / 1000) s — aborting")
                diag?("front: isPassed=false version=unknown conf=0.00 [models not ready]")
                diag?("back:  isPassed=false version=unknown conf=0.00 [models not ready]")
                DispatchQueue.main.async {
                    completion(MergenIdResult(
                        success: false, croppedImage: nil, originalImage: front,
                        confidence: 0, errorCode: 1,
                        errorMessage: "Engine models failed to load (timeout)",
                        cardVersion: .unknown, isFlipped: false, fieldProgressJson: ""
                    ))
                }
                return
            }

            // ── Helper: feed one image N times, return best result ──
            // Early-exit mirrors Android processGallerySideCore: break as soon as the card
            // is captured successfully (isPassed).  A failed frame (isFinished && !isPassed)
            // does NOT break — we keep trying up to `budget` times in case the engine needs
            // more passes to stabilise detection on the static image.
            //
            // WHY budget must be > kTimeoutFrames (10):
            // A static image cannot satisfy card_is_still (needs 3+ frames with <12 px
            // movement — impossible on the very first frames when OF has no prior state).
            // The high_quality_capture gate requires card_is_still AND quality_gates.
            // timeout_capture fires at stable_frames_count >= kTimeoutFrames (10) regardless
            // of motion — it is the ONLY path that captures a perfectly still gallery image.
            // With budget=4 the loop exits at pass 4; stable_frames_count reaches ~4 at most,
            // never hitting kTimeoutFrames=10, so getFinalResultJson returns "{}".
            // With budget>=12 (enforced above), pass 10-12 fires timeout_capture → populated JSON.
            func feedImage(_ image: UIImage, budget: Int, sideLabel: String)
                -> (result: FrameResult, crop: UIImage?)
            {
                var last = FrameResult()
                var passCount = 0
                for _ in 0..<budget {
                    last = eng.processFrame(image: image)
                    passCount += 1
                    if last.isFinished && last.isPassed { break }
                }
                let crop = eng.getLastCroppedCardImage()
                diag?("\(sideLabel): isPassed=\(last.isPassed) version=\(last.cardVersion) conf=\(String(format:"%.2f", last.confidence)) passes=\(passCount)/\(budget) hasCard=\(last.hasCard) state=\(last.state) crop=\(crop != nil ? "Y" : "nil")")
                return (last, crop)
            }

            // Downscale oversized gallery photos BEFORE the 15-frame feed loop.
            // A full-resolution phone photo (e.g. 12 MP) allocates ~48 MB per
            // processFrame call; ×15 frames ×2 sides this can OOM-kill the app on
            // memory-constrained devices.  The card detector resizes to 640×640
            // internally, so capping the long edge at 2048 px loses no OCR fidelity.
            // The bundled demo pair (1860 px) is below the cap → proven path unchanged.
            let frontDS = Self.downscaledForGallery(front)
            let backDS  = Self.downscaledForGallery(back)

            // ── FRONT side FIRST (independent snapshot before MRZ arrives) ────
            //
            // INVARIANT: front MUST be fed first, Vision-injected, then beginNextSide()
            // called — in that exact order.
            //
            // WHY front-first is mandatory (mirrors Android processGalleryTwoSidedInternal):
            //   softReset() / beginNextSide() freezes the per-side FieldResolver snapshot
            //   into the IdentitySession accumulator.  That snapshot must contain the FRONT's
            //   own visual doc#/PIN reads, NOT values derived from the BACK's MRZ.
            //
            //   Back-first (the old iOS order) created a critical security hole:
            //     1. Back MRZ is processed → C++ resolver writes MRZ doc# into last_ocr_result_.
            //     2. beginNextSide() / softReset() — front snapshot is committed WITH the MRZ
            //        value already in last_ocr_result_ (because softReset does NOT clear
            //        resolver_/accumulator_ across sides).
            //     3. Front is fed next → its own visual doc# is absent (no MRZ anchor yet
            //        at feed time) → comes back empty or MRZ-overwritten.
            //     4. identity_v2 same_document cross-check compares MRZ doc# with itself
            //        → SAME_DOCUMENT = true for ANY pair (own OR mismatched front+back).
            //
            //   Front-first eliminates the hole:
            //     1. Front is fed → its visual doc#/PIN are read WITHOUT an MRZ anchor
            //        (may be weaker, but they are the FRONT's own values).
            //     2. Vision OCR is injected → homoglyph-normalised doc#/PIN votes enter
            //        the front-side accumulator.
            //     3. beginNextSide() commits the FRONT snapshot (visual doc# only, no MRZ
            //        contamination).
            //     4. Back is fed → MRZ doc# is read and stored in the BACK-side accumulator.
            //     5. identity_v2 cross-check: FRONT visual doc# vs BACK MRZ doc# → mismatch
            //        for a mismatched pair → FAILED (correct behaviour).
            //
            // NOTE: the Vision injection for the front side MUST happen BEFORE beginNextSide()
            // so that the Vision votes (especially doc#/PIN via validatedExternalField with
            // Cyrillic homoglyph normalisation) are included in the front snapshot.
            // This is the exact mirror of Android processGallerySideCore ordering:
            //   feedImage loop → ML Kit → addExternalOCR → beginNextSide.
            diag?("side order: front-first (Android parity — independent snapshot invariant)")
            let (frontResult, frontCrop) = feedImage(frontDS, budget: repeatBudget, sideLabel: "front")

            // ── Front-fail early-exit (Android parity: MergenScanner.kt:683) ────
            //
            // Android: `if (!frontResult.success) return@withContext frontResult`
            // where fail = raw==null || !raw.isPassed || confidence<=0.5 (kt:762).
            //
            // If the front side could not be captured we MUST NOT call beginNextSide():
            // beginNextSide/softReset would commit an empty front snapshot into the
            // IdentitySession accumulator, and a back-side MRZ pass could then yield
            // SINGLE_SIDE VERIFIED instead of the correct failure result.
            //
            // defer { eng.setStaticImageMode(false) } registered above fires automatically
            // on this early-return path — no additional cleanup is needed.
            if !frontResult.isPassed || frontResult.confidence <= 0.5 {
                controllerLog.warning("processGalleryTwoSided: front failed (isPassed=\(frontResult.isPassed, privacy: .public) conf=\(String(format: "%.2f", frontResult.confidence), privacy: .public)) — aborting without beginNextSide")
                diag?("front failed — early return, back not processed")
                let failResult = MergenIdResult(
                    success:           false,
                    croppedImage:      frontCrop,
                    originalImage:     front,
                    confidence:        frontResult.confidence,
                    errorCode:         1,
                    errorMessage:      "Front detection failed",
                    cardVersion:       frontResult.cardVersion,
                    isFlipped:         frontResult.isFlipped,
                    fieldProgressJson: ""
                )
                DispatchQueue.main.async { completion(failResult) }
                return
            }

            // ── Vision OCR injection — FRONT side (BEFORE beginNextSide) ────────
            // MUST be injected before beginNextSide() so Vision doc#/PIN votes are frozen
            // into the front-side snapshot in softReset().  Mirrors Android:
            //   processGallerySideCore runs addExternalOCR before returning to
            //   processGalleryTwoSidedInternal, which then calls beginNextSide().
            if #available(iOS 13.0, *), let frontCropForVision = frontCrop {
                if let frontVisionJson = _galleryVisionOCRJson(engine: eng, crop: frontCropForVision,
                                                               isLean: cfg.leanIdentityFields) {
                    eng.addExternalOCR(frontVisionJson)
                    let keyCount = frontVisionJson.components(separatedBy: "\":\"").count - 1
                    diag?("front vision inject: \(keyCount) fields passed gate")
                } else {
                    diag?("front vision inject: 0 fields passed gate")
                }
            }

            let frontCropImage = frontCrop

            // beginNextSide() (not reset()) preserves the IdentitySession accumulator so the
            // cross-side identity_v2 merge (doc#/PIN/MRZ) survives across sides.
            // At this point the front-side snapshot (visual doc#/PIN, NO MRZ) is frozen.
            // MrzScanner2 async rebuild (m12/m13) is triggered here — models are guaranteed
            // ready for the back side's MRZ pass (same trigger point as Android).
            eng.beginNextSide()

            // ── BACK side SECOND (MRZ reads independently of the front snapshot) ──
            let (backResult, backCrop) = feedImage(backDS, budget: repeatBudget, sideLabel: "back ")

            // ── Vision OCR injection — BACK side ────────────────────────────────
            // Mirror Android processGallerySideCore: inject per-field platform OCR BEFORE
            // reading getFinalResultJson() so the C++ identity_v2 accumulator reflects Vision
            // votes (doc#, PIN, MRZ) on the back side.
            if #available(iOS 13.0, *), let backCropForVision = backCrop {
                if let backVisionJson = _galleryVisionOCRJson(engine: eng, crop: backCropForVision,
                                                              isLean: cfg.leanIdentityFields) {
                    eng.addExternalOCR(backVisionJson)
                    let keyCount = backVisionJson.components(separatedBy: "\":\"").count - 1
                    diag?("back vision inject: \(keyCount) fields passed gate")
                } else {
                    diag?("back vision inject: 0 fields passed gate")
                }
            }

            let backCropImage = backCrop

            // getFinalResultJson() called ONCE here — after BOTH sides and their Vision
            // injections are complete.  Mirrors Android processGalleryTwoSidedInternal:
            //   parseFinalResult() / getFinalResultJson() called once after back side.
            // The old iOS code called getFinalResultJson() twice (once after back, once after
            // front in the back-first order) — the first call was unused in the final result
            // and is eliminated here.
            let mergedFinalJson = eng.getFinalResultJson()
            // PII-FREE log: length + empty-check only. Raw merged JSON is never logged.
            diag?("merged finalJson.len=\(mergedFinalJson.count) isEmpty=\(mergedFinalJson == "{}" || mergedFinalJson.isEmpty)")

            // The C++ two-sided engine accumulates both sides into `identity_v2` on the
            // second `getFinalResultJson` call (after back side is processed). The merged
            // JSON is what we return as `finalJson` on the result.
            let rawFinal  = mergedFinalJson
            let finalJson: String? = (rawFinal == "{}" || rawFinal.trimmingCharacters(in: .whitespaces).isEmpty)
                ? nil
                : rawFinal

            let success   = frontResult.isPassed || backResult.isPassed
            var sdkResult = MergenIdResult(
                success:           success,
                croppedImage:      frontCropImage,
                originalImage:     front,
                confidence:        max(frontResult.confidence, backResult.confidence),
                errorCode:         success ? 0 : 1,
                errorMessage:      success ? nil : "Detection failed on both sides",
                cardVersion:       frontResult.cardVersion != .unknown ? frontResult.cardVersion : backResult.cardVersion,
                isFlipped:         frontResult.isFlipped,
                fieldProgressJson: ""
            )
            sdkResult.finalJson       = finalJson
            sdkResult.croppedImageBack = backCropImage

            DispatchQueue.main.async {
                completion(sdkResult)
            }
        }

        // Always run on a dedicated 32 MB-stack thread — ONNX model loading.
        let thread = Thread {
            initAndRun()
        }
        thread.name           = "com.mergen.gallery.two-sided"
        thread.stackSize      = 32 * 1024 * 1024
        thread.qualityOfService = QualityOfService.userInitiated
        thread.start()
    }

    /// Caps the long edge of a gallery photo at `maxDim` px (default 2048) to bound
    /// the per-frame pixel-buffer allocation in `processFrame(image:)`.  Returns the
    /// original image untouched when it is already within the cap (e.g. the demo
    /// pair) so the verified small-image path is bit-for-bit unchanged.  The output
    /// always has `.up` orientation, which also skips the orientation re-render.
    static func downscaledForGallery(_ image: UIImage, maxDim: CGFloat = 2048) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > maxDim, longEdge > 0 else { return image }
        let scale = maxDim / longEdge
        let newSize = CGSize(width: (image.size.width  * scale).rounded(),
                             height: (image.size.height * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1               // 1 px per point — newSize is already in pixels
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: fmt)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // ── Sharpness measurement (Accelerate) ───────────────────────────────────

    /// Returns the variance of the 3×3 Laplacian response of the image (standard
    /// focus quality metric; higher = sharper).
    ///
    /// The computation is fully off-screen (CGContext) and safe to call from any
    /// thread.  Measured cost: ~3–5 ms for a 640×400 card crop on A14 — negligible
    /// relative to the still-capture latency (~500–1000 ms on device).
    ///
    /// Typical field values observed on device (iPhone 11 Pro):
    ///   Very blurry (iOS front, unreadable):  ~30–55
    ///   Marginally readable (iOS back):        ~50–80
    ///   Sharp (Android front, 491 raw):       ~300–600
    /// Threshold `kSharpnessThreshold` = 130 separates the two populations with
    /// a comfortable margin.
    static func laplacianVariance(_ image: UIImage) -> Float {
        guard let cgImage = image.cgImage else { return 0 }
        let w = cgImage.width
        let h = cgImage.height
        guard w > 4, h > 4 else { return 0 }

        // Render to BGRA 8-bit (off-screen, thread-safe CGContext).
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &raw,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                      | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return 0 }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Convert BGRA → luma (BT.601: Y = 0.114B + 0.587G + 0.299R).
        let n = w * h
        var luma = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let b = Float(raw[i * 4])
            let g = Float(raw[i * 4 + 1])
            let r = Float(raw[i * 4 + 2])
            luma[i] = 0.114 * b + 0.587 * g + 0.299 * r
        }

        // Apply 3×3 Laplacian kernel: [0,-1,0; -1,4,-1; 0,-1,0].
        let kernel: [Float] = [0, -1, 0, -1, 4, -1, 0, -1, 0]
        var lap = [Float](repeating: 0, count: n)
        luma.withUnsafeMutableBufferPointer { lumaBuf in
            lap.withUnsafeMutableBufferPointer { lapBuf in
                var srcVBuf = vImage_Buffer(
                    data: lumaBuf.baseAddress,
                    height: vImagePixelCount(h),
                    width:  vImagePixelCount(w),
                    rowBytes: w * MemoryLayout<Float>.stride)
                var dstVBuf = vImage_Buffer(
                    data: lapBuf.baseAddress,
                    height: vImagePixelCount(h),
                    width:  vImagePixelCount(w),
                    rowBytes: w * MemoryLayout<Float>.stride)
                _ = vImageConvolve_PlanarF(
                    &srcVBuf, &dstVBuf, nil, 0, 0,
                    kernel, 3, 3, 0.0,
                    vImage_Flags(kvImageEdgeExtend))
            }
        }

        // Variance = E[X²] − E[X]²  (standard definition).
        var mean: Float   = 0
        var sqMean: Float = 0
        let vn = vDSP_Length(n)
        vDSP_meanv(lap, 1, &mean, vn)
        var lapSq = [Float](repeating: 0, count: n)
        vDSP_vsq(lap, 1, &lapSq, 1, vn)
        vDSP_meanv(lapSq, 1, &sqMean, vn)
        return max(0, sqMean - mean * mean)
    }

    // ── Gallery image processing ──────────────────────────────

    func processGalleryImage(_ image: UIImage) {
        if engine != nil {
            processImageWithEngine(image)
            return
        }
        // Engine not yet ready — init on a dedicated 32 MB-stack thread.
        // processingQueue default threads have 512 KB which is insufficient
        // for ONNX model loading / decryption (same pattern as prepare()).
        let cfg = self.configuration
        let initThread = Thread { [weak self] in
            let eng = MergenEngine(config: cfg)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.engine = eng
                self.processImageWithEngine(image)
            }
        }
        initThread.name = "com.mergen.engine-init.gallery"
        initThread.stackSize = 32 * 1024 * 1024
        initThread.qualityOfService = .userInitiated
        initThread.start()
    }

    private func processImageWithEngine(_ image: UIImage) {
        guard let eng = engine else { return }
        processingQueue.async { [weak self] in
            guard let self else { return }

            // Await ALL capture models (YOLO + PaddleOCR + FieldDetector + CRNN) before
            // feeding any frames.  The previous approach polled only the YOLO state
            // transition out of .idle, which is insufficient: PaddleOCR and FieldDetector
            // load independently and may still be initialising when the frame loop starts,
            // producing empty OCR output.  awaitModelsReady() blocks until the C++ engine
            // signals all async loaders complete (same guard used in processGalleryTwoSided).
            // Tier-adaptive: same threshold as processGalleryTwoSided (<3 GB → 20 s).
            let isWeakDevice = ProcessInfo.processInfo.physicalMemory < 3_000_000_000
            let modelsTimeoutMs: Int64 = isWeakDevice ? 20_000 : 10_000
            let modelsReady = eng.awaitModelsReady(timeoutMs: modelsTimeoutMs)
            if !modelsReady {
                controllerLog.error("processImageWithEngine: models NOT ready after \(modelsTimeoutMs / 1000) s — aborting")
                Task { @MainActor [weak self] in
                    self?.deliverFinished(MergenIdResult(
                        success: false, croppedImage: nil, originalImage: image,
                        confidence: 0, errorCode: 1,
                        errorMessage: "Engine models failed to load (timeout)",
                        cardVersion: .unknown, isFlipped: false, fieldProgressJson: ""
                    ))
                }
                return
            }

            // RC-3 fix: must exceed C++ kTimeoutFrames=10 so timeout_capture fires on
            // static gallery images. Android uses GALLERY_REPEAT_COUNT=12 (MergenScanner.kt:882).
            // Previous value (stabilityFrames+2 = 7) never reached frame-10 → empty JSON.
            let maxAttempts = 15  // mirrors Android GALLERY_REPEAT_COUNT; > kTimeoutFrames=10
            var lastResult: FrameResult?
            for _ in 0..<maxAttempts {
                let result = eng.processFrame(image: image)
                lastResult = result
                if result.isFinished { break }
            }

            guard let result = lastResult else {
                Task { @MainActor [weak self] in
                    self?.deliverFinished(MergenIdResult(
                        success: false, croppedImage: nil, originalImage: image,
                        confidence: 0, errorCode: 1, errorMessage: "Detection failed",
                        cardVersion: .unknown, isFlipped: false, fieldProgressJson: ""
                    ))
                }
                return
            }

            let success = result.isPassed || (result.hasCard && result.confidence > 0.5)
            guard success else {
                Task { @MainActor [weak self] in
                    self?.deliverFinished(MergenIdResult(
                        success: false, croppedImage: nil, originalImage: image,
                        confidence: result.confidence, errorCode: 1, errorMessage: "Card not detected",
                        cardVersion: result.cardVersion, isFlipped: result.isFlipped, fieldProgressJson: ""
                    ))
                }
                return
            }

            // Promote isPassed to true for the gallery path when hasCard + confidence > 0.5
            // so ScanFinalizer runs the full Vision-ensemble path.
            var galleryResult = result
            galleryResult.isPassed = success

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.finalizer.finalize(
                    engine:        eng,
                    originalImage: image,
                    frameResult:   galleryResult,
                    isLean:        self.configuration.leanIdentityFields
                ) { [weak self] sdkResult in
                    self?.deliverFinished(sdkResult)
                    eng.reset()
                }
            }
        }
    }

    // ── Frame routing (called from processingQueue) ───────────

    private func deliverFrame(sampleBuffer: CMSampleBuffer, captureTime: TimeInterval) {
        guard !finished,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let eng = engine else { return }

        frameCounter += 1

        // FAST PATH: OF tracking on every frame (<1 ms, processingQueue).
        trackOnly(pixelBuffer: pixelBuffer, engine: eng, captureTime: captureTime)

        // SLOW PATH: YOLO on yoloQueue (every YOLO_INTERVAL frames, non-blocking).
        // yoloInFlight prevents queue buildup if the previous YOLO call is still running.
        // stillInFlight pauses the video OCR pipeline while a high-res still photo is
        // captured/processed — the engine works on ONE sharp still instead of more
        // motion-blurred video frames (trackOnly above keeps the overlay live).
        guard frameCounter % YOLO_INTERVAL == 0, !yoloInFlight, !stillInFlight else { return }
        yoloInFlight = true
        let buffer = sampleBuffer
        let time = captureTime
        yoloQueue.async { [weak self] in
            self?.process(sampleBuffer: buffer, captureTime: time)
            self?.processingQueue.async { self?.yoloInFlight = false }
        }
    }

    // ── YOLO frame processing (called from yoloQueue) ─────────

    private func process(sampleBuffer: CMSampleBuffer, captureTime: TimeInterval) {
        guard !finished,
              let eng = engine,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Try zero-copy BGRA path first; fall back to CIImage→CGImage if unavailable.
        let result: FrameResult
        let fallbackImage: UIImage?

        if let bgraResult = eng.processFrameBuffer(pixelBuffer) {
            result = bgraResult
            fallbackImage = nil
        } else {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = cameraSession.fallbackCIContext.createCGImage(ciImage, from: ciImage.extent) else { return }
            let uiImage = UIImage(cgImage: cgImage)
            result = eng.processFrame(image: uiImage)
            fallbackImage = uiImage
        }

        let imageSize = CGSize(
            width:  CGFloat(CVPixelBufferGetWidth(pixelBuffer)),
            height: CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        )

        // Trigger point-of-interest autofocus on the card center (throttled to 2 s).
        if result.hasCard {
            cameraSession.triggerFocusIfNeeded(bbox: result.cardBbox, imageSize: imageSize)
        }
        // During smart re-scan (captured state), refine focus onto the weakest OCR field.
        if result.state == .captured, result.hasCard,
           let weakCenter = eng.getWeakFieldCenter() {
            cameraSession.triggerWeakFieldFocusIfNeeded(
                cardBbox: result.cardBbox,
                imageSize: imageSize,
                weakCenter: weakCenter
            )
        }

        // videoRotationAngle / videoOrientation already rotates the pixel buffer
        // to portrait before delivery → rotationDegrees = 0.
        // Use C++ EMA-smoothed bbox (smoothedBbox) instead of the raw YOLO detection
        // (cardBbox) for the overlay coordinate transform.  The raw bbox jitters
        // frame-to-frame because every YOLO inference produces an independent detection;
        // smoothedBbox is the Kalman/EMA-filtered version that the C++ engine maintains
        // for exactly this purpose (FrameResult.smoothedBbox doc: "Prefer this over
        // cardBbox for overlay rendering to reduce jitter").  The BBoxInterpolator (1€
        // filter at 60/120 Hz) in the overlay views further smooths the signal at
        // display rate — feeding it pre-smoothed input eliminates visible jitter.
        // Raw cardBbox is still used for autofocus targeting (triggerFocusIfNeeded /
        // triggerWeakFieldFocusIfNeeded) and the distance-hint area ratio, where the
        // unfiltered value is correct and latency matters more than sub-pixel precision.
        let boundsInView: CGRect? = result.hasCard && viewSize != .zero
            ? CoordinateTransformer.toViewSpace(
                bbox: result.smoothedBbox,
                imageSize: imageSize,
                rotationDegrees: 0,
                viewSize: viewSize,
                paddingFraction: _bboxPaddingFraction
              )
            : nil

        // Capture result.isFinished as a plain local — FrameResult is a struct, safe to read
        // from yoloQueue. The `finished` Bool is @MainActor-isolated; we must NOT read or
        // write it here on yoloQueue. The gate check and write are deferred to the Task below.
        let resultIsFinished = result.isFinished

        // Only create UIImage on the final frame (one-time cost).
        // FrameResult is a struct — safe to capture by value across queue hop.
        // We speculatively allocate the image when result says finished; the @MainActor
        // gate below discards it if another YOLO call already set finished = true first.
        let speculativeImage: UIImage? = resultIsFinished
            ? (fallbackImage ?? eng.imageFromBuffer(pixelBuffer))
            : nil

        Task { @MainActor [weak self] in
            guard let self else { return }

            // ── teardown gate ────────────────────────────────────────────────────
            // If teardownCamera() was called while this Task was queued, isClosed
            // is already true. Drop the frame entirely — touching frameState or
            // calling onFinished after teardown causes use-after-free / post-dismiss
            // callbacks (the "Done mid-scan crash" race).
            guard !self.isClosed else { return }

            // ── finished-flag gate (all reads/writes on @MainActor) ──────────────
            // Previous pattern wrote `finished = true` on yoloQueue — a data race because
            // `finished` is @MainActor-isolated and `reset()` writes it on @MainActor too.
            // Moving the gate here eliminates the race: both the check and the write are
            // always on the same actor, making the sequence atomic within the actor.
            let isNewlyFinished = resultIsFinished && !self.finished
            if isNewlyFinished { self.finished = true }

            // ── Side-gate reject: sticky COLOR, live POSITION ────────────────────
            // Position (bbox) is ALWAYS live — we never freeze it. The card may move
            // and the overlay must follow it smoothly. Only the COLOR is sticky:
            // it stays red while sideGateRejectActive, regardless of where the card is.
            //
            // No-card counter:
            //   • hasCard=true  → card still in frame, reset no-card counter.
            //   • hasCard=false → increment counter; when saturated the user has clearly
            //     removed the wrong card → clear reject state automatically.
            let effectiveBoundsInView: CGRect? = boundsInView  // always live

            // ── Guide frame gate ─────────────────────────────────────────────────
            // cardInGuide = true when guide is disabled OR when the card's view-space
            // bbox intersects the guide rect by ≥ 80 % of the card's own area.
            // When guide is enabled and cardInGuide=false the gate suppresses capture,
            // neutral/success colours, scan-line animation, and overrides the hint.
            // Renderer and gate use the SAME guideRect helper to stay in sync.
            let cardInGuide: Bool = {
                guard self.style.showGuideFrame else { return true }    // gate disabled
                guard let viewBounds = effectiveBoundsInView,
                      self.viewSize != .zero,
                      viewBounds.width > 0, viewBounds.height > 0 else { return false }
                let guide = ScannerOverlayRenderer.guideRect(
                    in: CGRect(origin: .zero, size: self.viewSize)
                )
                let inter = viewBounds.intersection(guide)
                guard !inter.isNull else { return false }
                let ratio = (inter.width * inter.height) / (viewBounds.width * viewBounds.height)
                return ratio >= 0.80
            }()

            if self.sideGateRejectActive {
                if result.hasCard {
                    // Card still present — reset no-card counter, keep reject color.
                    self.sideGateNoCardFrames = 0
                } else {
                    // Card gone this frame — increment no-card counter.
                    self.sideGateNoCardFrames += 1
                    if self.sideGateNoCardFrames >= self.kSideGateNoCardFramesToClear {
                        self.clearSideGateReject()
                    }
                }
            }

            // ── Side-gate state machine (SGSM) ──────────────────────────────────
            //
            // Runs only when liveVersionProbe + enforceSideMatch are both ON.
            // Drives ANALYZING animation, REJECT_WRONG_SIDE, and REJECT_UNKNOWN states.
            // Replaces the former separate `beginAnalyzing`/`clearAnalyzing` + per-frame
            // `liveGateMismatch` Optional — single authoritative SM for live probe UX.
            //
            // STEP 1: ANALYZING trigger (card appearance + flip detection).
            // STEP 2: New-verdict handling (probeSeq-gated).
            // STEP 3: Card-lost handling.

            let cardJustAppeared = result.hasCard && !self.wasCardVisible
            var liveGateMismatch: (title: String, hint: String)? = nil

            // Android parity: the SM runs whenever the live probe + side gate are on.
            // showAnalysisAnimation gates ONLY the ANALYZING visual (frameState
            // construction below: `isAnalyzing && showAnalysisAnimation`) — it must
            // NOT gate the reject/clear logic itself. With the flag inside this
            // condition, turning the animation off in settings silently killed both
            // the live wrong-side red AND its correct-verdict clearing: the sticky
            // red from a capture-veto could then only clear via the no-card counter.
            if self.configuration.liveVersionProbe,
               self.configuration.enforceSideMatch {

                // ── STEP 1: ANALYZING triggers ───────────────────────────────────
                if cardJustAppeared && !self.sideGateRejectActive {
                    // Fresh card appearance → start ANALYZING window.
                    self.sgsmBeginAnalyzing()
                    self.sgsmNotStillFrames = 0
                    self.sgsmWasStill       = result.cardIsStill
                    controllerLog.debug("side-gate sm: card appeared → ANALYZING")
                } else if result.hasCard {
                    // Flip detection: card was still, now not-still for kMotionFrames in a row.
                    if self.sgsmWasStill && !result.cardIsStill {
                        self.sgsmNotStillFrames += 1
                        if self.sgsmNotStillFrames >= self.kMotionFrames {
                            // User probably flipped the card → reset and wait for re-stabilisation.
                            self.sgsmBeginAnalyzing()
                            // Full clear (not just the flag): a bare `sideGateRejectActive = false`
                            // left the stale reject title/hint/no-card counter behind, so the old
                            // "Нужна … сторона" text could resurface after the flip.
                            if self.sideGateRejectActive { self.clearSideGateReject() }
                            self.sgsmNotStillFrames   = 0
                            controllerLog.info("side-gate sm: flip detected (\(self.kMotionFrames, privacy: .public) not-still frames) → ANALYZING")
                        }
                    } else {
                        self.sgsmNotStillFrames = 0
                    }
                    self.sgsmWasStill = result.cardIsStill
                }

                // ── STEP 2: New verdict (probeSeq changed) ───────────────────────
                // Bug 1 fix: use != instead of > so that a C++ probe_seq restart
                // (reset to 0 → 1,2,3,...) is detected even when the new seq is
                // smaller than the previously stored sgsmLastProbeSeq.
                // The != 0 guard skips the "no probe yet" sentinel value.
                let newSeq = result.probeSeq
                if newSeq != 0 && newSeq != self.sgsmLastProbeSeq {
                    self.sgsmLastProbeSeq = newSeq
                    let rawVerdict = result.probeLastVerdict   // -1=Unknown, 0..5=CardVersion

                    // Map raw int → CardVersion (same mapping as ios_bridge / MergenTypes)
                    let verdictVersion = CardVersion(rawValue: rawVerdict)  // nil → unknown equiv

                    let isUnknown = rawVerdict == -1 || verdictVersion == nil
                    let isCorrect: Bool = {
                        guard let v = verdictVersion else { return false }
                        return self.sideGateRejectReason(for: v) == nil
                    }()

                    if isCorrect {
                        // Correct side — advance correctStreak; wrong/unknown streaks reset.
                        self.sgsmWrongStreak   = 0
                        self.sgsmUnknownStreak = 0
                        self.sgsmCorrectStreak += 1
                        let correct = self.sgsmCorrectStreak
                        let prevState = self.sgsmState
                        let inReject: Bool
                        switch prevState {
                        case .rejectWrongSide, .rejectUnknown: inReject = true
                        default: inReject = false
                        }
                        if inReject && correct >= self.kCorrectStreak {
                            // Bug A fix: kCorrectStreak consecutive correct probes while in REJECT
                            // → exit reject immediately without waiting for card-absent counter.
                            self.sgsmState        = .normal
                            self.sgsmCorrectStreak = 0
                            self.sgsmTimeoutTask?.cancel()
                            self.sgsmTimeoutTask  = nil
                            if self.sideGateRejectActive { self.clearSideGateReject() }
                            controllerLog.info("side-gate sm: seq=\(newSeq, privacy: .public) raw=\(rawVerdict, privacy: .public) state=NORMAL correct=\(correct, privacy: .public) (sticky cleared via correct-verdict streak)")
                        } else if !inReject {
                            // NORMAL / ANALYZING: transition to NORMAL immediately on first correct verdict.
                            self.sgsmState        = .normal
                            self.sgsmCorrectStreak = 0
                            self.sgsmTimeoutTask?.cancel()
                            self.sgsmTimeoutTask  = nil
                            if self.sideGateRejectActive { self.clearSideGateReject() }
                            controllerLog.info("side-gate sm: seq=\(newSeq, privacy: .public) raw=\(rawVerdict, privacy: .public) state=NORMAL wrong=0 unk=0 (was=\(String(describing: prevState), privacy: .public))")
                        } else {
                            // Still in REJECT, correctStreak < kCorrectStreak — wait for more.
                            controllerLog.debug("side-gate sm: seq=\(newSeq, privacy: .public) raw=\(rawVerdict, privacy: .public) correct_streak=\(correct, privacy: .public)/\(self.kCorrectStreak, privacy: .public) (in reject, awaiting streak)")
                        }
                    } else if isUnknown {
                        self.sgsmCorrectStreak = 0
                        self.sgsmWrongStreak   = 0   // a confident wrong verdict resets this, not unknown
                        self.sgsmUnknownStreak += 1
                        let unk = self.sgsmUnknownStreak
                        if unk >= self.kUnknownStreak, result.cardIsStill {
                            self.sgsmState = .rejectUnknown
                            self.sgsmTimeoutTask?.cancel()
                            self.sgsmTimeoutTask = nil
                            controllerLog.info("side-gate sm: seq=\(newSeq, privacy: .public) raw=\(rawVerdict, privacy: .public) state=REJECT_UNKNOWN wrong=\(self.sgsmWrongStreak, privacy: .public) unk=\(unk, privacy: .public)")
                        } else {
                            // Not enough unknown streaks OR card is moving — stay ANALYZING.
                            if case .analyzing = self.sgsmState { } else { self.sgsmBeginAnalyzing() }
                            // Fail-open (mirror of the C++ capture-hold Unknown-release):
                            // a sticky red with NO fresh wrong-side evidence must not
                            // outlive an Unknown burst — after the flip the classifier
                            // often yields Unknowns (angle/glare), the correct-verdict
                            // exit never fires, and the red used to stick through the
                            // whole correct-side scan while the C++ hold released and
                            // capture proceeded ("рамка красная, но сканирует").
                            if self.sideGateRejectActive, unk >= 3 {
                                self.clearSideGateReject()
                                controllerLog.info("side-gate: sticky cleared — \(unk, privacy: .public) consecutive Unknown verdicts (fail-open)")
                            }
                            controllerLog.debug("side-gate sm: seq=\(newSeq, privacy: .public) raw=\(rawVerdict, privacy: .public) state=ANALYZING wrong=\(self.sgsmWrongStreak, privacy: .public) unk=\(unk, privacy: .public)")
                        }
                    } else {
                        // Wrong side (confident verdict, wrong direction).
                        self.sgsmCorrectStreak = 0
                        self.sgsmUnknownStreak = 0
                        self.sgsmWrongStreak  += 1
                        let wrong = self.sgsmWrongStreak
                        // Android parity (ScannerController.kt): REJECT_WRONG_SIDE requires
                        // cardIsStill — a moving card is most likely mid-flip, and m15 emits
                        // confident wrong-side verdicts on edge-on/rotating cards. Locking the
                        // sticky red during the flip made the hint lag behind the user
                        // ("Нужна лицевая сторона" stuck after flipping to the correct side).
                        // The streak keeps accumulating; the transition fires on the first
                        // wrong verdict that arrives while the card is still.
                        if (wrong >= self.kWrongStreak && result.cardIsStill) || wrong >= self.kWrongStreakMoving {
                            // Build the title from sideGateRejectReason (same source as capture-reject).
                            let title: String
                            if let v = verdictVersion, let reason = self.sideGateRejectReason(for: v) {
                                title = reason.title
                            } else {
                                title = "Неверная сторона"
                            }
                            self.sgsmState = .rejectWrongSide(title: title)
                            self.sgsmTimeoutTask?.cancel()
                            self.sgsmTimeoutTask = nil
                            controllerLog.info("side-gate sm: seq=\(newSeq, privacy: .public) raw=\(rawVerdict, privacy: .public) state=REJECT_WRONG_SIDE wrong=\(wrong, privacy: .public) unk=\(self.sgsmUnknownStreak, privacy: .public)")
                        } else if wrong >= self.kWrongStreak {
                            // Streak reached but card is moving (likely mid-flip) — defer the
                            // REJECT until the card is still again. Mirrors Android.
                            controllerLog.debug("side-gate sm: seq=\(newSeq, privacy: .public) raw=\(rawVerdict, privacy: .public) wrong=\(wrong, privacy: .public) REJECT deferred (card moving)")
                        } else {
                            // Single wrong — ignore, keep current state (ANALYZING or NORMAL).
                            controllerLog.debug("side-gate sm: seq=\(newSeq, privacy: .public) raw=\(rawVerdict, privacy: .public) state=ANALYZING(streak<\(self.kWrongStreak, privacy: .public)) wrong=\(wrong, privacy: .public) unk=\(self.sgsmUnknownStreak, privacy: .public)")
                        }
                    }
                }

                // ── STEP 3: Card lost ────────────────────────────────────────────
                if !result.hasCard {
                    if case .analyzing = self.sgsmState {
                        // Card gone while analyzing → abort window.
                        self.sgsmState = .normal
                        self.sgsmTimeoutTask?.cancel()
                        self.sgsmTimeoutTask = nil
                    }
                    // REJECT states persist until card-absent counter clears sideGateReject
                    // (handled below in the existing sideGateNoCardFrames block).
                    self.sgsmNotStillFrames = 0
                    self.sgsmWasStill       = false
                }
            }

            // Derive liveGateMismatch from SM state for downstream color/message logic.
            // This is the single authoritative source — no second code path needed.
            switch self.sgsmState {
            case .rejectWrongSide(let title):
                liveGateMismatch = (title: title, hint: "")
            case .rejectUnknown:
                liveGateMismatch = (title: "Сканируйте кыргызскую ID-карту", hint: "")
            case .analyzing, .normal:
                liveGateMismatch = nil
            }

            // ── Shooting-distance hint (soft gate: hysteresis + debounce) ────────
            // Computed from bbox area relative to full image area (sensor space).
            // Priority: side-gate reject > ANALYZING > distance > lighting > engine hint.
            // Gated by showCaptureTips. State machine is reset whenever card is absent /
            // state not detecting / hints disabled — next card appearance starts neutral.
            let distanceHint: String? = {
                guard self.configuration.showCaptureTips else {
                    self.resetDistanceHint(); return nil
                }
                guard result.hasCard else {
                    self.resetDistanceHint(); return nil
                }
                guard result.state == .detecting || result.state == .idle else {
                    self.resetDistanceHint(); return nil
                }
                guard !self.sideGateRejectActive,
                      !self.isAnalyzing,
                      liveGateMismatch == nil else {
                    self.resetDistanceHint(); return nil
                }
                let imgArea = CGFloat(result.imageWidth) * CGFloat(result.imageHeight)
                guard imgArea > 0 else { return nil }
                let bboxArea = result.cardBbox.width * result.cardBbox.height
                let ratio    = bboxArea / imgArea
                // Edge-clipping check: card actually overflows the frame (4 px margin).
                let clipping = result.cardBbox.minX < self.kBBoxEdgeMarginPx
                            || result.cardBbox.minY < self.kBBoxEdgeMarginPx
                            || result.cardBbox.maxX > CGFloat(result.imageWidth)  - self.kBBoxEdgeMarginPx
                            || result.cardBbox.maxY > CGFloat(result.imageHeight) - self.kBBoxEdgeMarginPx
                let hint = self.computeDistanceHint(ratio: ratio, clipping: clipping)
                return hint.isEmpty ? nil : hint
            }()

            // ── Lighting hint ─────────────────────────────────────────────────────
            // Only when no higher-priority message is active and card is visible.
            // Gated by showCaptureTips.
            var lightingHint: String? = nil
            if self.configuration.showCaptureTips,
               result.hasCard,
               result.state == .detecting || result.state == .idle,
               !self.sideGateRejectActive,
               !self.isAnalyzing,
               liveGateMismatch == nil,
               distanceHint == nil {
                if result.isGlared {
                    lightingHint = "Слишком ярко"
                } else if result.isDark {
                    lightingHint = "Слишком темно"
                }
            }

            // ── Auto-torch ────────────────────────────────────────────────────────
            // Mirrors Android auto-torch 1:1. Active only when config.autoTorch == true
            // and the user has not overridden the torch state manually.
            // Threshold: 8 consecutive dark+card YOLO frames → torch ON.
            // Clear:    30 consecutive no-card frames → torch OFF.
            if self.configuration.autoTorch, !self.userTorchOverride {
                if result.isDark && result.hasCard {
                    self.darkNoCardFrames = 0
                    self.darkStreak += 1
                    if self.darkStreak >= self.kDarkStreakThreshold, !self.autoTorchActive {
                        self.autoTorchActive = true
                        self.cameraSession.setTorch(true)
                        controllerLog.info("auto-torch ON (dark streak \(self.darkStreak, privacy: .public))")
                    }
                } else {
                    // Not (dark AND hasCard): reset the dark streak counter.
                    self.darkStreak = 0
                    // If torch is auto-active and card is gone, count no-card frames.
                    if !result.hasCard, self.autoTorchActive {
                        self.darkNoCardFrames += 1
                        if self.darkNoCardFrames >= self.kDarkNoCardClearFrames {
                            self.autoTorchActive  = false
                            self.darkNoCardFrames = 0
                            self.cameraSession.setTorch(false)
                            controllerLog.info("auto-torch OFF (card lost \(self.kDarkNoCardClearFrames, privacy: .public) frames)")
                        }
                    }
                }
            }

            let activeColor: Color = {
                // Priority 1: capture-reject sticky (from beginSideGateReject).
                // Evaluated AFTER the no-card counter check above so a just-cleared
                // reject falls through to lower priorities immediately.
                if self.sideGateRejectActive { return self.style.colorFailure }
                // Priority 2: ANALYZING window — neutral colour, no false red/green.
                if self.isAnalyzing { return self.style.colorDetecting }
                // Priority 3: live-probe detecting mismatch (reactive, no capture needed).
                if liveGateMismatch != nil { return self.style.colorFailure }
                // Priority 4: guide frame gate — card detected but outside guide.
                // Hold neutral colour; no green until card is positioned inside.
                if self.style.showGuideFrame && !cardInGuide && result.hasCard {
                    return self.style.colorDetecting
                }
                if result.cardIsStill && result.hasCard { return self.style.colorSuccess }
                switch result.state {
                case .idle:            return self.style.colorIdle
                case .detecting:       return self.style.colorDetecting
                case .captured,
                     .finishedSuccess: return self.style.colorSuccess
                case .finishedFailure: return self.style.colorFailure
                }
            }()
            // While the capture-reject OR live-probe mismatch is active, override the
            // C++ hint messages with the rejection text so the overlay shows the
            // actionable instruction.  Live mismatch takes precedence over capture-reject
            // because it is more current (fresh detecting frame vs stale capture bbox).
            // ANALYZING suppresses side-gate messages so the user sees a neutral overlay.
            let displayTitle: String
            let displayHint:  String
            if self.isAnalyzing {
                // Suppress all gate messages during the analyzing window.
                displayTitle = result.messageTitle
                displayHint  = result.messageHint
            } else if let live = liveGateMismatch {
                displayTitle = live.title
                displayHint  = live.hint
            } else if self.sideGateRejectActive {
                displayTitle = self.sideGateRejectTitle
                displayHint  = self.sideGateRejectHint
            } else if self.style.showGuideFrame && !cardInGuide {
                // Guide active: card absent or outside guide — show positioning instruction.
                // Higher priority than distance/lighting: those are irrelevant while the
                // card is not yet positioned in the guide area.
                if result.hasCard {
                    displayTitle = "Поместите карту в рамку"
                    displayHint  = ""
                } else {
                    displayTitle = ""
                    displayHint  = "Поместите карту в рамку"
                }
            } else if let dist = distanceHint {
                // Distance hint overrides the engine's generic hint.
                displayTitle = dist
                displayHint  = ""
            } else if let light = lightingHint {
                displayTitle = light
                displayHint  = ""
            } else {
                displayTitle = result.messageTitle
                displayHint  = result.messageHint
            }
            // effectiveBoundsInView is always the live boundsInView — derive hasCard from it.
            let effectiveHasCard = effectiveBoundsInView != nil || result.hasCard
            // isScanning: card visible + active engine state + no gate reject.
            // Drives scan-line animation for all scan sessions (not only SGSM/probe).
            // Suppressed when guide is active and card is outside guide — the scan-line
            // inside the bbox should not animate until the card is positioned correctly.
            let isScanning = self.configuration.showAnalysisAnimation
                && result.hasCard
                && (result.state == .detecting || result.state == .captured)
                && !self.sideGateRejectActive
                && liveGateMismatch == nil
                && !(self.style.showGuideFrame && !cardInGuide)
            self.frameState = ScannerFrameState(
                engineState:      result.state,
                hasCard:          effectiveHasCard,
                cardBoundsInView: effectiveBoundsInView,
                confidence:       result.confidence,
                progress:         result.progress,
                messageTitle:     displayTitle,
                messageHint:      displayHint,
                isFinished:       result.isFinished,
                isPassed:         result.isPassed,
                activeColor:      activeColor,
                captureTimestamp: captureTime,
                // Expose isAnalyzing only when the animation feature is enabled.
                // If disabled, the flag stays false → scan-line is never drawn.
                isAnalyzing:      self.isAnalyzing && self.configuration.showAnalysisAnimation,
                isScanning:       isScanning,
                isCardInGuide:    self.style.showGuideFrame && cardInGuide
            )

            // ── Derived public events (Phase A5) ──────────────────────────────
            // documentDetected: rising edge of hasCard, bounds already view-space.
            if result.hasCard, !self.wasCardVisible, let bounds = effectiveBoundsInView {
                self.emitEvent(.documentDetected(bounds: bounds))
            }
            self.wasCardVisible = result.hasCard
            self.lastYoloHasCard = result.hasCard   // gate for trackOnly positive publishes
            // processing: progress quantised to 0.1 buckets to avoid flooding consumers.
            let progressBucket = Int(result.progress * 10)
            if result.progress > 0, progressBucket != self.lastProgressBucket {
                self.lastProgressBucket = progressBucket
                self.emitEvent(.processing(progress: result.progress))
            }

            if isNewlyFinished {
                if self.style.showGuideFrame && !cardInGuide {
                    // Card captured outside the guide frame — discard silently.
                    // Re-open the finished gate and re-arm the C++ engine so the next
                    // frame restarts detection without any side effects on the overlay.
                    self.finished = false
                    self.engine?.reset()
                    self.stillCaptureRequested = false
                    self.processingQueue.async { [weak self] in self?.stillInFlight = false }
                    controllerLog.debug("guide-frame: capture outside guide discarded — engine re-armed")
                } else {
                    self.handleFinished(image: speculativeImage, result: result)
                }
            }

            // ── Still-photo capture trigger (v2.1 still-capture flow) ─────────
            // The engine attempted a capture on this video frame and the smart-
            // rescan gate blocked the finish (stillCaptureWanted). Snap ONE real
            // photo and run the OCR/MRZ pass on it instead of the blurred video
            // rescan loop. The instant-capture arms (Arm C / Arm C-front) finish
            // BEFORE this flag is ever set — easy cards never pay the photo cost.
            if result.stillCaptureWanted {
                // DEBUG chain: STILL: engine wants → (here) STILL: iOS requesting →
                //   CameraSession → STILL: photo WxH → STILL: engine result.
                controllerLog.info("STILL: engine wants still photo useStillCapture=\(self.configuration.useStillCapture, privacy: .public) alreadyRequested=\(self.stillCaptureRequested, privacy: .public) finished=\(self.finished, privacy: .public)")
            }
            if result.stillCaptureWanted,
               self.configuration.useStillCapture,
               !self.stillCaptureRequested,
               !self.finished,
               // While a side-gate reject is active a still photo is pointless (the
               // scene is the wrong side) AND harmful: stillInFlight suspends the
               // YOLO/probe loop, so the probes that would release the C++
               // capture-hold never run — a 2+ s deadlock until the watchdog.
               !self.sideGateRejectActive {
                self.stillCaptureRequested = true
                controllerLog.info("STILL: iOS requesting photo")
                self.beginStillCapture()
            }
        }
    }

    // ── Still-photo capture (v2.1 still-capture flow) ─────────

    /// Requests one high-res still from the camera; while it is in flight the
    /// video frames skip the YOLO/OCR pipeline (preview stays live via trackOnly).
    ///
    /// Watchdog: if neither the success path nor the error path resets `stillInFlight`
    /// within 1.8 s (e.g. AVFoundation skipped `didFinishProcessingPhoto` and the
    /// delegate-fallback `didFinishCaptureFor` also never fired — documented edge-case
    /// when the session is stopped mid-capture), the watchdog resets the flag so the
    /// video pipeline resumes. The watchdog is a no-op when the flag is already `false`
    /// (i.e. the normal path beat it). No branching changes to the success flow.
    ///
    /// Threading: `stillInFlight` is only accessed on `processingQueue` (serial) —
    /// the watchdog also dispatches onto `processingQueue` to stay consistent.
    private func beginStillCapture() {
        controllerLog.info("still-capture: rescan gate blocked — requesting photo")
        processingQueue.async { [weak self] in self?.stillInFlight = true }

        // Watchdog: arms immediately after setting the flag; fires 1.8 s later
        // on processingQueue. If the flag is already false by then, it is a no-op.
        // 1.8 s is chosen to exceed the AVFoundation still-capture latency budget
        // on all supported hardware (typical P99 < 800 ms) while being short enough
        // that a stuck front-side pipeline recovers within two scan seconds.
        processingQueue.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self else { return }
            if self.stillInFlight {
                self.stillInFlight = false
                // PII-free diagnostic: flag state only, no frame content.
                controllerLog.warning("still-capture watchdog fired — stillInFlight was stuck, pipeline resumed")
            }
        }

        cameraSession.capturePhoto { [weak self] image in
            // Called on processingQueue (guaranteed by CameraSession.capturePhoto).
            guard let self else { return }
            guard let image else {
                // Photo failed / session closed — resume the video rescan loop.
                // Watchdog may also reset this, but explicit reset here is faster
                // and guarantees immediate recovery on the normal failure path.
                self.stillInFlight = false
                return
            }
            self.yoloQueue.async { [weak self] in
                self?.processStillPhoto(image)
            }
        }
    }

    /// Runs the engine's capture pipeline on the still (yoloQueue — serialized
    /// with the video YOLO path). The still's bbox is in photo coordinates and
    /// is intentionally NOT published to frameState.
    ///
    /// Sharpness gate: after processStillFrame, the cropped card image is measured
    /// for sharpness (variance of Laplacian).  A blurry crop is rejected and
    /// `stillCaptureRequested` is reset so the engine can trigger another still on
    /// the next `stillCaptureWanted` frame.  After `kSharpnessMaxAttempts` rejections
    /// the sharpest crop seen is accepted unconditionally.
    private func processStillPhoto(_ photo: UIImage) {
        guard let eng = engine else {
            processingQueue.async { [weak self] in self?.stillInFlight = false }
            return
        }
        // Cap at the gallery-path long edge (2048) — same proven input contract
        // as processGalleryTwoSided; also normalizes EXIF orientation to .up.
        let still = Self.downscaledForGallery(photo)
        controllerLog.info("STILL: photo \(Int(still.size.width))x\(Int(still.size.height)) — sending to engine")
        let result = eng.processStillFrame(image: still)

        // Reopen the video pipeline first: if the still didn't finish the scan,
        // the rescan loop continues seamlessly on the next YOLO-interval frame.
        processingQueue.async { [weak self] in self?.stillInFlight = false }

        guard let result else {
            // Symbol missing (stale binary) or engine gone — video-only fallback.
            controllerLog.error("still-capture: processStillFrame unavailable — falling back to video loop")
            return
        }
        controllerLog.info("STILL: engine result finished=\(result.isFinished, privacy: .public) passed=\(result.isPassed, privacy: .public) conf=\(String(format: "%.2f", result.confidence), privacy: .public)")

        guard result.isFinished else { return }   // gate still blocked — video loop resumes

        // ── Sharpness gate ────────────────────────────────────────────────────
        // Measure crop sharpness on yoloQueue before hopping to @MainActor.
        // getLastCroppedCardImage is thread-safe (C++ returns a copy).
        let crop      = eng.getLastCroppedCardImage()
        let sharpness: Float = crop.map { Self.laplacianVariance($0) } ?? 0

        Task { @MainActor [weak self] in
            guard let self, !self.isClosed else { return }

            // Track the sharpest crop seen across all attempts this side.
            if sharpness > self.bestSharpness {
                self.bestSharpness       = sharpness
                self.bestSharpnessImage  = still
                self.bestSharpnessResult = result
            }
            self.sharpnessAttemptCount += 1

            let accepted = sharpness >= self.kSharpnessThreshold
            controllerLog.info("[sharpness] crop=\(Int(sharpness), privacy: .public) threshold=\(Int(self.kSharpnessThreshold), privacy: .public) attempt=\(self.sharpnessAttemptCount, privacy: .public)/\(self.kSharpnessMaxAttempts, privacy: .public) \(accepted ? "accepted" : "rejected", privacy: .public)")

            if !accepted && self.sharpnessAttemptCount < self.kSharpnessMaxAttempts {
                // Blurry crop and budget remains — allow another still on the next
                // engine trigger.  The video loop is already resumed (stillInFlight=false
                // above); resetting stillCaptureRequested unblocks beginStillCapture.
                self.stillCaptureRequested = false
                return
            }

            // Either sharp enough, or budget exhausted — pick the best crop seen.
            let finalImage: UIImage
            let finalResult: FrameResult
            if accepted {
                finalImage  = still
                finalResult = result
            } else {
                // Budget exhausted — accept best; log the fallback for diagnostics.
                controllerLog.warning("[sharpness] budget exhausted — accepting best crop sharpness=\(Int(self.bestSharpness), privacy: .public) after \(self.sharpnessAttemptCount, privacy: .public) attempts")
                finalImage  = self.bestSharpnessImage  ?? still
                finalResult = self.bestSharpnessResult ?? result
            }

            // Side-gate: handleFinished manages the reject path internally.
            // Do NOT pre-set finished=true here — handleFinished's gate branch
            // re-arms the engine WITHOUT setting finished, so the scan continues.
            let isNewlyFinished = !self.finished
            if isNewlyFinished { self.finished = true }
            if isNewlyFinished {
                // handleFinished may reset `finished` back to false internally
                // (via beginSideGateReject → engine.reset()) when the gate fires.
                self.handleFinished(image: finalImage, result: finalResult)
            }
        }
    }

    // ── Distance-hint state machine helpers (@MainActor) ──────────────────────

    /// Debounced, hysteretic distance hint.
    ///
    /// Maps the current bbox coverage `ratio` and edge-`clipping` to a committed
    /// distance hint, applying hysteresis and an enter/clear debounce so the hint
    /// doesn't flicker on small movements. Mirrors Android `ScannerController.distanceHint()`.
    ///
    /// - Returns: "Отодвиньте дальше", "Поднесите ближе", or "" (no hint).
    private func computeDistanceHint(ratio: CGFloat, clipping: Bool) -> String {
        // Instantaneous target, with hysteresis relative to the committed state.
        let raw: Int
        switch distState {
        case 1:
            raw = (ratio < kBBoxRatioCloseExit && !clipping) ? 0 : 1
        case -1:
            raw = (ratio > kBBoxRatioFarExit) ? 0 : -1
        default:
            if ratio > kBBoxRatioTooClose || clipping {
                raw = 1
            } else if ratio < kBBoxRatioTooFar {
                raw = -1
            } else {
                raw = 0
            }
        }
        if raw == distState {
            distPendingCount = 0
        } else {
            if raw == distPending {
                distPendingCount += 1
            } else {
                distPending      = raw
                distPendingCount = 1
            }
            let need = (raw == 0) ? kDistanceClearFrames : kDistanceEnterFrames
            if distPendingCount >= need {
                distState        = raw
                distPendingCount = 0
            }
        }
        switch distState {
        case  1: return "Отодвиньте дальше"
        case -1: return "Поднесите ближе"
        default: return ""
        }
    }

    /// Resets distance-hint state to neutral (ok, no pending transition).
    /// Called whenever the card disappears, the engine leaves detecting state,
    /// or capture hints are disabled — so the next card appearance starts neutral.
    private func resetDistanceHint() {
        distState = 0; distPending = 0; distPendingCount = 0
    }

    // ── Side/generation gate helpers (@MainActor) ─────────────

    /// Returns a non-nil reject reason string when the gate should block this capture,
    /// or `nil` when the capture is accepted.
    ///
    /// The gate fires only when `configuration.enforceSideMatch == true`.
    /// `.unknown` CardVersion always fails the gate (classifier did not fire).
    private func sideGateRejectReason(for version: CardVersion) -> (title: String, hint: String)? {
        guard configuration.enforceSideMatch else { return nil }

        // 1. Unknown version — classifier did not fire (poor quality, unrecognised).
        if version == .unknown {
            let r = (
                title: "Сканируйте кыргызскую ID-карту",
                hint:  ""
            )
            controllerLog.info("side-gate: REJECT unknown version")
            return r
        }

        // 2. Side mismatch.
        let isFrontVersion = version == .front2008 || version == .front2017 || version == .front2025
        let isBackVersion  = version == .back2008  || version == .back2017  || version == .back2025
        let expected = configuration.expectedSide
        if expected == .front, !isFrontVersion {
            // Expected front but got back version — user must flip to show front.
            let r = (
                title: "Нужна лицевая сторона",
                hint:  ""
            )
            controllerLog.info("side-gate: REJECT expected=front got=\(String(describing: version), privacy: .public)")
            return r
        }
        if expected == .back, !isBackVersion {
            // Expected back but got front version — user must flip to show back.
            let r = (
                title: "Нужна обратная сторона",
                hint:  ""
            )
            controllerLog.info("side-gate: REJECT expected=back got=\(String(describing: version), privacy: .public)")
            return r
        }

        // 3. Generation mismatch (optional).
        if let gen = configuration.expectedGeneration, !gen.isEmpty {
            let versionYear: String
            switch version {
            case .front2008, .back2008: versionYear = "2008"
            case .front2017, .back2017: versionYear = "2017"
            case .front2025, .back2025: versionYear = "2025"
            case .unknown:              versionYear = ""
            }
            if !versionYear.isEmpty, versionYear != gen {
                let r = (
                    title: "Разные документы",
                    hint:  ""
                )
                controllerLog.info("side-gate: REJECT gen mismatch expected=\(gen, privacy: .public) got=\(versionYear, privacy: .public)")
                return r
            }
        }

        let acceptedSide = configuration.expectedSide
        let acceptedGen  = configuration.expectedGeneration ?? "nil"
        controllerLog.debug("side-gate: ACCEPT version=\(String(describing: version), privacy: .public) expected=\(String(describing: acceptedSide), privacy: .public) gen=\(acceptedGen, privacy: .public)")
        return nil  // accepted
    }

    /// Rejects the current capture: paints bbox red (sticky COLOR, live POSITION) and
    /// re-arms the engine for the next attempt. Mirrors the Android "same-side
    /// re-scan" pattern in `ScannerController.kt`.
    ///
    /// Called on @MainActor. The `finished` flag is deliberately NOT set — the
    /// scan continues after the reject.
    ///
    /// The bbox COLOR stays red (sideGateRejectActive) until:
    ///   • The card disappears from frame for `kSideGateNoCardFramesToClear` consecutive
    ///     YOLO frames (user moved the card away), OR
    ///   • A live-probe detecting frame confirms the correct side is now visible (early
    ///     clear in the live-version-probe block of process()), OR
    ///   • A subsequent capture PASSES the gate (handled naturally: `sideGateRejectActive`
    ///     is cleared in `clearSideGateReject()` before `handleFinished` proceeds).
    ///
    /// The bbox POSITION is always live — it follows the card; it is never frozen.
    private func beginSideGateReject(title: String, hint: String) {
        controllerLog.info("side-gate: rejected capture — \(title, privacy: .public)")
        sideGateRejectActive  = true
        sideGateRejectTitle   = title
        sideGateRejectHint    = hint
        sideGateNoCardFrames  = 0

        // Reopen the finished gate so the next capture attempt can be processed.
        // `finished` may have been set to true in process() or processStillPhoto()
        // before handleFinished() was called; the gate branch must undo that.
        finished = false

        // Position is no longer frozen — bbox follows the card live.
        // Only the COLOR is held red via sideGateRejectActive.
        // Force frameState to show the reject colour + message immediately
        // (using the current bbox position as-is, not freezing it).
        sgsmClear()  // reject terminates the SGSM (analyzing window + streaks) immediately
        let cur = frameState
        frameState = ScannerFrameState(
            engineState:      cur.engineState,
            hasCard:          cur.hasCard,
            cardBoundsInView: cur.cardBoundsInView,
            confidence:       cur.confidence,
            progress:         cur.progress,
            messageTitle:     title,
            messageHint:      hint,
            isFinished:       false,
            isPassed:         false,
            activeColor:      style.colorFailure,
            captureTimestamp: cur.captureTimestamp,
            isAnalyzing:      false,
            isCardInGuide:    cur.isCardInGuide
        )

        // Re-arm the C++ engine for the next attempt immediately.
        engine?.reset()
        stillCaptureRequested = false
        processingQueue.async { self.stillInFlight = false }
        // No asyncAfter timer — the reject clears via state-driven logic in process().
    }

    /// Clears the side-gate reject state, allowing normal colour/message rendering.
    /// Called from process() when the no-card counter saturates.
    private func clearSideGateReject() {
        sideGateRejectActive  = false
        sideGateRejectTitle   = ""
        sideGateRejectHint    = ""
        sideGateLastBBox      = nil
        sideGateNoCardFrames  = 0
        controllerLog.info("side-gate: reject cleared — card absent long enough")
    }

    // ── Finalization (camera path) ────────────────────────────

    private func handleFinished(image: UIImage?, result: FrameResult) {
        // ── Side/generation gate ──────────────────────────────────────────────────
        // Applied BEFORE the isPassed check so that a wrong-side capture that the
        // engine deems "passed" (e.g. back side scanned when front was expected)
        // is still intercepted.  The reject arms a 1.5-s cooldown and re-arms the
        // engine; `finished` stays false and the scan continues.
        if let reject = sideGateRejectReason(for: result.cardVersion) {
            beginSideGateReject(title: reject.title, hint: reject.hint)
            return
        }

        // The capture PASSED the gate — a stale sticky red (armed by an earlier
        // wrong-side attempt) must not colour the successful finish. This is the
        // exit path the beginSideGateReject() doc always promised ("a subsequent
        // capture PASSES the gate") but never actually implemented.
        if sideGateRejectActive { clearSideGateReject() }

        guard let eng = engine else {
            deliverFinished(MergenIdResult(
                success: false, croppedImage: nil, originalImage: image,
                confidence: 0, errorCode: 1, errorMessage: "Engine released",
                cardVersion: .unknown, isFlipped: false, fieldProgressJson: ""
            ))
            return
        }
        guard result.isPassed else {
            deliverFinished(MergenIdResult(
                success: false, croppedImage: nil, originalImage: image,
                confidence: result.confidence, errorCode: 1, errorMessage: result.failReason,
                cardVersion: result.cardVersion, isFlipped: result.isFlipped, fieldProgressJson: ""
            ))
            return
        }
        finalizer.finalize(
            engine:        eng,
            originalImage: image,
            frameResult:   result,
            isLean:        configuration.leanIdentityFields
        ) { [weak self] sdkResult in
            self?.deliverFinished(sdkResult)
        }
    }

    // ── OF-only tracking (every frame) ────────────────────────

    /// OF-only track: updates cardBoundsInView without running YOLO.
    /// Called from processingQueue on frames that skip full processing.
    private func trackOnly(
        pixelBuffer: CVPixelBuffer,
        engine: MergenEngine,
        captureTime: TimeInterval
    ) {
        guard let result = engine.processFrameTrackOnly(pixelBuffer) else { return }

        let imageSize = CGSize(
            width:  CGFloat(CVPixelBufferGetWidth(pixelBuffer)),
            height: CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        )
        // Use smoothedBbox (C++ EMA-filtered) for the same reason as in process() —
        // the raw cardBbox jitters between OF frames; smoothedBbox is stable.
        let bounds: CGRect? = (result.hasCard && viewSize != .zero)
            ? CoordinateTransformer.toViewSpace(
                bbox: result.smoothedBbox,
                imageSize: imageSize,
                rotationDegrees: 0,
                viewSize: viewSize,
                paddingFraction: _bboxPaddingFraction
              )
            : nil

        // Read on processingQueue (owner of stillInFlight) before hopping to main.
        // While a still photo is captured/OCR'd the Kalman track-only prediction has no
        // fresh detection to correct it and drifts over the ~2 s window, making the
        // overlay bbox "stand in the wrong place". Hold the last real position instead.
        let holdBboxForStill = self.stillInFlight

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished, !self.isClosed else { return }
            let cur = self.frameState

            // Positive publish only when BOTH the OF track sees the card AND the most
            // recent YOLO frame confirmed it (lastYoloHasCard). After YOLO said
            // "no card", a stale OF track may coast for up to YOLO_INTERVAL-1 frames —
            // without this gate those frames resurrected the overlay in a 4:1
            // true/false flicker ("ghost bbox" after the card was removed).
            if let bounds, self.lastYoloHasCard {
                self.frameState = ScannerFrameState(
                    engineState:      cur.engineState,
                    hasCard:          true,
                    cardBoundsInView: holdBboxForStill ? cur.cardBoundsInView : bounds,
                    confidence:       cur.confidence,
                    progress:         cur.progress,
                    messageTitle:     cur.messageTitle,
                    messageHint:      cur.messageHint,
                    isFinished:       cur.isFinished,
                    isPassed:         cur.isPassed,
                    activeColor:      cur.activeColor,
                    captureTimestamp: captureTime,
                    isAnalyzing:      cur.isAnalyzing,
                    // Was omitted → defaulted to false on 4 of 5 frames while process()
                    // published true → scan-line animation flickered at ~6 Hz.
                    isScanning:       cur.isScanning,
                    isCardInGuide:    cur.isCardInGuide
                )
            } else if cur.hasCard {
                // Android parity: the Kotlin controller publishes hasCard=false on
                // EVERY frame. The previous silent early-return here left the last
                // hasCard=true state (bbox + scan animation) on screen indefinitely
                // once the card left the frame between YOLO ticks.
                self.frameState = ScannerFrameState(
                    engineState:      cur.engineState,
                    hasCard:          false,
                    cardBoundsInView: nil,
                    confidence:       0,
                    progress:         cur.progress,
                    messageTitle:     cur.messageTitle,
                    messageHint:      cur.messageHint,
                    isFinished:       cur.isFinished,
                    isPassed:         cur.isPassed,
                    activeColor:      cur.activeColor,
                    captureTimestamp: captureTime,
                    isAnalyzing:      cur.isAnalyzing,
                    isScanning:       false,
                    isCardInGuide:    false
                )
            }
        }
    }

    // ── Constants ─────────────────────────────────────────────

    /// Run full YOLO pipeline every N-th frame; all other frames use OF tracking only.
    /// At 30 fps: YOLO_INTERVAL=5 → YOLO ~6 fps, OF ~24 fps.
    private let YOLO_INTERVAL = 5
}

// ── Gallery Vision OCR helper ─────────────────────────────────────────────────
//
// Intentional parallel to ScanFinalizer's per-field Vision pass.
//
// WHY NOT shared with ScanFinalizer:
//   ScanFinalizer is @MainActor and async (camera path). Sharing its internal
//   implementation with the gallery background thread would require either making
//   ScanFinalizer nonisolated (breaking its actor contract) or introducing a
//   Task{} + continuation into the synchronous gallery loop (deadlock risk on the
//   32 MB thread when the task executor is busy). The gallery path needs a
//   SYNCHRONOUS, non-actor-isolated call; the camera path needs an ASYNC,
//   @MainActor call. The two threading models are fundamentally different, so a
//   deliberate parallel is the safer design. If this logic changes, update BOTH.
//
// Threading contract:
//   Called from the gallery 32 MB background thread (com.mergen.gallery.two-sided).
//   Blocks on DispatchSemaphore.wait() until VisionOCR completes.
//   VisionOCR dispatches onto its OWN serial queue (idcardsdk.vision_ocr) — a
//   DIFFERENT queue from the calling thread — so the semaphore.wait() on the
//   calling thread cannot deadlock VisionOCR's completion handler.
//
// PII safety: counts only are logged via diag?(); no field values are logged.

// Lean-mode field id set for the gallery Vision OCR path.
// MUST stay in sync with ScanFinalizer.leanFieldIds.
// Verified against C++ enum class FieldId (card_field_coords.h):
//   DocNumber      = 6   ("doc_number")
//   PersonalNumber = 11  ("personal_number")
//   MRZ            = 12  (handled in the fid==12 branch)
private let _galleryLeanFieldIds: Set<Int> = [6, 11, 12]

@available(iOS 13.0, *)
private func _galleryVisionOCRJson(
    engine: MergenEngine,
    crop:   UIImage,
    isLean: Bool = false
) -> String? {
    // ── fieldId → JSON key mapping (MUST stay in sync with ScanFinalizer.fieldKeyMap) ──
    let fieldKeyMap: [Int: String] = [
        0:  "last_name",
        1:  "first_name",
        2:  "patronymic",
        3:  "gender",
        4:  "nationality",
        5:  "birth_date",
        6:  "doc_number",
        7:  "expiry_date",
        8:  "birth_place",
        9:  "issued_by",
        10: "issue_date",
        11: "personal_number",
        // fieldId 12 = MRZ zone — handled separately below
        13: "last_name_lat",
        14: "first_name_lat",
    ]

    let fields = engine.getDetectedFields()
    // PII-free: field ids and counts only, never values.
    controllerLog.info("gallery vision: FD fields=\(fields.count, privacy: .public) ids=\(fields.map { String($0.fieldId) }.joined(separator: ","), privacy: .public) lean=\(isLean, privacy: .public)")

    // ── Fallback: full-crop heuristic Vision pass when no field detections ──
    if fields.isEmpty {
        let sema = DispatchSemaphore(value: 0)
        var result: String? = nil
        let visionOCR = VisionOCR()
        visionOCR.recognize(card: crop) { json in
            if let j = json, !j.isEmpty, j != "{}" { result = j }
            sema.signal()
        }
        sema.wait()
        controllerLog.info("gallery vision: fallback full-crop pass -> \(result == nil ? "empty" : "non-empty", privacy: .public)")
        return result
    }

    guard let cgCrop = crop.cgImage else { return nil }

    let visionOCR  = VisionOCR()
    let group      = DispatchGroup()
    var fieldResults: [String: String] = [:]
    let lock       = NSLock()

    for field in fields {
        let fid  = field.fieldId
        let bbox = field.bbox
        guard bbox.width > 20, bbox.height > 8 else { continue }

        // Lean-mode gate: skip Vision passes for non-lean fields.
        // The C++ accumulator already discards non-lean votes when
        // lean_identity_fields=true, so these passes are pure waste.
        // Lean fields: DocNumber(6), PersonalNumber(11), MRZ(12).
        if isLean && !_galleryLeanFieldIds.contains(fid) { continue }

        // Clamp field bbox to crop pixel bounds.
        let x = max(0, Int(bbox.origin.x))
        let y = max(0, Int(bbox.origin.y))
        let w = min(cgCrop.width  - x, Int(bbox.width))
        let h = min(cgCrop.height - y, Int(bbox.height))
        guard w > 10, h > 5 else { continue }
        guard let fieldCG = cgCrop.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { continue }

        // Upscale small crops — VNRecognizeTextRequest performs best on images >= 32×32 px.
        let minDim: CGFloat = 32
        let fieldImg = UIImage(cgImage: fieldCG)
        let fieldToRecognize: UIImage
        if CGFloat(fieldCG.width) < minDim || CGFloat(fieldCG.height) < minDim {
            let scale = max(minDim / CGFloat(fieldCG.width), minDim / CGFloat(fieldCG.height), 1.0)
            let newW  = Int(CGFloat(fieldCG.width)  * scale)
            let newH  = Int(CGFloat(fieldCG.height) * scale)
            UIGraphicsBeginImageContextWithOptions(CGSize(width: newW, height: newH), false, 1)
            fieldImg.draw(in: CGRect(x: 0, y: 0, width: newW, height: newH))
            fieldToRecognize = UIGraphicsGetImageFromCurrentImageContext() ?? fieldImg
            UIGraphicsEndImageContext()
        } else {
            fieldToRecognize = fieldImg
        }

        if fid == 12 {
            // MRZ zone: read all lines, filter to A-Z/0-9/<, split into mrz_line1/2/3.
            // Use en-US only: MRZ is strictly Latin+digits+<. ru-RU produces Cyrillic
            // homoglyphs (К, О, etc.) that must be stripped — suppressing the source
            // is cleaner and improves recall by giving Vision a single-language model
            // optimised for Latin characters.
            group.enter()
            visionOCR.recognizeRawText(image: fieldToRecognize,
                                       languages: ["en-US"]) { text in
                defer { group.leave() }
                guard let t = text, !t.isEmpty else { return }
                let mrzLines = t.components(separatedBy: .whitespacesAndNewlines)
                    .map { $0.filter { $0.isLetter || $0.isNumber || $0 == "<" }.uppercased() }
                    .filter { $0.count >= 20 }
                lock.lock()
                if mrzLines.count >= 1 { fieldResults["mrz_line1"] = mrzLines[0] }
                if mrzLines.count >= 2 { fieldResults["mrz_line2"] = mrzLines[1] }
                if mrzLines.count >= 3 { fieldResults["mrz_line3"] = mrzLines[2] }
                lock.unlock()
            }
        } else if let key = fieldKeyMap[fid] {
            // Regular field: raw-text recognizer — field type already known from field detector.
            // For structured Latin/digit-only fields (doc_number fid=6, personal_number fid=11)
            // use en-US only: ru-RU produces Cyrillic homoglyphs that reduce gate pass-through.
            // All other fields (names, dates, etc.) keep ["en-US", "ru-RU"] for Cyrillic reads.
            let fieldLanguages: [String] = _galleryLeanFieldIds.contains(fid)
                ? ["en-US"]
                : ["en-US", "ru-RU"]
            group.enter()
            visionOCR.recognizeRawText(image: fieldToRecognize,
                                       languages: fieldLanguages) { text in
                defer { group.leave() }
                guard let t = text, !t.isEmpty else { return }
                // Guard against card header leakage — real KG ID field values are <= 40 chars.
                guard t.count <= 40 else { return }
                // Format gate (Android parity): drop malformed doc#/PIN Vision reads so a
                // misread can't outvote the correct internal read. Shared with the live path.
                guard let value = ScanFinalizer.validatedExternalField(key: key, raw: t) else { return }
                lock.lock()
                fieldResults[key] = value
                lock.unlock()
            }
        }
        // fieldIds without a mapping are silently skipped.
    }

    // Block the gallery background thread until all VisionOCR callbacks have fired.
    // VisionOCR runs on its own queue (idcardsdk.vision_ocr); no deadlock risk here.
    group.wait()

    // PII-free: only which keys survived the gates, not their values.
    controllerLog.info("gallery vision: injected keys=[\(fieldResults.keys.sorted().joined(separator: ","), privacy: .public)]")

    // Field NAMES and value lengths always; the values themselves only under `piiTrace`
    // (see internal/PiiTrace.swift).
    ocrTraceControllerLog.debug("[vision/gate-pass] \(fieldResults.count, privacy: .public) fields passed gate:")
    for (k, v) in fieldResults.sorted(by: { $0.key < $1.key }) {
        if piiTrace {
            ocrTraceControllerLog.debug("[vision/gate-pass] key=\(k, privacy: .public) val=\(v, privacy: .public)")
        } else {
            ocrTraceControllerLog.debug("[vision/gate-pass] key=\(k, privacy: .public) val=\(piiLen(v), privacy: .public)")
        }
    }

    guard !fieldResults.isEmpty else { return nil }

    // Serialize to the same minimal JSON format ScanFinalizer uses.
    let json = fieldResults.map { k, v in
        let esc = v
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(k)\":\"\(esc)\""
    }.joined(separator: ",")
    let finalJson = "{\(json)}"
    // The payload is a JSON object of recognised field VALUES — PII. Size only by default.
    if piiTrace {
        ocrTraceControllerLog.debug("[vision/addExternalOCR-json] \(finalJson, privacy: .public)")
    } else {
        ocrTraceControllerLog.debug("[vision/addExternalOCR-json] \(finalJson.utf8.count, privacy: .public) bytes, \(fieldResults.count, privacy: .public) keys")
    }
    return finalJson
}
