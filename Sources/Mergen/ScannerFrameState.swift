import Foundation
import CoreGraphics
import SwiftUI

/// Per-frame scanner state with bounding box already mapped to **view coordinates**.
///
/// The SDK computes all coordinate transforms internally. Consumers of a
/// `customOverlay` closure receive this struct directly — zero geometry math required.
///
/// - `cardBoundsInView`: Card rect in view pixel space (rotated + aspect-fill fitted).
///   `nil` when `hasCard` is `false`.
public struct ScannerFrameState {

    public let engineState:       EngineState
    public let hasCard:           Bool
    /// Bounding box in **view coordinates** (UIKit points). Already rotated and scaled.
    public let cardBoundsInView:  CGRect?
    public let confidence:        Float
    /// Detection stability progress in [0..1].
    public let progress:          Float
    public let messageTitle:      String
    public let messageHint:       String
    public let isFinished:        Bool
    public let isPassed:          Bool
    /// Active SwiftUI Color derived from [engineState] + active [ScannerStyle].
    public let activeColor:       Color
    /// Wall-clock timestamp (CACurrentMediaTime) when the source camera frame arrived.
    /// Internal: used by BBoxInterpolator for processing-lag compensation.
    internal let captureTimestamp: TimeInterval

    /// True while the engine is in the brief "analyzing" transition window:
    /// the card just appeared (or re-appeared after a reject) and the live-version
    /// probe hasn't returned a stable result yet.
    ///
    /// While `isAnalyzing` is true:
    /// - `activeColor` is forced to `style.colorDetecting` (neutral — no false red/green).
    /// - `messageTitle` / `messageHint` suppress the side-gate reject messages.
    /// - The overlay should draw a scan-line animation inside the bbox to signal
    ///   that the SDK is actively working.
    ///
    /// The flag clears as soon as `cardVersion` changes away from `.unknown`,
    /// or after a ~400 ms timeout (version stable, apply the actual colour).
    public let isAnalyzing: Bool

    /// True during an active scan pass: card is in frame, engine is in DETECTING or
    /// CAPTURED state, and no gate reject (side-gate / live-gate mismatch) is active.
    ///
    /// Drives the scan-line animation independently of SGSM / `liveVersionProbe` — the
    /// animation is visible on every scan session as long as `showAnalysisAnimation` is
    /// enabled in `MergenScannerConfig`. Set by `ScannerEngineController`; consumers of
    /// `customOverlay` may use it to drive their own activity indicator.
    public var isScanning: Bool = false

    /// True when `showGuideFrame` is enabled and the detected card overlaps the
    /// guide frame by ≥ 80 % of the card's bounding-box area.
    /// Always `false` when `style.showGuideFrame = false` or no card is detected.
    /// Custom overlays may use this flag to drive their own in-guide indicator.
    public var isCardInGuide: Bool = false

    public static let empty = ScannerFrameState(
        engineState: .idle, hasCard: false, cardBoundsInView: nil,
        confidence: 0, progress: 0, messageTitle: "", messageHint: "",
        isFinished: false, isPassed: false, activeColor: .white,
        captureTimestamp: 0, isAnalyzing: false, isScanning: false
    )
}
