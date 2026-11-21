#!/usr/bin/env python3
"""Build77/03: execute upstream params_builder.digest_params as a frozen oracle.

The result is a REFERENCE contract, not proof that the iOS UI or rendering
pipeline uses all these settings. No upstream algorithm or defaults are edited.
"""
from __future__ import annotations

import argparse
import contextlib
import dataclasses
import hashlib
import io
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))
SOURCE_SHA = "3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"
SECTIONS = (
    "camera", "enlarger", "scanner", "film_render", "print_render",
    "io", "debug", "settings", "taps",
)
EXTRA_MODES = (
    "preview", "lut", "disable_spatial", "disable_stochastic",
    "preview_lut", "neutral_database_off", "without_stock_specifics",
    "debug_both", "nondefault_spatial", "nondefault_lut",
)


def require(ok: bool, why: str) -> None:
    if not ok:
        raise RuntimeError(why)


def snapshot(params) -> dict:
    # Do not deep-copy the two arrays-heavy material profiles.
    values = {key: dataclasses.asdict(getattr(params, key)) for key in SECTIONS}
    json.dumps(values, allow_nan=False)
    return values


def configure(params, mode: str) -> bool:
    apply_specifics = mode != "without_stock_specifics"
    if mode in ("preview", "preview_lut"):
        params.settings.preview_mode = True
    if mode in ("lut", "preview_lut", "nondefault_lut"):
        params.debug.lut_mode = True
    if mode in ("disable_spatial", "debug_both", "nondefault_spatial"):
        params.debug.deactivate_spatial_effects = True
    if mode in ("disable_stochastic", "debug_both"):
        params.debug.deactivate_stochastic_effects = True
    if mode == "neutral_database_off":
        params.settings.neutral_print_filters_from_database = False
    if mode.startswith("nondefault_"):
        # Deliberately non-default values reveal "set to zero/False" omissions.
        params.camera.lens_blur_um = 3.125
        params.enlarger.lens_blur = 2.5
        params.enlarger.diffusion_filter.active = True
        params.camera.diffusion_filter.active = True
        params.film_render.grain.blur = 1.75
        params.film_render.grain.blur_dye_clouds_um = 2.25
        params.film_render.dir_couplers.diffusion_size_um = 14.25
        params.print_render.glare.blur = 1.5
        params.scanner.lens_blur = 1.125
        params.scanner.unsharp_mask = (1.0, 2.0)
        params.camera.auto_exposure = True
        params.camera.exposure_compensation_ev = 2.0
        params.enlarger.print_exposure = 3.0
        params.enlarger.print_exposure_compensation = True
        params.scanner.white_correction = True
        params.scanner.black_correction = True
        params.film_render.halation.boost_ev = 1.0
        params.film_render.halation.active = True
        params.print_render.glare.active = True
        params.film_render.grain.active = True
    return apply_specifics


def generate() -> dict:
    from spektrafilm.runtime.params_builder import (
        _get_neutral_print_filters, digest_params, init_params,
    )
    catalog = sorted((ROOT / "src/spektrafilm/data/profiles").glob("*.json"))
    info = {p.stem: json.loads(p.read_text(encoding="utf-8"))["info"]
            for p in catalog}
    films = sorted(x for x in info if info[x]["stage"] == "filming")
    papers = sorted(x for x in info if info[x]["stage"] == "printing")
    require(len(films) == 20 and len(papers) == 8,
            "Original 20-film/8-print inventory drifted")
    neutral_db = _get_neutral_print_filters()
    require(isinstance(neutral_db, dict), "Original neutral filter database not mapping")

    cases = []
    pairs = [(film, paper, "base") for film in films for paper in papers]
    pairs.extend((film, "kodak_portra_endura", mode)
                 for film in films for mode in EXTRA_MODES)
    for film, paper, mode in pairs:
        params = init_params(film_profile=film, print_profile=paper)
        specifics = configure(params, mode)
        before = snapshot(params)
        # Source prints warnings for missing neutral filter rows; do not
        # change its semantics or add substitutes in this oracle.
        warnings = io.StringIO()
        with contextlib.redirect_stdout(warnings):
            result = digest_params(params, apply_stocks_specifics=specifics)
        after = snapshot(result)
        cases.append({
            "id": f"{film}|{paper}|{mode}",
            "film_info": {
                key: info[film][key] for key in
                ("stock", "type", "support", "use", "antihalation")
            },
            "paper_info": {"stock": paper},
            "mode": mode,
            "apply_stock_specifics": specifics,
            "before": before,
            "expected": after,
            "warning_on_missing_neutral": bool(warnings.getvalue()),
        })
    require(len(cases) == 360, "Unexpected Build77 digest matrix size")
    report = {
        "status": "ORIGINAL_PYTHON_DIGEST_REFERENCE_NOT_IOS_PRODUCTION_PARITY",
        "upstream_sha": SOURCE_SHA,
        "cases": cases,
        "neutral_database": neutral_db,
    }
    canonical = json.dumps(report, sort_keys=True, ensure_ascii=False,
                           allow_nan=False, separators=(",", ":")).encode()
    report["reference_sha256"] = hashlib.sha256(canonical).hexdigest()
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    report = generate()
    path = Path(args.output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, ensure_ascii=False, sort_keys=True,
                               allow_nan=False, separators=(",", ":")),
                    encoding="utf-8")
    print("ORIGINAL PYTHON DIGEST:", len(report["cases"]),
          "cases; SHA256", report["reference_sha256"])


if __name__ == "__main__":
    main()
