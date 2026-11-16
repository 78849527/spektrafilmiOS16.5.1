# SpektraFilm iOS 16.5.1 — Repository Agent & CI Rules

These instructions apply to all future iOS porting, test, build, and IPA release work in this repository.

## Mandatory macOS build environment

- **Default and required GitHub-hosted iOS builder: Apple Silicon `macos-15`.**
- CI workflows that build or package `SpektraFilmPort` MUST use `runs-on: macos-15`. Do not set `macos-15-intel`, `macos-14`, or a floating `macos-latest` as the standard builder.
- Do not change the runner architecture as a speculative way to fix a Python, Swift, or GitHub Actions failure. Diagnose the failed command and compare with the most recent full successful Apple Silicon build (Build112 run 43877837429) first.
- A temporary exception requires an explicit user decision **before** changing this rule or choosing a different macOS runner. Document the reason, scope, and restoration plan. Apple Silicon remains the permanent default.
- Keep the selected Python and NumPy/SciPy/Numba/llvmlite versions compatible with the selected runner. Do not silently upgrade them mid-workflow. A dependency change must be tested or justified against the successful full-build baseline.
- `macos-15` is the host architecture; continue building a real `iphoneos` **arm64** app with minimum deployment target **iOS 16.5**, designed to run on **iOS 16.5.1**. Never confuse macOS architecture with the target iPhone architecture.

## Build and parity discipline

- Use the upstream Python implementation as the algorithmic source of truth; preserve order, parameters, precision, guards, and error behavior. Separate full precision from mobile fast-path approximations.
- Before any IPA run, audit the *full* workflow for obsolete UI tokens, changed source symbols, missing standalone Swift dependencies, incompatible Python wheels, and version/IPA identities. Fail fast on Linux where possible.
- Prefer one batched source revision and one end-to-end macOS build after preflight. Avoid repeated trial-and-error runner toggles, test-only label changes, and unnecessary cancellation of a build already executing.
- An unsigned IPA is not installable without signing. Report separate outcomes for static checks, original Python reference parity, Swift compilation, iPhoneOS arm64 build, real iPhone verification, and GitHub Release asset existence.
- Provide a direct IPA URL only after a successful GitHub Release is actually published and its asset verified.
