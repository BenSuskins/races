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
        // Deliberately NOT `.defaultIsolation(MainActor.self)`, unlike Family Hub.
        //
        // That kit is mostly a networking client driven from SwiftUI, so a
        // MainActor default fitted it. This one is overwhelmingly pure value
        // types and a pure algorithm, and making those MainActor-isolated is
        // simply wrong: it contradicts the rule in CLAUDE.md that everything the
        // rater needs is pure, and it forces hundreds of isolated conformances
        // to Equatable, Codable and OptionSet that no value type should have.
        //
        // It is also not survivable in practice — the volume of those isolated
        // conformances crashed the compiler during module emission.
        //
        // The two types that genuinely need isolation say so themselves:
        // `RacingAPIClient` is an actor because it caches tier state, and
        // `RateLimiter` is an actor because it hands out slots.
        .target(
            name: "RacesKit",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Likewise no .defaultIsolation: it would make XCTestCase subclasses
        // MainActor-isolated, and those cannot override XCTestCase's nonisolated
        // init(name:testClosure:) — which breaks the build on Linux outright.
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
