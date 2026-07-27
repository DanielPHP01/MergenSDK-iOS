import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
import QuartzCore

// ─────────────────────────────────────────────────────────────────────────────
// One Euro Filter — adaptive low-pass filter for real-time noisy signals.
//
// At low speed (still card): high smoothing, eliminates jitter.
// At high speed (moving card): low smoothing, eliminates lag.
//
// Reference: Géry Casiez et al. "1€ Filter: A Simple Speed-based Low-pass
// Filter for Noisy Input in Interactive Systems", CHI 2012.
// Used by MediaPipe, ARKit, and Google ML Kit for landmark smoothing.
// ─────────────────────────────────────────────────────────────────────────────

private struct OneEuroFilter {
    // ── Tunable parameters ─────────────────────────────────────────────────
    /// Minimum cutoff frequency (Hz). Lower → more smoothing at rest. Default 1.0.
    var minCutoff: Double
    /// Speed coefficient. Higher → faster tracking during motion. Default 0.007.
    var beta: Double
    /// Cutoff for the derivative low-pass (Hz). Rarely needs tuning. Default 1.0.
    var dCutoff: Double

    private var xPrev:       Double = 0
    private var dxPrev:      Double = 0
    private var tPrev:       Double = 0
    private var initialized: Bool   = false

    init(minCutoff: Double = 1.0, beta: Double = 0.007, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta      = beta
        self.dCutoff   = dCutoff
    }

    /// α = (2π · cutoff · te) / (2π · cutoff · te + 1)
    private func alpha(te: Double, cutoff: Double) -> Double {
        let r = 2.0 * .pi * cutoff * te
        return r / (r + 1.0)
    }

    /// Filter a new sample `x` at the given wall-clock `timestamp` (seconds).
    /// Returns the filtered value. Thread-unsafe — each call site owns its own instance.
    mutating func filter(_ x: Double, timestamp: Double) -> Double {
        guard initialized else {
            xPrev = x; tPrev = timestamp; initialized = true
            return x
        }
        let te = timestamp - tPrev
        guard te > 0 else { return xPrev }
        tPrev = timestamp

        // Filtered derivative
        let dx   = (x - xPrev) / te
        let edx  = alpha(te: te, cutoff: dCutoff)
        dxPrev   = edx * dx + (1.0 - edx) * dxPrev

        // Adaptive cutoff driven by speed
        let cutoff = minCutoff + beta * abs(dxPrev)
        let a      = alpha(te: te, cutoff: cutoff)
        xPrev      = a * x + (1.0 - a) * xPrev
        return xPrev
    }

    mutating func reset() { initialized = false; dxPrev = 0 }
}

// ─────────────────────────────────────────────────────────────────────────────
// BBoxInterpolator
//
// Smooths bounding box transitions using One Euro Filters driven by
// CADisplayLink (60/120 fps). Receives target bbox from the engine (~30 fps)
// and produces a smooth, jitter-free interpolated rect for rendering.
//
// Design:
//   • Four OneEuroFilter instances (x, y, w, h) run at display rate.
//   • Feeding the same stale target every tick is correct: the derivative
//     converges to 0 → filter settles at minCutoff → slow convergence.
//   • On a new large-jump detection: speed spike → beta raises cutoff → fast
//     tracking. No explicit velocity prediction needed.
//   • Gyro prediction (optional) applies a pixel offset before the filter
//     output for instant visual response to phone rotation.
// ─────────────────────────────────────────────────────────────────────────────

@available(iOS 4.0, macOS 14.0, *)
internal final class BBoxInterpolator {

    /// The smoothed bounding box for rendering (updated on every display tick).
    private(set) var interpolatedBBox: CGRect?

    /// Latest target bbox from the engine frame.
    private var targetBBox: CGRect?

    // ── One Euro Filter tuning ────────────────────────────────────────────
    /// Minimum cutoff frequency (Hz). Lower → more smoothing at rest.
    /// Increase if the overlay still jitters on a stationary card.
    var minCutoff: Double = 1.0

    /// Speed coefficient. Higher → faster tracking during fast motion.
    /// Increase if the overlay lags visibly when the user sweeps the card.
    var beta: Double = 0.007

    // ── Gyroscope prediction ──────────────────────────────────────────────
    /// Called every display-link tick to consume accumulated gyro delta
    /// (pitch, yaw) in radians. Supply `nil` to disable (graceful degradation).
    var gyroConsumer: (() -> (pitch: CGFloat, yaw: CGFloat))? = nil

    /// View width in points — needed for radian→pixel conversion.
    var viewWidthPx: CGFloat = 0

    private static let fovRadians: CGFloat = .pi / 3  // ≈ 60° horizontal FoV

    // ── Lag compensation ──────────────────────────────────────────────────
    /// Wall-clock timestamp (CACurrentMediaTime) of the camera frame that
    /// produced the current targetBBox. Set via setTarget(_:captureTimestamp:).
    private var lastCaptureTimestamp: TimeInterval = 0

    /// Filtered position from the previous display tick — used to estimate
    /// per-tick velocity for the forward extrapolation step.
    private var prevFilteredX: Double = 0
    private var prevFilteredY: Double = 0

