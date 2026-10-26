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

    @Test func goToNextAgentNeedingYouIsShiftCommandUInEverySet() {
        // ⇧⌘U is no other command's in Next Term's set, VS Code's or JetBrains', the keys outside the menus included.
        let key = KeyChord(key: "u", command: true, shift: true)
        let bindings = KeyBindings()
        for preset in KeymapPreset.allCases {
            let keys = Self.defaults(under: preset)
            #expect((keys["goToNextAgentNeedingYou:"] ?? nil) == key, "\(preset.name)")
            let others: [String] = bindings.owners(of: key, defaults: keys, except: "goToNextAgentNeedingYou:")
            #expect(others.isEmpty, "\(preset.name): \(others)")
            #expect(bindings.sharers(of: key, defaults: keys, except: "goToNextAgentNeedingYou:").isEmpty, "\(preset.name)")
        }
        #expect(key.display == "⇧⌘U")
    }

    /// Tasks sits right after Agents, and Add Task… has ⌃⌘T in every set: no set gives that key to anything else.
    @Test func tasksComesAfterAgentsAndAddTaskIsControlCommandT() {
        #expect(MenuBar.titles == ["File", "Edit", "View", "Agents", "Tasks", "Secrets", "Git", "Notifications", "Window"])
        let tasks = MenuBar.neighbours(of: "Tasks"), notifications = MenuBar.neighbours(of: "Notifications")
        #expect(tasks.before == "Agents" && tasks.after == "Secrets")
        #expect(notifications.before == "Git" && notifications.after == "Window" && MenuBar.neighbours(of: "File").before == nil)
        let chord = KeyChord(key: "t", command: true, control: true)
        for preset in KeymapPreset.allCases {
            let keys = Self.defaults(under: preset)
            #expect(keys["addTask:"] == .some(chord), "\(preset.name)")
            #expect(KeyBindings().owners(of: chord, defaults: keys, except: "addTask:").isEmpty, "\(preset.name)")
        }
        #expect(chord.display == "⌃⌘T")
    }

    /// Wrap Up… has ⌃⌘W in every set: no set, no key outside the menus and nothing macOS keeps holds it, and an
    /// import that puts another command on ⌃⌘W, from any app's keys, is left unticked with Wrap Up named, never
    /// applied over it unseen.
    @Test func wrapUpIsControlCommandWInEverySet() {
        let chord = KeyChord(key: "w", command: true, control: true)
        #expect(MenuKeys.defaults["wrapUp:"] == chord)
        #expect(MenuKeys.defaults["postUpdate:"] == nil)
        #expect(ImportShortcuts.macOSKeys[chord] == nil && !ImportShortcuts.isShellKey(chord))
        #expect(MenuKeys.aliases[chord] == nil)
        for preset in KeymapPreset.allCases {
            let keys = Self.defaults(under: preset)
            #expect(keys["wrapUp:"] == .some(chord), "\(preset.name)")
            #expect(KeyBindings().owners(of: chord, defaults: keys, except: "wrapUp:").isEmpty, "\(preset.name)")
            #expect(KeyBindings().sharers(of: chord, defaults: keys, except: "wrapUp:").isEmpty, "\(preset.name)")
            // An imported row giving ⌃⌘W to Close Window, Soft Wrap or Close Tab: each is unticked, naming Wrap Up.
            for other in ["performClose:", "toggleSoftWrap:", "closeTab:"] {
                let row = ImportShortcuts.row(other, chord, source: "test: \(other)")
                let plan = ImportPlan(preset: preset, shortcuts: [row])
                let settled = plan.settlingShortcuts(current: keys, titles: ["wrapUp:": "Wrap Up…"])
                let left = settled.shortcuts.first
                #expect(left?.ticked == false, "\(preset.name): \(other)")
                #expect(left?.note?.contains("Wrap Up…’s") == true, "\(preset.name): \(left?.note ?? "")")
            }
        }
        #expect(chord.display == "⌃⌘W")
    }

    /// View › Expand Window Column has ⌃⌘S in every set: no set, no key outside the menus and nothing macOS keeps holds it,
    /// and ⌘S and ⌥⌘S stay Save's and Save All's.
    @Test func expandWindowColumnIsControlCommandSInEverySet() {
        let chord = KeyChord(key: "s", command: true, control: true)
        #expect(MenuKeys.defaults["toggleWindowColumnExpanded:"] == chord)
        #expect(MenuKeys.defaults["toggleWindowColumn:"] == nil) // Hide Window Column has no key
        #expect(MenuKeys.defaults["saveDocument:"] == KeyChord(key: "s", command: true))
        #expect(MenuKeys.defaults["saveAllDocuments:"] == KeyChord(key: "s", command: true, option: true))
        #expect(ImportShortcuts.macOSKeys[chord] == nil && !ImportShortcuts.isShellKey(chord))
        #expect(MenuKeys.aliases[chord] == nil)
        for preset in KeymapPreset.allCases {
            let keys = Self.defaults(under: preset)
            #expect(keys["toggleWindowColumnExpanded:"] == .some(chord), "\(preset.name)")
            #expect(KeyBindings().owners(of: chord, defaults: keys, except: "toggleWindowColumnExpanded:").isEmpty, "\(preset.name)")
            #expect(KeyBindings().sharers(of: chord, defaults: keys, except: "toggleWindowColumnExpanded:").isEmpty, "\(preset.name)")
        }
        #expect(chord.display == "⌃⌘S")
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

    // MARK: Markdown

    /// ⇧⌘V switches the Markdown file in front between Live Preview and its source in every set, as it opens VS Code's
    /// preview, and a VS Code binding of that preview lands on it.
    @Test func markdownLivePreviewIsShiftCommandVInEverySet() {
        let shiftV = KeyChord(key: "v", command: true, shift: true)
        for preset in KeymapPreset.allCases {
            #expect(Self.defaults(under: preset)["toggleMarkdownPreview:"] == .some(shiftV), "\(preset.name)")
        }
        #expect(ImportVSCode.commandMap["markdown.showPreview"] == "toggleMarkdownPreview:")
        #expect(ImportShortcuts.titles["toggleMarkdownPreview:"] == "Markdown Live Preview")
    }

    static let commandB = KeyChord(key: "b", command: true)

    /// ⌘B is Bold only while a Markdown file's editor has the keyboard, and Hide Project Sidebar everywhere else. Every
    /// Markdown command keeps to its place so; no other editor command shares a key with a command for everywhere.
    @Test func boldSharesCommandBWithTheSidebarOnlyInAMarkdownEditor() {
        let bindings = KeyBindings()
        let keys = Self.defaults(under: .nextTerm)
        #expect(keys["toggleMarkdownBold:"] == .some(Self.commandB) && keys["toggleProjectSidebar:"] == .some(Self.commandB))
        #expect(KeyBindings.canShareKey("toggleMarkdownBold:", "toggleProjectSidebar:"))
        #expect(KeyBindings.canShareKey("toggleProjectSidebar:", "toggleMarkdownBold:"))
        #expect(KeyBindings.canShareKey("toggleMarkdownItalic:", "toggleProjectSidebar:"))
        #expect(!KeyBindings.canShareKey("toggleMarkdownItalic:", "duplicateLine:"))
        #expect(!KeyBindings.canShareKey("duplicateLine:", "toggleProjectSidebar:"))
        #expect(bindings.sharers(of: Self.commandB, defaults: keys, except: "toggleMarkdownBold:") == ["toggleProjectSidebar:"])
        let titles = ["toggleMarkdownBold:": "Bold", "toggleProjectSidebar:": "Hide Project Sidebar"]
        let note = KeyBindings.sharingNote(Self.commandB, ["toggleMarkdownBold:", "toggleProjectSidebar:"], title: { titles[$0] ?? $0 })
        #expect(note == "⌘B is Bold while a Markdown file’s editor has the keyboard, Hide Project Sidebar everywhere else")
    }

    /// ⌘K is Link in a Markdown file's editor and Clear Buffer everywhere else; under JetBrains' set ⌘K is Commit…, a
    /// command for everywhere, so Link has no key there.
    @Test func linkSharesCommandKWithClearBuffer() {
        let bindings = KeyBindings()
        let keys = Self.defaults(under: .nextTerm)
        let commandK = KeyChord(key: "k", command: true)
        #expect(keys["insertMarkdownLink:"] == .some(commandK))
        #expect(bindings.owners(of: commandK, defaults: keys, except: "insertMarkdownLink:").isEmpty)
        let titles = ["insertMarkdownLink:": "Link", "clearBuffer:": "Clear Buffer"]
        let note = KeyBindings.sharingNote(commandK, ["insertMarkdownLink:", "clearBuffer:"], title: { titles[$0] ?? $0 })
        #expect(note == "⌘K is Link while a Markdown file’s editor has the keyboard, Clear Buffer everywhere else")
        #expect(Self.defaults(under: .jetBrains)["insertMarkdownLink:"] == .some(nil))
    }

    @Test func theMarkdownKeys() {
        let keys = Self.defaults(under: .nextTerm)
        func shown(_ id: String) -> String { (keys[id] ?? nil)?.display ?? "none" }
        #expect(shown("toggleMarkdownItalic:") == "⌘I" && shown("toggleMarkdownStrikethrough:") == "⇧⌘X")
        #expect(shown("toggleMarkdownTask:") == "⇧⌘L" && shown("markdownBodyText:") == "⌥⌘0")
        #expect((1...6).map { shown("markdownHeading:#\($0)") } == (1...6).map { "⌥⌘\($0)" })
        #expect(shown("toggleMarkdownCode:") == "none" && shown("insertMarkdownCodeBlock:") == "none")
        // Edit › Markdown's are the editor's; the switch and Go to Heading are the window's.
        #expect(KeyBindings.markdownCommands.isSubset(of: KeyBindings.editorCommands) && KeyBindings.markdownCommands.count == 17)
        for id in MenuKeys.defaults.keys where id.lowercased().contains("markdown") {
            #expect(KeyBindings.editorCommands.contains(id) == (id != "toggleMarkdownPreview:"), "\(id)")
        }
        #expect(KeyBindings.scope(of: "goToHeading:") == .everywhere)
    }

    /// Go to Heading is ⇧⌘O, VS Code's Go to Symbol; under JetBrains' keys, where ⇧⌘O is Go to File, it is ⌘F12.
    @Test func goToHeadingIsShiftCommandOOrCommandF12() {
        func shown(_ preset: KeymapPreset) -> String { (Self.defaults(under: preset)["goToHeading:"] ?? nil)?.display ?? "none" }
        #expect(shown(.nextTerm) == "⇧⌘O" && shown(.vsCode) == "⇧⌘O")
        #expect(shown(.jetBrains) == KeyChord(key: "\u{F70F}", command: true).display)
        #expect((Self.defaults(under: .jetBrains)["goToFile:"] ?? nil)?.display == "⇧⌘O")
    }
}
