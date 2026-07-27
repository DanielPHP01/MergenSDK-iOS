import SwiftUI
import AVFoundation
import PhotosUI

// ─────────────────────────────────────────────────────────────────────────────
// MergenVerifyView — drop-in full-flow two-sided ID card verification view
//
// Minimal client integration (3 lines total):
//
//   MergenVerifyView { result in
//       handleResult(result)
//   }
//
// The view self-contains:
//   - License auto-load from app bundle (license.json) when `license` is nil.
//   - AVCaptureDevice camera permission request & denied error screen.
//   - Two-sided camera flow: front scan → back scan.
//   - Mergen.verify() call.
//   - Built-in MergenResultView result screen (suppressible via showResultScreen).
//   - Gallery front+back picker as an alternative path.
//
// SemVer: MINOR addition — zero breaking changes to existing public API.
// ─────────────────────────────────────────────────────────────────────────────

// ── Internal screen state machine ─────────────────────────────────────────────

private enum MVScreen {
    case home
    case permissionDenied
    case cameraScanFront
    /// Intermediate screen shown after the front side is captured.
    /// The camera is NOT running here — MVCameraSideView (and therefore MergenScannerView)
    /// is not in the SwiftUI tree during this state, so onDisappear has already fired and
    /// teardownCamera() has already been called.  On the user's button tap the flow
    /// transitions to .cameraScanBack, which re-mounts MVCameraSideView and rebuilds the
    /// camera session fresh — matching Android's AwaitingFlip state in MergenVerifyFlow.kt.
    /// The captured front crop is stored in the parent view's cameraFrontCrop @State.
    case cameraAwaitFlip
    case cameraScanBack
    case processing(stage: String)
    case result(VerifyResult, title: String)
    case galleryPickingFront
    case galleryPickingBack
    case error(String)
}

// ─────────────────────────────────────────────────────────────────────────────
// iOS 14-compatible button styles
// ─────────────────────────────────────────────────────────────────────────────

/// iOS 14-compatible replacement for `.buttonStyle(.borderedProminent)`.
private struct MVProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .background(Color.accentColor.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1.0) : 0.4))
            .cornerRadius(10)
    }
}

/// iOS 14-compatible replacement for `.buttonStyle(.bordered)`.
private struct MVBorderedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Color.accentColor.opacity(isEnabled ? 1.0 : 0.4))
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor.opacity(isEnabled ? (configuration.isPressed ? 0.5 : 1.0) : 0.4),
                            lineWidth: 1)
            )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MergenVerifyView
// ─────────────────────────────────────────────────────────────────────────────

/**
 Drop-in SwiftUI view that runs the complete two-sided Kyrgyz ID verification flow.

 Handles license loading, camera permission, front/back scanning, Mergen.verify(),
 and an optional built-in result screen — the client writes ~3 lines.

 **Minimal usage:**
 ```swift
 MergenVerifyView { result in
     print(result.status, result.verifyId)
 }
 ```

 **With dismiss callback and no result screen:**
 ```swift
 MergenVerifyView(showResultScreen: false, onResult: { result in
     dismiss()
     handleResult(result)
 }, onCancel: {
     dismiss()
 })
 ```

 **Explicit license (e.g. fetched from server):**
 ```swift
 MergenVerifyView(license: fetchedLicenseJson) { result in ... }
 ```

 - Parameters:
   - license:          License JSON string. When `nil` the view auto-loads
                       `license.json` from `Bundle.main`.
   - style:            Optional scanner overlay style. Uses SDK default when nil.
   - showResultScreen: When `true` (default) the built-in `MergenResultView` is
                       presented before calling `onResult`. When `false` the caller
                       receives `onResult` immediately after `Mergen.verify()`.
   - onResult:         Called once with the `VerifyResult` after verification
                       (and after the user dismisses the result screen when
                       `showResultScreen == true`).
   - onCancel:                   Called when the user taps the close / dismiss button from
                                 the home screen. Optional — no-op when nil.
   - handlePermissionsInternally: When `false`, the view NEVER calls
                                 `AVCaptureDevice.requestAccess`. It only checks
                                 `authorizationStatus`; if not `.authorized`, `onResult` is
                                 called immediately with `VerifyResult.failed(...)` referencing
                                 `MergenError.cameraPermissionDenied`. Default: `true`
                                 (pre-v2.1 behaviour, source-compatible).

 - Note: **Deprecated since v2.1.** Copy `SampleVerifyFlow` from MergenSampleiOS into your
         app for the v3.0-compatible, client-owned flow. See `docs/dev/migration-v3.md`.
 */
