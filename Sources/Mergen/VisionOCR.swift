import Foundation
import Vision
import UIKit
import CoreImage
import os

/// iOS Vision framework OCR wrapper — supplementary engine for the accumulator.
/// Best for: Latin text, digits, dates. Complements our Cyrillic-focused PaddleOCR.
/// Zero-cost on disk (system framework, no bundled weights).
@available(iOS 13.0, *)
final class VisionOCR {
    private let queue = DispatchQueue(label: "idcardsdk.vision_ocr", qos: .userInitiated)

    /// OCR diagnostics channel. Structural output (counts, geometry, value lengths) is
    /// always emitted here; recognised VALUES only when `piiTrace` is flipped on for local
    /// debugging — see internal/PiiTrace.swift.
    private static let ocrTraceLog = Logger(subsystem: "com.mergen", category: "ocrtrace")

    /// `true` on devices with < 3 GB physical RAM (e.g. A9-class iPhones).
    /// Vision `.fast` recognition on these devices cuts per-field latency by ~4×
    /// with no accuracy regression because VisionOCR is additive — PaddleOCR always
    /// runs in parallel and covers any field Vision `.fast` may miss.
    /// Strong devices (≥ 3 GB) keep `.accurate` recognition unchanged.
    private var isWeakDevice: Bool {
        ProcessInfo.processInfo.physicalMemory < 3_000_000_000
    }

    init() {}

    /// Run Vision OCR on a full card crop and return an OCRResult-compatible JSON
    /// (matching our C++ OCRResult keys). This JSON can be fed directly into
    /// `MergenEngine::addExternalOCR()`.
    ///
    /// Heuristic field mapping by bbox Y-position:
    ///   * Top-third: names (last_name, first_name, patronymic)
    ///   * Middle: nationality, gender
    ///   * Bottom-third: dates, doc_number, personal_number
    /// For best results, pass the perspective-corrected 1280×800 card crop.
    func recognize(card: UIImage, completion: @escaping (String?) -> Void) {
        guard let cgImage = card.cgImage else { completion(nil); return }
        queue.async {
            let request = VNRecognizeTextRequest { req, err in
                if err != nil { completion(nil); return }
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                // Counts / confidences / geometry always; recognised text only under `piiTrace`.
                Self.ocrTraceLog.debug("[vision/full-crop] observations=\(observations.count, privacy: .public)")
                for (i, obs) in observations.enumerated() {
                    if let cand = obs.topCandidates(1).first {
                        let bboxStr = String(format: "x=%.3f y=%.3f w=%.3f h=%.3f",
                                             obs.boundingBox.minX, obs.boundingBox.minY,
                                             obs.boundingBox.width, obs.boundingBox.height)
                        let confStr = String(format: "%.3f", cand.confidence)
                        if piiTrace {
                            Self.ocrTraceLog.debug("[vision/full-crop] [\(i, privacy: .public)] text=\(cand.string, privacy: .public) conf=\(confStr, privacy: .public) bbox=\(bboxStr, privacy: .public)")
                        } else {
                            Self.ocrTraceLog.debug("[vision/full-crop] [\(i, privacy: .public)] text=\(piiLen(cand.string), privacy: .public) conf=\(confStr, privacy: .public) bbox=\(bboxStr, privacy: .public)")
                        }
                    }
                }
                let json = Self.buildJson(observations: observations,
                                          imgW: cgImage.width,
                                          imgH: cgImage.height)
                // The JSON is a map of recognised field VALUES — PII. Size only by default.
                if piiTrace {
                    Self.ocrTraceLog.debug("[vision/full-crop] final-json=\(json, privacy: .public)")
                } else {
                    Self.ocrTraceLog.debug("[vision/full-crop] final-json \(json.utf8.count, privacy: .public) bytes")
                }
                completion(json)
            }
            // Tier-adaptive: weak devices (<3 GB) use .fast to reduce per-field latency
            // by ~4×. VisionOCR is additive — PaddleOCR runs in parallel and covers any
            // field .fast may miss, so there is no accuracy regression path.
            request.recognitionLevel = self.isWeakDevice ? .fast : .accurate
            request.usesLanguageCorrection = false  // numbers/names: no autocorrect
            request.recognitionLanguages = ["en-US", "ru-RU"]
            do {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try handler.perform([request])
            } catch {
                completion(nil)
            }
        }
    }

