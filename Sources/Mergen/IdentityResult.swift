import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// identity_v2 — additive public API (SemVer MINOR 1.0 → 1.1)
//
// All types are ADDITIVE — nothing existing is removed, renamed, or reordered.
// Each enum carries `unknown` as the first case so future server-side additions
// never break exhaustive `switch` expressions on the client side.
//
// Enum case spellings are BYTE-IDENTICAL to the Kotlin counterparts in
// IdentityV2.kt so the shared JSON produced by C++ parses to the same value
// on both platforms — no platform-side translation tables needed.
// ─────────────────────────────────────────────────────────────────────────────

// ── Enums ─────────────────────────────────────────────────────────────────────

/**
 Confidence tier for a single fused identity field.

 | Tier      | Meaning                                                  |
 |-----------|----------------------------------------------------------|
 | confirmed | conf ≥ 0.90 AND (checksum-ok OR ≥2 independent sources)  |
 | probable  | 0.65 ≤ conf < 0.90, one strong source                    |
 | uncertain | conf < 0.65 OR single weak source                        |
 | missing   | no non-empty candidate available                         |
 | unknown   | forward-compat fallback for future values                 |
 */
public enum ConfidenceBadge: String {
    case unknown   = "UNKNOWN"
    case missing   = "MISSING"
    case uncertain = "UNCERTAIN"
    case probable  = "PROBABLE"
    case confirmed = "CONFIRMED"

    /// Case-insensitive factory; returns `.unknown` for unrecognised strings (forward-compat).
    public static func fromString(_ s: String) -> ConfidenceBadge {
        ConfidenceBadge(rawValue: s.uppercased()) ?? .unknown
    }
}

/**
 Cross-side same-document verdict from the C++ reconcile() step.

 | Verdict          | Meaning                                                              |
 |------------------|----------------------------------------------------------------------|
 | sameDocument     | Both sides from the same document (score ≥ τ_same, 0 contradictions)|
 | sameWithWarning  | Score ≥ τ_same but one low-weight field diverges; warn_field downgraded|
 | mismatch         | ≥2 contradictions or a dual-checksum-valid mismatch                  |
 | singleSide       | Only one side was scanned                                            |
 | unknown          | Forward-compat fallback                                              |
 */
public enum SameDocumentVerdict: String {
    case unknown         = "UNKNOWN"
    case singleSide      = "SINGLE_SIDE"
    case sameDocument    = "SAME_DOCUMENT"
    case sameWithWarning = "SAME_WITH_WARNING"
    case mismatch        = "MISMATCH"

    /// Case-insensitive factory; returns `.unknown` for unrecognised strings (forward-compat).
    public static func fromString(_ s: String) -> SameDocumentVerdict {
        SameDocumentVerdict(rawValue: s.uppercased()) ?? .unknown
    }
}

/**
 Structured error code from the identity reconciliation pipeline.

 Codes are populated by the C++ buildErrors() helper and carried verbatim in
 the "errors" array of the "identity_v2" JSON object.
 */
enum IdentityErrorCode: String {
    case unknown             = "UNKNOWN"
    case none                = "NONE"
    case blur                = "BLUR"
    case glare               = "GLARE"
    case dark                = "DARK"
    case partialCrop         = "PARTIAL_CROP"
    case fieldNotDetected    = "FIELD_NOT_DETECTED"
    case checksumFail        = "CHECKSUM_FAIL"
    case lowConfidence       = "LOW_CONFIDENCE"
    case sideMissing         = "SIDE_MISSING"
    case sideMismatch        = "SIDE_MISMATCH"
    case credentialExpired   = "CREDENTIAL_EXPIRED"
    case fieldMismatch       = "FIELD_MISMATCH"

    /// Case-insensitive factory; returns `.unknown` for unrecognised strings (forward-compat).
    static func fromString(_ s: String) -> IdentityErrorCode {
        IdentityErrorCode(rawValue: s.uppercased()) ?? .unknown
    }
}

/**
 Retry action recommended when an error is actionable.

 Corresponds to the "action" field in each error object.
 */
