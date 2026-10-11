import Foundation

/// One of the options a Remote access connection holds (the plan's Connection Options table): what the user lets
/// that connection do, picked on the Mac when it pairs and changed only there. Each option names the tools it
/// admits. A tool no option names is never offered remotely, whatever its annotations or scope tag say (allow by
/// name), so a tool a later release adds stays local until an option names it.
///
/// For now only the See options name tools; the others admit none until the control options are built. Nothing
/// names the import tools (list_import_sources, preview_import, apply_import, undo_import), which stay local. The
/// Secrets group joins the table only once plan 007's secret tools are in the base (decided 2026-10-11).
public struct RemoteAccessOption: Sendable {
    /// The option's stable key, as a grant file stores it. Never renamed: a grant saved with it keeps its value.
    public enum ID: String, CaseIterable, Codable, Sendable {
        case tabs = "see.tabs"
        case projectFiles = "see.project_files"
        case editor = "see.editor"
        case serversRead = "see.servers"
        case typeAsking = "agents.type_asking"
        case typeNeverAsking = "agents.type_never_asking"
        case answerOnce = "agents.answer_once"
        case answerStanding = "agents.answer_standing"
        case slashAllowlist = "text.slash_allowlist"
        case anySlash = "text.any_slash"
        case shellAndMemory = "text.shell_and_memory"
        case safeKeys = "keys.safe"
        case everyKey = "keys.every"
        case typeShells = "shells.type"
        case openAgentTab = "tabs.open_agent"
        case openAnyTab = "tabs.open_any"
        case closeIdleTabs = "tabs.close_idle"
        case closeBusyTabs = "tabs.close_busy"
        case showOnMac = "more.show_on_mac"
        case servers = "more.servers"
        case skills = "more.skills"
        case writeTools = "more.write_tools"
        case askOnMac = "checks.ask_on_mac"
        case notify = "checks.notify"
        case rateLimit = "checks.rate_limit"
    }

    /// The groups, in the order the pairing window and Edit… show them.
    public enum Group: String, CaseIterable, Sendable {
        case see, agents, text, keys, shells, tabs, moreTools, checks

        public var title: String {
            switch self {
            case .see: return "See"
            case .agents: return "Agents"
            case .text: return "Text"
            case .keys: return "Keys"
            case .shells: return "Shells"
            case .tabs: return "Tabs"
            case .moreTools: return "More tools"
            case .checks: return "Checks"
            }
        }
    }

    public let id: ID
    public let group: Group
    /// Its checkbox label, which every refusal that names it quotes.
    public let label: String
    /// Its value in Control.
    public let control: Bool
    /// Its value when Custom starts: the safe defaults.
    public let customStart: Bool
    /// The tools it admits, by name.
    public let tools: [String]

    /// Every option, in the table's order (one entry per row, each added in its own step).
    public static let all: [RemoteAccessOption] = {
        var rows: [RemoteAccessOption] = []
        func add(_ id: ID, _ group: Group, _ label: String, control: Bool, custom: Bool, tools: [String] = []) {
            rows.append(RemoteAccessOption(id: id, group: group, label: label, control: control, customStart: custom, tools: tools))
        }
        add(.tabs, .see, "Tabs and their output", control: true, custom: true,
            tools: ["list_tabs", "read_tab", "wait_for_tab"])
        add(.projectFiles, .see, "Project files, diffs and git", control: true, custom: true,
            tools: ["list_projects", "read_file", "find_in_files", "git_status", "get_diff"])
        add(.editor, .see, "Editor selection and open files", control: true, custom: true,
            tools: ["get_editor_selection", "get_open_files"])
        add(.serversRead, .see, "Servers: list, check and read changes", control: true, custom: false,
            tools: ["list_hosts", "check_host", "host_sessions", "host_changes"])
        add(.typeAsking, .agents, "Type into agents that ask before acting", control: true, custom: true)
        add(.typeNeverAsking, .agents, "Type into agents that never ask, or whose mode can't be read", control: true, custom: false)
        add(.answerOnce, .agents, "Answer with a one-time choice", control: true, custom: true)
        add(.answerStanding, .agents, "Answer with standing choices, such as always or don't ask again", control: true, custom: false)
        add(.slashAllowlist, .text, "/ commands on the allowlist", control: true, custom: true)
        add(.anySlash, .text, "Any / command", control: true, custom: false)
        add(.shellAndMemory, .text, "! shell lines and # memory lines", control: true, custom: false)
        add(.safeKeys, .keys, "Arrows, Return and Escape", control: true, custom: true)
        add(.everyKey, .keys, "Every key", control: true, custom: false)
        add(.typeShells, .shells, "Type into shell tabs", control: true, custom: false)
        add(.openAgentTab, .tabs, "Open a tab that runs a listed agent", control: true, custom: true)
        add(.openAnyTab, .tabs, "Open a tab with any command, or a plain shell", control: true, custom: false)
        add(.closeIdleTabs, .tabs, "Close tabs where nothing runs", control: true, custom: true)
        add(.closeBusyTabs, .tabs, "Close busy tabs", control: true, custom: false)
        add(.showOnMac, .moreTools, "Open projects and show things on the Mac", control: true, custom: false)
        add(.servers, .moreTools, "Servers: add, remove and open tabs", control: true, custom: false)
        add(.skills, .moreTools, "Skills", control: true, custom: false)
        add(.writeTools, .moreTools, "Next Term's write tools", control: true, custom: true)
        add(.askOnMac, .checks, "Ask on this Mac before changes", control: false, custom: true)
        add(.notify, .checks, "Notify on this Mac", control: true, custom: true)
        add(.rateLimit, .checks, "At most 10 control calls a minute", control: false, custom: true)
        return rows
    }()

