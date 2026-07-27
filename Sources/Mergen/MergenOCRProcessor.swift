import Vision
import UIKit
import CoreImage
import os

// ── OCRResult — public value type returned via MergenIdResult.ocrResult ──

/// OCR field extraction result for a single card side.
///
/// Populated by the Vision-based OCR pipeline and surfaced through
/// `MergenIdResult.ocrResult`. All fields are optional; nil means the field
/// was not detected or the card version does not carry that field.
public struct MergenOCRResult {
    public var lastName:       String?
    public var firstName:      String?
    /// Latin variant of last name (from cls1 field detector, English model).
    /// Nil when the card has no Latin name strip or the detector did not fire.
    public var lastNameLat:    String?
    /// Latin variant of first name (from cls3 field detector, English model).
    /// Nil when the card has no Latin name strip or the detector did not fire.
    public var firstNameLat:   String?
    public var patronymic:     String?
    public var gender:         String?
    public var nationality:    String?
    public var birthDate:      String?
    public var docNumber:      String?
    public var expiryDate:     String?
    public var birthPlace:     String?
    public var issuedBy:       String?
    public var issueDate:      String?
    public var personalNumber: String?
    public var mrzLine1:       String?
    public var mrzLine2:       String?
    public var mrzLine3:       String?
    /// All recognised fields keyed by field name string (e.g. `"last_name"`, `"doc_number"`).
    public var rawFields:      [String: String] = [:]

    public init() {}
}

// ── MergenOCRProcessor — internal Vision OCR pipeline ────────────────────────

/// Processes a perspective-corrected card crop and extracts text fields via Vision OCR.
///
/// Two modes:
///   1. Field-based (preferred): uses bounding boxes from the C++ FieldDetector to run
///      per-region Vision requests with language hints tuned to each field type.
///   2. Spatial fallback: whole-image Vision pass with coordinate matching against
///      fixed `cardFieldCoords` tables (640×400 reference space).
///
/// C++ crop dimensions are always 1280×800 (see `perspectiveCrop()` in id_card_engine.cpp).
@MainActor
final class MergenOCRProcessor {

    // ── Constants ─────────────────────────────────────────────────────────────

    /// Reference dimensions of the C++ perspective crop (perspectiveCrop outputs 1280×800).
    private static let cropRefW: CGFloat = 1280.0
    private static let cropRefH: CGFloat = 800.0

    /// raw_class_id values that map to MRZ.
    private static let mrzClassId = 14

    /// raw_class_id values that are date/numeric fields (use English-only OCR).
    private static let numericClassIds: Set<Int> = [7, 8, 9, 12, 13]  // birth_date, doc_number, expiry_date, issue_date, personal_number

    /// raw_class_id values that are Latin-only name fields.
    private static let latinNameClassIds: Set<Int> = [1, 3]  // last_name_lat, first_name_lat

    /// raw_class_id values that are bilingual (kyr top, lat bottom), applicable for
    /// Front2017 / Front2025 only (raw_class_id 0 = last_name_kyr, 2 = first_name_kyr).
    private static let bilingualClassIds: Set<Int> = [0, 2]

    /// Card versions that have bilingual fields.
    private static let bilingualVersions: Set<CardVersion> = [.front2017, .front2025]

    // ── Internal result type (aliased to the public MergenOCRResult) ──────────

    typealias OCRResult = MergenOCRResult

    /// OCR diagnostics channel. Structural output (counts, geometry, value lengths) is
    /// always emitted here; recognised VALUES only when `piiTrace` is flipped on for local
    /// debugging — see internal/PiiTrace.swift.
    private static let ocrTraceLog = Logger(subsystem: "com.mergen", category: "ocrtrace")

    // ── Init ─────────────────────────────────────────────────────────────────

    init() {}

    // ── Internal API ──────────────────────────────────────────────────────────

