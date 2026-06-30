// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OntologyKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OntologyKit", targets: ["OntologyKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0")
    ],
    targets: [
        .target(
            name: "OntologyKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OntologyKitTests",
            dependencies: ["OntologyKit"]
        )
    ]
)
