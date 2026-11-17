#!/usr/bin/env python3
"""P1 original RAW ACES source contract only; NOT RAW image numerical parity."""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = (root / "src/spektrafilm/utils/raw_file_processor.py").read_text()
bridge = (root / "ios/SpektraFilmPort/Build94LibRawBridge.mm").read_text()
header = (root / "ios/SpektraFilmPort/Build94LibRawBridge.h").read_text()
ingress = (root / "ios/SpektraFilmPort/P1OriginalRawACESIngress.swift").read_text()

for token in (
    "'output_color': getattr(rawpy, 'ColorSpace').ACES",
    "'output_bps': 16",
    "'no_auto_bright': True",
    "'gamma': (1, 1)",
    "params['use_camera_wb'] = True",
    "astype(np.float32) / np.float32(65535.0)",
):
    assert token in source, f"Python RAW source contract changed: {token}"

for token in (
    "sourceLinearACES ? 6 : 1",
    "raw->params.gamm[0] = 1.0",
    "raw->params.gamm[1] = 1.0",
    "raw->params.use_camera_wb = 1",
    "libraw_set_no_auto_bright(raw, 1)",
    "libraw_set_output_bps(raw, (int)bits)",
    "if (sourceLinearACES && bits != 16)",
    "sourceLinearACES:NO",
):
    assert token in bridge, f"iOS LibRaw source contract missing: {token}"
assert "decode(_:bitsPerComponent:sourceLinearACES:)" in header
assert "Float(sample) / Float(65535.0)" in ingress
assert "Build79RAWSignature.probeFile(url)" in ingress
assert "JPEG" in ingress
assert "sourceCCTFEncoded = false" in ingress
assert "ACES2065-1" in ingress

print("PASS P1 source/LibRaw parameter contract; real RAW parity and device ingress NOT CERTIFIED")