    /// Run field-based OCR using bounding boxes from the C++ FieldDetector.
    ///
    /// Each detected field gets its own Vision request with language hints appropriate
    /// to the field type. Falls back to `process(image:cardVersion:completion:)` when
    /// `detectedFields` is empty.
    ///
    /// - Parameters:
    ///   - image:          Perspective-corrected card image from C++ (nominally 1280×800).
    ///   - detectedFields: Fields from `MergenEngine.getDetectedFields()`.
    ///   - cardVersion:    Card layout version used for bilingual detection.
    ///   - completion:     Called on the **main thread** with the extracted fields.
    func process(
        image: UIImage,
        detectedFields: [(fieldId: Int, rawClassId: Int, bbox: CGRect, confidence: Float)],
        cardVersion: CardVersion,
        completion: @escaping @MainActor (OCRResult) -> Void
    ) {
        guard !detectedFields.isEmpty else {
            process(image: image, cardVersion: cardVersion, completion: completion)
            return
        }
        guard let cgImage = image.cgImage else {
            completion(OCRResult())
            return
        }

        Task.detached(priority: .userInitiated) {
            let result = Self.runFieldBasedOCR(
                cgImage: cgImage,
                detectedFields: detectedFields,
                cardVersion: cardVersion
            )
            await MainActor.run { completion(result) }
        }
    }

    /// Run OCR on a corrected card image using fixed coordinate tables.
    ///
    /// - Parameters:
    ///   - image:       Perspective-corrected card image.
    ///   - cardVersion: Card layout version. `.unknown` → completion called with empty result.
    ///   - completion:  Called on the **main thread** with the extracted fields.
    func process(
        image: UIImage,
        cardVersion: CardVersion,
        completion: @escaping @MainActor (OCRResult) -> Void
    ) {
        guard cardVersion != .unknown,
              let cgImage = image.cgImage else {
            completion(OCRResult())
            return
        }

        let fields = cardFieldCoords[cardVersion.rawValue] ?? []
        guard !fields.isEmpty else {
            completion(OCRResult())
            return
        }

        Task.detached(priority: .userInitiated) {
            // 1. Preprocess: contrast + sharpen
            let processedImage = Self.preprocess(cgImage: cgImage)

            // 2. Run Vision on whole image (single pass)
            let observations = Self.recognizeAllText(in: processedImage)

            // 3. Spatial matching
            var result = OCRResult()
            let imageW = CGFloat(cgImage.width)
            let imageH = CGFloat(cgImage.height)
            // Coords are in 640×400 space — scale to actual image pixels
            let scaleX = imageW / 640.0
            let scaleY = imageH / 400.0

            for field in fields {
                let fieldRect = CGRect(
                    x:      field.rect.minX  * scaleX,
                    y:      field.rect.minY  * scaleY,
                    width:  field.rect.width * scaleX,
                    height: field.rect.height * scaleY
                )

                let matches = Self.findObservationsInRect(
                    fieldRect,
                    observations: observations,
                    imageSize: CGSize(width: imageW, height: imageH)
                )
                guard !matches.isEmpty else { continue }

                if field.id == .mrz {
                    let mrzText = matches.joined(separator: "\n")
                    let lines = mrzText.components(separatedBy: "\n").filter { !$0.isEmpty }
                    result.mrzLine1 = lines.count > 0 ? lines[0] : nil
                    result.mrzLine2 = lines.count > 1 ? lines[1] : nil
                    result.mrzLine3 = lines.count > 2 ? lines[2] : nil
                    result.rawFields[CardFieldId.mrz.rawValue] = mrzText

                    if let parsed = MRZParser.parseTD1(
                        line1: result.mrzLine1,
                        line2: result.mrzLine2,
                        line3: result.mrzLine3
                    ) {
                        if result.lastName       == nil { result.lastName       = parsed.lastName }
                        if result.firstName      == nil { result.firstName      = parsed.firstName }
                        if result.birthDate      == nil { result.birthDate      = parsed.birthDate }
                        if result.expiryDate     == nil { result.expiryDate     = parsed.expiryDate }
                        if result.docNumber      == nil { result.docNumber      = parsed.documentNumber }
                        if result.gender         == nil { result.gender         = parsed.gender }
                        if result.nationality    == nil { result.nationality    = parsed.nationality }
                        if result.personalNumber == nil { result.personalNumber = parsed.personalNumber }
                    }
                    continue
                }

                let text = matches.joined(separator: " ")
                result.rawFields[field.id.rawValue] = text
                Self.assign(text: text, to: &result, fieldId: field.id)
            }

            await MainActor.run { completion(result) }
        }
    }

