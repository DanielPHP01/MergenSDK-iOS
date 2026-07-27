import UIKit
import Vision
import os

private let finalizerLog = Logger(subsystem: "com.mergen", category: "finalizer")

/// Single implementation of the scan-finalization path.
///
/// Shared by:
/// - Camera path  — invoked from [ScannerEngineController.handleFinished]
///                  after a frame result passes quality gates.
/// - Gallery path — invoked from [ScannerEngineController.processImageWithEngine]
///                  after the static-image stability loop completes.
///
/// Sequence (identical for both callers):
///   1. Retrieve the perspective-corrected crop via [MergenEngine.getLastCroppedCardImage()].
///   2. Run Apple Vision OCR on individual field crops (or the full crop as fallback)
///      and inject votes into the C++ accumulator via [addExternalOCR].
///   3. Read the (now Vision-enriched) C++ OCR result via [getOCRResult()].
///   4. If C++ returns nothing, fall back to platform [MergenOCRProcessor].
///   5. Deliver the final [MergenIdResult] via [completion].
///
/// All Vision work is dispatched asynchronously; completion is always called
/// on the main thread.
///
/// Ownership: [ScannerEngineController] holds a single instance and passes
/// its own [engine] reference on each call — no retained engine reference here.
@MainActor
internal final class ScanFinalizer {

    // ── fieldId → JSON key mapping ────────────────────────────
    //
    // fieldId=12 is the MRZ zone: Vision reads it as a single block;
    // split on newlines or spaces and assign to mrz_line1/mrz_line2/mrz_line3.
    // fieldId=13 = last_name_lat (Latin surname on bilingual cards).
    // fieldId=14 = first_name_lat (Latin given name on bilingual cards).
    // Any fieldId without a mapping is skipped — no vote sent.
    private static let fieldKeyMap: [Int: String] = [
        0:  "last_name",
        1:  "first_name",
        2:  "patronymic",
        3:  "gender",
        4:  "nationality",
        5:  "birth_date",
        6:  "doc_number",
        7:  "expiry_date",
        8:  "birth_place",
        9:  "issued_by",
        10: "issue_date",
        11: "personal_number",
        // fieldId 12 = MRZ zone — handled separately
        13: "last_name_lat",
        14: "first_name_lat",
    ]

    // ── Lean-mode field id set ─────────────────────────────────
    //
    // Verified against C++ enum class FieldId (card_field_coords.h):
    //   DocNumber     = 6   ("doc_number")
    //   PersonalNumber= 11  ("personal_number")
    //   MRZ           = 12  (handled in the fid==12 branch above)
    //
    // In lean mode the C++ addExternalOCR() discards non-lean fields anyway
    // (mergen_engine.cpp lean_identity_fields gate), so skipping their Vision
    // passes here is pure waste elimination — not a semantic change.
    private static let leanFieldIds: Set<Int> = [6, 11, 12]

