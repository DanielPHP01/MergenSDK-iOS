import Foundation
import os
import CoreGraphics
import UIKit
import Mergen

// ─────────────────────────────────────────────────────────────────────────────
// MergenDebugger — PII diagnostics implementation for QA / field debugging
// ─────────────────────────────────────────────────────────────────────────────
//
// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  MERGEN PII DIAGNOSTICS MODULE                                           ║
// ║                                                                          ║
// ║  This product writes document numbers, personal numbers (ПИН), MRZ,    ║
// ║  names and other END-USER personal data to os_log (unified log).        ║
// ║                                                                          ║
// ║  Activation requires explicit `MergenDebugger.install()` in your code.     ║
// ║  NEVER ship a build containing this module to end users.                 ║
// ║                                                                          ║
// ║  Recommended usage: add MergenDebugger only to a separate QA Xcode target. ║
// ║  See: docs/DIAGNOSTICS.md                                                ║
// ╚══════════════════════════════════════════════════════════════════════════╝
//
// See ADR-0003: docs/adr/0003-pluggable-pii-diagnostics-module.md
// ─────────────────────────────────────────────────────────────────────────────

// ── Public entry point ───────────────────────────────────────────────────────

/// Entry point for the MergenDebugger diagnostics module.
///
/// Call `install()` once — typically in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`
/// wrapped in `#if DEBUG` — to activate full PII diagnostics:
///
/// ```swift
/// #if DEBUG
/// import MergenDebugger
/// MergenDebugger.install()
/// #endif
/// ```
///
/// - Warning: All scan results will emit document numbers, ПИН, MRZ and names to
///   `os_log` (visible in Console.app on a paired Mac, sysdiagnose bundles, etc.).
///   Never activate this in a build distributed to end users.
public enum MergenDebugger {

    /// Register the default `OSLogDiagnosticsSink`. Prints a loud banner to `os_log`
    /// at `.fault` level (visible without any log profile, in Console.app and Xcode console).
    ///
    /// Calling this more than once replaces the previously registered sink.
    public static func install() {
        let sink = OSLogDiagnosticsSink()
        MergenDiagnostics.install(sink)
        sink.printActivationBanner()
    }

    /// Register a custom sink. Useful for routing diagnostics to a QA backend.
    /// - Parameter sink: Your custom `MergenDiagnosticsSink` implementation.
    public static func install(customSink: any MergenDiagnosticsSink) {
        MergenDiagnostics.install(customSink)
    }

    /// Unregister the current sink. Diagnostics immediately become no-ops.
    public static func uninstall() {
        MergenDiagnostics.uninstall()
    }
}

// ── OSLogDiagnosticsSink ─────────────────────────────────────────────────────

/// `MergenDiagnosticsSink` implementation that writes to `os_log` / unified log.
///
/// All output uses `privacy: .public` intentionally — the entire point of this
/// module is to make values visible for debugging. Do NOT use in production builds.
///
/// Thread-safe: `os_log` is thread-safe; this class adds no additional state.
public final class OSLogDiagnosticsSink: MergenDiagnosticsSink, @unchecked Sendable {

    // Subsystem matches the core SDK so all output appears in the same Console.app filter.
    private static let log     = Logger(subsystem: "com.mergen.debug", category: "diagnostics")
    private static let scanLog = Logger(subsystem: "com.mergen.debug", category: "scan-result")
    private static let ocrLog  = Logger(subsystem: "com.mergen.debug", category: "ocr")

    public init() {}

    // Called once from MergenDebugger.install().
    func printActivationBanner() {
        let log = Logger(subsystem: "com.mergen.debug", category: "banner")
        // .fault — highest severity, always visible in Console.app without any profile.
        log.fault("""
        ╔══════════════════════════════════════════════════════════════════════════╗
        ║  MERGEN PII DIAGNOSTICS ACTIVE                                           ║
        ║  Document number, personal number (ПИН), MRZ, names and card images of  ║
        ║  the END USER are being written to os_log (unified log).                 ║
        ║  This build MUST NOT be distributed to end users.                        ║
        ║  Deactivate: MergenDebugger.uninstall() or remove MergenDebugger from target.  ║
        ╚══════════════════════════════════════════════════════════════════════════╝
        """)
    }

    // ── MergenDiagnosticsSink ────────────────────────────────────────────────

