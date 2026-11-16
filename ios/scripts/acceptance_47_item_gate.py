#!/usr/bin/env python3
"""Build108 frozen-source final acceptance ledger. Read-only production audit.

This program does NOT claim complete source parity. It checks provenance,
known production blockers, the fixed 47-item roadmap and available source
evidence. All unproven certification branches remain explicitly BLOCKED.
"""
from __future__ import annotations
import argparse
import datetime as dt
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
FROZEN = "b02e2773f07d913e101bd3dcdc5d0c709b74dc77"
DEVICE_JSON_SHA256 = "936697573994c6ada6a808f11b18d431ca40e2e00eaf3346312ce213c9cc6df0"
PREVIOUS_CI = "https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43798512291"
# Preliminary, scoped 47-row audit. E = numeric evidence exists in subset;
# P = partial/approximate production support; X = source branch not migrated.
# E is NEVER a full 47-item certification.
CODES = "P E P E E P P X P P X X P P E X E E E E E E E E E X E X E P E E E P E P E P X X P P P P P P P".split()
STATUS = {"P": "近似实现", "E": "数值等价", "X": "尚未移植"}
# One existing repository pointer per work item, not proof of completion.
EVIDENCE = [
    "docs/MASTER-PORTING-ROADMAP-ios16.5.1.md",
    "ios/tests/SourcePhysicalImageParity.swift",
    "ios/SpektraFilmPort/ContentView.swift",
    "ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift",
    "ios/tests/SourcePhysicalImageParity.swift",
    "ios/SpektraFilmPort/OriginalSourcePixelIO.swift",
    "ios/SpektraFilmPort/Build78HighBitDepthIngress.swift",
    "ios/SpektraFilmPort/Build81OriginalInputGamut.swift",
    "ios/SpektraFilmPort/Build79NativeRAWBackend.swift",
    "ios/SpektraFilmPort/Build80AppleRAWDevelopment.swift",
    "docs/BUILD80-RAW-WB-LENS-AND-SOURCE-TINT.md",
    "docs/BUILD80-RAW-WB-LENS-AND-SOURCE-TINT.md",
    "ios/SpektraFilmPort/Build81OriginalCrop.swift",
    "ios/SpektraFilmPort/Build81OriginalPreview.swift",
    "ios/SpektraFilmPort/Build81OriginalSourceInputStage.swift",
    "ios/SpektraFilmPort/Build81OriginalInputGamut.swift",
    "ios/SpektraFilmPort/Build82OriginalHanatosSurface.swift",
    "ios/SpektraFilmPort/Build82OriginalSpectralRuntime.swift",
    "ios/SpektraFilmPort/Build83OriginalCameraPhoton.swift",
    "ios/SpektraFilmPort/OriginalSourceDiffusion.swift",
    "ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift",
    "ios/SpektraFilmPort/Build84OriginalFilmDIR.swift",
    "ios/SpektraFilmPort/OriginalSourcePhysicalGrain.swift",
    "ios/SpektraFilmPort/OriginalSourceSciPySampler.swift",
    "ios/SpektraFilmPort/OriginalSourceNumbaFastCounts.swift",
    "ios/SpektraFilmPort/OriginalSourceNumbaSingleThreadNormal.swift",
    "ios/SpektraFilmPort/OriginalSourceMicrostructure.swift",
    "ios/SpektraFilmPort/Build108SourceOpticalDeviceStress.swift",
    "ios/SpektraFilmPort/OriginalPrintOptics.swift",
    "ios/SpektraFilmPort/OriginalPrintOptics.swift",
    "ios/SpektraFilmPort/Build87OriginalColorReference.swift",
    "ios/SpektraFilmPort/OriginalSourceDiffusion.swift",
    "ios/SpektraFilmPort/OriginalPrintMorph.swift",
    "ios/SpektraFilmPort/Build87OriginalColorReference.swift",
    "ios/SpektraFilmPort/Build88OriginalScannerSpectrum.swift",
    "ios/SpektraFilmPort/OriginalSourceScannerGlare.swift",
    "ios/SpektraFilmPort/OriginalSourceScannerOptics.swift",
    "ios/SpektraFilmPort/Build89OriginalOutputGamut.swift",
    "ios/SpektraFilmPort/Build90NativeOutputWriter.swift",
    "ios/SpektraFilmPort/Build90NativeOutputWriter.swift",
    "ios/SpektraFilmPort/Build90OriginalLUT.swift",
    "ios/SpektraFilmPort/Build106SourceMemoryLedger.swift",
    "docs/BUILD91-DOUBLE-FFT-METAL-MEMORY-42-44-BULK.md",
    "ios/SpektraFilmPort/Build91PhysicalMemory.swift",
    "ios/SpektraFilmPort/Build103VerificationEvidence.swift",
    "ios/SpektraFilmPort/Build100Readiness.swift",
    "ios/project.yml",
]
assert len(CODES) == 47 and len(EVIDENCE) == 47

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")

