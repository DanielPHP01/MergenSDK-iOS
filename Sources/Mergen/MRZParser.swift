import Foundation

/// ICAO 9303 TD1 format MRZ parser (3 lines × 30 chars).
/// Kyrgyz ID card uses TD1.
enum MRZParser {

    struct Parsed {
        var documentNumber: String?
        var lastName:       String?
        var firstName:      String?
        var birthDate:      String?  // "DD MM YYYY"
        var expiryDate:     String?  // "DD MM YYYY"
        var gender:         String?  // "M" / "F"
        var nationality:    String?  // "KGZ" / ...
        var personalNumber: String?
    }

    /// Parse TD1 MRZ (3 lines, 30 chars each).
    ///
    /// Line 1: `I<{CC}{DOC_NUMBER}<{CHECK}{OPTIONAL_DATA}`
    /// Line 2: `{YYMMDD}{CHECK}{SEX}{YYMMDD}{CHECK}{NATIONALITY}<<…{CHECK}`
    /// Line 3: `{SURNAME}<<{GIVEN_NAMES}<<<…`
    public static func parseTD1(line1: String?, line2: String?, line3: String?) -> Parsed? {
        guard let l1 = line1, let l2 = line2, let l3 = line3 else { return nil }

        // Normalise: strip spaces, uppercase
        let c1 = l1.replacingOccurrences(of: " ", with: "").uppercased()
        let c2 = l2.replacingOccurrences(of: " ", with: "").uppercased()
        let c3 = l3.replacingOccurrences(of: " ", with: "").uppercased()

        var p = Parsed()

        // Line 1, positions 5-13: document number (9 chars, '<' padded)
        if c1.count >= 14 {
            let start = c1.index(c1.startIndex, offsetBy: 5)
            let end   = c1.index(c1.startIndex, offsetBy: 14)
            p.documentNumber = String(c1[start..<end]).replacingOccurrences(of: "<", with: "")
        }
        // Line 1, positions 15-29: optional data (may contain personal number)
        if c1.count >= 30 {
            let start = c1.index(c1.startIndex, offsetBy: 15)
            let end   = c1.index(c1.startIndex, offsetBy: 30)
            let opt   = String(c1[start..<end]).replacingOccurrences(of: "<", with: "")
            if !opt.isEmpty { p.personalNumber = opt }
        }

        // Line 2, positions 0-5: birth date (YYMMDD)
        if c2.count >= 18 {
            let birthRaw = String(c2.prefix(6))
            p.birthDate = formatMrzDate(birthRaw, isBirth: true)

            // Position 7: sex
            let sexIdx = c2.index(c2.startIndex, offsetBy: 7)
            let sex = String(c2[sexIdx])
            p.gender = (sex == "M") ? "M" : (sex == "F" ? "F" : nil)

            // Positions 8-13: expiry date (YYMMDD)
            let expiryStart = c2.index(c2.startIndex, offsetBy: 8)
            let expiryEnd   = c2.index(c2.startIndex, offsetBy: 14)
            let expiryRaw   = String(c2[expiryStart..<expiryEnd])
            p.expiryDate = formatMrzDate(expiryRaw, isBirth: false)

            // Positions 15-17: nationality
            let natStart = c2.index(c2.startIndex, offsetBy: 15)
            let natEnd   = c2.index(c2.startIndex, offsetBy: 18)
            p.nationality = String(c2[natStart..<natEnd])
        }

        // Line 3: SURNAME<<GIVEN_NAMES<<<…
        let names = c3.components(separatedBy: "<<")
        if names.count >= 1 {
            let ln = names[0].replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespaces)
            if !ln.isEmpty { p.lastName = ln }
        }
        if names.count >= 2 {
            let fn = names[1].replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespaces)
            if !fn.isEmpty { p.firstName = fn }
        }

        return p
    }

    /// Convert `YYMMDD` → `"DD MM YYYY"`.
    /// For birth dates: if YY > current 2-digit year → 19YY, otherwise 20YY.
    private static func formatMrzDate(_ raw: String, isBirth: Bool) -> String? {
        guard raw.count == 6,
              let yy = Int(raw.prefix(2)),
              let mm = Int(raw.dropFirst(2).prefix(2)),
              let dd = Int(raw.dropFirst(4).prefix(2)) else { return nil }
        let currentYY = Calendar.current.component(.year, from: Date()) % 100
        let century   = isBirth ? (yy > currentYY ? 1900 : 2000) : 2000
        return String(format: "%02d %02d %04d", dd, mm, century + yy)
    }
}
