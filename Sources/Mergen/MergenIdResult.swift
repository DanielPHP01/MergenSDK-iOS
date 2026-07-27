import UIKit

public struct MergenIdResult {
    public let success: Bool
    public let croppedImage: UIImage?
    public let originalImage: UIImage?
    public let confidence: Float
    public let errorCode: Int
    public let errorMessage: String?

    /// Card layout version. `.unknown` when the classifier did not fire.
    public let cardVersion: CardVersion
    public let isFlipped: Bool

    /// OCR output; nil when OCR was skipped (cardVersion == .unknown or no crop available).
    public var ocrResult: MergenOCRResult?

    /// Per-field accumulator progress JSON from the C++ engine.
    /// Format: `{"accumulated_frames":N,"fields":[{"name":"last_name","guess":"ИВАНОВ","confidence":0.87,"confident":true}]}`
    /// Empty string when unavailable (simulator, no capture, OCR disabled).
    public var fieldProgressJson: String

    /// Perspective-corrected crop of the BACK side, populated by `Mergen.verify` /
    /// `processGalleryTwoSided` only. `nil` for single-sided camera scans.
    public var croppedImageBack: UIImage? = nil

    /// Full final-result JSON from `native_get_final_result_json`, populated by
    /// `ScanFinalizer` after each successful capture.
    /// Contains the `identity_v2` block when `enable_identity_reconciliation=true` in C++.
    /// `nil` when absent, blank, or `"{}"` (simulator, no capture, or older engine binary).
    /// Use `fusedIdentity` (computed on `MergenIdResult`) to parse this lazily.
    public var finalJson: String? = nil

    /// Opaque per-side blob from `native_get_side_result_json`, captured immediately after
    /// a single-side finalization (before the engine is reset for the next side).
    /// Passed through to `MergenScanResult.sideJson` for use in `Mergen.verifyCards`.
    /// `nil` when not populated (simulator, gallery two-sided path, older engine binary).
    ///
    /// Publicly readable so client flows can gate the fast `Mergen.verifyCards` path
    /// (present on both sides → no re-OCR) vs the `Mergen.verify` image fallback —
    /// mirrors the public `sideResultJson` on Android's `MergenIdResult`.
    /// Treat the content as opaque; only the SDK writes it.
    public internal(set) var sideResultJson: String? = nil
}
