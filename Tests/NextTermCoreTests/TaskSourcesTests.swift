import Foundation
import Testing

/// The Tasks sources make no network request and log nothing: a task's text leaves the Mac only through an app, a page
/// the user submits or a line typed for the user to send, and never lands in a log. Each file in the list is read with
/// its comments stripped (string literals and regex literals kept), and any call below fails with the file and line.
/// Opening a link or an app, by any API, goes through TaskOpen.swift only; a command starts, by any API, only in
/// TaskShortcut.swift; and a failure message with text in it fails too, since it lands in the crash report. The
/// matcher reads names, not meaning: a call it has no rule for passes, so a new way to reach out gets a rule here.
@Suite struct TaskSourcesTests {
    static let core = [
        "AgentReadiness", "DestinationChoices", "DestinationForm", "DestinationPlan", "Handoff", "HandoffRequest",
        "MCPTaskDestinations", "MCPTaskTools", "PromptLine", "RemindersAccess", "RepositoryAddress", "ShortcutList",
        "TaskDestination", "TaskDraft", "TaskLink", "TaskPayload", "TaskRecord", "TaskRecordFile", "TaskSettings",
        "TodayCommits", "TodoFile", "TodoFolder", "TrackerLines", "TrackerLinesCatalog", "UpdateDraft", "WrapUpModel",
    ]
    static let app = [
        "AddTaskDestinationViews", "AddTaskOffer", "AddTaskSheet", "AgentReadinessTab", "ConnectTrackerSheet",
        "ConnectTrackerSheetActions", "ConnectTrackerSheetBuild", "PostUpdate", "PostUpdateSheet", "RemindersSheets",
        "TaskAgentRequest", "TaskDestinations", "TaskDestinationsView", "TaskHandoffFolderRow", "TaskOpen",
        "TaskRecordStore", "TaskReminders", "TaskRemindersFlow", "TaskSettingsView", "TaskShortcut", "TaskShortcutFlow",
        "TasksMCP", "TasksMenu", "TasksMenuDestinations", "TaskWriter", "WrapUp", "WrapUpSheet",
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

    /// Wrap Up runs no git and opens nothing itself; Post Update runs git only to read today's commits, and shows a
    /// saved update through TaskOpen like every other file.
    @Test func gitRunsOnlyWherePostUpdateReadsCommitsAndNothingElseOpens() {
        let git = "let git = GitRunner.locateGit()"
        #expect(SourceScan.hits(file: "PostUpdate.swift", text: git).isEmpty)
        #expect(SourceScan.hits(file: "TodayCommits.swift", text: git).isEmpty)
        #expect(SourceScan.hits(file: "WrapUp.swift", text: git) == ["WrapUp.swift:1: GitRunner"])
        #expect(SourceScan.hits(file: "WrapUpSheet.swift", text: git) == ["WrapUpSheet.swift:1: GitRunner"])
        #expect(SourceScan.hits(file: "PostUpdateSheet.swift", text: git) == ["PostUpdateSheet.swift:1: GitRunner"])
        let open = "NSWorkspace.shared.open(url)"
        #expect(SourceScan.hits(file: "PostUpdate.swift", text: open) == ["PostUpdate.swift:1: NSWorkspace"])
        #expect(SourceScan.hits(file: "WrapUp.swift", text: open) == ["WrapUp.swift:1: NSWorkspace"])
        #expect(SourceScan.hits(file: "PostUpdate.swift", text: "let p = Process()") == ["PostUpdate.swift:1: Process("])
        // Every slice 3 file is in the list the scan reads.
        let slice3 = ["Handoff", "HandoffRequest", "WrapUpModel", "UpdateDraft", "TodayCommits"]
        let slice3App = ["WrapUp", "WrapUpSheet", "PostUpdate", "PostUpdateSheet"]
        #expect(slice3.allSatisfy(Self.core.contains) && slice3App.allSatisfy(Self.app.contains))
    }

    @Test func everyOtherWayToStartACommandIsAllowedOnlyWhereProcessIs() {
        let calls = ["let p = Process.launchedProcess(launchPath: x, arguments: [])",
                     "posix_spawn(&pid, x, nil, nil, a, e)",
                     "let s = NSAppleScript(source: x)", "let t = try NSUserAppleScriptTask(url: x)",
                     "let f = popen(x, \"r\")", "_ = system(x)", "execv(x, a)"]
        for call in calls {
            #expect(SourceScan.hits(file: "TaskReminders.swift", text: call).count == 1, "\(call)")
            #expect(SourceScan.hits(file: "TaskShortcut.swift", text: call).isEmpty, "\(call)")
        }
        let named = ["let fileSystem(x)", "case system(Int32)", "throw Failure.system(errno)"]
        for line in named {
            #expect(SourceScan.hits(file: "TaskReminders.swift", text: line).isEmpty, "\(line)")
        }
    }

    @Test func aLinkOpenedAnyOtherWayFailsOutsideTheGate() {
        let calls = ["@Environment(\\.openURL) var open", "Link(destination: url) { Text(x) }",
                     "WebLinks.open(url, from: window)"]
        for call in calls {
            #expect(SourceScan.hits(file: "TasksMenu.swift", text: call).count == 1, "\(call)")
        }
        #expect(SourceScan.hits(file: "TaskOpen.swift", text: "WebLinks.open(url, from: window)").isEmpty)
    }

    @Test func taskTextWrittenToTheConsoleOrACrashReportFails() {
        let calls = ["FileHandle.standardOutput.write(d)", "fputs(title, stderr)", "fwrite(p, 1, n, stdout)",
                     "fatalError(\"bad \\(title)\")", "preconditionFailure(\"\\(task.title)\")",
                     "assertionFailure(\"x \\(t)\")"]
        for call in calls {
            #expect(SourceScan.hits(file: "TaskPayload.swift", text: call).count == 1, "\(call)")
        }
        // A fixed message says nothing of the task.
        #expect(SourceScan.hits(file: "TaskPayload.swift", text: "fatalError(\"not used\")").isEmpty)
    }

    @Test func aRemoteReadFailsAndAFileReadIsAllowedOnlyWhereTheShortcutRuns() {
        let calls = ["let c = NSURLConnection(request: r, delegate: nil)", "let d = try Data(contentsOf: remote)",
                     "let d = NSData(contentsOf: remote)"]
        for call in calls {
            #expect(SourceScan.hits(file: "TaskPayload.swift", text: call).count == 1, "\(call)")
        }
        #expect(SourceScan.hits(file: "TaskShortcut.swift", text: "read(try? Data(contentsOf: outputURL))").isEmpty)
        #expect(SourceScan.hits(file: "TaskRecordFile.swift", text: "data.append(contentsOf: buffer)").isEmpty)
    }

    @Test func aRegexLiteralHoldingTwoSlashesHidesNothingAfterIt() {
        #expect(SourceScan.hits(file: "TaskPayload.swift", text: "let r = /a\\//; print(x)").count == 1)
        #expect(SourceScan.hits(file: "TaskPayload.swift", text: "let r = #/a//b/#; print(x)").count == 1)
        let scheme = "if x.contains(/https?:\\/\\//) { print(x) }"
        #expect(SourceScan.hits(file: "TaskPayload.swift", text: scheme).count == 1)
        // Division is not a regex: the comment after it still goes.
        #expect(SourceScan.hits(file: "TaskPayload.swift", text: "let h = w / 2 // print(x)").isEmpty)
        #expect(SourceScan.hits(file: "TaskPayload.swift", text: "let h = (w) / 2 // print(x)").isEmpty)
        #expect(SourceScan.hits(file: "TaskPayload.swift", text: "let h = w/2 // print(x) /").isEmpty)
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
        /// Other files it is allowed in too.
        var alsoIn: [String] = []
    }

    static let wordStart = "(?<![A-Za-z0-9_])"
    static let wordEnd = "(?![A-Za-z0-9_])"

    static let rules: [Rule] = {
        let network: [Rule] = [
            word("URLSession"), word("URLRequest"), word("NWConnection"), word("NWListener"), word("NWPathMonitor"),
            Rule(name: "CFStream", pattern: wordStart + "CFStream", onlyIn: nil), word("getStreamsToHost"),
            word("WKWebView"), literal("contentsOf: URL(string"), literal("String(contentsOf:"),
            literal("NSData(contentsOf:"), word("NSURLConnection"), word("import Network"), word("import WebKit"),
            word("curl"), word("wget"),
        ]
        let logging: [Rule] = [
            literal("print("), literal("debugPrint("), literal("dump("), literal("NSLog("), literal("os_log("),
            literal("Logger("), word("import os"), word("OSLog"), literal("FileHandle.standardError"),
            literal("FileHandle.standardOutput"), literal("fputs("), literal("fwrite("), literal("DebugLog."),
            // A failure message with text in it lands in the crash report.
            Rule(name: "failure with text",
                 pattern: wordStart + "(?:fatalError|preconditionFailure|assertionFailure)\\([^\\n]*\\\\\\(",
                 onlyIn: nil),
        ]
        return network + logging + opening + commands + [git]
    }()

    /// Running git: only where today's commits are read (read-only, with an argument array) and where a
    /// destination's repository is read from the project's remote. Wrap Up and the sheets run none.
    static let git = Rule(name: "GitRunner", pattern: wordStart + "GitRunner" + wordEnd, onlyIn: "PostUpdate.swift",
                          alsoIn: ["TodayCommits.swift", "TaskDestinationsView.swift", "DestinationForm.swift"])

    /// Opening a link or an app: in TaskOpen.swift only.
    static let opening: [Rule] = [
        Rule(name: "NSWorkspace", pattern: wordStart + "NSWorkspace" + wordEnd, onlyIn: "TaskOpen.swift"),
        gated(literal("WebLinks."), in: "TaskOpen.swift"), gated(word("openURL"), in: "TaskOpen.swift"),
        gated(literal("Link(destination:"), in: "TaskOpen.swift"),
    ]

    /// Starting a command, or reading a file a command wrote: in TaskShortcut.swift only.
    static let commands: [Rule] = [
        Rule(name: "Process(", pattern: wordStart + "Process\\(", onlyIn: "TaskShortcut.swift"),
        gated(literal("Process.launchedProcess("), in: "TaskShortcut.swift"),
        gated(word("posix_spawn"), in: "TaskShortcut.swift"), gated(word("NSAppleScript"), in: "TaskShortcut.swift"),
        gated(word("NSUserAppleScriptTask"), in: "TaskShortcut.swift"),
        gated(literal("popen("), in: "TaskShortcut.swift"),
        // The C call only: an enum case named system, or `.system(`, is not it.
        Rule(name: "system(", pattern: "(?<![A-Za-z0-9_.])(?<!case )system\\(", onlyIn: "TaskShortcut.swift"),
        gated(literal("execv"), in: "TaskShortcut.swift"),
        gated(literal("Data(contentsOf:"), in: "TaskShortcut.swift"),
    ]

    static func gated(_ rule: Rule, in file: String) -> Rule {
        Rule(name: rule.name, pattern: rule.pattern, onlyIn: file)
    }

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
        for rule in rules where rule.onlyIn != file && !rule.alsoIn.contains(file) {
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
                } else if c == "/", let length = regexLength(chars, at: i, after: out) {
                    keep(length)
                } else if c == "#" || c == "\"" {
                    var hashes = 0
                    while at(hashes) == "#" { hashes += 1 }
                    if hashes > 0, at(hashes) == "/" {
                        keep(extendedRegexLength(chars, at: i, hashes: hashes))
                        continue
                    }
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

    /// The characters a bare regex literal starting at `start` takes up, or nil when the slash is division: it must
    /// follow an opening bracket, an operator or the line's start, not begin with a space, and close on its line. A
    /// regex holding `//` is then kept whole and can't start a comment.
    static func regexLength(_ chars: [Character], at start: Int, after out: [Character]) -> Int? {
        let before: Character? = out.last { (c: Character) -> Bool in c != " " && c != "\t" }
        let opener: Set<Character> = ["(", "[", "{", "=", ",", ":", "!", "&", "|", "?", ";", "\n"]
        if let before, !opener.contains(before) { return nil }
        guard start + 1 < chars.count, chars[start + 1] != " " else { return nil }
        var j = start + 1
        while j < chars.count, chars[j] != "\n" {
            if chars[j] == "\\" {
                j += 2
                continue
            }
            if chars[j] == "/" { return j - start + 1 }
            j += 1
        }
        return nil
    }

    /// The characters an extended regex literal `#/…/#` starting at `start` takes up, to its closing slash and hashes
    /// (to the end of the text when it never closes).
    static func extendedRegexLength(_ chars: [Character], at start: Int, hashes: Int) -> Int {
        var j = start + hashes + 1
        while j < chars.count {
            let closes: Bool = chars[j] == "/" && (1...hashes).allSatisfy { (k: Int) -> Bool in
                j + k < chars.count && chars[j + k] == "#"
            }
            if closes { return j + hashes + 1 - start }
            j += 1
        }
        return chars.count - start
    }
}
