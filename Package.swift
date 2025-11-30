// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftQuery",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SwiftQuery", targets: ["SwiftQuery"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "SwiftQuery",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "SwiftQueryTests",
            dependencies: ["SwiftQuery"]
        )
    ]
)
