#!/usr/bin/env python3
"""Generate TRUE ORIGINAL Python whole-frame nonlinear optics / spatial DIR.

This is NOT a Swift self-reference: upstream SpektraFilm actual Hanatos
functions and 2D film/coupler/spectral/print functions are executed. Source
measured Float64 datasets are loaded untouched, not quantized to Float32.
Fixtures exclude RAW, halation, random grain and default CAM16 (use source
documented ACES option). The exact physical scope is explicit in manifest.
"""
import hashlib
import json
from pathlib import Path

import colour
import numpy as np

from generate_source_full_frame import rgb_source, png_rgb8
from generate_source_film_dir_print_chain import (
    ROOT, FILES, upstream_film, negative_params, load_original_module,
)
from generate_source_camera_film_print_chain import (
    load_actual_source_hanatos, stock_float64_lut,
)
from generate_source_negative_print_chain import settings
from generate_original_optics import default_dichroic, kg3_filter
from generate_print_morph import DensityCurvesModel, apply_print_curves_morph
from generate_source_print_scanner_parity import source_scan_print

OUT = ROOT / "ios/verification/generated-physical-v1.8.22"
STAGES = ("logRaw", "initial", "inhibitors", "diffused",
          "correctedLog", "density", "printed")
CASES = (
    ("kodak_neutral_fir", "kodak_portra_400", "kodak_portra_endura",
     "neutral", 19, 13, 12.0, 0.0, 0.0, 0.0, 0.0, (0., 0., 0.), 0.0),
    ("fujifilm_2383_iir", "fujifilm_pro_400h", "kodak_2383",
     "gamma_082", 31, 17, 4.0, 0.5, -1.0, 0.02, 9.0, (-8., 12., 7.), 0.0),
    ("kodak_endura_morph", "kodak_portra_400", "kodak_portra_endura",
     "exhaustion_04", 47, 31, 9.0, -0.5, 1.0, 0.04, -12.0, (6., -9., 11.), -8.0),
)


