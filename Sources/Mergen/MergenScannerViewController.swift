import UIKit
import AVFoundation
import PhotosUI

// ─────────────────────────────────────────────────────────────────────────────
// Delegate
// ─────────────────────────────────────────────────────────────────────────────

public protocol MergenScannerDelegate: AnyObject {
    func idCardScanner(_ scanner: MergenScannerViewController, didFinish result: MergenIdResult)
    func idCardScannerDidCancel(_ scanner: MergenScannerViewController)
    func idCardScanner(_ scanner: MergenScannerViewController, didFail error: Error)
}

public extension MergenScannerDelegate {
    func idCardScanner(_ scanner: MergenScannerViewController, didFail error: Error) {}
    func idCardScannerDidCancel(_ scanner: MergenScannerViewController) {}
}

// ─────────────────────────────────────────────────────────────────────────────
// MergenScannerViewController
// ─────────────────────────────────────────────────────────────────────────────

/// UIKit drop-in view controller for ID card scanning.
///
/// **Present modally:**
/// ```swift
/// let vc = MergenScannerViewController(licenseKey: myLicense)
/// vc.delegate = self
/// present(vc, animated: true)
/// ```
///
/// **Customise style:**
/// ```swift
/// let vc = MergenScannerViewController(
///     licenseKey: myLicense,
///     style: ScannerStyle { $0.bboxDrawStyle = .cornersOnly }
/// )
/// ```
///
/// **Programmatic result + style — no delegate:**
/// ```swift
/// let vc = MergenScannerViewController(licenseKey: myLicense)
/// vc.onFinished = { [weak self] result in self?.handle(result) }
/// ```
///
/// **Custom overlay renderer (full Canvas control):**
/// ```swift
/// vc.customOverlayRenderer = { canvas, state, w, h in
///     // state.cardBoundsInView is already in view coordinates
///     guard let rect = state.cardBoundsInView else { return }
///     myPaint.setStroke()
///     UIBezierPath(ovalIn: rect).stroke()
/// }
/// ```
public final class MergenScannerViewController: UIViewController {

    // ── Public API ────────────────────────────────────────────

    public weak var delegate: MergenScannerDelegate?
    public var onFinished:     ((MergenIdResult) -> Void)?
    public var onError:        ((Error) -> Void)?
    /// Optional per-event callback (Phase A5): cameraReady / documentDetected /
    /// processing / success / error. The legacy `onFinished`/`onError`/delegate
    /// callbacks keep firing unchanged.
    public var onEvent:        ((ScannerEvent) -> Void)?
    public var customOverlayRenderer: ScannerUIOverlayRenderer?

    /// Named scanner events as an `AsyncStream` (Phase A5). Each access creates a
    /// NEW independent stream — store it once and iterate. Mirrors Android
    /// `MergenScannerView.events` (Flow).
    public var events: AsyncStream<ScannerEvent> { controller.makeEventStream() }

    public private(set) var configuration: MergenScannerConfig
    public var style: ScannerStyle {
        didSet { controller.updateStyle(style); overlayView.style = style }
    }

    // ── Internal ──────────────────────────────────────────────

    private let controller:      ScannerEngineController
    private var overlayView:     ScannerOverlayUIView!
    private var previewContainer: UIView!
    /// Overlay polling timer — kept so repeated startScanning() calls don't stack timers.
    private var overlayTimer:    Timer?
    /// Bug 2 fix: one-shot guard so closeTapped() cannot fire twice (double-tap on
    /// the ✕ button) before the VC is dismissed. Without this, delegate would be
    /// notified twice and stop() would queue two async stopRunning blocks.
    private var isCancelScheduled = false

    // ── Init ──────────────────────────────────────────────────