enum RetakeAction: String {
    case unknown        = "UNKNOWN"
    case none           = "NONE"
    case retakeFront    = "RETAKE_FRONT"
    case retakeBack     = "RETAKE_BACK"
    case retakeSideMrz  = "RETAKE_SIDE_MRZ"

    /// Case-insensitive factory; returns `.unknown` for unrecognised strings (forward-compat).
    static func fromString(_ s: String) -> RetakeAction {
        RetakeAction(rawValue: s.uppercased()) ?? .unknown
    }
}

/**
 Severity of an identity error; drives UI styling.

 | Level     | Display         |
 |-----------|-----------------|
 | info      | Grey hint       |
 | warning   | Amber banner    |
 | retryable | Amber + CTA     |
 | error     | Red, no CTA     |
 | unknown   | Forward-compat  |
 */
enum Severity: String {
    case unknown   = "UNKNOWN"
    case info      = "INFO"
    case warning   = "WARNING"
    case retryable = "RETRYABLE"
    case error     = "ERROR"

    /// Case-insensitive factory; returns `.unknown` for unrecognised strings (forward-compat).
    static func fromString(_ s: String) -> Severity {
        Severity(rawValue: s.uppercased()) ?? .unknown
    }
}

/**
 Which document side this object refers to.
 */
enum SideId: String {
    case unknown = "UNKNOWN"
    case front   = "FRONT"
    case back    = "BACK"

    /// Case-insensitive factory; returns `.unknown` for unrecognised strings (forward-compat).
    static func fromString(_ s: String) -> SideId {
        SideId(rawValue: s.uppercased()) ?? .unknown
    }
}

// ── Data structs ──────────────────────────────────────────────────────────────

/**
 A single fused identity field with confidence metadata.

 Corresponds to one element of the "fields" array in "identity_v2".

 - Parameters:
   - name:       Field key, e.g. "doc_number", "birth_date".
   - value:      Best-fused value string; empty when `badge == .missing`.
   - confidence: Raw confidence score [0, 1].
   - tier:       C++ tier string (e.g. "MRZ_CHECKED", "CONFIRMED_VISUAL") — raw string
                 for forward-compat; use `badge` for UI decisions.
   - badge:      Swift-mapped confidence tier; safe for exhaustive `switch`.
   - checksumOk: True when at least one ICAO check digit validated this field.
   - sources:    Source labels that contributed to the fused value.
 */
struct FusedField {
    let name:       String
    let value:      String
    let confidence: Double
    let tier:       String
    let badge:      ConfidenceBadge
    let checksumOk: Bool
    let sources:    [String]
}

/**
 A single structured error from the reconciliation pipeline.

 - Parameters:
   - code:      Machine-readable error code.
   - side:      Which side triggered the error, or `.unknown` for session-level.
   - field:     Specific field name if applicable; nil for side/session errors.
   - severity:  Display severity.
   - messageRu: Human-readable message in Russian (from C++ "message" key).
   - messageEn: Human-readable message in English (from C++ "message_en" key); may be empty.
   - action:    Recommended retake action.
 */
struct IdentityError {
    let code:      IdentityErrorCode
    let side:      SideId
    let field:     String?
    let severity:  Severity
    let messageRu: String
    let messageEn: String
    let action:    RetakeAction
}

/**
 Physical field availability for a specific card version/side.

 Mirrors the C++ `SideFieldAvailability` struct emitted in `identity_v2.sides[].field_availability`.
 Use these flags to conditionally show/hide UI elements (e.g. do NOT show a "PIN" row for
 Front2017/2025 which have no printed PIN field).
 */
public struct FieldAvailability {
    /// Side has a printed doc_number field (true for all versions).
    public let hasVisDoc: Bool
    /// Side has a printed personal_number (PIN) field (only Front2008, Back2017, Back2025).
    public let hasVisPin: Bool
    /// Side has a machine-readable zone (MRZ) (back sides only).
    public let hasMrz: Bool

    public init(hasVisDoc: Bool = true, hasVisPin: Bool = false, hasMrz: Bool = false) {
        self.hasVisDoc = hasVisDoc
        self.hasVisPin = hasVisPin
        self.hasMrz    = hasMrz
    }
}

