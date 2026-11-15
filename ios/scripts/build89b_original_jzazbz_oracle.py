#!/usr/bin/env python3
"""Source Spektrafilm JzAzBz via actual gamut_compression.py and real
colour-science 0.4.6 Safdar 2017/SDR 100 cd/m².
Output Cmax(Jz,h) = 64x720, 18 bisections, upper chroma=0.3.
Real full RGB vectors with knee and high-side perceptual lightness.
"""
import hashlib,importlib.util,json,sys,warnings
from pathlib import Path
import numpy as np
import colour

ROOT=Path(__file__).resolve().parents[2]
PATH=ROOT/"src/spektrafilm/utils/gamut_compression.py"
BLOB="9783e7fcfc2909c4acdf2da53595c5404645dde9"

def main(destination):
    raw=PATH.read_bytes()
    assert hashlib.sha1(
        b"blob "+str(len(raw)).encode()+b"\0"+raw
    ).hexdigest()==BLOB
    assert colour.__version__=="0.4.6"
    spec=importlib.util.spec_from_file_location("original_build89b_jz",PATH)
    src=importlib.util.module_from_spec(spec)
    sys.modules[spec.name]=src
    spec.loader.exec_module(src)
    assert src._JZAZBZ_Y_W_CDM2==100.
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
    options=(
        ((0.,1.,6.),(0.7,1.,2.2)),
        ((0.17,1.,3.2),None)
    )
    cases=[]
    for space in spaces:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore",RuntimeWarning)
            lightgrid,hues,ctable=src._get_output_c_max_table(
                "jzazbz",space
            )
        assert ctable.shape==(64,720)
        assert np.all(np.isfinite(ctable))
        for knee,lightness in options:
            settings=src.OutputGamutCompressSpec(
                algorithm="jzazbz",knee=knee,
                lightness_compression=lightness
            )
            with warnings.catch_warnings():
                warnings.simplefilter("ignore",RuntimeWarning)
                output=np.asarray(src.compress_rgb(
                    samples,settings,output_color_space=space
                ),dtype=np.float64)
            assert output.shape==samples.shape
            assert np.isfinite(output).all(),(
                space,knee,output[~np.isfinite(output).all(axis=1)]
            )
            for rgb,expected in zip(samples,output):
                cases.append(dict(
                    algorithm="jzazbz",space=space,
                    rgb=rgb.tolist(),knee=knee,
                    light=lightness,expected=expected.tolist()
                ))
    assert len(cases)==72
    Path(destination).write_text(
        json.dumps(dict(sourceBlob=BLOB,
                        colourVersion=colour.__version__,cases=cases,
                        grid=[64,720,18],peak=100),
                   separators=(",",":"),allow_nan=False),
        encoding="utf8"
    )
    print("ORIGINAL SOURCE JZAZBZ PASS",len(cases),
          "real 64x720x18 source colour-science 0.4.6 Cmax "
          "vectors, 3 RGB primaries, SDR white100, two lightness modes.")

if __name__=="__main__":
    main(sys.argv[1])
