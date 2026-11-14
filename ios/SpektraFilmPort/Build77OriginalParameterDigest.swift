import Foundation

/// Build77/03 — literal source-order digest of Python
/// runtime/params_builder.py on a JSON-compatible scalar parameter subtree.
/// This adapter does NOT become active in photo processing automatically:
/// wiring source defaults and every UI toggle requires a separate device gate.
///
/// Independent upstream Python fixtures test all 360 source configurations.
/// Missing fields are errors: never synthesize a source default or ignore it.
enum Build77OriginalParameterDigest {
    enum DigestError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    private static func value(_ root: [String: Any], at key: String) throws -> Any {
        let segments = key.split(separator: ".").map(String.init)
        var v: Any = root
        for segment in segments {
            guard let dict = v as? [String: Any],
                  let next = dict[segment] else {
                throw DigestError.invalid("Missing Python source parameter: " + key)
            }
            v = next
        }
        return v
    }

    private static func flag(_ root: [String: Any], _ key: String) throws -> Bool {
        guard let v = try value(root, at: key) as? NSNumber,
              CFGetTypeID(v) == CFBooleanGetTypeID() else {
            throw DigestError.invalid("Expected source Boolean: " + key)
        }
        return v.boolValue
    }

    private static func string(_ root: [String: Any], _ key: String) throws -> String {
        guard let v = try value(root, at: key) as? String else {
            throw DigestError.invalid("Expected source string: " + key)
        }
        return v
    }

    private static func set(
        _ root: inout [String: Any], _ key: String, _ replacement: Any
    ) throws {
        let components = key.split(separator: ".").map(String.init)
        guard !components.isEmpty else {
            throw DigestError.invalid("Empty source parameter path")
        }
        try set(&root, components: ArraySlice(components), value: replacement)
    }

    private static func set(
        _ target: inout [String: Any],
        components: ArraySlice<String>, value: Any
    ) throws {
        guard let head = components.first, target[head] != nil else {
            throw DigestError.invalid("Missing source digest field: "
                                      + components.joined(separator: "."))
        }
        if components.count == 1 {
            target[head] = value
            return
        }
        guard var child = target[head] as? [String: Any] else {
            throw DigestError.invalid("Malformed nested parameter: " + head)
        }
        try set(&child, components: components.dropFirst(), value: value)
        target[head] = child
    }

    private static func setAll(
        _ root: inout [String: Any], _ mutations: [(String, Any)]
    ) throws {
        for (key, val) in mutations {
            try set(&root, key, val)
        }
    }

