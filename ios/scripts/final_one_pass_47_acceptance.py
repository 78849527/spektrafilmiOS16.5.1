#!/usr/bin/env python3
"""Single CI entrypoint. 47 items + all available original-source evidence.
No iPhone device, real RAW source or signed IPA is invented by this test."""
import pathlib,subprocess,json,re,datetime,traceback,sys
R=pathlib.Path(__file__).resolve().parents[2]
O=pathlib.Path("/tmp/SpektraFilm-one-pass")
A="4e1ab8faf4ebfe47a6bac7e85e657881d68d2bf1"
B108="b02e2773f07d913e101bd3dcdc5d0c709b74dc77"
status={}
def git(*x):return subprocess.check_output(["git",*x],cwd=R,text=True).strip()
def read(p):return (R/p).read_text()
def run(name,commands):
    logfile=O/"logs"/(name+".log")
    good=True
    with logfile.open("w") as out:
        for c in commands:
            out.write("$ "+" ".join(c)+"\n");out.flush()
            try:
                q=subprocess.run(c,cwd=R,stdout=out,stderr=subprocess.STDOUT,timeout=1800)
                if q.returncode:good=False;break
            except Exception as ex:out.write(str(ex)+"\n");good=False;break
    status[name]="PASS" if good else "FAIL"
    print(status[name],name,flush=True)
def sw(name,*files):
    exe=str(O/"bin"/name)
    return ["swiftc","-O","-parse-as-library",*files,"-o",exe],[exe]
