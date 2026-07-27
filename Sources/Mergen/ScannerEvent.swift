import Foundation
import CoreGraphics

/// Named scanner events (Phase A / v2.1.0 — §6 of the SDK spec).
///
/// Mirrors the Android `ScannerEvent` sealed interface case-for-case:
///
/// | Swift                          | Kotlin                       |
/// |--------------------------------|------------------------------|
/// | `.cameraReady`                 | `CameraReady`                |
/// | `.documentDetected(bounds:)`   | `DocumentDetected(bounds)`   |
/// | `.processing(progress:)`       | `Processing(progress)`       |
/// | `.success(_:)`                 | `Success(result)`            |
/// | `.error(_:)`                   | `Error(error)`               |
///
/// Events are *derived* from the existing frame-state pipeline — subscribing to
/// them does not change engine behaviour, and the legacy `onFinished`/`onError`
/// callbacks keep firing exactly as before.
///
/// Delivery: `AsyncStream<ScannerEvent>` via `events` on
/// `MergenScannerViewController` and `MergenScannerStateHandle`, plus an optional
/// `onEvent` closure on the view wrappers. Streams are hot — events emitted while
/// nobody consumes are dropped (UI-event semantics).
public enum ScannerEvent {

    /// Camera pipeline running and delivering frames (fires again after a foreground resume).
    case cameraReady

    /// A document entered the frame (rising edge of card detection).
    /// `bounds` is already in **view coordinates** — same space as
    /// `ScannerFrameState.cardBoundsInView`, no math needed.
    case documentDetected(bounds: CGRect)

    /// Capture/OCR pipeline is working on the detected document.
    /// Emitted when `progress` (0...1) changes by ≥ 0.1 — throttled, safe to
    /// drive progress UI directly.
    case processing(progress: Float)

    /// A final scan result was produced. Mirrors the `onFinished` callback:
    /// check `MergenIdResult.success` — a failed scan is also delivered here
    /// (identical contract to `onFinished`, kept for backward compatibility).
    case success(MergenIdResult)

    /// Engine init failure, runtime error, or `MergenError.cameraPermissionDenied`.
    case error(Error)
}
