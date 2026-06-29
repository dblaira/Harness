// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OntologyKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OntologyKit", targets: ["OntologyKit"])
    ],
    targets: [
        .target(
            name: "OntologyKit",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OntologyKitTests",
            dependencies: ["OntologyKit"]
        )
    ]
)
