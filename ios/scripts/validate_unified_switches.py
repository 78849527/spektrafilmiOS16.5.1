#!/usr/bin/env python3
"""Source-structure regression for all iOS16.5.1 editor menu switches.

This test intentionally checks the real first/second/third-level SwiftUI
implementation instead of a mock switch, and avoids claiming a screenshot
or physical-device tap test. No algorithm path is modified.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
p = ROOT / "ios/SpektraFilmPort/FloatingEditorWorkspace.swift"
src = p.read_text(encoding="utf-8")

def block(after: str, before: str) -> str:
    assert src.count(after) == 1, f"Missing/ambiguous Swift anchor {after!r}"
    return src.split(after, 1)[1].split(before, 1)[0]

shared = block("    private enum MiniSwitchMetrics {", "    private func simpleToggle(")
for token in (
    "static let trackWidth: CGFloat = 28",
    "static let trackHeight: CGFloat = 16",
    "static let thumbSize: CGFloat = 12",
    "static let thumbOffset: CGFloat = 6",
    "static let tapWidth: CGFloat = 42",
    "static let tapHeight: CGFloat = 32",
    ".frame(width: MiniSwitchMetrics.trackWidth,",
    "height: MiniSwitchMetrics.trackHeight)",
    ".frame(width: MiniSwitchMetrics.thumbSize,",
    "height: MiniSwitchMetrics.thumbSize)",
):
    assert token in shared, f"Shared second-row switch changed: {token}"
assert src.count("private func miniatureSwitch(isOn: Bool)") == 1

feature = block("    private func featureToggle(", "    // Second row:")
second = block("    private func simpleToggle(", "    // Top feature row")
mode = block("    private func sourceModeControl(", "    private func openFilmDrawer(")
third = block("    private func resetToggle(", "    private func exposureControl(")

for label, body in (("first-level feature", feature), ("second-level", second),
                    ("third-level", third), ("original source mode", mode)):
    assert "miniatureSwitch(isOn:" in body, f"{label} missing shared switch"
assert "Toggle(title, isOn: value)" not in src
assert re.search(r"(?<!\w)Toggle\s*\(", src) is None, "Native oversized Toggle in editor"

for token in (
    "Button {",
    "guard enabled else { return }",
    "value.wrappedValue.toggle()",
    "miniatureSwitch(isOn: value.wrappedValue)",
    ".frame(width: MiniSwitchMetrics.tapWidth,",
    "height: MiniSwitchMetrics.tapHeight)",
    ".buttonStyle(.plain)",
    ".onTapGesture(count: 2)",
    "value.wrappedValue = resetTo",
    ".accessibilityLabel(",
    ".disabled(!enabled)",
):
    assert token in third, f"Third-level behavior accidentally removed: {token}"
assert third.count(".onTapGesture(count: 2)") == 1, "Gesture must bind label, not switch"
assert third.index(".onTapGesture(count: 2)") < third.index("Button {")
assert "miniatureSwitch(isOn: isOn)" in mode
assert "MiniSwitchMetrics.tapWidth" in mode

# Existing second-level independent toggles and their reset semantics are kept.
for token in (
    'simpleToggle("64位"',
    'simpleToggle("散射"',
    'simpleToggle("CAM16"',
    'simpleToggle("曝光参考"',
    'simpleToggle("归一化"',
    'simpleToggle("曝光补偿"',
    'simpleToggle("SciPy"',
    'simpleToggle("Poisson"',
):
    assert token in src, f"Second-level control missing: {token}"
assert "value.wrappedValue = resetTo" in second
assert "confirmedSimpleLock(title)" in second
assert "confirmedFeatureLock(feature)" in feature

third_calls = re.findall(r'\bresetToggle\("([^"]+)"', src)
assert len(third_calls) == 10, f"Expected 10 nested switches, found {third_calls}"
assert len(set(third_calls)) == len(third_calls)
for token in (
    'resetToggle("黑白场校准"',
    'resetToggle("DIR 原版 FIR/YVV"',
    'resetToggle("原版摄影曝光前处理（Double｜三模块）"',
    'resetToggle("原版乳剂散射＋背反射同时开启（Double）"',
    'resetToggle("原版扫描镜头 / Unsharp（Double）"',
    'resetToggle("相机 UV 光谱截止"',
    'resetToggle("相机 IR 光谱截止"',
    'resetToggle("实测三乳剂亚层"',
    'resetToggle("原版 Metal 显影链"',
):
    assert token in src, f"Original third-level feature lost: {token}"
assert src.count("resetToggle(") == 11

# Keep the iOS16.5.1 crash-mitigation and the original report UI.
for token in (
    "private var featureRow: AnyView",
    "private var simpleSwitchRow: AnyView",
    "private var activeSettings: AnyView",
    "private var adjustmentDetailContent: AnyView",
    "tx.disablesAnimations = true",
    "StableImageHoldRecognizer(isHolding: $originalHeld)",
    "OriginalSourceNumbaFastCountsDiagnostic.evaluate()",
):
    assert token in src, f"Core UI stability/diagnostic feature lost: {token}"
assert ".simultaneousGesture(" not in src

print(f"PASS: {len(third_calls)} third-level on/off switches use the shared 28×16 miniature geometry")
print("PASS: source-mode, feature-row and independent second-row switches use the same visual switch")
print("PASS: 42×32 nested tap regions, single-tap action, label double-tap default, disabled gates and accessibility")
print("PASS: v1.8.43 diagnostic, iOS16.5.1 type-erased adjustment navigation and legacy switches retained")
print("NOT CERTIFIED: actual iPhone touch hit-testing or screenshot geometry")
