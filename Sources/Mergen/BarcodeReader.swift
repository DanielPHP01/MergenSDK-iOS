import Foundation
import Vision
import UIKit
import os

private let barcodeLog = Logger(subsystem: "com.mergen", category: "barcode")

/// Vision Code-128 barcode reader for the back side of KG ID cards (2017 and later).
///
/// KG ID 2017+ cards carry two Code-128 barcodes on the reverse:
///   - Personal identification number (ПИН): exactly 14 decimal digits.
///   - Document number: two uppercase Latin letters followed by 7 digits.
///
/// Code-128 includes a built-in modulo-103 checksum that Vision validates before
/// populating `payloadStringValue`.  A returned payload is either the exact value
/// or absent — there are no partial / garbled reads unlike OCR.
///
/// Threading: `readBarcodes(from:completion:)` runs the Vision request on a
/// dedicated serial background queue.  `completion` is called on that queue.
/// The caller (ScanFinalizer) synchronises via NSLock + DispatchGroup.
internal enum BarcodeReader {

    // ── Classification patterns ───────────────────────────────────────────────

    /// KG ID document-number format: 2 uppercase letters + 7 digits, e.g. "ID1234567".
    private static let docNumberRegex = try! NSRegularExpression(
        pattern: #"^[A-Z]{2}\d{7}$"#
    )

    /// KG ПИН: exactly 14 decimal digits.
    private static let pinRegex = try! NSRegularExpression(
        pattern: #"^\d{14}$"#
    )

    // ── Public API ────────────────────────────────────────────────────────────

    /// Scan Code-128 barcodes in `image` and classify their payloads into
    /// `doc_number` / `personal_number` entries.
    ///
    /// - Parameters:
    ///   - image:      Perspective-corrected card crop (nominally 1280×800).
    ///   - completion: Called (on a background queue) with a dict containing
    ///                 zero or more of: `"doc_number"`, `"personal_number"`.
    ///                 An empty dict means no decodable Code-128 was found.
    static func readBarcodes(
        from image: UIImage,
        completion: @escaping ([String: String]) -> Void
    ) {
        guard let cgImage = image.cgImage else {
            barcodeLog.debug("BARCODE none — no cgImage")
            completion([:])
            return
        }

        let queue = DispatchQueue(
            label: "com.mergen.barcode",
            qos: .userInitiated,
            attributes: [],
            autoreleaseFrequency: .workItem
        )
        queue.async {
            var results: [String: String] = [:]

            let request = VNDetectBarcodesRequest { req, err in
                guard err == nil,
                      let observations = req.results as? [VNBarcodeObservation]
                else { return }

                for obs in observations {
                    guard obs.symbology == .code128,
                          let payload = obs.payloadStringValue,
                          !payload.isEmpty
                    else { continue }

                    if Self.matchesDocNumber(payload) {
                        results["doc_number"] = payload
                    } else if Self.matchesPin(payload) {
                        results["personal_number"] = payload
                    }
                    // Unrecognised payloads are silently ignored.
                }
            }
            // Restrict to Code-128 only — no QR / EAN / etc. noise.
            request.symbologies = [.code128]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])

            // Log outcome. doc# and ПИН are the user's PII: the always-on line reports
            // whether each was decoded and its length — enough to tell "barcode read but
            // wrong length" from "barcode missed" — never the value itself.
            if results.isEmpty {
                barcodeLog.debug("BARCODE none")
            } else {
                let doc = results["doc_number"]        ?? ""
                let pin = results["personal_number"]   ?? ""
                if piiTrace {
                    barcodeLog.debug("BARCODE decoded doc=\(doc, privacy: .public) pin=\(pin, privacy: .public)")
                } else {
                    barcodeLog.debug("BARCODE decoded doc=\(piiLen(doc), privacy: .public) pin=\(piiLen(pin), privacy: .public) (n=\(results.count, privacy: .public))")
                }
            }

            completion(results)
        }
    }

    // ── Payload classification ────────────────────────────────────────────────

    /// Returns `true` when `s` matches `^[A-Z]{2}\d{7}$`.
    private static func matchesDocNumber(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return docNumberRegex.firstMatch(in: s, range: range) != nil
    }

    /// Returns `true` when `s` matches `^\d{14}$`.
    private static func matchesPin(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return pinRegex.firstMatch(in: s, range: range) != nil
    }
}
