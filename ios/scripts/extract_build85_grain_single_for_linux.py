#!/usr/bin/env python3
"""Extract unchanged production grain Settings + applySingleLayer for Linux.
Exclude the separate Metal-only microstructure validation type. Do not
rewrite any math or stochastic source, and abort on layout changes.
"""
from pathlib import Path
import sys

src=Path("ios/SpektraFilmPort/OriginalSourcePhysicalGrain.swift").read_text()
opening="enum OriginalSourcePhysicalGrain {"
settings="    struct Settings {"
boundary="    /// For parent pre-decode safety budget."
single="    /// Source grain.py::apply_grain_to_density, selected when"
for marker in (opening,settings,boundary,single):
    assert src.count(marker)==1, "production grain layout drift: "+marker
header=src.split(opening,1)[1].split(settings,1)[0]
settings_body=src.split(settings,1)[1].split(boundary,1)[0]
single_body=src.split(single,1)[1].rsplit("\n}",1)[0]
assert "OriginalSourceSciPySampler.drawLayer" in single_body
assert "SourceSpatialDIRConvolution.diffuseMemoryBounded" in single_body
assert "applySingleLayer" in single_body and "numbaSeed" in settings_body
output=(
    "import Foundation\n"+opening+
    header+settings+settings_body+
    single+single_body+"\n}\n"
)
dest=Path(sys.argv[1])
dest.write_text(output)
print("PASS: extracted unmodified original single-layer grain + settings, "
      "bytes",len(output))
