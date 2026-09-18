// swift-tools-version: 6.0
// FeedRuntimeV2 — the Runtime V2 local package.
//
// Dependency direction is the architecture (plan §3 of
// docs/superpowers/plans/2026-09-17-feedmine-runtime-v2-revised.md):
//
//   FeedDomain   ← Foundation and Sendable value types only
//   FeedStorage  ← FeedDomain + GRDB (Admission, Selection, Publication persistence)
//   FeedRuntime  ← FeedDomain + FeedStorage (session, selection, publication, runway)
//   FeedConnectorSyndication ← FeedDomain + FeedKit/HTTP (RSS/Atom translation only)
//   FeedMedia    ← FeedDomain + HTTP/ImageIO where needed (no editorial semantics)
//   FeedUIBridge ← FeedRuntime + FeedDomain + SwiftUI (snapshots in, intents out)
//
// The rule is enforced mechanically by scripts/verify-runtime-v2-boundaries.sh; do not add a
// dependency without updating the table there and in the plan.
import PackageDescription

let package = Package(
    name: "FeedRuntimeV2",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FeedDomain", targets: ["FeedDomain"]),
        .library(name: "FeedStorage", targets: ["FeedStorage"]),
        .library(name: "FeedRuntime", targets: ["FeedRuntime"]),
        .library(name: "FeedConnectorSyndication", targets: ["FeedConnectorSyndication"]),
        .library(name: "FeedMedia", targets: ["FeedMedia"]),
        .library(name: "FeedUIBridge", targets: ["FeedUIBridge"]),
    ],
    dependencies: [
        // Versions must match feedmine.xcodeproj/…/Package.resolved.
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.4.0"),
        .package(url: "https://github.com/nmdias/FeedKit", exact: "9.1.2"),
    ],
    targets: [
        .target(
            name: "FeedDomain",
            path: "Sources/FeedDomain"
        ),
        .target(
            name: "FeedStorage",
            dependencies: [
                "FeedDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/FeedStorage"
        ),
        .target(
            name: "FeedRuntime",
            dependencies: ["FeedDomain", "FeedStorage"],
            path: "Sources/FeedRuntime"
        ),
        .target(
            name: "FeedConnectorSyndication",
            dependencies: [
                "FeedDomain",
                .product(name: "FeedKit", package: "FeedKit"),
            ],
            path: "Sources/FeedConnectorSyndication"
        ),
        .target(
            name: "FeedMedia",
            dependencies: ["FeedDomain"],
            path: "Sources/FeedMedia"
        ),
        .target(
            name: "FeedUIBridge",
            dependencies: ["FeedDomain", "FeedRuntime"],
            path: "Sources/FeedUIBridge"
        ),
        .testTarget(
            name: "FeedDomainTests",
            dependencies: ["FeedDomain"],
            path: "Tests/FeedDomainTests"
        ),
        .testTarget(
            name: "FeedStorageTests",
            dependencies: [
                "FeedStorage",
                "FeedDomain",
                // PR-16's crash rehearsal kills a process between the temporary asset file and the
                // reference to it, so the test has to prove the leftover is collectable — and
                // collecting it is `FeedMedia`'s own path, not a second implementation in the test.
                // A test-only edge: production `FeedStorage` still may not see `FeedMedia` (plan §3).
                "FeedMedia",
            ],
            path: "Tests/FeedStorageTests"
        ),
        // PR-16's crash class needs a real process to kill (plan §15.1: an exception thrown inside a
        // transaction does not substitute for a terminated process). This target is that process and
        // nothing else: the tests spawn it, wait for its boundary marker, kill it, and reopen the
        // database it was writing.
        //
        // It lives under `Probes/` rather than `Sources/` on purpose. `Sources/` means "the modules of
        // plan §3's dependency table", and the boundary gate treats a directory there that no rule
        // governs as a module nobody declared — which is right. This is a test helper, not a module:
        // nothing links against it, it is in neither the dependency table nor the gate's rules, so it
        // must not sit where modules sit. It names FeedStorage *and* FeedMedia — a pair no production
        // target may combine — because the file-write boundary has to place the temporary file where
        // `LocalAssetStore`'s own reclaim path looks for it.
        .executableTarget(
            name: "FeedStorageProbe",
            dependencies: ["FeedDomain", "FeedStorage", "FeedMedia"],
            path: "Probes/FeedStorageProbe"
        ),
        .testTarget(
            name: "FeedRuntimeTests",
            dependencies: [
                "FeedRuntime",
                "FeedDomain",
                "FeedStorage",
                // Selection fixtures write supply rows directly, so the test target names GRDB
                // explicitly instead of relying on a transitive import through FeedStorage.
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/FeedRuntimeTests"
        ),
        .testTarget(
            name: "FeedConnectorSyndicationTests",
            dependencies: ["FeedConnectorSyndication", "FeedDomain"],
            path: "Tests/FeedConnectorSyndicationTests"
        ),
        .testTarget(
            name: "FeedMediaTests",
            dependencies: ["FeedMedia", "FeedDomain"],
            path: "Tests/FeedMediaTests"
        ),
        .testTarget(
            name: "FeedUIBridgeTests",
            dependencies: ["FeedUIBridge", "FeedRuntime", "FeedDomain"],
            path: "Tests/FeedUIBridgeTests"
        ),
    ]
)
