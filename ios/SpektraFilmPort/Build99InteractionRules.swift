import Foundation

/// Build99: deterministic, platform-independent UI interaction rules.
/// Original film / paper / grain numerical algorithms are not modified.
enum Build99InteractionRules {
    static func nextPhotoScale(_ value: Double) -> Double {
        value.isFinite && value > 1.0 ? 1.0 : 2.0
    }

    static func compareDivider(x: Double, width: Double) -> Double {
        guard x.isFinite, width.isFinite, width > 0 else { return 0.5 }
        return min(0.98, max(0.02, x / width))
    }

    /// Only the latest submitted optical result may be applied to UI.
    static func acceptsPreview(generation: Int, current: Int) -> Bool {
        generation == current
    }

    /// The selected film/paper cannot be exported while its LUT is old
    /// or a new spectral request has failed.
    static func canExport(pendingSelectedMaterial: Bool) -> Bool {
        !pendingSelectedMaterial
    }
}