@available(*, deprecated, message: "Moves to your app in v3.0 — copy the reference flow from MergenSampleiOS (SampleVerifyFlow.swift); see docs/dev/migration-v3.md")
public struct MergenVerifyView: View {

    // ── Public configuration ──────────────────────────────────────
    private let providedLicense:             String?
    private let style:                        ScannerStyle
    private let showResultScreen:             Bool
    /// When `true`, bypasses the built-in home screen and goes straight to
    /// camera scanning on first appear.  Intended for host apps that provide
    /// their own home screen (e.g. MergenSampleRootView).
    private let startInCamera:                Bool
    /// When `false`, the view never calls `AVCaptureDevice.requestAccess`.
    /// Checks `authorizationStatus` only; if not `.authorized`, delivers
    /// `onResult(VerifyResult.failed(...))` with a camera-permission message.
    private let handlePermissionsInternally:  Bool
    private let onResult:                     (VerifyResult) -> Void
    private let onCancel:                     (() -> Void)?

    // ── Internal state machine ────────────────────────────────────
    @State private var screen:               MVScreen     = .home
    @State private var cameraFrontCrop:      UIImage?     = nil
    /// Full MergenIdResult from the front-side camera scan.
    /// Stored alongside cameraFrontCrop so cameraScanBackView can choose the
    /// fast verifyCards() path (no re-OCR) when sideResultJson is available.
    @State private var cameraFrontResult:    MergenIdResult? = nil
    @State private var galleryFrontImg:      UIImage?     = nil
    @State private var showFrontPicker:      Bool     = false
    @State private var showBackPicker:       Bool     = false
    /// Prevents the auto-start-camera trigger from firing more than once.
    @State private var didAutoStartCamera:   Bool     = false
    /// Alert shown before the FRONT gallery picker opens (side label prompt).
    @State private var showFrontPickerAlert: Bool     = false
    /// Alert shown before the BACK gallery picker opens (side label prompt).
    @State private var showBackPickerAlert:  Bool     = false

    // ── Initialisers ──────────────────────────────────────────────

    /// - Parameters:
    ///   - startInCamera:              When `true`, the view skips its own home screen and goes
    ///                                 directly to camera scanning on appear.  Default: `false`.
    ///   - handlePermissionsInternally: `false` = SDK never requests access; check-only mode.
    ///                                 Default: `true` (pre-v2.1 behaviour, source-compatible).
    public init(
        license:                     String?             = nil,
        style:                       ScannerStyle        = ScannerStyle(),
        showResultScreen:            Bool                = true,
        startInCamera:               Bool                = false,
        handlePermissionsInternally: Bool                = true,
        onResult:                    @escaping (VerifyResult) -> Void,
        onCancel:                    (() -> Void)?       = nil
    ) {
        self.providedLicense             = license
        self.style                        = style
        self.showResultScreen             = showResultScreen
        self.startInCamera                = startInCamera
        self.handlePermissionsInternally  = handlePermissionsInternally
        self.onResult                     = onResult
        self.onCancel                     = onCancel
    }

    // ── Body ──────────────────────────────────────────────────────

