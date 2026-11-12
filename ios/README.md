# SpektraFilm Port — iOS 16.5.1

Unofficial experimental iPhone app in a fork of andreavolpato/spektrafilm.
The original Python implementation on main remains untouched.

## v0.2.0 — measured stock and paper profiles

- Preserves functional JPEG/HEIC/PNG/TIFF import, external .cube LUT playback,
  preview, before/after, and JPEG export (12.5 MP cap) from v0.1.
- Bundles full, unchanged measured film/paper JSON files from the upstream tree.
- Generates an index from each profile's actual ID, name, usage, polarity,
  recommended print, wavelength count, original version, license, and SHA-256.
- Adds native filming-stock and paper selectors with preferred-paper pairing
  and local persistence of selected stock IDs.
- Bundles upstream GPL, measured-profile CC BY-SA, and citation notices.
- All stages local/offline; no fabricated film responses or stock LUTs.

IMPORTANT: Choosing a real film/paper config is **metadata only** in v0.2.
It does NOT alter the photo. The actual image processor continues to use only
the externally imported sRGB-to-sRGB .cube LUT. The spectral simulation
pipeline is not yet ported. Film and paper JSON data are NOT Core Image LUTs.

Staging reads source data directly from src/spektrafilm/data/profiles and copies
the originals byte-for-byte into ios/SpektraFilmPort/Resources/profiles.
This generated resource folder is ignored by Git. No measurement is changed.

## Local build

Requires macOS, Xcode, XcodeGen, Python 3 standard library:

    python3 ios/scripts/stage_profiles.py
    python3 ios/scripts/validate_profiles.py
    brew install xcodegen
    cd ios
    xcodegen generate --spec project.yml
    xcodebuild -project SpektraFilmPort.xcodeproj -scheme SpektraFilmPort \
      -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
      CODE_SIGNING_ALLOWED=NO build

GitHub Actions workflow: .github/workflows/ios16.yml.
Push to ios16 publishes a separate unsigned ios16-v0.2.0 prerelease.
Previous ios16-mvp release is preserved as rollback.
Unsigned IPA requires your own signing prior to installation.

## Device acceptance checklist

1. App shows measured film and paper counts without missing-resource warning.
2. Kodak Portra 400 selection shows an 81-wavelength source profile and
   automatically selects Kodak Professional Portra Endura paper.
3. Choose another stock and paper, restart, verify selections persist.
4. Photo import via Photos and Files; import .cube through Files.
5. Export and share JPEG. Without a LUT, selecting stock must not invent effect.
6. Verify no crash, black image, missing metadata, or empty picker.

## Next milestones

v0.3: native physical pipeline, reference-image parity and first working
measured negative/print effect. RAW/ProRAW, full-resolution rendering,
physical grain, halation and additional color-management follow later.

## License

Original source code GPLv3 (root LICENSE). Measured profiles CC BY-SA 4.0
and additional terms in SPEKTRAFILM_LICENSE.txt. Their original notices
are embedded with the unmodified data. Attribution: Andrea Volpato and
source dataset holders. Unofficial fork without upstream endorsement.
