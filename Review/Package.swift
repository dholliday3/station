// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "onramp",
    platforms: [.macOS(.v14)],
    products: [.library(name: "onramp", targets: ["onramp"])], // Station's review windows
    targets: [
        .binaryTarget(name: "onramp_coreFFI", path: "Frameworks/onramp_core.xcframework"),
        .target(
            name: "onramp",
            dependencies: ["onramp_coreFFI"],
            resources: [.copy("Extensions"), .copy("Reviewers")] // built-in extensions (fonts, themes, languages), the app icon
        ),
    ]
)