    public var body: some View {
        ZStack {
            activeScreen
        }
        .animation(.easeInOut(duration: 0.25), value: screenTag)
        // ── Auto-start camera on first appear (startInCamera mode) ──────────────
        .onAppear {
            guard startInCamera, !didAutoStartCamera else { return }
            didAutoStartCamera = true
            requestCameraPermission {
                cameraFrontCrop = nil
                screen = .cameraScanFront
            }
        }
        // ── Front gallery side-label alert ────────────────────────────────────────
        // Shown BEFORE the front picker so the user knows which side to pick.
        .alert(isPresented: $showFrontPickerAlert) {
            Alert(
                title: Text("Шаг 1 из 2"),
                message: Text("Выберите ЛИЦЕВУЮ сторону документа (фронт)"),
                primaryButton: .default(Text("Выбрать фото")) {
                    screen = .galleryPickingFront
                    showFrontPicker = true
                },
                secondaryButton: .cancel(Text("Отмена")) {
                    screen = .home
                }
            )
        }
        // ── Back gallery side-label alert ─────────────────────────────────────────
        // Shown BEFORE the back picker so the user knows which side to pick.
        // NOTE: SwiftUI allows only one .alert(isPresented:) per view — the second
        // alert is attached to a hidden overlay view to work around this limitation.
        .background(
            Color.clear
                .alert(isPresented: $showBackPickerAlert) {
                    Alert(
                        title: Text("Шаг 2 из 2"),
                        message: Text("Теперь выберите ОБОРОТНУЮ сторону документа (бэк)"),
                        primaryButton: .default(Text("Выбрать фото")) {
                            showBackPicker = true
                        },
                        secondaryButton: .cancel(Text("Отмена")) {
                            galleryFrontImg = nil
                            screen = .home
                        }
                    )
                }
        )
        // Front gallery picker
        .sheet(isPresented: $showFrontPicker, onDismiss: {
            if case .galleryPickingFront = screen { screen = .home }
        }) {
            MVGalleryPicker { img in
                showFrontPicker = false
                guard let img else { screen = .home; return }
                galleryFrontImg = img
                screen = .galleryPickingBack
                // Show the back-side label alert before presenting the back picker.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showBackPickerAlert = true
                }
            }
        }
        // Back gallery picker
        // onDismiss fires SYNCHRONOUSLY on sheet dismiss — BEFORE the async
        // PHPicker loadObject callback delivers the back image.  Clearing
        // galleryFrontImg here would wipe the front before the callback reads it,
        // causing the guard to fail and Task { runVerify } to never execute.
        //
        // Correct contract: the PHPicker callback (below) is the sole owner of
        // galleryFrontImg.  It captures front into a local, nils galleryFrontImg,
        // and only then launches runVerify.
        //
        // onDismiss therefore only resets to .home on a REAL cancel — i.e. when the
        // picker was dismissed WITHOUT selecting an image (galleryFrontImg still set
        // means the callback delivered the back image and is about to launch verify).
        .sheet(isPresented: $showBackPicker, onDismiss: {
            if case .galleryPickingBack = screen, galleryFrontImg == nil {
                screen = .home
            }
        }) {
            MVGalleryPicker { backImg in
                showBackPicker = false
                let front = galleryFrontImg
                galleryFrontImg = nil
                guard let front, let back = backImg else {
                    screen = .home
                    return
                }
                screen = .processing(stage: "Обработка обеих сторон…")
                Task {
                    let r = await runVerify(front: front, back: back)
                    await deliver(r, title: "Результат — Галерея")
                }
            }
        }
    }

    // ── Active screen routing ─────────────────────────────────────

    @ViewBuilder
    private var activeScreen: some View {
        switch screen {

        case .home, .processing, .galleryPickingFront, .galleryPickingBack:
            if startInCamera {
                // When startInCamera=true the host app owns the home screen.
                // Show a neutral black background with a spinner while the camera
                // permission request / auto-navigate is in flight.  This prevents
                // the built-in MVHomeScreen from flashing on screen.
                Color.black.ignoresSafeArea()
                    .overlay(ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)))
                    .transition(.opacity)
            } else {
                MVHomeScreen(
                    hasLicense:    hasValidLicense,
                    isBusy:        isBusy,
                    busyLabel:     busyLabel,
                    onStartCamera: {
                        requestCameraPermission {
                            cameraFrontCrop = nil
                            screen = .cameraScanFront
                        }
                    },
                    onStartGallery: {
                        // Show the front-side label alert before opening the picker.
                        showFrontPickerAlert = true
                    },
                    onDismiss: onCancel
                )
                .transition(.opacity)
            }

        case .permissionDenied:
            MVPermissionDeniedScreen { screen = .home }
                .transition(.opacity)

        case .cameraScanFront:
            MVCameraSideView(
                licenseJson:                resolvedLicense,
                style:                      style,
                sideLabel:                  "Отсканируйте ФРОНТ документа",
                onResult:    { result in
                    // Store the front crop and transition to the intermediate flip screen.
                    // MVCameraSideView (and MergenScannerView inside it) will leave the
                    // SwiftUI tree, firing onDisappear → controller.teardownCamera().
                    // The camera session is torn down while the user reads the flip prompt.
                    // On button tap → .cameraScanBack mounts MVCameraSideView fresh →
                    // onAppear → prepare() → CameraSession.setup() finds captureSession == nil
                    // and rebuilds a fresh session → smooth back-side preview.
                    //
                    // Also store the full MergenIdResult so cameraScanBackView can use the
                    // fast verifyCards() path (nativeCompareSides, no re-OCR) when
                    // sideResultJson is non-empty — skipping the ~4 s gallery re-OCR path.
                    cameraFrontCrop    = result.croppedImage
                    cameraFrontResult  = result
                    screen = .cameraAwaitFlip
                },
                onCancel: {
                    // When startInCamera=true the built-in home screen is not shown —
                    // screen = .home renders a black spinner that the user cannot escape.
                    // In that mode, cancel must bubble up to the host via onCancel() so
                    // the host can dismiss its own sheet / navigation.
                    // When startInCamera=false, returning to .home shows MVHomeScreen.
                    if startInCamera { onCancel?() } else { screen = .home }
                },
                handlePermissionsInternally: handlePermissionsInternally
            )
            .transition(.opacity)

        case .cameraAwaitFlip:
            MVFlipCardScreen(
                onFlipped: {
                    // .cameraScanBack reads cameraFrontCrop (set when front completed).
                    // The screen state change triggers a fresh MVCameraSideView mount.
                    screen = .cameraScanBack
                },
                onCancel: {
                    cameraFrontCrop = nil
                    // Same startInCamera logic as .cameraScanFront onCancel above.
                    if startInCamera { onCancel?() } else { screen = .home }
                }
            )
            .transition(.opacity)

        case .cameraScanBack:
            cameraScanBackView

        case .result(let verifyResult, let title):
            if showResultScreen {
                MergenResultView(
                    result:    verifyResult,
                    title:     title,
                    onDismiss: {
                        screen = .home
                        onResult(verifyResult)
                    }
                )
                .transition(.opacity)
            } else {
                // showResultScreen == false: deliver and return to home immediately.
                Color.clear
                    .onAppear {
                        screen = .home
                        onResult(verifyResult)
                    }
            }

        case .error(let message):
            MVErrorScreen(message: message) { screen = .home }
                .transition(.opacity)
        }
    }

    /// Back-scan view extracted so the `let savedFront` / `savedFrontResult` captures are outside ViewBuilder.
    @ViewBuilder
    private var cameraScanBackView: some View {
        let savedFront       = cameraFrontCrop
        let savedFrontResult = cameraFrontResult
        MVCameraSideView(
            licenseJson:                resolvedLicense,
            style:                      style,
            sideLabel:                  "Отсканируйте ОБОРОТ документа",
            onResult:    { backResult in
                let backCrop = backResult.croppedImage
                cameraFrontCrop   = nil
                cameraFrontResult = nil

                guard let front = savedFront, let back = backCrop else {
                    screen = .error(
                        "Не удалось получить кроп карты.\n" +
                        "Фронт: \(savedFront != nil ? "OK" : "nil"), " +
                        "Бэк: \(backCrop != nil ? "OK" : "nil").\n" +
                        "Попробуйте переснять при хорошем освещении."
                    )
                    return
                }

                // Fast path: both sides have sideResultJson from live capture.
                // verifyCards() calls nativeCompareSides (~1 ms, no re-OCR).
                // Fall back to Mergen.verify(images) only when sideJson is absent.
                let frontJson = savedFrontResult?.sideResultJson.flatMap {
                    ($0.isEmpty || $0 == "{}") ? nil : $0
                }
                let backJson  = backResult.sideResultJson.flatMap {
                    ($0.isEmpty || $0 == "{}") ? nil : $0
                }

                if let fResult = savedFrontResult, frontJson != nil, backJson != nil {
                    let license = resolvedLicense
                    screen = .processing(stage: "Mergen.verifyCards()…")
                    Task {
                        let r = await runVerifyCards(
                            frontResult: fResult,
                            frontImage:  front,
                            backResult:  backResult,
                            backImage:   back,
                            license:     license
                        )
                        await deliver(r, title: "Mergen.verifyCards() — Камера")
                    }
                } else {
                    screen = .processing(stage: "Mergen.verify()…")
                    Task {
                        let r = await runVerify(front: front, back: back)
                        await deliver(r, title: "Mergen.verify() — Камера")
                    }
                }
            },
            onCancel: {
                cameraFrontCrop   = nil
                cameraFrontResult = nil
                // Same startInCamera logic as .cameraScanFront onCancel.
                if startInCamera { onCancel?() } else { screen = .home }
            },
            handlePermissionsInternally: handlePermissionsInternally
        )
        .transition(.opacity)
    }

    // ── Helpers ───────────────────────────────────────────────────

    /// Resolved license: provided value wins; falls back to bundle auto-load.
    private var resolvedLicense: String {
        if let l = providedLicense, !l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
        return MVLicenseLoader.loadFromBundle() ?? ""
    }

    private var hasValidLicense: Bool {
        !resolvedLicense.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isBusy: Bool {
        switch screen {
        case .processing, .galleryPickingFront, .galleryPickingBack: return true
        default: return false
        }
    }

    private var busyLabel: String {
        switch screen {
        case .processing(let s):   return s
        case .galleryPickingFront: return "Выбирается фронт…"
        case .galleryPickingBack:  return "Выбирается бэк…"
        default:                   return ""
        }
    }

    private var screenTag: Int {
        switch screen {
        case .home:               return 0
        case .permissionDenied:   return 1
        case .cameraScanFront:    return 2
        case .cameraAwaitFlip:    return 9
        case .cameraScanBack:     return 3
        case .processing:         return 4
        case .result:             return 5
        case .galleryPickingFront: return 6
        case .galleryPickingBack: return 7
        case .error:              return 8
        }
    }

    /// Fast camera-flow verify: calls `Mergen.verifyCards()` (stateless nativeCompareSides,
    /// ~1 ms) using the opaque per-side JSON blobs captured during live scanning.
    ///
    /// Falls through to `runVerify(front:back:)` on any error so accuracy is never regressed.
    private func runVerifyCards(
        frontResult: MergenIdResult,
        frontImage:  UIImage,
        backResult:  MergenIdResult,
        backImage:   UIImage,
        license:     String
    ) async -> VerifyResult {
        // Mergen.makeScanResult extracts version/pin/mrz/sideJson with the exact
        // logic MergenScanView uses internally (OCR fields, sideResultJson fallback).
        let frontScanResult = Mergen.makeScanResult(
            idResult:     frontResult,
            side:         .front,
            croppedPhoto: frontImage
        )
        let backScanResult = Mergen.makeScanResult(
            idResult:     backResult,
            side:         .back,
            croppedPhoto: backImage
        )
        do {
            // strict deliberately left at the default (false) — mirrors both the
            // Android fast path and the legacy Mergen.verify camera flow, where
            // strictSameDocument defaults to false unless the client opts in.
            return try await Mergen.verifyCards(
                front:   frontScanResult,
                back:    backScanResult,
                license: license
            )
        } catch {
            // Fallback: re-OCR via full gallery path (accuracy preserved).
            return await runVerify(front: frontImage, back: backImage)
        }
    }

    /// Calls `Mergen.verify` and wraps all errors into a typed failed `VerifyResult`.
    private func runVerify(front: UIImage, back: UIImage) async -> VerifyResult {
        let license = resolvedLicense
        do {
            return try await Mergen.verify(
                front:     front,
                back:      back,
                license:   license
            ) {
                $0.leanFields = true
                // strictSameDocument left false — parity with Android's MergenVerifyFlow.
                // Hard MISMATCH still fails regardless; strict only additionally fails
                // SAME_WITH_WARNING (1-edit OCR tolerance) and UNKNOWN verdicts.
            }
        } catch MergenError.licenseEmpty {
            return MVVerifyFailed.make(front: front, back: back,
                message:   "Лицензия пуста — движок не инициализируется.",
                messageEn: "License is empty — engine will not initialise.")
        } catch MergenError.engineInitFailed {
            return MVVerifyFailed.make(front: front, back: back,
                message:   "Ошибка инициализации нативного движка (модели не найдены?).",
                messageEn: "Native engine init failed (models missing?).")
        } catch {
            return MVVerifyFailed.make(front: front, back: back,
                message:   "Ошибка движка: \(error.localizedDescription)",
                messageEn: "Engine error: \(error.localizedDescription)")
        }
    }

    /// Transition to the result state on the main actor.
    @MainActor
    private func deliver(_ result: VerifyResult, title: String) {
        screen = .result(result, title: title)
    }

    /// Requests or checks camera access depending on `handlePermissionsInternally`.
    ///
    /// When `handlePermissionsInternally == true` (default):
    ///   - If already authorised, calls `granted()` synchronously on the main actor.
    ///   - If `notDetermined`, shows the system permission prompt; on denial shows
    ///     the built-in permission-denied screen.
    ///   - If denied/restricted, shows the built-in permission-denied screen.
    ///
    /// When `handlePermissionsInternally == false`:
    ///   - Only checks `authorizationStatus`; NEVER calls `requestAccess`.
    ///   - If `.authorized`, calls `granted()`.
    ///   - Otherwise, delivers `onResult(VerifyResult.failed(...))` immediately with
    ///     a message referencing `MergenError.cameraPermissionDenied`.
    private func requestCameraPermission(granted: @escaping @MainActor () -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        guard handlePermissionsInternally else {
            // Check-only mode: never request access, never show SDK permission screen.
            if status == .authorized {
                Task { @MainActor in granted() }
            } else {
                let result = VerifyResult.failed(
                    message:   "Нет доступа к камере. Предоставьте разрешение в Настройках перед запуском сканера. (MergenError.cameraPermissionDenied)",
                    messageEn: "Camera permission not granted. Grant access in Settings before starting the scanner. (MergenError.cameraPermissionDenied)"
                )
                Task { @MainActor in self.onResult(result) }
            }
            return
        }

        switch status {
        case .authorized:
            Task { @MainActor in granted() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in
                    if ok { granted() } else { self.screen = .permissionDenied }
                }
            }
        default:
            screen = .permissionDenied
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal sub-views (private to this file)
// ─────────────────────────────────────────────────────────────────────────────

// ── Home screen ───────────────────────────────────────────────────────────────

private struct MVHomeScreen: View {
    let hasLicense:     Bool
    let isBusy:         Bool
    let busyLabel:      String
    let onStartCamera:  () -> Void
    let onStartGallery: () -> Void
    let onDismiss:      (() -> Void)?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "creditcard.viewfinder")
                            .font(.system(size: 40, weight: .thin))
                            .foregroundColor(.blue)
                        Text("KG ID Верификация")
                            .font(.title3).fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        Text("doc# / PIN / MRZ — Mergen.verify()")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)

                    // Busy indicator
                    if isBusy {
                        HStack(spacing: 10) {
                            ProgressView().progressViewStyle(CircularProgressViewStyle()).scaleEffect(0.85)
                            Text(busyLabel)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }

                    // License warning
                    if !hasLicense {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                            Text("license.json не найден в bundle.\nДвижок не инициализируется.")
                                .font(.callout).foregroundColor(.red)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08))
                        .cornerRadius(10)
                        .padding(.horizontal, 20)
                    }

                    // CTA buttons
                    VStack(spacing: 12) {
                        Button(action: onStartCamera) {
                            Label("Сканировать камерой (обе стороны)", systemImage: "camera.fill")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(MVProminentButtonStyle())
                        .disabled(!hasLicense || isBusy)

                        Button(action: onStartGallery) {
                            Label("Выбрать фронт + бэк из галереи",
                                  systemImage: "photo.on.rectangle.angled")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(MVBorderedButtonStyle())
                        .disabled(!hasLicense || isBusy)
                    }
                    .padding(.horizontal, 20)

                    // Instruction card
                    MVInstructionCard()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                }
            }
            .navigationTitle("Mergen ID Verify")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Group {
                if let dismiss = onDismiss {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                    }
                }
            })
        }
        .navigationViewStyle(.stack)
    }
}

