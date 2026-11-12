# SpektraFilm v1.3 — Source printing black-white reference and original s023 morphology

Based on v1.2, preserving user-tested v1.0.1 safe floating photo
workspace and deployment iOS 16.5 / Xcode 16.4. Independent branch.

## New opt-in printing calibration (negative-film printing)
Source ColorReferenceService computes film min/max densities,
passes them through the enlarger and original printing H-D curves,
then uses viewing illuminant XYZ luminance for black/white references.
Its black_white_printing_exposure_correction then inverts the *measured
average print density vs exposure* around 0.184 midgray to determine
an additional enlarger EV. The new "按印相曝光计算黑白参考" control
activates this path only if source scanner and B/W correction are on.
Direct reversal-film scanning never exposes photographic paper.

This port now propagates the source black/white dye endpoints through
the actual measured film->print->scanner path instead of the older
material-only Y endpoints. The upstream enlarger exposure normalization,
preflash, and print-CC source reference system are already partially
approximated by this port's optical printRaw / printReference; the
precise source-normalized print reference is NOT yet bit-exact.
The original is *optical* / CIE 1931 based rather than RGB post-filter.
Exposure compensation is capped at +/-4 EV if the print response is
nearly singular. Default disabled; legacy appearance unchanged.

## Original printing s023 development
The source PrintCurvesMorphParams has seven parameters:
gamma_factor, gamma_factor_fast, gamma_factor_slow, per-channel R/G/B
gamma, and developer_exhaustion. All seven are implemented by
OriginalPrintMorph.swift using 3-channel x 3 original per-layer
centers/amplitudes/sigmas for all eight printing materials.
The CDF is Gaussian with Gumbel mixture, sigma floor 0.05.
The Gumbel center compensation is found by a +/- root bracket and
binary search keeping D(logE=0) fixed. The "fast" speed sublayer is
lowest mu, not necessarily the D-logE toe.

The first UI exposes global, fast, slow gamma and developer exhaustion.
Per-channel RGB values are implemented in the algorithm model but
remain at 1.0 in this initial UI.

The original fitted CDF is not identical point-for-point to the earlier
measured 256-point optical print curve. The native renderer therefore
uses only (source morphed-fit - source baseline-fit) as a difference on
the legacy measured H-D curve, preserving v1.2 byte-for-byte when the
new mode is off. The source mathematical morphology itself is matched
with generated original-Python values. The corrective delta
composition is a compatibility choice, not exact upstream print
develop() parity.

The 256-point corrected curve is precomputed *once per material* on
the background LUT generation, instead of solving Gumbel centers on
each photo pixel. This is important for the iOS 16.5.1 device.

## CI gates
- All eight original source 3-layer printing models generated from JSON
- 56 source Python s023 morph-mode reference arrays x 5 exposures x 3 channels
- 16 original NumPy inverse-H-D print exposure reference checks
- 128 native negative-print routes, 4 direct reversal-film routes;
  original v1.2-off source appearance parity
- 9^3 density-grain two-stage calibrated print LUT compatibility
- All earlier Hanatos/DIR/ACES/CAM16, spatial optics and GPU grain tests
- Xcode 16.4 iPhoneOS Release, bundle/min-OS validation and unsigned IPA

This branch remains an experiment until installed on actual iOS 16.5.1.
The unsigned IPA requires user-side code signing.