    // ── Pre-injection field validation (Android parity) ───────────
    //
    // Apple Vision reads a tight per-field crop with ru-RU enabled and no digit
    // restriction, so it can drop a digit or substitute a Cyrillic homoglyph into
    // a structured doc#/PIN read. Injecting such a malformed value lets it OUTVOTE
    // the correct internal PaddleOCR read (external votes carry more weight in the
    // C++ accumulator) — the observed cause of a wrong ПИН on device
    // (Vision '2150720050128' (13 digits) → normalised → overrode the correct
    // 14-digit internal read). Android never hits this because MlKitOcr gates
    // doc#/PIN with strict regexes BEFORE injection (MlKitOcr.kt:97-133); this
    // mirrors those gates so both platforms feed the shared engine equally clean.
    //
    // Returning nil DROPS the read so the clean internal value stands. Non-structured
    // fields (names/dates/etc.) are passed through unchanged — no behaviour change.
    //   - personal_number: exactly 14 digits (KG ПИН).      innRe = ^\d{14}$
    //   - doc_number:       2 letters + 7 digits (KG series). docRe = ^[A-Z]{2}\d{7}$
    //                       (C++ validates the specific prefix downstream.)
    //
    // ── Cyrillic homoglyph normalisation ─────────────────────────
    //
    // Apple Vision with ru-RU locale frequently returns Cyrillic lookalikes instead
    // of their visually identical Latin counterparts for doc# and PIN fields.
    // Example: "IK0090290" returned as "ІК0090290" (Cyrillic К U+041A, etc.).
    //
    // C++ normalizeDocNumber strips these via `isalnum(c)` on unsigned char: multi-byte
    // UTF-8 Cyrillic codepoints (U+0400–U+04FF) produce bytes > 0x7F that isalnum()
    // maps to false → they are stripped before the prefix check, so C++ never sees
    // them.  Swift must mirror this: convert the known visual homoglyphs to their Latin
    // equivalents BEFORE applying the regex gate, so a doc# that contains "К" (U+041A)
    // instead of "K" (U+004B) passes through instead of being silently dropped.
    //
    // Mapping: visual homoglyphs only (NOT phonetic transliteration).
    //   А(U+0410)→A  В(U+0412)→B  Е(U+0415)→E  К(U+041A)→K  М(U+041C)→M
    //   Н(U+041D)→H  О(U+041E)→O  Р(U+0420)→P  С(U+0421)→C  Т(U+0422)→T
    //   Х(U+0425)→X  И(U+0418)→I
    // У(U+0423) is intentionally EXCLUDED: Y is not a valid character in KG doc-number
    // prefixes (which are 2 uppercase Latin letters from the known series ID/IK/AN/KG/…)
    // nor in PIN digits, so У→Y would introduce a non-ASCII letter into those fields and
    // diverge from C++ normalizeDocNumber / normalizePersonalNumber behaviour (C++ strips
    // all non-alnum bytes including full UTF-8 multibyte sequences via isalnum(c)).
    // Lowercase first, then uppercased() → mapping applied once on uppercase form.
    //
    // normalizePersonalNumber additionally maps O→0, I/|/!→1, S→5, B→8, Z→2 (ASCII).
    // Those substitutions are in the digit-extraction path for personal_number below.
    //
    // This function is called for BOTH doc_number and personal_number from
    // ScanFinalizer (camera path) and _galleryVisionOCRJson (gallery path).
    nonisolated private static func applyCyrillicHomoglyphs(_ s: String) -> String {
        // Map: applied after uppercasing.
        // Cyrillic codepoints → visually identical Latin capital letters.
        // Extended Cyrillic (Ё, Й, У, etc.) without a useful Latin homoglyph are omitted.
        // У→Y is explicitly excluded (see comment above).
        let map: [Character: Character] = [
            "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M",
            "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T",
            "Х": "X", "И": "I",
        ]
        return String(s.uppercased().map { map[$0] ?? $0 })
    }

