# SpektraFilm Port — experimental v0.3 on iOS 16.5.1

This branch is based on the user-tested functional iOS 16.5.1 v0.2.3 app,
built on Xcode 16.4. The stable branch and its IPA are retained.

## What is newly functional

A native, **simplified, measured-profile spectral negative/print pipeline**:
1. sRGB photo decoded to linear sRGB.
2. Approximate spectral input reconstruction with smooth RGB spectral bands.
3. Kodak Portra 400's 81-wavelength measured log sensitivity maps exposure
   to native H-D film density curves.
4. Measured film dye-density spectra modulate a 3400K enlarger illuminant.
5. Kodak Professional Portra Endura spectral sensitivity and H-D response
   produce exposed paper dye density.
6. Measured paper dye spectra produce a viewed color under 5000K light.
7. CIE XYZ matching, simple display white calibration, and output to sRGB.
8. At runtime, evaluate 17x17x17 colors and use CIColorCube as an acceleration
   structure to apply the calculated look to actual pixels. No external LUT is
   required; external .cube import remains supported independently.

Camera/film exposure and enlarger/paper exposure are separate EV controls.
One combination only: Kodak Portra 400 and Kodak Portra Endura. Other entries
in the stock catalog remain metadata-only. All processing is offline.

## Accurate limitations (important)

This is not the full original Spektrafilm Python physics engine or a
numerically matching port of its end-to-end output. Spectral RGB
reconstruction is approximated with Gaussian bases instead of Hanatos 2025.
Black-body light approximates the enlarger without the original TH-KG3 heat
filter. CIE matching uses published smooth approximations; output adaptation
and neutral balancing are simplified. No color-reference compensation, print
curve morphing, DIR couplers, halation, grain, glare, RAW/ProRAW pipeline, or
high-precision per-pixel full-spectrum engine. The 17-cube introduces
interpolation approximation. No "original parity" claim should be made.

The measured arrays themselves are packed from the unchanged upstream JSON
files into Float32 arrays with only nil values replaced by zero. Full JSON
profiles are not packaged in app resources, matching stable v0.2.3 packaging.
Build-time generator records original profile SHA-256 digests.

## Compatibility and build

Device target: iOS 16.5.1 only; deployment target iOS 16.5.
macOS-15 and Xcode 16.4 pinned. Bundle ID unchanged from the working app:
com.twogou.spektrafilmport.

    python3 ios/scripts/generate_compact_catalog.py
    python3 ios/scripts/generate_spectral_data.py
    xcrun swiftc -O -parse-as-library \
      ios/SpektraFilmPort/SpectralPhysics.swift \
      ios/SpektraFilmPort/GeneratedSpectralData.swift \
      ios/tests/SpectralValidation.swift \
      -o /tmp/SpektrafilmSpectralValidation
    /tmp/SpektrafilmSpectralValidation
    cd ios && xcodegen generate --spec project.yml

GitHub Actions builds an unsigned iPhoneOS IPA; sign it before device install.

## Acceptance testing on actual iOS 16.5.1 iPhone

1. Launch (must not crash before opening editor).
2. Import from Photos, Files, import arbitrary .cube and export JPEG.
3. Open measured catalog; choose Kodak Portra 400 + Portra Endura.
4. Import a JPEG. Press "计算并应用光谱模拟" (no external LUT).
5. Preview must change; try exposure EV+1 and paper EV+1, verify they change
   output in opposite brightness directions.
6. Before/after preview and JPEG export must match.
7. Try choosing any unsupported film: app should display a clear message
   without falsely applying a different stock's simulation.

If a crash occurs, use the actual 16.5.1 .ips report (not build logs).
See ios/CRASH-iOS16.5.1.md on the stable branch.

## License

Original profile data: Andrea Volpato / CC BY-SA 4.0; original source GPLv3.
Source attribution remains in the fork and generated source header.
Unofficial experiment; not endorsed by upstream.
