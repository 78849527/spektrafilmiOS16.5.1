#!/usr/bin/env python3
"""Create fresh SOURCE-Python, multi-size whole-frame DIR reference fixtures.

This is a deterministic *stage-limited* 8-bit RGB -> source spatial DIR
comparison, not full SpektraFilm optical/RAW/Numba stochastic certification.
No SciPy replacement kernels or stored hand-crafted Swift output references.
"""
import hashlib
import json
import struct
import zlib

import numpy as np

from generate_source_film_dir_print_chain import ROOT, upstream_film, load_original_module
from generate_dir import PROFILES, matrix


CASES = [
    ("negative_edges", "kodak_portra_400", False, 193, 129, 40.0, 1.0, 0.06),
    ("positive_edges", "fujifilm_provia_100f", True, 192, 128, 50.0, 1.0, 0.06),
    ("negative_uneven", "kodak_portra_400", False, 601, 401, 90.0, 1.1, 0.15),
]
STAGES = ("input", "raw", "initial", "inhibitors", "diffused",
          "log", "densityPreGrain", "printed")


def chunk(kind, payload):
    return (struct.pack(">I", len(payload)) + kind + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff))


def png_rgb8(rgb):
    """Write tagged sRGB PNG without Pillow/CI or ambiguous pixel ordering."""
    height, width, channels = rgb.shape
    assert channels == 3 and rgb.dtype == np.uint8
    stream = b"".join(b"\x00" + rgb[row].tobytes() for row in range(height))
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"sRGB", b"\x00")
            + chunk(b"IDAT", zlib.compress(stream, level=9))
            + chunk(b"IEND", b""))


def rgb_source(height, width):
    yy, xx = np.indices((height, width), dtype=np.int64)
    # Non-symmetric rows, hard edges, high-frequency checks, channel differences.
    red = (19 + 17 * xx + 31 * yy + 71 * ((xx // 19 + yy // 13) % 2)) % 256
    green = (101 + 7 * xx + 43 * yy + 53 * ((xx // 11) % 3)) % 256
    blue = (223 + 37 * xx + 3 * yy + 89 * ((yy // 17) % 2)) % 256
    return np.stack((red, green, blue), axis=-1).astype(np.uint8)


def main():
    density_module, couplers, _ = upstream_film()
    source_filter = load_original_module(
        "spektrafilm.utils.fast_gaussian_filter",
        ROOT / "src/spektrafilm/utils/fast_gaussian_filter.py",
    )
    couplers.fast_gaussian_filter = source_filter.fast_gaussian_filter
    couplers.fast_exponential_filter = source_filter.fast_exponential_filter

    output = ROOT / "ios" / "verification" / "generated-fullframe-v1.8.20"
    output.mkdir(parents=True, exist_ok=True)
    manifest = {"scope": "8bit-sRGB-source-spatial-DIR-identity-LUT-only",
                "source": "src/spektrafilm/model/couplers.py",
                "cases": []}
    for name, film, positive, width, height, pixel_um, radius_scale, tail_weight in CASES:
        image = rgb_source(height, width)
        source = image.astype(np.float64) / 255.0
        document = json.loads((PROFILES / (film + ".json")).read_text())
        density = np.asarray(document["data"]["density_curves"], dtype=np.float64)
        maximum = (density - np.min(density, axis=0)).max(axis=0)
        m = np.asarray(matrix(film, positive), dtype=np.float64)
        silver = maximum - source if positive else source
        inhibitors = silver @ m
        core_sigma = 20.0 * radius_scale / pixel_um
        tail_sigma = 200.0 * radius_scale / pixel_um
        # Execute upstream function directly; never replace with a mock.
        corrected = couplers.compute_exposure_correction_dir_couplers(
            source, source, maximum, m, core_sigma, tail_sigma,
            tail_weight, positive=positive,
        )
        diffused = source - corrected
        direct = ((1.0 - tail_weight)
                  * source_filter.fast_gaussian_filter(inhibitors, core_sigma)
                  + tail_weight
                  * source_filter.fast_exponential_filter(inhibitors, tail_sigma))
        assert np.max(np.abs(diffused - direct)) < 1e-10
        printed = np.clip(source - diffused / 2.0, 0.0, 1.0)
        stages = {
            "input": source, "raw": source, "initial": source,
            "inhibitors": inhibitors, "diffused": diffused,
            "log": printed, "densityPreGrain": printed, "printed": printed,
        }
        hashes = {}
        png = png_rgb8(image)
        (output / (name + ".png")).write_bytes(png)
        hashes["png"] = hashlib.sha256(png).hexdigest()
        for stage in STAGES:
            values = np.ascontiguousarray(stages[stage], dtype="<f8")
            assert values.shape == (height, width, 3)
            assert np.isfinite(values).all()
            payload = values.tobytes(order="C")
            (output / (name + "." + stage + ".f64le")).write_bytes(payload)
            hashes[stage] = hashlib.sha256(payload).hexdigest()
        manifest["cases"].append({
            "name": name, "film": film, "positive": positive,
            "width": width, "height": height,
            "pixelUM": pixel_um, "radiusScale": radius_scale,
            "tailWeight": tail_weight, "matrix": m.ravel().tolist(),
            "densityMaximum": maximum.tolist(), "sha256": hashes,
        })
        print(f"PASS upstream Python original {name} {width}x{height}: "
              f"{width*height*3} Float64 RGB channels across {len(STAGES)} stages",
              flush=True)
    path = output / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")
    print("Generated ORIGINAL upstream staged image fixtures in", output)


if __name__ == "__main__":
    main()