    public func onOcrLines(pass: DiagOcrPass, label: String?,
                           imageWidth: Int, imageHeight: Int,
                           lines: [DiagOcrLine]) {
        let passTag = pass.rawValue
        let labelTag = label.map { "[\($0)] " } ?? ""
        Self.ocrLog.debug("[diag/\(passTag, privacy: .public)] \(labelTag, privacy: .public)img=\(imageWidth, privacy: .public)x\(imageHeight, privacy: .public) lines=\(lines.count, privacy: .public)")
        for line in lines {
            let bb = line.boundingBox
            Self.ocrLog.debug(
                "[diag/\(passTag, privacy: .public)] \(labelTag, privacy: .public)[\(line.index, privacy: .public)] " +
                "text=\(line.text, privacy: .public) conf=\(String(format: "%.3f", line.confidence), privacy: .public) " +
                "bbox=x\(String(format: "%.3f", bb.minX), privacy: .public) y\(String(format: "%.3f", bb.minY), privacy: .public) " +
                "w\(String(format: "%.3f", bb.width), privacy: .public) h\(String(format: "%.3f", bb.height), privacy: .public)"
            )
        }
    }

    public func onOcrText(pass: DiagOcrPass, label: String?, text: String) {
        let passTag = pass.rawValue
        let labelTag = label.map { "[\($0)] " } ?? ""
        Self.ocrLog.debug("[diag/\(passTag, privacy: .public)] \(labelTag, privacy: .public)text=\(text, privacy: .public)")
    }

    public func onFieldsResolved(pass: DiagOcrPass, fields: [String: String]) {
        let passTag = pass.rawValue
        Self.ocrLog.debug("[diag/\(passTag, privacy: .public)] fields-resolved count=\(fields.count, privacy: .public)")
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            Self.ocrLog.debug("[diag/\(passTag, privacy: .public)] \(k, privacy: .public)=\(v, privacy: .public)")
        }
    }

    public func onExternalOcrPayload(source: DiagPayloadSource, json: String) {
        Self.ocrLog.debug("[diag/external-ocr] source=\(source.rawValue, privacy: .public) json=\(json, privacy: .public)")
    }

    public func onBarcodeDecoded(rawValues: [String], docNumber: String?, personalNumber: String?) {
        Self.ocrLog.debug(
            "[diag/barcode] raw=[\(rawValues.joined(separator: ","), privacy: .public)] " +
            "doc=\(docNumber ?? "nil", privacy: .public) " +
            "pin=\(personalNumber ?? "nil", privacy: .public)"
        )
    }

    public func onScanResult(_ result: MergenIdResult) {
        let confStr = String(format: "%.3f", result.confidence)
        Self.scanLog.debug(
            "[diag/scan-result] version=\(result.cardVersion.rawValue, privacy: .public) " +
            "flipped=\(result.isFlipped, privacy: .public) " +
            "conf=\(confStr, privacy: .public) " +
            "success=\(result.success, privacy: .public)"
        )
        if let ocr = result.ocrResult {
            Self.scanLog.debug("[diag/scan-result/ocr] last_name=\(ocr.lastName ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] first_name=\(ocr.firstName ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] patronymic=\(ocr.patronymic ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] gender=\(ocr.gender ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] nationality=\(ocr.nationality ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] birth_date=\(ocr.birthDate ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] doc_number=\(ocr.docNumber ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] expiry_date=\(ocr.expiryDate ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] birth_place=\(ocr.birthPlace ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] issued_by=\(ocr.issuedBy ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] issue_date=\(ocr.issueDate ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] personal_number=\(ocr.personalNumber ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] mrz_line1=\(ocr.mrzLine1 ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] mrz_line2=\(ocr.mrzLine2 ?? "nil", privacy: .public)")
            Self.scanLog.debug("[diag/scan-result/ocr] mrz_line3=\(ocr.mrzLine3 ?? "nil", privacy: .public)")
        }
        if let finalJson = result.finalJson {
            Self.scanLog.debug("[diag/scan-result] finalJson=\(String(finalJson.prefix(1000)), privacy: .public)")
        }
    }

    public func onVerifyResult(finalJson: String?, sideResultJson: String?) {
        Self.scanLog.debug("[diag/verify-result] finalJson=\(finalJson?.prefix(500).description ?? "nil", privacy: .public)")
        Self.scanLog.debug("[diag/verify-result] sideJson=\(sideResultJson?.prefix(500).description ?? "nil", privacy: .public)")
    }
}
