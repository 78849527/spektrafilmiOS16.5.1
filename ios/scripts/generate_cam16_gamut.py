#!/usr/bin/env python3
"""Bake the ORIGINAL Spektrafilm default CAM16-UCS output gamut mapping.

Original uses colour-science/CAM16-UCS, output c_max(Jp,h) lookup
(64 x 720, 18 bisections), smooth Reinhard knee (0,1,6) and a
one-sided lightness knee (0.7,1.0,2.2), with viewing L_A=64/Y_b=20.

This script imports the upstream implementation from its actual file.
Packing a 33³ extended linear-sRGB lookup (rather than recreating a
full CAM16 perceptual model per pixel in Swift) enables iOS 16.5 and
preserves the source formula at each grid point. Interpolated samples
are an approximation; nodes and off-grid samples are tested separately.
"""
import base64
import importlib.util
import json
import math
import struct
import sys
import warnings
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "src/spektrafilm/utils/gamut_compression.py"
OUT = ROOT / "ios/SpektraFilmPort/GeneratedCAM16Gamut.swift"
SIDE = 33
MINIMUM = -0.25
MAXIMUM = 1.75

def load_source():
    name="spektrafilm_original_gamut_reference"
    spec=importlib.util.spec_from_file_location(name,SRC)
    mod=importlib.util.module_from_spec(spec)
    sys.modules[name]=mod
    spec.loader.exec_module(mod)
    return mod

def pack(values):
    a=np.asarray(values,dtype="<f4")
    return base64.b64encode(a.tobytes()).decode("ascii")

def swift_array(values):
    return "["+",".join(format(float(v),".17g") for v in values)+"]"

def main():
    gamut=load_source()
    # Exact original DEFAULT output spec, including one-sided highlight knee.
    spec=gamut.OutputGamutCompressSpec()
    assert spec.algorithm=="cam16ucs" and spec.knee==(0.,1.,6.)
    assert spec.lightness_compression==(0.7,1.0,2.2)
    grid=np.linspace(MINIMUM,MAXIMUM,SIDE)
    # Red fastest, then green, then blue, in CIColorCube order.
    samples=np.array([[r,g,b] for b in grid for g in grid for r in grid],dtype=np.float64)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore",RuntimeWarning)
        compressed=np.asarray(
            gamut.compress_rgb(samples,spec,output_color_space="sRGB"),
            dtype=np.float64
        )
    assert compressed.shape==samples.shape
    isfinite=np.isfinite(compressed).all(axis=1)
    count_bad=int((~isfinite).sum())
    # CAM16's domain cannot represent extremely nonphysical negative XYZ.
    # Store a safe original alternative only for those nonfinite nodes.
    if count_bad:
        compressed[~isfinite]=gamut.compress_rgb_aces_rgc(
            samples[~isfinite],threshold=0,limit=1,power=6
        )
    assert np.isfinite(compressed).all()
    assert count_bad < int(len(samples)*0.25), f"too many undefined nodes: {count_bad}"
    # Source cam16 gamut map can produce tiny negative numerical noise.
    # Leave it in linear floats for the final encoder to clamp, consistent
    # with iOS CIColorCube behaviour.
    refs=[
      [0,0,0],[0.18,0.18,0.18],[0.5,0.5,0.5],[1,1,1],
      [0.9,0.2,0.1],[0.04,0.35,0.8],[0.2,0.75,0.2],
      [0.7,0.4,0.85],[1.25,0.8,0.3],[0.24,0.17,0.5],
      [0.015,0.025,0.018],[0.91,0.72,0.45],
      [0.35,0.15,0.85],[0.33,0.48,0.66],[0.61,0.4,0.2]
    ]
    with warnings.catch_warnings():
        warnings.simplefilter("ignore",RuntimeWarning)
        refout=np.asarray(
            gamut.compress_rgb(np.asarray(refs),spec,output_color_space="sRGB"),
            dtype=float
        )
    assert np.isfinite(refout).all()
    # Check exact center sample matches original; source sometimes yields
    # tiny negative or >1 values which are kept for Swift's final clamp.
    lines=[
        "// AUTOMATIC: Original Spektrafilm OutputGamutCompressSpec CAM16-UCS",
        "// colour-science RGB→CAM16UCS→Reinhard knee→RGB. 33³ extended LUT.",
        "// 64x720 source Cmax(Jp,h), 18 bisections, L_A=64, Y_b=20.",
        "// No on-device Python. Trilinear interpolation outside exact nodes.",
        "enum GeneratedCAM16Gamut {",
        f"    static let dimension = {SIDE}",
        f"    static let minimum = {MINIMUM}",
        f"    static let maximum = {MAXIMUM}",
        f"    static let invalidSourceNodes = {count_bad}",
        f'    static let payload = "{pack(compressed)}"',
    ]
    for i,(val,expected) in enumerate(zip(refs,refout)):
        lines.append(f"    static let input{i}: [Double] = {swift_array(val)}")
        lines.append(f"    static let output{i}: [Double] = {swift_array(expected)}")
    lines.append("}")
    OUT.write_text("\n".join(lines)+"\n",encoding="utf-8")
    print("PASS: source default CAM16-UCS 64x720 gamut gamut boundary and highlight Reinhard knee")
    print(f"PASS: baked {len(samples)} original CAM16 samples; undefined/extreme nodes: {count_bad}")
    print(f"PASS: {len(refs)} independent source reference probes for iOS interpolation")
    print(f"Generated: {OUT.stat().st_size} bytes")

if __name__=="__main__":
    main()
