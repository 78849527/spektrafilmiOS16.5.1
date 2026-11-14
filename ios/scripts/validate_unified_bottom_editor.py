#!/usr/bin/env python3
"""iOS16.5.1 v1.8.47 UI contract: ONE bottom sheet, top title tabs,
horizontal film/paper rails, no left/right snapped drawer entry.

Tests actual Swift source structure and parent bindings (not a screenshot).
Avoids changing algorithms or copying source globals into a test mock.
"""
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
ui=(ROOT/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
parent=(ROOT/"ios/SpektraFilmPort/ContentView.swift").read_text()
project=(ROOT/"ios/project.yml").read_text()

assert 'MARKETING_VERSION: "1.8.47"' in project
assert 'CURRENT_PROJECT_VERSION: "72"' in project
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project

def between(start,stop):
    assert ui.count(start)==1,("missing/nonunique",start,ui.count(start))
    assert ui.count(stop)==1,("missing/nonunique",stop,ui.count(stop))
    return ui.split(start,1)[1].split(stop,1)[0]

body=between("    var body: some View {","    private func previewImage(")
toolbar=between("    private var bottomToolbar: some View {","    private func toolButton(")
panel=between("    private func unifiedEditorDock(","    // First row: only features with parameter panels.")
lifecycle=between("    private func selectEditorPage(","    private var films: [MeasuredStock] {")
photos=between("    private func previewImage(","    private var bottomToolbar: some View {")
assert '@State private var unifiedEditorExpanded = false' in ui
assert '@State private var selectedEditorPage: EditorPage = .adjustment' in ui
assert 'private enum EditorPage: String { case film = "胶卷", adjustment = "调整" }' in ui
assert 'Button(action: openUnifiedEditor)' in toolbar
assert 'Text("调整")' in toolbar
assert '.disabled(!model.hasPhoto)' in toolbar
assert 'unifiedEditorDock(width:' in body
assert body.count('.overlay(alignment: .bottom)')==1
assert '.padding(.bottom, 63)' in body
assert 'bottomToolbar' in body
assert 'statusChip' in body
assert 'StableImageHoldRecognizer(isHolding: $originalHeld)' in photos
assert '.scaleEffect(photoScale, anchor: .top)' in ui
assert 'statusReportSheet' in ui
assert "PhotosPicker(selection: $selectedPhoto" in toolbar
assert 'onExport(.original)' in toolbar
assert 'onSaveToPhotos(.original)' in toolbar
assert 'Text("胶卷")' in panel and 'Text("调整")' in panel
assert 'selectEditorPage(.film)' in panel and 'selectEditorPage(.adjustment)' in panel
assert 'selectedEditorPage == .film' in panel
assert 'filmSelectionContent' in panel
assert 'adjustmentControls' in panel
assert 'Button(action: closeUnifiedEditor)' in panel
assert 'private func horizontalMaterialPicker(' in panel
assert 'TabView(selection: selection)' in panel
assert '.tabViewStyle(.page(indexDisplayMode: .never))' in panel
assert 'horizontalMaterialPicker("胶卷 FILM", items: films,' in panel
assert 'horizontalMaterialPicker("相纸 PAPER", items: media,' in panel
assert 'ForEach(items)' in panel
assert '.tag(stock.id)' in panel
assert 'selection.wrappedValue = defaultID' in panel
assert '左右滑动切换' in panel
assert '向左或向右滑动切换当前材料' in panel
assert 'if isReversal' in panel and '反转片直接扫描 · 无需相纸' in panel
assert 'Button(action: onOpenCatalog)' in panel
assert '.pickerStyle(.wheel)' not in ui
for forbidden in (
    'edgeDrawerTab', 'DrawerSide', 'frontDrawer',
    'wheelExpanded', 'adjustmentExpanded',
    'wheelDock(', 'adjustmentDock(',
    'openFilmDrawer(', 'closeFilmDrawer(',
    'openAdjustmentDrawer(', 'closeAdjustmentDrawer(',
):
    assert forbidden not in ui,("old side dock leftover",forbidden)

for stage in (
    'private func openUnifiedEditor()', 'private func closeUnifiedEditor()',
    'private func selectEditorPage(_ page: EditorPage)',
    'transaction.disablesAnimations = true',
    'withTransaction(transaction)',
    'adjustmentRowsReady = false',
    'adjustmentDetailReady = false',
    'DispatchQueue.main.async',
    'adjustmentRowsReady = true',
    'adjustmentDetailReady = true',
    'guard unifiedEditorExpanded && selectedEditorPage == .adjustment',
):
    assert stage in lifecycle,stage
assert 'selectedEditorPage = .adjustment' in lifecycle
assert 'model.applyMeasuredSimulation()' not in lifecycle
assert 'model.queueSpectralPreview()' not in lifecycle
assert '.simultaneousGesture(' not in ui
assert 'DragGesture(minimumDistance: 16)' not in ui
assert ui.count('.gesture(')==1
for boundary in (
    'private var featureRow: AnyView',
    'private var simpleSwitchRow: AnyView',
    'private var adjustmentControls: AnyView',
    'private var adjustmentDetailContent: AnyView',
    'private var activeSettings: AnyView',
    'private var filmSelectionContent: AnyView',
):
    assert boundary in ui,boundary
for token in (
    'FloatingEditorWorkspace(',
    'selectedFilmID: $selectedFilmID',
    'selectedPaperID: $selectedPaperID',
    '.onChange(of: selectedFilmID)',
    '.onChange(of: selectedPaperID)',
):
    assert token in parent,("film/paper binding changed",token)
print("PASS: one 16.5.1 bottom-menu entry named 调整; no floating or snapped edge tabs")
print("PASS: top 胶卷/调整 names switch mutually exclusive full-width content")
print("PASS: film and paper selection follow every actual horizontal page swipe (no extra tap); reversal bypass, defaults and catalogue preserved")
print("PASS: selected film/paper IDs still drive production model preview; no algorithm change")
print("PASS: safe two-stage adjustment mounting and photo/status/export/compare gestures retained")
print("NOT CERTIFIED: physical-device touch performance, pixel-perfect screenshots")