    public init(
        licenseKey:    String,
        configuration: MergenScannerConfig = .init(),
        style:         ScannerStyle               = .init()
    ) {
        var cfg = configuration
        cfg.licenseKey = licenseKey
        self.configuration = cfg
        self.style = style
        // FIX: obtain the controller from MergenEnginePool so that a prior warmUp(license:)
        // call shares ONE engine with this VC.  Creating ScannerEngineController directly here
        // bypassed the pool and caused a second MergenEngine to be allocated (~230 MB peak +
        // two 86 MB AES decrypts) alongside the already-warm pooled engine — a jetsam risk
        // on 2 GB devices.  MergenEnginePool is @MainActor; UIKit VCs are always initialised
        // on the main thread so the call is safe here.
        // leanIdentityFields defaults to false for the live-scan VC path (full-field OCR).
        // If the caller has already warmed a leanFields=false engine the pool returns it;
        // a leanFields=true warmUp creates a new controller (correct — different config).
        // FIX (useUnifiedDetector): pass cfg.useUnifiedDetector so the pool key matches
        // the warmUp() call — previously the flag was omitted, forcing pool to default
        // (false) and creating a SECOND engine (m1+m9) instead of reusing the warm m15 one.
        self.controller = MergenEnginePool.controller(
            for: licenseKey,
            leanFields: cfg.leanIdentityFields,
            useUnifiedDetector: cfg.useUnifiedDetector
        )
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(licenseKey:configuration:style:)") }

    // ── Lifecycle ─────────────────────────────────────────────

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()

        controller.onFinished = { [weak self] result in
            guard let self else { return }
            self.onFinished?(result)
            self.delegate?.idCardScanner(self, didFinish: result)
        }
        controller.onError = { [weak self] error in
            guard let self else { return }
            self.onError?(error)
            self.delegate?.idCardScanner(self, didFail: error)
        }
        controller.onEvent = { [weak self] event in
            self?.onEvent?(event)
        }

        #if targetEnvironment(simulator)
        showSimulatorPlaceholder()
        #else
        requestCameraAndStart()
        #endif
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        controller.previewLayer?.frame = view.bounds
        overlayView.frame = view.bounds
        controller.updateViewSize(view.bounds.size)
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop the overlay polling timer — startScanning() re-creates it on restart.
        overlayTimer?.invalidate()
        overlayTimer = nil
        // Use teardownCamera() instead of stop() so that:
        // 1. isClosed is set before any pending Tasks/callbacks fire.
        // 2. The AVCaptureVideoDataOutput delegate is removed before stopRunning().
        // 3. The capture session is fully torn down so the next viewDidAppear
        //    rebuilds a fresh AVCaptureSession (no stale-session black preview).
        controller.teardownCamera()
    }

    // ── Public controls ───────────────────────────────────────

    public func reset()       { controller.reset() }

    /// Starts (or restarts) scanning. Canonical name since v2.1 — same contract on
    /// Android (`MergenScannerView.startScanning`).
    ///
    /// Permission (Phase A7): with `configuration.handlePermissionsInternally = false`
    /// this method never requests camera access — if not authorized it emits
    /// `onError` / `ScannerEvent.error(MergenError.cameraPermissionDenied)` and returns.
    public func startScanning() {
        #if targetEnvironment(simulator)
        return
        #else
        requestCameraAndStart()
        #endif
    }

    /// Pauses frame delivery (camera stops running; the session and engine stay
    /// warm). Resume with `startScanning()`. Canonical name since v2.1.
    public func stopScanning() { controller.stop() }

    /// Pre-v2.1 name.
    @available(*, deprecated, renamed: "stopScanning()",
               message: "Renamed for cross-platform consistency (Phase A6).")
    public func stopScanner() { stopScanning() }

    /// Terminal camera teardown: stops the session and releases all AVFoundation
    /// objects. The warm engine stays pooled (`MergenEnginePool`) for the next
    /// scanner presentation. Same contract as Android `MergenScannerView.release()`.
    public func release() { controller.teardownCamera() }

    /// Torch (flashlight) control — Phase A1. The desired state persists across
    /// background/foreground pauses and resets when the camera is torn down.
    public func setFlashlightEnabled(_ enabled: Bool) {
        controller.setFlashlightEnabled(enabled)
    }

    // ── UI setup ──────────────────────────────────────────────

    private func setupUI() {
        view.backgroundColor = .black

        // Camera preview layer placeholder view.
        // NOTE: previewLayer is nil here — prepare() hasn't been called yet.
        // The layer is attached in attachPreviewLayer() after prepare() returns.
        previewContainer = UIView(frame: view.bounds)
        previewContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(previewContainer)

        // Overlay view
        overlayView = ScannerOverlayUIView(frame: view.bounds)
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.style = style
        overlayView.customRenderer = customOverlayRenderer
        view.addSubview(overlayView)

        // Close button
        let closeBtn = UIButton(type: .system)
        closeBtn.setTitle("✕", for: .normal)
        closeBtn.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
        closeBtn.setTitleColor(.white, for: .normal)
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeBtn)
        NSLayoutConstraint.activate([
            closeBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeBtn.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            closeBtn.widthAnchor.constraint(equalToConstant: 44),
            closeBtn.heightAnchor.constraint(equalToConstant: 44),
        ])

