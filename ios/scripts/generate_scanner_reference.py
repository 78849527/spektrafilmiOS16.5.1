#!/usr/bin/env python3
"""Build original spektrafilm scanner colour reference data for native Swift.

The upstream ScanningStage uses colour.XYZ_to_RGB with its viewing-illuminant
chromatic adaptation, then source gamut_compression.py. The 3x3 D50 and
Kinoton K75P XYZ -> linear sRGB matrices are evaluated directly with
colour.XYZ_to_RGB, not with the previous simplified white-channel scaling.

Also writes original source ACES-RGC v1.3 knee reference vectors for a
native Swift equivalence test. CAM16-UCS is a different (default) source
algorithm and is deliberately NOT advertised as ported here.
"""
from pathlib import Path
import colour
import numpy as np

ROOT=Path(__file__).resolve().parents[2]
TARGET=ROOT/"ios/SpektraFilmPort/GeneratedScannerReference.swift"
SHAPE=colour.SpectralShape(380,780,5)
CMFS=np.asarray(colour.MSDS_CMFS["CIE 1931 2 Degree Standard Observer"]
        .copy().align(SHAPE).values, dtype=np.float64)

def illuminant(name):
    table=colour.SDS_LIGHT_SOURCES if name=="K75P" else colour.SDS_ILLUMINANTS
    key="Kinoton 75P" if name=="K75P" else name
    data=np.asarray(table[key].copy().align(SHAPE).values, dtype=np.float64)
    return data/np.mean(data)

def rgb_from_xyz(xyz, source_xy):
    return np.asarray(colour.XYZ_to_RGB(xyz,
        colourspace="sRGB", illuminant=source_xy,
        apply_cctf_encoding=False),dtype=np.float64)

def reinhard_knee(d):
    d=np.asarray(d,dtype=np.float64)
    return np.where(d>0,d/(1+np.maximum(d,0)**6)**(1/6),d)

def compress_rgb_aces_rgc(rgb):
    rgb=np.asarray(rgb,dtype=np.float64)
    ach=np.max(rgb,axis=-1,keepdims=True)
    safe=np.where(ach>1e-12,ach,1.0)
    d=(ach-rgb)/safe
    return np.where(ach>1e-12,ach*(1-reinhard_knee(d)),rgb)

def fmt(v):
    return "["+",".join(format(float(i),".17g") for i in np.asarray(v).ravel())+"]"

def main():
    lines=[
      "// Generated with ORIGINAL source ScanningStage XYZ_to_RGB and",
      "// gamut_compression.compress_rgb_aces_rgc under colour-science 0.4.6.",
      "// The original Python default CAM16-UCS gamut algorithm is separate.",
      "enum GeneratedScannerReference {",
      "    static let transformsXYZToLinearSRGB: [String: [Double]] = [",
    ]
    sources={}
    for name in ("D50","K75P"):
        source=illuminant(name)
        norm=float(np.einsum("w,w->",source,CMFS[:,1]))
        source_xyz=np.einsum("w,wc->c",source,CMFS)/norm
        xy=colour.XYZ_to_xy(source_xyz)
        matrix=rgb_from_xyz(np.eye(3),xy)
        assert matrix.shape==(3,3) and np.isfinite(matrix).all()
        sources[name]=(norm,matrix)
        lines.append(f'        "{name}": {fmt(matrix)},')
    lines.append("    ]")
    lines.append("    static let xyzYNormalization: [String: Double] = [")
    for name,(norm,_) in sources.items():
        lines.append(f'        "{name}": {format(norm,".17g")},')
    lines.append("    ]")
    for i,(name,xyz) in enumerate([
        ("D50",[0.184,0.184,0.184]),
        ("D50",[0.47,0.35,0.20]),
        ("K75P",[0.184,0.184,0.184]),
        ("K75P",[0.15,0.32,0.62])
    ]):
        src=illuminant(name)
        xyzwhite=np.einsum("w,wc->c",src,CMFS)
        xy=colour.XYZ_to_xy(xyzwhite)
        rgb=rgb_from_xyz(np.asarray(xyz),xy)
        lines.extend([
            f'    static let xyzStock{i} = "{name}"',
            f"    static let xyzInput{i}: [Double] = {fmt(xyz)}",
            f"    static let xyzRGB{i}: [Double] = {fmt(rgb)}",
        ])
    for i,vec in enumerate([
        [-0.3,0.45,0.85],[0.2,0.3,0.8],
        [1.4,0.32,0.09],[0.018,0.018,0.018],
        [0.72,-0.22,0.12],[0.0,0.0,0.0],
        [0.35,0.35,0.35],[0.03,0.98,-0.04]
    ]):
        lines.extend([
            f"    static let gamutInput{i}: [Double] = {fmt(vec)}",
            f"    static let gamutExpected{i}: [Double] = {fmt(compress_rgb_aces_rgc(vec))}"
        ])
    lines.append("}")
    TARGET.write_text("\n".join(lines)+"\n",encoding="utf-8")
    print("PASS: source XYZ_to_RGB sRGB matrices for D50/K75P and CIE 1931 viewing normalizations")
    print("PASS: 4 XYZ/RGB and 8 original source ACES v1.3 gamut compression reference vectors")
    print(f"Generated scanner reference: {TARGET.stat().st_size} bytes")

if __name__=="__main__":
    main()
