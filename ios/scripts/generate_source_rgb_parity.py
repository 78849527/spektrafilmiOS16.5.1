#!/usr/bin/env python3
"""Source-runtime direct reversal-film density -> scanner RGB truth vectors.

The comparison intentionally bypasses film exposure, chemical development,
random grain, photographic printing, glare, lens blur and sharpening. For a
POSITIVE stock, ScanningStage._density_to_rgb uses the original film's
measured 81-wavelength dyes and base, D50 viewing, colour.XYZ_to_RGB and
source aces_rgc compression, followed by the upstream CCTF encoding.

This test IS NOT complete RAW->negative->paper->scan/JPEG parity.
We explicitly run/source-pin original spektrafilm helper functions.
"""
from __future__ import annotations
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
import colour
from opt_einsum import contract

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT / "src"))
from spektrafilm.config import STANDARD_OBSERVER_CMFS
from spektrafilm.model.develop import compute_density_spectral
from spektrafilm.model.illuminants import standard_illuminant
from spektrafilm.utils.conversions import density_to_light
from spektrafilm.utils.gamut_compression import compress_rgb_aces_rgc

PROFILES = ROOT / "src/spektrafilm/data/profiles"
OUTPUT = ROOT / "ios/SpektraFilmPort/GeneratedSourceRGBReference.swift"

def swift(values):
    values=np.asarray(values,dtype=np.float64).ravel()
    assert np.isfinite(values).all(), "Source RGB reference is nonfinite"
    return "[" + ",".join(format(float(v),".17g") for v in values) + "]"

def source_scan(profile, density):
    assert profile["info"]["type"]=="positive"
    info=profile["info"]
    data=profile["data"]
    dye=np.asarray(data["channel_density"],dtype=np.float64)
    base=np.asarray(data["base_density"],dtype=np.float64)
    light_source=np.asarray(standard_illuminant(info["viewing_illuminant"]),
                             dtype=np.float64)
    cie=np.asarray(STANDARD_OBSERVER_CMFS,dtype=np.float64)
    assert dye.shape==(81,3) and base.shape==(81,)
    assert cie.shape==(81,3) and light_source.shape==(81,)
    normalization=np.sum(light_source*cie[:,1])
    # Original _return_callable_cmy_to_log_xyz:
    density_spectral=compute_density_spectral(
        dye, density[None,:,:], base_density=base
    )
    transmission=density_to_light(density_spectral,light_source)
    xyz=contract("ijk,kl->ijl",transmission,cie)/normalization
    log_xyz=np.log10(np.fmax(xyz,0.0)+1e-10)
    # Original _density_to_rgb: 10**log_xyz, reference blackwhite OFF,
    # no glare (positive film direct scan), ACES RGC opt-in compressor.
    xyz=10.0**log_xyz
    illuminant_xyz=contract("k,kl->l",light_source,cie)/normalization
    viewing_xy=colour.XYZ_to_xy(illuminant_xyz)
    linear=colour.XYZ_to_RGB(
        xyz,colourspace="sRGB",apply_cctf_encoding=False,
        illuminant=viewing_xy
    )
    compressed=compress_rgb_aces_rgc(linear)
    encoded=colour.RGB_to_RGB(
        compressed,"sRGB","sRGB",
        apply_cctf_decoding=False,apply_cctf_encoding=True
    )
    assert np.isfinite(encoded).all()
    return linear[0],compressed[0],encoded[0]

def main():
    sources=[
        ROOT / "src/spektrafilm/runtime/stages/scanning.py",
        ROOT / "src/spektrafilm/model/develop.py",
        ROOT / "src/spektrafilm/utils/conversions.py",
        ROOT / "src/spektrafilm/utils/gamut_compression.py",
    ]
    src=(sources[0]).read_text()
    for guard in (
        "log_xyz = self._lut_service.spectral_compute_scanner(",
        "xyz = 10 ** log_xyz",
        "rgb = colour.XYZ_to_RGB(",
        "rgb = compress_rgb(",
        "apply_cctf_decoding=False",
    ):
        assert guard in src, "ScanningStage source has changed: "+guard
    lines=[
        "// Direct source POSITIVE film spectral scan only, NOT whole rendering.",
        "// Upstream scanning.py -> XYZ -> ACES RGC -> sRGB CCTF.",
        "// Python Float64 reference; iOS measured spectra packed as Float32.",
        "enum GeneratedSourceRGBReference {",
        "    struct Case {",
        "        let stock: String",
        "        let density: [Double]",
        "        let sourceLinearRGB: [Double]",
        "        let sourceEncodedRGB: [Double]",
        "    }",
        "    static let sourceSHA: [String: String] = [",
    ]
    for p in sources:
        lines.append(f'        "{p.name}": "{hashlib.sha256(p.read_bytes()).hexdigest()}",')
    lines.extend(["    ]","    static let cases: [Case] = ["])
    n=0
    for stock in ["fujifilm_provia_100f","fujifilm_velvia_100"]:
        path=PROFILES/(stock+".json")
        p=json.loads(path.read_text())
        maxima=np.nanmax(np.asarray(p["data"]["density_curves"],np.float64),axis=0)
        densities=[]
        for t in (0.03,0.10,0.22,0.42,0.61,0.85):
            densities += [
                maxima*np.array([t,t,t]),
                maxima*np.array([t, min(0.96,t*1.5),max(0.01,t*0.7)]),
            ]
        densities=np.array(densities,dtype=np.float64)
        assert densities.shape==(12,3)
        linear,compressed,encoded=source_scan(p,densities)
        for k in range(len(densities)):
            lines.extend([
                "        Case(",
                f'            stock: "{stock}",',
                f'            density: {swift(densities[k])},',
                f'            sourceLinearRGB: {swift(linear[k])},',
                f'            sourceEncodedRGB: {swift(encoded[k])}',
                "        ),",
            ])
            n+=1
    lines.extend(["    ]","}"])
    OUTPUT.write_text("\n".join(lines)+"\n")
    print(f"PASS: {n} Python upstream direct positive-film scanner RGB vectors; stage-specific only (NOT whole pipeline)")

if __name__=="__main__":
    main()
