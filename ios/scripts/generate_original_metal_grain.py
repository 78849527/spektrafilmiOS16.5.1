#!/usr/bin/env python3
"""Original Spektrafilm grain.py formulas + reflect-filter reference vectors.

All reference numbers originate from actual original 256x3x3 measured
density_curves_layers; cloud sigma uses source:
  od_particle = (maximum_layer + density_min*fraction)/n_particles_per_pixel
  sigma_dye_clouds = blur_dye_clouds_um*sqrt(od_particle)
  micro_sigma = 30 nm * 0.001 / pixel_um
  micro_blur = 0.2 um / pixel_um
Final source fast_gaussian_filter(0.65) is SciPy-reflect-equivalent.
"""
from __future__ import annotations
import json
from pathlib import Path
import numpy as np
from scipy.ndimage import gaussian_filter

ROOT=Path(__file__).resolve().parents[2]
PROFILES=ROOT/"src/spektrafilm/data/profiles"
DEST=ROOT/"ios/SpektraFilmPort/GeneratedOriginalMetalGrainReference.swift"

def values(a):
    return "["+",".join(format(float(v), ".17g") for v in np.ravel(a))+"]"

def main():
    result=[
        "// Original upstream density sublayers, source cloud and microstructure math.",
        "enum GeneratedOriginalMetalGrainReference {",
        "    struct Item {",
        "        let stock: String",
        "        let pixelUM: Double",
        "        let maxima: [Double]",
        "        let fractions: [Double]",
        "        let dyeSigmas: [Double]",
        "        let microSigma: Double",
        "        let microBlur: Double",
        "    }",
        "    static let samples: [Item] = [",
    ]
    count=0
    for stock in [
        "kodak_portra_400","kodak_vision3_250d",
        "fujifilm_provia_100f","fujifilm_velvia_100"
    ]:
        profile=json.loads((PROFILES/(stock+".json")).read_text())
        maxima=np.nanmax(
            np.asarray(profile["data"]["density_curves_layers"],np.float64),
            axis=0
        )
        assert maxima.shape==(3,3)
        fractions=maxima/np.sum(maxima,axis=0)[None,:]
        dMin=np.array([0.03,0.03,0.03])
        for pixelUM in [0.5,4.5,9.0]:
            n=(pixelUM**2)*fractions/(
                0.2*np.array([1.6,1.6,3.2])[None,:]*
                np.array([2.0,1.0,0.5])[:,None]
            )
            sourceD=maxima+dMin[None,:]*fractions
            cloud=np.sqrt(sourceD/n)
            microSigma=30*0.001/pixelUM
            microBlur=0.2/pixelUM
            assert np.all(cloud>0)
            result.extend([
                "        Item(",
                f"            stock: {json.dumps(stock)}, pixelUM: {pixelUM},",
                f"            maxima: {values(maxima)},",
                f"            fractions: {values(fractions)},",
                f"            dyeSigmas: {values(cloud)},",
                f"            microSigma: {format(microSigma,'.17g')},",
                f"            microBlur: {format(microBlur,'.17g')}",
                "        ),",
            ])
            count+=1
    result.append("    ]")
    # Impulse at first pixel; source 'reflect' boundary, truncate=3.0.
    # scipy's filter with 1D array has exactly the same boundary weights as
    # fast_gaussian_filter's _fir_2d_fused for a constant-y 2D image.
    impulse=np.zeros(11,np.float64)
    impulse[0]=1.0
    for sigma,name in [(0.65,"reflect065"),(1.2,"reflect120"),(0.2,"reflect020")]:
        result.append(
            f"    static let {name}: [Double] = " +
            values(gaussian_filter(impulse,sigma,mode="reflect",truncate=3.0))
        )
    impulse2d=np.zeros((7,11),np.float64)
    impulse2d[0,0]=1.0
    result.append(
        "    static let reflect2dCorner065: [Double] = " +
        values(gaussian_filter(impulse2d,0.65,mode="reflect",truncate=3.0))
    )
    result.append("}")
    DEST.write_text("\n".join(result)+"\n",encoding="utf-8")
    assert count==12
    print("PASS: 12 original measured 3x3 cloud vectors; micro activation threshold + reflect FIR reference.")


if __name__=="__main__":
    main()
