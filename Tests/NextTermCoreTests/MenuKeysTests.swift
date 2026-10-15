import Testing
@testable import NextTermCore

struct MenuKeysTests {
    /// Every command's key under `preset` before the user's own changes: the menus', the keys outside them, and the set's
    /// on top, as KeyboardShortcuts lays them.
    static func defaults(under preset: KeymapPreset) -> [String: KeyChord?] {
        var keys: [String: KeyChord?] = MenuKeys.defaults.mapValues { $0 }
        for command in KeyBindings.partCommands { keys[command.id] = .some(command.chord) }
        for (id, chord) in preset.overrides { keys[id] = .some(chord) }
        return keys
    }

    static let commandR = KeyChord(key: "r", command: true)

    @Test func noDefaultClashesInAnySet() {
        let bindings = KeyBindings()
        for preset in KeymapPreset.allCases {
            let keys = Self.defaults(under: preset)
            for id in keys.keys.sorted() {
                guard let chord = keys[id] ?? nil else { continue }
                // A key is one command's per part of the window (KeyBindings.canShareKey).
                #expect(bindings.owners(of: chord, defaults: keys, except: id).isEmpty, "\(preset.name): \(id) \(chord.display)")
                // Not a hidden item's (⌘= for Bigger), not one macOS keeps, and one that never swallows typing.
                #expect(MenuKeys.aliases[chord].map { $0 == id } ?? true, "\(preset.name): \(id) \(chord.display) is a hidden item's")
                #expect(ImportShortcuts.macOSKeys[chord] == nil, "\(preset.name): \(id) \(chord.display) is macOS's")
                #expect(KeyBindings.isUsable(chord, for: id), "\(preset.name): \(id) \(chord.display)")
            }
            // A set changes only commands there are.
            let known = Set(keys.keys)
            #expect(preset.overrides.keys.allSatisfy { known.contains($0) }, "\(preset.name)")
        }
    }

    @Test func fetchUpdateCommitPushNewBranchAndTheViewTogglesHaveKeysInEverySet() {
        let ids = ["gitFetch:", "gitUpdate:", "gitCommit:", "gitPush:", "gitNewBranch:", "toggleUnifiedDiffs:", "toggleBlameAnnotations:",
                   "toggleCurrentLineBlame:"]
        func shown(_ preset: KeymapPreset) -> [String: String] {
            let keys = Self.defaults(under: preset)
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, (keys[$0] ?? nil)?.display ?? "none") })
        }
        let nextTerm = shown(.nextTerm)
        #expect(ids.map { nextTerm[$0] ?? "" } == ["⌘R", "⌥⌘U", "⇧⌘C", "⌥⌘P", "⇧⌘B", "⌃⌘U", "⌃⇧⌘A", "⌃⇧⌘L"])
        #expect(shown(.vsCode) == nextTerm)
        // JetBrains' set: ⌘R is Replace… there, so Fetch is ⌥⌘F (Replace…'s in Next Term's). Commit… and Push… are Next
        // Term's until the set gives them the IDE's own ⌘K and ⇧⌘K; the rest are Next Term's.
        let jetBrains = shown(.jetBrains)
        #expect(jetBrains["gitFetch:"] == "⌥⌘F")
        #expect(jetBrains["gitCommit:"] == nextTerm["gitCommit:"] || jetBrains["gitCommit:"] == "⌘K")
        #expect(jetBrains["gitPush:"] == nextTerm["gitPush:"] || jetBrains["gitPush:"] == "⇧⌘K")
        for id in ids where !["gitFetch:", "gitCommit:", "gitPush:"].contains(id) { #expect(jetBrains[id] == nextTerm[id], "\(id)") }
        // None is a Control key without ⌘, which belongs to the shell and the agents.
        for preset in KeymapPreset.allCases {
            let keys = Self.defaults(under: preset)
            #expect(ids.allSatisfy { id in (keys[id] ?? nil).map { !ImportShortcuts.isShellKey($0) } ?? false }, "\(preset.name)")
        }
    }

    /// Tasks sits right after Agents, and Add Task… has ⌃⌘T in every set: no set gives that key to anything else.
    @Test func tasksComesAfterAgentsAndAddTaskIsControlCommandT() {
        #expect(MenuBar.titles == ["File", "Edit", "View", "Agents", "Tasks", "Git", "Notifications", "Window"])
        let tasks = MenuBar.neighbours(of: "Tasks"), notifications = MenuBar.neighbours(of: "Notifications")
        #expect(tasks.before == "Agents" && tasks.after == "Git")
        #expect(notifications.before == "Git" && notifications.after == "Window" && MenuBar.neighbours(of: "File").before == nil)
        let chord = KeyChord(key: "t", command: true, control: true)
        for preset in KeymapPreset.allCases {
            let keys = Self.defaults(under: preset)
            #expect(keys["addTask:"] == .some(chord), "\(preset.name)")
            #expect(KeyBindings().owners(of: chord, defaults: keys, except: "addTask:").isEmpty, "\(preset.name)")
        }
        #expect(chord.display == "⌃⌘T")
    }

    @Test func fetchSharesCommandRWithTheBranchPopupsFetch() {
        let bindings = KeyBindings()
        let keys = Self.defaults(under: .nextTerm)
        #expect(bindings.sharers(of: Self.commandR, defaults: keys, except: "gitFetch:") == ["branchPopup.fetch"])
        #expect(bindings.owners(of: Self.commandR, defaults: keys, except: "gitFetch:").isEmpty)
        let titles = ["gitFetch:": "Fetch", "branchPopup.fetch": "Fetch"]
        #expect(KeyBindings.sharingNote(Self.commandR, ["gitFetch:", "branchPopup.fetch"], title: { titles[$0] ?? $0 })
            == "⌘R is Fetch while the branch popup is open and everywhere else")
        // Under JetBrains' set ⌘R is Replace…, which the popup's Fetch shares it with in turn.
        let jetBrains = Self.defaults(under: .jetBrains)
        #expect(bindings.sharers(of: Self.commandR, defaults: jetBrains, except: "replaceInFile:") == ["branchPopup.fetch"])
        // Another command given ⌘R takes it from Fetch, as from any command for everywhere.
        #expect(bindings.owners(of: Self.commandR, defaults: keys, except: "goToLine:") == ["gitFetch:"])
    }
}
