import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// BBoxDrawStyle
// ─────────────────────────────────────────────────────────────────────────────

/// Controls how the detected card bounding box is rendered.
public enum BBoxDrawStyle {
    /// Simple rounded rectangle stroke.
    case fullRect
    /// Four L-shaped corner brackets only.
    case cornersOnly
    /// Full rounded rect + thicker corner accents (default).
    case cornersAndRect
    /// No bbox drawn; use `customOverlay` for fully custom rendering.
    case none
}

// ─────────────────────────────────────────────────────────────────────────────
// ScannerStyle
// ─────────────────────────────────────────────────────────────────────────────

/// Complete visual style for the scanner overlay.
///
/// All dimensions are in logical points. Separate engine settings live in
/// `MergenScannerConfig`.
///
/// **Kotlin-like DSL (Swift result builder not required — just a mutable struct):**
/// ```swift
/// let style = ScannerStyle {
///     $0.bboxDrawStyle = .cornersOnly
///     $0.colorSuccess  = .green
///     $0.strokeWidth   = 4
/// }
/// ```
public struct ScannerStyle {

    // ── Bounding box ──────────────────────────────────────────
    public var bboxDrawStyle: BBoxDrawStyle = .cornersAndRect
    public var strokeWidth: CGFloat = 3
    /// Length of each corner bracket arm (cornersOnly / cornersAndRect).
    public var cornerLength: CGFloat = 28
    public var cornerRadius: CGFloat = 12
    /// Extra padding around the detected bbox as a fraction of the shorter bbox side.
    public var bboxPaddingFraction: CGFloat = 0.04

    // ── BBox state colours ────────────────────────────────────
    public var colorIdle: Color      = .white
    public var colorDetecting: Color = .yellow
    public var colorSuccess: Color   = Color(red: 0, green: 0.88, blue: 0.46)
    public var colorFailure: Color   = .red

    // ── Background dim ────────────────────────────────────────
    public var dimColor: Color = Color.black.opacity(0.35)

    // ── Hint / title text ─────────────────────────────────────
    public var hintTextSize: CGFloat  = 15
    public var titleTextSize: CGFloat = 18
    public var hintTextColor: Color   = .white
    public var titleTextColor: Color  = .white
    public var hintBackgroundColor: Color = Color.black.opacity(0.72)
    public var hintCornerRadius: CGFloat  = 10
    /// Fraction of view height from the bottom where the hint block is placed.
    public var hintPositionFraction: CGFloat = 0.12

    // ── Progress bar ──────────────────────────────────────────
    /// Show the detection-progress bar at the bottom of the overlay.
    /// Default `false` — the scan-line animation (visible whenever the card
    /// is in frame) replaces it as the primary active-scan indicator.
    /// Set to `true` to restore the legacy bar alongside the animation.
    public var showProgressBar: Bool  = false
    public var progressColor: Color   = Color(red: 0, green: 0.88, blue: 0.46)
    public var progressTrackColor: Color = Color.white.opacity(0.25)
    public var progressHeight: CGFloat   = 4
    public var progressCornerRadius: CGFloat = 2
    /// Additional downward shift for the progress bar, in points.
    /// Positive values push the bar towards the screen's bottom edge.
    /// Use when a floating button occupies the space between the bar's default
    /// position and the safe-area bottom (e.g. a Cancel button with 32 pt padding).
    /// Default 0 — bar sits 48 pt above the safe-area bottom edge.
    public var progressBottomInset: CGFloat = 0

    // ── Extras ────────────────────────────────────────────────
    public var showConfidenceLabel: Bool = false
    public var showDebugInfo: Bool = false

    // ── Guide frame ───────────────────────────────────────────
    /// When `true`, draws a static ID-1 card–shaped guide frame centred in the
    /// camera preview and restricts capture to frames where the detected card
    /// overlaps the guide by ≥ 80 % of the card's bounding-box area.
    /// Default `false` — current behaviour (no guide frame, capture accepted
    /// from any detected position).
    public var showGuideFrame: Bool = false

    // ── Initialisers ──────────────────────────────────────────

    public init() {}

    /// DSL initialiser.
    /// ```swift
    /// let style = ScannerStyle { $0.colorSuccess = .green }
    /// ```
    public init(_ configure: (inout ScannerStyle) -> Void) {
        configure(&self)
    }

    // ── Convenience presets ───────────────────────────────────

    /// Corners only, thin white lines.
    public static var minimal: ScannerStyle {
        ScannerStyle { $0.bboxDrawStyle = .cornersOnly; $0.strokeWidth = 2 }
    }

    /// Bold corners + rect, vibrant green on success.
    public static var bold: ScannerStyle {
        ScannerStyle { $0.strokeWidth = 5; $0.cornerLength = 40 }
    }

}
