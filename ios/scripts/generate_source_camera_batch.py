#!/usr/bin/env python3
"""Generate independent upstream Python data for THREE native camera stages.

Imports source modules (not Swift reimplementations):
  utils.autoexposure.measure_autoexposure_ev
  utils.numba_boost_hightlights.boost_highlights
  model.diffusion.apply_gaussian_blur_um
All images are deterministic synthetic full RGB frames, converted to
little-endian binary64; metadata/source SHA remains in the generator.
"""
from __future__ import annotations
import base64
import hashlib
from pathlib import Path
import importlib.util
import sys
import types
import numpy as np
from skimage.transform import rescale

root = Path(__file__).resolve().parents[2]
src = root / "src/spektrafilm"

# Upstream package __init__ eagerly loads optional exiv2/RAW bindings.
# Import the ORIGINAL source function files directly, exactly as the
# existing source DIR parity generators do. No reimplemented Python math.
for name, path in (
    ("spektrafilm", src),
    ("spektrafilm.utils", src / "utils"),
    ("spektrafilm.model", src / "model"),
):
    mod = types.ModuleType(name)
    mod.__path__ = [str(path)]
    sys.modules[name] = mod

def load_original(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module

load_original(
    "spektrafilm.utils.fast_gaussian_filter",
    src / "utils/fast_gaussian_filter.py",
)
load_original(
    "spektrafilm.utils.numba_boost_hightlights",
    src / "utils/numba_boost_hightlights.py",
)
meter = load_original(
    "spektrafilm.utils.autoexposure",
    src / "utils/autoexposure.py",
)
diffusion = load_original(
    "spektrafilm.model.diffusion",
    src / "model/diffusion.py",
)
measure_autoexposure_ev = meter.measure_autoexposure_ev
boost_highlights = sys.modules[
    "spektrafilm.utils.numba_boost_hightlights"
].boost_highlights
apply_gaussian_blur_um = diffusion.apply_gaussian_blur_um

out = root / "ios/SpektraFilmPort/GeneratedSourceCameraReference.swift"

def rgb(w, h):
    i = np.arange(w * h * 3, dtype=np.int64).reshape((h, w, 3))
    return (((i * 37 + 11) % 251).astype(np.float64) + 0.5) / 251.0

def photon(w, h):
    i = np.arange(w * h * 3, dtype=np.int64).reshape((h, w, 3))
    return ((i * 17 + 3) % 397).astype(np.float64) / 71.0

def encode(values):
    buf = np.asarray(values, dtype="<f8")
    assert np.all(np.isfinite(buf))
    return base64.b64encode(buf.tobytes()).decode("ascii")

methods = (
    "average","median","center_weighted","partial",
    "matrix","multi_zone","highlight_weighted"
)
meter_records=[]
for w,h in [(17,13), (257,301)]:
    image=rgb(w,h)
    if max(w,h) > 256:
        image=rescale(image,256/max(w,h),channel_axis=2,order=0)
    ev=[float(measure_autoexposure_ev(
        image,color_space="sRGB",apply_cctf_decoding=True,method=m
    )) for m in methods]
    meter_records.append((w,h,ev))
boost_records=[]
for w,h,ev,spread,protect in [
    (17,13,2.2,0.3,0.8),(17,13,0.8,0.85,1.1)
]:
    raw=photon(w,h)
    expected=boost_highlights(
        raw,boost_ev=ev,boost_range=spread,protect_ev=protect
    )
    boost_records.append((w,h,ev,spread,protect,encode(expected)))
lens_records=[]
for w,h,um,mm in [
    (31,29,45.0,1.0),(31,29,150.0,1.0)
]:
    raw=photon(w,h)
    px=mm*1000/max(w,h)
    expected=apply_gaussian_blur_um(raw,um,px)
    lens_records.append((w,h,um,mm,encode(expected)))
lines=[
    "import Foundation",
    "// GENERATED from actual original Python functions; do not hand-edit.",
    "enum GeneratedSourceCameraReference {",
    "    struct MeterCase {let width:Int;let height:Int;let ev:[Double]}",
    "    struct BoostCase {let width:Int;let height:Int;let ev:Double;let span:Double;let protect:Double;let output:String}",
    "    struct LensCase {let width:Int;let height:Int;let microns:Double;let formatMM:Double;let output:String}",
    "    static let meter:[MeterCase] = [",
]
for w,h,ev in meter_records:
    lines.append("        .init(width:%d,height:%d,ev:[%s])," % (
        w,h,",".join(repr(float(x)) for x in ev)
    ))
lines.extend(["    ]","    static let boost:[BoostCase] = ["])
for w,h,ev,spread,protect,b64 in boost_records:
    lines.append("        .init(width:%d,height:%d,ev:%r,span:%r,protect:%r,output:\"%s\")," %(
        w,h,ev,spread,protect,b64
    ))
lines.extend(["    ]","    static let lens:[LensCase] = ["])
for w,h,um,mm,b64 in lens_records:
    lines.append("        .init(width:%d,height:%d,microns:%r,formatMM:%r,output:\"%s\")," %(
        w,h,um,mm,b64
    ))
# Record the real upstream byte identity, including the filter dependency.
# Re-generated fixtures after an upstream change are not automatically
# considered certified: source hashes remain visible in native tests/reports.
lines.extend(["    ]", "    static let sourceSHA256: [String: String] = ["])
for label, path in (
    ("autoexposure", src / "utils/autoexposure.py"),
    ("highlight_boost", src / "utils/numba_boost_hightlights.py"),
    ("camera_diffusion", src / "model/diffusion.py"),
    ("source_gaussian", src / "utils/fast_gaussian_filter.py"),
):
    lines.append('        "%s": "%s",' % (
        label, hashlib.sha256(path.read_bytes()).hexdigest()
    ))
lines.extend(["    ]", "}"])
out.write_text("\n".join(lines)+"\n",encoding="utf-8")
print("PASS: source camera reference:",len(meter_records)*len(methods),
      "Python meter vectors,",
      len(boost_records),"Numba highlight full fields,",
      len(lens_records),"source FIR/YVV full-image lenses",out)
