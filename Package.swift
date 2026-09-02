// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Kjol",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "KjolLogic", targets: ["KjolLogic"])
    ],
    targets: [
        .target(
            name: "KjolLogic",
            path: "Sources/KjolLogic"
        ),
        .testTarget(
            name: "KjolLogicTests",
            dependencies: ["KjolLogic"],
            path: "Tests/KjolLogicTests"
        )
    ]
)