        // Gallery button (bottom-right)
        let galleryBtn = UIButton(type: .system)
        let galleryImage = UIImage(systemName: "photo.on.rectangle.angled")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        galleryBtn.setImage(galleryImage, for: .normal)
        galleryBtn.tintColor = .white
        galleryBtn.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        galleryBtn.layer.cornerRadius = 24
        galleryBtn.clipsToBounds = true
        galleryBtn.addTarget(self, action: #selector(galleryTapped), for: .touchUpInside)
        galleryBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(galleryBtn)
        NSLayoutConstraint.activate([
            galleryBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            galleryBtn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            galleryBtn.widthAnchor.constraint(equalToConstant: 48),
            galleryBtn.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    @objc private func closeTapped() {
        // Bug 2 fix: guard against double-tap before the VC is dismissed.
        guard !isCancelScheduled else { return }
        isCancelScheduled = true

        // Stop camera frame delivery immediately (non-blocking: async dispatch to
        // processingQueue). Queuing stopRunning HERE — before dismiss(animated:)
        // triggers viewWillDisappear — gives AVFoundation a head start to stop the
        // session concurrently with the dismiss animation setup. This prevents a
        // render-pipeline synchronisation stall on the main thread that would
        // otherwise delay the start of the dismiss animation by up to ~300 ms.
        controller.stop()

        // Notify delegate and kick off the dismiss animation immediately —
        // no heavy cleanup before this point.
        delegate?.idCardScannerDidCancel(self)
        dismiss(animated: true)
        // Full camera teardown (nil AVFoundation refs, isClosed = true) is handled
        // by teardownCamera() inside viewWillDisappear — which fires synchronously
        // at the start of the dismiss transition. The session is already stopping
        // by then (stop() above), so teardown's second stopRunning is a quick no-op.
    }

    /// DEPRECATED PATH (v2.1 → removed in v3.0): the SDK-embedded PHPicker gallery
    /// button leaves the core artifact — per the v3.0 "flexible tool" contract the
    /// host app presents its own picker and hands the image to the SDK via the
    /// public analyze path (`MergenScannerStateHandle.processGalleryImage(_:)` /
    /// `analyzeImage`). A client-owned reference picker lives in MergenSampleiOS
    /// (`SampleVerifyFlow.swift`). See docs/dev/migration-v3.md.
    @objc private func galleryTapped() {
        if !Self.didLogGalleryDeprecation {
            Self.didLogGalleryDeprecation = true
            NSLog("[Mergen] DEPRECATED: the built-in gallery picker of " +
                  "MergenScannerViewController is removed in v3.0. Present your own " +
                  "PHPicker and pass the UIImage to the SDK (processGalleryImage / " +
                  "analyzeImage) — see docs/dev/migration-v3.md.")
        }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    /// One-time guard for the gallery-deprecation runtime warning.
    private static var didLogGalleryDeprecation = false

    // ── Camera permission + start ─────────────────────────────

    private func requestCameraAndStart() {
        // Phase A7: check-only mode — the SDK never triggers the system permission
        // prompt or the Settings alert. The host app owns the permission UX and
        // receives the denial via onError / delegate / ScannerEvent.error.
        guard configuration.handlePermissionsInternally else {
            if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                startScanner()
            } else {
                controller.deliverError(MergenError.cameraPermissionDenied)
            }
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startScanner()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.startScanner() }
                    else { self?.handlePermissionDenied() }
                }
            }
        default:
            handlePermissionDenied()
        }
    }

    private func startScanner() {
        controller.prepare()
        // prepare() → setupCamera() runs synchronously on @MainActor,
        // so previewLayer is non-nil immediately after prepare() returns.
        attachPreviewLayer()
        startOverlayUpdates()
    }

    private func attachPreviewLayer() {
        guard let layer = controller.previewLayer else { return }
        layer.videoGravity = .resizeAspectFill
        layer.frame = previewContainer.bounds
        previewContainer.layer.insertSublayer(layer, at: 0)
    }

