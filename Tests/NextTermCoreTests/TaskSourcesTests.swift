import Foundation
import Testing

/// The Tasks sources make no network request and log nothing: a task's text leaves the Mac only through an app, a page
/// the user submits or a line typed for the user to send, and never lands in a log. Each file in the list is read with
/// its comments stripped (string literals kept), and any call below fails with the file and line. Opening a link or an
/// app goes through TaskOpen.swift only, and a command starts only in TaskShortcut.swift.
@Suite struct TaskSourcesTests {
    static let core = [
        "AgentReadiness", "DestinationChoices", "DestinationForm", "DestinationPlan", "MCPTaskDestinations",
        "MCPTaskTools", "PromptLine", "RemindersAccess", "RepositoryAddress", "ShortcutList", "TaskDestination",
        "TaskDraft", "TaskLink", "TaskPayload", "TaskRecord", "TaskRecordFile", "TaskSettings", "TodoFile", "TodoFolder",
        "TrackerLines", "TrackerLinesCatalog",
    ]
    static let app = [
        "AddTaskDestinationViews", "AddTaskOffer", "AddTaskSheet", "AgentReadinessTab", "ConnectTrackerSheet",
        "ConnectTrackerSheetActions", "ConnectTrackerSheetBuild", "RemindersSheets", "TaskAgentRequest",
        "TaskDestinations", "TaskDestinationsView", "TaskOpen", "TaskRecordStore", "TaskReminders", "TaskRemindersFlow",
        "TaskSettingsView", "TaskShortcut", "TaskShortcutFlow", "TasksMCP", "TasksMenu", "TasksMenuDestinations",
        "TaskWriter",
    ]

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every listed source, as (file name, path).
    static var listed: [(name: String, path: URL)] {
        let coreFiles = core.map { (name: String) -> (name: String, path: URL) in
            ("\(name).swift", root.appendingPathComponent("Sources/NextTermCore/\(name).swift"))
        }
        let appFiles = app.map { (name: String) -> (name: String, path: URL) in
            ("\(name).swift", root.appendingPathComponent("Sources/NextTerm/\(name).swift"))
        }
        return coreFiles + appFiles
    }

    @Test func theTasksSourcesHoldNoNetworkingNoLoggingAndOpenOnlyThroughTheGate() throws {
        let missing = SourceScan.missing(Self.listed)
        #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
        var hits: [String] = []
        for file in Self.listed {
            guard let text = try? String(contentsOf: file.path, encoding: .utf8) else { continue }
            hits += SourceScan.hits(file: file.name, text: text)
        }
        #expect(hits.isEmpty, "\(hits.joined(separator: "\n"))")
    }

    @Test func aNetworkCallAddedToACopyFailsWithItsFileAndLine() throws {
        let path = Self.root.appendingPathComponent("Sources/NextTermCore/TaskPayload.swift")
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(SourceScan.hits(file: "TaskPayload.swift", text: text).isEmpty)
        let lines = text.components(separatedBy: "\n").count
        let changed = text + "\nlet session = URLSession.shared\n"
        let hits = SourceScan.hits(file: "TaskPayload.swift", text: changed)
        #expect(hits == ["TaskPayload.swift:\(lines + 1): URLSession"])
    }

    @Test func everyLoggingCallFailsAndACommentNamingOneDoesNot() {
        let calls = ["print(title)", "NSLog(\"%@\", t)", "os_log(.info, \"x\")", "let l = Logger(subsystem: \"x\")",
                     "DebugLog.write(\"x\")", "debugPrint(x)", "dump(x)", "import os", "import OSLog",
                     "FileHandle.standardError.write(d)"]
        for call in calls {
            #expect(SourceScan.hits(file: "TaskPayload.swift", text: call).count == 1, "\(call)")
        }
        let quiet = ["// print(x)", "/* URLSession */", "/* a /* nested */ NSLog( */", "let blueprint = sprint(x)",
                     "/// Logger(subsystem:", "let curly = 1", "let url = \"https://example.com\" // curl"]
        for line in quiet {
            #expect(SourceScan.hits(file: "TaskPayload.swift", text: line).isEmpty, "\(line)")
        }
        // A string literal is kept: a command in one still fails.
        #expect(SourceScan.hits(file: "TrackerLines.swift", text: "let line = \"curl -s x\"").count == 1)
        #expect(SourceScan.hits(file: "TrackerLines.swift", text: "let a = \"\"\"\nwget x\n\"\"\"").count == 1)
    }

    @Test func openingAndCommandsAreAllowedOnlyInTheirOwnFile() {
        let open = "NSWorkspace.shared.open(url)"
        #expect(SourceScan.hits(file: "TaskOpen.swift", text: open).isEmpty)
        #expect(SourceScan.hits(file: "TasksMenu.swift", text: open) == ["TasksMenu.swift:1: NSWorkspace"])
        let process = "let process = Process()"
        #expect(SourceScan.hits(file: "TaskShortcut.swift", text: process).isEmpty)
        #expect(SourceScan.hits(file: "TaskReminders.swift", text: process) == ["TaskReminders.swift:1: Process("])
        // Showing a file in Finder opens nothing of the task's.
        let reveal = "NSWorkspace.shared.activateFileViewerSelecting([url])"
        #expect(SourceScan.hits(file: "TasksMenu.swift", text: reveal).isEmpty)
    }

    @Test func aListedFileThatIsGoneFailsByName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nt-sources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let here = folder.appendingPathComponent("TaskShortcut.swift")
        try Data("let x = 1\n".utf8).write(to: here)
        let files = [("TaskShortcut.swift", here), ("TaskOpen.swift", folder.appendingPathComponent("TaskOpen.swift"))]
        #expect(SourceScan.missing(files) == ["TaskOpen.swift is missing from the Tasks sources list"])
    }
}

