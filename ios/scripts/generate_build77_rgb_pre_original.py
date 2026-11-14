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
import ast
import hashlib
import json
import runpy
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import colour
from skimage.transform import rescale

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ios/scripts"))
from generate_source_full_frame import rgb_source

# Git blob IDs of ORIGINAL source files in locked
# upstream commit 3bb2c2d2801ff68b92019cf1dbcbb133d60832bc.
# Never execute unpinned or rewritten algorithms.
PINNED = {
    "src/spektrafilm/runtime/pipeline.py":
        "d2d3ccdb08c2b9f89294bc05e9a0c74c58b96642",
    "src/spektrafilm/runtime/stages/filming.py":
        "b58759160dfa9dd45b5528b09b24ffafb5493b66",
    "src/spektrafilm/runtime/services/resize.py":
        "d2ca4db8e88cc9aae5e00abd4d4cf0fb600bdc84",
    "src/spektrafilm/utils/autoexposure.py":
        "59533605bab853f5cb57232b19edd286df3b8b4d",
}


def execute_exact_source_class(path, name, environment):
    """Execute unmodified original AST class, avoiding unrelated package init.

    Importing the full package triggers exiv2/RAW and spectral processing
    dependencies unrelated to this local _preprocess source contract.
    No method body or numerical operation is modified in this executor.
    """
    filepath = ROOT / path
    parsed = ast.parse(filepath.read_text(encoding="utf-8"), str(filepath))
    original = [
        node for node in parsed.body
        if isinstance(node, ast.ClassDef) and node.name == name
    ]
    assert len(original) == 1, f"Source class missing: {name}"
    # Preserve source __future__.annotations semantics for class signatures.
    preamble = ast.ImportFrom(
        module="__future__", names=[ast.alias(name="annotations")],
        level=0,
    )
    module = ast.fix_missing_locations(
        ast.Module(body=[preamble, original[0]], type_ignores=[])
    )
    namespace = dict(environment)
    exec(compile(module, str(filepath), "exec"), namespace)
    return namespace[name]


def load_original_preprocess():
    for path, sha in PINNED.items():
        actual = subprocess.run(
            ["git", "rev-parse", f"HEAD:{path}"],
            cwd=ROOT, check=True, capture_output=True, text=True,
        ).stdout.strip()
        assert actual == sha, f"Pinned source drift: {path}"

    # Run the ORIGINAL autoexposure.py as a standalone file. It imports only
    # NumPy and colour-science and does not depend on the RAW/ICC entrypoint.
    auto = runpy.run_path(
        str(ROOT / "src/spektrafilm/utils/autoexposure.py")
    )
    def rejected_crop(*args, **kwargs):
        raise AssertionError("Source rgb_pre fixture forbids image crop")
    environment = {
        "np": np,
        "measure_autoexposure_ev": auto["measure_autoexposure_ev"],
        "rescale": rescale,
        "crop_image": rejected_crop,
    }
    return tuple(execute_exact_source_class(path, name, environment)
                 for path, name in [
                    ("src/spektrafilm/runtime/pipeline.py",
                     "SimulationPipeline"),
                    ("src/spektrafilm/runtime/stages/filming.py",
                     "FilmingStage"),
                    ("src/spektrafilm/runtime/services/resize.py",
                     "ResizingService"),
                 ])

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

    SimulationPipeline, FilmingStage, ResizingService = load_original_preprocess()
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
