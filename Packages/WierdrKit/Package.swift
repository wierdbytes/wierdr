// swift-tools-version: 6.0
//
// WierdrKit: everything in Wierdr that is not UI.
//
//   HerdrCore    herdr-core API client: framing, JSON-RPC, attach streams, events.
//                Transport-agnostic (talks to any byte pipe).
//   HerdrSSH     The byte pipe on iOS: SSH (SwiftNIO SSH) exec of `hc connect`,
//                plus key management (Ed25519 via CryptoKit, Keychain).
//   WierdrModel  The Herdr world as the app shows it: spaces, tabs, panes,
//                agents, statuses (from the `herdr-app` document + terminals).
//   wierdr-cli   macOS-only debugging tool: talks to the local core through
//                `hc connect` and prints what the model sees.
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "WierdrKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "HerdrCore", targets: ["HerdrCore"]),
        .library(name: "HerdrSSH", targets: ["HerdrSSH"]),
        .library(name: "WierdrModel", targets: ["WierdrModel"]),
        .executable(name: "wierdr-cli", targets: ["wierdr-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "HerdrCore",
            swiftSettings: swift5
        ),
        .target(
            name: "HerdrSSH",
            dependencies: [
                "HerdrCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: swift5
        ),
        .target(
            name: "WierdrModel",
            dependencies: ["HerdrCore"],
            swiftSettings: swift5
        ),
        .executableTarget(
            name: "wierdr-cli",
            dependencies: ["HerdrCore", "HerdrSSH", "WierdrModel"],
            swiftSettings: swift5
        ),
        .testTarget(
            name: "HerdrCoreTests",
            dependencies: ["HerdrCore", "HerdrSSH"],
            swiftSettings: swift5
        ),
        .testTarget(
            name: "HerdrSSHTests",
            dependencies: ["HerdrSSH", "HerdrCore"],
            swiftSettings: swift5
        ),
        .testTarget(
            name: "WierdrModelTests",
            dependencies: ["WierdrModel", "HerdrCore"],
            swiftSettings: swift5
        ),
    ]
)
