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
        // SVG file icons. Exact: 0.25+ needs SwiftUI preview macros the Command Line Tools lack.
        .package(url: "https://github.com/swhitty/SwiftDraw.git", exact: "0.24.0"),
    ],
    targets: [
        // Platform-neutral logic (tab status, command classification). No AppKit, but not ready for iOS as it
        // is: Process (how Git.swift runs git) and homeDirectoryForCurrentUser are macOS-only.
        .target(name: "NextTermCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(
            name: "NextTerm",
            dependencies: [
                "NextTermCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Shiki", package: "shiki-swift"),
                .product(name: "SwiftDraw", package: "SwiftDraw"),
            ]
        ),
        .testTarget(name: "NextTermCoreTests", dependencies: ["NextTermCore"]),
    ],
    swiftLanguageModes: [.v5]
)