    /// Run Vision OCR on a pre-cropped single-field image and return the raw
    /// concatenated text (all recognized lines joined by space), or nil if nothing
    /// was recognized. Use this for per-field crops where field type is already
    /// known from the field detector — no heuristic classification is needed.
    ///
    /// The caller is responsible for mapping the result to the correct JSON key
    /// before calling `MergenEngine::addExternalOCR()`.
    ///
    /// - Parameter languages: VNRecognizeTextRequest recognitionLanguages.
    ///   Default `["en-US", "ru-RU"]` preserves the previous behaviour for name/date
    ///   fields (Cyrillic capable).  Pass `["en-US"]` for structured Latin/digit-only
    ///   fields (doc_number, personal_number, MRZ) to prevent ru-RU from producing
    ///   Cyrillic homoglyphs (К instead of K, etc.) that would then be stripped by the
    ///   validatedExternalField gate — reducing effective recall on those fields.
    func recognizeRawText(
        image:     UIImage,
        languages: [String] = ["en-US", "ru-RU"],
        completion: @escaping (String?) -> Void
    ) {
        guard let cgImage = image.cgImage else { completion(nil); return }
        queue.async {
            let request = VNRecognizeTextRequest { req, err in
                if err != nil { completion(nil); return }
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                guard !observations.isEmpty else { completion(nil); return }
                // Collect top-candidate strings top-to-bottom (Vision bbox origin is
                // bottom-left; sort descending by minY to get top-to-bottom order).
                let sorted = observations.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                // Counts / confidences / geometry always; recognised text only under `piiTrace`.
                let langStr = languages.joined(separator: ",")
                Self.ocrTraceLog.debug("[vision/raw] langs=\(langStr, privacy: .public) observations=\(sorted.count, privacy: .public)")
                for (i, obs) in sorted.enumerated() {
                    if let cand = obs.topCandidates(1).first {
                        let bboxStr = String(format: "x=%.3f y=%.3f w=%.3f h=%.3f",
                                             obs.boundingBox.minX, obs.boundingBox.minY,
                                             obs.boundingBox.width, obs.boundingBox.height)
                        let confStr = String(format: "%.3f", cand.confidence)
                        if piiTrace {
                            Self.ocrTraceLog.debug("[vision/raw] [\(i, privacy: .public)] text=\(cand.string, privacy: .public) conf=\(confStr, privacy: .public) bbox=\(bboxStr, privacy: .public)")
                        } else {
                            Self.ocrTraceLog.debug("[vision/raw] [\(i, privacy: .public)] text=\(piiLen(cand.string), privacy: .public) conf=\(confStr, privacy: .public) bbox=\(bboxStr, privacy: .public)")
                        }
                    }
                }
                let parts = sorted.compactMap { $0.topCandidates(1).first?.string }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let joined = parts.joined(separator: " ")
                if piiTrace {
                    let joinedForLog = joined.isEmpty ? "<empty>" : joined
                    Self.ocrTraceLog.debug("[vision/raw] joined=\(joinedForLog, privacy: .public)")
                } else {
                    Self.ocrTraceLog.debug("[vision/raw] joined=\(piiLen(joined), privacy: .public) parts=\(parts.count, privacy: .public)")
                }
                completion(joined.isEmpty ? nil : joined)
            }
            // Tier-adaptive: weak devices (<3 GB) use .fast. See recognize(card:) for rationale.
            request.recognitionLevel = self.isWeakDevice ? .fast : .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = languages
            do {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try handler.perform([request])
            } catch {
                completion(nil)
            }
        }
    }

