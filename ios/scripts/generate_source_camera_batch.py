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
import colour
from skimage.transform import rescale

root = Path(__file__).resolve().parents[2]
src = root / "src/spektrafilm"

# Pin the original, unmodified Python source *Git blob* identity.
# Hashes are the repository's main-branch upstream baseline. Regenerating
# expected Swift vectors must NOT silently legitimize source-code drift.
SOURCE_BLOBS={
    "autoexposure": (src / "utils/autoexposure.py", "59533605bab853f5cb57232b19edd286df3b8b4d"),
    "highlight_boost": (src / "utils/numba_boost_hightlights.py", "61cb5ca89163762335674279a9743801e13e0e8f"),
    "camera_diffusion": (src / "model/diffusion.py", "cb22136f9d6a65e32ab54fc6f46f64f308e1a4f7"),
    "source_gaussian": (src / "utils/fast_gaussian_filter.py", "8918c673ea0fb3f5d9ae820ca85bf6db4aba457a"),
}
for label,(path,expected_git_blob) in SOURCE_BLOBS.items():
    payload=path.read_bytes()
    header=b"blob "+str(len(payload)).encode("ascii")+b"\x00"
    actual_git_blob=hashlib.sha1(header+payload).hexdigest()
    if actual_git_blob != expected_git_blob:
        raise RuntimeError(
            f"Original Python source changed ({label}): "
            f"{actual_git_blob} != pinned {expected_git_blob}; "
            "review upstream delta and intentionally rebaseline references"
        )
print("PASS: four original Python camera dependency Git blobs pinned")

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
# Black/white edge cases are produced by the real upstream exposure meter.
# In the black frame, upstream -log2(0) yields Inf, then explicitly resets
# to 0 EV. White must remain finite and all seven original modes agree.
meter_edge_records=[]
for w,h,level in [(9,7,0.0),(9,7,1.0),(257,301,0.0)]:
    image=np.full((h,w,3),level,dtype=np.float64)
    if max(w,h)>256:
        image=rescale(image,256/max(w,h),channel_axis=2,order=0)
    ev=[float(measure_autoexposure_ev(
        image,color_space="sRGB",apply_cctf_decoding=True,method=m
    )) for m in methods]
    meter_edge_records.append((w,h,level,ev))
boost_records=[]
for w,h,ev,spread,protect in [
    (17,13,2.2,0.3,0.8),(17,13,0.8,0.85,1.1),(17,13,0.0,0.3,0.8)
]:
    raw=photon(w,h)
    expected=boost_highlights(
        raw,boost_ev=ev,boost_range=spread,protect_ev=protect
    )
    boost_records.append((w,h,ev,spread,protect,encode(expected)))
lens_records=[]
for w,h,um,mm in [
    (31,29,45.0,1.0),(31,29,150.0,1.0),
    (31,29,0.0,1.0),(30,27,100.0,1.0)
]:
    raw=photon(w,h)
    px=mm*1000/max(w,h)
    expected=apply_gaussian_blur_um(raw,um,px)
    lens_records.append((w,h,um,mm,encode(expected)))
# Real upstream Python per-channel emulsion scatter and three-bounce halation.
# Test all source paths: combined, varied size/scales, identity,
# scatter-only and halation-only. No reimplemented Python expected math.
halation_records=[]
for w,h,pixel_um,scatter_amount,hal_amount,scatter_scale,hal_scale in [
    (11,9,2.0,1.0,1.0,1.0,1.0),
    (17,13,5.0,0.35,0.8,1.7,0.6),
    (11,9,11.0,0.0,0.0,1.0,1.0),
    (15,11,40.0,1.0,0.0,1.0,1.0),
    (12,10,6.0,0.0,1.0,1.0,1.0),
]:
    params=types.SimpleNamespace(
        active=True,
        scatter_amount=scatter_amount,
        scatter_spatial_scale=scatter_scale,
        scatter_tail_weight=(0.78,0.65,0.67),
        scatter_core_um=(2.2,2.0,1.6),
        scatter_tail_um=(9.3,9.7,9.1),
        halation_amount=hal_amount,
        halation_spatial_scale=hal_scale,
        halation_strength=(0.05,0.015,0.0),
        halation_first_sigma_um=(65.0,65.0,65.0),
        halation_n_bounces=3,
        halation_bounce_decay=0.5,
        halation_renormalize=True,
    )
    expected=diffusion.apply_halation_um(photon(w,h),params,pixel_um)
    halation_records.append((
        w,h,pixel_um,scatter_amount,hal_amount,
        scatter_scale,hal_scale,encode(expected)
    ))

# The original colour-science implementation owns its actual sRGB
# RGB_to_XYZ Y-row. Never substitute matrix constants from a different
# library/release; the 17x13 original Python regression is stricter than
# such small yet measurable differences.
source_luminance_weights=colour.RGB_to_XYZ(
    np.eye(3,dtype=np.float64),"sRGB",apply_cctf_decoding=True
)[:,1]
assert source_luminance_weights.shape==(3,)
assert np.all(np.isfinite(source_luminance_weights))
assert np.all(source_luminance_weights>0)
lines=[
    "import Foundation",
    "// GENERATED from actual original Python functions; do not hand-edit.",
    "enum GeneratedSourceCameraReference {",
    "    static let sourceLuminanceWeights:[Double] = [%s]" % ",".join(repr(float(y)) for y in source_luminance_weights),
    "    struct MeterCase {let width:Int;let height:Int;let ev:[Double]}",
    "    struct EdgeMeterCase {let width:Int;let height:Int;let level:Double;let ev:[Double]}",
    "    struct BoostCase {let width:Int;let height:Int;let ev:Double;let span:Double;let protect:Double;let output:String}",
    "    struct LensCase {let width:Int;let height:Int;let microns:Double;let formatMM:Double;let output:String}",
    "    struct HalationCase {let width:Int;let height:Int;let pixelUM:Double;let scatter:Double;let halation:Double;let scatterScale:Double;let halationScale:Double;let output:String}",
    "    static let meter:[MeterCase] = [",
]
for w,h,ev in meter_records:
    lines.append("        .init(width:%d,height:%d,ev:[%s])," % (
        w,h,",".join(repr(float(x)) for x in ev)
    ))
lines.extend(["    ]","    static let meterEdge:[EdgeMeterCase] = ["])
for w,h,level,ev in meter_edge_records:
    lines.append("        .init(width:%d,height:%d,level:%r,ev:[%s])," % (
        w,h,level,",".join(repr(float(x)) for x in ev)
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
lines.extend(["    ]","    static let filmHalation:[HalationCase] = ["])
for w,h,px,sc,ha,ss,hs,b64 in halation_records:
    lines.append(
        '        .init(width:%d,height:%d,pixelUM:%r,scatter:%r,halation:%r,scatterScale:%r,halationScale:%r,output:"%s"),' %
        (w,h,px,sc,ha,ss,hs,b64)
    )
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
print("PASS: source camera true colour-science luminance weights:",source_luminance_weights.tolist())
print("PASS: source camera reference:",(len(meter_records)+len(meter_edge_records))*len(methods),
      "Python meter vectors,",
      len(boost_records),"Numba highlight full fields,",
      len(lens_records),"source FIR/YVV full-image lenses,",
      len(halation_records),"source full-image scatter/halation fields",out)