/**
 Per-side summary carried in the "sides" array of "identity_v2".

 - Parameters:
   - side:              Which side.
   - version:           Card version string, e.g. "Front2025", "Back2017".
   - qualityOk:         Whether quality gates passed for this side.
   - fieldAvailability: Physical field availability for this version/side.
   - ocrProdJson:       Raw OCR_PROD JSON string for this side. Contains doc_number, pin,
                        and (back only) mrz_pin / mrz_doc_number / mrz_full.
                        Nil when the engine is older than the lean-identity feature.
 */
struct SideSummary {
    let side:              SideId
    let version:           String
    let qualityOk:         Bool
    let fieldAvailability: FieldAvailability
    /// Parsed OCR_PROD dictionary for this side. Nil when `ocrProdJson` is absent.
    let ocrProdJson:       String?

    init(
        side:              SideId,
        version:           String,
        qualityOk:         Bool,
        fieldAvailability: FieldAvailability = FieldAvailability(),
        ocrProdJson:       String?           = nil
    ) {
        self.side              = side
        self.version           = version
        self.qualityOk         = qualityOk
        self.fieldAvailability = fieldAvailability
        self.ocrProdJson       = ocrProdJson
    }
}

/**
 The headline confident doc_number or PIN field from "identity_v2".

 Mirrors the top-level "doc_number" / "pin" objects in the JSON.

 - Parameters:
   - value:      Best-fused value; empty string if absent.
   - badge:      Confidence tier.
   - checksumOk: True when ICAO checksum validated this value.
 */
struct SideSnapshot {
    let value:      String
    let badge:      ConfidenceBadge
    let checksumOk: Bool
}

/**
 Same-document cross-side decision from reconcile().

 - Parameters:
   - verdict: The verdict enum.
   - score:   Weighted similarity score [0, 1]; 0.0 when not computed (SINGLE_SIDE).
 */
struct SameDocScore {
    let verdict: SameDocumentVerdict
    let score:   Double
}

/**
 Fully parsed "identity_v2" block from `native_get_final_result_json`.

 Obtain via `parseFusedIdentity(_:)`.

 - Parameters:
   - sameDocument:     Cross-side verdict and weighted score.
   - fields:           All fused fields in declaration order.
   - docNumber:        Headline confident doc_number snapshot; nil when absent from JSON.
   - pin:              Headline confident PIN snapshot; nil when absent from JSON.
   - errors:           Ordered list of reconciliation errors (may be empty).
   - sides:            Per-side summaries (1 entry for single-side, 2 for two-sided).
   - ocrProdFrontJson: Raw OCR_PROD JSON string for the front side emitted by C++ in lean mode.
                       Contains {side, version, doc_number, pin}. Nil on older engine versions.
   - ocrProdBackJson:  Raw OCR_PROD JSON string for the back side emitted by C++ in lean mode.
                       Contains {side, version, doc_number, pin, mrz_pin, mrz_doc_number, mrz_full}.
                       Nil on older engine versions.
 */
struct FusedIdentity {
    let sameDocument:     SameDocScore
    let fields:           [FusedField]
    let docNumber:        SideSnapshot?
    let pin:              SideSnapshot?
    let errors:           [IdentityError]
    let sides:            [SideSummary]
    let ocrProdFrontJson: String?
    let ocrProdBackJson:  String?

    init(
        sameDocument:     SameDocScore,
        fields:           [FusedField],
        docNumber:        SideSnapshot?,
        pin:              SideSnapshot?,
        errors:           [IdentityError],
        sides:            [SideSummary],
        ocrProdFrontJson: String? = nil,
        ocrProdBackJson:  String? = nil
    ) {
        self.sameDocument     = sameDocument
        self.fields           = fields
        self.docNumber        = docNumber
        self.pin              = pin
        self.errors           = errors
        self.sides            = sides
        self.ocrProdFrontJson = ocrProdFrontJson
        self.ocrProdBackJson  = ocrProdBackJson
    }
}

