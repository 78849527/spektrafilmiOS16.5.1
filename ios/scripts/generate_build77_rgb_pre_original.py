#!/usr/bin/env python3
"""Build77/02: capture ORIGINAL Python SimulationPipeline._preprocess.

Constrained source contract: 8-bit sRGB encoded input, sRGB CCTF decoding,
uncropped 1:1 dimensions, explicitly enabled center_weighted auto exposure.
This is NOT the upstream default ProPhoto RGB input and is NOT a RAW/crop
or arbitrary skimage-rescale equivalence certification.

The Python source methods below are invoked as they are, without a reimplementation.
Unrelated model creation is bypassed using uninitialized stage instances only
to avoid spending runtime generating large spectral lookup tables.
"""
import hashlib
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "ios/scripts"))

from spektrafilm.runtime.pipeline import SimulationPipeline
from spektrafilm.runtime.stages.filming import FilmingStage
from spektrafilm.runtime.services.resize import ResizingService
from generate_source_full_frame import rgb_source

OUT = ROOT / "ios/verification/generated-physical-v1.8.22"
CASE = "kodak_neutral_fir"


def main():
    manifest_file = OUT / "manifest.json"
    doc = json.loads(manifest_file.read_text(encoding="utf-8"))
    fixture = next((v for v in doc["cases"] if v["name"] == CASE), None)
    assert fixture is not None, "Missing original physical fixture"
    width, height = fixture["width"], fixture["height"]
    image = np.asarray(rgb_source(height, width), dtype=np.float64) / 255.0
    assert image.shape == (height, width, 3)

    # The real source preprocess and FilmingStage.auto_exposure are called;
    # these objects simply supply the original fields consumed by the methods.
    io = SimpleNamespace(
        input_color_space="sRGB",
        input_cctf_decoding=True,
        crop=False, upscale_factor=1.0,
    )
    camera = SimpleNamespace(
        auto_exposure=True, auto_exposure_method="center_weighted",
    )
    resize = ResizingService(io, film_format_mm=35.0)
    filming = object.__new__(FilmingStage)
    filming._camera = camera
    filming._io = io
    filming._resize_service = resize
    pipeline = object.__new__(SimulationPipeline)
    pipeline._resize_service = resize
    pipeline._filming_stage = filming

    pre = SimulationPipeline._preprocess(pipeline, image)
    assert pre.dtype == np.dtype("float64")
    assert pre.shape == image.shape
    assert np.isfinite(pre).all() and (pre >= 0).all()
    assert resize.pixel_size_um == 35000.0 / max(height, width)
    # Disable the source auto-exposure via its ORIGINAL parameter, then
    # confirm the unchanged upstream no-resize branch is an identity.
    camera.auto_exposure = False
    off = SimulationPipeline._preprocess(pipeline, image)
    assert np.array_equal(off, image)
    camera.auto_exposure = True

    data = np.ascontiguousarray(pre, dtype="<f8").tobytes(order="C")
    (OUT / (CASE + ".rgbPre.f64le")).write_bytes(data)
    fixture["sha256"]["rgbPre"] = hashlib.sha256(data).hexdigest()
    fixture["rgb_pre_reference"] = {
        "source": "SimulationPipeline._preprocess",
        "meter_source": "FilmingStage.auto_exposure",
        "resizer_source": "ResizingService.crop_and_rescale",
        "io_color_space": "sRGB",
        "input_cctf_decoding": True,
        "auto_exposure": True,
        "method": "center_weighted",
        "crop": False,
        "upscale_factor": 1.0,
        "not_certified": [
            "upstream default ProPhoto RGB and CCTF configuration",
            "original skimage cropping and rescaling",
            "HDR/RAW/high-bit-depth and device ingress",
        ],
    }
    manifest_file.write_text(
        json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        "PASS original Python SimulationPipeline._preprocess "
        f"{width}x{height}x3 sRGB center_weighted source stage; "
        f"Float64 SHA256 {fixture['sha256']['rgbPre']}; "
        "no crop/rescale; autoexposure-off identity PASS"
    )


if __name__ == "__main__":
    main()
