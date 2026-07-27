import CoreGraphics
#if os(iOS)
import CoreMotion
#endif

/// Accumulates gyroscope rotation between calls to `consumeDelta()`.
///
/// CMMotionManager delivers updates on its own queue; `consumeDelta()` is
/// expected to be called from the CADisplayLink tick (main thread). An NSLock
/// protects the accumulator from concurrent access.
///
/// On platforms without a gyroscope (or non-iOS), `isAvailable` is false and
/// all deltas return zero — callers require no conditional code.
internal final class GyroscopeTracker {

#if os(iOS)
    private let motionManager = CMMotionManager()
    private let lock = NSLock()
    private var _deltaPitch: Double = 0
    private var _deltaYaw: Double = 0

    var isAvailable: Bool { motionManager.isGyroAvailable }

    func start() {
        guard isAvailable else { return }
        _deltaPitch = 0
        _deltaYaw   = 0
        motionManager.gyroUpdateInterval = 1.0 / 60.0   // 60 Hz — matches display refresh; integrated angle per frame is unchanged
        motionManager.startGyroUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let dt = self.motionManager.gyroUpdateInterval
            self.lock.lock()
            self._deltaPitch += data.rotationRate.x * dt  // pitch
            self._deltaYaw   += data.rotationRate.y * dt  // yaw
            self.lock.unlock()
        }
    }

    func stop() {
        motionManager.stopGyroUpdates()
        lock.lock()
        _deltaPitch = 0
        _deltaYaw   = 0
        lock.unlock()
    }

    /// Returns accumulated rotation since the last call and resets the accumulator.
    /// - Returns: (pitch, yaw) in radians.
    func consumeDelta() -> (pitch: CGFloat, yaw: CGFloat) {
        lock.lock()
        let pitch = _deltaPitch
        let yaw   = _deltaYaw
        _deltaPitch = 0
        _deltaYaw   = 0
        lock.unlock()
        return (CGFloat(pitch), CGFloat(yaw))
    }
#else
    // Non-iOS stub: gyroscope unavailable, all deltas are zero.
    var isAvailable: Bool { false }
    func start() {}
    func stop() {}
    func consumeDelta() -> (pitch: CGFloat, yaw: CGFloat) { (0, 0) }
#endif
}