// ── MRZ field comparison (cross-platform parity with Android FieldCompare) ───

/**
 Whether two independently-read values for the same document field agree.

 Mirrors Kotlin's `MatchKind` in `IdentityV2.kt` (currently not in the Kotlin file
 but aligned with Android's `FieldCompare.match: Boolean?` semantics).

 | Case        | Meaning                                              |
 |-------------|------------------------------------------------------|
 | matches     | Visual OCR value and MRZ-decoded value are identical |
 |             | (after normalisation: uppercase + strip '<').        |
 | mismatch    | Both values are non-empty but they differ.           |
 | unavailable | At least one source was empty — cannot compare.      |
 | unknown     | Forward-compat fallback.                             |
 */
public enum MatchKind: String {
    case unknown     = "UNKNOWN"
    case matches     = "MATCHES"
    case mismatch    = "MISMATCH"
    case unavailable = "UNAVAILABLE"

    /// Case-insensitive factory; returns `.unknown` for unrecognised strings.
    public static func fromString(_ s: String) -> MatchKind {
        MatchKind(rawValue: s.uppercased()) ?? .unknown
    }

    /// Convenience: derives `MatchKind` from an optional Boolean as emitted by the
    /// C++ `mrz_match` block (nil = only one source available; true/false = comparison).
    static func from(optionalBool: Bool?) -> MatchKind {
        switch optionalBool {
        case .none:  return .unavailable
        case true:   return .matches
        case false:  return .mismatch
        }
    }
}

/**
 Per-field comparison between the visual OCR read and the MRZ-decoded value.

 Sourced from the engine's top-level `mrz_match` JSON object (C++ reconcile step).
 Present only when a back-side MRZ was read and the engine emitted the `mrz_match` block.

 Mirrors Android's `FieldCompare` data class in `Mergen.kt`.

 - Parameters:
   - fieldName:     Canonical field key, e.g. `"doc_number"` or `"personal_number"`.
   - visualValue:   Value read visually from the document. Empty string when absent.
   - mrzValue:      Value decoded from the MRZ. Empty string when MRZ not read for this field.
   - match:         Whether the visual and MRZ values agree after normalisation.
                    `.unavailable` when only one source was available.
   - mrzChecksumOk: Whether the ICAO check digit for this MRZ field validated successfully.
 */
public struct MrzMatch {
    public let fieldName:     String
    public let visualValue:   String
    public let mrzValue:      String
    public let match:         MatchKind
    public let mrzChecksumOk: Bool
}

// ── Lean identity surface ─────────────────────────────────────────────────────

/**
 Compact result of a lean identity-verify scan.

 In lean mode the engine reads ONLY doc_number, personal_number (PIN), and MRZ.
 This struct surfaces those three fields plus the cross-side same-document verdict
 so the caller needs zero JSON parsing.

 Mirrors Kotlin's `LeanVerifyResult` in `IdentityV2.kt`.
 */
struct LeanVerifyResult {
    let sameDocument:    SameDocumentVerdict
    let docNumberFront:  String?
    let pinFront:        String?
    let docNumberBack:   String?
    let pinBack:         String?
    let mrzDocNumber:    String?
    let mrzPin:          String?
    let mrzFull:         String?
    /// Parsed OCR_PROD dictionary for the front side (diagnostics only).
    let ocrProdFront:    [String: Any]?
    /// Parsed OCR_PROD dictionary for the back side (diagnostics only).
    let ocrProdBack:     [String: Any]?
}

