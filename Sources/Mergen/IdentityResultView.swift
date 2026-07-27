import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// Identity V2 — document-style SwiftUI result UI
//
// Full parity with Android's AndroidProdConsumerTest/MainActivity.kt:
//   DocStatusStamp, DocumentHeroCard, BackDocumentCard, SameDocSeal,
//   VerifyHeadlineCard, ConfidencePill, HeadlineValueRow, AllFieldsTable,
//   CollapsibleOcrProd.
//
// NOTE: Uses a plain VStack (NOT List or ScrollView) on purpose so it embeds
// safely in any parent scrolling container (same reason Kotlin uses plain Column).
// The caller owns the ScrollView.
// ─────────────────────────────────────────────────────────────────────────────

// ── Design tokens (exact Android parity) ─────────────────────────────────────

private enum DocColors {
    static let verified        = Color(hex: 0x00897B)  // teal-700
    static let verifiedVisual  = Color(hex: 0x0277BD)  // light-blue-800 — positive but noted
    static let failedFront     = Color(hex: 0xE65100)  // deep-orange-900
    static let failedBack      = Color(hex: 0xE65100)
    static let failed          = Color(hex: 0xB71C1C)  // red-900
    static let unknown         = Color(hex: 0x546E7A)  // blue-grey-600
    static let sameDoc      = Color(hex: 0x2E7D32)  // green-800
    static let sameWarn     = Color(hex: 0xE65100)
    static let mismatch     = Color(hex: 0xB71C1C)
    static let singleSide   = Color(hex: 0x37474F)

    // Document card chrome
    static let docBg        = Color(hex: 0x1A2540)  // dark navy
    static let docBorder    = Color(hex: 0x2E4A7A)
    static let docFieldLabel = Color(hex: 0x90CAF9) // light blue
    static let docFieldValue = Color.white
    static let mrzBand      = Color(hex: 0x101828)
    static let mrzText      = Color(hex: 0xB0BEC5)

    // OCR block
    static let codeBlockBg   = Color(hex: 0x1A1A1A)
    static let codeBlockText  = Color(hex: 0x80CBC4)
    static let codeHeaderBg   = Color(hex: 0x2A2A2A)

    // Confidence badge
    static let confConfirmed = Color(hex: 0x2E7D32)
    static let confProbable  = Color(hex: 0xF57F17)
    static let confUncertain = Color(hex: 0xB71C1C)
    static let confMissing   = Color(hex: 0x546E7A)

