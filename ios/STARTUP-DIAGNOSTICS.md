# v0.2.2 iOS 16.5.1 — STARTUP ISOLATION TEST

This is an intentionally limited diagnostic build. Do NOT ship as the real v0.2 release.

What is included:
- Exactly the known-working v0.1 photo editor user interface;
- Stable Photos + Files + .cube import and JPEG share/export;
- Same upstream measured film/paper files included in the v0.2 bundle;
- Same app identifier com.twogou.spektrafilmport as the prior versions;
- iOS deployment target 16.0.

What is deliberately disabled:
- Compiling StockCatalog.swift.
- Eager or lazy measured-profile views.
- Film/paper selection UI.

Why:
v0.2.0 and v0.2.1 reportedly exit immediately on launch on the user's iPhone.
Build passed CI, but that does not provide runtime diagnostics.

Interpretation:
1. If this build opens but v0.2.1 fails, the added v0.2 UI/model path
   (not merely resources and signing) is implicated.
2. If this build fails but known-good v0.1 opens, the packaged resources,
   binary/signing differences, or installation path are implicated.
3. If a freshly signed v0.1 also fails, investigate signing/provisioning
   or device configuration before changing Swift code.

To get a conclusive exception cause, obtain an iOS .ips crash log
(Settings > Privacy & Security > Analytics & Improvements > Analytics Data)
and examine Exception Type, Termination Reason, Last Exception Backtrace.

v0.2.1 is preserved on ios16; this diagnostic branch is separate.
