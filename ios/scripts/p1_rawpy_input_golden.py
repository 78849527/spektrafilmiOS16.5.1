#!/usr/bin/env python3
"""Original rawpy ACES16 -> Float32 golden input tap. Does not certify iOS."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import numpy as np

# Float32, not Float64, is deliberately the reference for RAW input:
# source raw_file_processor.load_and_process_raw_file first casts uint16 to
# np.float32, then divides by np.float32(65535.0).
SAMPLES = [0, 1, 2, 32767, 32768, 65534, 65535]
EXPECTED_BITS = [
    0x00000000, 0x37800080, 0x38000080, 0x3effff00,
    0x3f000080, 0x3f7fff00, 0x3f800000,
]


def selftest() -> None:
    source = np.asarray(SAMPLES, dtype=np.uint16)
    observed = source.astype(np.float32) / np.float32(65535.0)
    assert list(observed.view(np.uint32)) == EXPECTED_BITS
    assert observed.dtype == np.float32
    print("PASS original RAW uint16 -> Float32 normalization: 7/7 bit patterns")


def generate(raw_path: Path, out_dir: Path) -> None:
    from spektrafilm.utils.raw_file_processor import load_and_process_raw_file
    import rawpy
    if not raw_path.is_file():
        raise FileNotFoundError(raw_path)
    # Same path and defaults as upstream; no manual TIFF, sRGB conversion,
    # Apple RAW decoder, gamut remap, JPEG or implicit downscale.
    original = load_and_process_raw_file(
        raw_path,
        white_balance="as_shot",
        lens_correction=False,
        output_colorspace="ACES2065-1",
        output_cctf_encoding=False,
    )
    if original.ndim != 3 or original.shape[-1] != 3:
        raise ValueError("rawpy original returned non-RGB image")
    if original.dtype != np.float32:
        raise ValueError("rawpy original precision changed from Float32")
    if not np.all(np.isfinite(original)):
        raise ValueError("rawpy original produced nonfinite ACES input")
    data = np.ascontiguousarray(original.astype("<f4", copy=False)).tobytes()
    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / "rawpy-linear-aces-f32le.rgb"
    manifest = out_dir / "rawpy-linear-aces.json"
    target.write_bytes(data)
    source_bytes_sha = hashlib.file_digest(raw_path.open("rb"), "sha256").hexdigest()
    payload = {
        "source": "src/spektrafilm/utils/raw_file_processor.py",
        "white_balance": "as_shot",
        "output_colorspace": "ACES2065-1",
        "output_cctf_encoding": False,
        "output_type": "float32",
        "endianness": "little",
        "shape": list(original.shape),
        "byte_length": len(data),
        "raw_sha256": source_bytes_sha,
        "golden_sha256": hashlib.sha256(data).hexdigest(),
        "rawpy_version": getattr(rawpy, "__version__", "unknown"),
        "libraw_version": str(getattr(rawpy, "libraw_version", "unknown")),
        "minimum": float(np.min(original)),
        "maximum": float(np.max(original)),
        "note": "Input-only oracle, not proof of equivalent decoder, film or iOS full render.",
    }
    manifest.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(payload, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--raw", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    selftest()
    if args.selftest and args.raw is None:
        return
    if args.raw is None or args.out is None:
        parser.error("--raw and --out required unless --selftest")
    generate(args.raw, args.out)


if __name__ == "__main__":
    main()
