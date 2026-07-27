import Foundation
import SwiftUI
import PhotosUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MergenHelpers — convenience utilities distributed with the SDK so client apps
// do not need to rewrite bundle-loading or PHPicker boilerplate.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - License loading

public extension Mergen {

    /// Loads a license JSON file from a bundle.
    ///
    /// Reads `<named>.json` from `bundle` (defaults to `Bundle.main`), trims
    /// whitespace, and returns `nil` when the file is absent or empty.
    ///
    /// Typical usage in `App.init`:
    /// ```swift
    /// if let license = Mergen.loadLicense() {
    ///     Mergen.warmUp(license: license)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - named:  Base name of the JSON file (without extension). Default: `"license"`.
    ///   - bundle: Bundle to search. Default: `Bundle.main`.
    /// - Returns: License JSON string, or `nil` when absent / unreadable / empty.
    static func loadLicense(named: String = "license", in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: named, withExtension: "json") else {
            return nil
        }
        guard let json = try? String(contentsOf: url, encoding: .utf8),
              !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return json
    }
}

// MARK: - Photo picker

/// A SwiftUI `UIViewControllerRepresentable` wrapping `PHPickerViewController`
/// for selecting a single image from the photo library.
///
/// Clients can use this in `.sheet` presentations to let the user pick a photo
/// without writing PHPicker boilerplate:
/// ```swift
/// .sheet(isPresented: $showPicker) {
///     MergenPhotoPicker { image in
///         showPicker = false
///         if let image { handleImage(image) }
///     }
/// }
/// ```
///
/// `onPicked` is called on the **main thread** with the selected `UIImage`, or
/// `nil` when the user cancels.  The picker does **not** dismiss itself — the
/// caller is responsible for toggling the presentation binding in `onPicked`.
///
/// ### Notes on `.sheet(item:)` usage
/// When driving presentation with `sheet(item:)`, do **not** call
/// `picker.dismiss(animated:)` inside the delegate — SwiftUI owns the sheet
/// lifecycle.  Clear the bound item in `onPicked` instead.
public struct MergenPhotoPicker: UIViewControllerRepresentable {

    /// Called on the main thread when the user selects an image, or with `nil` on cancel.
    public let onPicked: (UIImage?) -> Void

    public init(onPicked: @escaping (UIImage?) -> Void) {
        self.onPicked = onPicked
    }

    public func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter         = .images
        configuration.selectionLimit = 1
        let vc = PHPickerViewController(configuration: configuration)
        vc.delegate = context.coordinator
        return vc
    }

    public func updateUIViewController(_ uiViewController: PHPickerViewController,
                                       context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    // ── Coordinator ───────────────────────────────────────────────

    public final class Coordinator: NSObject, PHPickerViewControllerDelegate {

        private let onPicked: (UIImage?) -> Void

        public init(onPicked: @escaping (UIImage?) -> Void) {
            self.onPicked = onPicked
        }

        public func picker(_ picker: PHPickerViewController,
                           didFinishPicking results: [PHPickerResult]) {
            // Capture the callback before the coordinator may be deallocated when
            // the sheet dismisses (loadObject completes asynchronously; a [weak self]
            // capture would be nil by that time, silently dropping the result).
            //
            // NOTE: do NOT call picker.dismiss() here when used with .sheet(item:).
            // SwiftUI owns the presentation lifecycle; calling dismiss() while the
            // binding still holds the item causes the sheet to re-present immediately.
            // The caller should instead clear the binding in onPicked.
            let cb = onPicked
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                cb(nil)
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                DispatchQueue.main.async { cb(object as? UIImage) }
            }
        }
    }
}