// ── Camera-permission denied screen ──────────────────────────────────────────

private struct MVPermissionDeniedScreen: View {
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "camera.slash.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)
                Text("Доступ к камере запрещён")
                    .font(.headline)
                Text(
                    "Разрешите доступ к камере в Настройках устройства:\n" +
                    "Настройки → Конфиденциальность → Камера."
                )
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                Spacer()
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Открыть Настройки")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(MVProminentButtonStyle())
                .padding(.horizontal, 24)

                Button(action: onDismiss) {
                    Text("Назад")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(MVBorderedButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .navigationTitle("Нет доступа к камере")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }
}

// ── One camera-side scan view ─────────────────────────────────────────────────

private struct MVCameraSideView: View {
    let licenseJson:                 String
    let style:                        ScannerStyle
    let sideLabel:                    String
    let onResult:                     (MergenIdResult) -> Void
    let onCancel:                     () -> Void
    /// Forwarded from `MergenVerifyView.handlePermissionsInternally`.
    /// When `false`, the scanner never calls `requestAccess` (check-only mode).
    var handlePermissionsInternally:  Bool = true

    var body: some View {
        ZStack(alignment: .top) {
            MergenScannerView(
                licenseKey:    licenseJson,
                configuration: MergenScannerConfig {
                    $0.leanIdentityFields          = true
                    $0.handlePermissionsInternally = handlePermissionsInternally
                },
                style:         style,
                onFinished:    onResult
            )
            .ignoresSafeArea()

            // Side label banner
            Text(sideLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
                .padding(.top, 56)

            // Cancel button
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 56)
            .padding(.leading, 20)
        }
    }
}

// ── Flip-card prompt (between front and back scans) ──────────────────────────
//
// Shown after the front side is captured and the camera session has been torn
// down (teardownCamera fires on MergenScannerView's onDisappear).  The camera
// is NOT running here — this is a full-screen dark prompt identical in spirit to
// Android's MergenFlipCardScreen / FlowState.AwaitingFlip.
// The user taps the primary button → .cameraScanBack → fresh camera session.

private struct MVFlipCardScreen: View {
    let onFlipped: () -> Void
    let onCancel:  () -> Void

