import QuartzCore
import CoreGraphics
import Darwin

// ─────────────────────────────────────────────────────────────────────────────
// BBoxSpringAnimator
//
// Port of Android BBoxAnimator (Kotlin / Choreographer) to Swift / CADisplayLink.
//
// Runs at vsync rate (60 fps), decoupled from camera analysis (6–10 Hz).
// Applies four independent SpringEdge instances — one per bbox edge
// (left, top, right, bottom) — to the latest C++ smoothedBbox target.
//
// ## Why critically-damped spring (replaces One Euro Filter)
// ζ=1 → no overshoot, fastest settle without oscillation (~85 ms at ω=√1200).
// The spring carries internal velocity: when a new target arrives the animation
// continues at the same speed — no visual discontinuity. Unlike One Euro with
// minCutoff=0.4 (~24 frames to converge at rest), the spring settles in ~5 frames.
//
// ## Lag compensation (simplified vs Android)
// Android uses Kalman velocity from C++; iOS bridges do not expose it.
// We extrapolate forward using the spring's own velocity (a good approximation
// after the first detection frame) with a conservative 50% factor to avoid
// overshoot on fast stops. Maximum lag capped at 80 ms.
//
// ## Thread safety
// All state lives on the main thread. setTarget() must be called from main;
// CADisplayLink fires on main. No locks needed.
//
// ## Lifecycle
// Card appears → spring snaps to first target (pos=NaN → snap), animates.
// Card lost   → nil passed to setTarget → all springs reset, smoothedBounds = nil.
// Stop        → CADisplayLink invalidated, no CPU usage.
// ─────────────────────────────────────────────────────────────────────────────

internal final class BBoxSpringAnimator {

    // ── Public output ─────────────────────────────────────────────────────────
    /// Smoothed bbox in view coordinates. Updated on every display tick.
    /// Nil when no card is visible. Read on main thread only.
    private(set) var smoothedBounds: CGRect?

    // ── Target ────────────────────────────────────────────────────────────────
    /// Latest detection target. Set from setTarget() on the main thread.
    private var targetBounds: CGRect?
    /// CACurrentMediaTime() when the source camera frame arrived.
    /// Used to measure pipeline lag and extrapolate the target forward.
    private var lastCaptureTimestamp: TimeInterval = 0

    // ── Spring state (main-thread only, one per bbox edge) ────────────────────
    private var springLeft   = SpringEdge()
    private var springTop    = SpringEdge()
    private var springRight  = SpringEdge()
    private var springBottom = SpringEdge()

    // ── Display link ──────────────────────────────────────────────────────────
    private var displayLink: CADisplayLink?
    private var onUpdate:    (() -> Void)?
    private var prevTickTs:  TimeInterval = 0

    // ── Spring constants (mirrors Android BBoxAnimator) ───────────────────────

    /// Natural frequency ω = √1200 ≈ 34.6 rad/s → settles ~85 ms.
    /// Rollback: √800 (ω ≈ 28.3 rad/s, ~105 ms) if jitter observed on device.
    static let springOmega: Float = sqrtf(1200)

    /// Damping ratio ζ=1 → critically damped (no overshoot, no oscillation).
    static let springZeta:  Float = 1.0

    /// Maximum pipeline lag to compensate in seconds (80 ms = Android MAX_LAG_NS).
    static let maxLagSec:   TimeInterval = 0.08

