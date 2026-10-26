// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SPUltra",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "SPUltra", targets: ["SPUltra"]),
        .executable(name: "SPUltraMCP", targets: ["SPUltraMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", exact: "0.3.7"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.1"),
    ],
    targets: [
        .executableTarget(
            name: "SPUltra",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            resources: [.copy("Resources/donation-trc20.png")]
        ),
        .executableTarget(
            name: "SPUltraMCP",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "SPUltraTests", dependencies: ["SPUltra", "SPUltraMCP"]),
    ]
)
