import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// PII diagnostics master switch — iOS wrapper layer
// ─────────────────────────────────────────────────────────────────────────────
//
// Values recognised by the scanner (document number, personal number / ПИН,
// dates, names, MRZ lines, raw Vision text, addExternalOCR JSON payloads) are
// the END USER's personal data, not ours. The unified log is a shared surface:
// `log stream` / `log collect` on a paired Mac, sysdiagnose bundles and any
// bug-report attachment will carry it. Therefore the SDK MUST NOT emit field
// VALUES to os_log in anything a client ever ships.
//
// This constant is the ONLY switch. It is `false` in every build that leaves
// this repo. Flip it to `true` for local field debugging, then flip it back —
// never commit `true`.
//
// The Android mirror of this file is
//   mergen-android-sdk/src/main/java/com/mergen/sdk/internal/PiiTrace.kt
//     (`PII_TRACE`)
//
// KEEP BOTH COPIES OF THIS FILE IDENTICAL:
//   iOSMergenSDK/Sources/internal/PiiTrace.swift          (dev source of truth)
//   xcframework_output/Sources/Mergen/internal/PiiTrace.swift  (SPM distribution)
//
// RULES for adding a log line:
//   * Structural / diagnostic output (counts, lengths, timings, statuses,
//     field NAMES, image dimensions, booleans) is ALWAYS ON — observability
//     must survive; it never contains a field value.
//   * Anything that interpolates a recognised VALUE goes behind `piiTrace`,
//     and the always-on branch logs a de-identified stand-in instead:
//     `<len 9>`, `payload 412 bytes`, `observations=6`, `keys=[doc_number,…]`.
//   * `privacy: .private` is NOT sufficient on its own: it only redacts for
//     remote readers, and a device with a logging profile installed still sees
//     the value. Gate on `piiTrace` as well.
//
// Because this is a module-internal `let` with a literal initialiser, the
// optimiser constant-folds `if piiTrace { … }` and strips the guarded branch
// (and the strings it builds) from release builds.
internal let piiTrace = false

/// De-identified stand-in for a recognised field value, for the always-on branch of a
/// PII-gated log line: `<nil>` / `<empty>` / `<len 9>`.
///
/// Length alone is genuinely useful for debugging (a doc number is 9 chars, a ПИН is 14,
/// an MRZ line is 30/36) while carrying no personal data.
@inline(__always)
internal func piiLen(_ value: String?) -> String {
    guard let value else { return "<nil>" }
    return value.isEmpty ? "<empty>" : "<len \(value.count)>"
}