def git(*args: str) -> str:
    return subprocess.check_output(
        ["git", *args], cwd=ROOT, text=True
    ).strip()

def blockers():
    ui = read("ios/SpektraFilmPort/ContentView.swift")
    gamut = read("ios/SpektraFilmPort/Build81OriginalInputGamut.swift")
    writer = read("ios/SpektraFilmPort/Build90NativeOutputWriter.swift")
    physical = read("ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift")
    doc = read("docs/BUILD100-PRODUCTION-CANDIDATE-VERIFICATION.md")
    probes = [
        ("03", "P0", "原版 Float64 生产精确模式不是已认证默认入口",
         "@Published var sourcePhysicalDirectEnabled = false" in ui),
        ("03", "P0", "原版像素直连仍为显式实验入口",
         "@Published var sourcePixelIOEnabled = false" in ui),
        ("16", "P0", "输入 Oklch 原版分支明确尚未移植",
         "Oklch mode remains NOT MIGRATED" in gamut),
        ("40", "P0", "原版 EXR 编码明确禁止，不能改名为 TIFF",
         "guard options.format != .exr" in writer),
        ("26", "P0", "UI 生产颗粒仍固定受控 seed=8888，非原版默认多线程随机",
         "numbaSeed:sourcePhysicalGrainEnabled ? 8888 : nil" in ui),
        ("38", "P0", "CAM16 逐像素存在，但生产默认色域算法未认证",
         "var sourceOutputGamut: Build89OriginalOutputGamut.Settings? = nil" in physical),
        ("12", "P0", "RAW 与 rawpy 后端逐阶段等价证据未齐",
         "原版" in doc),
        ("44", "P0", "12/13MP 全光学＋颗粒真实 RSS/Jetsam 未取得",
         "full13MPOperationMeasured:false" in read("ios/SpektraFilmPort/Build108SourceOpticalDeviceStress.swift")),
        ("45", "P0", "1/2MP 真机结果无独立 Python 全图数值比对",
         "largeImagePythonNumericParityCertified:false" in read("ios/SpektraFilmPort/Build108SourceOpticalDeviceStress.swift")),
        ("46", "P0", "12 项真实手势/导入导出人工验收尚缺证据",
         "result=not_run" in doc),
    ]
    return [{"work_item": item, "priority": pri, "reason": reason,
             "source_observation": ("confirmed" if found else "needs_recheck"),
             "decision": "BLOCKED"} for item,pri,reason,found in probes]

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--out", type=pathlib.Path,
                   default=pathlib.Path("/tmp/spektrafilm-final-acceptance"))
    a=p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    roadmap = read("docs/MASTER-PORTING-ROADMAP-ios16.5.1.md")
    # Only numbered scientific requirements in section B; section C repeats\n    # four entries in its illustrative planning prose.\n    begin=roadmap.index("## B. 路线图逐项执行")\n    end=roadmap.index("## C. 建议批次",begin)\n    specs = re.findall(r"(?m)^(0[1-9]|[1-3][0-9]|4[0-7])\.\s+(.+)$",roadmap[begin:end])
    assert len(specs) == 47, f"roadmap changed: {len(specs)} instead of 47"
    assert [int(n) for n,_ in specs] == list(range(1,48)), "roadmap IDs drift"
    project=read("ios/project.yml")
    assert 'MARKETING_VERSION: "1.8.74"' in project
    assert 'CURRENT_PROJECT_VERSION: "108"' in project
    assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project
    assert git("merge-base", FROZEN, "HEAD") == FROZEN, "frozen source ancestry drift"
    changed=git("diff", "--name-only", FROZEN, "HEAD").splitlines()
    allowed={
        "ios/scripts/acceptance_47_item_gate.py",
        ".github/workflows/acceptance-47-item-build108-ios1651.yml",
        "docs/ACCEPTANCE-47-FROZEN-BUILD108.md",
    }
    assert set(changed) <= allowed, "acceptance must not modify production code"
    entries=[]
    for index, (n,title) in enumerate(specs):
        pointer=EVIDENCE[index]
        exists=(ROOT/pointer).is_file()
        assert exists, f"missing evidence pointer for {n}: {pointer}"
        entries.append({
            "item":n, "requirement":title,
            "preliminary_state":STATUS[CODES[index]],
            "evidence_file":pointer,
            "evidence_scope":"historical source/controlled CI, NOT entire branch",
            "formal_complete":False,
            "final_acceptance":"BLOCKED",
        })
    problems=blockers()
    assert len(problems)>=8
    report={
        "schema":1,
        "baseline_commit":FROZEN,
        "acceptance_commit":git("rev-parse","HEAD"),
        "app_version":"1.8.74", "app_build":"108",
        "ios_target":"16.5.1", "minimum_ios":"16.5",
        "created_utc":dt.datetime.now(dt.timezone.utc).isoformat(),
        "prior_source_ci":{"url":PREVIOUS_CI,"status":"PASS","scope":"Build108 CI; not full certification"},
        "prior_device_report":{
            "sha256":DEVICE_JSON_SHA256,
            "source":"user-provided Build108 physical-device JSON; not stored in this repository",
            "observed":"28/28 core, 20/20 grain, 1MP+2MP controlled optical pass",
            "independent_1m_2m_python_reference":False,
            "full_13mp_render":False},
        "roadmap_count":len(entries),
        "preliminary_counts":{k:sum(x["preliminary_state"]==k for x in entries)
                              for k in STATUS.values()},
        "items":entries, "blocking_findings":problems,
        "automated_lab_checks":"separate CI job",
        "manual_12_item_gui_check":"NOT_RUN",
        "full_python_original_certified":False,
        "release_gate":"BLOCKED",
        "ipa_generated_by_acceptance":False
    }
    jsonpath=a.out/"final-47-acceptance.json"
    mdpath=a.out/"final-47-acceptance.md"
    jsonpath.write_text(json.dumps(report,indent=2,ensure_ascii=False)+"\n",encoding="utf-8")
    rows=[
        "# SpektraFilm Build108｜47 项集中验收（冻结源）",
        "",
        f"Baseline SHA: {FROZEN}",
        "Release certificate: **BLOCKED**（尚无全原版正式认证）",
        f"既有 Build108 CI：{PREVIOUS_CI}（成功≠完整原版认证）",
        "真机 JSON SHA256："+DEVICE_JSON_SHA256,
        "",
        "## P0 阻塞项",
        "| 编号 | 验收项 | 来源现状 |",
        "|---|---|---|",
    ]
    rows += [f"| {x['work_item']} | {x['reason']} | {x['source_observation']} |"
             for x in problems]
    rows += ["", "## 47 项逐条登记",
             "| # | 工作项 | 初审分类 | 关联源文件 | 正式验收 |",
             "|---|---|---|---|---|"]
    for x in entries:
        rows.append(f"| {x['item']} | {x['requirement']} | "
                    f"{x['preliminary_state']}（限历史范围） | "
                    f"{x['evidence_file']} | BLOCKED |")
    rows += ["", "## 结论",
             "此项验收只核实证据与现有源状态，没有假设 47 项均通过。",
             "待完成 RAW/rawpy、文件格式/ICC、CAM16 默认接入、Numba 多线程、1/2MP Python 全图对照、"
             "13MP 真实内存与 12 项人工 GUI 验收，再复核正式认证。",
             "验收分支不得修改生产算法或构建新的 IPA。",
             ""]
    mdpath.write_text("\n".join(rows),encoding="utf-8")
    print("ACCEPTANCE_REPORT_CREATED",jsonpath,mdpath)
    print("47-ITEM REGISTRY",len(entries),"P0 KNOWN BLOCKERS",len(problems))
    print("FORMAL CERTIFICATE: BLOCKED (expected and truthful)")

if __name__=="__main__":
    main()