    // Hero card
    static let heroBg        = Color(hex: 0x0D1B2A)
    static let heroAccent     = Color(hex: 0x00C853)
}

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >>  8) & 0xFF) / 255
        let b = Double( hex        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// ── ConfidenceBadge → color ───────────────────────────────────────────────────

private func badgeColor(_ badge: ConfidenceBadge) -> Color {
    switch badge {
    case .confirmed: return DocColors.confConfirmed
    case .probable:  return DocColors.confProbable
    case .uncertain: return DocColors.confUncertain
    case .missing:   return DocColors.confMissing
    case .unknown:   return DocColors.confMissing
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ConfidencePill
// ─────────────────────────────────────────────────────────────────────────────

/**
 Compact confidence pill — "CONFIRMED 92%", "PROBABLE", "UNCERTAIN", or "MISSING".
 Android parity: `ConfidencePill` in MainActivity.kt.
 */
struct ConfidencePill: View {
    let badge:       ConfidenceBadge
    let confidence:  Double

    init(badge: ConfidenceBadge, confidence: Double = -1.0) {
        self.badge      = badge
        self.confidence = confidence
    }

    var body: some View {
        let color = badgeColor(badge)
        let label: String = {
            if confidence >= 0 {
                return "\(badge.rawValue) \(Int(confidence * 100))%"
            }
            return badge.rawValue
        }()
        Text(label)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(color.opacity(0.55), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VerifyHeadlineCard  — verify_id / verify_pin hero card
// ─────────────────────────────────────────────────────────────────────────────

/**
 Hero card showing the authoritative verify_id + verify_pin.
 Android parity: `VerifyHeadlineCard` in MainActivity.kt.
 */
struct VerifyHeadlineCard: View {
    let verifyId:  String
    let verifyPin: String
    let status:    VerifyStatus
    let docBadge:  ConfidenceBadge
    let pinBadge:  ConfidenceBadge

    init(
        verifyId:  String,
        verifyPin: String,
        status:    VerifyStatus,
        docBadge:  ConfidenceBadge = .unknown,
        pinBadge:  ConfidenceBadge = .unknown
    ) {
        self.verifyId  = verifyId
        self.verifyPin = verifyPin
        self.status    = status
        self.docBadge  = docBadge
        self.pinBadge  = pinBadge
    }

    var body: some View {
        let accentColor: Color = {
            switch status {
            case .verified:       return DocColors.heroAccent           // green
            case .verifiedVisual: return Color(hex: 0x29B6F6)           // light-blue-400
            default:              return DocColors.failedFront
            }
        }()

        VStack(alignment: .leading, spacing: 0) {
            // Top gradient stripe
            LinearGradient(
                colors: [Color(hex: 0x003F87), accentColor],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 5)

            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack {
                    Text("ИТОГОВОЕ ПОДТВЕРЖДЁННОЕ ЗНАЧЕНИЕ")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(accentColor)
                        .tracking(1.2)
                    Spacer()
                    Text("KG ID · MERGEN")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(DocColors.docFieldLabel.opacity(0.55))
                }

                Divider().background(DocColors.docBorder)

                // verify_id
                HeadlineValueRow(
                    label:       "НОМЕР ДОКУМЕНТА / DOC NUMBER",
                    value:       verifyId.isEmpty ? "—" : verifyId,
                    badge:       docBadge,
                    accentColor: accentColor
                )
                // verify_pin
                HeadlineValueRow(
                    label:       "ЖЕКЕ ПИН / PERSONAL NUMBER",
                    value:       verifyPin.isEmpty ? "—" : verifyPin,
                    badge:       pinBadge,
                    accentColor: accentColor
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(DocColors.heroBg)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 6)
    }
}

/**
 Single row with label, value, and optional badge chip.
 Android parity: `HeadlineValueRow` in MainActivity.kt.
 */
struct HeadlineValueRow: View {
    let label:       String
    let value:       String
    let badge:       ConfidenceBadge
    let accentColor: Color

    init(
        label:       String,
        value:       String,
        badge:       ConfidenceBadge,
        accentColor: Color
    ) {
        self.label       = label
        self.value       = value
        self.badge       = badge
        self.accentColor = accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(DocColors.docFieldLabel)
                    .tracking(0.8)
                if badge != .unknown {
                    ConfidencePill(badge: badge)
                }
            }
            Text(value)
                .font(.system(size: 26, weight: .black, design: .monospaced))
                .foregroundColor(value == "—" ? DocColors.docFieldLabel.opacity(0.4) : DocColors.docFieldValue)
                .tracking(1.5)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// DocStatusStamp
// ─────────────────────────────────────────────────────────────────────────────

/**
 Status stamp — top banner that looks like an official "stamp" on the document.
 Android parity: `DocStatusStamp` in MainActivity.kt.
 */
struct DocStatusStamp: View {
    let status:  VerifyStatus
    let message: String?

    init(status: VerifyStatus, message: String?) {
        self.status  = status
        self.message = message
    }

    private var bgColor: Color {
        switch status {
        case .verified:       return DocColors.verified
        case .verifiedVisual: return DocColors.verifiedVisual
        case .failedFront:    return DocColors.failedFront
        case .failedBack:     return DocColors.failedBack
        case .failed:         return DocColors.failed
        case .unknown:        return DocColors.unknown
        }
    }

    private var label: String {
        switch status {
        case .verified:       return "ВЕРИФИЦИРОВАНО"
        case .verifiedVisual: return "ПОДТВЕРЖДЕНО (визуально)"
        case .failedFront:    return "ОШИБКА — ФРОНТ"
        case .failedBack:     return "ОШИБКА — БЭК"
        case .failed:         return "РАСХОЖДЕНИЕ"
        case .unknown:        return "СТАТУС НЕИЗВЕСТЕН"
        }
    }

    private var okSymbol: String { status.isSuccess ? "OK" : "!" }

    var body: some View {
        // Wrap in a rounded-corner container so the top stamp corners are always
        // rounded regardless of whether a message row follows.
        VStack(spacing: 0) {
            // ── Top stamp row ──────────────────────────────────────────
            HStack(spacing: 14) {
                // Square seal indicator
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                        )
                    Text(okSymbol)
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 0) {
                    Text("MERGEN ID VERIFY")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.70))
                        .tracking(1.5)
                    Text(label)
                        .font(.system(size: 20, weight: .black))
                        .foregroundColor(.white)
                        .tracking(0.5)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(bgColor)

            // ── Optional message row ───────────────────────────────────
            if let msg = message {
                HStack {
                    Text(msg)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(bgColor)
                        .lineSpacing(4)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(bgColor.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 0)
                        .stroke(bgColor.opacity(0.30), lineWidth: 1)
                )
            }

            // ── verifiedVisual note row ────────────────────────────────
            if status == .verifiedVisual {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundColor(bgColor)
                    Text("MRZ не считан — подтверждено визуальным совпадением сторон")
                        .font(.system(size: 12))
                        .foregroundColor(bgColor)
                        .lineSpacing(3)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(bgColor.opacity(0.10))
            }
        }
        // Single clipShape on the outer VStack gives proper rounded corners everywhere.
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(bgColor.opacity((message != nil || status == .verifiedVisual) ? 0.30 : 0), lineWidth: 1)
        )
    }
}

private extension View {
    @ViewBuilder
    func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// DocumentHeroCard  — FRONT document card
// ─────────────────────────────────────────────────────────────────────────────

/**
 FRONT document hero card — dark navy card resembling the physical KG ID.
 Android parity: `DocumentHeroCard` in MainActivity.kt.
 */
struct DocumentHeroCard: View {
    let photo:         UIImage?
    let docNumber:     String?
    let pin:           String?
    let versionLabel:  String?
    let showPin:       Bool

    init(
        photo:        UIImage?,
        docNumber:    String?,
        pin:          String?,
        versionLabel: String? = nil,
        showPin:      Bool    = true
    ) {
        self.photo        = photo
        self.docNumber    = docNumber
        self.pin          = pin
        self.versionLabel = versionLabel
        self.showPin      = showPin
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top accent stripe (KG flag blue → red)
            LinearGradient(
                colors: [Color(hex: 0x003F87), Color(hex: 0xE8112D)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 6)

            // Document header row
            HStack {
                Text("КЫРГЫЗ РЕСПУБЛИКАСЫ")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DocColors.docFieldLabel)
                    .tracking(1.0)
                Spacer()
                Text(versionLabel ?? "ID CARD")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(DocColors.docFieldLabel.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().background(DocColors.docBorder).padding(.horizontal, 0)

            // Photo + fields
            HStack(alignment: .top, spacing: 14) {
                // Photo slot
                Group {
                    if let img = photo {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            DocColors.docBorder
                            Text("НЕТ\nФОТО")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(DocColors.docFieldLabel.opacity(0.5))
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(width: 110, height: 147)  // portrait 0.75 aspect
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Fields column
                VStack(alignment: .leading, spacing: 14) {
                    DocPrintedField(
                        label: "НОМЕР ДОКУМЕНТА\nDOC NUMBER",
                        value: docNumber ?? "—"
                    )
                    if showPin {
                        DocPrintedField(
                            label: "ЖЕКЕ ПИН\nPERSONAL NUMBER",
                            value: pin ?? "—"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
        .background(DocColors.docBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 4)
    }
}

/**
 A single field rendered like printed text on a physical ID card.
 */
private struct DocPrintedField: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(DocColors.docFieldLabel)
                .tracking(0.8)
                .lineSpacing(2)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(DocColors.docFieldValue)
                .tracking(1.0)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// BackDocumentCard  — BACK card with MRZ zone
// ─────────────────────────────────────────────────────────────────────────────

/**
 BACK document card — dark card with photo above and MRZ zone below.
 Android parity: `BackDocumentCard` in MainActivity.kt.
 */
struct BackDocumentCard: View {
    let photo:        UIImage?
    let mrzFull:      String?
    let mrzDocNumber: String?
    let mrzPin:       String?

    init(
        photo:        UIImage?,
        mrzFull:      String?,
        mrzDocNumber: String?,
        mrzPin:       String?
    ) {
        self.photo        = photo
        self.mrzFull      = mrzFull
        self.mrzDocNumber = mrzDocNumber
        self.mrzPin       = mrzPin
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top accent stripe (red → blue)
            LinearGradient(
                colors: [Color(hex: 0xE8112D), Color(hex: 0x003F87)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 6)

            // Back photo
            Group {
                if let img = photo {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    ZStack {
                        DocColors.docBorder
                        Text("НЕТ ФОТО")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(DocColors.docFieldLabel.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }

            // MRZ labeled fields
            if mrzDocNumber != nil || mrzPin != nil {
                Divider().background(DocColors.docBorder)
                HStack(spacing: 20) {
                    if let docNum = mrzDocNumber {
                        DocPrintedField(label: "MRZ DOC NUMBER", value: docNum)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let mrzPin = mrzPin {
                        DocPrintedField(label: "MRZ PIN", value: mrzPin)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            // MRZ full zone
            if let mrzFull = mrzFull, !mrzFull.isEmpty {
                Divider().background(DocColors.docBorder)
                VStack(alignment: .leading, spacing: 5) {
                    Text("MACHINE READABLE ZONE")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundColor(DocColors.mrzText.opacity(0.55))
                        .tracking(1.5)
                    ForEach(mrzFull.components(separatedBy: "\n").filter { !$0.isEmpty }, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(DocColors.mrzText)
                            .tracking(1.0)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(DocColors.mrzBand)
            }
        }
        .background(DocColors.docBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 4)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SameDocSeal
// ─────────────────────────────────────────────────────────────────────────────

/**
 Same-document seal — styled like an official verification stamp.
 Android parity: `SameDocSeal` in MainActivity.kt.
 */
struct SameDocSeal: View {
    let verdict: SameDocumentVerdict

    init(verdict: SameDocumentVerdict) { self.verdict = verdict }

    private struct Style {
        let bgColor:  Color
        let symbol:   String
        let title:    String
        let subtitle: String
    }

    private var sealStyle: Style {
        switch verdict {
        case .sameDocument:
            return Style(bgColor: DocColors.sameDoc, symbol: "OK",
                         title: "ТОТ ЖЕ ДОКУМЕНТ",
                         subtitle: "Фронт и бэк принадлежат одному документу")
        case .sameWithWarning:
            return Style(bgColor: DocColors.sameWarn, symbol: "!",
                         title: "ДОКУМЕНТ: ДА (предупреждение)",
                         subtitle: "Одно поле расходится — проверьте вручную")
        case .mismatch:
            return Style(bgColor: DocColors.mismatch, symbol: "X",
                         title: "РАСХОЖДЕНИЕ",
                         subtitle: "Фронт и бэк НЕ совпадают")
        case .singleSide:
            return Style(bgColor: DocColors.singleSide, symbol: "~",
                         title: "ОДНА СТОРОНА",
                         subtitle: "Сверка невозможна — нужна вторая сторона")
        case .unknown:
            return Style(bgColor: DocColors.unknown, symbol: "?",
                         title: "НЕИЗВЕСТНО",
                         subtitle: "Вердикт не определён")
        }
    }

    var body: some View {
        let s = sealStyle
        HStack(spacing: 14) {
            // Circle seal
            ZStack {
                Circle().fill(s.bgColor)
                Text(s.symbol)
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 0) {
                Text("SAME-DOCUMENT VERDICT")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(s.bgColor.opacity(0.70))
                    .tracking(1.2)
                Text(s.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(s.bgColor)
                    .tracking(0.3)
                Text(s.subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(s.bgColor.opacity(0.80))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(s.bgColor.opacity(0.09))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(s.bgColor, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VisualVsMrzTable  — per-field ВИЗУАЛ ↔ MRZ side-by-side comparison
// ─────────────────────────────────────────────────────────────────────────────

/**
 Data for one row in the ВИЗУАЛ ↔ MRZ comparison table.
 */
struct VisualMrzRow: Identifiable {
    let id:            UUID
    let fieldName:     String     // e.g. "НОМЕР ДОКУМЕНТА"
    let visualFront:   String?    // OCR read from front
    let visualBack:    String?    // OCR read from back (same field if present)
    let mrzValue:      String?    // MRZ-derived value
    let finalValue:    String     // authoritative fused value
    let match:         MatchTier  // how well visual aligns with MRZ / fused
    let badge:         ConfidenceBadge

    enum MatchTier {
        case fullMatch        // visual == mrz, checksums ok
        case partialMatch     // at least one visual matches mrz
        case mismatch         // visual and mrz disagree
        case mrzOnly          // no visual read, mrz present
        case visualOnly       // no mrz, visual only
        case noData           // nothing available
    }

    init(
        fieldName:   String,
        visualFront: String?,
        visualBack:  String?,
        mrzValue:    String?,
        finalValue:  String,
        match:       MatchTier,
        badge:       ConfidenceBadge
    ) {
        self.id          = UUID()
        self.fieldName   = fieldName
        self.visualFront = visualFront
        self.visualBack  = visualBack
        self.mrzValue    = mrzValue
        self.finalValue  = finalValue
        self.match       = match
        self.badge       = badge
    }
}

/**
 ВИЗУАЛ ↔ MRZ per-field comparison table.

 Shows for each key field (doc_number, personal_number):
   - Визуал (фронт) — OCR read from the front side
   - Визуал (бэк)   — OCR read from the back side (same field when present)
   - MRZ            — machine-readable zone value
   - Итог           — authoritative fused value (verify_id / verify_pin)
   - Match badge    — full/partial/mismatch indicator

 Version-aware: fields absent for the detected card version show "—".
 */
struct VisualVsMrzTable: View {
    let rows: [VisualMrzRow]

    init(rows: [VisualMrzRow]) { self.rows = rows }

    var body: some View {
        VStack(spacing: 0) {
            // Column header
            HStack(spacing: 0) {
                headerCell("ПОЛЕ",          width: 90)
                Divider().frame(width: 1, height: 36).background(DocColors.docBorder)
                headerCell("ВИЗУАЛ\nФРОНТ", width: 90)
                Divider().frame(width: 1, height: 36).background(DocColors.docBorder)
                headerCell("ВИЗУАЛ\nБЭК",   width: 90)
                Divider().frame(width: 1, height: 36).background(DocColors.docBorder)
                headerCell("MRZ",           width: 90)
                Divider().frame(width: 1, height: 36).background(DocColors.docBorder)
                headerCell("ИТОГ",          width: nil)
            }
            .frame(maxWidth: .infinity)
            .background(DocColors.codeHeaderBg)

            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                Divider().background(DocColors.docBorder)
                HStack(alignment: .top, spacing: 0) {
                    // Field name
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.fieldName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DocColors.docFieldLabel)
                            .tracking(0.5)
                        matchBadgeView(row.match)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .frame(width: 90, alignment: .leading)

                    Divider().frame(width: 1).background(DocColors.docBorder)

                    monoCell(row.visualFront, width: 90)

                    Divider().frame(width: 1).background(DocColors.docBorder)

                    monoCell(row.visualBack, width: 90)

                    Divider().frame(width: 1).background(DocColors.docBorder)

                    monoCell(row.mrzValue, width: 90)

                    Divider().frame(width: 1).background(DocColors.docBorder)

                    // Final (итог) — highlighted
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.finalValue.isEmpty ? "—" : row.finalValue)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(row.finalValue.isEmpty ? DocColors.docFieldLabel.opacity(0.45) : DocColors.docFieldValue)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                        ConfidencePill(badge: row.badge)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(idx % 2 == 0 ? DocColors.docBg : DocColors.docBg.opacity(0.75))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DocColors.docBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func headerCell(_ text: String, width: CGFloat?) -> some View {
        if let w = width {
            Text(text)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(DocColors.docFieldLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .frame(width: w, alignment: .center)
        } else {
            Text(text)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(DocColors.docFieldLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func monoCell(_ value: String?, width: CGFloat) -> some View {
        Text(value ?? "—")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(value != nil ? DocColors.mrzText : DocColors.docFieldLabel.opacity(0.4))
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func matchBadgeView(_ tier: VisualMrzRow.MatchTier) -> some View {
        let (label, color): (String, Color) = {
            switch tier {
            case .fullMatch:    return ("СОВПАД", DocColors.confConfirmed)
            case .partialMatch: return ("ЧАСТИЧНО", DocColors.confProbable)
            case .mismatch:     return ("РАСХОЖД", DocColors.confUncertain)
            case .mrzOnly:      return ("MRZ", DocColors.confProbable)
            case .visualOnly:   return ("ВИЗУАЛ", DocColors.confProbable)
            case .noData:       return ("НЕТ", DocColors.confMissing)
            }
        }()
        Text(label)
            .font(.system(size: 7, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// RawJsonFieldsTable — "ВСЕ ПОЛЯ (JSON)" exhaustive breakdown
// ─────────────────────────────────────────────────────────────────────────────

/**
 Data model for a single raw field in the JSON breakdown.
 */
struct RawJsonField: Identifiable {
    let id:     UUID
    let group:  String   // section header
    let key:    String   // JSON key
    let value:  String   // string representation of the value (or "—" for absent)

    init(group: String, key: String, value: String) {
        self.id    = UUID()
        self.group = group
        self.key   = key
        self.value = value
    }
}

/**
 Exhaustive breakdown of every JSON field from the engine output.

 Groups:
 - ИТОГ (fused headline): verify_id, verify_pin, status, mrz_confirmed, same_document
 - OCR ВИЗУАЛ ФРОНТ:    side, version, doc_number, pin
 - OCR ВИЗУАЛ БЭК:      side, version, doc_number, pin, mrz_doc_number, mrz_pin, mrz_full
 - MRZ:                 mrz_doc_number, mrz_pin, mrz_full (from VerifyResult)

 Version-aware: absent fields render as "—".
 */
struct RawJsonFieldsTable: View {
    let groups: [(header: String, fields: [RawJsonField])]

    init(groups: [(header: String, fields: [RawJsonField])]) {
        self.groups = groups
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(spacing: 0) {
                    // Group header
                    HStack {
                        Text(group.header)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(DocColors.codeBlockText)
                            .tracking(1.0)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DocColors.codeHeaderBg)

                    ForEach(Array(group.fields.enumerated()), id: \.element.id) { idx, field in
                        Divider().background(DocColors.docBorder)
                        HStack(alignment: .top, spacing: 12) {
                            Text(field.key)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(DocColors.docFieldLabel)
                                .frame(width: 145, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(field.value)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(field.value == "—"
                                                 ? DocColors.docFieldLabel.opacity(0.4)
                                                 : DocColors.docFieldValue)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(idx % 2 == 0
                                    ? DocColors.codeBlockBg
                                    : DocColors.codeBlockBg.opacity(0.75))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DocColors.docBorder, lineWidth: 0.8)
                )
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers: build VisualVsMrzTable rows + RawJsonFieldsTable groups from VerifyResult
// ─────────────────────────────────────────────────────────────────────────────

/// Parse an OCR_PROD JSON string into a dictionary. Returns nil on failure.
private func parseOcrProd(_ json: String?) -> [String: Any]? {
    guard let json, !json.isEmpty,
          let data = json.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    return obj
}

/// Normalise an optional string — nil or empty → nil.
private func norm(_ s: String?) -> String? {
    s.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
}

/// Build ВИЗУАЛ ↔ MRZ comparison rows for a `VerifyResult`.
func buildVisualMrzRows(_ result: VerifyResult) -> [VisualMrzRow] {
    let frontProd = parseOcrProd(result.ocrProdFront)
    let backProd  = parseOcrProd(result.ocrProdBack)

    func str(_ dict: [String: Any]?, _ key: String) -> String? {
        norm(dict?[key] as? String)
    }

    var rows: [VisualMrzRow] = []

    // ── doc_number ───────────────────────────────────────────────────
    let visDocFront = str(frontProd, "doc_number")
    let visDocBack  = str(backProd,  "doc_number")
    let mrzDoc      = norm(result.mrzDocNumber)
    let finalDoc    = result.verifyId

    let docMatch: VisualMrzRow.MatchTier = {
        let visuals = [visDocFront, visDocBack].compactMap { $0 }
        if visuals.isEmpty && mrzDoc == nil { return .noData }
        if visuals.isEmpty { return .mrzOnly }
        if mrzDoc == nil   { return .visualOnly }
        let allMatch = visuals.allSatisfy { $0 == mrzDoc }
        if allMatch { return .fullMatch }
        let anyMatch = visuals.contains { $0 == mrzDoc }
        return anyMatch ? .partialMatch : .mismatch
    }()

    rows.append(VisualMrzRow(
        fieldName:   "НОМЕР ДОК.",
        visualFront: visDocFront,
        visualBack:  visDocBack,
        mrzValue:    mrzDoc,
        finalValue:  finalDoc,
        match:       docMatch,
        badge:       result.docBadge
    ))

    // ── personal_number (PIN) ────────────────────────────────────────
    // Version-aware: Front2017 and Front2025 have no printed PIN.
    let frontHasPin = result.frontFieldAvailability?.hasVisPin ?? true
    let backHasPin  = result.backFieldAvailability?.hasVisPin  ?? true

    let visPinFront = frontHasPin ? str(frontProd, "pin") : nil
    let visPinBack  = backHasPin  ? str(backProd,  "pin") : nil
    let mrzPin      = norm(result.mrzPin)
    let finalPin    = result.verifyPin

    let pinMatch: VisualMrzRow.MatchTier = {
        let visuals = [visPinFront, visPinBack].compactMap { $0 }
        if visuals.isEmpty && mrzPin == nil { return .noData }
        if visuals.isEmpty { return .mrzOnly }
        if mrzPin == nil   { return .visualOnly }
        let allMatch = visuals.allSatisfy { $0 == mrzPin }
        if allMatch { return .fullMatch }
        let anyMatch = visuals.contains { $0 == mrzPin }
        return anyMatch ? .partialMatch : .mismatch
    }()

    rows.append(VisualMrzRow(
        fieldName:   "ЖЕК. ПИН",
        visualFront: visPinFront,
        visualBack:  visPinBack,
        mrzValue:    mrzPin,
        finalValue:  finalPin,
        match:       pinMatch,
        badge:       result.pinBadge
    ))

    return rows
}

/// Build exhaustive raw-JSON field groups for a `VerifyResult`.
func buildRawJsonGroups(_ result: VerifyResult) -> [(header: String, fields: [RawJsonField])] {
    let frontProd = parseOcrProd(result.ocrProdFront)
    let backProd  = parseOcrProd(result.ocrProdBack)

    func v(_ s: String?)  -> String { s.flatMap { $0.isEmpty ? nil : $0 } ?? "—" }
    func vb(_ b: Bool)    -> String { b ? "true" : "false" }
    func vd(_ d: [String: Any]?, _ k: String) -> String { v(d?[k] as? String) }

    var groups: [(header: String, fields: [RawJsonField])] = []

    // ── Group 1: ИТОГ ────────────────────────────────────────────────
    groups.append((
        header: "ИТОГ (FUSED)",
        fields: [
            RawJsonField(group: "ИТОГ", key: "verify_id",      value: v(result.verifyId.nilIfEmpty)),
            RawJsonField(group: "ИТОГ", key: "verify_pin",     value: v(result.verifyPin.nilIfEmpty)),
            RawJsonField(group: "ИТОГ", key: "status",         value: result.status.rawValue),
            RawJsonField(group: "ИТОГ", key: "mrz_confirmed",  value: vb(result.mrzConfirmed)),
            RawJsonField(group: "ИТОГ", key: "same_document",  value: result.sameDocument.rawValue),
            RawJsonField(group: "ИТОГ", key: "doc_badge",      value: result.docBadge.rawValue),
            RawJsonField(group: "ИТОГ", key: "pin_badge",      value: result.pinBadge.rawValue),
        ]
    ))

    // ── Group 2: OCR ВИЗУАЛ ФРОНТ ────────────────────────────────────
    groups.append((
        header: "OCR ВИЗУАЛ — ФРОНТ",
        fields: [
            RawJsonField(group: "ФРОНТ", key: "side",       value: vd(frontProd, "side")),
            RawJsonField(group: "ФРОНТ", key: "version",    value: vd(frontProd, "version")),
            RawJsonField(group: "ФРОНТ", key: "doc_number", value: vd(frontProd, "doc_number")),
            RawJsonField(group: "ФРОНТ", key: "pin",        value: vd(frontProd, "pin")),
        ]
    ))

    // ── Group 3: OCR ВИЗУАЛ БЭК ─────────────────────────────────────
    groups.append((
        header: "OCR ВИЗУАЛ — БЭК",
        fields: [
            RawJsonField(group: "БЭК", key: "side",           value: vd(backProd, "side")),
            RawJsonField(group: "БЭК", key: "version",        value: vd(backProd, "version")),
            RawJsonField(group: "БЭК", key: "doc_number",     value: vd(backProd, "doc_number")),
            RawJsonField(group: "БЭК", key: "pin",            value: vd(backProd, "pin")),
            RawJsonField(group: "БЭК", key: "mrz_doc_number", value: vd(backProd, "mrz_doc_number")),
            RawJsonField(group: "БЭК", key: "mrz_pin",        value: vd(backProd, "mrz_pin")),
            RawJsonField(group: "БЭК", key: "mrz_full",       value: vd(backProd, "mrz_full")),
        ]
    ))

    // ── Group 4: MRZ (from VerifyResult top-level) ────────────────────
    groups.append((
        header: "MRZ (VerifyResult)",
        fields: [
            RawJsonField(group: "MRZ", key: "mrz_doc_number", value: v(result.mrzDocNumber)),
            RawJsonField(group: "MRZ", key: "mrz_pin",        value: v(result.mrzPin)),
            RawJsonField(group: "MRZ", key: "mrz_full",       value: v(result.mrzFull)),
        ]
    ))

    return groups
}

/// Build ВИЗУАЛ ↔ MRZ comparison rows for the gallery path.
///
/// The gallery path exposes per-side OCR reads via `LeanVerifyResult` instead of
/// directly via `VerifyResult.ocrProdFront/Back`, so the logic is slightly different
/// from the camera path (`buildVisualMrzRows`).
func buildGalleryVisualMrzRows(
    lean:              LeanVerifyResult?,
    identity:          FusedIdentity?,
    verifyId:          String,
    verifyPin:         String,
    frontAvailability: FieldAvailability?,
    backAvailability:  FieldAvailability?
) -> [VisualMrzRow] {
    var rows: [VisualMrzRow] = []

    // ── doc_number ───────────────────────────────────────────────────
    let visDocFront = norm(lean?.docNumberFront)
    let visDocBack  = norm(lean?.docNumberBack)
    let mrzDoc      = norm(lean?.mrzDocNumber)
    let finalDoc    = verifyId

    let docBadge = identity?.docNumber?.badge ?? .unknown

    let docMatch: VisualMrzRow.MatchTier = {
        let visuals = [visDocFront, visDocBack].compactMap { $0 }
        if visuals.isEmpty && mrzDoc == nil { return .noData }
        if visuals.isEmpty { return .mrzOnly }
        if mrzDoc == nil   { return .visualOnly }
        let allMatch = visuals.allSatisfy { $0 == mrzDoc }
        if allMatch { return .fullMatch }
        let anyMatch = visuals.contains { $0 == mrzDoc }
        return anyMatch ? .partialMatch : .mismatch
    }()

    rows.append(VisualMrzRow(
        fieldName:   "НОМЕР ДОК.",
        visualFront: visDocFront,
        visualBack:  visDocBack,
        mrzValue:    mrzDoc,
        finalValue:  finalDoc,
        match:       docMatch,
        badge:       docBadge
    ))

    // ── personal_number (PIN) — version-aware ────────────────────────
    let frontHasPin = frontAvailability?.hasVisPin ?? true
    let backHasPin  = backAvailability?.hasVisPin  ?? true

    let visPinFront = frontHasPin ? norm(lean?.pinFront) : nil
    let visPinBack  = backHasPin  ? norm(lean?.pinBack)  : nil
    let mrzPin      = norm(lean?.mrzPin)
    let finalPin    = verifyPin

    let pinBadge = identity?.pin?.badge ?? .unknown

    let pinMatch: VisualMrzRow.MatchTier = {
        let visuals = [visPinFront, visPinBack].compactMap { $0 }
        if visuals.isEmpty && mrzPin == nil { return .noData }
        if visuals.isEmpty { return .mrzOnly }
        if mrzPin == nil   { return .visualOnly }
        let allMatch = visuals.allSatisfy { $0 == mrzPin }
        if allMatch { return .fullMatch }
        let anyMatch = visuals.contains { $0 == mrzPin }
        return anyMatch ? .partialMatch : .mismatch
    }()

    rows.append(VisualMrzRow(
        fieldName:   "ЖЕК. ПИН",
        visualFront: visPinFront,
        visualBack:  visPinBack,
        mrzValue:    mrzPin,
        finalValue:  finalPin,
        match:       pinMatch,
        badge:       pinBadge
    ))

    return rows
}

/// Build exhaustive raw-JSON field groups for the gallery path.
///
/// Reads from `LeanVerifyResult` (OCR reads) and `FusedIdentity` (confidence badges).
func buildGalleryRawJsonGroups(
    lean:      LeanVerifyResult?,
    identity:  FusedIdentity?,
    verifyId:  String,
    verifyPin: String,
    verdict:   SameDocumentVerdict
) -> [(header: String, fields: [RawJsonField])] {
    func v(_ s: String?)  -> String { s.flatMap { $0.isEmpty ? nil : $0 } ?? "—" }
    func vb(_ b: Bool)    -> String { b ? "true" : "false" }

    var groups: [(header: String, fields: [RawJsonField])] = []

    // ── Group 1: ИТОГ ────────────────────────────────────────────────
    let docBadge = identity?.docNumber?.badge.rawValue ?? "—"
    let pinBadge = identity?.pin?.badge.rawValue       ?? "—"
    groups.append((
        header: "ИТОГ (FUSED)",
        fields: [
            RawJsonField(group: "ИТОГ", key: "verify_id",     value: v(verifyId.nilIfEmpty)),
            RawJsonField(group: "ИТОГ", key: "verify_pin",    value: v(verifyPin.nilIfEmpty)),
            RawJsonField(group: "ИТОГ", key: "same_document", value: verdict.rawValue),
            RawJsonField(group: "ИТОГ", key: "doc_badge",     value: docBadge),
            RawJsonField(group: "ИТОГ", key: "pin_badge",     value: pinBadge),
        ]
    ))

    // ── Group 2: OCR ВИЗУАЛ ФРОНТ ────────────────────────────────────
    let frontSide = identity?.sides.first { $0.side == .front }
    groups.append((
        header: "OCR ВИЗУАЛ — ФРОНТ",
        fields: [
            RawJsonField(group: "ФРОНТ", key: "version",    value: v(frontSide?.version)),
            RawJsonField(group: "ФРОНТ", key: "doc_number", value: v(lean?.docNumberFront)),
            RawJsonField(group: "ФРОНТ", key: "pin",        value: v(lean?.pinFront)),
        ]
    ))

    // ── Group 3: OCR ВИЗУАЛ БЭК ─────────────────────────────────────
    let backSide = identity?.sides.first { $0.side == .back }
    groups.append((
        header: "OCR ВИЗУАЛ — БЭК",
        fields: [
            RawJsonField(group: "БЭК", key: "version",        value: v(backSide?.version)),
            RawJsonField(group: "БЭК", key: "doc_number",     value: v(lean?.docNumberBack)),
            RawJsonField(group: "БЭК", key: "pin",            value: v(lean?.pinBack)),
            RawJsonField(group: "БЭК", key: "mrz_doc_number", value: v(lean?.mrzDocNumber)),
            RawJsonField(group: "БЭК", key: "mrz_pin",        value: v(lean?.mrzPin)),
            RawJsonField(group: "БЭК", key: "mrz_full",       value: v(lean?.mrzFull)),
        ]
    ))

    // ── Group 4: MRZ (from LeanVerifyResult) ─────────────────────────
    groups.append((
        header: "MRZ (LeanVerifyResult)",
        fields: [
            RawJsonField(group: "MRZ", key: "mrz_doc_number", value: v(lean?.mrzDocNumber)),
            RawJsonField(group: "MRZ", key: "mrz_pin",        value: v(lean?.mrzPin)),
            RawJsonField(group: "MRZ", key: "mrz_full",       value: v(lean?.mrzFull)),
        ]
    ))

    return groups
}

// Private helper mirroring the one in Mergen.swift (avoids cross-file dependency)
private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// ─────────────────────────────────────────────────────────────────────────────
// AllFieldsTable / FieldRow
// ─────────────────────────────────────────────────────────────────────────────

/**
 Data model for one row in the AllFieldsTable.
 Android parity: `FieldRow` data class in MainActivity.kt.
 */
struct IdentityFieldRow: Identifiable {
    let id:    UUID
    let key:   String
    let value: String
    let note:  String?

    init(key: String, value: String, note: String? = nil) {
        self.id    = UUID()
        self.key   = key
        self.value = value
        self.note  = note
    }
}

/**
 Clean key-value table for "all fields" section.
 Android parity: `AllFieldsTable` in MainActivity.kt.
 */
struct AllFieldsTable: View {
    let rows: [IdentityFieldRow]

    init(rows: [IdentityFieldRow]) { self.rows = rows }

    var body: some View {
        if rows.isEmpty {
            Text("Нет полей")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(4)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    HStack(alignment: .top, spacing: 12) {
                        Text(row.key)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 140, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.value.isEmpty ? "—" : row.value)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(row.value.isEmpty ? .secondary : .primary)
                            if let note = row.note {
                                Text(note)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(idx % 2 == 0 ? Color(.systemBackground) : Color(.secondarySystemBackground))

                    if idx < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CollapsibleOcrProd
// ─────────────────────────────────────────────────────────────────────────────

/**
 Collapsible code block showing raw OCR_PROD JSON for diagnostics.
 Android parity: `CollapsibleOcrProd` in MainActivity.kt.
 */
struct CollapsibleOcrProd: View {
    let label: String
    let json:  String?

    @State private var expanded = false

    init(label: String, json: String?) {
        self.label = label
        self.json  = json
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row (always visible)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(DocColors.codeBlockText)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(DocColors.codeBlockText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DocColors.codeHeaderBg)
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    Group {
                        if #available(iOS 15, *) {
                            Text(formattedJson)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(DocColors.codeBlockText)
                                .padding(12)
                                .textSelection(.enabled)
                        } else {
                            Text(formattedJson)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(DocColors.codeBlockText)
                                .padding(12)
                        }
                    }
                }
                .background(DocColors.codeBlockBg)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var formattedJson: String {
        guard let json = json, !json.isEmpty else { return "— нет данных —" }
        // Pretty-print if valid JSON, otherwise show raw.
        if let data = json.data(using: .utf8),
           let obj  = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str  = String(data: pretty, encoding: .utf8) {
            return str
        }
        return json
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// DocSectionLabel — section header
// ─────────────────────────────────────────────────────────────────────────────

/**
 Section header label (e.g. "ЛИЦЕВАЯ СТОРОНА").
 Android parity: inline `DocSectionLabel` calls in MainActivity.kt.
 */
struct DocSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.secondary)
            .tracking(1.2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CameraResultView / GalleryResultView
// ─────────────────────────────────────────────────────────────────────────────

/**
 Camera result screen — document-style, driven by `VerifyResult`.
 Android parity: `CameraResultScreen` in MainActivity.kt.

 IMPORTANT: Wrap this view in a `ScrollView` — it uses a plain VStack.
 */
struct MergenCameraResultView: View {
    let result: VerifyResult

    init(result: VerifyResult) { self.result = result }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 14)

            // 0. Authoritative verify_id / verify_pin hero card
            if !result.verifyId.isEmpty || !result.verifyPin.isEmpty {
                VerifyHeadlineCard(
                    verifyId:  result.verifyId,
                    verifyPin: result.verifyPin,
                    status:    result.status
                )
                Spacer().frame(height: 14)
            }

            // 1. Status stamp
            DocStatusStamp(
                status:  result.status,
                message: result.message
            )
            Spacer().frame(height: 20)

            // 2. Front document hero card
            if result.frontPhoto != nil || result.docNumber != nil || result.pin != nil {
                DocSectionLabel("ЛИЦЕВАЯ СТОРОНА")
                Spacer().frame(height: 8)
                DocumentHeroCard(
                    photo:     result.frontPhoto,
                    docNumber: result.docNumber,
                    pin:       result.pin,
                    showPin:   result.pin != nil
                )
                Spacer().frame(height: 16)
            }

            // 3. Back card with MRZ zone
            let hasMrz = result.mrzFull != nil || result.mrzDocNumber != nil || result.mrzPin != nil
            if result.backPhoto != nil || hasMrz {
                DocSectionLabel("ОБОРОТНАЯ СТОРОНА / MRZ")
                Spacer().frame(height: 8)
                BackDocumentCard(
                    photo:        result.backPhoto,
                    mrzFull:      result.mrzFull,
                    mrzDocNumber: result.mrzDocNumber,
                    mrzPin:       result.mrzPin
                )
                Spacer().frame(height: 16)
            }

            // 4. Same-document seal
            DocSectionLabel("ВЕРИФИКАЦИЯ ДОКУМЕНТА")
            Spacer().frame(height: 8)
            SameDocSeal(verdict: result.sameDocument)
            Spacer().frame(height: 20)

            // 5. ВИЗУАЛ ↔ MRZ — per-field comparison
            DocSectionLabel("ВИЗУАЛ \u{2194} MRZ — СРАВНЕНИЕ ПО ПОЛЯМ")
            Spacer().frame(height: 8)
            VisualVsMrzTable(rows: buildVisualMrzRows(result))
            Spacer().frame(height: 20)

            // 6. ВСЕ ПОЛЯ (JSON) — exhaustive per-field breakdown
            DocSectionLabel("ВСЕ ПОЛЯ (JSON)")
            Spacer().frame(height: 8)
            RawJsonFieldsTable(groups: buildRawJsonGroups(result))
            Spacer().frame(height: 20)

            // 7. Legacy AllFieldsTable (headline summary)
            DocSectionLabel("СВОДКА ПОЛЕЙ")
            Spacer().frame(height: 8)
            AllFieldsTable(rows: cameraFieldRows(result))
            Spacer().frame(height: 20)

            // 8. OCR_PROD collapsible blocks
            DocSectionLabel("ТЕХНИЧЕСКИЕ ДАННЫЕ OCR")
            Spacer().frame(height: 8)
            CollapsibleOcrProd(label: "OCR_PROD — ФРОНТ", json: result.ocrProdFront)
            Spacer().frame(height: 8)
            CollapsibleOcrProd(label: "OCR_PROD — БЭК",  json: result.ocrProdBack)
            Spacer().frame(height: 32)
        }
        .padding(.horizontal, 16)
    }

    private func cameraFieldRows(_ result: VerifyResult) -> [IdentityFieldRow] {
        var rows: [IdentityFieldRow] = []
        if !result.verifyId.isEmpty  { rows.append(IdentityFieldRow(key: "verify_id",   value: result.verifyId)) }
        if !result.verifyPin.isEmpty { rows.append(IdentityFieldRow(key: "verify_pin",  value: result.verifyPin)) }
        if let v = result.docNumber  { rows.append(IdentityFieldRow(key: "doc_number",  value: v)) }
        if let v = result.pin        { rows.append(IdentityFieldRow(key: "pin",         value: v)) }
        if let v = result.mrzDocNumber { rows.append(IdentityFieldRow(key: "mrz_doc_number", value: v)) }
        if let v = result.mrzPin     { rows.append(IdentityFieldRow(key: "mrz_pin",     value: v)) }
        if let v = result.mrzFull    { rows.append(IdentityFieldRow(key: "mrz_full",      value: v)) }
        rows.append(IdentityFieldRow(key: "mrz_confirmed",  value: result.mrzConfirmed ? "true" : "false"))
        rows.append(IdentityFieldRow(key: "same_document",  value: result.sameDocument.rawValue))
        rows.append(IdentityFieldRow(key: "status",         value: result.status.rawValue))
        return rows
    }
}

/**
 Gallery result screen — document-style, driven by `FusedIdentity` + raw `MergenIdResult`.
 Android parity: `GalleryResultScreen` in MainActivity.kt.

 IMPORTANT: Wrap this view in a `ScrollView` — it uses a plain VStack.
 */
struct MergenGalleryResultView: View {
    let identity: FusedIdentity?
    let raw:      MergenIdResult

    init(identity: FusedIdentity?, raw: MergenIdResult) {
        self.identity = identity
        self.raw      = raw
    }

    var body: some View {
        let (topStatus, topMessageRu) = parseTopLevelStatus(raw.finalJson)

        let verifyId  = (raw.finalJson.flatMap { extractString($0, "verify_id")  } ?? "")
        let verifyPin = (raw.finalJson.flatMap { extractString($0, "verify_pin") } ?? "")

        let docBadge = identity?.docNumber?.badge ?? .unknown
        let pinBadge = identity?.pin?.badge       ?? .unknown

        let frontSummary = identity?.sides.first { $0.side == .front }
        let backSummary  = identity?.sides.first { $0.side == .back  }

        let lean = identity?.leanVerifyResult

        let docNumber = verifyId.isEmpty ? (
            { (s: String?) -> String? in s.flatMap { $0.isEmpty ? nil : $0 } }(identity?.docNumber?.value)
            ?? lean?.docNumberFront ?? lean?.docNumberBack
        ) : verifyId

        let pin = verifyPin.isEmpty ? (
            { (s: String?) -> String? in s.flatMap { $0.isEmpty ? nil : $0 } }(identity?.pin?.value)
            ?? lean?.pinFront ?? lean?.pinBack
        ) : verifyPin

        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 14)

            // 0. Authoritative verify_id / verify_pin hero card
            if !verifyId.isEmpty || !verifyPin.isEmpty {
                VerifyHeadlineCard(
                    verifyId:  verifyId,
                    verifyPin: verifyPin,
                    status:    topStatus,
                    docBadge:  docBadge,
                    pinBadge:  pinBadge
                )
                Spacer().frame(height: 14)
            }

            // 1. Status stamp
            DocStatusStamp(status: topStatus, message: topMessageRu)
            Spacer().frame(height: 20)

            // 2. Front document hero card
            let frontHasPin = frontSummary?.fieldAvailability.hasVisPin ?? (pin != nil)
            let frontVersionLabel = frontSummary?.version
            if raw.croppedImage != nil || docNumber != nil || pin != nil {
                DocSectionLabel("ЛИЦЕВАЯ СТОРОНА\(frontVersionLabel.map { " · \($0)" } ?? "")")
                Spacer().frame(height: 8)
                DocumentHeroCard(
                    photo:        raw.croppedImage,
                    docNumber:    docNumber,
                    pin:          frontHasPin ? pin : nil,
                    versionLabel: frontVersionLabel,
                    showPin:      frontHasPin
                )
                Spacer().frame(height: 16)
            }

            // 3. Back card with MRZ
            let mrzFull      = lean?.mrzFull
            let mrzDocNumber = lean?.mrzDocNumber
            let mrzPin       = lean?.mrzPin
            let hasMrz = mrzFull != nil || mrzDocNumber != nil || mrzPin != nil
            let backVersionLabel = backSummary?.version
            if raw.croppedImageBack != nil || hasMrz {
                DocSectionLabel("ОБОРОТНАЯ СТОРОНА / MRZ\(backVersionLabel.map { " · \($0)" } ?? "")")
                Spacer().frame(height: 8)
                BackDocumentCard(
                    photo:        raw.croppedImageBack,
                    mrzFull:      mrzFull,
                    mrzDocNumber: mrzDocNumber,
                    mrzPin:       mrzPin
                )
                Spacer().frame(height: 16)
            }

            // 4. Same-document seal
            let verdict = identity?.sameDocument.verdict ?? .unknown
            DocSectionLabel("ВЕРИФИКАЦИЯ ДОКУМЕНТА")
            Spacer().frame(height: 8)
            SameDocSeal(verdict: verdict)
            Spacer().frame(height: 20)

            // 5. ВИЗУАЛ ↔ MRZ — per-field comparison
            DocSectionLabel("ВИЗУАЛ \u{2194} MRZ — СРАВНЕНИЕ ПО ПОЛЯМ")
            Spacer().frame(height: 8)
            VisualVsMrzTable(rows: buildGalleryVisualMrzRows(
                lean:                lean,
                identity:            identity,
                verifyId:            verifyId,
                verifyPin:           verifyPin,
                frontAvailability:   frontSummary?.fieldAvailability,
                backAvailability:    backSummary?.fieldAvailability
            ))
            Spacer().frame(height: 20)

            // 6. ВСЕ ПОЛЯ (JSON) — exhaustive per-field breakdown
            DocSectionLabel("ВСЕ ПОЛЯ (JSON)")
            Spacer().frame(height: 8)
            RawJsonFieldsTable(groups: buildGalleryRawJsonGroups(
                lean:      lean,
                identity:  identity,
                verifyId:  verifyId,
                verifyPin: verifyPin,
                verdict:   verdict
            ))
            Spacer().frame(height: 20)

            // 7. Legacy AllFieldsTable (headline summary)
            DocSectionLabel("СВОДКА ПОЛЕЙ")
            Spacer().frame(height: 8)
            AllFieldsTable(rows: galleryFieldRows(lean, identity, verifyId, verifyPin))
            Spacer().frame(height: 20)

            // 8. OCR_PROD collapsible
            DocSectionLabel("ТЕХНИЧЕСКИЕ ДАННЫЕ OCR")
            Spacer().frame(height: 8)
            CollapsibleOcrProd(
                label: "OCR_PROD — ФРОНТ",
                json:  identity?.ocrProdFrontJson
            )
            Spacer().frame(height: 8)
            CollapsibleOcrProd(
                label: "OCR_PROD — БЭК",
                json:  identity?.ocrProdBackJson
            )

            // 9. Fused fields with per-field confidence badges
            if let identity = identity, !identity.fields.isEmpty {
                Spacer().frame(height: 20)
                DocSectionLabel("FUSED FIELDS — УВЕРЕННОСТЬ (identity_v2)")
                Spacer().frame(height: 8)
                AllFieldsTable(rows: identity.fields.map { f in
                    IdentityFieldRow(
                        key:   f.name,
                        value: f.value.isEmpty ? "—" : f.value,
                        note:  "\(f.badge.rawValue) · \(Int(f.confidence * 100))%"
                    )
                })
            }

            // 10. Errors
            if let identity = identity, !identity.errors.isEmpty {
                Spacer().frame(height: 20)
                DocSectionLabel("ОШИБКИ РЕКОНЧИЛЯЦИИ")
                Spacer().frame(height: 8)
                ForEach(Array(identity.errors.enumerated()), id: \.offset) { _, err in
                    ErrorRow(
                        code:     err.code.rawValue,
                        message:  err.messageRu.isEmpty ? err.messageEn : err.messageRu,
                        severity: err.severity.rawValue
                    )
                }
            }

            Spacer().frame(height: 32)
        }
        .padding(.horizontal, 16)
    }

    private func galleryFieldRows(
        _ lean:      LeanVerifyResult?,
        _ identity:  FusedIdentity?,
        _ verifyId:  String,
        _ verifyPin: String
    ) -> [IdentityFieldRow] {
        var rows: [IdentityFieldRow] = []
        if !verifyId.isEmpty  { rows.append(IdentityFieldRow(key: "verify_id",   value: verifyId)) }
        if !verifyPin.isEmpty { rows.append(IdentityFieldRow(key: "verify_pin",  value: verifyPin)) }
        if let v = lean?.docNumberFront  { rows.append(IdentityFieldRow(key: "doc_number (front)", value: v)) }
        if let v = lean?.pinFront        { rows.append(IdentityFieldRow(key: "pin (front)",         value: v)) }
        if let v = lean?.mrzDocNumber    { rows.append(IdentityFieldRow(key: "mrz_doc_number",      value: v)) }
        if let v = lean?.mrzPin          { rows.append(IdentityFieldRow(key: "mrz_pin",             value: v)) }
        if let v = lean?.mrzFull         { rows.append(IdentityFieldRow(key: "mrz_full",            value: v)) }
        if let verdict = identity?.sameDocument.verdict {
            rows.append(IdentityFieldRow(key: "same_document", value: verdict.rawValue))
        }
        return rows
    }
}

/**
 Single error row with left-edge colour bar.
 Android parity: `ErrorRow` helper in MainActivity.kt.
 */
struct ErrorRow: View {
    let code:     String
    let message:  String
    let severity: String

    init(code: String, message: String, severity: String) {
        self.code     = code
        self.message  = message
        self.severity = severity
    }

    private var barColor: Color {
        switch severity.uppercased() {
        case "ERROR":     return DocColors.failed
        case "RETRYABLE": return DocColors.failedFront
        default:          return DocColors.unknown
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(barColor)
                .frame(width: 4, height: 40)

            VStack(alignment: .leading, spacing: 0) {
                Text(message.isEmpty ? code : message)
                    .font(.system(size: 13, weight: .medium))
                if !message.isEmpty {
                    Text(code)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Extract top-level "status" + "message_ru" from finalJson.
/// Returns `(.unknown, nil)` on parse failure.
func parseTopLevelStatus(_ finalJson: String?) -> (VerifyStatus, String?) {
    guard let finalJson = finalJson,
          let data = finalJson.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return (.unknown, nil) }

    let statusStr = root["status"]     as? String ?? "UNKNOWN"
    let messageRu = root["message_ru"] as? String
    return (VerifyStatus.fromString(statusStr), messageRu?.isEmpty == false ? messageRu : nil)
}

/// Extract a string value from a JSON string by key (no full parse overhead for simple cases).
private func extractString(_ json: String, _ key: String) -> String? {
    guard let data = json.data(using: .utf8),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    return (root[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
}

// ─────────────────────────────────────────────────────────────────────────────
// MergenResultView — self-contained full-screen result screen
//
// Drop-in replacement for the old TwoSidedResultView. Driven purely by VerifyResult
// from Mergen.verify(). Includes the NavigationStack, ScrollView, and top bar so
// the caller only needs: .fullScreenCover { MergenResultView(result: r) { dismiss() } }
//
// Android parity: CameraResultScreen in MainActivity.kt
// ─────────────────────────────────────────────────────────────────────────────

/**
 Full-screen document-style result screen driven by `VerifyResult`.

 Assembles `VerifyHeadlineCard`, `DocStatusStamp`, `DocumentHeroCard`, `BackDocumentCard`,
 `SameDocSeal`, `AllFieldsTable`, and `CollapsibleOcrProd` in a single `ScrollView`
 with a sticky top bar. Mirrors `CameraResultScreen` in Android's `MainActivity.kt`.

 Usage:
 ```swift
 .fullScreenCover(isPresented: $showResult) {
     MergenResultView(result: verifyResult, title: "Mergen.verify()") {
         showResult = false
     }
 }
 ```

 - Note: **Deprecated since v2.1.** Copy `SampleResultView` from MergenSampleiOS into your
         app for the v3.0-compatible, client-owned result screen. See `docs/dev/migration-v3.md`.
 */
@available(*, deprecated, message: "Moves to your app in v3.0 — copy the reference implementation from MergenSampleiOS (SampleResultView.swift); see docs/dev/migration-v3.md")
public struct MergenResultView: View {
    public let result:    VerifyResult
    public let title:     String
    public let onDismiss: () -> Void

    public init(
        result:    VerifyResult,
        title:     String     = "Mergen.verify()",
        onDismiss: @escaping () -> Void
    ) {
        self.result    = result
        self.title     = title
        self.onDismiss = onDismiss
    }

    public var body: some View {
        if #available(iOS 16, *) {
            NavigationStack {
                ScrollView {
                    MergenCameraResultView(result: result)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Готово", action: onDismiss)
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { onDismiss() } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
            }
        } else {
            NavigationView {
                ScrollView {
                    MergenCameraResultView(result: result)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Готово", action: onDismiss)
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { onDismiss() } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
    }
}

/**
 Full-screen result screen driven by a `FusedIdentity` + raw `MergenIdResult`
 (gallery flow). Mirrors `GalleryResultScreen` in Android's `MainActivity.kt`.

 Usage:
 ```swift
 MergenGalleryResultFullView(identity: identity, raw: rawResult, title: "Галерея") {
     dismiss()
 }
 ```
 */
struct MergenGalleryResultFullView: View {
    let identity:  FusedIdentity?
    let raw:       MergenIdResult
    let title:     String
    let onDismiss: () -> Void

    init(
        identity:  FusedIdentity?,
        raw:       MergenIdResult,
        title:     String     = "Результат — Галерея",
        onDismiss: @escaping () -> Void
    ) {
        self.identity  = identity
        self.raw       = raw
        self.title     = title
        self.onDismiss = onDismiss
    }

    var body: some View {
        if #available(iOS 16, *) {
            NavigationStack {
                ScrollView {
                    MergenGalleryResultView(identity: identity, raw: raw)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Готово", action: onDismiss)
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { onDismiss() } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
            }
        } else {
            NavigationView {
                ScrollView {
                    MergenGalleryResultView(identity: identity, raw: raw)
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Готово", action: onDismiss)
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { onDismiss() } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
    }
}