/// The matcher: comments out, string literals kept, then each rule by regular expression.
enum SourceScan {
    struct Rule {
        let name: String
        let pattern: String
        /// The one file the call is allowed in, or nil: none.
        let onlyIn: String?
    }

    static let wordStart = "(?<![A-Za-z0-9_])"
    static let wordEnd = "(?![A-Za-z0-9_])"

    static let rules: [Rule] = {
        let network: [Rule] = [
            word("URLSession"), word("URLRequest"), word("NWConnection"), word("NWListener"), word("NWPathMonitor"),
            Rule(name: "CFStream", pattern: wordStart + "CFStream", onlyIn: nil), word("getStreamsToHost"),
            word("WKWebView"), literal("Data(contentsOf: URL(string"), literal("String(contentsOf:"),
            word("import Network"), word("import WebKit"), word("curl"), word("wget"),
        ]
        let logging: [Rule] = [
            literal("print("), literal("debugPrint("), literal("dump("), literal("NSLog("), literal("os_log("),
            literal("Logger("), word("import os"), word("OSLog"), literal("FileHandle.standardError"),
            literal("DebugLog."),
        ]
        let gated: [Rule] = [
            Rule(name: "NSWorkspace", pattern: wordStart + "NSWorkspace" + wordEnd, onlyIn: "TaskOpen.swift"),
            Rule(name: "Process(", pattern: wordStart + "Process\\(", onlyIn: "TaskShortcut.swift"),
        ]
        return network + logging + gated
    }()

    static func word(_ text: String) -> Rule {
        Rule(name: text, pattern: wordStart + NSRegularExpression.escapedPattern(for: text) + wordEnd, onlyIn: nil)
    }

    static func literal(_ text: String) -> Rule {
        Rule(name: text, pattern: wordStart + NSRegularExpression.escapedPattern(for: text), onlyIn: nil)
    }

    /// Showing a file in Finder is allowed anywhere: it opens nothing of the task's.
    static let allowed = "NSWorkspace.shared.activateFileViewerSelecting"

    /// "File.swift:line: rule" for each match.
    static func hits(file: String, text: String) -> [String] {
        let code = stripComments(text).replacingOccurrences(of: allowed, with: "")
        let lineStarts = starts(code)
        var found: [(line: Int, name: String)] = []
        for rule in rules where rule.onlyIn != file {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: range) {
                let offset = match.range.location
                let line = lineStarts.lastIndex { $0 <= offset }.map { $0 + 1 } ?? 1
                found.append((line, rule.name))
            }
        }
        let sorted = found.sorted { $0.line < $1.line }
        return sorted.map { "\(file):\($0.line): \($0.name)" }
    }

    /// The UTF-16 offset each line starts at.
    static func starts(_ text: String) -> [Int] {
        var result: [Int] = [0]
        for (index, unit) in text.utf16.enumerated() where unit == 10 { result.append(index + 1) }
        return result
    }

    /// The listed files with nothing at their path.
    static func missing(_ files: [(String, URL)]) -> [String] {
        files.filter { !FileManager.default.fileExists(atPath: $0.1.path) }
            .map { "\($0.0) is missing from the Tasks sources list" }
    }
}

extension SourceScan {
    /// The text with every comment's characters turned into spaces, line breaks kept so line numbers stay. String
    /// literals, single-line, multi-line and raw, are kept as written; block comments nest, as Swift's do.
    static func stripComments(_ text: String) -> String {
        enum State { case code, line, block(Int), string(hashes: Int, triple: Bool) }
        let chars: [Character] = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var state = State.code
        var i = 0
        func at(_ offset: Int) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }
        func blank(_ count: Int) {
            for k in 0..<count where i + k < chars.count { out.append(chars[i + k] == "\n" ? "\n" : " ") }
            i += count
        }
        func keep(_ count: Int) {
            for k in 0..<count where i + k < chars.count { out.append(chars[i + k]) }
            i += count
        }
        while i < chars.count {
            let c = chars[i]
            switch state {
            case .code:
                if c == "/", at(1) == "/" {
                    state = .line
                    blank(2)
                } else if c == "/", at(1) == "*" {
                    state = .block(1)
                    blank(2)
                } else if c == "#" || c == "\"" {
                    var hashes = 0
                    while at(hashes) == "#" { hashes += 1 }
                    guard at(hashes) == "\"" else { keep(1); continue }
                    let triple = at(hashes + 1) == "\"" && at(hashes + 2) == "\""
                    state = .string(hashes: hashes, triple: triple)
                    keep(hashes + (triple ? 3 : 1))
                } else {
                    keep(1)
                }
            case .line:
                if c == "\n" { state = .code; keep(1) } else { blank(1) }
            case .block(let depth):
                if c == "*", at(1) == "/" {
                    state = depth == 1 ? .code : .block(depth - 1)
                    blank(2)
                } else if c == "/", at(1) == "*" {
                    state = .block(depth + 1)
                    blank(2)
                } else {
                    blank(1)
                }
            case .string(let hashes, let triple):
                if c == "\\", hashes == 0 {
                    keep(2)
                    continue
                }
                let quotes = triple ? 3 : 1
                let quoted: Bool = (0..<quotes).allSatisfy { (k: Int) -> Bool in at(k) == "\"" }
                let hashed: Bool = (0..<hashes).allSatisfy { (k: Int) -> Bool in at(quotes + k) == "#" }
                if quoted && hashed {
                    state = .code
                    keep(quotes + hashes)
                } else if c == "\n", !triple {
                    // An unclosed single-line string ends at the line's end, so a stray quote can't hide the rest.
                    state = .code
                    keep(1)
                } else {
                    keep(1)
                }
            }
        }
        return String(out)
    }
}
