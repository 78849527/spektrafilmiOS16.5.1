# Vendored NextLevel 0.18.0

Source: https://github.com/NextLevel/NextLevel/tree/0.18.0

All 14 upstream source files and the MIT LICENSE are committed without
modifications; their Git blob SHAs match the original repository's tag.

Only this local Package.swift differs from upstream, because the upstream
Swift 5.2 manifest with iOS 14 cannot be parsed by the current Xcode 16.4
package resolver. New manifest uses Swift tools 5.9, Swift 5 mode and iOS 16.
The NextLevel product remains a separate local package module.

The NextLevel RAW capture TODO in 0.18.0 is not implemented in this port.
