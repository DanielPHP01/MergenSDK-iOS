import CoreGraphics

/// Maps a bounding box from raw camera sensor space to view (display) space.
///
/// The C++ engine receives the raw camera frame (sensor-native, potentially landscape,
/// unrotated) and returns the bbox in that same space. This transformer applies:
///  1. Rotation by `rotationDegrees` to get display-oriented coordinates.
///  2. `resizeAspectFill` scale + centering offset to map into view points.
internal enum CoordinateTransformer {

    /// - Parameters:
    ///   - bbox:             Detected card rect in sensor pixel space.
    ///   - imageSize:        Raw sensor frame size (before rotation).
    ///   - rotationDegrees:  Clockwise degrees to rotate the image to make it upright.
    ///                       Typical values: 0 (landscape locked), 90 (portrait back camera).
    ///   - viewSize:         Destination view size in points.
    ///   - paddingFraction:  Extra padding around the box as a fraction of the shorter side.
    /// - Returns: Bbox rect in view coordinates, clamped to view bounds.
    static func toViewSpace(
        bbox: CGRect,
        imageSize: CGSize,
        rotationDegrees: Int,
        viewSize: CGSize,
        paddingFraction: CGFloat = 0
    ) -> CGRect {

        // ── Step 1: rotate bbox to display orientation ─────────
        let (dispSize, rotated) = rotate(bbox: bbox, imageSize: imageSize, degrees: rotationDegrees)

        // ── Step 2: resizeAspectFill scale + centering ──────────
        let scaleX = viewSize.width  / dispSize.width
        let scaleY = viewSize.height / dispSize.height
        let scale  = max(scaleX, scaleY)

        let offsetX = (viewSize.width  - dispSize.width  * scale) / 2
        let offsetY = (viewSize.height - dispSize.height * scale) / 2

        let left   = rotated.minX * scale + offsetX
        let top    = rotated.minY * scale + offsetY
        let right  = rotated.maxX * scale + offsetX
        let bottom = rotated.maxY * scale + offsetY

        // ── Step 3: apply padding ────────────────────────────────
        let bw   = right - left
        let bh   = bottom - top
        let padX = bw * paddingFraction
        let padY = bh * paddingFraction

        let clamped = CGRect(
            x:      (left   - padX).clamped(to: 0...viewSize.width),
            y:      (top    - padY).clamped(to: 0...viewSize.height),
            width:  (bw + padX * 2).clamped(to: 0...(viewSize.width  - (left - padX).clamped(to: 0...viewSize.width))),
            height: (bh + padY * 2).clamped(to: 0...(viewSize.height - (top  - padY).clamped(to: 0...viewSize.height)))
        )
        return clamped
    }

    // ── Private ───────────────────────────────────────────────

    private static func rotate(
        bbox: CGRect,
        imageSize: CGSize,
        degrees: Int
    ) -> (displaySize: CGSize, rotated: CGRect) {
        let iw = imageSize.width
        let ih = imageSize.height
        switch degrees % 360 {
        case 90:
            // (x,y,w,h) → (H-y-h, x, h, w)
            return (
                CGSize(width: ih, height: iw),
                CGRect(x: ih - bbox.maxY, y: bbox.minX, width: bbox.height, height: bbox.width)
            )
        case 180:
            return (
                imageSize,
                CGRect(x: iw - bbox.maxX, y: ih - bbox.maxY, width: bbox.width, height: bbox.height)
            )
        case 270:
            // (x,y,w,h) → (y, W-x-w, h, w)
            return (
                CGSize(width: ih, height: iw),
                CGRect(x: bbox.minY, y: iw - bbox.maxX, width: bbox.height, height: bbox.width)
            )
        default:
            return (imageSize, bbox)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
