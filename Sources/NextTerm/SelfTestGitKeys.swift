import AppKit
import NextTermCore

/// The keys of View › Unified Diffs, Annotate with Git Blame and Current Line Blame, and of Git › Fetch, Update Project,
/// Commit…, Push… and New Branch…: the menus as built have the keys the unit tests check for clashes (MenuKeys), each
/// item shows its key under every set of keys, Settings says where ⌘R is the branch popup's Fetch, and a key you gave
/// another command before it was one of these commands' default stays yours.
extension SelfTest {
    /// The commands, with their keys in Next Term's set.
    static let gitAndViewKeys: [(id: String, key: String)] = [
        ("gitFetch:", "⌘R"), ("gitUpdate:", "⌥⌘U"), ("gitCommit:", "⇧⌘C"), ("gitPush:", "⌥⌘P"), ("gitNewBranch:", "⇧⌘B"),
        ("toggleUnifiedDiffs:", "⌃⌘U"), ("toggleBlameAnnotations:", "⌃⇧⌘A"), ("toggleCurrentLineBlame:", "⌃⇧⌘L"),
    ]

    static func gitAndViewKeyChecks(_ c: TerminalWindowController, proj: URL) async {
        let shortcuts = KeyboardShortcuts.shared
        let savedBindings = shortcuts.bindings, savedPreset = shortcuts.preset
        defer {
            shortcuts.bindings = savedBindings
            shortcuts.preset = savedPreset // applies both
        }
        shortcuts.preset = .nextTerm
        shortcuts.resetAll()
        func shown(_ id: String) -> String {
            shortcuts.commands.first { $0.id == id }?.item.flatMap(KeyboardShortcuts.chord(of:))?.display ?? "none"
        }

        // The menus as built are MenuKeys, which the unit tests check for clashes under every set.
        var built: [String: KeyChord] = [:]
        for command in shortcuts.commands where command.item != nil { built[command.id] = command.defaultChord }
        let drift = Set(built.keys).union(MenuKeys.defaults.keys).filter { built[$0] != MenuKeys.defaults[$0] }.sorted()
        check(drift.isEmpty, "menu keys: the menus as built have the keys MenuKeys lists for the unit tests",
              drift.map { "\($0) \(built[$0]?.display ?? "none"), listed \(MenuKeys.defaults[$0]?.display ?? "none")" }.joined(separator: "; "))
        check(shortcuts.aliases == MenuKeys.aliases, "menu keys: and so are the hidden items' keys",
              shortcuts.aliases.map { "\($0.key.display) \($0.value)" }.joined(separator: ", "))

        // Each item shows its key, in every set (JetBrains': Fetch ⌥⌘F, as ⌘R is Replace… there).
        let ids = gitAndViewKeys.map(\.id)
        check(ids.map(shown) == gitAndViewKeys.map(\.key), "view and git keys: each menu item shows its key", ids.map(shown).joined(separator: " "))
        for preset in KeymapPreset.allCases where preset != .nextTerm {
            shortcuts.preset = preset
            let expected = ids.map { shortcuts.baseChord(for: $0)?.display ?? "none" }
            let fetch = preset == .jetBrains ? "⌥⌘F" : "⌘R"
            check(ids.map(shown) == expected && shown("gitFetch:") == fetch && !expected.contains("none"),
                  "view and git keys: and under \(preset.name)'s keys", ids.map(shown).joined(separator: " "))
        }
        shortcuts.preset = .nextTerm

        // ⌘R is Fetch in the branch popup too, and Settings says which has it where.
        let fetchTip = ShortcutRecorder(commandID: "gitFetch:").toolTip
        check(fetchTip == "⌘R is Fetch while the branch popup is open, Fetch everywhere else", "Settings says ⌘R is the branch popup's Fetch too",
              fetchTip ?? "no tooltip")

        // A key you gave another command before it was Commit…'s default stays yours: Commit… has none until yours moves.
        let shiftCommandC = KeyChord(key: "c", command: true, shift: true)
        shortcuts.set(shiftCommandC, for: "toggleSoftWrap:")
        let taken = [shown("gitCommit:"), shown("toggleSoftWrap:"), shortcuts.chord(for: "gitCommit:")?.display ?? "none"]
            + shortcuts.bindings.owners(of: shiftCommandC, defaults: shortcuts.defaults, except: "goToLine:")
        check(taken == ["none", "⇧⌘C", "none", "toggleSoftWrap:"], "a key you gave a command before it was Commit…'s default stays yours",
              taken.joined(separator: " "))
        shortcuts.reset("toggleSoftWrap:")
        check(shown("gitCommit:") == "⇧⌘C" && shown("toggleSoftWrap:") == "none", "and Commit… has ⇧⌘C again once yours moves",
              "\(shown("gitCommit:")) \(shown("toggleSoftWrap:"))")
    }
}
