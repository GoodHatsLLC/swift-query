// swift-tools-version: 6.1
import PackageDescription

var targets: [Target] = [
    .target(
        name: "SQLiteSnapshotShims",
        path: "Sources/SQLiteSnapshotShims",
        publicHeadersPath: "."
    ),
    .target(
        name: "SwiftQuery",
        dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            .product(name: "Crypto", package: "swift-crypto"),
            "SQLiteSnapshotShims",
            "SwiftThreadingShim"
        ]
    ),
    .target(
        name: "SwiftThreadingShim",
        path: "Sources/SwiftThreadingShim"
    ),
    .executableTarget(
        name: "TestApp",
        dependencies: ["SwiftQuery"],
        path: "Sources/TestApp"
    ),
    .testTarget(
        name: "SwiftQueryTests",
        dependencies: ["SwiftQuery"]
    )
]

#if os(Linux)
targets.removeAll { $0.name == "TestApp" }
#endif

let package = Package(
    name: "SwiftQuery",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SwiftQuery", targets: ["SwiftQuery"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.8.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.7.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0")
    ],
    targets: targets
)
