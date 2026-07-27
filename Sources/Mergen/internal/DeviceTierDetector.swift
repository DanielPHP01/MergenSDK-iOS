import Foundation

/// Detects the device hardware tier for adaptive performance settings.
///
/// Tier mapping (mirrors Android `DeviceTierDetector`):
///   0 (weak)   — physicalMemory < 3 GB  OR  processorCount ≤ 4
///   1 (mid)    — physicalMemory < 4 GB
///   2 (strong) — otherwise
///
/// The result drives three adaptive behaviours:
///   - `"device_tier"` in the C++ engine config JSON (ORT thread allocation
///     via `ort_session_config.h` — same key as Android)
///   - `"ort_intra_op_cap": 2` auto-injected in `toEngineJson()` on tier-0
///     (leaves CPU headroom for Metal / CADisplayLink / UI layers)
///   - CADisplayLink `preferredFramesPerSecond = 30` on tier-0
///   - CMMotionManager gyroscope update interval 30 Hz instead of 60 Hz on tier-0
///
/// Detection reads immutable system properties — safe to call from any thread.
/// Callers should cache the result for the scanner session lifetime.
internal enum DeviceTierDetector {

    /// Returns 0, 1, or 2.
    @inline(__always)
    static func detect() -> Int {
        let cores = ProcessInfo.processInfo.processorCount
        let ramMB = ProcessInfo.processInfo.physicalMemory / 1_048_576
        var tier: Int
        switch ramMB {
        case ..<3_072: tier = 0
        case ..<4_096: tier = 1
        default:       tier = 2
        }
        // ≤4 cores (A9/A10-class SoCs) → cap at tier 0 regardless of RAM.
        if cores <= 4 { tier = 0 }
        return tier
    }
}
