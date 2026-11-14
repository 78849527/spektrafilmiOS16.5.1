#!/usr/bin/env python3
"""Generate original stock-specific film halation baselines (Build77/03).

Reads unchanged Python source AST + ALL 28 original JSON profile identities.
Does NOT invent a mobile halation preset. Output is a real production Swift
table, regenerated before Xcode and independently compared with Python's
digest_params actual 360-case output. No algorithm reference update.
"""
from __future__ import annotations

import ast
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "src/spektrafilm/runtime/params_builder.py"
SCHEMA = ROOT / "src/spektrafilm/runtime/params_schema.py"
PROFILES = ROOT / "src/spektrafilm/data/profiles"
DEST = ROOT / "ios/SpektraFilmPort/GeneratedBuild77StockHalationSource.swift"


def source_literal(path: Path, target: str, class_name: str | None = None):
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    body = tree.body
    if class_name is not None:
        matches = [x for x in body if isinstance(x, ast.ClassDef)
                   and x.name == class_name]
        assert len(matches) == 1, (path, class_name)
        body = matches[0].body
    matches = [x for x in body if isinstance(x, ast.AnnAssign)
               and isinstance(x.target, ast.Name)
               and x.target.id == target]
    assert len(matches) == 1, (path, class_name, target)
    return ast.literal_eval(matches[0].value)


def main() -> None:
    preset = source_literal(BUILDER, "_HALATION_PRESETS")
    default_sigma = source_literal(
        SCHEMA, "halation_first_sigma_um", "HalationParams"
    )
    default_strength = source_literal(
        SCHEMA, "halation_strength", "HalationParams"
    )
    assert len(default_sigma) == len(default_strength) == 3
    lines = [
        "// GENERATED, DO NOT HAND-EDIT. Source: locked original Python",
        "// runtime/params_builder.py:_HALATION_PRESETS,",
        "// runtime/params_schema.py:HalationParams and JSON profile info.",
        "// This is used ONLY by the opt-in source-physical production mode.",
        "enum GeneratedBuild77StockHalationSource {",
        "    static let records:[String:Build77StockHalation.Record] = [",
    ]
    films, papers, coverage = 0, 0, 0
    for path in sorted(PROFILES.glob("*.json")):
        info = json.loads(path.read_text(encoding="utf-8"))["info"]
        if info["stage"] == "printing":
            papers += 1
            continue
        assert info["stage"] == "filming", path
        films += 1
        stock = info["stock"]
        use = info["use"]
        ah = info["antihalation"]
        assert stock == path.stem
        lookup = preset.get((use, ah)) if info["support"] == "film" else None
        sigma = lookup["sigma_h"] if lookup is not None else default_sigma
        strength = lookup["strength"] if lookup is not None else default_strength
        if lookup is not None:
            coverage += 1
        assert len(sigma) == len(strength) == 3
        assert all(float(x) >= 0 for x in (*sigma, *strength))
        def values(row):
            return "[" + ",".join(repr(float(v)) for v in row) + "]"
        lines.append(
            f"        {json.dumps(stock)}: .init("
            f"sigmaUM:{values(sigma)},strength:{values(strength)},"
            f"sourceUse:{json.dumps(use)},"
            f"sourceAntihalation:{json.dumps(ah)},"
            f"hasStockPreset:{str(lookup is not None).lower()}),"
        )
    assert films == 20 and papers == 8, (films, papers)
    lines += ["    ]", "}"]
    DEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("Build77 original Python source stock halation:",
          films, "filming stocks,", papers, "print profiles,",
          coverage, "specific presets; no Swift fallback")


if __name__ == "__main__":
    main()
