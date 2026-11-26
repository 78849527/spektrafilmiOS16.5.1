#!/usr/bin/env python3
"""Shared ordered source gates for Linux preflight and macOS compile.
No gate is omitted; failures propagate immediately.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = (
    "ios/scripts/build115_unseeded_parallel_source_audit.py",
    "ios/scripts/build116_grain_memory_matrix_audit.py",
    "ios/scripts/build117_dynamic_memory_audit.py",
    "ios/scripts/build118_separate_large_memory_audit.py",
    "ios/scripts/build119_committed_memory_audit.py",
    "ios/scripts/build120_process_ui_restructure_audit.py",
    "ios/scripts/build121_switch_explanation_audit.py",
    "ios/scripts/build122_compact_native_camera_audit.py",
    "ios/scripts/build123_native_raw_capture_safety_audit.py",
    "ios/scripts/build124_native_dng_editor_ingress_audit.py",
    "ios/scripts/build125_raw_8bit_transport_audit.py",
    "ios/scripts/build126_recipe_system_audit.py",
    "ios/scripts/build127_film_carousel_camera_raw_default_audit.py",
    "ios/scripts/build128_raw_float32_original_tiff16_audit.py",
    "ios/scripts/build129_float_srgb_compatibility_audit.py",
    "ios/scripts/build129_precise_mode_gate_audit.py",
    "ios/scripts/build131_original_input_fidelity_audit.py",
)
for script in SCRIPTS:
    print(f"RUN {script}", flush=True)
    subprocess.run([sys.executable, str(ROOT / script)], cwd=ROOT, check=True)
