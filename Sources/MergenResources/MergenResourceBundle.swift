import Foundation

/// Exposes the SPM-generated `Bundle.module` for the Mergen SDK model assets.
///
/// This source-only shim exists because binary xcframework targets cannot synthesise
/// `Bundle.module` (that accessor is generated only for SPM source targets). Declaring
/// a companion source target (`MergenResources`) with the model files as resources lets
/// SPM create a single platform-independent bundle — eliminating the ~147 MB duplication
/// that results from embedding the same 73 MB of models in each xcframework slice.
///
/// At runtime `MergenEngine.findResourceBundle()` locates this bundle automatically via
/// `Bundle.allBundles` + a main-bundle sub-bundle search. Clients can also register it
/// explicitly via `MergenEngine.setResourceBundle(_:)` for unusual host configurations.
///
/// **Internal use only.** Not part of the public SDK API.
enum MergenResourceBundle {
    /// The bundle that holds the Mergen model assets (m4, m5, m7, m12–m15).
    static var bundle: Bundle { .module }
}