/// Convenience accessor — mirrors Kotlin `val FusedIdentity.leanVerifyResult`.
/// Returns nil when `ocrProdFrontJson` is absent (engine ran in full-field mode,
/// or engine version predates lean support).
extension FusedIdentity {
    var leanVerifyResult: LeanVerifyResult? {
        guard let frontJson = ocrProdFrontJson,
              let frontData = frontJson.data(using: .utf8),
              let frontObj = (try? JSONSerialization.jsonObject(with: frontData)) as? [String: Any]
        else { return nil }

        let backObj: [String: Any]? = ocrProdBackJson.flatMap { s in
            s.data(using: .utf8).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }

        func str(_ dict: [String: Any]?, _ k: String) -> String? {
            (dict?[k] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        return LeanVerifyResult(
            sameDocument:   sameDocument.verdict,
            docNumberFront: str(frontObj, "doc_number"),
            pinFront:       str(frontObj, "pin"),
            docNumberBack:  str(backObj,  "doc_number"),
            pinBack:        str(backObj,  "pin"),
            mrzDocNumber:   str(backObj,  "mrz_doc_number"),
            mrzPin:         str(backObj,  "mrz_pin"),
            mrzFull:        str(backObj,  "mrz_full"),
            ocrProdFront:   frontObj,
            ocrProdBack:    backObj
        )
    }
}

// ── Parser ────────────────────────────────────────────────────────────────────

/**
 Parses the "identity_v2" object from a `native_get_final_result_json` JSON string.

 This is the Swift mirror of Kotlin's `parseFusedIdentity(finalJson: String)` in
 `IdentityV2.kt`. It operates purely on a String — no JNI / bridging call is made here.

 Returns `nil` when:
 - `finalJson` is blank or `"{}"`.
 - The `"identity_v2"` key is absent (C++ built without
   `enable_identity_reconciliation=true`, or engine version predates identity_v2 —
   old clients remain binary-compatible).
 - JSON is malformed.

 - Parameter finalJson: Raw JSON string from `native_get_final_result_json`.
 */
func parseFusedIdentity(_ finalJson: String?) -> FusedIdentity? {
    guard let finalJson, !finalJson.trimmingCharacters(in: .whitespaces).isEmpty,
          finalJson != "{}" else { return nil }

    guard let data = finalJson.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let iv2  = root["identity_v2"] as? [String: Any]
    else { return nil }

    // same_document
    let sameDocObj = iv2["same_document"] as? [String: Any]
    let sameDoc = SameDocScore(
        verdict: SameDocumentVerdict.fromString(sameDocObj?["verdict"] as? String ?? "UNKNOWN"),
        score:   sameDocObj?["score"] as? Double ?? 0.0
    )

    // fields array
    let fieldsArr = iv2["fields"] as? [[String: Any]] ?? []
    let fields: [FusedField] = fieldsArr.compactMap { f in
        let sourcesArr = f["sources"] as? [String] ?? []
        return FusedField(
            name:       f["name"]       as? String ?? "",
            value:      f["value"]      as? String ?? "",
            confidence: f["confidence"] as? Double ?? 0.0,
            tier:       f["tier"]       as? String ?? "",
            badge:      ConfidenceBadge.fromString(f["badge"] as? String ?? "UNKNOWN"),
            checksumOk: f["checksum_ok"] as? Bool  ?? false,
            sources:    sourcesArr.filter { !$0.isEmpty }
        )
    }

    // headline doc_number / pin snapshots
    func parseSnapshot(_ key: String) -> SideSnapshot? {
        guard let obj = iv2[key] as? [String: Any] else { return nil }
        return SideSnapshot(
            value:      obj["value"]       as? String ?? "",
            badge:      ConfidenceBadge.fromString(obj["badge"] as? String ?? "UNKNOWN"),
            checksumOk: obj["checksum_ok"] as? Bool   ?? false
        )
    }

    // errors array
    let errArr = iv2["errors"] as? [[String: Any]] ?? []
    let errors: [IdentityError] = errArr.compactMap { e in
        let fieldStr = e["field"] as? String
        return IdentityError(
            code:      IdentityErrorCode.fromString(e["code"]     as? String ?? "UNKNOWN"),
            side:      SideId.fromString(            e["side"]     as? String ?? "UNKNOWN"),
            field:     (fieldStr?.isEmpty ?? true) ? nil : fieldStr,
            severity:  Severity.fromString(          e["severity"] as? String ?? "UNKNOWN"),
            messageRu: e["message"]    as? String ?? "",
            messageEn: e["message_en"] as? String ?? "",
            action:    RetakeAction.fromString(      e["action"]   as? String ?? "UNKNOWN")
        )
    }

    // sides array — also captures per-side ocr_prod and field_availability if present
    let sidesArr = iv2["sides"] as? [[String: Any]] ?? []
    let sides: [SideSummary] = sidesArr.compactMap { s in
        let ver = s["version"] as? String ?? ""
        let prodObj = s["ocr_prod"] as? [String: Any]
        let prodJson: String? = prodObj.flatMap { obj in
            (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) }
        }

        let fa: FieldAvailability
        if let faObj = s["field_availability"] as? [String: Any] {
            fa = FieldAvailability(
                hasVisDoc: faObj["has_vis_doc"] as? Bool ?? true,
                hasVisPin: faObj["has_vis_pin"] as? Bool ?? false,
                hasMrz:    faObj["has_mrz"]     as? Bool ?? false
            )
        } else {
            // Infer from version string for backward-compat with older engine builds.
            fa = FieldAvailability(
                hasVisDoc: true,
                hasVisPin: ver.contains("2008") ||
                           ver.lowercased().contains("back2017") ||
                           ver.lowercased().contains("back2025"),
                hasMrz:    ver.lowercased().contains("back")
            )
        }

        return SideSummary(
            side:              SideId.fromString(s["side"] as? String ?? "UNKNOWN"),
            version:           ver,
            qualityOk:         s["quality_ok"] as? Bool ?? true,
            fieldAvailability: fa,
            ocrProdJson:       prodJson
        )
    }

    // ocr_prod_front / ocr_prod_back: try iv2 first (where C++ actually emits them),
    // then root (legacy path), then fall back to per-side ocr_prod from the sides[] array.
    // This mirrors the Android fix in parseFusedIdentity (IdentityV2.kt).
    func sideOcrProdJson(_ sideId: String) -> String? {
        sides.first { $0.side.rawValue.caseInsensitiveCompare(sideId) == .orderedSame }?.ocrProdJson
    }

    func jsonString(from value: Any?) -> String? {
        guard let value = value else { return nil }
        // C++ may emit ocr_prod_* either as a nested JSON object OR as an already-
        // serialized JSON string (or an empty "" on failed sides). Passing a String
        // to JSONSerialization.data(withJSONObject:) throws an *ObjC* exception
        // ("Invalid top-level type") that `try?` does NOT catch → hard crash.
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.isEmpty || t == "{}") ? nil : s
        }
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    let ocrProdFrontJson =
        jsonString(from: iv2["ocr_prod_front"])
        ?? jsonString(from: root["ocr_prod_front"])
        ?? sideOcrProdJson("FRONT")