    nonisolated static func validatedExternalField(key: String, raw: String) -> String? {
        switch key {
        case "personal_number":
            // Step 1: apply Cyrillic homoglyph repair on the uppercased string.
            let deHomo = applyCyrillicHomoglyphs(raw)
            // Step 2: mirror C++ normalizePersonalNumber confusable set:
            //   O/Q→0, I/L/|/!→1, S→5, B→8, Z→2.
            // (After applyCyrillicHomoglyphs the string is already uppercased, so only
            //  uppercase forms need to be listed here.)
            // Mirrors mergen_engine.cpp:606-618:
            //   'O','o','Q'→'0'; 'I','l','|','!'→'1'; 'S','s'→'5'; 'B'→'8'; 'Z','z'→'2'.
            // Then extract only digit characters (strips whitespace, dashes, remaining letters).
            var digits = ""
            for ch in deHomo {
                switch ch {
                case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                    digits.append(ch)
                case "O", "Q":
                    digits.append("0")
                case "I", "L",
                     "|", "!":
                    // "L" covers visual "l" (lowercase L) after uppercasing.
                    // "|" and "!" mirror C++ normalizePersonalNumber (cpp:608).
                    digits.append("1")
                case "S":
                    digits.append("5")
                case "B":
                    digits.append("8")
                case "Z":
                    digits.append("2")
                default:
                    break  // skip spaces, dashes, unknown letters
                }
            }
            // Accept exactly 14 digits. C++ isPINValid is not replicated here —
            // C++ addExternalOCR runs normalizePersonalNumber (which includes isPINValid)
            // on every injected personal_number anyway, so a semantically invalid 14-digit
            // string will still be rejected downstream. The Swift gate's job is purely
            // structural: ensure the count is correct and no stray non-digit survived.
            return digits.count == 14 ? digits : nil

        case "doc_number":
            // Step 1: strip whitespace, uppercase, apply Cyrillic homoglyphs.
            let compact = applyCyrillicHomoglyphs(
                raw.filter { !$0.isWhitespace }
            )
            // Step 2: structural gate — mirrors C++ normalizeDocNumber fast-accept path:
            // the string must be exactly [A-Z]{2}[0-9]{7} after cleanup.
            // C++ does further confusable repair for invalid prefixes (OO→ID etc.),
            // but those repairs happen INSIDE C++ addExternalOCR after injection, so
            // we only need to guarantee the Swift gate is NOT STRICTER than C++'s
            // fast-accept path.  A 9-char string whose first 2 chars are uppercase
            // ASCII letters after homoglyph repair will pass this gate, reach C++,
            // and be normalised there if needed.
            return compact.range(of: #"^[A-Z]{2}\d{7}$"#, options: .regularExpression) != nil
                ? compact : nil

        default:
            return raw
        }
    }

    // ── Main entry point ──────────────────────────────────────

    /// Run the full finalization sequence for a passed card capture.
    ///
    /// - Parameters:
    ///   - engine:         The active engine (holds C++ state, crop, field detections).
    ///   - originalImage:  Full camera frame at capture time (nil for gallery path).
    ///   - frameResult:    The [FrameResult] from the final processed frame.
    ///   - isLean:         When `true`, Vision OCR is run ONLY on lean identity fields
    ///                     (doc_number / personal_number / MRZ — fieldIds 6, 11, 12).
    ///                     Non-lean fields are skipped; the C++ accumulator already discards
    ///                     them in lean mode.  Full mode (`false`) is unchanged — all detected
    ///                     fields receive a Vision pass.  Default: `false`.
    ///   - completion:     Called on the main thread with the final [MergenIdResult].
    func finalize(
        engine: MergenEngine,
        originalImage: UIImage?,
        frameResult: FrameResult,
        isLean: Bool = false,
        completion: @escaping (MergenIdResult) -> Void
    ) {
        let croppedImage = engine.getLastCroppedCardImage()
        let fieldProgressJson = engine.getFieldProgressJson() ?? ""

        // NOTE: finalJson is NOT captured here — it is captured inside finalizeAndDeliver()
        // AFTER addExternalOCR() has injected Vision votes into the C++ accumulator.
        // Mirrors Android ScanFinalizer.kt:123 ordering: getFinalResultJson() is called
        // at Step 5, after addExternalOCR (Step 3) and re-fetch (Step 4).
        // Capturing it here (before Vision runs) produced a stale finalJson that excluded
        // all Vision-enriched identity_v2 fields — the root cause of the iOS divergence.

        var sdkResult = MergenIdResult(
            success:           frameResult.isPassed,
            croppedImage:      croppedImage,
            originalImage:     originalImage,
            confidence:        frameResult.confidence,
            errorCode:         frameResult.isPassed ? 0 : 1,
            errorMessage:      frameResult.isPassed ? nil : frameResult.failReason,
            cardVersion:       frameResult.cardVersion,
            isFlipped:         frameResult.isFlipped,
            fieldProgressJson: fieldProgressJson
        )
        // finalJson intentionally left nil here; set after Vision in finalizeAndDeliver().

        guard #available(iOS 13.0, *), let crop = croppedImage, frameResult.isPassed else {
            finalizeAndDeliver(sdkResult: sdkResult, frameResult: frameResult,
                               crop: croppedImage, engine: engine, completion: completion)
            return
        }

        let fields = engine.getDetectedFields()

        if fields.isEmpty {
            // Fallback: full-crop heuristic Vision pass + barcode scan (back sides).
            // Both run in parallel; group.notify fires on main after both complete.
            let fallbackGroup  = DispatchGroup()
            let fallbackLock   = NSLock()
            var fallbackVisionJson:    String?           = nil
            var fallbackBarcodeFields: [String: String]  = [:]

            let visionOCR = VisionOCR()
            fallbackGroup.enter()
            visionOCR.recognize(card: crop) { json in
                defer { fallbackGroup.leave() }
                fallbackLock.lock()
                fallbackVisionJson = json
                fallbackLock.unlock()
            }

            let isBackSideFallback = frameResult.cardVersion == .back2008
                || frameResult.cardVersion == .back2017
                || frameResult.cardVersion == .back2025
            if isBackSideFallback {
                fallbackGroup.enter()
                BarcodeReader.readBarcodes(from: crop) { barcodes in
                    defer { fallbackGroup.leave() }
                    guard !barcodes.isEmpty else { return }
                    fallbackLock.lock()
                    fallbackBarcodeFields = barcodes
                    fallbackLock.unlock()
                }
            }

            fallbackGroup.notify(queue: .main) { [weak self] in
                guard let self else { return }
                // Inject barcode votes first — Code-128 is self-checking (mod-103 CRC),
                // so these values carry higher certainty than heuristic Vision reads.
                if !fallbackBarcodeFields.isEmpty {
                    engine.addExternalOCR(Self.buildBarcodeJson(fallbackBarcodeFields))
                }
                if let j = fallbackVisionJson, !j.isEmpty, j != "{}" {
                    engine.addExternalOCR(j)
                }
                self.finalizeAndDeliver(sdkResult: sdkResult, frameResult: frameResult,
                                        crop: crop, engine: engine, completion: completion)
            }
            return
        }

        guard let cgCrop = crop.cgImage else {
            finalizeAndDeliver(sdkResult: sdkResult, frameResult: frameResult,
                               crop: croppedImage, engine: engine, completion: completion)
            return
        }

        // Per-field Vision pass: each field crop is recognized independently so no
        // heuristic position-based classification is needed.
        let visionOCR = VisionOCR()
        let group = DispatchGroup()
        var fieldResults: [String: String] = [:]
        var barcodeFields: [String: String] = [:]  // back-side Code-128 results (parallel)
        let lock = NSLock()

        for field in fields {
            let fid = field.fieldId
            let bbox = field.bbox
            guard bbox.width > 20, bbox.height > 8 else { continue }

            // Lean-mode gate: skip Vision passes for non-lean fields.
            // The C++ accumulator already discards non-lean votes when
            // lean_identity_fields=true, so these passes are pure waste.
            // Lean fields: DocNumber(6), PersonalNumber(11), MRZ(12).
            if isLean && !Self.leanFieldIds.contains(fid) { continue }

            // Clamp field bbox to crop pixel bounds.
            let x = max(0, Int(bbox.origin.x))
            let y = max(0, Int(bbox.origin.y))
            let w = min(cgCrop.width  - x, Int(bbox.width))
            let h = min(cgCrop.height - y, Int(bbox.height))
            guard w > 10, h > 5 else { continue }
            guard let fieldCG = cgCrop.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else { continue }

            // Upscale small crops — VNRecognizeTextRequest performs best on images >= 32×32 px.
            let minDim: CGFloat = 32
            let fieldImg = UIImage(cgImage: fieldCG)
            let fieldToRecognize: UIImage
            if CGFloat(fieldCG.width) < minDim || CGFloat(fieldCG.height) < minDim {
                let scale = max(minDim / CGFloat(fieldCG.width), minDim / CGFloat(fieldCG.height), 1.0)
                let newW = Int(CGFloat(fieldCG.width)  * scale)
                let newH = Int(CGFloat(fieldCG.height) * scale)
                UIGraphicsBeginImageContextWithOptions(CGSize(width: newW, height: newH), false, 1)
                fieldImg.draw(in: CGRect(x: 0, y: 0, width: newW, height: newH))
                fieldToRecognize = UIGraphicsGetImageFromCurrentImageContext() ?? fieldImg
                UIGraphicsEndImageContext()
            } else {
                fieldToRecognize = fieldImg
            }

            if fid == 12 {
                // MRZ zone: read all lines and split into mrz_line1 / mrz_line2 / mrz_line3.
                // MRZ characters are strictly A-Z, 0-9 and < — ru-RU recognition is
                // counterproductive here (produces Cyrillic homoglyphs that must be stripped).
                // Use en-US only to get clean Latin output without homoglyph contamination.
                group.enter()
                visionOCR.recognizeRawText(image: fieldToRecognize,
                                           languages: ["en-US"]) { text in
                    defer { group.leave() }
                    guard let t = text, !t.isEmpty else { return }
                    // MRZ characters are strictly A-Z, 0-9 and <; filter noise.
                    let mrzLines = t.components(separatedBy: .whitespacesAndNewlines)
                        .map { $0.filter { $0.isLetter || $0.isNumber || $0 == "<" }.uppercased() }
                        .filter { $0.count >= 20 }
                    lock.lock()
                    if mrzLines.count >= 1 { fieldResults["mrz_line1"] = mrzLines[0] }
                    if mrzLines.count >= 2 { fieldResults["mrz_line2"] = mrzLines[1] }
                    if mrzLines.count >= 3 { fieldResults["mrz_line3"] = mrzLines[2] }
                    lock.unlock()
                }
            } else if let key = Self.fieldKeyMap[fid] {
                // Regular field: use raw-text recognizer — field type is already known.
                // For structured Latin/digit-only fields (doc_number fid=6, personal_number
                // fid=11) use en-US only: ru-RU produces Cyrillic homoglyphs (К, О, etc.)
                // that the validatedExternalField gate strips — reducing recall unnecessarily.
                // The homoglyph-normalisation in validatedExternalField recovers the remaining
                // cases, but suppressing the source (ru-RU for these fields) is cleaner.
                // All other fields (names, dates, etc.) keep the default ["en-US", "ru-RU"]
                // so Cyrillic names are still read correctly.
                let fieldLanguages: [String] = Self.leanFieldIds.contains(fid)
                    ? ["en-US"]
                    : ["en-US", "ru-RU"]
                group.enter()
                visionOCR.recognizeRawText(image: fieldToRecognize,
                                           languages: fieldLanguages) { text in
                    defer { group.leave() }
                    guard let t = text, !t.isEmpty else { return }
                    // Guard against overly long strings (card header leakage).
                    // Real field values on KG ID cards are ≤40 characters.
                    guard t.count <= 40 else { return }
                    // Format gate (Android parity): drop malformed doc#/PIN Vision reads
                    // so they can't outvote the correct internal read. See validatedExternalField.
                    guard let value = Self.validatedExternalField(key: key, raw: t) else {
                        finalizerLog.debug("external gate: dropped \(key, privacy: .public) (malformed Vision read)")
                        return
                    }
                    lock.lock()
                    fieldResults[key] = value
                    lock.unlock()
                }
            }
            // fieldIds without a mapping (unknown future classes) are silently skipped.
        }

        // Back-side barcode scan (KG ID 2017+): Code-128 barcodes carry doc# and PIN.
        // Runs in parallel with the per-field Vision passes (same DispatchGroup).
        // Only executed for back-side captures; front sides carry no barcodes.
        let isBackSide = frameResult.cardVersion == .back2008
            || frameResult.cardVersion == .back2017
            || frameResult.cardVersion == .back2025
        if isBackSide {
            group.enter()
            BarcodeReader.readBarcodes(from: crop) { barcodes in
                defer { group.leave() }
                guard !barcodes.isEmpty else { return }
                lock.lock()
                barcodeFields = barcodes
                lock.unlock()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            // Inject barcode votes first — Code-128 mod-103 CRC guarantees exact
            // payload so these values are more reliable than Vision OCR reads.
            if !barcodeFields.isEmpty {
                engine.addExternalOCR(Self.buildBarcodeJson(barcodeFields))
            }
            if !fieldResults.isEmpty {
                // Build a minimal JSON string safe for extractJsonString in C++.
                // Values are escaped for backslash and double-quote only.
                let json = fieldResults.map { k, v in
                    let esc = v
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    return "\"\(k)\":\"\(esc)\""
                }.joined(separator: ",")
                engine.addExternalOCR("{\(json)}")
            }
            self.finalizeAndDeliver(sdkResult: sdkResult, frameResult: frameResult,
                                    crop: crop, engine: engine, completion: completion)
        }
    }

    // ── Barcode JSON builder ──────────────────────────────────

    /// Build the addExternalOCR JSON payload for barcode-decoded fields.
    ///
    /// The `"source":"barcode"` metadata key lets C++ diagnostics identify the
    /// provenance (currently logged; ignored by the field accumulator logic which
    /// only inspects known field-name keys like "doc_number" / "personal_number").
    nonisolated private static func buildBarcodeJson(_ fields: [String: String]) -> String {
        var pairs: [String] = ["\"source\":\"barcode\""]
        for (k, v) in fields {
            let esc = v
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            pairs.append("\"\(k)\":\"\(esc)\"")
        }
        return "{\(pairs.joined(separator: ","))}"
    }

    // ── Delivery ──────────────────────────────────────────────

    /// Reads the (possibly Vision-enriched) C++ OCR result and invokes [completion].
    /// Falls back to Vision-based [MergenOCRProcessor] if the C++ engine returns nothing
    /// (e.g. simulator, OCR disabled).
    /// Must be called on the main thread.
    private func finalizeAndDeliver(
        sdkResult: MergenIdResult,
        frameResult: FrameResult,
        crop: UIImage?,
        engine: MergenEngine,
        completion: @escaping (MergenIdResult) -> Void
    ) {
        var out = sdkResult

        // Capture finalJson HERE — after addExternalOCR() has injected Vision votes.
        // Mirrors Android ScanFinalizer.kt Step 5 (line 123): getFinalResultJson() is called
        // after addExternalOCR and re-fetch, so the returned JSON reflects all Vision votes.
        let rawFinalJson = engine.getFinalResultJson()
        out.finalJson = (rawFinalJson == "{}" || rawFinalJson.trimmingCharacters(in: .whitespaces).isEmpty)
            ? nil
            : rawFinalJson

        // Capture per-side blob BEFORE the caller resets/beginNextSide() the engine.
        // Used by MergenScanView's onFinished to build MergenScanResult.sideJson.
        let rawSideJson = engine.getSideResultJson()
        out.sideResultJson = (rawSideJson == "{}" || rawSideJson.trimmingCharacters(in: .whitespaces).isEmpty)
            ? nil
            : rawSideJson

        if let cppOCR = engine.getOCRResult() {
            out.ocrResult = cppOCR
            logResult(out)
            completion(out)
            return
        }

        guard let crop = crop, frameResult.cardVersion != .unknown else {
            logResult(out)
            completion(out)
            return
        }

        // Last-resort fallback: platform OCR inside MergenOCRProcessor.
        let detectedFields = engine.getDetectedFields()
        let ocr = MergenOCRProcessor()
        if !detectedFields.isEmpty {
            ocr.process(
                image: crop,
                detectedFields: detectedFields,
                cardVersion: frameResult.cardVersion
            ) { [weak self] ocrResult in
                out.ocrResult = ocrResult
                self?.logResult(out)
                completion(out)
            }
        } else {
            ocr.process(image: crop, cardVersion: frameResult.cardVersion) { [weak self] ocrResult in
                out.ocrResult = ocrResult
                self?.logResult(out)
                completion(out)
            }
        }
    }

    // ── Debug logging ─────────────────────────────────────────

    private func logResult(_ result: MergenIdResult) {
        // Structural summary — always on. Tells you which fields the pipeline produced
        // and how long each value is, without ever printing a value.
        var populated: [String] = []
        if let ocr = result.ocrResult {
            let pairs: [(String, String?)] = [
                ("last_name",       ocr.lastName),
                ("first_name",      ocr.firstName),
                ("last_name_lat",   ocr.lastNameLat),
                ("first_name_lat",  ocr.firstNameLat),
                ("patronymic",      ocr.patronymic),
                ("gender",          ocr.gender),
                ("nationality",     ocr.nationality),
                ("birth_date",      ocr.birthDate),
                ("doc_number",      ocr.docNumber),
                ("expiry_date",     ocr.expiryDate),
                ("birth_place",     ocr.birthPlace),
                ("issued_by",       ocr.issuedBy),
                ("issue_date",      ocr.issueDate),
                ("personal_number", ocr.personalNumber),
                ("mrz_line1",       ocr.mrzLine1),
                ("mrz_line2",       ocr.mrzLine2),
                ("mrz_line3",       ocr.mrzLine3),
            ]
            populated = pairs.compactMap { name, value in
                value.map { "\(name):\($0.count)" }
            }
        }
        let confStr = String(format: "%.2f", result.confidence)
        finalizerLog.debug("""
        IdCardResult: version=\(result.cardVersion.rawValue, privacy: .public) \
        flipped=\(result.isFlipped, privacy: .public) conf=\(confStr, privacy: .public) \
        fields=\(populated.count, privacy: .public) \
        [\(populated.joined(separator: ","), privacy: .public)]  (name:len — values need piiTrace)
        """)

        // PII GUARD: the full value dump carries name/doc#/ПИН/MRZ. Gated on `piiTrace`
        // (internal/PiiTrace.swift) so it cannot reach os_log in a client build regardless
        // of configuration; privacy:.private is a second line of defense.
        guard piiTrace else { return }
        var dict: [String: Any] = [
            "card_version": result.cardVersion.rawValue,
            "is_flipped":   result.isFlipped,
            "confidence":   result.confidence,
        ]
        if let ocr = result.ocrResult {
            var ocrDict: [String: String] = [:]
            if let v = ocr.lastName       { ocrDict["last_name"]       = v }
            if let v = ocr.firstName      { ocrDict["first_name"]      = v }
            if let v = ocr.patronymic     { ocrDict["patronymic"]      = v }
            if let v = ocr.gender         { ocrDict["gender"]          = v }
            if let v = ocr.nationality    { ocrDict["nationality"]     = v }
            if let v = ocr.birthDate      { ocrDict["birth_date"]      = v }
            if let v = ocr.docNumber      { ocrDict["doc_number"]      = v }
            if let v = ocr.expiryDate     { ocrDict["expiry_date"]     = v }
            if let v = ocr.birthPlace     { ocrDict["birth_place"]     = v }
            if let v = ocr.issuedBy       { ocrDict["issued_by"]       = v }
            if let v = ocr.issueDate      { ocrDict["issue_date"]      = v }
            if let v = ocr.personalNumber { ocrDict["personal_number"] = v }
            if let v = ocr.mrzLine1       { ocrDict["mrz_line1"]       = v }
            if let v = ocr.mrzLine2       { ocrDict["mrz_line2"]       = v }
            if let v = ocr.mrzLine3       { ocrDict["mrz_line3"]       = v }
            dict["ocr"] = ocrDict
        }
        if let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            finalizerLog.debug("IdCardResult (PII): \(jsonString, privacy: .private)")
        }
    }
}
