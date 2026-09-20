// swift-tools-version: 6.2
import PackageDescription

// Shared model, networking and rating layer for the Races client.
//
// Deliberately Foundation-only: no SwiftUI, no UIKit, no Security.framework. That
// is what lets CI build and test it on a Linux runner in seconds rather than
// waiting on a macOS one — and the Linux job is what enforces the rule, since it
// fails the moment anyone imports a platform framework.
//
// It matters more here than it did in Family Hub: the rating algorithm lives in
// this package, so the back-test runs on Linux in seconds too.
//
// The Swift settings mirror the app target's build settings
// (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, SWIFT_VERSION = 5.0) so isolation
// behaves identically on both sides of the module boundary.
let package = Package(
    name: "RacesKit",
    platforms: [
        .iOS(.v26),
    ],
    products: [
        .library(name: "RacesKit", targets: ["RacesKit"]),
    ],
    targets: [
        .target(
            name: "RacesKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
            ]
        ),
        // No .defaultIsolation here: it would make XCTestCase subclasses
        // MainActor-isolated, which cannot override XCTestCase's nonisolated
        // init(name:testClosure:). The library keeps it; the tests don't need it.
        .testTarget(
            name: "RacesKitTests",
            dependencies: ["RacesKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
