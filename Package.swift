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
        // TextMate grammars (as in VS Code), tokenized natively. Exact: 0.x and one author, so updates are
        // reviewed by hand. Only its engine ships; grammars come from Resources/Highlighting (licence-checked).
        .package(url: "https://github.com/fayazara/shiki-swift.git", exact: "0.1.2"),
    ],
    targets: [
        // Platform-neutral logic (tab status, command classification). No AppKit, so an iOS app can reuse it.
        .target(name: "NextTermCore"),
        .executableTarget(
            name: "NextTerm",
            dependencies: [
                "NextTermCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Shiki", package: "shiki-swift"),
            ]
        ),
        .testTarget(name: "NextTermCoreTests", dependencies: ["NextTermCore"]),
    ],
    swiftLanguageModes: [.v5]
)
