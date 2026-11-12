# iOS 16.5.1 v0.4.1 — film/paper wheels

Device target exclusively iOS 16.5.1. Uses macos-15 and Xcode 16.4, original
working CFBundleIdentifier and compact generated spectral arrays.

The main editor has two independently draggable vertical wheel selectors in
its lower-left area: negative film above, print paper below. The right column
holds film exposure, paper exposure, LUT/preview strength, and manual apply.
Changing a wheel debounces for 380ms, then recalculates the selected measured
pair without requiring a modal stock selector or pressing Apply.
Stale calculations cannot overwrite the latest selected combination.
The detailed source-stock catalog is still accessible from the wheel column.

Supported six measured negatives:
Kodak Portra 160/400/800, Kodak Gold 200, Kodak Ektar 100,
Fujifilm Pro 400H.

Supported three print papers:
Kodak Portra Endura, Kodak Endura Premier, Fuji Crystal Archive Type II.
There are 18 supported combinations. Other source profiles are metadata only.

Long-pressing the photo preview displays the untouched original until release.
Photos/Files import, external .cube, preview and JPEG export are preserved.
Measured optical pipeline remains simplified relative to original Spektrafilm
(no Hanatos upsampling, full couplers, halation, etc).

CI must run native physics tests on all supported 18 combinations, then compile
with iOS minimum 16.5, verify Bundle ID, and publish unsigned diagnostic IPA.
No original JSON folder assets are bundled, preserving iOS 16.5.1 startup.
