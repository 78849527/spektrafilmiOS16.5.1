// swift-tools-version:5.9
// Upstream NextLevel 0.18.0 sources are unmodified, MIT licensed.
// Only this Package.swift is adapted to the iOS16.5.1/Xcode16.4 toolchain.
import PackageDescription

let package = Package(
    name: "NextLevel",
    platforms: [.iOS(.v16)],
    products: [.library(name: "NextLevel", targets: ["NextLevel"])],
    targets: [.target(name: "NextLevel", path: "Sources")],
    swiftLanguageVersions: [.v5]
)
