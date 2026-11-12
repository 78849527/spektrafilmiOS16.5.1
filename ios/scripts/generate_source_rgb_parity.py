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
import ast
import hashlib
import json
from pathlib import Path

import numpy as np
import colour
from opt_einsum import contract

ROOT = Path(__file__).resolve().parents[2]

def original_config():
    # The package __init__ imports RAW support (exiv2, OpenImageIO). Our
    # reference requires only these ORIGINAL assignments from config.py.
    # Execute them unchanged from the AST, not a copied calibration.
    path=ROOT/"src/spektrafilm/config.py"
    tree=ast.parse(path.read_text(encoding="utf-8"),filename=str(path))
    wanted={"SPECTRAL_SHAPE","STANDARD_OBSERVER_CMFS"}
    nodes=[
        node for node in tree.body
        if isinstance(node,ast.Assign) and any(
            isinstance(t,ast.Name) and t.id in wanted
            for t in node.targets
        )
    ]
    namespace={"np":np,"colour":colour}
    exec(compile(ast.fix_missing_locations(
        ast.Module(body=nodes,type_ignores=[])),str(path),"exec"),namespace)
    assert wanted.issubset(namespace), "Original CIE 1931/D50 spectral setup changed"
    return namespace

CONFIG=original_config()
STANDARD_OBSERVER_CMFS=CONFIG["STANDARD_OBSERVER_CMFS"]
SPECTRAL_SHAPE=CONFIG["SPECTRAL_SHAPE"]

# Extract the ORIGINAL source functions unchanged. Importing the full
# illuminants.py module pulls optional exiv2/OpenImageIO dependencies
# through color_filters; the D50 scanner reference doesn't use them.
# AST extraction preserves original source equations and signatures
# without installing unrelated image-metadata or RAW adapters.
def original_functions():
    namespace = dict(np=np, colour=colour, contract=contract,
                     SPECTRAL_SHAPE=SPECTRAL_SHAPE)
    modules = [
        ("src/spektrafilm/model/develop.py", ["compute_density_spectral"]),
        ("src/spektrafilm/model/illuminants.py", ["standard_illuminant"]),
        ("src/spektrafilm/utils/conversions.py", ["density_to_light"]),
        ("src/spektrafilm/utils/gamut_compression.py",
         ["reinhard_knee", "compress_rgb_aces_rgc"]),
    ]
    for rel, names in modules:
        path=ROOT/rel
        tree=ast.parse(path.read_text(encoding="utf-8"),
                       filename=str(path))
        for name in names:
            nodes=[node for node in tree.body if
                   isinstance(node,ast.FunctionDef) and node.name==name]
            assert len(nodes)==1, f"Source reference function changed: {rel}:{name}"
            module=ast.fix_missing_locations(
                ast.Module(body=nodes, type_ignores=[]))
            exec(compile(module,str(path),"exec"),namespace)
    return namespace

FUNCTIONS=original_functions()
compute_density_spectral=FUNCTIONS["compute_density_spectral"]
standard_illuminant=FUNCTIONS["standard_illuminant"]
density_to_light=FUNCTIONS["density_to_light"]
compress_rgb_aces_rgc=FUNCTIONS["compress_rgb_aces_rgc"]

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
    cie=np.asarray(STANDARD_OBSERVER_CMFS[:],dtype=np.float64)
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
    compressed=compress_rgb_aces_rgc(
        linear,threshold=0.0,limit=1.0,power=6.0
    )
    encoded=colour.RGB_to_RGB(
        compressed,"sRGB","sRGB",
        apply_cctf_decoding=False,apply_cctf_encoding=True
    )
    assert np.isfinite(encoded).all()
    return linear[0],compressed[0],encoded[0]

def main():
    sources=[
        ROOT / "src/spektrafilm/config.py",
        ROOT / "src/spektrafilm/runtime/stages/scanning.py",
        ROOT / "src/spektrafilm/model/develop.py",
        ROOT / "src/spektrafilm/model/illuminants.py",
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