    var body: some View {
        ZStack {
            Color(UIColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 1))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Success icon
                Text("✓")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundColor(Color(red: 0, green: 0.784, blue: 0.325))

                Spacer().frame(height: 28)

                Text("Лицевая сторона считана")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Spacer().frame(height: 10)

                Text("Переверните документ и нажмите кнопку\nниже для сканирования оборота")
                    .font(.system(size: 15))
                    .foregroundColor(Color.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 40)

                // Primary CTA — starts the back-side camera
                Button(action: onFlipped) {
                    Text("Перевернул — сканировать оборот")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.accentColor)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 20)

                Spacer().frame(height: 12)

                // Secondary — cancel
                Button(action: onCancel) {
                    Text("Отмена")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.75))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                }
                .padding(.horizontal, 20)

                Spacer().frame(height: 48)
            }
        }
    }
}

// ── Error screen ──────────────────────────────────────────────────────────────

private struct MVErrorScreen: View {
    let message:   String
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48)).foregroundColor(.red)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ошибка")
                        .font(.headline).foregroundColor(.red)
                    Text(message)
                        .font(.body).foregroundColor(.red.opacity(0.85))
                        .multilineTextAlignment(.leading)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .cornerRadius(12)
                .padding(.horizontal, 24)
                Spacer()
                Button(action: onDismiss) {
                    Text("Назад")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(MVBorderedButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .navigationTitle("Ошибка")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading:
                Button(action: onDismiss) { Image(systemName: "xmark") }
            )
        }
        .navigationViewStyle(.stack)
    }
}

