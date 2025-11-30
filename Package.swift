// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SwiftUIQuery",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SwiftUIQuery", targets: ["SwiftUIQuery"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.8.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.1.0")
    ],
    targets: [
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
)