def store(base, name, values):
    values = np.asarray(values, dtype="<f8")
    assert np.isfinite(values).all(), (name, "Nonfinite original Python stage")
    payload = np.ascontiguousarray(values).tobytes(order="C")
    (base / name).write_bytes(payload)
    return hashlib.sha256(payload).hexdigest()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    density, couplers, params_cls = upstream_film()
    filtering = load_original_module(
        "spektrafilm.utils.fast_gaussian_filter",
        ROOT / "src/spektrafilm/utils/fast_gaussian_filter.py",
    )
    # Source couplers import these functions by name when loaded; bind
    # the ACTUAL upstream functions to that module, not test approximations.
    couplers.fast_gaussian_filter = filtering.fast_gaussian_filter
    couplers.fast_exponential_filter = filtering.fast_exponential_filter
    raw_hanatos = load_actual_source_hanatos()

    original_source = np.asarray(
        colour.colorimetry.blackbody_spectral_radiance(
            np.arange(380, 781, 5, dtype=np.float64) * 1e-9, 3400
        ) * kg3_filter(), dtype=np.float64,
    )
    original_source /= original_source.mean()
    filters = json.loads(
        (ROOT / "src/spektrafilm/data/filters/neutral_print_filters.json"
         ).read_text(encoding="utf-8")
    )
    manifest = {
        "scope": "original-source-nonlinear-hanatos-spatial-dir-paper-aces-8bit",
        "source_modules": [
            "src/spektrafilm/utils/spectral_upsampling.py",
            "src/spektrafilm/model/density_curves.py",
            "src/spektrafilm/model/couplers.py",
            "src/spektrafilm/utils/fast_gaussian_filter.py",
            "src/spektrafilm/runtime/stages/printing.py",
            "src/spektrafilm/runtime/stages/scanning.py",
        ],
        "cases": [],
    }

    cache = {}
    for (name, film, paper, morph, width, height, pixel_um, camera_ev,
         paper_ev, flash, flash_m, shift, flash_y) in CASES:
        assert width * height <= 2000000
        encoded = rgb_source(height, width)
        png = png_rgb8(encoded)
        (OUT / (name + ".png")).write_bytes(png)
        rgb = encoded.astype(np.float64) / 255.0
        linear = colour.cctf_decoding(rgb, function="sRGB")
        if film not in cache:
            cache[film] = stock_float64_lut(film)
        lut, sensitivity, info = cache[film]
        source_raw = raw_hanatos(
            linear, sensitivity, color_space="sRGB",
            apply_cctf_decoding=False,
            reference_illuminant=info["reference_illuminant"],
            tc_lut=lut,
        )
        log_raw = np.log10(np.fmax(source_raw * 2.0**camera_ev, 0.0) + 1e-10)
        film_data = json.loads((FILES / (film + ".json")).read_text())["data"]
        film_axis = np.asarray(film_data["log_exposure"], dtype=np.float64)
        measured = np.asarray(film_data["density_curves"], dtype=np.float64)
        curves = measured - np.nanmin(measured, axis=0)
        params = negative_params(params_cls)
        params.diffusion_size_um = 20.0
        params.diffusion_tail_um = 200.0
        params.diffusion_tail_weight = 0.06
        matrix = couplers.compute_dir_couplers_matrix(params) * params.amount
        initial = density.interpolate_exposure_to_density(
            log_raw, curves, film_axis, gamma_factor=1.0
        )
        maximum = np.nanmax(curves, axis=0)
        inhibitors = np.einsum("ijk,km->ijm", initial, matrix)
        corrected_log = couplers.compute_exposure_correction_dir_couplers(
            log_raw, initial, maximum, matrix,
            20.0 / pixel_um, 200.0 / pixel_um, 0.06, positive=False
        )
        developed = couplers.apply_density_correction_dir_couplers(
            initial.copy(), log_raw, pixel_um,
            film_axis, curves, params, "negative", gamma_factor=1.0
        )
        assert np.isfinite(developed).all()
        diffused = log_raw - corrected_log
        # Independent original pre-DIR density curve calculation.
        precurve = couplers.compute_density_curves_before_dir_couplers(
            curves, film_axis, matrix, positive=False
        )
        direct = density.interpolate_exposure_to_density(
            corrected_log, precurve, film_axis, gamma_factor=1.0
        )
        assert np.max(np.abs(direct - developed)) < 1e-10

        paper_doc = json.loads((FILES / (paper + ".json")).read_text())
        paper_data = paper_doc["data"]
        paper_axis = np.asarray(paper_data["log_exposure"], dtype=np.float64)
        model = paper_data["density_curves_model"]
        paper_curves = apply_print_curves_morph(
            paper_axis,
            DensityCurvesModel(model["model_type"],
                               model["centers"], model["amplitudes"],
                               model["sigmas"]),
            settings(morph), profile_type=paper_doc["info"]["type"]
        )
        film_base = np.asarray(film_data["base_density"], dtype=np.float64)
        dyes = np.asarray(film_data["channel_density"], dtype=np.float64)
        paper_sensitivity = np.nan_to_num(
            10**np.asarray(paper_data["log_sensitivity"], dtype=np.float64)
        )
        default_cc = np.asarray(
            filters.get(paper, {}).get("TH-KG3", {}).get(film, [0, 65, 55]),
            dtype=np.float64
        )
        light = original_source * default_dichroic(default_cc + np.asarray(shift))
        flash_light = original_source * default_dichroic(
            default_cc + [0, flash_m, flash_y]
        )
        preflash = flash * np.einsum(
            "l,lc->c",
            np.nan_to_num(10**(-film_base) * flash_light, nan=0.0),
            paper_sensitivity
        )
        # Original spectral density -> transmission. NaN at any source
        # wavelength means ZERO transmitted light, never no dye.
        total_density = film_base[None,None,:] + np.einsum(
            "hwc,lc->hwl", developed, dyes
        )
        trans = np.nan_to_num(10**(-total_density), nan=0.0)
        print_raw = np.einsum(
            "hwl,lc,l->hwc", trans, paper_sensitivity, light
        )
        print_log = np.log10(
            np.maximum((np.maximum(print_raw + preflash, 0.0) + 1e-10)
                       * 2**paper_ev, 0.0) + 1e-10
        )
        paper_density = np.stack(
            [np.interp(print_log[:, :, c], paper_axis, paper_curves[:, c])
             for c in range(3)], axis=-1
        )
        _, _, _, encoded_output = source_scan_print(
            paper_doc, paper_density.reshape(-1,3)
        )
        printed = np.clip(
            encoded_output.reshape(height, width, 3), 0.0, 1.0
        )
        stages = {
            "logRaw": log_raw, "initial": initial,
            "inhibitors": inhibitors, "diffused": diffused,
            "correctedLog": corrected_log, "density": developed,
            "printed": printed
        }
        hashes = {"png": hashlib.sha256(png).hexdigest()}
        for stage in STAGES:
            hashes[stage] = store(
                OUT, name + "." + stage + ".f64le", stages[stage]
            )
        manifest["cases"].append({
            "name": name, "film": film, "paper": paper, "morph": morph,
            "width": width, "height": height, "pixelUM": pixel_um,
            "cameraEV": camera_ev, "paperEV": paper_ev,
            "flash": flash, "flashM": flash_m, "flashY": flash_y,
            "shift": list(shift), "sha256": hashes,
        })
        print(
            f"PASS original upstream physical source {name}: "
            f"{width}x{height}, original Hanatos→H-D→real spatial FIR/YVV"
            "→source paper CDF→XYZ/ACES RGB, 7 stages", flush=True
        )
    (OUT/"manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True)+"\n",
        encoding="utf-8"
    )
    print("PASS: original upstream nonlinear 2D whole-image references generated")


if __name__ == "__main__":
    main()
