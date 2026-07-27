import SwiftUI
import AVFoundation
import CoreMotion

// ─────────────────────────────────────────────────────────────────────────────
// Primary SwiftUI view — full scanner with default overlay
// ─────────────────────────────────────────────────────────────────────────────

/// Drop-in SwiftUI scanner view.
///
/// **Simplest usage:**
/// ```swift
/// MergenScannerView(licenseKey: myLicense) { result in
///     // handle result
/// }
/// ```
///
/// **Custom overlay** (state is already in view coordinates — no math needed):
/// ```swift
/// MergenScannerView(
///     licenseKey: myLicense,
///     style: ScannerStyle { $0.bboxDrawStyle = .none }
/// ) { result in
///     // handle result
/// } customOverlay: { state in
///     if let bounds = state.cardBoundsInView {
///         MyAnimatedCardFrame(bounds: bounds, color: state.activeColor)
///     }
/// }
/// ```
///
/// - Parameters:
///   - licenseKey:    SDK license JSON string.
///   - configuration: Engine settings (detection thresholds, etc.).
///   - style:         Full visual style.
///   - onFinished:    Called once when detection finishes (success or failure).
///   - onError:       Called on initialization or runtime error.
///   - customOverlay: Fully custom overlay. Receives `ScannerFrameState` with
///                    `cardBoundsInView` already in view coordinates.
///                    When provided the default overlay is suppressed entirely.
public struct MergenScannerView<Overlay: View>: View {

    private let licenseKey:    String
    private let configuration: MergenScannerConfig
    private let style:         ScannerStyle
    private let onFinished:    (MergenIdResult) -> Void
    private let onError:       ((Error) -> Void)?
    private let onEvent:       ((ScannerEvent) -> Void)?
    private let customOverlay: ((ScannerFrameState) -> Overlay)?

    @StateObject private var controller: ScannerEngineController

    // ── Initialisers ──────────────────────────────────────────

