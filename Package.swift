// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tapll",
    // macOS is included only so `swift test` runs on the host; the SDK targets iOS apps.
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "Tapll", targets: ["Tapll"]),
    ],
    targets: [
        // The crash handler's signal/mach path is C because it has to be: a handler runs on a dying
        // thread that may hold the malloc lock, and Swift cannot promise async-signal-safety — even a
        // retain is a runtime call. See Sources/TapllCrashCore/include/tapll_crash.h.
        .target(name: "TapllCrashCore"),
        .target(
            name: "Tapll",
            dependencies: ["TapllCrashCore"],
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "TapllTests",
            dependencies: ["Tapll", "TapllCrashCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
