// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StationKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "StationKit", targets: ["StationKit"])], // Station's review windows
    targets: [
        .binaryTarget(name: "station_coreFFI", path: "Frameworks/station_core.xcframework"),
        .target(
            name: "StationKit",
            dependencies: ["station_coreFFI"],
            resources: [.copy("Extensions"), .copy("Reviewers")] // built-in extensions (fonts, themes, languages), the app icon
        ),
    ]
)