    // ── Field-based OCR ───────────────────────────────────────────────────────

    private nonisolated static func runFieldBasedOCR(
        cgImage: CGImage,
        detectedFields: [(fieldId: Int, rawClassId: Int, bbox: CGRect, confidence: Float)],
        cardVersion: CardVersion
    ) -> OCRResult {
        var result = OCRResult()
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        // Scale factor from FieldDetector crop coordinates (1280×800) to the actual image.
        let scaleX = imgW / cropRefW
        let scaleY = imgH / cropRefH

        var mrzLines: [String] = []

        for field in detectedFields {
            let rawClass = field.rawClassId

            // Scale bbox from C++ crop space to CGImage pixel space
            let scaledBbox = CGRect(
                x:      field.bbox.minX * scaleX,
                y:      field.bbox.minY * scaleY,
                width:  field.bbox.width  * scaleX,
                height: field.bbox.height * scaleY
            )

            // Clamp to image bounds
            let clampedBbox = scaledBbox.intersection(
                CGRect(x: 0, y: 0, width: imgW, height: imgH)
            )
            guard !clampedBbox.isEmpty,
                  clampedBbox.width >= 4, clampedBbox.height >= 4 else { continue }

            guard let roiImage = cgImage.cropping(to: clampedBbox) else { continue }

            if rawClass == mrzClassId {
                // MRZ: use Latin character whitelist, no language correction
                let mrzText = recognizeText(
                    in: roiImage,
                    languages: ["en"],
                    usesLanguageCorrection: false,
                    customWords: [],
                    minimumTextHeight: 0.0,
                    fieldLabel: "cls\(rawClass)/mrz"   // field NAME only — not PII
                )
                let normalized = normalizeMRZ(mrzText)
                if !normalized.isEmpty {
                    mrzLines.append(normalized)
                }
                continue
            }

            let isBilingual = bilingualClassIds.contains(rawClass)
                && bilingualVersions.contains(cardVersion)

            if isBilingual {
                // Top half → Cyrillic (ru), bottom half → Latin (en)
                let halfH = clampedBbox.height / 2.0

                let topBbox = CGRect(
                    x: clampedBbox.minX, y: clampedBbox.minY,
                    width: clampedBbox.width, height: halfH
                )
                let botBbox = CGRect(
                    x: clampedBbox.minX, y: clampedBbox.minY + halfH,
                    width: clampedBbox.width, height: halfH
                )

                if let topROI = cgImage.cropping(to: topBbox) {
                    let kyrText = recognizeText(
                        in: topROI,
                        languages: ["ru", "en"],
                        usesLanguageCorrection: false,
                        customWords: [],
                        minimumTextHeight: 0.0,
                        fieldLabel: "cls\(rawClass)/kyr"   // field NAME only — not PII
                    )
                    if !kyrText.isEmpty {
                        assignFieldText(kyrText, rawClassId: rawClass, to: &result,
                                        cardVersion: cardVersion, isLat: false)
                    }
                }

                if let botROI = cgImage.cropping(to: botBbox) {
                    let latText = recognizeText(
                        in: botROI,
                        languages: ["en"],
                        usesLanguageCorrection: false,
                        customWords: [],
                        minimumTextHeight: 0.0,
                        fieldLabel: "cls\(rawClass)/lat"   // field NAME only — not PII
                    )
                    if !latText.isEmpty {
                        assignFieldText(latText, rawClassId: rawClass, to: &result,
                                        cardVersion: cardVersion, isLat: true)
                    }
                }
            } else {
                let languages: [String]
                if latinNameClassIds.contains(rawClass) {
                    languages = ["en"]
                } else if numericClassIds.contains(rawClass) {
                    languages = ["en"]
                } else {
                    languages = ["ru", "en"]
                }

                var text = recognizeText(
                    in: roiImage,
                    languages: languages,
                    usesLanguageCorrection: false,
                    customWords: [],
                    minimumTextHeight: 0.0,
                    fieldLabel: "cls\(rawClass)"       // field NAME only — not PII
                )
                if numericClassIds.contains(rawClass) {
                    text = normalizeNumeric(text)
                }
                if !text.isEmpty {
                    assignFieldText(text, rawClassId: rawClass, to: &result,
                                    cardVersion: cardVersion, isLat: false)
                }
            }
        }

        // Assemble MRZ
        if !mrzLines.isEmpty {
            result.mrzLine1 = mrzLines.count > 0 ? mrzLines[0] : nil
            result.mrzLine2 = mrzLines.count > 1 ? mrzLines[1] : nil
            result.mrzLine3 = mrzLines.count > 2 ? mrzLines[2] : nil
            result.rawFields[CardFieldId.mrz.rawValue] = mrzLines.joined(separator: "\n")

            // MRZ cross-check: fill empty fields from parsed MRZ
            if let parsed = MRZParser.parseTD1(
                line1: result.mrzLine1,
                line2: result.mrzLine2,
                line3: result.mrzLine3
            ) {
                if result.lastName       == nil { result.lastName       = parsed.lastName }
                if result.firstName      == nil { result.firstName      = parsed.firstName }
                if result.birthDate      == nil { result.birthDate      = parsed.birthDate }
                if result.expiryDate     == nil { result.expiryDate     = parsed.expiryDate }
                if result.docNumber      == nil { result.docNumber      = parsed.documentNumber }
                if result.gender         == nil { result.gender         = parsed.gender }
                if result.nationality    == nil { result.nationality    = parsed.nationality }
                if result.personalNumber == nil { result.personalNumber = parsed.personalNumber }
            }
        }

        return result
    }