    public init(
        licenseKey:    String,
        configuration: MergenScannerConfig  = .init(),
        style:         ScannerStyle                = .init(),
        onFinished:    @escaping (MergenIdResult) -> Void,
        onError:       ((Error) -> Void)?          = nil,
        onEvent:       ((ScannerEvent) -> Void)?   = nil,
        @ViewBuilder customOverlay: @escaping (ScannerFrameState) -> Overlay
    ) {
        var cfg = configuration
        cfg.licenseKey = licenseKey
        self.licenseKey    = licenseKey
        self.configuration = cfg
        self.style         = style
        self.onFinished    = onFinished
        self.onError       = onError
        self.onEvent       = onEvent
        self.customOverlay = customOverlay
        // FIX (task #14): obtain the controller from MergenEnginePool so that a prior
        // warmUp(license:leanFields:useUnifiedDetector:) call shares ONE engine with this
        // SwiftUI view.  Constructing ScannerEngineController directly here bypassed the
        // pool and caused a second MergenEngine to be allocated (~230 MB peak + a second
        // AES decrypt) alongside the already-warm pooled engine — a jetsam risk on 2 GB
        // devices.  MergenEnginePool is @MainActor; SwiftUI View inits run on the main thread.
        // FIX (useUnifiedDetector): pass cfg.useUnifiedDetector so the pool key matches
        // the warmUp() call — previously the flag was omitted, forcing pool to default
        // (false) and creating a SECOND engine (m1+m9) instead of reusing the warm m15 one.
        _controller = StateObject(wrappedValue: MergenEnginePool.controller(
            for: licenseKey,
            leanFields: cfg.leanIdentityFields,
            useUnifiedDetector: cfg.useUnifiedDetector
        ))
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // ── Camera preview ────────────────────────────
                // Pass captureSession (a @Published property) so SwiftUI
                // re-renders CameraPreviewRepresentable when it becomes non-nil.
                CameraPreviewRepresentable(
                    controller: controller,
                    session: controller.captureSession
                )
                .ignoresSafeArea()

                // ── Overlay ───────────────────────────────────
                if let custom = customOverlay {
                    custom(controller.frameState)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScannerOverlayRepresentable(
                        state: controller.frameState,
                        style: style
                    )
                    .ignoresSafeArea()
                }

            }
            .onAppear {
                controller.updateViewSize(geo.size)
                controller.updateStyle(style)
                controller.onFinished = onFinished
                controller.onError    = onError
                controller.onEvent    = onEvent
                // Inject side/generation gate from the caller's configuration into the
                // pooled controller.  MergenEnginePool creates the controller with a
                // default config (enforceSideMatch = false); the gate fields must be
                // patched here on every appear so that:
                //   • A warmUp()-then-scan flow applies the caller's gate on first appear.
                //   • A front→back transition (same pooled controller, new expectedSide /
                //     expectedGeneration) updates the gate for the back-side scan.
                // applySideGate() touches only the three gate fields; all other config
                // values (lens, resolution, lean mode) are preserved from pool creation.
                controller.applySideGate(config: configuration)
                // Reset clears `finished = true` (set by the FRONT scan) so that the
                // BACK scan's deliverFrame() is not gated out immediately.
                // This is the fix for the front→back black-preview regression:
                //   1. Front scans, sets finished=true, onDisappear fires → teardownCamera().
                //   2. Back MVCameraSideView appears → onAppear fires on the SAME pooled
                //      controller. Without reset(), finished stays true → every frame is
                //      dropped → camera preview works but nothing is processed.
                // reset() also calls engine?.reset() which clears C++ pipeline state,
                // which is required before starting a new scan side.
                controller.reset()
                controller.prepare()
            }
            .onDisappear {
                // Tear down the camera session when the view leaves the screen.
                // teardownCamera() stops the capture session AND nils all
                // AVFoundation objects so that the next onAppear → prepare() call
                // unconditionally rebuilds a fresh AVCaptureSession.
                //
                // This fixes the "laggy back camera" issue in the two-sided verify
                // flow: previously stop() only called stopRunning() — the session
                // object was kept alive, and CameraSession.setup()'s idempotent
                // guard (`guard captureSession == nil else { return }`) prevented
                // rebuild on the back-side appear.  The stale, warm session caused
                // a stuttering preview on the back side.
                //
                // IMPORTANT: teardownCamera() does NOT deallocate the engine or
                // evict the pool entry.  The pooled ScannerEngineController (and its
                // MergenEngine) remain alive so that warmUp() or another presentation
                // of this view reuses the warm engine without a second cold model load.
                //
                // Bug 2 fix: call stop() first (async, non-blocking) to queue
                // stopRunning on processingQueue before teardownCamera() dispatches
                // its own teardown block. For SwiftUI sheets/navigation, onDisappear
                // fires AFTER the dismiss animation completes, so the ordering here
                // is belt-and-braces rather than critical-path — mirrors UIKit fix.
                controller.stop()
                controller.teardownCamera()
            }
            .onChange(of: geo.size) { controller.updateViewSize($0) }
            .onChange(of: geo.size) { _ in controller.updateStyle(style) }
        }
    }
}

// ── Convenience init without custom overlay ───────────────────

