// swift-tools-version:5.2
import PackageDescription

//VS
let package = Package(
    name: "leaf",
    platforms: [
       .macOS(.v10_15),
        .iOS(.v13)
    ],
    products: [
        .library(name: "Leaf", targets: ["Leaf"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/leaf-kit.git", from: "1.0.0"),
//        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
        .package(url: "https://github.com/radbench/vapor.git", .branch("master")),
    ],
    targets: [
        .target(name: "Leaf", dependencies: [
            .product(name: "LeafKit", package: "leaf-kit"),
            .product(name: "Vapor", package: "vapor"),
        ]),
        .testTarget(name: "LeafTests", dependencies: [
            .target(name: "Leaf"),
            .product(name: "XCTVapor", package: "vapor"),
        ]),
    ]
)