// ── Instruction card ──────────────────────────────────────────────────────────

private struct MVInstructionCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lean Identity Verify — Mergen")
                .font(.subheadline).fontWeight(.bold)
                .foregroundColor(.secondary)
            Text(
                "Камера: фронт + бэк → Mergen.verify() → статус + doc#/PIN/MRZ.\n\n" +
                "Галерея: выбрать фронт, затем бэк → тот же результат."
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.systemGroupedBackground))
        .cornerRadius(12)
    }
}

// ── Gallery picker (PHPicker, single image) ───────────────────────────────────

private struct MVGalleryPicker: UIViewControllerRepresentable {
    let onPicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter         = .images
        cfg.selectionLimit = 1
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (UIImage?) -> Void
        init(onPicked: @escaping (UIImage?) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                onPicked(nil); return
            }
            provider.loadObject(ofClass: UIImage.self) { [weak self] image, _ in
                DispatchQueue.main.async { self?.onPicked(image as? UIImage) }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// License auto-loader (internal)
// ─────────────────────────────────────────────────────────────────────────────

/// Loads `license.json` from the **caller's** main bundle.
/// Returns `nil` when the file is absent or unreadable.
private enum MVLicenseLoader {
    static func loadFromBundle() -> String? {
        guard let url  = Bundle.main.url(forResource: "license", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8),
              !json.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return json
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MVVerifyFailed — typed failure factory
// ─────────────────────────────────────────────────────────────────────────────

private enum MVVerifyFailed {
    static func make(
        front:     UIImage,
        back:      UIImage,
        message:   String,
        messageEn: String
    ) -> VerifyResult {
        .failed(message: message, messageEn: messageEn,
                frontPhoto: front, backPhoto: back)
    }
}

