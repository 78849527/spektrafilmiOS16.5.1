#!/usr/bin/env python3
"""Build126 strict recipe persistence/atomic-application source contracts.

No device rendering is claimed until actual iOS 16.5.1 tests are supplied.
"""
import re
from pathlib import Path
from build_ci_version_floor import minimum_build, minimum_minor
root=Path(__file__).resolve().parents[2]
app=(root/"ios/SpektraFilmPort/ContentView.swift").read_text()
ui=(root/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
shelf=(root/"ios/SpektraFilmPort/Build126RecipeLibraryView.swift").read_text()
recipe=(root/"ios/SpektraFilmPort/Build126Recipe.swift").read_text()
project=(root/"ios/project.yml").read_text()
assert minimum_build(project,126) and minimum_minor(project,92)
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project

fields=re.findall(r'^\s*@Published var (\w+)\s*=\s*(true|false|-?\d+(?:\.\d+)?)\s*$',app,re.M)
excluded={"busy","rawNeedsChoice","rawFastModeActive","photoInputConvertedFromP3"}
bools={name for name,value in fields if value in {"true","false"} and name not in excluded}
numbers={name for name,value in fields if value not in {"true","false"}}
enums={
    "printIlluminant","printSourceDiffusionFamily",
    "sourceCameraMeteringMethod","sourceCameraDiffusionFamily",
    "sourceCameraRawMethod"
}
assert len(bools)>=35 and len(numbers)>=55

def segment(text,head,tail):
    return text[text.index(head):text.index(tail,text.index(head))]
def keys(section):
    return set(re.findall(r'"([A-Za-z]\w*)"',section))
bool_section=segment(recipe,"static let booleanKeys:","static let numberKeys:")
number_section=segment(recipe,"static let numberKeys:","static let enumKeys:")
enum_section=segment(recipe,"static let enumKeys:","var schemaVersion:")
assert keys(bool_section)==bools,(bools-keys(bool_section),keys(bool_section)-bools)
assert keys(number_section)==numbers
assert keys(enum_section)==enums

snap=segment(app,"private func recipeSnapshot(","private func setRecipeValues(")
setter=segment(app,"private func setRecipeValues(","private func saveRecipeLibrary(")
for key in bools|numbers:
    assert f'"{key}":{key}' in snap, f'capture missing {key}'
    route="bools" if key in bools else "numbers"
    assert f'{key}=recipe.{route}["{key}"]!' in setter,f'apply missing {key}'
for key in enums:
    assert f'"{key}":{key}.rawValue' in snap
    assert f'{key}= ' not in setter
    assert f'{key}=' in setter and f'recipe.choices["{key}"]!' in setter

for item in [
    "schemaVersion==Self.schema","Set(bools.keys)==Self.booleanKeys",
    "Set(numbers.keys)==Self.numberKeys","Set(choices.keys)==Self.enumKeys",
    "numbers.values.allSatisfy","try embeddedLUT?.validate()",
    "try bytes.write(to:libraryURL(),options:.atomic)",
    "try recipe.validateStructure()","try Build126RecipeStorage.write(entries)",
    "guard entries.count<=300",
    "let granted=url.startAccessingSecurityScopedResource()",
    "coverJPEG","rgbaFloatData","enum Build126RecipeStorage"
]:
    assert item in recipe+app,item
for item in [
    "func addSavedRecipe(name:String,includeCover:Bool) throws",
    "func preflightSavedRecipe(_ recipe:Build126Recipe) throws",
    "func applySavedRecipe(_ recipe:Build126Recipe) throws",
    "try preflightSavedRecipe(recipe)",
    "let previous=recipeSnapshot(name:",
    "setRecipeValues(undo.settings)",
    "lut=undo.lut","densityGrainStage=undo.density",
    "spatialDIRStage=undo.dir","processedPreview=undo.preview",
    "rejectRecipePreview(error.localizedDescription)",
    "finishRecipePreview()",
    "p.declaredDepth==8,p.decodedDepth==8",
    "p.color == .sRGB,!p.hasAlphaChannel",
    "originalPhotoData != nil,!rawFastModeActive",
    'bs["spatialDIREnabled"]==true',
    'bs["spatialDIRSourceConvolutionEnabled"]==true',
    'bs["grainEnabled"]==false',
    "recipe.embeddedLUT != nil",
    "recipeFilmSelectionToIgnore=recipe.filmID",
    "consumeRecipeFilmSelection",
    "if !isRecipeApplying { strength = 1.0 }",
]:
    assert item in app,item
assert app.index("try preflightSavedRecipe(recipe)")<app.index("setRecipeValues(recipe)",app.index("func applySavedRecipe"))
assert 'UserDefaults.standard.set(recipe.filmID' in app
assert "func convertActiveRAWTo8BitSRGBCopy()" in app
assert "Build125RAW8BitTransport.makeCertifiedCopy(rawImage)" in app

for item in [
    "我的冲印配方","model.addSavedRecipe(","model.applySavedRecipe(",
    "model.importSavedRecipe(","model.exportSavedRecipe(",
    "model.duplicateSavedRecipe(","model.toggleRecipeFavorite(",
    "model.deleteSavedRecipe(","model.renameSavedRecipe(",
    "saveCover=false","ShareLink(item:url)","allowedContentTypes:[.json]"
]:
    assert item in shelf,item
assert "let onOpenRecipes: () -> Void" in ui and "Button(action:onOpenRecipes)" in ui
assert "Build126RecipeLibraryView(" in app
assert "rawNeedsChoice" in app and "Build93AppleRAWImport.open(rawFile)" in app
print(f"PASS Build126: {len(bools)} booleans + {len(numbers)} doubles + {len(enums)} enums + stock pair; stable storage, 8-bit refusal, transactional restoration, shelf and exchange")
print("NOT CERTIFIED: signed iPhone16.5.1 gallery interaction, effect parity after imported recipes")
