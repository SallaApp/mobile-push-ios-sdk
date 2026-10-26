// swift-tools-version:5.9
import PackageDescription

let strict: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "SallaPush",
    platforms: [.iOS(.v15), .macOS(.v12)],   // macOS only so `swift test` runs the core and engine on a Mac
    products: [
        .library(name: "SallaPush", targets: ["SallaPush"]),
        .library(name: "SallaPushExtension", targets: ["SallaPushExtension"]),
    ],
    targets: [
        .target(name: "SallaPushCore", path: "Sources/SallaPushCore", swiftSettings: strict),
        .target(name: "SallaPush", dependencies: ["SallaPushCore"], path: "Sources/SallaPush",
                resources: [.copy("PrivacyInfo.xcprivacy")], swiftSettings: strict),
        .target(name: "SallaPushExtension", dependencies: ["SallaPushCore"], path: "Sources/SallaPushExtension",
                resources: [.copy("PrivacyInfo.xcprivacy")], swiftSettings: strict),
        .testTarget(name: "SallaPushCoreTests", dependencies: ["SallaPushCore"], path: "Tests/SallaPushCoreTests",
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SallaPushTests", dependencies: ["SallaPush"], path: "Tests/SallaPushTests"),
        .testTarget(name: "SallaPushExtensionTests", dependencies: ["SallaPushExtension"], path: "Tests/SallaPushExtensionTests"),
    ]
)
