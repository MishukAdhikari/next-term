// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NextTerm",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NextTerm", targets: ["NextTerm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        // Platform-neutral logic (tab status, command classification). No AppKit, so an iOS app can reuse it.
        .target(name: "NextTermCore"),
        .executableTarget(
            name: "NextTerm",
            dependencies: ["NextTermCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(name: "NextTermCoreTests", dependencies: ["NextTermCore"]),
    ],
    swiftLanguageModes: [.v5]
)
