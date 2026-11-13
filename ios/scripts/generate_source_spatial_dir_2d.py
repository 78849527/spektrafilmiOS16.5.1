#!/usr/bin/env python3
"""Run actual upstream Python spatial DIR 2D kernels, not scipy substitute.

The reference generator IMPORTS the original fast_gaussian_filter module,
injects its two real FIR/YVV/exponential functions into the already-loaded
model/couplers.py, then invokes the original source
compute_exposure_correction_dir_couplers() on nonuniform 2D film arrays.
This covers original FIR small sigma, YVV IIR large sigma, reflect borders,
positive (silver=dmax-density), donor->receiver inhibition and 3-Gaussian
tail. No grain/RAW or end-to-end full-size pixel equality is inferred.
"""
import json
import numpy as np

from generate_source_film_dir_print_chain import ROOT, upstream_film, load_original_module
from generate_dir import PROFILES, matrix

OUTPUT=ROOT/"ios/SpektraFilmPort/GeneratedSourceSpatialDIR2D.swift"

def nums(data):
    return "["+",".join(format(float(v),".17g") for v in np.asarray(data).ravel())+"]"

def main():
    density_mod,couplers,_=upstream_film()
    gaussian=load_original_module(
        "spektrafilm.utils.fast_gaussian_filter",
        ROOT/"src/spektrafilm/utils/fast_gaussian_filter.py"
    )
    couplers.fast_gaussian_filter=gaussian.fast_gaussian_filter
    couplers.fast_exponential_filter=gaussian.fast_exponential_filter
    cfg=[
        ("kodak_portra_400",False,40.,.06,1.0),
        ("fujifilm_provia_100f",True,50.,.06,1.0),
        ("kodak_portra_400",False,90.,.15,1.1),
    ]
    h,w=11,13
    rows=[
        "// ACTUAL source model/couplers.py spatial DIR via source Numba FIR/YVV",
        "// fast_gaussian_filter.py, positive reversals and reflect boundaries.",
        "// Test-image RGB is already normalized film log exposure and density;",
        "// identity CI cubes are used to independently test the native bridge.",
        "enum GeneratedSourceSpatialDIR2D {",
        "  struct Case {",
        "    let film: String",
        "    let positive: Bool",
        "    let width: Int",
        "    let height: Int",
        "    let pixelUM: Double",
        "    let radiusScale: Double",
        "    let tailWeight: Double",
        "    let matrix: [Double]",
        "    let densityMaximum: [Double]",
        "    let input: [Double]",
        "    let sourceInhibitors: [Double]",
        "    let sourceDiffused: [Double]",
        "    let sourceCorrected: [Double]",
        "    let sourceNormalizedDisplay: [Double]",
        "  }",
        "  static let samples: [Case] = [",
    ]
    for film,positive,px,weight,scale in cfg:
        doc=json.loads((PROFILES/(film+".json")).read_text())
        dc=np.asarray(doc["data"]["density_curves"],dtype=np.float64)
        normalized=dc-np.min(dc,axis=0)
        dmax=normalized.max(axis=0)
        M=matrix(film,positive)
        grid=np.empty((h,w,3),dtype=np.float64)
        for y in range(h):
            for x in range(w):
                grid[y,x]=[
                    .22+.34*(x/(w-1))+.12*(y/(h-1)),
                    .25+.23*(y/(h-1))+.07*((x+y)%5)/5,
                    .17+.35*(((3*x+2*y)%19)/18),
                ]
        if not positive:
            silver=grid
        else:
            silver=dmax-grid
        inhibitor=silver@M
        coreSigma=20.*scale/px
        tailSigma=200.*scale/px
        # Source actual convolution and routing — call the original coupler.
        corrected=couplers.compute_exposure_correction_dir_couplers(
            grid,grid,dmax,M,
            coreSigma,tailSigma,weight,positive=positive
        )
        diffused=grid-corrected
        # Identity source raw/density/print colorCube; CI subtracts
        # native log10 inhibitor from identity cube normalized by span 2.
        normalized_display=np.clip(grid-diffused/2.0,0,1)
        # Check source filters independently in the same order as original:
        direct=(1-weight)*gaussian.fast_gaussian_filter(inhibitor,coreSigma)
        direct+=weight*gaussian.fast_exponential_filter(inhibitor,tailSigma)
        assert np.max(np.abs(direct-diffused))<1e-10
        for value in (grid,corrected,diffused,normalized_display):
            assert np.isfinite(value).all()
        rows.extend([
            "    Case(",
            f'      film:{json.dumps(film)},positive:{str(positive).lower()},',
            f'      width:{w},height:{h},pixelUM:{px},',
            f'      radiusScale:{scale},tailWeight:{weight},',
            f'      matrix:{nums(M)},densityMaximum:{nums(dmax)},',
            f'      input:{nums(grid)},',
            f'      sourceInhibitors:{nums(inhibitor)},',
            f'      sourceDiffused:{nums(diffused)},',
            f'      sourceCorrected:{nums(corrected)},',
            f'      sourceNormalizedDisplay:{nums(normalized_display)}',
            "    ),",
        ])
    rows+=["  ]","}"]
    OUTPUT.write_text("\n".join(rows)+"\n",encoding="utf-8")
    assert len(cfg)==3
    print(f"PASS: {len(cfg)} ACTUAL upstream 2D DIR NumPy/Numba spatial fields "
          f"x {h*w*3} sample values, FIR (<3) + YVV IIR (>=3), "
          "reflect borders, reversal inhibitors, exponential Gaussian mixture")


if __name__=="__main__":
    main()
