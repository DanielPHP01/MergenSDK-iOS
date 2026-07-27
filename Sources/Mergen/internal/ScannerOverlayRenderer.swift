import UIKit
import CoreGraphics
import QuartzCore

/// Pure-canvas renderer for the default overlay (UIKit / Core Graphics path).
///
/// Stateless — driven entirely by `ScannerFrameState` + `ScannerStyle`.
/// Used by both `ScannerOverlayUIView` and the SwiftUI canvas bridge.
internal final class ScannerOverlayRenderer {

    private let density: CGFloat   // screen scale

    init(density: CGFloat = UIScreen.main.scale) {
        self.density = density
    }

    func draw(
        in context: CGContext,
        bounds: CGRect,
        state: ScannerFrameState,
        style: ScannerStyle
    ) {
        let safeBottom = Self.safeAreaBottom

        // Guide frame active: replace the regular full-dim with a dim-with-cutout
        // so the guide area stays clear. Guide is drawn ONLY while the card has not
        // yet been accepted into the guide (isCardInGuide=false) and the scan has
        // not finished — avoids overlaying the success / finalization states.
        let showGuide = style.showGuideFrame && !state.isCardInGuide && !state.isFinished
        if showGuide {
            drawGuideDim(context: context, bounds: bounds)
        } else {
            drawDim(context: context, bounds: bounds, style: style)
        }

        if state.hasCard,
           let rect = state.cardBoundsInView,
           style.bboxDrawStyle != .none {
            drawBBox(context: context, rect: rect, state: state, style: style)
        }

        // Scan-line animation: replaced by a CAGradientLayer bouncing inside the
        // bbox in _ScannerOverlayDrawView / ScannerOverlayUIView (Фикс A).
        // The render-server drives the animation independently of the main-thread
        // CGContext redraw cadence, so it stays smooth during OCR-burst CPU spikes.
        // CG path is kept below for reference; the caller passes isScanning=false
        // so this block is never reached even if uncommented.
        // if (state.isAnalyzing || state.isScanning),
        //    state.hasCard,
        //    let rect = state.cardBoundsInView,
        //    style.bboxDrawStyle != .none {
        //     drawScanLine(context: context, rect: rect, style: style)  // CA-слой
        // }

        // Guide stroke: drawn on top of bbox so it is always visible.
        if showGuide {
            drawGuideStroke(context: context, bounds: bounds, state: state)
        }

        drawHint(context: context, bounds: bounds, state: state, style: style, safeBottom: safeBottom)

        if style.showProgressBar, state.progress > 0 {
            drawProgress(context: context, bounds: bounds, progress: CGFloat(state.progress), style: style, safeBottom: safeBottom)
        }

        if style.showConfidenceLabel, state.confidence > 0 {
            drawConfidence(context: context, bounds: bounds, confidence: state.confidence, style: style)
        }
    }

    // ── Guide frame geometry (shared with ScannerEngineController) ────────────
    //
    // ID-1 aspect ratio = 85.6 × 53.98 mm → 1.585.
    // guideW = 0.86 * viewW; guideH = guideW / 1.585.
    // Clamp: if guideH > 0.9 * viewH → guideH = 0.9 * viewH, guideW = guideH * 1.585.
    // Centred horizontally and vertically.
    //
    // MUST stay byte-for-byte in sync with `ScannerEngineController.guideRect(for:)`
    // so that the rendered frame and the capture gate always reference the same rect.

    internal static func guideRect(in bounds: CGRect) -> CGRect {
        let viewW = bounds.width
        let viewH = bounds.height
        var guideW = viewW * 0.86
        var guideH = guideW / 1.585
        if guideH > viewH * 0.9 {
            guideH = viewH * 0.9
            guideW = guideH * 1.585
        }
        let x = bounds.midX - guideW / 2
        let y = bounds.midY - guideH / 2
        return CGRect(x: x, y: y, width: guideW, height: guideH)
    }