extension MergenScannerView where Overlay == EmptyView {
    public init(
        licenseKey:    String,
        configuration: MergenScannerConfig = .init(),
        style:         ScannerStyle               = .init(),
        onFinished:    @escaping (MergenIdResult) -> Void,
        onError:       ((Error) -> Void)?         = nil,
        onEvent:       ((ScannerEvent) -> Void)?  = nil
    ) {
        var cfg = configuration
        cfg.licenseKey = licenseKey
        self.licenseKey    = licenseKey
        self.configuration = cfg
        self.style         = style
        self.onFinished    = onFinished
        self.onError       = onError
        self.onEvent       = onEvent
        self.customOverlay = nil   // nil → shows ScannerOverlayRepresentable (UIKit CGContext)
        // FIX (task #14): obtain from pool — mirrors the custom-overlay init above.
        // FIX (useUnifiedDetector): pass cfg.useUnifiedDetector — same key as warmUp().
        _controller = StateObject(wrappedValue: MergenEnginePool.controller(
            for: licenseKey,
            leanFields: cfg.leanIdentityFields,
            useUnifiedDetector: cfg.useUnifiedDetector
        ))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Headless — Observable state handle only, no preset UI
// ─────────────────────────────────────────────────────────────────────────────

/// Provides live `ScannerFrameState` without imposing any UI structure.
/// Use when you want to build the camera preview and overlay entirely yourself.
///
/// ```swift
/// @StateObject var scanner = MergenScannerStateHandle(licenseKey: myLicense)
///
/// var body: some View {
///     ZStack {
///         CameraPreviewView(layer: scanner.previewLayer)
///         MyFullyCustomOverlay(state: scanner.frameState)
///     }
///     .onAppear { scanner.startScanning() }
/// }
/// ```
@MainActor
public final class MergenScannerStateHandle: ObservableObject {

    @Published public private(set) var frameState: ScannerFrameState = .empty

    public var onFinished: ((MergenIdResult) -> Void)?
    public var onError:    ((Error) -> Void)?
    /// Optional per-event callback (Phase A5): cameraReady / documentDetected /
    /// processing / success / error. Legacy callbacks keep firing unchanged.
    public var onEvent:    ((ScannerEvent) -> Void)?

    public var previewLayer: AVCaptureVideoPreviewLayer? { controller.previewLayer }

    /// Named scanner events as an `AsyncStream` (Phase A5). Each access creates a
    /// NEW independent stream — store it once and iterate. Mirrors Android
    /// `ScannerStateHandle.events` (Flow).
    public var events: AsyncStream<ScannerEvent> { controller.makeEventStream() }

    private let controller: ScannerEngineController
    /// Guards the Combine frameState pipeline against duplicate subscriptions
    /// when start/startScanning is called more than once.
    private var frameStateSubscribed = false

    public init(
        licenseKey:    String,
        configuration: MergenScannerConfig = .init(),
        style:         ScannerStyle               = .init()
    ) {
        controller = ScannerEngineController(configuration: configuration, style: style)
        controller.onFinished = { [weak self] r in self?.onFinished?(r) }
        controller.onError    = { [weak self] e in self?.onError?(e) }
        controller.onEvent    = { [weak self] ev in self?.onEvent?(ev) }
    }

    /// Starts (or resumes) camera scanning. Canonical name since v2.1 — same
    /// contract on Android. Set the view size first via `updateViewSize(_:)`
    /// (or use the deprecated `start(viewSize:)` convenience).
    ///
    /// Permission (Phase A7): with `handlePermissionsInternally = false` this never
    /// requests camera access — if not authorized it emits `onError` /
    /// `ScannerEvent.error(MergenError.cameraPermissionDenied)` and returns.
    public func startScanning() {
        controller.prepare()
        ensureFrameStateSubscription()
    }

    /// Pauses frame delivery (camera stops running; the session and engine stay
    /// warm). Resume with `startScanning()`. Canonical name since v2.1.
    public func stopScanning() { controller.stop() }

    /// Terminal camera teardown: stops the session and releases all AVFoundation
    /// objects. The engine stays warm for a subsequent `startScanning()`, which
    /// rebuilds a fresh capture session. Same contract as Android
    /// `ScannerStateHandle.release`.
    public func release() { controller.teardownCamera() }

    /// Torch (flashlight) control — Phase A1. The desired state persists across
    /// background/foreground pauses and resets when the camera is torn down.
    public func setFlashlightEnabled(_ enabled: Bool) {
        controller.setFlashlightEnabled(enabled)
    }

    /// Pre-v2.1 name.
    @available(*, deprecated, renamed: "startScanning()",
               message: "Use updateViewSize(_:) + startScanning() — renamed for cross-platform consistency (Phase A6).")
    public func start(viewSize: CGSize = .zero) {
        controller.updateViewSize(viewSize)
        startScanning()
    }

    /// Pre-v2.1 name.
    @available(*, deprecated, renamed: "stopScanning()",
               message: "Renamed for cross-platform consistency (Phase A6).")
    public func stop() { stopScanning() }

    public func updateViewSize(_ size: CGSize) { controller.updateViewSize(size) }
    public func updateStyle(_ style: ScannerStyle) { controller.updateStyle(style) }
    public func reset() { controller.reset() }

    /// Process a static gallery image without starting the camera.
    /// Result is delivered via `onFinished` callback on the main thread.
    public func processGalleryImage(_ image: UIImage) {
        controller.processGalleryImage(image)
    }

    /// Forward published changes via Combine (iOS 14+). Subscribed exactly once —
    /// pre-v2.1 `start()` re-subscribed on every call, stacking pipelines.
    private func ensureFrameStateSubscription() {
        guard !frameStateSubscribed else { return }
        frameStateSubscribed = true
        controller.$frameState
            .receive(on: DispatchQueue.main)
            .assign(to: &$frameState)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Camera preview (UIViewRepresentable)
// ─────────────────────────────────────────────────────────────────────────────

internal struct CameraPreviewRepresentable: UIViewRepresentable {
    let controller: ScannerEngineController
    /// Passed explicitly so SwiftUI detects the change (it's @Published on the controller).
    let session: AVCaptureSession?

    func makeUIView(context: Context) -> CameraPreviewHostView {
        let view = CameraPreviewHostView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: CameraPreviewHostView, context: Context) {
        uiView.previewLayer = controller.previewLayer
    }
}

/// UIView subclass that keeps previewLayer filling its bounds via layoutSubviews.
/// This guarantees the layer frame is set AFTER Auto Layout has resolved bounds.
internal final class CameraPreviewHostView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            guard let layer = previewLayer, layer !== oldValue else { return }
            oldValue?.removeFromSuperlayer()
            layer.videoGravity = .resizeAspectFill
            self.layer.insertSublayer(layer, at: 0)
            setNeedsLayout()
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Default overlay — UIViewRepresentable wrapping ScannerOverlayRenderer
//
// Deliberately avoids SwiftUI's conditional-view / ForEach state machinery,
// which can crash on rapid frameState updates (30 fps) in iOS betas.
// ScannerOverlayRenderer draws everything in a single CGContext pass.
// ─────────────────────────────────────────────────────────────────────────────

internal struct ScannerOverlayRepresentable: UIViewRepresentable {
    let state: ScannerFrameState
    let style: ScannerStyle

    func makeUIView(context: Context) -> _ScannerOverlayDrawView {
        let v = _ScannerOverlayDrawView()
        v.isUserInteractionEnabled      = false
        v.accessibilityElementsHidden   = true
        return v
    }

    func updateUIView(_ uiView: _ScannerOverlayDrawView, context: Context) {
        uiView.update(state: state, style: style)
    }
}

internal final class _ScannerOverlayDrawView: UIView {
    private var state: ScannerFrameState = .empty
    private var style: ScannerStyle      = .init()
    private let renderer                 = ScannerOverlayRenderer()
    // BBoxSpringAnimator replaces BBoxInterpolator: critically-damped spring at
    // vsync rate (60 fps) instead of One Euro Filter. Settles in ~85 ms vs the
    // ~400 ms One Euro convergence time at minCutoff=0.4 — eliminates the "jump
    // and freeze" pattern when C++ smoothedBbox updates at 6–10 Hz.
    // BBoxInterpolator (and OneEuro inside it) is kept for the custom-overlay path.
    private let bboxSpring               = BBoxSpringAnimator()
    private let gyroTracker              = GyroscopeTracker()

    // ── Scan-line visibility debounce ────────────────────────────────────────
    // CACurrentMediaTime() when isScanning||isAnalyzing was last true.
    // The scan line stays visible for 300 ms after this flag drops to false,
    // suppressing brief flickers during inter-analysis gaps (6–10 Hz engine rate).
    private var scanLineLastVisibleAt: TimeInterval = -.infinity

    // ── Фикс A: CA scan-line layer ───────────────────────────────────────────
    // A CAGradientLayer inside a clipping container bounces vertically inside
    // the bbox. The render-server drives the CABasicAnimation independently of
    // the main thread — the line keeps moving smoothly even when the CPU is
    // saturated by OCR inference at end-of-scan.
    private var scanLineContainerLayer: CALayer?
    private var scanLineGradientLayer:  CAGradientLayer?
    private let kCALineHeight: CGFloat  = 3.0   // pt — matches former kScanLineHeight
    private let kCALineAlpha:  CGFloat  = 0.85  // matches former kScanLineAlpha

    // ── Фикс B: bbox draw-hold ───────────────────────────────────────────────
    // Last non-nil cardBoundsInView and its expiry time. In draw() we substitute
    // this rect when the spring goes nil within the hold window (≤350 ms), hiding
    // brief detection flickers without touching BBoxSpringAnimator inputs.
    private var bboxHoldRect:          CGRect?
    private var bboxHoldUntil:         TimeInterval = -.infinity
    private let kBBoxHoldDuration:     TimeInterval = 0.350

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque        = false
        // Spring drives redraws at vsync rate — no separate timer needed.
        bboxSpring.start { [weak self] in self?.setNeedsDisplay() }
        gyroTracker.start()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(state: ScannerFrameState, style: ScannerStyle) {
        self.state = state
        self.style = style
        bboxSpring.setTarget(state.cardBoundsInView, captureTimestamp: state.captureTimestamp)
        // Refresh the debounce clock while the engine is actively scanning.
        if state.isScanning || state.isAnalyzing {
            scanLineLastVisibleAt = CACurrentMediaTime()
        }

        // ── Фикс B: update bbox draw-hold ────────────────────────────────────
        if let bbox = state.cardBoundsInView {
            bboxHoldRect  = bbox
            bboxHoldUntil = CACurrentMediaTime() + kBBoxHoldDuration
        }
        // Clear hold on side-change / scan completion so the previous side's
        // rect never bleeds into the next scan.
        if state.isFinished {
            bboxHoldRect  = nil
            bboxHoldUntil = -.infinity
        }

        // ── Фикс A: CA scan-line layer lifecycle ─────────────────────────────
        // Create the layer when the scan begins; destroy it after the 300 ms
        // debounce window closes. The layer frame is kept in sync at vsync rate
        // inside draw() via applyScanLineLayerFrame().
        let now      = CACurrentMediaTime()
        let scanLive = (now - scanLineLastVisibleAt) < 0.30
        if scanLive, let bbox = state.cardBoundsInView {
            if scanLineContainerLayer == nil {
                makeScanLineLayer(bbox: bbox, style: style)
            } else {
                updateScanLineColors(style: style)
            }
        } else if !scanLive {
            removeScanLineLayer()
        }
        // When scanLive but bbox is currently nil (brief engine gap inside the
        // debounce window): keep the existing layer at its previous frame —
        // applyScanLineLayerFrame() will re-sync once spring produces a rect.
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let viewBounds = self.bounds

        // Spring-smoothed bbox (BBoxSpringAnimator ticks via DisplayLink → setNeedsDisplay).
        var smoothedBBox = bboxSpring.smoothedBounds

        // ── Фикс B: bbox draw-hold ───────────────────────────────────────────
        // When the spring goes nil (brief detection gap) but we are still within
        // the 350 ms hold window, substitute the last known rect. This suppresses
        // sub-350 ms flickers without any change to BBoxSpringAnimator inputs or
        // setTarget() calls.
        if smoothedBBox == nil {
            let holdNow = CACurrentMediaTime()
            if holdNow < bboxHoldUntil {
                smoothedBBox = bboxHoldRect
            }
        }

        // Apply optional gyroscope offset (phone rotation between analysis frames).
        let viewW = viewBounds.width
        if let box = smoothedBBox, gyroTracker.isAvailable, viewW > 0 {
            let (pitch, yaw) = gyroTracker.consumeDelta()
            if pitch != 0 || yaw != 0 {
                let fovRad: CGFloat = .pi / 3   // ≈ 60° horizontal FoV
                let pxPerRad = viewW / fovRad
                smoothedBBox = box.offsetBy(dx: -yaw * pxPerRad, dy: -pitch * pxPerRad)
            }
        }

        // ── Фикс A: sync CA scan-line frame at vsync rate ────────────────────
        // Container frame tracks the spring-smoothed bbox so the clipping rect
        // and the CG bbox border stay aligned at 60/120 fps.
        if let bbox = smoothedBBox, scanLineContainerLayer != nil {
            applyScanLineLayerFrame(bbox)
        }

        let smoothedState = ScannerFrameState(
            engineState:      state.engineState,
            hasCard:          smoothedBBox != nil,
            cardBoundsInView: smoothedBBox,
            confidence:       state.confidence,
            progress:         state.progress,
            messageTitle:     state.messageTitle,
            messageHint:      state.messageHint,
            isFinished:       state.isFinished,
            isPassed:         state.isPassed,
            activeColor:      state.activeColor,
            captureTimestamp: state.captureTimestamp,
            isAnalyzing:      state.isAnalyzing,
            // CG scan-line disabled — CA layer drives it (Фикс A). Pass false so
            // ScannerOverlayRenderer.drawScanLine is never reached even if the
            // commented-out block in draw() is re-enabled.
            isScanning:       false,
            isCardInGuide:    state.isCardInGuide
        )
        renderer.draw(in: ctx, bounds: viewBounds, state: smoothedState, style: style)
    }

    override func removeFromSuperview() {
        gyroTracker.stop()
        bboxSpring.stop()
        removeScanLineLayer()
        super.removeFromSuperview()
    }

    // ── CA scan-line layer helpers (Фикс A) ──────────────────────────────────

    /// Creates the container + gradient layers and starts the bounce animation.
    /// Called from update() on the first frame where the scan line should be visible.
    private func makeScanLineLayer(bbox: CGRect, style: ScannerStyle) {
        // Container clips the gradient to the bbox rect.
        let container = CALayer()
        container.masksToBounds = true
        layer.addSublayer(container)

        let lineH = kCALineHeight
        let base  = UIColor(style.colorDetecting).withAlphaComponent(kCALineAlpha)
        let faded = UIColor(style.colorDetecting).withAlphaComponent(0)

        // Horizontal gradient: fades at both ends, opaque in the middle —
        // matches the drawScanLine() CG gradient (locations 0/0.2/0.8/1.0).
        let grad = CAGradientLayer()
        grad.startPoint = CGPoint(x: 0, y: 0.5)
        grad.endPoint   = CGPoint(x: 1, y: 0.5)
        grad.colors     = [faded.cgColor, base.cgColor, base.cgColor, faded.cgColor]
        grad.locations  = [0, 0.2, 0.8, 1.0]
        grad.bounds     = CGRect(origin: .zero, size: CGSize(width: bbox.width, height: lineH))
        grad.position   = CGPoint(x: bbox.width / 2, y: lineH / 2)
        container.addSublayer(grad)

        // Bounce position.y inside the container height. duration=0.6 s is the
        // half-period (0→top, 0.6→bottom, 1.2→top) matching kScanLinePeriod=1.2 s.
        let anim             = CABasicAnimation(keyPath: "position.y")
        anim.fromValue       = lineH / 2
        anim.toValue         = bbox.height - lineH / 2
        anim.duration        = 0.6
        anim.autoreverses    = true
        anim.repeatCount     = .infinity
        anim.timingFunction  = CAMediaTimingFunction(name: .linear)
        anim.isRemovedOnCompletion = false
        grad.add(anim, forKey: "scanLineBounce")

        scanLineContainerLayer = container
        scanLineGradientLayer  = grad

        // Set initial frame without implicit animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bbox
        CATransaction.commit()
    }

    /// Updates gradient colours when style changes (no animation restart needed).
    private func updateScanLineColors(style: ScannerStyle) {
        guard let grad = scanLineGradientLayer else { return }
        let base  = UIColor(style.colorDetecting).withAlphaComponent(kCALineAlpha)
        let faded = UIColor(style.colorDetecting).withAlphaComponent(0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grad.colors = [faded.cgColor, base.cgColor, base.cgColor, faded.cgColor]
        CATransaction.commit()
    }

    /// Synchronises the CA layer frame with the spring-smoothed bbox. Called from
    /// draw() at vsync rate. The CABasicAnimation on position.y uses absolute
    /// fromValue/toValue, so updating model-layer position.x and bounds.width here
    /// does not restart or jitter the bounce animation.
    private func applyScanLineLayerFrame(_ bbox: CGRect) {
        guard let container = scanLineContainerLayer,
              let grad      = scanLineGradientLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bbox
        let lineH   = kCALineHeight
        let newW    = bbox.width
        grad.bounds  = CGRect(origin: .zero, size: CGSize(width: newW, height: lineH))
        // Preserve model position.y unchanged — the animation overrides it in the
        // presentation layer. Only x needs updating when bbox width shifts.
        grad.position = CGPoint(x: newW / 2, y: grad.position.y)
        CATransaction.commit()
    }

    /// Removes and nils the CA scan-line sublayers. Safe to call multiple times.
    private func removeScanLineLayer() {
        scanLineContainerLayer?.removeFromSuperlayer()
        scanLineContainerLayer = nil
        scanLineGradientLayer  = nil
    }
}