    // ── Vision helpers ────────────────────────────────────────────────────────

    /// Run a Vision text recognition request on a single CGImage ROI.
    /// `fieldLabel` is the detector class name (e.g. "cls5/mrz") used to tag the
    /// diagnostic log — a field NAME, never a field value, so it is safe to keep on.
    private nonisolated static func recognizeText(
        in cgImage: CGImage,
        languages: [String],
        usesLanguageCorrection: Bool,
        customWords: [String],
        minimumTextHeight: Float,
        fieldLabel: String = ""
    ) -> String {
        var observations: [VNRecognizedTextObservation] = []
        let request = VNRecognizeTextRequest { req, _ in
            guard let obs = req.results as? [VNRecognizedTextObservation] else { return }
            observations = obs
        }
        request.recognitionLevel       = .accurate
        request.recognitionLanguages   = languages
        request.usesLanguageCorrection = usesLanguageCorrection
        if !customWords.isEmpty {
            request.customWords = customWords
        }
        if minimumTextHeight > 0 {
            request.minimumTextHeight = minimumTextHeight
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        var lines: [String] = []
        // Structural trace (which field, which languages, how many observations, how
        // confident, where) is always on — it carries no personal data. The recognised
        // TEXT is PII and only appears under `piiTrace` (see internal/PiiTrace.swift).
        let langStr = languages.joined(separator: ",")
        let label = fieldLabel.isEmpty ? "field" : fieldLabel
        ocrTraceLog.debug("[vision/field] \(label, privacy: .public) langs=\(langStr, privacy: .public) observations=\(observations.count, privacy: .public)")
        for (i, obs) in observations.enumerated() {
            if let cand = obs.topCandidates(1).first {
                lines.append(cand.string)
                let bboxStr = String(format: "x=%.3f y=%.3f w=%.3f h=%.3f",
                                     obs.boundingBox.minX, obs.boundingBox.minY,
                                     obs.boundingBox.width, obs.boundingBox.height)
                let confStr = String(format: "%.3f", cand.confidence)
                if piiTrace {
                    ocrTraceLog.debug("[vision/field] \(label, privacy: .public) [\(i, privacy: .public)] text=\(cand.string, privacy: .public) conf=\(confStr, privacy: .public) bbox=\(bboxStr, privacy: .public)")
                } else {
                    ocrTraceLog.debug("[vision/field] \(label, privacy: .public) [\(i, privacy: .public)] text=\(piiLen(cand.string), privacy: .public) conf=\(confStr, privacy: .public) bbox=\(bboxStr, privacy: .public)")
                }
            }
        }
        let result = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if piiTrace {
            let resultForLog = result.isEmpty ? "<empty>" : result
            ocrTraceLog.debug("[vision/field] \(label, privacy: .public) result=\(resultForLog, privacy: .public)")
        } else {
            ocrTraceLog.debug("[vision/field] \(label, privacy: .public) result=\(piiLen(result), privacy: .public) lines=\(lines.count, privacy: .public)")
        }
        return result
    }

    /// Run a single whole-image VNRecognizeTextRequest and return all observations.
    private nonisolated static func recognizeAllText(in cgImage: CGImage) -> [VNRecognizedTextObservation] {
        var results: [VNRecognizedTextObservation] = []
        let request = VNRecognizeTextRequest { req, _ in
            if let observations = req.results as? [VNRecognizedTextObservation] {
                results = observations
            }
        }
        request.recognitionLevel       = .accurate
        request.recognitionLanguages   = ["ru", "en"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        // Counts / confidences / geometry always; recognised text only under `piiTrace`.
        ocrTraceLog.debug("[vision/spatial-fallback] observations=\(results.count, privacy: .public)")
        for (i, obs) in results.enumerated() {
            if let cand = obs.topCandidates(1).first {
                let bboxStr = String(format: "x=%.3f y=%.3f w=%.3f h=%.3f",
                                     obs.boundingBox.minX, obs.boundingBox.minY,
                                     obs.boundingBox.width, obs.boundingBox.height)
                let confStr = String(format: "%.3f", cand.confidence)
                if piiTrace {
                    ocrTraceLog.debug("[vision/spatial-fallback] [\(i, privacy: .public)] text=\(cand.string, privacy: .public) conf=\(confStr, privacy: .public) bbox=\(bboxStr, privacy: .public)")
                } else {
                    ocrTraceLog.debug("[vision/spatial-fallback] [\(i, privacy: .public)] text=\(piiLen(cand.string), privacy: .public) conf=\(confStr, privacy: .public) bbox=\(bboxStr, privacy: .public)")
                }
            }
        }

        return results
    }

    // ── Image preprocessing ───────────────────────────────────────────────────

    /// Apply contrast boost + unsharp mask to improve OCR on ID card text.
    private nonisolated static func preprocess(cgImage: CGImage) -> CGImage {
        let ciImage = CIImage(cgImage: cgImage)

        let contrast = CIFilter(name: "CIColorControls")!
        contrast.setValue(ciImage, forKey: kCIInputImageKey)
        contrast.setValue(1.3, forKey: kCIInputContrastKey)
        contrast.setValue(0.0, forKey: kCIInputSaturationKey)
        contrast.setValue(0.0, forKey: kCIInputBrightnessKey)

        let sharpen = CIFilter(name: "CIUnsharpMask")!
        sharpen.setValue(contrast.outputImage, forKey: kCIInputImageKey)
        sharpen.setValue(2.5, forKey: kCIInputRadiusKey)
        sharpen.setValue(0.7, forKey: kCIInputIntensityKey)

        guard let output = sharpen.outputImage else { return cgImage }
        let context = CIContext()
        return context.createCGImage(output, from: output.extent) ?? cgImage
    }

    // ── Field assignment helpers ──────────────────────────────────────────────

    /// Maps raw_class_id → OCRResult field assignment.
    /// raw_class_id→FieldId mapping (from field_detector.h):
    ///   0 last_name_kyr, 1 last_name_lat, 2 first_name_kyr, 3 first_name_lat,
    ///   4 patronymic, 5 gender, 6 nationality, 7 birth_date, 8 doc_number,
    ///   9 expiry_date, 10 birth_place, 11 issued_by, 12 issue_date,
    ///   13 personal_number, 14 mrz, 15 address (→ lastName)
    private nonisolated static func assignFieldText(
        _ text: String,
        rawClassId: Int,
        to result: inout OCRResult,
        cardVersion: CardVersion,
        isLat: Bool
    ) {
        switch rawClassId {
        case 0:   // last_name_kyr: kyr in top half → lastName (kyr overwrites if already set by lat)
            result.lastName = text
            result.rawFields["last_name_kyr"] = text
        case 1:   // last_name_lat: lat-only variant
            // Only set if not yet set by a kyr variant
            if result.lastName == nil { result.lastName = text }
            result.lastNameLat = text
            result.rawFields["last_name_lat"] = text
        case 2:   // first_name_kyr
            result.firstName = text
            result.rawFields["first_name_kyr"] = text
        case 3:   // first_name_lat
            if result.firstName == nil { result.firstName = text }
            result.firstNameLat = text
            result.rawFields["first_name_lat"] = text
        case 4:
            result.patronymic = text
            result.rawFields[CardFieldId.patronymic.rawValue] = text
        case 5:
            result.gender = text
            result.rawFields[CardFieldId.gender.rawValue] = text
        case 6:
            result.nationality = text
            result.rawFields[CardFieldId.nationality.rawValue] = text
        case 7:
            result.birthDate = text
            result.rawFields[CardFieldId.birthDate.rawValue] = text
        case 8:
            result.docNumber = text
            result.rawFields[CardFieldId.docNumber.rawValue] = text
        case 9:
            result.expiryDate = text
            result.rawFields[CardFieldId.expiryDate.rawValue] = text
        case 10:
            result.birthPlace = text
            result.rawFields[CardFieldId.birthPlace.rawValue] = text
        case 11:
            result.issuedBy = text
            result.rawFields[CardFieldId.issuedBy.rawValue] = text
        case 12:
            result.issueDate = text
            result.rawFields[CardFieldId.issueDate.rawValue] = text
        case 13:
            result.personalNumber = text
            result.rawFields[CardFieldId.personalNumber.rawValue] = text
        case 15:  // address → lastName (same FieldId mapping as in C++)
            if result.lastName == nil { result.lastName = text }
            result.rawFields["address"] = text
        default:
            break
        }
    }

    private nonisolated static func assign(
        text: String,
        to result: inout OCRResult,
        fieldId: CardFieldId
    ) {
        result.rawFields[fieldId.rawValue] = text
        switch fieldId {
        case .lastName:       result.lastName       = text
        case .firstName:      result.firstName      = text
        case .patronymic:     result.patronymic     = text
        case .gender:         result.gender         = text
        case .nationality:    result.nationality    = text
        case .birthDate:      result.birthDate      = text
        case .docNumber:      result.docNumber      = text
        case .expiryDate:     result.expiryDate     = text
        case .birthPlace:     result.birthPlace     = text
        case .issuedBy:       result.issuedBy       = text
        case .issueDate:      result.issueDate      = text
        case .personalNumber: result.personalNumber = text
        case .mrz:            break
        }
    }

    // ── Normalization ─────────────────────────────────────────────────────────

    /// Normalize MRZ text: keep only A-Z, 0-9, < characters.
    private nonisolated static func normalizeMRZ(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "<" }
    }

    /// Normalize numeric/date fields: replace common OCR confusions O→0, I→1, l→1.
    private nonisolated static func normalizeNumeric(_ text: String) -> String {
        text.map { ch -> Character in
            switch ch {
            case "O", "o": return "0"
            case "I", "l": return "1"
            default: return ch
            }
        }.reduce("") { $0 + String($1) }
    }

    // ── Spatial matching (fallback path) ──────────────────────────────────────

    /// Return the text of every observation whose bounding-box center falls inside `fieldRect`.
    ///
    /// - `fieldRect`: pixel coordinates, top-left origin.
    /// - Vision `boundingBox`: normalised (0…1), **bottom-left** origin.
    private nonisolated static func findObservationsInRect(
        _ fieldRect: CGRect,
        observations: [VNRecognizedTextObservation],
        imageSize: CGSize
    ) -> [String] {
        // Convert pixel top-left rect → normalised bottom-left rect
        let normX = fieldRect.minX / imageSize.width
        let normW = fieldRect.width / imageSize.width
        let normY = (imageSize.height - fieldRect.maxY) / imageSize.height
        let normH = fieldRect.height / imageSize.height
        let searchRect = CGRect(x: normX, y: normY, width: normW, height: normH)

        // Expand by 10% on each axis for tolerance
        let expanded = searchRect.insetBy(dx: -searchRect.width * 0.1, dy: -searchRect.height * 0.1)

        var matches: [String] = []
        for obs in observations {
            let center = CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY)
            if expanded.contains(center),
               let text = obs.topCandidates(1).first?.string {
                matches.append(text)
            }
        }
        return matches
    }
}
