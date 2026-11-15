#!/usr/bin/env python3
"""Source OutputGamutCompressSpec off and ACES custom knee exact oracle.

Execute actual pinned utils/gamut_compression.py and native source dispatch,
including negative/overwhite, threshold, limit, power and the source
"lightness compression ignored by ACES" branch. Never clamp to [0,1].
"""
import hashlib,importlib.util,json,sys,warnings
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/"src/spektrafilm/utils/gamut_compression.py"
PIN="9783e7fcfc2909c4acdf2da53595c5404645dde9"
def main(dest):
    raw=SRC.read_bytes()
    sha=hashlib.sha1(b"blob "+str(len(raw)).encode()+b"\0"+raw).hexdigest()
    assert sha==PIN,"Original gamut source drift"
    spec=importlib.util.spec_from_file_location("build89_output_source",SRC)
    source=importlib.util.module_from_spec(spec)
    sys.modules[spec.name]=source
    spec.loader.exec_module(source)
    colours=[
      [-0.2,-0.05,-0.1],[0,0,0],[1e-14,0,0],
      [0.004,0.01,0.002],[0.18,0.18,0.18],
      [0.9,0.1,0.015],[0.2,0.7,1.4],
      [1.7,0.8,0.3],[1.7,1.5,1.3],
      [0.0,-0.5,0.9],[1.2,-0.7,0.3],
      [0.95,1.6,0.4],[3.1,2.9,-0.8],
      [0.3,0.2,0.0],
    ]
    settings=[
      ("off",(0.0,1.0,6.0),(0.7,1.0,2.2)),
      ("off",(0.2,1.18,4.0),None),
      ("aces_rgc",(0.0,1.0,6.0),(0.7,1.0,2.2)),
      ("aces_rgc",(0.1,1.0,2.0),None),
      ("aces_rgc",(0.3,1.1,5.5),(0.1,1.01,2.4)),
      ("aces_rgc",(0.0,0.8,1.0),None),
      ("aces_rgc",(0.6,1.0,2.0),(0.2,1.0,2.2)),
      ("aces_rgc",(0.0,1.2,3.3),None),
      ("aces_rgc",(0.2,1.0,3.0),None),
    ]
    cases=[]
    for method,knee,lightness in settings:
        cfg=source.OutputGamutCompressSpec(
            algorithm=method,knee=knee,
            lightness_compression=lightness
        )
        for rgb in colours:
            sourceRGB=np.asarray(rgb,dtype=np.float64)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore",RuntimeWarning)
                answer=np.asarray(source.compress_rgb(
                    sourceRGB,cfg,output_color_space="sRGB"
                ),dtype=np.float64)
            assert answer.shape==(3,)
            assert np.isfinite(answer).all(),(rgb,knee,lightness)
            cases.append(dict(
                algorithm=method,knee=knee,light=lightness,
                rgb=rgb,answer=answer.tolist()
            ))
    assert len(cases)==126
    Path(dest).write_text(json.dumps(
        dict(cases=cases,sourceBlob=PIN),allow_nan=False,
        separators=(",",":")),encoding="utf8")
    print("PASS ORIGINAL 126 source full Float64 ACES/OFF cases "
          "from actual OutputGamutCompressSpec+compress_rgb; "
          "underblack, superwhite, six user knee conditions.")
if __name__=="__main__":
    main(sys.argv[1])
