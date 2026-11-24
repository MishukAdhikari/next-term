import AppIntents
import AppKit

// Spotlight and Shortcuts actions. Each one opens the nextterm:// link that does the same thing (docs/launchers.md),
// so they do no more than a link from a web page could: Start Agent still asks on the Mac before anything runs.
//
// This file stands alone (AppIntents, AppKit and Foundation only): the release build compiles it once more by itself
// to give Xcode's appintentsmetadataprocessor the compiler's constant values, and writes Metadata.appintents into the
// app (scripts/app-intents.sh). Without Xcode that file is left out, and macOS then lists none of these actions.

@available(macOS 13.0, *)
enum LauncherLink {
    /// Opens a nextterm:// link in this app, which is already running: an intent with openAppWhenRun runs inside it.
    @MainActor
    static func open(_ host: String, _ query: [URLQueryItem] = []) {
        var parts = URLComponents()
        parts.scheme = "nextterm"
        parts.host = host
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// A folder from Shortcuts as the path a link takes.
    static func path(of folder: IntentFile) throws -> String {
        guard let url = folder.fileURL else { throw LauncherError.notAFolder }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw LauncherError.notAFolder
        }
        return url.path
    }
}

@available(macOS 13.0, *)
enum LauncherError: Error, CustomLocalizedStringResourceConvertible {
    case notAFolder

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notAFolder: "Choose a folder on this Mac."
        }
    }
}

@available(macOS 13.0, *)
struct GoToWaitingAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "Go to Waiting Agent"
    static var description = IntentDescription("Brings forward the tab whose agent waits for you.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LauncherLink.open("attention")
        return .result()
    }
}

@available(macOS 13.0, *)
struct GoToAnythingIntent: AppIntent {
    static var title: LocalizedStringResource = "Go to Anything"
    static var description = IntentDescription("Opens Go to Anything over the window in front.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LauncherLink.open("goto")
        return .result()
    }
}

@available(macOS 13.0, *)
struct OpenProjectIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Project"
    static var description = IntentDescription("Opens a folder as a project in Next Term.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Folder")
    var folder: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$folder) in Next Term")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LauncherLink.open("open", [URLQueryItem(name: "path", value: try LauncherLink.path(of: folder))])
        return .result()
    }
}

@available(macOS 13.0, *)
enum LauncherAgent: String, AppEnum {
    case claude, codex, opencode, gemini, cmd

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static var caseDisplayRepresentations: [LauncherAgent: DisplayRepresentation] = [
        .claude: "Claude Code",
        .codex: "Codex",
        .opencode: "OpenCode",
        .gemini: "Gemini CLI",
        .cmd: "Command Code",
    ]
}

@available(macOS 13.0, *)
struct StartAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Agent"
    static var description = IntentDescription("Starts an agent in a new tab in a folder, after you say yes in Next Term.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Agent", default: .claude)
    var agent: LauncherAgent

    @Parameter(title: "Folder")
    var folder: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$agent) in \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LauncherLink.open("agent", [URLQueryItem(name: "path", value: try LauncherLink.path(of: folder)),
                                    URLQueryItem(name: "agent", value: agent.rawValue)])
        return .result()
    }
}

/// The phrases Spotlight and Siri offer without any setup. Each must name the app.
@available(macOS 13.0, *)
struct LauncherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GoToWaitingAgentIntent(),
                    phrases: ["Go to the waiting agent in \(.applicationName)", "Which agent waits in \(.applicationName)"])
        AppShortcut(intent: GoToAnythingIntent(), phrases: ["Go to anything in \(.applicationName)"])
    }
}
