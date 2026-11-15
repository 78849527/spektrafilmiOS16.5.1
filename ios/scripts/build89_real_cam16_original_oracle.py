#!/usr/bin/env python3
"""Build89: ORIGINAL 0.4.6 colour CAM16-UCS and original Python gamut.

True original source gamut_compression.py, not a manual port oracle.
Source CAM16_UCS -> original 64x720 Cmax and 18 bisections, all computed
by colour-science before Swift production Float64 comparison. Exact
source file SHA is checked before any original function executes.
"""
import hashlib,importlib.util,json,sys,warnings
from pathlib import Path
import numpy as np
import colour
ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/"src/spektrafilm/utils/gamut_compression.py"
PIN="9783e7fcfc2909c4acdf2da53595c5404645dde9"

def gitblob(path):
    raw=path.read_bytes()
    return hashlib.sha1(b"blob "+str(len(raw)).encode()+b"\0"+raw).hexdigest()

def main(dest):
    assert gitblob(SOURCE)==PIN,"Original gamut source drift"
    assert colour.__version__=="0.4.6",colour.__version__
    spec=importlib.util.spec_from_file_location("build89_real_original_gamut",SOURCE)
    module=importlib.util.module_from_spec(spec)
    sys.modules[spec.name]=module
    spec.loader.exec_module(module)
    assert module.OutputGamutCompressSpec().algorithm=="cam16ucs"
    assert module._CAM16UCS_L_A==64.0
    assert module._CAM16UCS_Y_B==20.0
    rgb_samples=np.asarray([
        [0.0,0.0,0.0],
        [0.007,0.009,0.012],
        [0.18,0.18,0.18],
        [0.9,0.9,0.9],
        [1.0,1.0,1.0],
        [0.84,0.12,0.015],
        [0.04,0.35,0.80],
        [0.20,0.75,0.20],
        [0.7,0.4,0.85],
        [1.25,0.8,0.3],
        [0.24,0.17,0.5],
        [0.06,0.015,0.95],
        [1.4,1.25,1.1],
        [0.90,0.2,0.35],
        [0.2,0.93,0.70],
        [0.35,0.15,0.85],
        [1.75,0.7,0.36],
        [0.4,0.4,0.4],
    ],dtype=np.float64)
    spaces=("sRGB","Display P3","ITU-R BT.2020")
    configs=[
        ((0.0,1.0,6.0),(0.7,1.0,2.2)),
        ((0.0,1.0,6.0),None),
        ((0.22,1.0,2.6),(0.65,1.0,3.2)),
        ((0.0,1.18,4.5),(0.2,1.05,1.8)),
    ]
    all_cases=[]
    for space in spaces:
        cs=colour.RGB_COLOURSPACES[space]
        white=module._output_cs_whitepoint_xyz(space)
        rgb_xyz=np.asarray(colour.RGB_to_XYZ(
            rgb_samples,colourspace=space,illuminant=cs.whitepoint,
            apply_cctf_decoding=False
        ),dtype=np.float64)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore",RuntimeWarning)
            originalJab=np.asarray(colour.XYZ_to_CAM16UCS(
                rgb_xyz,XYZ_w=white,L_A=64.0,Y_b=20.0
            ),dtype=np.float64)
            invxyz=np.asarray(colour.CAM16UCS_to_XYZ(
                originalJab,XYZ_w=white,L_A=64.0,Y_b=20.0
            ),dtype=np.float64)
            # The native inverse returns source OUTPUT RGB (not XYZ).
            # Colour's RGB↔XYZ matrices are NOT exact algebraic inverses;
            # never compare a second roundtrip to raw source XYZ.
            inverseRGB=np.asarray(colour.XYZ_to_RGB(
                invxyz,colourspace=space,illuminant=cs.whitepoint,
                apply_cctf_encoding=False
            ),dtype=np.float64)
        assert originalJab.shape==(len(rgb_samples),3)
        # Source reference table per output primaries (64x720x18
        # original CAM16UCS inverse bisections).
        with warnings.catch_warnings():
            warnings.simplefilter("ignore",RuntimeWarning)
            L,H,table=module._get_output_c_max_table("cam16ucs",space)
        assert table.shape==(64,720)
        assert np.isfinite(table).all()
        assert np.all(table>=0)
        for (knee,light) in configs:
            params=module.OutputGamutCompressSpec(
                algorithm="cam16ucs",knee=knee,
                lightness_compression=light
            )
            with warnings.catch_warnings():
                warnings.simplefilter("ignore",RuntimeWarning)
                got=np.asarray(module.compress_rgb(
                    rgb_samples,params,output_color_space=space
                ),dtype=np.float64)
            assert got.shape==rgb_samples.shape
            for idx,rgb in enumerate(rgb_samples):
                if not np.isfinite(got[idx]).all():
                    # Unsupported source domain: keep explicitly counted,
                    # NOT silently call ACES or assert a false source pass.
                    all_cases.append(dict(
                        space=space,rgb=rgb.tolist(),
                        knee=knee,light=light,unsupported=True
                    ))
                    continue
                if not np.isfinite(originalJab[idx]).all():
                    all_cases.append(dict(
                        space=space,rgb=rgb.tolist(),
                        knee=knee,light=light,unsupported=True
                    ))
                    continue
                all_cases.append(dict(
                    space=space,rgb=rgb.tolist(),
                    knee=knee,light=light,
                    sourceJab=originalJab[idx].tolist(),
                    roundtripXYZ=invxyz[idx].tolist(),
                    sourceInverseRGB=inverseRGB[idx].tolist(),
                    result=got[idx].tolist(),unsupported=False
                ))
    assert len(all_cases)==3*4*len(rgb_samples)
    valid=sum(not c["unsupported"] for c in all_cases)
    assert valid>=180,(valid,len(all_cases))
    Path(dest).write_text(json.dumps(
        dict(cases=all_cases,valid=valid,sourceBlob=PIN,
             colourVersion=colour.__version__,
             view=dict(L_A=64,Y_b=20),
             gamutGrid=[64,720,18]),
        separators=(",",":"),allow_nan=False),encoding="utf8")
    print("ORIGINAL PYTHON TRUE CAM16-UCS SOURCE PASS",
          len(all_cases),"space/knee/lightness cases,",valid,"finite",
          "source 64x720x18 Cmax table probes (3 RGB gamuts).")

if __name__=="__main__":
    main(sys.argv[1])