    /// Safe area bottom inset (cached per-draw from key window).
    private static var safeAreaBottom: CGFloat {
        if #available(iOS 15.0, *) {
            return UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.keyWindow?.safeAreaInsets.bottom ?? 0
        } else {
            return UIApplication.shared.windows.first?.safeAreaInsets.bottom ?? 0
        }
    }

    // ── Dim ───────────────────────────────────────────────────

    private func drawDim(context: CGContext, bounds: CGRect, style: ScannerStyle) {
        context.setFillColor(UIColor(style.dimColor).cgColor)
        context.fill(bounds)
    }

    // ── Guide frame dim (even-odd cutout) ─────────────────────
    //
    // Draws a semi-transparent black overlay over the ENTIRE view, with a
    // rounded-rect hole punched out at the guide rect position (even-odd fill
    // rule). The cutout shows the camera feed clearly through the guide shape.
    // Alpha ≈ 0.45, slightly darker than the standard dim (0.35), so the
    // guide area stands out as the "active zone".

    private func drawGuideDim(context: CGContext, bounds: CGRect) {
        let guide = Self.guideRect(in: bounds)
        context.saveGState()
        let outer = UIBezierPath(rect: bounds)
        let inner = UIBezierPath(roundedRect: guide, cornerRadius: 14)
        outer.append(inner)
        outer.usesEvenOddFillRule = true
        context.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
        context.addPath(outer.cgPath)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    // ── Guide frame stroke ────────────────────────────────────
    //
    // Rounded-rect outline of the guide area. Stroke colour mirrors the current
    // bbox state colour (`state.activeColor`) so it tracks the neutral/success
    // palette without additional configuration. Stroke width ≈ 2.5 pt.

    private func drawGuideStroke(context: CGContext, bounds: CGRect, state: ScannerFrameState) {
        let guide = Self.guideRect(in: bounds)
        context.saveGState()
        context.setStrokeColor(UIColor(state.activeColor).cgColor)
        context.setLineWidth(2.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let path = UIBezierPath(roundedRect: guide, cornerRadius: 14)
        context.addPath(path.cgPath)
        context.strokePath()
        context.restoreGState()
    }

    // ── BBox ──────────────────────────────────────────────────

    private func drawBBox(
        context: CGContext, rect: CGRect,
        state: ScannerFrameState, style: ScannerStyle
    ) {
        let color   = UIColor(state.activeColor).cgColor
        let stroke  = style.strokeWidth
        let radius  = style.cornerRadius
        let cLen    = style.cornerLength

        context.setStrokeColor(color)
        context.setLineWidth(stroke)
        context.setLineCap(.round)

        switch style.bboxDrawStyle {
        case .fullRect:
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            context.addPath(path.cgPath)
            context.strokePath()

        case .cornersOnly:
            drawCornerBrackets(context: context, rect: rect, strokeWidth: stroke, cornerLen: cLen, radius: radius)

        case .cornersAndRect:
            context.setLineWidth(stroke)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            context.addPath(path.cgPath)
            context.strokePath()
            context.setLineWidth(stroke * 2.2)
            drawCornerBrackets(context: context, rect: rect, strokeWidth: stroke * 2.2, cornerLen: cLen, radius: radius)

        case .none:
            break
        }
    }

    private func drawCornerBrackets(
        context: CGContext, rect: CGRect,
        strokeWidth: CGFloat, cornerLen: CGFloat, radius: CGFloat
    ) {
        let r2  = radius * 0.6
        let l   = rect.minX, t = rect.minY
        let r   = rect.maxX, b = rect.maxY

        let path = UIBezierPath()
        // Top-left
        path.move(to: CGPoint(x: l, y: t + cornerLen))
        path.addLine(to: CGPoint(x: l, y: t + r2))
        path.addQuadCurve(to: CGPoint(x: l + r2, y: t), controlPoint: CGPoint(x: l, y: t))
        path.addLine(to: CGPoint(x: l + cornerLen, y: t))
        // Top-right
        path.move(to: CGPoint(x: r - cornerLen, y: t))
        path.addLine(to: CGPoint(x: r - r2, y: t))
        path.addQuadCurve(to: CGPoint(x: r, y: t + r2), controlPoint: CGPoint(x: r, y: t))
        path.addLine(to: CGPoint(x: r, y: t + cornerLen))
        // Bottom-right
        path.move(to: CGPoint(x: r, y: b - cornerLen))
        path.addLine(to: CGPoint(x: r, y: b - r2))
        path.addQuadCurve(to: CGPoint(x: r - r2, y: b), controlPoint: CGPoint(x: r, y: b))
        path.addLine(to: CGPoint(x: r - cornerLen, y: b))
        // Bottom-left
        path.move(to: CGPoint(x: l + cornerLen, y: b))
        path.addLine(to: CGPoint(x: l + r2, y: b))
        path.addQuadCurve(to: CGPoint(x: l, y: b - r2), controlPoint: CGPoint(x: l, y: b))
        path.addLine(to: CGPoint(x: l, y: b - cornerLen))

        context.addPath(path.cgPath)
        context.strokePath()
    }

    // ── Hint text ─────────────────────────────────────────────

    private func drawHint(
        context: CGContext, bounds: CGRect,
        state: ScannerFrameState, style: ScannerStyle,
        safeBottom: CGFloat = 0
    ) {
        // Show the block when at least one of title or hint is non-empty.
        // Previously gated only on messageHint — side-gate paths set title but NOT hint
        // (hint is intentionally "" to keep the overlay compact), so the block was
        // silently skipped and the title text never appeared on red-bbox frames.
        let hasTitle = !state.messageTitle.isEmpty
        let hasHint  = !state.messageHint.isEmpty
        guard hasTitle || hasHint else { return }

        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: style.titleTextSize, weight: .semibold),
            .foregroundColor: UIColor(style.titleTextColor),
        ]
        let hintAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: style.hintTextSize, weight: .regular),
            .foregroundColor: UIColor(style.hintTextColor),
        ]

        let maxW  = bounds.width * 0.85
        let titleSize = hasTitle
            ? (state.messageTitle as NSString).boundingRect(
                with: CGSize(width: maxW, height: 200),
                options: .usesLineFragmentOrigin, attributes: titleAttr, context: nil).size
            : .zero
        let hintSize = hasHint
            ? (state.messageHint as NSString).boundingRect(
                with: CGSize(width: maxW, height: 200),
                options: .usesLineFragmentOrigin, attributes: hintAttr, context: nil).size
            : .zero

        let pad: CGFloat = 16
        // When only a title is shown (no hint), omit the inter-element gap so the
        // background block doesn't have a spurious empty bottom section.
        let gap: CGFloat = (hasTitle && hasHint) ? 8 : 0
        let blockH = titleSize.height + hintSize.height + gap + pad * 2
        let minBlockW = bounds.width * 0.6
        let blockW = max(max(titleSize.width, hintSize.width) + pad * 2, minBlockW)
        let cx     = bounds.midX
        let usableHeight = bounds.height - safeBottom
        let baseY  = usableHeight * (1 - style.hintPositionFraction) - blockH

        let bgRect = CGRect(x: cx - blockW / 2, y: baseY, width: blockW, height: blockH)
        let bgPath = UIBezierPath(roundedRect: bgRect, cornerRadius: style.hintCornerRadius)
        context.setFillColor(UIColor(style.hintBackgroundColor).cgColor)
        context.addPath(bgPath.cgPath)
        context.fillPath()

        if hasTitle {
            (state.messageTitle as NSString).draw(
                at: CGPoint(x: cx - titleSize.width / 2, y: baseY + pad),
                withAttributes: titleAttr
            )
        }
        if hasHint {
            (state.messageHint as NSString).draw(
                at: CGPoint(x: cx - hintSize.width / 2, y: baseY + pad + titleSize.height + gap),
                withAttributes: hintAttr
            )
        }
    }

    // ── Progress bar ──────────────────────────────────────────

    private func drawProgress(
        context: CGContext, bounds: CGRect, progress: CGFloat, style: ScannerStyle,
        safeBottom: CGFloat = 0
    ) {
        let barW  = bounds.width * 0.72
        let barH  = style.progressHeight
        let r     = style.progressCornerRadius
        let cx    = bounds.midX
        // Positive progressBottomInset pushes the bar further down (towards the screen edge).
        // Increase it when an overlay button sits between the bar and the safe-area bottom.
        let y     = bounds.height - safeBottom - 48 + style.progressBottomInset

        let trackRect = CGRect(x: cx - barW / 2, y: y, width: barW, height: barH)
        let trackPath = UIBezierPath(roundedRect: trackRect, cornerRadius: r)
        context.setFillColor(UIColor(style.progressTrackColor).cgColor)
        context.addPath(trackPath.cgPath)
        context.fillPath()

        let fillW    = barW * min(progress, 1)
        let fillRect = CGRect(x: cx - barW / 2, y: y, width: fillW, height: barH)
        let fillPath = UIBezierPath(roundedRect: fillRect, cornerRadius: r)
        context.setFillColor(UIColor(style.progressColor).cgColor)
        context.addPath(fillPath.cgPath)
        context.fillPath()
    }

    // ── Confidence label ──────────────────────────────────────

    private func drawConfidence(
        context: CGContext, bounds: CGRect, confidence: Float, style: ScannerStyle
    ) {
        let text = String(format: "%.0f%%", confidence * 100)
        let attr: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor(style.hintTextColor),
        ]
        (text as NSString).draw(at: CGPoint(x: bounds.width - 52, y: 20), withAttributes: attr)
    }

    // ── Scan-line animation (ANALYZING state) ─────────────────
    //
    // A horizontal gradient line that bounces vertically inside the bbox,
    // period ≈ 1.2 s. Driven by CACurrentMediaTime() so every draw() call
    // at any frequency produces the correct position. The full-width clip
    // is applied so the line stays strictly inside the card rect.
    //
    // Gradient: semi-transparent on both ends, opaque in the middle; uses the
    // style's colorDetecting (emerald by default) so it matches the neutral colour.

    private let kScanLinePeriod: TimeInterval = 1.2     // seconds per full bounce cycle
    private let kScanLineHeight: CGFloat      = 3.0     // pt (dense enough to be visible)
    private let kScanLineAlpha:  CGFloat      = 0.85

    private func drawScanLine(context: CGContext, rect: CGRect, style: ScannerStyle) {
        // Phase in [0,1]: 0→top, 0.5→bottom, 1→top (ping-pong via triangle wave).
        let t     = CACurrentMediaTime().truncatingRemainder(dividingBy: kScanLinePeriod)
        let phase = t / kScanLinePeriod   // [0, 1)
        // Triangle wave: 0→0.5 goes top→bottom, 0.5→1 goes bottom→top.
        let norm: CGFloat = phase <= 0.5
            ? CGFloat(phase * 2)
            : CGFloat(1.0 - (phase - 0.5) * 2)

        let yCenter = rect.minY + norm * rect.height

        // Clip to the card rect so the line never bleeds outside.
        context.saveGState()
        context.clip(to: rect)

        // Build a horizontal gradient that fades out at both ends.
        let baseColor = UIColor(style.colorDetecting).withAlphaComponent(kScanLineAlpha)
        let fadedColor = UIColor(style.colorDetecting).withAlphaComponent(0)

        let colors: [CGColor] = [fadedColor.cgColor, baseColor.cgColor, baseColor.cgColor, fadedColor.cgColor]
        let locations: [CGFloat] = [0, 0.2, 0.8, 1.0]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) {
            // Hairline rect for the scan bar.
            let lineRect = CGRect(
                x:      rect.minX,
                y:      yCenter - kScanLineHeight / 2,
                width:  rect.width,
                height: kScanLineHeight
            )
            context.clip(to: lineRect)
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: yCenter),
                end:   CGPoint(x: rect.maxX, y: yCenter),
                options: []
            )
        }

        context.restoreGState()
    }
}
