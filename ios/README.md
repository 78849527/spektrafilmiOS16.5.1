# SpektraFilm Port — iOS 16.5.1

## v0.2.1 — launch-safe measured profiles (test build)

The stable v0.1 editor flow continues to load without touching any bundled
measured-profile JSON. Measured film and paper data remain in the app, copied
byte-for-byte from the original Spektrafilm profiles and validated with SHA-256
during GitHub Actions.

Fix for v0.2 startup crash reports:
- Remove eager profile catalog parsing from PhotoEditorModel.init().
- Remove eager SwiftUI Picker construction from the primary editing screen.
- Move film/paper selection into a separately opened sheet.
- Load profile index only when the user explicitly opens the sheet.
- If bundled metadata cannot be decoded, display the error inside the sheet.
- Keep Photos/Files/.cube import, previews and JPEG export independent.
- Maintain original stock/paper IDs in UserDefaults.
- Publish separately as ios16-v0.2.1, preserving v0.2 and stable v0.1 rollback.

These changes isolate a plausible launch-time failure path, but are not proof
of a root cause without an iPhone device crash report.

**Not yet implemented:** native physical spectral simulation. The bundled
profiles are original measured data and metadata only. Selecting a stock does
not alter pixels; image effects still depend on a manually imported .cube LUT.

## Build

    python3 ios/scripts/stage_profiles.py
    python3 ios/scripts/validate_profiles.py
    brew install xcodegen
    cd ios
    xcodegen generate --spec project.yml
    xcodebuild -project SpektraFilmPort.xcodeproj -scheme SpektraFilmPort \
      -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
      CODE_SIGNING_ALLOWED=NO build

## Recommended iOS 16.5.1 test

1. Install signed v0.2.1; launch with no interactions.
2. Confirm normal editor loads before opening measured-profile screen.
3. Import test photo and .cube; export JPEG.
4. Tap '打开胶片 / 相纸配置'. Check list, stock/paper selection, relaunch persistence.
5. If launch or sheet still crashes, share the iOS analytics crash report:
   Settings -> Privacy & Security -> Analytics & Improvements -> Analytics Data,
   search for SpektraFilmPort (or JetSam / app binary process name). If the
   report contains a sensitive device identifier, redact it before sharing.

## Copyright

Spektrafilm original code by Andrea Volpato, GPLv3. Original measured data
licensed CC BY-SA 4.0, with full original notices packaged in the app. The
experimental iOS port is unofficial and unaffiliated with the upstream author.
