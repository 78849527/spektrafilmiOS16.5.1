#!/usr/bin/env python3
"""Extract EXACT original Swift source spatial FIR/YVV core for Linux parity.

The source file itself imports Core Image for a separate CI bridge, which
is unavailable on Linux. This extractor does not reimplement or edit the
production numerical implementation. It preserves the real source methods
from the original Swift file, up to the first CI bridge method. If source
layout changes, abort instead of testing a fabricated replacement.
"""
from pathlib import Path
import sys

source = Path("ios/SpektraFilmPort/SourceSpatialDIRConvolution.swift").read_text()
opening = "enum SourceSpatialDIRConvolution {"
ending = "    /// Convert the Core Image inhibitor buffer to Float32 RGBA only at"
assert source.count(opening) == 1, "Source enum identity changed"
assert source.count(ending) == 1, "CoreImage boundary changed"
body = source.split(opening,1)[1].split(ending,1)[0]
required = (
    "static func diffuseMemoryBounded(",
    "static func gaussianPerChannelMemoryBounded(",
    "static func exponentialPerChannelMemoryBounded(",
    "private static func reflect(",
    "private static func yvvCoefficients("
)
for fragment in required:
    assert fragment in body, f"Missing actual production algorithm: {fragment}"
assert "CIImage" not in body, "Source extraction included Core Image bridge"
target = Path(sys.argv[1] if len(sys.argv)>1 else "/tmp/SourceSpatialDoubleCore.swift")
target.write_text("import Foundation\n" + opening + body + "}\n")
print("PASS: extracted unchanged source FIR/YVV Double core", len(body), "characters")