    private static let byID: [ID: RemoteAccessOption] = {
        var byID: [ID: RemoteAccessOption] = [:]
        for option in all { byID[option.id] = option }
        return byID
    }()

    /// Every ID has its row (RemoteAccessToolsTests checks it).
    public static func option(_ id: ID) -> RemoteAccessOption { byID[id]! }
}

/// A connection's options: one value per option, as its grant holds them.
public struct RemoteAccessOptions: Equatable, Sendable, Codable {
    /// The values by key, as the grant file holds them. A key it does not hold, such as an option a later
    /// release adds, reads as on for a Checks option and as off in every other group, Text and Keys included.
    /// Only this release's keys are kept: any other, such as U1's old stub keys for the Secrets group, is dropped
    /// when the set is read, so it turns nothing on and is never written back.
    public private(set) var stored: [String: Bool]

    public init(stored: [String: Bool]) {
        self.stored = stored.filter { RemoteAccessOption.ID(rawValue: $0.key) != nil }
    }

    /// Every option set: the ones in `on` on, the rest off.
    public init(on: Set<RemoteAccessOption.ID>) {
        var stored: [String: Bool] = [:]
        for id in RemoteAccessOption.ID.allCases { stored[id.rawValue] = on.contains(id) }
        self.stored = stored
    }

    public subscript(_ id: RemoteAccessOption.ID) -> Bool {
        get {
            if let value = stored[id.rawValue] { return value }
            return RemoteAccessOption.option(id).group == .checks
        }
        set { stored[id.rawValue] = newValue }
    }

    /// The options that are on.
    public var on: Set<RemoteAccessOption.ID> {
        Set(RemoteAccessOption.ID.allCases.filter { self[$0] })
    }

    /// The preset these options carry the name of.
    public var preset: RemoteAccessPreset { RemoteAccessPreset.named(self) }

    /// Two sets are the same when every option reads the same, however the grant file spells it.
    public static func == (a: RemoteAccessOptions, b: RemoteAccessOptions) -> Bool {
        a.on == b.on
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(stored: try container.decode([String: Bool].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stored)
    }

    /// Read only: "Tabs and their output", "Project files, diffs and git" and "Editor selection and open files",
    /// the Checks options as Custom starts, and nothing else.
    public static let readOnly: RemoteAccessOptions = {
        let see: Set<RemoteAccessOption.ID> = [.tabs, .projectFiles, .editor]
        let checks = RemoteAccessOption.all.filter { $0.group == .checks && $0.customStart }
        return RemoteAccessOptions(on: see.union(checks.map(\.id)))
    }()

    /// Control: every option outside Checks, and "Notify on this Mac".
    public static let control: RemoteAccessOptions = {
        let on = RemoteAccessOption.all.filter(\.control)
        return RemoteAccessOptions(on: Set(on.map(\.id)))
    }()

    /// Custom's starting values: the safe defaults.
    public static let customStart: RemoteAccessOptions = {
        let on = RemoteAccessOption.all.filter(\.customStart)
        return RemoteAccessOptions(on: Set(on.map(\.id)))
    }()
}

/// The three presets pairing offers.
public enum RemoteAccessPreset: String, CaseIterable, Sendable {
    case readOnly, control, custom

    /// Pairing opens with Read only picked; Control is never preselected.
    public static let preselected = RemoteAccessPreset.readOnly

    public var title: String {
        switch self {
        case .readOnly: return "Read only"
        case .control: return "Control"
        case .custom: return "Custom"
        }
    }

    /// The options picking it sets. Custom opens the checkboxes at its starting values.
    public var options: RemoteAccessOptions {
        switch self {
        case .readOnly: return .readOnly
        case .control: return .control
        case .custom: return .customStart
        }
    }

    /// The preset a set of options is named for:
    /// - Read only, when every option outside Checks reads as in Read only (the Checks never change the name);
    /// - Control, when every option outside Checks is on and "Ask on this Mac before changes" is off ("Notify on
    ///   this Mac" and "At most 10 control calls a minute" never change it);
    /// - Custom otherwise.
    public static func named(_ options: RemoteAccessOptions) -> RemoteAccessPreset {
        let outsideChecks = RemoteAccessOption.all.filter { $0.group != .checks }
        let readOnly = RemoteAccessOptions.readOnly
        if outsideChecks.allSatisfy({ options[$0.id] == readOnly[$0.id] }) { return .readOnly }
        let everyOneOn = outsideChecks.allSatisfy { options[$0.id] }
        if everyOneOn && !options[.askOnMac] { return .control }
        return .custom
    }
}