    /// Build an OCRResult-compatible JSON from Vision text observations.
    /// Assigns text lines to fields by vertical position within the crop.
    private static func buildJson(observations: [VNRecognizedTextObservation],
                                  imgW: Int, imgH: Int) -> String {
        struct Line { let text: String; let top: CGFloat }
        var lines: [Line] = []
        for obs in observations {
            guard let cand = obs.topCandidates(1).first else { continue }
            // bbox in Vision is normalized, origin bottom-left → flip to top-left
            let top = 1.0 - obs.boundingBox.maxY
            lines.append(Line(text: cand.string, top: top))
        }
        lines.sort { $0.top < $1.top }

        // Heuristic classification by vertical position
        var fields: [String: String] = [:]
        let dateRegex = try! NSRegularExpression(pattern: "^\\d{1,2}[ .-]\\d{1,2}[ .-]\\d{2,4}$")
        let docRegex  = try! NSRegularExpression(pattern: "^[A-Z]{2}\\d{6,9}$")
        let digitsOnly = try! NSRegularExpression(pattern: "^\\d{6,16}$")

        // Known card header/label text — must NOT be assigned to name fields.
        // Includes Latin transliterations that Vision produces from Cyrillic headers
        // (e.g. "KPTH3 PECTYSHKACH" for "КЫРГЫЗ РЕСПУБЛИКАСЫ").
        let headerPatterns = [
            "КЫРГЫЗ РЕСПУБЛИКАСЫ", "КЫРГЫЗСКАЯ РЕСПУБЛИКА", "THE KYRGYZ REPUBLIC",
            "ИДЕНТИФИКАЦИЯЛЫК КАРТА", "ИДЕНТИФИКАЦИОННАЯ КАРТА", "IDENTITY CARD",
            "КЫРГЫЗ ЖАРАНЫ", "ПАСПОРТ", "PASSPORT",
            "ФАМИЛИЯ", "SURNAME", "ИМЯ", "NAME", "ОТЧЕСТВО", "PATRONYMIC",
            "ПОЛ", "SEX", "ДАТА", "DATE", "ДОКУМЕНТ", "DOCUMENT",
            "ЖАРАНДЫГЫ", "ГРАЖДАНСТВО", "NATIONALITY",
            // Latin garbled / transliterated patterns from card headers
            "REPUBLIC", "IDENTITY", "CARD", "PASSPORT", "KYRGYZ", "RESPUB",
        ]
        let maxNameLength = 25  // Real names are max ~20 chars; anything longer is header garbage

        var dateSlots: [String] = []
        for line in lines {
            let t = line.text.trimmingCharacters(in: .whitespaces)
            let range = NSRange(t.startIndex..., in: t)
            if dateRegex.firstMatch(in: t, range: range) != nil {
                dateSlots.append(t)
            } else if docRegex.firstMatch(in: t, range: range) != nil {
                fields["doc_number"] = t
            } else if digitsOnly.firstMatch(in: t, range: range) != nil && t.count >= 10 {
                fields["personal_number"] = t
            } else if t.uppercased() == t && t.count >= 3
                      && t.range(of: "[A-ZА-ЯҢҮӨ]", options: .regularExpression) != nil {
                // Skip known header/label text (case-insensitive) or overly long strings
                let upper = t.uppercased()
                let isHeader = headerPatterns.contains { upper.contains($0.uppercased()) }
                if isHeader || t.count > maxNameLength { continue }
                // Upper-case name/place — assign by position
                if line.top < 0.25 && fields["last_name"] == nil { fields["last_name"] = t }
                else if line.top < 0.40 && fields["first_name"] == nil { fields["first_name"] = t }
                else if line.top < 0.55 && fields["patronymic"] == nil { fields["patronymic"] = t }
                else if fields["nationality"] == nil
                        && (t.contains("КЫРГЫЗ") || t.contains("KYRGYZ")
                            || t.contains("РЕСПУБЛИКА") || t.contains("REPUBLIC")) {
                    fields["nationality"] = t
                }
            }
        }
        // Dates: earlier = birth, later = expiry
        if dateSlots.count >= 1 { fields["birth_date"]  = dateSlots[0] }
        if dateSlots.count >= 2 { fields["expiry_date"] = dateSlots.last }

        // Serialize to JSON.
        // "cyrillic_capable":true tells the C++ FieldResolver that this payload
        // comes from Apple Vision with recognitionLanguages=["en-US","ru-RU"],
        // which reliably reads Cyrillic text.  The resolver then uses
        // EvidenceSource::PLATFORM_OCR_CYR for Cyrillic name fields instead of
        // EvidenceSource::PLATFORM_OCR (ML Kit / Latin-only), allowing Vision
        // Cyrillic reads to compete with and override garbled PaddleOCR names.
        var pairs: [String] = ["\"cyrillic_capable\":true"]
        for (k, v) in fields {
            let esc = v.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
            pairs.append("\"\(k)\":\"\(esc)\"")
        }
        return "{\(pairs.joined(separator: ","))}"
    }
}
