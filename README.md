# Mergen iOS SDK

Binary SPM distribution of the Mergen ID-card scanning SDK.

## What's new in 2.6.0

A new on-device frame gate — model `m16` (MobileNetV2 w=0.5, 2.8 MB FP32, 698k
parameters, input = the rectified 256×160 card crop) — now judges the frame while
the user is still aiming, before anything is recognised.

- **The card is turned right way up automatically** (`orient` head; accuracy 0.9963
  on real crops, one miss in 272). An upside-down card is rotated *before*
  recognition. This retires the old rot-180 retry — one to two extra full cascade
  passes, i.e. seconds on device — and fixes side detection, which used to answer
  confidently wrong on an upside-down card.
- **A finger on the data blocks capture** (`finger` head, threshold 0.99). Recall
  11/12 on real hands, and no false positives measured anywhere: 0/68 clean crops,
  0/12 frames where the card is held by its edge, 0/38 fronts carrying a portrait.
  The frame turns red and the hint names the covered field — «Уберите палец с номера
  документа». Safety fuse: an occlusion held continuously for longer than 20 s lifts
  the veto, so the camera can never hang (`quality_gate_block_timeout_ms`).
- **Per-field report.** The occlusion mask is intersected with the field zones; the
  right field is named in 8 cases out of 10 (mask probability 0.5, coverage 0.25).
- **The gate is polled every 350 ms** while the user aims
  (`quality_gate_probe_interval_ms`).

Off by default (threshold `1.1` = never fires; both heads ship inside the model and
are enabled by threshold alone, no rebuild):

- `shadow` — false positives on live capture: while aiming, the phone itself casts a
  shadow on the card. That is normal shooting geometry, not a defect, and it does not
  hurt OCR.
- `dirt` — recall 0.300 on honest dirt; the accuracy gate was not passed.

### Breaking change: `ScanStatus.occluded`

`ScanStatus` gained one case, `occluded`. **Exhaustive `switch` statements over
`ScanStatus` stop compiling until they handle it.** The case is declared last, and the
enum has no raw value, so nothing else about the contract shifts.

Until 2.6.0 such frames were reported as `.holdSteady` — while the frame on screen was
already red. The status now says what the UI shows.

Coming from **v2.5.1**, the previous tag published here, there is nothing to migrate:
`ScanStatus` itself arrives with this release (see "Also in this tag" below). The
migration matters if you already track the typed statuses from the 2.5.2 line.

```swift
switch state.scanStatus {
case .noCard, .cardOutsideGuide:
    hint = "Наведите карту на рамку"
case .holdSteady, .analyzing, .capturing:
    hint = state.messageTitle

// ← NEW in 2.6.0. Add this branch; everything else stays as it was.
case .occluded:
    // state.occlusionType     — .finger or .shadow
    // state.occludedFieldId   — which field is covered (-1 = not named)
    // state.messageTitle      — ready-made Russian hint, e.g.
    //                           «Уберите палец с номера документа»
    hint = state.messageTitle

case .wrongSide, .notKgDocument, .flipDocument,
     .tooClose, .tooFar, .tooBright, .tooDark:
    hint = state.messageTitle
case .finished(let success):
    hint = success ? "Готово" : "Не удалось"
}
```

If your `switch` already ends in `default:`, it keeps compiling untouched — but it will
route occluded frames into the default branch, so add the case anyway to show the hint.

### New fields on `ScannerFrameState`

The verdict does not arrive on every frame — the SDK holds the last positive verdict
for a short window (≈0.8 s), so these fields are already smoothed; no debounce of your
own is needed. All three ways of reporting an occlusion (`scanStatus`, the fields
below, and `messageTitle`) are resolved in the same cascade and cannot disagree.

| Field | Type | Meaning |
|---|---|---|
| `isFingerOccluded` | `Bool` | A finger / hand is on the card. Capture is vetoed while it is there. |
| `isShadowed` | `Bool` | A hard local shadow on the card. Always `false` at the shipped default (the `shadow` head is off). |
| `occludedFieldId` | `Int` | `ocr::FieldId` as an int: `0` = surname, `6` = document number, `12` = MRZ, …; `100` = portrait; `-1` = not named (the occlusion is outside the zones, or the side is not classified yet). |
| `occlusionType` | `OcclusionType` | `.none` / `.finger` / `.shadow`. Filled in even when the field could not be named. |

### Engine defaults for the gate

These are `PipelineConfig` keys inside the engine, shipped at the values below.
`MergenScannerConfig` does not expose them in 2.6.0 — the defaults are what runs.

| Key | Default | Meaning |
|---|---|---|
| `enable_quality_gate` | `true` | The gate as a whole. |
| `quality_gate_finger_threshold` | `0.99` | Finger probability that vetoes capture. |
| `quality_gate_shadow_threshold` | `1.1` | Disabled (see above). |
| `quality_gate_dirt_threshold` | `1.1` | Disabled (see above). |
| `quality_gate_block_timeout_ms` | `20000` | Safety fuse: after this much continuous blocking the gate steps aside. |
| `quality_gate_probe_interval_ms` | `350` | How often the gate is polled while aiming. |
| `quality_gate_field_coverage` | `0.25` | Share of a field's zone the mask must cover before that field is named. |
| `quality_gate_auto_rotate` | `true` | Rotate an upside-down card before recognition. |

### Also in this tag: 2.5.2, which was never published here

