# SpektraFilm Port v1.2 — source CAM16-UCS gamut (iOS 16.5.1)

Builds on v1.1 optical scanner and the user-tested v1.0.1 fixed full
photo preview. Minimum iOS16.5, Xcode16.4, unchanged Bundle ID.

### This stage
The original Python default gamut_compression.py OutputGamutCompressSpec
selects **CAM16-UCS**, not the previous optional ACES RGC. New opt-in
"原版默认 CAM16-UCS" toggle within "扫描光源 · ACES 色域" chooses
a source-default CAM16 colour mapping, while still allowing original
ACES v1.3 as an alternative.

The build machine imports the upstream actual gamut_compression.py
module and uses the source default OutputGamutCompressSpec including
CIECAM16-UCS colour appearance under Y_b=20, L_A=64, its 64x720
C_max(Jp,h) boundary (18 bisections), its original (0,1,6) Reinhard
chroma rolloff and (0.7,1,2.2) lightness compression. It bakes RGB
mapping over [-0.25,1.75]³ in a 33³ Float32 lookup. The app loads
this data ONLY if the user requests CAM16, using fast trilinear
interpolation to avoid per-pixel CAM16 adaptation on iOS 16.5.1.

### Fidelity limits
The original source model is exact only at finite grid nodes.
Trilinear interpolation is an approximation off-grid; values outside
the baked domain, and a small number of undefined nonphysical source
CAM16 cells, fall back to the source-supported ACES-RGC path.
The first experimental black-white correction in v1.1 still uses
measured density endpoints rather than the full exposure-aware
printing reference. Source XYZ glare ordering and original
sublayer/spatial DIR modules also remain incomplete.

The initial appearance is unchanged: both source scanning and CAM16
are OFF at launch. Existing older optical grain and all v1.0.1
floating-dock controls remain intact, with no new startup data load.

### Gates
- Original Python source CAM16 generation for 33³ extended gamut
- Swift trilinear sampling against 15 independent Python probes
- Source ACES and sRGB XYZ reference regression
- All original 28 measured materials, 128 negative/print combinations,
  4 reversal direct scanning routes and density-grain two-stage output
- Spatial scattering, multi-bounce halation, density-grain statistics,
  original optical curves and iOS16.5.1 safe UI guard
- Unsigned iPhoneOS Release package and verified GitHub Release asset

The IPA is unsigned and requires device signing. Test CAM16 switching
with a night scene (colored lights), skin tones and grayscale patches.
