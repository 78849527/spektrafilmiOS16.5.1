#!/usr/bin/env python3
"""P1 ACES/CAT16 source dispatch audit; NOT numerical equivalence."""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
def src(path): return (root / path).read_text()
gen=src('ios/scripts/generate_hanatos.py')
han=src('ios/SpektraFilmPort/OriginalHanatosResponse.swift')
physics=src('ios/SpektraFilmPort/SpectralPhysics.swift')
phys=src('ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift')
original=src('src/spektrafilm/utils/spectral_upsampling.py')
assert "chromatic_adaptation_transform='CAT16'" in original
assert 'colourspace="ACES2065-1"' in gen
assert 'aces_matrices[info["stock"]]=aces' in gen
assert 'acesRGBToXYZByFilm' in gen and 'acesRGBToXYZByFilm' in han
assert 'case acesLinear' in han
assert physics.count('case .proPhotoLinear, .acesLinear: linear=encodedRGB')==2
assert 'cameraInputColorSpace != .sRGB' in phys
print('PASS P1 ACES source contract; numerical/demosaic/iOS compile NOT RUN')
