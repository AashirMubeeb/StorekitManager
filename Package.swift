// swift-tools-version: 6.0.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StorekitManager",
    platforms: [
        .iOS(.v15),    // Minimum iOS version
        .macOS(.v12)   // Minimum macOS version
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "StorekitManager",
            targets: ["StorekitManager"]),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "StorekitManager"),
        .testTarget(
            name: "StorekitManagerTests",
            dependencies: ["StorekitManager"]
        ),
    ]
)

