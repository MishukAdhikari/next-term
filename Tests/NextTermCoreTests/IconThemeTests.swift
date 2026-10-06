import Foundation
import Testing
@testable import NextTermCore

/// Checked against the shipped theme (Resources/Icons/theme.json), with the lookups the research verified
/// against VS Code's own rules.
@Suite struct IconThemeTests {
    static let theme: IconTheme? = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Icons/theme.json")
        return (try? Data(contentsOf: url)).flatMap(IconTheme.load)
    }()

    @Test func filesByNameExtensionAndLanguage() throws {
        let theme = try #require(Self.theme)
        let cases: [(String, String?, String)] = [
            ("welcome.blade.php", "views", "laravel"),     // compound extension beats php
            ("artisan", nil, "laravel"),
            ("lib.d.ts", nil, "typescript-def"),
            ("Dockerfile", nil, "docker"),
            ("App.tsx", nil, "react_ts"),
            ("styles.scss", nil, "sass"),
            ("next.config.mjs", nil, "next"),
            ("vite.config.ts", nil, "vite"),
            ("tailwind.config.js", nil, "tailwindcss"),
            ("composer.json", nil, "php"),                 // Next Term's overlay
            ("web.php", "routes", "routing"),              // parent-qualified extension, overlay
            ("web.php", "app", "php"),
            ("ci.yml", "workflows", "github-actions-workflow"),
            ("Cargo.toml", nil, "rust"),
            ("+page.server.ts", "routes", "svelte_ts"),
            ("weird.xyz", nil, "file"),
        ]
        for (name, parent, expected) in cases {
            #expect(theme.icon(forFile: name, parent: parent) == expected, "\(name) in \(parent ?? "-")")
        }
        // No extension: the language decides.
        #expect(theme.icon(forFile: "deploy", language: "shellscript") != theme.file)
    }

    @Test func foldersOpenAndClosed() throws {
        let theme = try #require(Self.theme)
        #expect(theme.icon(forFolder: "app", expanded: false) == "folder-app")
        #expect(theme.icon(forFolder: "app", expanded: true) == "folder-app-open")
        #expect(theme.icon(forFolder: "node_modules", expanded: false) == "folder-node")
        #expect(theme.icon(forFolder: "workflows", parent: ".github", expanded: false) == "folder-gh-workflows")
        #expect(theme.icon(forFolder: "Livewire", expanded: false) == "folder-components")
        #expect(theme.icon(forFolder: "something", expanded: false) == theme.folder)
        #expect(theme.icon(forFolder: "xCloud", expanded: true, isRoot: true) == theme.rootFolderExpanded)
    }
}
