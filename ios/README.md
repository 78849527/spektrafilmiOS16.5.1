# SpektraFilm Port — iOS 16.5.1

Unofficial iOS port experiment in a fork of andreavolpato/spektrafilm.
The original Python implementation remains untouched on the main branch.

## Stage 1 — v0.1.0

- SwiftUI iPhone app, deployment target iOS 16.0 (covers iOS 16.5.1).
- Import JPEG/HEIC/PNG/TIFF (where supported) from Photos or Files.
- Import a standard Adobe 3D .cube LUT (R-fastest, sizes 2–65, domain 0–1).
- Core Image GPU-supported rendering, before/after, intensity slider.
- Full JPEG sharing, capped at 12.5 MP with explicit downsampling notice.
- Offline image processing, no server, account, analytics or upload.
- GitHub Actions unsigned-device IPA. Sign it before sideloading.

This is **LUT playback only**. There is no native physical spectral simulation
yet. RAW/ProRAW, camera capture, measured film/paper modeling, true physical
grain and halation, color-managed log/ACES inputs, and high-res unrestricted
export are not implemented in Stage 1.

Use .cube LUTs exported for **sRGB input AND sRGB output**. Original upstream LUT
creator can also bake camera-log and other color spaces. Those are not
interchangeable with sRGB photography. The parser rejects non-unit domains and
1D shapers; it cannot infer the intended input/output profile of a .cube file.

## Building

macOS with Xcode and XcodeGen:

    brew install xcodegen
    cd ios
    xcodegen generate --spec project.yml
    xcodebuild -project SpektraFilmPort.xcodeproj -scheme SpektraFilmPort \
      -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
      CODE_SIGNING_ALLOWED=NO build

CI: .github/workflows/ios16.yml on branch ios16.
Successful runs upload SpektraFilmPort-ios16-unsigned.ipa as an Actions artifact.
Push-triggered builds also publish an unofficial public prerelease asset
at the ios16-mvp release tag. It is **unsigned**, requiring manual signing.

Compilation is not a replacement for real testing on an iOS 16.5.1 iPhone.

## Port roadmap

1. Native app, .cube parser, import and export.
2. Upstream LUT metadata and fidelity tests.
3. Native C++/Metal spectral physical pipeline, parity vs upstream reference.
4. RAW, hardware memory/performance tuning, true negative/print reproduction.
5. Physical grain, halation and complete UI.

## License and credits

Original source code: GPLv3 (see root LICENSE).
Measured profiles and LUTs may be subject to CC BY-SA 4.0 and additional
terms (see root SPEKTRAFILM_LICENSE.txt).
Original project by Andrea Volpato. Unofficial fork; no endorsement.
