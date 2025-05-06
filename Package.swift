// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "NetifyAuth",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "NetifyAuth",
            targets: ["NetifyAuth"]),
    ],
    dependencies: [
        .package(url: "https://github.com/AidenJLee/Netify.git", from: "2.0.2"),
    ],
    targets: [
        .target(
            name: "NetifyAuth",
            dependencies: [
                // Netify 제품에 대한 의존성 명시
                .product(name: "Netify", package: "Netify"),
            ],
            path: "Sources"),

        .testTarget(
            name: "NetifyAuthTests",
            dependencies: ["NetifyAuth"]),
    ]
)
