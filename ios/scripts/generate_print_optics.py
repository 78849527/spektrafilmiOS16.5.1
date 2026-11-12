#!/usr/bin/env python3
"""Source NumPy/dichroic references for iOS v1.4 optical-printing parity.

Uses source 81-wavelength profiles and the original color_enlarger formula
(via generate_original_optics.default_dichroic) at Float64. Missing dye
channels are preserved as NaN until transmission and then suppressed, exactly
as PrintingStage's density_to_light does in upstream Python. Vectors test
CMY shifts, film-substrate transmission, preflash exposure and normalization
BEFORE paper development (not merely final RGB).
"""
import json
from pathlib import Path
import numpy as np
from generate_original_optics import ROOT, SHAPE, default_dichroic, illuminant, kg3_filter
import colour

DEST = ROOT / "ios/SpektraFilmPort/GeneratedPrintOpticsReference.swift"

def arr(values):
    return "[" + ", ".join(format(float(x), ".16g") for x in values) + "]"

def quoted(value):
    return json.dumps(value)

def exposure_raw(film_density, base, dyes, paper_sens, spectrum):
    # Original develop.compute_density_spectral / conversions.density_to_light:
    # NaN * 0 is still NaN; missing any dye channel invalidates that wavelength.
    spectral_density = base + dyes @ np.asarray(film_density, dtype=float)
    light = 10 ** (-spectral_density) * spectrum
    light[np.isnan(light)] = 0.0
    return np.einsum("l,lc->c", light, paper_sens)

def main():
    wl = np.arange(380, 781, 5, dtype=float)
    source = colour.colorimetry.blackbody_spectral_radiance(wl*1e-9, 3400) * kg3_filter()
    source = np.asarray(source, dtype=float)
    source /= np.mean(source)
    db = json.loads((ROOT / "src/spektrafilm/data/filters/neutral_print_filters.json").read_text())
    routes = [
        ("kodak_portra_400", "kodak_portra_endura", [0, 0, 0], 0.0, 0, 0, 0),
        ("kodak_portra_400", "kodak_portra_endura", [17, -23, 31], 0.025, 10, -8, 1),
        ("fujifilm_pro_400h", "kodak_2383", [-20, 14, -11], 0.08, -12, 24, -1),
        ("kodak_portra_400", "kodak_2383", [30, 40, -35], 0.12, 28, -21, 2),
        ("fujifilm_pro_400h", "kodak_portra_endura", [-12, 17, -8], 0.035, 0, 11, 0),
        ("kodak_portra_400", "kodak_portra_endura", [7, -10, 22], 0.045, 5, -13, -1)
    ]
    lines = [
        "// GENERATED source Float64 optical print exposure comparisons.",
        "// Source: PrintingStage / color_enlarger, using measured profile arrays.",
        "enum GeneratedPrintOpticsReference {",
        "    struct Vector {",
        "        let film: String",
        "        let paper: String",
        "        let shift: [Double]",
        "        let preflashExposure: Double",
        "        let preflashM: Double",
        "        let preflashY: Double",
        "        let ev: Double",
        "        let density: [Double]",
        "        let midgrayDensity: [Double]",
        "        let lightSamples: [Double]",
        "        let raw: [Double]",
        "        let preflash: [Double]",
        "        let reference: Double",
        "        let normalizationFactors: [Double]",
        "        let logExposure: [Double]",
        "    }",
        "    static let vectors: [Vector] = [",
    ]
    film_density = np.array([0.11, 0.52, 0.84])
    midgray_density = np.array([0.20, 0.45, 0.60])
    largest_legacy_error = 0.0
    for film, paper, shift, flash, flash_m, flash_y, ev in routes:
        film_data = json.loads((ROOT / "src/spektrafilm/data/profiles" / (film + ".json")).read_text())["data"]
        paper_data = json.loads((ROOT / "src/spektrafilm/data/profiles" / (paper + ".json")).read_text())["data"]
        # v1.8.11: retain original NaN absorbance; NumPy source turns its
        # transmitted light into ZERO, not clear film. Do not coerce to zero.
        base = np.asarray(film_data["base_density"], dtype=np.float64)
        dyes = np.asarray(film_data["channel_density"], dtype=np.float64)
        paper_sens = np.nan_to_num(10**np.asarray(paper_data["log_sensitivity"], dtype=float))
        neutral = np.asarray(db.get(paper, {}).get("TH-KG3", {}).get(film, [0,65,55]), dtype=float)
        print_light = source * default_dichroic(neutral + shift)
        flash_light = source * default_dichroic(neutral + [0,flash_m,flash_y])
        raw = exposure_raw(film_density, base, dyes, paper_sens, print_light)
        old_clear_film = exposure_raw(
            film_density, np.nan_to_num(base, nan=0.0),
            np.nan_to_num(dyes, nan=0.0), paper_sens, print_light
        )
        largest_legacy_error = max(
            largest_legacy_error, float(np.max(np.abs(old_clear_film - raw)))
        )
        middle = exposure_raw(midgray_density, base, dyes, paper_sens, print_light)
        reference = float(np.exp(np.mean(np.log(np.maximum(middle, 1e-10)))))
        # Independent four-branch Python reference from PrintingStage.
        comp_density = midgray_density + np.array([0.09, -0.05, 0.10])
        compensated = exposure_raw(comp_density, base, dyes, paper_sens, print_light)
        mid_factor = 1.0 / float(np.exp(np.mean(np.log(np.maximum(middle, 1e-10)))))
        comp_factor = 1.0 / float(np.exp(np.mean(np.log(np.maximum(compensated, 1e-10)))))
        # [none, normalize only, compensate only, both].
        normalization_factors = [
            1.0, mid_factor, comp_factor / mid_factor, comp_factor
        ]
        flash_transmission = flash_light * 10 ** (-base)
        flash_transmission[np.isnan(flash_transmission)] = 0.0
        flash_raw = flash * np.einsum("l,lc->c", flash_transmission, paper_sens)
        before_enlarger = np.maximum(raw / reference + flash_raw, 0) + 1e-10
        log_exposure = np.log10(np.maximum(before_enlarger * 2**ev, 0) + 1e-10)
        samples = print_light[[0, 17, 40, 64, 80]]
        for v in [*raw, *flash_raw, *log_exposure, reference, *samples, *normalization_factors]:
            assert np.isfinite(v)
        lines += [
            "        Vector(",
            f"            film: {quoted(film)}, paper: {quoted(paper)},",
            f"            shift: {arr(shift)}, preflashExposure: {flash},",
            f"            preflashM: {flash_m}, preflashY: {flash_y}, ev: {ev},",
            f"            density: {arr(film_density)},",
            f"            midgrayDensity: {arr(midgray_density)},",
            f"            lightSamples: {arr(samples)},",
            f"            raw: {arr(raw)},",
            f"            preflash: {arr(flash_raw)},",
            f"            reference: {reference:.16g},",
            f"            normalizationFactors: {arr(normalization_factors)},",
            f"            logExposure: {arr(log_exposure)}",
            "        ),",
        ]
    lines += ["    ]", "}"]
    DEST.write_text("\n".join(lines) + "\n")
    assert largest_legacy_error > 1e-5, (
        "No regression witness: old zero-absorbance semantics not detected"
    )
    print(f"PASS: Python SOURCE NaN-correct optical print vectors: {len(routes)} routes; "
          f"5 irradiance taps + raw/preflash/reference/logE; "
          f"old invalid-clear-film largest error={largest_legacy_error:.9g}")

if __name__ == "__main__":
    main()