def main():
    (O/"logs").mkdir(parents=True,exist_ok=True)
    (O/"bin").mkdir(parents=True,exist_ok=True)
    try:
        assert git("merge-base",A,"HEAD")==A
        assert git("merge-base",B108,"HEAD")==B108
        assert not git("diff","--name-only",A,"HEAD","--","ios/SpektraFilmPort","ios/project.yml")
        project=read("ios/project.yml")
        assert 'CURRENT_PROJECT_VERSION: "108"' in project
        assert 'MARKETING_VERSION: "1.8.74"' in project
        assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project
        roadmap=read("docs/MASTER-PORTING-ROADMAP-ios16.5.1.md")
        section=roadmap.split("## B. 路线图逐项执行",1)[1].split("## C. 建议批次",1)[0]
        items=re.findall(r"(?m)^(0[1-9]|[1-3][0-9]|4[0-7])\.\s+(.+)$",section)
        assert len(items)==47
        assert [int(x) for x,y in items]==list(range(1,48))
        status["frozen_source_and_47"]="PASS"
    except Exception:
        (O/"logs"/"freeze-failure.log").write_text(traceback.format_exc())
        status["frozen_source_and_47"]="FAIL"
        items=[(f"{i:02}","未能验证路线图") for i in range(1,48)]
    swift=[str(p.relative_to(R)) for p in sorted((R/"ios/SpektraFilmPort").glob("*.swift"))]
    run("Swift_parse_and_production_routes",[
      ["xcrun","swiftc","-frontend","-parse",*swift],
      ["python3","ios/scripts/final_gamut_source_route_audit.py"]])
    glu="ios/SpektraFilmPort/Build81OriginalInputGamut.swift"
    locus="ios/SpektraFilmPort/Build81GeneratedSpectralLocus.swift"
    a,z=sw("gamut96",glu,locus,"ios/tests/FinalSourceOklchValidation.swift")
    run("Python_input_Oklch_96",[
      ["python3","ios/scripts/build81_generate_source_locus.py","--output",locus],
      ["python3","ios/scripts/final_source_oklch_oracle.py","--output",str(O/"original-oklch.json")],
      a,z+[str(O/"original-oklch.json")]])
    a,z=sw("tc4038",glu,locus,"ios/SpektraFilmPort/Build82OriginalHanatosSurface.swift",
      "ios/SpektraFilmPort/Build82OriginalSpectralRuntime.swift",
      "ios/tests/FinalOriginalTCLUTValidation.swift")
    run("Python_Hanatos_TC_LUT_4038",[
      ["python3","ios/scripts/final_source_tc_lut_oracle.py",str(O/"original-TC-LUT.json")],
      a,z+[str(O/"original-TC-LUT.json")]])
    a,z=sw("cam16",
      "ios/SpektraFilmPort/GeneratedScannerReference.swift",
      "ios/SpektraFilmPort/Build89OriginalCAM16.swift",
      "ios/tests/Build89NativeSourceCAM16Validation.swift")
    run("Python_CAM16_216",[
      ["python3","ios/scripts/generate_scanner_reference.py"],
      ["python3","ios/scripts/build89_real_cam16_original_oracle.py",str(O/"original-CAM16.json")],
      a,z+[str(O/"original-CAM16.json")]])
    a,z=sw("raw",
      "ios/SpektraFilmPort/Build79RAWSignature.swift",
      "ios/SpektraFilmPort/Build79RAWStorage.swift",
      "ios/SpektraFilmPort/Build79NativeRAWBackend.swift",
      "ios/tests/Build79RAWSignatureValidation.swift",
      "ios/tests/FinalSourceRawPreservationValidation.swift")
    run("RAW_signatures_spoofs_SHA256",[a,z])
    run("source_ICC_five_profiles",[
      ["python3","ios/scripts/build90_generate_original_icc.py"]])
    common=[
      "ios/SpektraFilmPort/Build90GeneratedSourceICC.swift",
      "ios/SpektraFilmPort/Build90SourceOutputQuantization.swift",
      "ios/SpektraFilmPort/Build90NativeOutputWriter.swift",
      "ios/SpektraFilmPort/Build90OriginalICCContainer.swift"]
    if status["source_ICC_five_profiles"]=="PASS":
        a,z=sw("icc8",*common,"ios/tests/Build90NativeImageIOValidation.swift")
        run("ICC_eight_real_files",[a,z])
        a,z=sw("metadata",*common,"ios/tests/FinalSourceMetadataRoundTripValidation.swift")
        run("EXIF_IPTC_GPS_real_JPEG_TIFF",[a,z])
    else:
        status["ICC_eight_real_files"]="SKIPPED"
        status["EXIF_IPTC_GPS_real_JPEG_TIFF"]="SKIPPED"
    a,z=sw("memory91",
      "ios/SpektraFilmPort/OriginalSourceDiffusion.swift",
      "ios/SpektraFilmPort/Build91PhysicalMemory.swift",
      "ios/tests/Build91PhysicalMemoryMatrixValidation.swift")
    run("memory_1_to_13MP_budget",[a,z])
    a,z=sw("memory106",
      "ios/SpektraFilmPort/Build106SourceMemoryLedger.swift",
      "ios/tests/Build106SourceMemoryLedgerValidation.swift")
    run("memory_106_ledger",[a,z])
    codes="P E P E E P P X P P X X P P E X E E E E E E E E E X E X E P E E E P E P E P X X P P P P P P P".split()
    for n,x in [(16,"E"),(38,"E"),(40,"P")]:codes[n-1]=x
    labels={"P":"部分实现/近似","E":"局部受控数值等价","X":"关键分支尚未移植"}
    blockers=[
      ("03","原版 Float64 UI 默认与生产完整链未认证"),
      ("08","ProPhoto/ACES/P3/ICC 输入矩阵未全覆盖"),
      ("09-12","真实 RAF/DNG/CR3 与 Python rawpy 去马赛克/镜头/白平衡无整图对照"),
      ("13","skimage order=3 resize 生产整链未认证"),
      ("26,36","Numba 无固定种子多线程随机与 scanner glare 默认语义未认证"),
      ("28,45","Python 1/2/8/12MP 全 tap 整图独立参考缺失"),
      ("39","光谱结果到真实广色域的全处理链未认证"),
      ("40","EXR 真编码、XMP 完整保留、原版 Writer 实际 GUI 接线不足"),
      ("44","13MP 全光学+颗粒 iOS16.5.1 真机 RSS/Jetsam 缺证据"),
      ("46","iPhoneOS 真机 12 项 GUI 人工操作未全部证明"),
      ("47","已签名且科学验收完整的正式 Release 未放行")]
    if "exportPhysicalOriginalFile(" not in read("ios/SpektraFilmPort/ContentView.swift"):
        blockers.append(("40","ContentView 没有调用现成的原版 Float64 文件 Writer"))
    rawcount=len([p for p in R.rglob("*") if p.is_file() and p.suffix.lower() in
                 (".raf",".dng",".cr3",".nef",".arw")])
    roadmap=[{"number":n,"title":title,"state":labels[codes[i]],"complete":False}
             for i,(n,title) in enumerate(items)]
    failures=[x for x,y in status.items() if y!="PASS"]
    report={
      "version":"1.8.74 Build108","ios_target":"16.5.1","minimum_ios":"16.5",
      "production_sha":A,"acceptance_sha":git("rev-parse","HEAD"),
      "time_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
      "same_run_checks":status,"passed_count":len(status)-len(failures),
      "total_count":len(status),"technical_failures":failures,
      "roadmap":roadmap,"roadmap_counts":{labels[k]:codes.count(k) for k in labels},
      "known_blockers":[{"items":n,"reason":v} for n,v in blockers],
      "raw_original_image_count":rawcount,
      "inherited":{
        "Build108_device_core":"28/28 previous actual iPhone report",
        "Build108_device_grain":"20/20 previous actual iPhone report",
        "Build108_device_frames":"1MP with grain and 2MP without grain PASS previous",
        "Build108_device_report_sha256":"936697573994c6ada6a808f11b18d431ca40e2e00eaf3346312ce213c9cc6df0",
        "same_production_iPhoneOS_arm64":"https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43831632544"},
      "rawpy_parity":"NOT_RUN_NO_REAL_CAMERA_RAW",
      "13MP_actual_device":"NOT_RUN","12_GUI_actual_device":"NOT_RUN",
      "formal_original_certified":False,"release_gate":"BLOCKED","new_IPA":False}
    (O/"one-pass.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
    md=["# SpektraFilm｜47 项一次集中验收",
        f"生产 SHA: {A}；Build108 / iOS16.5.1",
        f"本轮检查 **{len(status)-len(failures)}/{len(status)} PASS**；正式认证 **BLOCKED**。",
        "", "## 本轮一次执行的检查", "| 检查 | 状态 |","|---|---|"]
    md.extend(f"| {n} | {v} |" for n,v in status.items())
    md.extend(["","## 旧有有效证据（继承，不重跑）",
      "Build108 真机核心 28/28、颗粒 20/20、1MP 带颗粒及 2MP 不带颗粒；",
      "同生产源码 iPhoneOS Release 编译 PASS（CI 43831632544）。",
      "","## 正式认证阻塞","| 条目 | 缺口 |","|---|---|"])
    md.extend(f"| {n} | {v} |" for n,v in blockers)
    md.extend(["","## 47 项登记","| # | 要求 | 当前范围 | 正式认证 |",
      "|---|---|---|---|"])
    md.extend(f"| {z['number']} | {z['title']} | {z['state']} | 未完成 |"
              for z in roadmap)
    md.extend(["","CI 只验证已有原版受控样本；真实 RAW/rawpy、13MP 真机 RSS、手势无法伪造。",
      "一轮 CI；一份 JSON/MD/LOG；没有新 IPA。"])
    (O/"one-pass.md").write_text("\n".join(md)+"\n")
    combined=[]
    for p in sorted((O/"logs").glob("*.log")):
        combined.extend(["\n==== "+p.name+" ====\n",p.read_text(errors="replace")[-7500:]])
    (O/"one-pass.log").write_text("".join(combined))
    print("ONE-PASS",report["passed_count"],"/",report["total_count"],
          "tech fails",failures,"release",report["release_gate"],flush=True)
    return int(bool(failures))
if __name__=="__main__":sys.exit(main())