The previous tag in this repo is `v2.5.1`, so `v2.6.0` also carries everything from
2.5.2 — the release aimed at integrators who drive their own UI over the scanner:

- `ScanStatus` — the typed per-frame status (13 cases then, 14 now with `.occluded`),
  resolved in the same priority cascade as the SDK's own strings, so text and status
  cannot disagree. It inherits the existing hysteresis; no debounce of your own.
- `onFrameState` on `MergenScannerView` / `MergenScannerViewController`, and
  `awaitingFlip` / `setAwaitingFlip(_:)`. Fixes the frozen state a custom overlay used
  to receive: the callback fired inside the `@ViewBuilder`, during SwiftUI's render
  phase, where `@State` mutations are swallowed — it is delivered from `.onReceive` now.
- Torch on the drop-in surfaces (`torchOn` binding, `setFlashlightEnabled(_:)`) plus
  `ScannerEvent.torchChanged`; `ScannerEvent.documentLost` (previously Android-only).
- An overexposure signal for the card ROI (informational — capture behaviour unchanged),
  and `allowUnknownVersion` on `MergenScannerConfig`.
- Fixed: `customOverlayRenderer` set after `present` never reached the view, and
  assigning `style` before `viewDidLoad` crashed. `.tooClose` / `.tooFar` were
  unreachable with the SDK hints turned off — exactly the configuration this line of
  work exists for.

## Integration

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/DanielPHP01/MergenSDK-iOS", from: "2.6.0")
]
// target dependency:
.target(name: "YourApp", dependencies: [.product(name: "Mergen", package: "MergenSDK-iOS")])
```

Or in Xcode: File → Add Package Dependencies… → `https://github.com/DanielPHP01/MergenSDK-iOS`.

```swift
import Mergen

// Two-sided verification — front and back of the same card.
let result = try await MergenSDK.verify(front: frontImage,
                                        back:  backImage,
                                        license: licenseJson)
print(result.status)   // VerifyStatus

// Drop-in camera UI:
//   SwiftUI — MergenScannerView(licenseKey:onFinished:)
//   UIKit   — MergenScannerViewController(licenseKey:)
//
// Warm the engine up ahead of the first scan (optional, hides model load time):
MergenSDK.warmUp(license: licenseJson)
```

The example above used `MergenEngine(licenseJson:)` through 2.2.0 — a type that
is not public in the binary wrapper, so the snippet did not compile. The engine
is reached through the `MergenSDK` façade and the scanner views instead.

License JSON must be added to your app target's resources (or supplied at
runtime) — every entry point requires a non-empty, cryptographically valid
license and fails otherwise. `MergenSDK.loadLicense(named:in:)` reads it from a
bundle for you.

## Package layout

- `MergenSwift.xcframework` — one binaryTarget, committed in this repo and
  referenced by path, so it arrives with the git checkout and needs no second
  authentication step. The Swift wrapper is precompiled, and the C++ core,
  OpenCV, ONNX Runtime and OpenSSL are linked statically inside it. Your target
  needs no `linkerSettings` for any of them (2.1.x required nine).
- `Sources/MergenResources/` — encrypted model/dict assets (~36 MB; `m16` added
  2.8 MB in 2.6.0), versioned in this git repo. They live in a source target
  because a binaryTarget cannot carry SPM resources, and embedding them per-slice
  would duplicate them across the device and simulator slices.
- `Sources/MergenDebugger/` — optional PII diagnostics module (source).
  Logging and formatting only. **Never link this into a production target.**

## Publishing a new version (owner-run, manual)

This package is generated by `scripts/release_ios.sh` in the main
`ScanIdCards` repo. To cut version `2.6.0`:

1. Generate the package (already done to produce this tree):
   ```bash
   SDK_VERSION=2.6.0 ./scripts/release_ios.sh
   ```
2. Initialize / update this directory as its own git repo and push it to
   `https://github.com/DanielPHP01/MergenSDK-iOS`:
   ```bash
   cd dist/MergenSDK-iOS
   git init                                   # first release only
   git remote add origin https://github.com/DanielPHP01/MergenSDK-iOS.git   # first release only
   git add -A
   git commit -m "Mergen iOS SDK v2.6.0"
   git push -u origin main
   git tag v2.6.0
   git push origin v2.6.0
   ```
3. Create the GitHub Release for the tag. SPM does not need this asset (the
   xcframework is committed in the repo — see Package layout); it is attached
   for clients who integrate manually without SwiftPM:
   ```bash
   gh release create v2.6.0 \
       dist/release-assets/MergenSwift.xcframework.zip \
       --repo DanielPHP01/MergenSDK-iOS \
       --title "Mergen iOS SDK v2.6.0" \
       --notes-file CHANGELOG_SECTION.md   # or --generate-notes
   ```
4. Verify a fresh clone resolves the published tag (not local paths):
   ```bash
   swift package resolve   # in a throwaway client package pointing at the tag
   ```
5. Confirm the checksums recorded in `Package.swift` match
   `dist/release-assets/checksums.txt` — they are generated together by
   `release_ios.sh` and must never be hand-edited independently.

**Before step 2**, make sure the packaged `Mergen.xcframework` device slice
is a real production build (`-DIDCARD_PRODUCTION_BUILD=1`, no
`IDCARD_FORCE_LOGS`) — see the WARN printed by `release_ios.sh` Gate 1a and
`docs/RELEASE_CHECKLIST.md`.
