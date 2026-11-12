# SpektraFilm Port iOS 16.5.1 — Crash Evidence and Diagnostic v0.2.3

Uploaded iPhone crash log:
- OS: iPhone OS 16.5.1 (20F75).
- Exception: EXC_BREAKPOINT / SIGTRAP.
- Fault thread: com.apple.uikit.eventfetch-thread.
- Top frame: __BKSHIDEvent__BUNDLE_IDENTIFIER_FOR_CURRENT_PROCESS_IS_NIL__.
- Startup-to-crash: approximately 22 ms.
- Signing ID in report: com.twogou.spektrafilmport.
- Signing team in report: T8ALTGMVXN.
- Main thread was initializing UIKit; crash occurred before SwiftUI views.

This is evidence of main bundle ID lookup failure in UIKit on iOS 16.5.1,
not evidence of a bug in the film profile parser. Verify the installed
SIGNED IPA, not only the GitHub-generated UNSIGNED package.

Controlled diagnostic changes:
- Branch forked at known-good v0.1 code commit.
- Retain photo, Files, .cube, export functionality.
- Generate a small immutable Swift metadata table from original profiles.
- Exclude large JSON resources and folder-reference packaging.
- Specify CFBundleIdentifier and CFBundlePackageType in Info.plist.
- Run CI on macos-15, pin Xcode 16.4 instead of latest Xcode 26.6.
- Set minimum iOS deployment target to 16.5 for user's 16.5.1 phone.
- Inspect app Info.plist and package structure in CI.

If the signed build still crashes at the same frame, compare the final
SIGNED IPA's Payload/SpektraFilmPort.app/Info.plist with provisioning
entitlement application-identifier, and check if signer stripped CFBundleIdentifier.

No physical spectral simulation yet. Original measured profiles and source
licenses remain present in the fork at src/spektrafilm/data/profiles.