    // ── Internals ─────────────────────────────────────────────────────────
    // Tuned 2026-07-12 (device feedback: overlay still trembles at rest with the
    // defaults minCutoff=1.0 / beta=0.007). Lower minCutoff → much stronger
    // smoothing at rest; higher beta compensates so fast card motion stays snappy
    // (1€ design intent: jitter is a low-speed problem, lag is a high-speed one).
    // Rollback: OneEuroFilter() defaults.
    private var filterX = OneEuroFilter(minCutoff: 0.4, beta: 0.015)
    private var filterY = OneEuroFilter(minCutoff: 0.4, beta: 0.015)
    private var filterW = OneEuroFilter(minCutoff: 0.4, beta: 0.015)
    private var filterH = OneEuroFilter(minCutoff: 0.4, beta: 0.015)

    private var displayLink: CADisplayLink?
    private var onUpdate: (() -> Void)?

    // ── Lifecycle ─────────────────────────────────────────────────────────

    func start(onUpdate: @escaping () -> Void) {
        self.onUpdate = onUpdate
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        onUpdate = nil
    }

    /// Update the target bbox from the latest engine frame.
    /// - Parameters:
    ///   - bbox: Card bounding box in view coordinates, or `nil` when not detected.
    ///   - captureTimestamp: `CACurrentMediaTime()` value captured when the source
    ///     frame arrived at the AVCaptureVideoDataOutput delegate. Used to measure
    ///     the processing lag and extrapolate the overlay position forward in time.
    func setTarget(_ bbox: CGRect?, captureTimestamp: TimeInterval = 0) {
        guard let bbox else {
            targetBBox            = nil
            interpolatedBBox      = nil
            lastCaptureTimestamp  = 0
            filterX.reset(); filterY.reset()
            filterW.reset(); filterH.reset()
            return
        }
        if interpolatedBBox == nil {
            // First appearance — snap filters to avoid lerping from zero.
            let t = displayLink?.timestamp ?? CACurrentMediaTime()
            _ = filterX.filter(Double(bbox.origin.x), timestamp: t)
            _ = filterY.filter(Double(bbox.origin.y), timestamp: t)
            _ = filterW.filter(Double(bbox.width),    timestamp: t)
            _ = filterH.filter(Double(bbox.height),   timestamp: t)
            interpolatedBBox = bbox
            // Seed velocity tracking to the snapped position (first tick → vx/vy ≈ 0).
            prevFilteredX = Double(bbox.origin.x)
            prevFilteredY = Double(bbox.origin.y)
        }
        lastCaptureTimestamp = captureTimestamp
        targetBBox = bbox
    }

    // ── Display link tick (60 / 120 fps) ──────────────────────────────────

    @objc private func tick() {
        guard let link = displayLink else { return }

        guard let target = targetBBox else {
            if interpolatedBBox != nil {
                interpolatedBBox = nil
                onUpdate?()
            }
            return
        }

        let ts = link.timestamp

        // Run 1€ filters for each coordinate at display rate.
        // Feeding the same target value when detection hasn't updated is correct:
        // derivative→0 → minCutoff dominates → slow convergence to target.
        var fx = CGFloat(filterX.filter(Double(target.origin.x), timestamp: ts))
        var fy = CGFloat(filterY.filter(Double(target.origin.y), timestamp: ts))
        let fw = CGFloat(filterW.filter(Double(target.width),    timestamp: ts))
        let fh = CGFloat(filterH.filter(Double(target.height),   timestamp: ts))

        // ── Lag extrapolation ─────────────────────────────────────────────────
        // The camera preview renders frames in real time on CALayer, but YOLO
        // inference takes ~30-50 ms, so the bbox is always behind the live image.
        // Strategy: measure the velocity of the filtered signal over consecutive
        // display ticks, then extrapolate forward by half the observed lag.
        // Using 0.5× is conservative — avoids over-shooting on fast motion.
        let displayDt = max(link.duration, 1.0 / 120.0)   // guard against 0
        let vx = (Double(fx) - prevFilteredX) / displayDt
        let vy = (Double(fy) - prevFilteredY) / displayDt
        prevFilteredX = Double(fx)
        prevFilteredY = Double(fy)

        if lastCaptureTimestamp > 0 {
            let lagSeconds = max(0, ts - lastCaptureTimestamp)
            if lagSeconds > 0 && lagSeconds < 0.15 {   // sanity clamp: ignore stale frames
                fx += CGFloat(vx * lagSeconds * 0.5)
                fy += CGFloat(vy * lagSeconds * 0.5)
            }
        }

        // Gyro prediction: shift the filtered position for instant visual
        // response to phone rotation, without waiting for a YOLO frame.
        let w = viewWidthPx
        if let consume = gyroConsumer, w > 0 {
            let (pitch, yaw) = consume()
            if pitch != 0 || yaw != 0 {
                let pxPerRad = w / BBoxInterpolator.fovRadians
                fx += -yaw   * pxPerRad   // yaw right  → card moves left
                fy += -pitch * pxPerRad   // pitch down → card moves up
            }
        }

        let filtered = CGRect(x: fx, y: fy, width: fw, height: fh)

        // Snap when sub-pixel close to the raw target to stop endless micro-updates.
        let eps: CGFloat = 0.3
        if abs(filtered.origin.x - target.origin.x) < eps,
           abs(filtered.origin.y - target.origin.y) < eps,
           abs(filtered.width    - target.width)    < eps,
           abs(filtered.height   - target.height)   < eps {
            interpolatedBBox = target
        } else {
            interpolatedBBox = filtered
        }

        onUpdate?()
    }

    deinit { stop() }
}
