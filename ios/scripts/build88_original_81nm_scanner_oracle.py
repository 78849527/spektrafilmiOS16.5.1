#!/usr/bin/env python3
"""Real original ScanningStage 81-wavelength spectral XYZ + RGB + CCTF.

Four genuine source positive films (no enlarger), all eight real paper
stocks (already-developed density), each at four H-D-derived densities.
The source functions are original untouched AST, with stock SHA pins.
Original scan log10(max(XYZ,0)+1e-10) is NOT simplified away.
"""
import hashlib,json
from pathlib import Path
import sys
import colour
import numpy as np
from opt_einsum import contract
from generate_source_rgb_parity import (
    ROOT,PROFILES,STANDARD_OBSERVER_CMFS,original_functions
)

SRC_PINS={
    "src/spektrafilm/config.py":"3478508cf0a9426cb67294dd33dcbff39e9feec7",
    "src/spektrafilm/runtime/stages/scanning.py":"9e4303e39b8c1d8b048bbc03ed27fb7a93eb7de1",
    "src/spektrafilm/model/develop.py":"938ff7045c87ca77c0182f7608b66093ae87f421",
    "src/spektrafilm/model/illuminants.py":"5feacaec729f371eea48ea5e69da3291bcf7123e",
    "src/spektrafilm/utils/conversions.py":"2ca9cfc6138278a9fb8c32c0ca191e384b2cff6e",
    "src/spektrafilm/utils/gamut_compression.py":"9783e7fcfc2909c4acdf2da53595c5404645dde9"
}
PROFILES_PIN={
    "fujifilm_crystal_archive_typeii":"ff172170a5d6ef8095eabda99ccc6f111fe7ea2f",
    "kodak_2383":"f587b79bf4d3a599ee13989012f9cced02259495",
    "kodak_2393":"54adf037ba24c9ba22e23bc983fc1c539c935f48",
    "kodak_ektacolor_edge":"34a39e2a108b6c2a72b9e48d9c2f13ba351e473f",
    "kodak_endura_premier":"8f849d820176f8f90f1d66ceed339acd333c3a7c",
    "kodak_portra_endura":"2f007f0ff276da104c4ca1fcb9f355558e64fb9a",
    "kodak_supra_endura":"ba63b1788fd2794b890856866355c166761fbdf1",
    "kodak_ultra_endura":"a207c74b4f9a7502935cae80b87d579b3c54ba8b",
    "fujifilm_provia_100f":"ae08afb23dcc2a46507ef43e34cbf896b3303319",
    "fujifilm_velvia_100":"cbea6d15cae3ac19c1eff9d91da5490cadd49f39",
    "kodak_ektachrome_100":"8d187efca11b985fc54b56c8f9cb643ba523ccf0",
    "kodak_kodachrome_64":"31f58cb1b6011ebb3fbbb65415a4eedefc5ebf7f"
}

def sha(path):
    data=path.read_bytes()
    return hashlib.sha1(
        b"blob "+str(len(data)).encode()+b"\0"+data
    ).hexdigest()

def main(dest):
    for path,blob in SRC_PINS.items():
        assert sha(ROOT/path)==blob,"SOURCE CODE DRIFT "+path
    fn=original_functions()
    observer=np.asarray(STANDARD_OBSERVER_CMFS[:],dtype=np.float64)
    assert observer.shape==(81,3)
    cases=[]
    for stock,blob in PROFILES_PIN.items():
        profile_path=PROFILES/(stock+".json")
        assert sha(profile_path)==blob,"PROFILE DRIFT "+stock
        profile=json.loads(profile_path.read_text(encoding="utf8"))
        data=profile["data"]
        info=profile["info"]
        assert (info["stage"]=="printing" or
                info["type"]=="positive"),stock
        base=np.asarray(data["base_density"],dtype=np.float64)
        dye=np.asarray(data["channel_density"],dtype=np.float64)
        illum=np.asarray(fn["standard_illuminant"](
            info["viewing_illuminant"]
        ),dtype=np.float64)
        assert base.shape==(81,) and dye.shape==(81,3)
        assert illum.shape==(81,)
        valid=np.isfinite(base)&np.isfinite(dye).all(axis=1)
        assert valid.sum()>45,(stock,valid.sum())
        weights=illum[:,None]*observer
        normalization=float(np.dot(illum,observer[:,1]))
        assert normalization>0 and np.isfinite(normalization)
        maxima=np.nanmax(np.asarray(
            data["density_curves"],dtype=np.float64
        ),axis=0)
        minima=np.nanmin(np.asarray(
            data["density_curves"],dtype=np.float64
        ),axis=0)
        densities=np.asarray([
            minima-0.03,
            minima+0.18*(maxima-minima),
            minima+0.57*(maxima-minima),
            maxima+0.01,
        ],dtype=np.float64)
        spectral=fn["compute_density_spectral"](
            dye,densities[None,:,:],base_density=base
        )
        light=fn["density_to_light"](spectral,illum)
        xyz_raw=contract("ijk,kl->ijl",light,observer)/normalization
        # Never algebraically omit the original log_xyz then 10** step.
        xyz=10.0**np.log10(np.fmax(xyz_raw,0.0)+1e-10)
        illum_xyz=contract("k,kl->l",illum,observer)/normalization
        viewing_xy=colour.XYZ_to_xy(illum_xyz)
        linear=colour.XYZ_to_RGB(
            xyz,colourspace="sRGB",illuminant=viewing_xy,
            apply_cctf_encoding=False
        )
        compressed=fn["compress_rgb_aces_rgc"](
            linear,threshold=0.0,limit=1.0,power=6.0
        )
        encoded=colour.RGB_to_RGB(
            compressed,"sRGB","sRGB",
            apply_cctf_decoding=False,apply_cctf_encoding=True
        )
        for i in range(4):
            assert np.isfinite(xyz[0,i,:]).all()
            assert np.isfinite(compressed[0,i,:]).all()
            assert np.isfinite(encoded[0,i,:]).all()
            cases.append(dict(
                stock=stock,
                medium=info["stage"],
                viewing=info["viewing_illuminant"],
                density=densities[i].tolist(),
                valid=valid.tolist(),
                base=np.where(valid,base,0.0).tolist(),
                dye=np.where(valid[:,None],dye,0.0).reshape(-1).tolist(),
                weighted=weights.reshape(-1).tolist(),
                normalization=normalization,
                sourceXYZ=xyz[0,i,:].tolist(),
                sourceLinear=linear[0,i,:].tolist(),
                sourceCompressed=compressed[0,i,:].tolist(),
                sourceCCTF=encoded[0,i,:].tolist()
            ))
    assert len(cases)==48
    Path(dest).write_text(json.dumps(dict(
        cases=cases,pins=SRC_PINS,profiles=PROFILES_PIN,
        scope="Python original ScanningStage spectral source+Colour science "
        "for 8 papers and 4 positive films; no full RAW/film/grain/print"
    ),separators=(",",":"),allow_nan=False),encoding="utf8")
    print("ORIGINAL SCANNER 81nm SOURCE PASS: 12 measured film/paper " +
          "profiles × 4 density levels = 48 source XYZ→linear→ACES→CCTF "
          "vectors with actual original wavelength masks + log epsilon.")

if __name__=="__main__":
    main(sys.argv[1])