    let ocrProdBackJson =
        jsonString(from: iv2["ocr_prod_back"])
        ?? jsonString(from: root["ocr_prod_back"])
        ?? sideOcrProdJson("BACK")

    return FusedIdentity(
        sameDocument:     sameDoc,
        fields:           fields,
        docNumber:        parseSnapshot("doc_number"),
        pin:              parseSnapshot("pin"),
        errors:           errors,
        sides:            sides,
        ocrProdFrontJson: ocrProdFrontJson,
        ocrProdBackJson:  ocrProdBackJson
    )
}

// ── Computed property on MergenIdResult (additive, zero serialisation overhead) ──

/**
 Lazily parses the `identity_v2` block from `MergenIdResult.finalJson`.

 Mirror of Kotlin's `val MergenIdResult.fusedIdentity` extension in `IdentityV2.kt`.

 Returns `nil` when `finalJson` is absent, blank, or the C++ engine version predates
 `identity_v2` (`enable_identity_reconciliation=false` or older binary). Old clients that
 never read `finalJson` remain binary-compatible — this property adds zero overhead to
 the `MergenIdResult` value type itself.

 Example usage:
 ```swift
 result.fusedIdentity.map { identity in
     if identity.sameDocument.verdict == .mismatch { /* … */ }
     print(identity.docNumber?.value ?? "")
 }
 ```
 */
extension MergenIdResult {
    var fusedIdentity: FusedIdentity? {
        parseFusedIdentity(finalJson)
    }
}
