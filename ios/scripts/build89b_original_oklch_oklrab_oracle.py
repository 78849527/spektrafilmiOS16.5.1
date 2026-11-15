#!/usr/bin/env python3
"""Real pinned source output gamut: Oklch + Oklrab against original 64×720
Cmax and 18 bisections. Checks actual source Colour 0.4.6, does not
reimplement the colour-science forward/inverse in Python.
"""
from pathlib import Path
import hashlib,importlib.util,json,sys,warnings
import numpy as np
import colour

ROOT=Path(__file__).resolve().parents[2]
PATH=ROOT/"src/spektrafilm/utils/gamut_compression.py"
BLOB="9783e7fcfc2909c4acdf2da53595c5404645dde9"

def main(destination):
    raw=PATH.read_bytes()
    sha=hashlib.sha1(b"blob "+str(len(raw)).encode()+b"\0"+raw).hexdigest()
    assert sha==BLOB,("Upstream gamut changed",sha)
    assert colour.__version__=="0.4.6"
    spec=importlib.util.spec_from_file_location("original_gamut_build89b",PATH)
    source=importlib.util.module_from_spec(spec)
    sys.modules[spec.name]=source
    spec.loader.exec_module(source)
    samples=np.asarray([
        [0.,0.,0.],
        [0.002,0.004,0.008],
        [0.18,0.18,0.18],
        [1.,1.,1.],
        [0.90,0.015,0.08],
        [0.025,0.55,0.94],
        [0.25,0.75,0.2],
        [0.8,0.24,0.69],
        [1.35,0.5,0.28],
        [0.32,0.42,1.4],
        [0.2,0.4,0.3],
        [0.7,0.6,0.2],
    ],dtype=np.float64)
    spaces=("sRGB","Display P3","ITU-R BT.2020")
    settings=(
        ((0.,1.,6.),(0.7,1.,2.2)),
        ((0.17,1.,3.2),None),
    )
    cases=[]
    for algorithm in ("oklch","oklrab"):
        for space in spaces:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore",RuntimeWarning)
                table=source._get_output_c_max_table(algorithm,space)
            assert table[2].shape==(64,720)
            assert np.isfinite(table[2]).all()
            for knee,light in settings:
                config=source.OutputGamutCompressSpec(
                    algorithm=algorithm,knee=knee,
                    lightness_compression=light
                )
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore",RuntimeWarning)
                    expected=source.compress_rgb(
                        samples,config,output_color_space=space
                    )
                assert expected.shape==samples.shape
                assert np.isfinite(expected).all()
                for inputRGB,result in zip(samples,expected):
                    cases.append(dict(
                        algorithm=algorithm,space=space,
                        rgb=inputRGB.tolist(),knee=knee,light=light,
                        expected=result.tolist()
                    ))
    assert len(cases)==144
    Path(destination).write_text(
        json.dumps(dict(cases=cases,sourceBlob=BLOB,
                        colourVersion=colour.__version__,
                        table=[64,720,18]),separators=(",",":"),allow_nan=False)
    )
    print("ORIGINAL PYTHON source OKLCH+OKLRAB PASS",
          len(cases),"actual source colour-science 0.4.6 64x720x18 "
          "Cmax records, 3 RGB gamuts, original lightness on/off.")

if __name__=="__main__":
    main(sys.argv[1])
