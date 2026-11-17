#!/usr/bin/env python3
"""Build127 UI-only stock browsing + camera RAW default invariants.

Source-level contract only. Physical iOS16.5.1 UI gestures/capture require
device checks before reporting human-interface parity.
"""
from pathlib import Path
from build_ci_version_floor import minimum_build,minimum_minor

root=Path(__file__).resolve().parents[2]
workspace=(root/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
camera=(root/"ios/SpektraFilmPort/NextLevelCamera.swift").read_text()
main=(root/"ios/SpektraFilmPort/ContentView.swift").read_text()
shelf=(root/"ios/SpektraFilmPort/Build126RecipeLibraryView.swift").read_text()
project=(root/"ios/project.yml").read_text()

assert minimum_build(project,127) and minimum_minor(project,93)
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project
assert 'case film = "胶片与配方"' in workspace
assert 'editorTab(.film)' in workspace
assert 'editorTab(.adjustment)' in workspace
assert 'editorTab(.workflow)' in workspace
assert 'Text("高级")' in workspace

assert "GeneratedMeasuredProfiles.entries.filter {" in workspace
assert '$0.medium == "film" && $0.stage == "filming"' in workspace
assert '$0.stage == "printing"' in workspace
assert 'SpectralPhysics.supportedFilmIDs.contains(stock.id)' in workspace
assert 'SpectralPhysics.supportedPaperIDs.contains(stock.id)' in workspace
assert "仅目录数据 · 暂不可用" in workspace
assert ".disabled(!supported || model.busy)" in workspace
assert 'Text(stock.name)' in workspace
assert '.fixedSize(horizontal:false,vertical:true)' in workspace
assert 'ScrollView(.horizontal,showsIndicators:false)' in workspace
assert 'LazyHStack(spacing:8)' in workspace
assert 'ScrollViewReader { scroll in' in workspace
assert "左右滑动浏览 · 点卡片选择" in workspace
assert "if selection.wrappedValue != stock.id" in workspace
assert "selection.wrappedValue=stock.id" in workspace
assert "TabView(selection: selection)" not in workspace
assert ".tabViewStyle(.page(" not in workspace

assert '@AppStorage("sf.build127.filmFavorites")' in workspace
assert '@AppStorage("sf.build127.recentFilms")' in workspace
assert 'toggleFavoriteFilm(_ id:String)' in workspace
assert 'recordRecentFilm(_ id:String)' in workspace
assert 'quickFilmStocks' in workspace
assert 'quickSavedRecipes' in workspace
assert 'onOpenRecipes()' in workspace
assert 'selectRecipeFromShelf(_ recipe:Build126Recipe)' in workspace
assert 'try model.applySavedRecipe(recipe)' in workspace
assert 'selectedFilmID=recipe.filmID' in workspace
assert 'selectedPaperID=recipe.paperID' in workspace
assert 'recipeApplyError=error.localizedDescription' in workspace
assert 'model.simulationAwaitingCurrentSettings' in workspace
assert 'Build126RecipeLibraryView(' in main
assert 'func preflightSavedRecipe(_ recipe:Build126Recipe) throws' in main
assert "setRecipeValues(undo.settings)" in main
assert "原始 DNG" in shelf

# The established Build123 RAW exception handling remains untouched; RAW
# is selected by default, and unsupported lenses require an explicit choice.
assert '@Published private(set) var format:NativePhotoFormat = .raw' in camera
assert "Button(\"JPEG\") {camera.selectFormat(.jpeg)}" in camera
assert "Button(\"RAW DNG\") {camera.selectFormat(.raw)}" in camera
assert "Button(\"HEIC\") {camera.selectFormat(.heic)}" in camera
assert "NativeCameraLens.allCases" in camera
lens=camera.index("ForEach(NativeCameraLens.allCases)")
format_row=camera.index('Button("JPEG") {camera.selectFormat(.jpeg)}',lens)
shutter=camera.index("Button {camera.capture()}",format_row)
assert lens<format_row<shutter,"format picker must be beneath the 0.5x lens row"
assert "camera.format == .raw && !camera.rawAvailable" in camera
assert "当前镜头不支持 Bayer RAW" in camera
assert "RAW 拍摄未返回 DNG" in camera
assert "rawDNG:raw" in camera
assert "if photo.isRawPhoto {" in camera
assert "Build93AppleRAWImport.open(rawFile)" in main
assert "try loadPhoto(capture.processed,entry:.camera)" in main
print("PASS Build127: full-name swipe-only browsing, tap selection, favorite/recent recipe shelf, default RAW below lens with no JPEG fallback")
print("NOT CERTIFIED: iOS16.5.1 hardware tap/scroll layout, RAW capture on each physical lens")
