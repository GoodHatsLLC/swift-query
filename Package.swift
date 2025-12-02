// swift-tools-version: 6.1
import PackageDescription

var targets: [Target] = [
    .target(
        name: "SQLiteSnapshotShims",
        path: "Sources/SQLiteSnapshotShims",
        publicHeadersPath: "."
    ),
    .target(
        name: "SwiftUIQuery",
        dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            .product(name: "Crypto", package: "swift-crypto"),
            "SQLiteSnapshotShims"
        ]
    ),
    .executableTarget(
        name: "TestApp",
        dependencies: ["SwiftUIQuery"],
        path: "Sources/TestApp"
    ),
    .testTarget(
        name: "SwiftUIQueryTests",
        dependencies: ["SwiftUIQuery"]
    )
]

#if os(Linux)
targets.removeAll { $0.name == "TestApp" }
#endif

let package = Package(
    name: "SwiftUIQuery",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SwiftUIQuery", targets: ["SwiftUIQuery"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.8.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.7.0")
    ],
    targets: targets
)
