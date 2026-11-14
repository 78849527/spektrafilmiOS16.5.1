#!/usr/bin/env python3
"""Build77 01-05: pinned upstream provenance, topology and stage-tap evidence.

This is a VALIDATION HARNESS, not a claim that every iOS stage is implemented.
Only 'verify' uses the standard library. The optional tape commands need
the upstream Python runtime / NumPy, and do not modify its algorithm.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import math
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM_SHA = "3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"
IOS_BASE_SHA = "f00383059882efe9b9a09151898b5dadaa2906f9"
SOURCE_TREE_SHA = "9f0e2510d5af46b51eabd8096ae9bb1591ea81c9"
PROFILES_TREE_SHA = "fa9262d2440903262dd302b52739162c939e153e"
PYPROJECT_BLOB_SHA = "eb782eb444bdd76f34b645511039dec2fd9185d5"
TOPOLOGY = {
    "negative_print": [
        ("rgb_in", "rgb_pre", "preprocess"),
        ("rgb_pre", "log_e_film", "filming.expose"),
        ("log_e_film", "cmy_film", "filming.develop"),
        ("cmy_film", "log_e_print", "printing.expose"),
        ("log_e_print", "cmy_print", "printing.develop"),
        ("cmy_print", "rgb_out", "scanning.scan_print"),
    ],
    "direct_scan": [
        ("rgb_in", "rgb_pre", "preprocess"),
        ("rgb_pre", "log_e_film", "filming.expose"),
        ("log_e_film", "cmy_film", "filming.develop"),
        ("cmy_film", "rgb_out", "scanning.scan_film"),
    ],
}
SOURCE_STAGES = {
    "rgb_in": "Python caller input; iOS OriginalSourcePixelIO.decode",
    "rgb_pre": "Python SimulationPipeline._preprocess; iOS input/autoEV/resize audit pending",
    "log_e_film": "Python FilmingStage.expose; iOS OriginalSourcePhysicalImage camera photons/log exposure",
    "cmy_film": "Python FilmingStage.develop; iOS OriginalSourcePhysicalImage film density/grass/grain",
    "log_e_print": "Python PrintingStage.expose; iOS OriginalSourcePhysicalImage paper photon/diffusion",
    "cmy_print": "Python PrintingStage.develop; iOS OriginalSourcePhysicalImage paper HD",
    "rgb_out": "Python ScanningStage.scan; iOS OriginalSourcePhysicalImage scanner XYZ/RGB",
}
EXPECTED_STOCK_COUNT = {"filming": 20, "printing": 8}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def git_object(refpath: str) -> str:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD:" + refpath],
        cwd=ROOT, capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def source(filename: str) -> str:
    return (ROOT / "src" / "spektrafilm" / filename).read_text(encoding="utf-8")


def named_calls(tree: ast.AST, name: str) -> list[ast.Call]:
    return [
        n for n in ast.walk(tree)
        if isinstance(n, ast.Call)
        and isinstance(n.func, ast.Name)
        and n.func.id == name
    ]


def extract_topology() -> list[tuple[str, str, str]]:
    tree = ast.parse(source("runtime/pipeline.py"))
    triples = []
    for n in named_calls(tree, "Node"):
        if len(n.args) < 4:
            raise ValueError("Python Node arguments changed")
        reads = n.args[0]
        writes = n.args[1]
        require(isinstance(reads, ast.Tuple) and len(reads.elts) == 1,
                "Unexpected multi-read topology node")
        require(isinstance(writes, ast.Tuple) and len(writes.elts) == 1,
                "Unexpected multi-write topology node")
        read = reads.elts[0]
        write = writes.elts[0]
        require(isinstance(read, ast.Attribute) and isinstance(read.value, ast.Name)
                and read.value.id == "Tap", "Unexpected input tap")
        require(isinstance(write, ast.Attribute) and isinstance(write.value, ast.Name)
                and write.value.id == "Tap", "Unexpected output tap")
        label = ast.literal_eval(n.args[3])
        triples.append((read.attr.lower(), write.attr.lower(), label))
    return triples


def extract_defaults() -> dict:
    tree = ast.parse(source("runtime/params_schema.py"))
    defaults = {}
    for cls in tree.body:
        if not isinstance(cls, ast.ClassDef):
            continue
        if not any(isinstance(d, ast.Name) and d.id == "dataclass"
                   for d in cls.decorator_list):
            continue
        row = {}
        for f in cls.body:
            if not isinstance(f, ast.AnnAssign) or not isinstance(f.target, ast.Name):
                continue
            if f.value is None:
                value = "<required>"
            else:
                try:
                    value = ast.literal_eval(f.value)
                except (ValueError, TypeError, SyntaxError, MemoryError):
                    value = {"source_expression": ast.unparse(f.value)}
            row[f.target.id] = value
        defaults[cls.name] = row
    require("RuntimePhotoParams" in defaults, "RuntimePhotoParams missing")
    require(defaults["SettingsParams"]["use_fast_stats"] is False,
            "Original source stochastic default changed")
    return defaults


def validate_profiles() -> tuple[list[dict], dict[str, int]]:
    profiles = sorted((ROOT / "src/spektrafilm/data/profiles").glob("*.json"))
    require(len(profiles) == 28, f"Expected 28 profiles, got {len(profiles)}")
    manifest = []
    stages = {"filming": 0, "printing": 0}
    ids = set()
    for path in profiles:
        raw = path.read_bytes()
        doc = json.loads(raw)
        info, data, metadata = doc["info"], doc["data"], doc["metadata"]
        stock = info["stock"]
        require(stock == path.stem, f"{path.name} stock mismatch")
        require(stock not in ids, f"duplicate stock: {stock}")
        ids.add(stock)
        stage = info["stage"]
        require(stage in stages, f"{stock} unknown stage {stage}")
        stages[stage] += 1
        waves = data["wavelengths"]
        require(len(waves) == 81, f"{stock} not 81 wavelengths")
        require(all(isinstance(w, (int, float)) and not isinstance(w, bool)
                    for w in waves), f"{stock} nonnumeric wavelengths")
        require(all(waves[i] < waves[i + 1] for i in range(80)),
                f"{stock} nonmonotone wavelength axis")
        for key in ("log_sensitivity", "channel_density"):
            a = data[key]
            require(len(a) == 81 and all(isinstance(row, list) and len(row) == 3
                                          for row in a),
                    f"{stock} {key} is not 81x3")
        require(len(data["base_density"]) == 81,
                f"{stock} base_density not 81")
        require(len(data["log_exposure"]) == 256,
                f"{stock} log_exposure not 256")
        require(len(data["density_curves"]) == 256 and
                all(len(row) == 3 for row in data["density_curves"]),
                f"{stock} density_curves not 256x3")
        # A JSON null is a deliberate unmeasured sample; do not replace with 0.
        for key in ("log_sensitivity", "channel_density", "density_curves"):
            for row in data[key]:
                for value in row:
                    require(value is None or (
                        isinstance(value, (int, float))
                        and not isinstance(value, bool)
                        and math.isfinite(value)
                    ), f"{stock} invalid sample in {key}")
        require(metadata.get("license") and metadata.get("datasource"),
                f"{stock} missing upstream licensing / data attribution")
        git_blob = hashlib.sha1(
            b"blob " + str(len(raw)).encode() + b"\0" + raw
        ).hexdigest()
        manifest.append({
            "stock": stock, "stage": stage, "git_blob": git_blob,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "license": metadata["license"],
            "source": metadata["datasource"],
            "wavelengths": [waves[0], waves[-1], len(waves)],
            "profile_version": metadata["version"],
            "target_print": info.get("target_print"),
        })
    require(stages == EXPECTED_STOCK_COUNT,
            f"Expected 20+8 profile types, got {stages}")
    for m in manifest:
        if m["target_print"] is not None:
            require(m["target_print"] in ids, "Missing target print: " + m["stock"])
    return manifest, stages


def verify() -> dict:
    # Git tree pin includes ALL Python source and package resources: 28 stock
    # files, filters, ICC, measured spectra, LUTs and licensing text.
    for path, expected in (
        ("src/spektrafilm", SOURCE_TREE_SHA),
        ("src/spektrafilm/data/profiles", PROFILES_TREE_SHA),
        ("pyproject.toml", PYPROJECT_BLOB_SHA),
    ):
        actual = git_object(path)
        require(actual == expected,
                f"UPSTREAM SOURCE DRIFT: {path}: {actual} != {expected}")
    observed = extract_topology()
    expected_nodes = sorted(set(TOPOLOGY["negative_print"] +
                                TOPOLOGY["direct_scan"]))
    require(sorted(observed) == expected_nodes,
            "Topology changed; update explicit branch mapping after source audit")
    pipeline = source("runtime/pipeline.py")
    require("if self.io.scan_film:" in pipeline,
            "Direct film scan branch missing from original topology")
    defaults = extract_defaults()
    profiles, stages = validate_profiles()
    import tomllib
    project = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    return {
        "status": "SOURCE_CONTRACT_ONLY_NOT_IOS_NUMERIC_PARITY",
        "upstream_sha": UPSTREAM_SHA,
        "ios_baseline_sha": IOS_BASE_SHA,
        "source_tree_sha": SOURCE_TREE_SHA,
        "pyproject_blob_sha": PYPROJECT_BLOB_SHA,
        "python_requires": project["project"]["requires-python"],
        "python_dependencies": project["project"]["dependencies"],
        "parameter_defaults_from_source_ast": defaults,
        "topology": TOPOLOGY,
        "stage_mapping": SOURCE_STAGES,
        "profiles": profiles,
        "counts": stages,
        "unverified": [
            "Swift UI to source RuntimePhotoParams binding completeness",
            "Swift per-tap byte/Float64 numerical equivalence",
            "All Python stock-specific digest/neutral-filter branches",
            "Unseeded multithread random equivalence",
            "Full iPhoneOS and device acceptance",
        ],
    }


def emit_taps(args: argparse.Namespace) -> None:
    # Dependency-heavy: run ONLY with the pinned Python runtime installed.
    # Crucially use one topology invocation, so random states are not reset
    # by rerunning the whole pipeline separately for each requested tap.
    import numpy as np
    from spektrafilm.runtime.params_builder import init_params, digest_params
    from spektrafilm.runtime.pipeline import SimulationPipeline

    image = np.load(args.input, allow_pickle=False)
    require(image.ndim == 3 and image.shape[2] >= 3,
            "Input must be HxWx3+ .npy")
    require(image.dtype.kind in "fiu", "Input must be numeric")
    params = init_params(film_profile=args.film, print_profile=args.paper)
    params.io.scan_film = args.scan_film
    if args.oneshot_controlled:
        # This is a CONTROLLED source mode for all-at-once device comparison,
        # not original DEFAULT mode. All functions below are original Python.
        from dataclasses import replace
        params.io.input_color_space = "sRGB"
        params.io.input_cctf_decoding = True
        params.io.crop = False
        params.io.upscale_factor = 1.0
        params.io.output_gamut_compress = replace(
            params.io.output_gamut_compress, algorithm="aces_rgc")
        params.camera.auto_exposure = False
        params.film_render.grain.active = False
        params.film_render.halation.active = False
        params.film_render.glare.active = False
        params.print_render.glare.active = False
        params.scanner.unsharp_mask = (0.0, 0.0)
        params.enlarger.normalize_print_exposure = False
        params.enlarger.print_exposure_compensation = False
        params.settings.use_fast_stats = False
    if args.print_diffusion:
        require(not args.scan_film,
                "Paper diffusion cannot be tested on a direct film scan")
        # Exact upstream PrintingStage.expose branch. These are the
        # source's OWN settings; we do not substitute any iOS algorithm.
        params.enlarger.diffusion_filter.active = True
    params = digest_params(params)
    pipeline = SimulationPipeline(params)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    state = {"rgb_in": image}
    rows = {}
    start = time.perf_counter()
    def capture(name: str, elapsed: float) -> None:
        a = np.ascontiguousarray(state[name], dtype="<f8")
        payload = a.tobytes(order="C")
        np.save(output / (name + ".npy"), a, allow_pickle=False)
        rows[name] = {
            "shape": list(a.shape), "dtype": "<f8",
            "data_sha256": hashlib.sha256(payload).hexdigest(),
            "mae": None, "rmse": None, "max_abs": None,
            "elapsed_s_since_previous_tap": elapsed,
            "finite_count": int(np.isfinite(a).sum()),
            "nonfinite_count": int((~np.isfinite(a)).sum()),
        }
    capture("rgb_in", 0.0)
    for node in pipeline._topology:
        if all(r in state for r in node.reads):
            tick = time.perf_counter()
            node.fire(state)
            capture(node.writes[0], time.perf_counter() - tick)
    manifest = {
        "source_sha": UPSTREAM_SHA,
        "mode": ("PYTHON_SOURCE_CONTROLLED_BUILD77_ONESHOT"
                 if args.oneshot_controlled
                 else "PYTHON_SOURCE_DEFAULT_RNG_NO_FIXED_SEED"),
        "controlled_switches": {
            "input_color_space": "sRGB",
            "input_cctf_decoding": True,
            "camera_auto_exposure": False,
            "film_grain": False,
            "film_halation": False,
            "scanner_glare": False,
            "scan_unsharp_mask": [0, 0],
            "output_gamut_algorithm": "aces_rgc",
        } if args.oneshot_controlled else None,
        "scan_film": args.scan_film,
        "print_diffusion": args.print_diffusion,
        "film": args.film, "print": args.paper,
        "taps": rows, "total_seconds": time.perf_counter() - start,
        "note": "Separate tap file dumps are not proof of iOS parity.",
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8")
    print(json.dumps({
        "saved_taps": list(rows), "seconds": manifest["total_seconds"],
        "out": str(output),
    }, ensure_ascii=False))


def compare_taps(args: argparse.Namespace) -> None:
    import numpy as np
    refdir, iosdir = Path(args.reference), Path(args.candidate)
    reference = json.loads((refdir / "manifest.json").read_text())
    require(reference["source_sha"] == UPSTREAM_SHA,
            "Reference does not match locked Python source")
    # A real iOS capture labels files by its ACTUAL production observer,
    # not the original Python stage names. Optional mapping MUST have been
    # emitted by the strict Swift recorder, never inferred from file names.
    alias = {}
    observed_by_name = {}
    if args.candidate_mapping:
        manifest_file = iosdir / "candidate-source-tap-mapping.json"
        mapping_report = json.loads(manifest_file.read_text())
        require(mapping_report["status"] ==
                "IOS_CANDIDATE_MAPPING_NOT_PYTHON_NUMERIC_PARITY",
                "Candidate map must be the real unverified Swift recorder output")
        require(mapping_report["numerically_certified"] is False,
                "Mapping is not independent parity evidence")
        require(mapping_report["source_sha"] == UPSTREAM_SHA,
                "Candidate tap mapping has a different upstream source")
        branch = "direct_scan" if reference["scan_film"] else "negative_print"
        require(mapping_report["film_branch"] == branch,
                "Candidate/true-original Python routing differs")
        require(mapping_report["float_storage"] == "<f8",
                "Candidate mapping must preserve exact Float64 payloads")
        require(mapping_report["width"] > 0 and mapping_report["height"] > 0,
                "Invalid captured iOS pixel dimensions")
        alias = mapping_report["source_to_ios_actual_observer"]
        require(set(alias) == set(reference["taps"]),
                "Source candidate tap names must match the real Python topology")
        require(len(set(alias.values())) == len(alias),
                "Candidate source taps cannot alias one observer twice")
        require(mapping_report["source_tap_order"] ==
                list(reference["taps"]), "Candidate source tap order differs")
        manifest = json.loads((iosdir / "manifest.json").read_text())
        require(manifest["status"] == "IOS_INTERNAL_DIAGNOSTIC_NOT_PYTHON_TAP_PARITY",
                "Candidate must carry actual Swift recorder NPY metadata")
        observed_by_name = {row["name"]: row for row in manifest["observations"]}
    records = {}
    for tap in reference["taps"]:
        observed_name = alias.get(tap, tap)
        require(isinstance(observed_name, str)
                and len(observed_name) <= 100 and observed_name
                and all(ch.isascii() and (ch.isalnum() or ch in "-_")
                        for ch in observed_name),
                f"Unsafe iOS callback file name for source stage {tap}")
        path = iosdir / (observed_name + ".npy")
        require(path.is_file(), f"Missing iOS stage: {tap} / {observed_name}")
        if args.candidate_mapping:
            require(observed_name in observed_by_name,
                    f"Swift observer manifest omits: {observed_name}")
            row = observed_by_name[observed_name]
            require(row["dtype"] == "<f8", f"{tap} Swift stage is not Float64")
            require(row["shape"] == reference["taps"][tap]["shape"],
                    f"{tap} Swift stage shape differs")
            require(row["bytes"] == path.stat().st_size,
                    f"{tap} candidate NPY length differs from Swift manifest")
            if "file_sha256" in row:
                require(hashlib.sha256(path.read_bytes()).hexdigest()
                        == row["file_sha256"],
                        f"{tap} actual Swift .npy payload SHA256 mismatch")
        ref = np.load(refdir / (tap + ".npy"), allow_pickle=False)
        got = np.load(path, allow_pickle=False)
        # STRICT: a Float32 candidate must not be accepted via implicit
        # upcast, even if it happens to fall inside an absolute tolerance.
        require(ref.dtype == np.dtype("<f8") and got.dtype == np.dtype("<f8"),
                f"{tap} requires original little-endian Float64, not {got.dtype}")
        require(ref.shape == got.shape, f"{tap} dimensions differ")
        require(hashlib.sha256(np.ascontiguousarray(ref).tobytes()).hexdigest()
                == reference["taps"][tap]["data_sha256"],
                f"{tap} reference payload SHA256 mismatch")
        for kind, classify in (
            ("finite", np.isfinite), ("NaN", np.isnan),
            ("+Infinity", np.isposinf), ("-Infinity", np.isneginf),
        ):
            require(np.array_equal(classify(ref), classify(got)),
                    f"{tap} {kind} mask differs")
        mismatch = np.isfinite(ref)
        d = np.abs(ref[mismatch] - got[mismatch])
        mae = float(d.mean()) if d.size else 0.0
        rmse = float(np.sqrt(np.mean(d * d))) if d.size else 0.0
        maximum = float(d.max()) if d.size else 0.0
        records[tap] = {"mae": mae, "rmse": rmse, "max_abs": maximum,
                        "threshold": args.atol, "pass": maximum <= args.atol}
    result = {"status": "TAP_COMPARISON_ONLY_NOT_FULL_PORT_CERTIFICATION",
              "results": records, "all_pass": all(x["pass"] for x in records.values())}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    require(result["all_pass"], "Per-tap tolerance exceeded")


def self_test() -> None:
    require(len(TOPOLOGY["negative_print"]) == 6, "Negative chain incomplete")
    require(len(TOPOLOGY["direct_scan"]) == 4, "Positive scan chain incomplete")
    require("log_e_print" not in [n[1] for n in TOPOLOGY["direct_scan"]],
            "Direct scan incorrectly routed through paper")
    require(UPSTREAM_SHA != IOS_BASE_SHA, "Source/base identity collision")
    print("Build77 source-contract self-test PASS (not iOS parity)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    v = sub.add_parser("verify")
    v.add_argument("--report", type=Path, default=None)
    e = sub.add_parser("emit-taps")
    e.add_argument("--input", required=True)
    e.add_argument("--output", required=True)
    e.add_argument("--film", default="kodak_portra_400")
    e.add_argument("--paper", default="kodak_portra_endura")
    e.add_argument("--scan-film", action="store_true")
    e.add_argument("--oneshot-controlled", action="store_true",
                   help="Run exact original Python stages with explicit on-device "
                        "controlled settings; this is NOT default RNG/gamut parity")
    e.add_argument("--print-diffusion", action="store_true",
                   help="Run the original optical paper PSF, not an iOS simulation")
    c = sub.add_parser("compare-taps")
    c.add_argument("--reference", required=True)
    c.add_argument("--candidate", required=True)
    c.add_argument("--atol", type=float, default=0.0)
    c.add_argument("--candidate-mapping", action="store_true",
                   help="Use real Swift iOS production stage mapping manifest and "
                        "fail closed on all 5/7 stage metadata; never auto-certify")
    sub.add_parser("self-test")
    args = parser.parse_args()
    try:
        if args.action == "verify":
            report = verify()
            if args.report:
                args.report.parent.mkdir(parents=True, exist_ok=True)
                args.report.write_text(
                    json.dumps(report, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8")
            print("Build77 upstream tree, 28 source profiles, topology and defaults: PASS")
            print("Not an iPhoneOS build or a numerical parity certification.")
        elif args.action == "emit-taps":
            emit_taps(args)
        elif args.action == "compare-taps":
            require(args.atol >= 0 and math.isfinite(args.atol),
                    "atol must be finite and nonnegative")
            compare_taps(args)
        else:
            self_test()
        return 0
    except Exception as exc:
        print(f"Build77 validation FAILED: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