    /// Fraction of measured lag to extrapolate (0.5 = conservative).
    /// Android uses 1.0 with Kalman velocity gate; without Kalman we use 0.5.
    static let lagFactor:   Float = 0.5

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    /// Start the 60-fps display-link loop.
    /// - Parameter onUpdate: Called every frame; trigger `setNeedsDisplay()` here.
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
        onUpdate    = nil
    }

    // ── Target update (main thread) ───────────────────────────────────────────

    /// Update the target bbox from the latest detection frame.
    ///
    /// - Parameter rect: Card bbox in view coordinates, or `nil` when card is lost.
    /// - Parameter captureTimestamp: `CACurrentMediaTime()` when the source frame
    ///   arrived at the AVCaptureVideoDataOutput delegate — used for lag compensation.
    func setTarget(_ rect: CGRect?, captureTimestamp: TimeInterval = 0) {
        guard let rect else {
            // Card lost: reset all springs immediately (no spring-to-zero "fly-away").
            targetBounds         = nil
            smoothedBounds       = nil
            lastCaptureTimestamp = 0
            prevTickTs           = 0
            springLeft.reset(); springTop.reset()
            springRight.reset(); springBottom.reset()
            return
        }
        targetBounds = rect
        if captureTimestamp > 0 {
            lastCaptureTimestamp = captureTimestamp
        }
    }

    // ── CADisplayLink tick ────────────────────────────────────────────────────

    @objc private func tick() {
        guard let link = displayLink else { return }

        // Card lost since last tick — clear and redraw once (erase the overlay).
        guard let target = targetBounds else {
            if smoothedBounds != nil {
                smoothedBounds = nil
                onUpdate?()
            }
            return
        }

        let frameTs = link.timestamp

        // dt for spring integration. First frame assumes 60 fps to avoid a
        // large initial step from a zero prevTickTs.
        let dt: Float = prevTickTs > 0
            ? min(Float(frameTs - prevTickTs), 0.1)
            : Float(1.0 / 60.0)
        prevTickTs = frameTs

        // ── Lag compensation ──────────────────────────────────────────────────
        // The camera preview renders at vsync; YOLO inference takes 30–80 ms.
        // Extrapolate the target forward by spring velocity * measured lag * 0.5.
        // Using spring velocity instead of Kalman: good approximation after the
        // first few frames; zero for stationary cards → no overshoot on stop.
        let lagSec: Float = lastCaptureTimestamp > 0
            ? min(Float(frameTs - lastCaptureTimestamp), Float(Self.maxLagSec))
            : 0

        var predL = Float(target.minX)
        var predT = Float(target.minY)
        var predR = Float(target.maxX)
        var predB = Float(target.maxY)

        if lagSec > 0 && !springLeft.isUninitialized {
            let lag = lagSec * Self.lagFactor
            predL += springLeft.vel   * lag
            predT += springTop.vel    * lag
            predR += springRight.vel  * lag
            predB += springBottom.vel * lag
        }

        // ── Spring integration ────────────────────────────────────────────────
        let l = springLeft.update(target:  predL, dt: dt)
        let t = springTop.update(target:   predT, dt: dt)
        let r = springRight.update(target:  predR, dt: dt)
        let b = springBottom.update(target: predB, dt: dt)

        smoothedBounds = CGRect(
            x:      CGFloat(l),
            y:      CGFloat(t),
            width:  CGFloat(r - l),
            height: CGFloat(b - t)
        )
        onUpdate?()
    }

    deinit { stop() }
}

// ─────────────────────────────────────────────────────────────────────────────
// SpringEdge — scalar critically-damped spring.
//
// Physics: ẍ + 2ζω(ẋ) + ω²(x − target) = 0 , ζ = 1 (critically damped).
// Integration: semi-implicit Euler — stable at typical vsync dt (≈ 1/60 s).
//
// State is main-thread-only (BBoxSpringAnimator guarantee).
// ─────────────────────────────────────────────────────────────────────────────

private struct SpringEdge {
    /// Current position. NaN before the first target is received.
    var pos: Float = .nan
    /// Current velocity (px/s). Readable by BBoxSpringAnimator for lag compensation.
    var vel: Float = 0

    var isUninitialized: Bool { pos.isNaN }

    /// Advance the spring by `dt` seconds toward `target`.
    /// Returns the new position.
    mutating func update(target: Float, dt: Float) -> Float {
        // Snap to target on first appearance — avoids lerping from zero.
        if pos.isNaN {
            pos = target
            vel = 0
            return pos
        }
        let ω = BBoxSpringAnimator.springOmega
        let ζ = BBoxSpringAnimator.springZeta
        // Critically damped spring acceleration.
        let acc = -2 * ζ * ω * vel - ω * ω * (pos - target)
        vel += acc * dt
        pos += vel * dt
        return pos
    }

    mutating func reset() {
        pos = .nan
        vel = 0
    }
}
