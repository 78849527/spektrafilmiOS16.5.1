# iOS 16.5.1 launch hang on v1.0.0 Build 15

Device log from 2026-11-12 13:03:36 +0800: type 309, SIGKILL,
FRONTBOARD 0x8BADF00D, process-exit watchdog after failed graceful
termination, 5.0s. The process started approximately 33 seconds earlier.
The main thread was in SwiftUI AttributeGraph view update, Swift release
and malloc_zone_free. The report does not by itself prove the root cause
of the earlier UI unresponsiveness.

Conservative hotfix v1.0.1:
1. Start with only the photo preview canvas and top import toolbar.
   Never mount UIKit film/paper wheel pickers or nested adjustment ScrollView
   at cold start; lazy mount them only after photo import and eye-button tap.
2. Remove derived model.hasPhoto onChange that mutated SwiftUI state in a
   view-graph update. Remove continuous GestureState zoom/drag changes.
3. Remove costly variable native Material layers from dock cards.
4. Keep double-tap zoom, long press original, slide-to-compare, draggable
   onEnd panels, all 28 source films/print media and original algorithms.
5. Keep Xcode 16.4 on macos-15-intel, minimum iOS16.5, Bundle ID, and
   all v0.9 spectral and CoreImage tests unchanged.

This is a stability mitigation, not proven full root cause repair.
Automated compilation does not replace real iOS 16.5.1 device validation.
Prior v0.9 release remains available as an alternative.