    /// RuntimePhotoParams changes only, in exact Python params_builder order:
    /// neutral DB => preview => film-specifics => LUT => spatial => stochastic.
    static func digest(
        _ input: [String: Any],
        filmInfo: [String: Any],
        paperInfo: [String: Any],
        neutralDatabase: [String: Any],
        applyStockSpecifics: Bool = true
    ) throws -> [String: Any] {
        var result = input
        let film = try string(filmInfo, "stock")
        let filmType = try string(filmInfo, "type")
        let filmSupport = try string(filmInfo, "support")
        let filmUse = try string(filmInfo, "use")
        let filmAH = try string(filmInfo, "antihalation")
        let paper = try string(paperInfo, "stock")
        let illum = try string(result, "enlarger.illuminant")

        // Upstream apply_database_neutral_print_filters; when missing, the
        // source prints a warning and leaves original defaults unchanged.
        if try flag(result, "settings.neutral_print_filters_from_database"),
           let forPaper = neutralDatabase[paper] as? [String: Any],
           let forIlluminant = forPaper[illum] as? [String: Any],
           let row = forIlluminant[film] as? [Any] {
            guard row.count == 3,
                  let c = row[0] as? NSNumber,
                  let m = row[1] as? NSNumber,
                  let y = row[2] as? NSNumber else {
                throw DigestError.invalid("Original neutral filter row malformed: "
                                          + paper + "/" + illum + "/" + film)
            }
            try setAll(&result, [
                ("enlarger.c_filter_neutral", c.doubleValue),
                ("enlarger.m_filter_neutral", m.doubleValue),
                ("enlarger.y_filter_neutral", y.doubleValue),
            ])
        }

        if try flag(result, "settings.preview_mode") {
            try setAll(&result, [
                ("enlarger.lens_blur", 0.0),
                ("film_render.dir_couplers.diffusion_size_um", 0.0),
                ("film_render.grain.active", false),
                ("film_render.grain.particle_area_um2", 0.0),
                ("film_render.grain.blur", 0.0),
                ("print_render.glare.blur", 0.0),
                ("camera.lens_blur_um", 0.0),
                ("scanner.lens_blur", 0.0),
                ("scanner.unsharp_mask", [0.0, 0.0]),
            ])
        }

        if applyStockSpecifics {
            if filmType == "positive" {
                try setAll(&result, [
                    ("film_render.dir_couplers.gamma_samelayer_rgb", [0.12, 0.08, 0.06]),
                    ("film_render.dir_couplers.gamma_interlayer_r_to_gb", [0.12, 0.06]),
                    ("film_render.dir_couplers.gamma_interlayer_g_to_rb", [0.08, 0.06]),
                    ("film_render.dir_couplers.gamma_interlayer_b_to_rg", [0.06, 0.06]),
                ])
            }
            if filmType == "negative" {
                try setAll(&result, [
                    ("film_render.dir_couplers.gamma_samelayer_rgb", [0.336, 0.319, 0.273]),
                    ("film_render.dir_couplers.gamma_interlayer_r_to_gb", [0.353, 0.302]),
                    ("film_render.dir_couplers.gamma_interlayer_g_to_rb", [0.154, 0.353]),
                    ("film_render.dir_couplers.gamma_interlayer_b_to_rg", [0.168, 0.226]),
                ])
            }
            // Original _apply_halation_preset: metadata keyed by use and AH.
            if filmSupport == "film",
               (filmUse == "still" || filmUse == "cine"),
               (filmAH == "strong" || filmAH == "weak" || filmAH == "no") {
                let sigma = filmUse == "still" ? 65.0 : 50.0
                let strength: [Double]
                switch filmAH {
                case "strong": strength = [0.015, 0.005, 0.0]
                case "weak": strength = [0.08, 0.02, 0.0]
                default: strength = [0.30, 0.10, 0.015]
                }
                try setAll(&result, [
                    ("film_render.halation.halation_first_sigma_um",
                     [sigma, sigma, sigma]),
                    ("film_render.halation.halation_strength", strength),
                ])
            }
            if film == "fujifilm_velvia_100" {
                try setAll(&result, [
                    ("film_render.dir_couplers.gamma_samelayer_rgb", [0.108, 0.072, 0.054]),
                    ("film_render.dir_couplers.gamma_interlayer_r_to_gb", [0.108, 0.054]),
                    ("film_render.dir_couplers.gamma_interlayer_g_to_rb", [0.072, 0.054]),
                    ("film_render.dir_couplers.gamma_interlayer_b_to_rg", [0.054, 0.054]),
                ])
            }
            if film == "fujifilm_provia_100f" {
                try setAll(&result, [
                    ("film_render.dir_couplers.gamma_samelayer_rgb", [0.156, 0.104, 0.078]),
                    ("film_render.dir_couplers.gamma_interlayer_r_to_gb", [0.156, 0.078]),
                    ("film_render.dir_couplers.gamma_interlayer_g_to_rb", [0.104, 0.078]),
                    ("film_render.dir_couplers.gamma_interlayer_b_to_rg", [0.078, 0.078]),
                ])
            }
        }

        if try flag(result, "debug.lut_mode") {
            try setAll(&result, [
                ("debug.deactivate_spatial_effects", true),
                ("debug.deactivate_stochastic_effects", true),
                ("camera.auto_exposure", false),
                ("camera.exposure_compensation_ev", 0.0),
                ("enlarger.print_exposure_compensation", false),
                ("enlarger.print_exposure", 1.0),
                ("film_render.halation.boost_ev", 0.0),
                ("scanner.white_correction", false),
                ("scanner.black_correction", false),
                ("scanner.unsharp_mask", [0.0, 0.0]),
            ])
        }

        if try flag(result, "debug.deactivate_spatial_effects") {
            try setAll(&result, [
                ("film_render.halation.active", false),
                ("film_render.halation.scatter_core_um", [0.0, 0.0, 0.0]),
                ("film_render.halation.scatter_tail_um", [0.0, 0.0, 0.0]),
                ("film_render.halation.halation_first_sigma_um", [0.0, 0.0, 0.0]),
                ("film_render.dir_couplers.diffusion_size_um", 0),
                ("film_render.grain.blur", 0.0),
                ("film_render.grain.blur_dye_clouds_um", 0.0),
                ("print_render.glare.blur", 0),
                ("camera.lens_blur_um", 0.0),
                ("enlarger.lens_blur", 0.0),
                ("enlarger.diffusion_filter.active", false),
                ("camera.diffusion_filter.active", false),
                ("scanner.lens_blur", 0.0),
                ("scanner.unsharp_mask", [0.0, 0.0]),
            ])
        }
        if try flag(result, "debug.deactivate_stochastic_effects") {
            try setAll(&result, [
                ("film_render.grain.active", false),
                ("print_render.glare.active", false),
            ])
        }
        return result
    }
}
