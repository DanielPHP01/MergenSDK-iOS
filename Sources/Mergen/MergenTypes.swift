//
//  MergenTypes.swift
//  Mergen SDK
//
//  Created by Daniel Almazbekov
//

import Foundation
import UIKit

public enum EngineState: Int {
    case idle = 0
    case detecting = 1
    case captured = 2
    case finishedSuccess = 3
    case finishedFailure = 4
}

public enum CardVersion: Int {
    case unknown   = -1
    case back2008  =  0
    case back2017  =  1
    case back2025  =  2
    case front2008 =  3
    case front2017 =  4
    case front2025 =  5
}

enum StatusCode: Int {
    case ok = 0
    case warnCardLost = 100
    case warnLowQuality = 101
    case errNotInitialized = 200
    case errInvalidConfigJson = 201
    case errModelEmpty = 202
    case errModelLoadFailed = 203
    case errImageEmpty = 300
    case errImageTooSmall = 301
    case errInternalException = 302
}

struct FrameResult {
    var status: StatusCode = .ok
    var state: EngineState = .idle
    var isFinished: Bool = false
    var isPassed: Bool = false
    var progress: Float = 0.0
    var failReason: String = ""

    var messageTitle: String = ""
    var messageHint: String = ""
    var cardBbox: CGRect = .zero
    var hasCard: Bool = false
    var confidence: Float = 0.0

    var imageWidth: Int = 640
    var imageHeight: Int = 480

    /// Card layout version. .unknown when classifier is not loaded.
    var cardVersion: CardVersion = .unknown
    var isFlipped: Bool = false
    /// EMA-smoothed bbox from C++ engine (sub-pixel precision).
    /// Prefer this over cardBbox for overlay rendering to reduce jitter.
    var smoothedBbox: CGRect = .zero
    /// True when the card hasn't moved > 5px for 3+ consecutive frames.
    /// The overlay should use colorSuccess (green) and show "Замрите" hint.
    var cardIsStill: Bool = false
    /// True when the engine's smart-rescan gate blocked the capture on this frame
    /// (critical fields not yet confident).  Signals the controller to snap ONE
    /// high-resolution still photo and feed it via `processStillFrame(image:)`
    /// instead of continuing the video rescan loop (v2.1 still-capture flow).
    var stillCaptureWanted: Bool = false

    // ── Lighting / quality hints (ios_bridge slots [21..23]) ─────────────────
    // Used by ScannerEngineController to surface actionable UX hints
    // ("Слишком ярко" / "Слишком темно") in the detecting state.
    // Only shown when the card is visible and no higher-priority message is active.

    /// Glare / overexposure detected on the card surface.
    var isGlared: Bool = false
    /// Frame is too dark for reliable OCR.
    var isDark:   Bool = false
    /// Frame is too blurry (motion blur / shake) for reliable OCR.
    var isBlurry: Bool = false

    // ── Probe ticker (ios_bridge slots [24..25]) ─────────────────────────────
    // Populated by all C++ frame-processing functions when the bridge buffer is >=26 slots.
    // Used by ScannerEngineController's side-gate state machine to detect NEW verdicts
    // (seq increase) and debounce Unknown/wrong-side noise.

    /// Monotonic counter of completed m9 probe inferences.
    /// Increments by 1 on EVERY finished probe (confident OR Unknown); 0 = no probe yet.
    /// Resets on engine reset() / side transition. Use as a change-detector: a new verdict
    /// is available only when `probeSeq > lastSeenProbeSeq`.
    var probeSeq: Int = 0

    /// Raw CardVersion int from the latest probe BEFORE the engine's cached-result filter.
    /// -1 = Unknown (probe ran but classifier returned no confident class).
    /// 0–5 = specific CardVersion (matches CardVersion.rawValue).
    /// This is the RAW verdict, not the cached `cardVersion` (which never reverts to .unknown).
    var probeLastVerdict: Int = -1
}