    private func startOverlayUpdates() {
        // Poll published frameState using Timer at ~30 Hz — no Combine required in UIKit path
        overlayTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let state = self.controller.frameState
            self.overlayView.update(state: state)
            if self.customOverlayRenderer == nil {
                self.overlayView.customRenderer = self.customOverlayRenderer
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        overlayTimer = timer
    }

    private func handlePermissionDenied() {
        let alert = UIAlertController(
            title: "Camera Access Required",
            message: "Please enable camera access in Settings.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            guard let self else { return }
            self.delegate?.idCardScannerDidCancel(self)
            self.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    // ── Simulator placeholder ─────────────────────────────────

    #if targetEnvironment(simulator)
    private func showSimulatorPlaceholder() {
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)
        let label = UILabel()
        label.text = "ID Card Scanner\nnot available on Simulator.\nRun on a physical device."
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }
    #endif
}

// ─────────────────────────────────────────────────────────────────────────────
// PHPicker delegate — DEPRECATED PATH (v2.1), removed in v3.0 together with the
// built-in gallery button. Host apps present their own picker and call the
// public analyze path instead. See docs/dev/migration-v3.md.
// ─────────────────────────────────────────────────────────────────────────────

extension MergenScannerViewController: PHPickerViewControllerDelegate {
    @available(*, deprecated, message: "SDK-embedded gallery picker is removed in v3.0 — present your own PHPicker and pass the image to processGalleryImage/analyzeImage; see docs/dev/migration-v3.md")
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] image, _ in
            guard let image = image as? UIImage else { return }
            DispatchQueue.main.async {
                self?.controller.processGalleryImage(image)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Custom overlay renderer interface (UIKit)
// ─────────────────────────────────────────────────────────────────────────────

/// Provides fully custom overlay drawing via UIKit Canvas.
///
/// `state.cardBoundsInView` is already in view coordinates — no transforms needed.
public typealias ScannerUIOverlayRenderer = (
    _ context: CGContext,
    _ state: ScannerFrameState,
    _ viewWidth: CGFloat,
    _ viewHeight: CGFloat
) -> Void

// ─────────────────────────────────────────────────────────────────────────────
// Overlay UIView
// ─────────────────────────────────────────────────────────────────────────────

internal final class ScannerOverlayUIView: UIView {

    var style: ScannerStyle = ScannerStyle() {
        didSet { setNeedsDisplay() }
    }

    var customRenderer: ScannerUIOverlayRenderer? {
        didSet { setNeedsDisplay() }
    }

    private var currentState: ScannerFrameState = .empty
    private let renderer     = ScannerOverlayRenderer()
    // BBoxSpringAnimator: critically-damped spring at vsync rate.
    // Replaces BBoxInterpolator / One Euro on this path — see _ScannerOverlayDrawView
    // for the full rationale. BBoxInterpolator is retained for custom-overlay callers.
    private let bboxSpring   = BBoxSpringAnimator()
    private let gyroTracker  = GyroscopeTracker()

    // ── Scan-line visibility debounce ────────────────────────────────────────
    // Mirror of _ScannerOverlayDrawView: 300 ms debounce keeps the scan line
    // visible briefly after isScanning/isAnalyzing drops — suppresses flickers.
    private var scanLineLastVisibleAt: TimeInterval = -.infinity

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        bboxSpring.start { [weak self] in self?.setNeedsDisplay() }
        gyroTracker.start()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(state: ScannerFrameState) {
        currentState = state
        bboxSpring.setTarget(state.cardBoundsInView, captureTimestamp: state.captureTimestamp)
        if state.isScanning || state.isAnalyzing {
            scanLineLastVisibleAt = CACurrentMediaTime()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let viewBounds = self.bounds

        if let custom = customRenderer {
            // Custom renderer path: expose the raw (non-spring) state so the
            // caller receives cardBoundsInView from ScannerEngineController.
            // Custom overlays that want spring-smooth coords can use
            // MergenScannerStateHandle with their own interpolation.
            custom(ctx, currentState, viewBounds.width, viewBounds.height)
            return
        }

        // Apply gyroscope offset to the spring's smoothed bbox.
        var smoothedBBox = bboxSpring.smoothedBounds
        let viewW = viewBounds.width
        if let box = smoothedBBox, gyroTracker.isAvailable, viewW > 0 {
            let (pitch, yaw) = gyroTracker.consumeDelta()
            if pitch != 0 || yaw != 0 {
                let fovRad: CGFloat = .pi / 3
                let pxPerRad = viewW / fovRad
                smoothedBBox = box.offsetBy(dx: -yaw * pxPerRad, dy: -pitch * pxPerRad)
            }
        }

        // 300 ms debounce for scan-line visibility.
        let scanLineActive = smoothedBBox != nil
            && (CACurrentMediaTime() - scanLineLastVisibleAt) < 0.30

        let smoothedState = ScannerFrameState(
            engineState:      currentState.engineState,
            hasCard:          smoothedBBox != nil,
            cardBoundsInView: smoothedBBox,
            confidence:       currentState.confidence,
            progress:         currentState.progress,
            messageTitle:     currentState.messageTitle,
            messageHint:      currentState.messageHint,
            isFinished:       currentState.isFinished,
            isPassed:         currentState.isPassed,
            activeColor:      currentState.activeColor,
            captureTimestamp: currentState.captureTimestamp,
            isAnalyzing:      currentState.isAnalyzing,
            isScanning:       scanLineActive,
            isCardInGuide:    currentState.isCardInGuide
        )
        renderer.draw(in: ctx, bounds: viewBounds, state: smoothedState, style: style)
    }

    override func removeFromSuperview() {
        gyroTracker.stop()
        bboxSpring.stop()
        super.removeFromSuperview()
    }
}
