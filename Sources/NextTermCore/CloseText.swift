import Foundation

/// What the close and quit alerts say about a tab, from the plan its hangup follows (TabProcessTree): what
/// closing stops ("“next-server” (started by “claude”)") and what it leaves running (a program ignoring SIGHUP).
extension TabProcessTree {
    /// What closing the tab stops and what it leaves running, from the plan the hangup follows. `program` is what
    /// runs in front as the tab names it ("“npm run dev”"), nil if unnamed; `running` false: the tab is at its prompt.
    public static func closeNote(_ plan: HangupPlan, running: Bool, program: String?) -> CloseNote {
        var note = CloseNote()
        guard running else { return note }
        if !plan.foreground.isEmpty, plan.foreground.allSatisfy(\.ignoresHangup) {
            note.keeps.append(program ?? "a running process")
        } else {
            note.stops.append(program.map { $0 + " (running)" } ?? "a running process")
        }
        let started = startedNote(plan)
        note.stops += started.stops
        note.keeps += started.keeps
        return note
    }

    /// What the program in front started outside its group, which the hangup stops or leaves running, by group: the
    /// processes nothing else in the group runs under (next-server, not the npm and next above it), shells left out.
    /// The close alerts and the update sheet both say it ("“next-server” (started by “claude”)").
    public static func startedNote(_ plan: HangupPlan) -> CloseNote {
        var note = CloseNote()
        var stopping: [String] = [], keeping: [String] = []
        var starter: String?
        let byPid = Dictionary(plan.targets.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let frontPids = Set(plan.foreground.map(\.pid))
        for group in plan.groups.dropFirst() {
            let members = plan.startedOutside.filter { $0.group == group }
            let parents = Set(members.map(\.parent))
            var named = members.filter { !parents.contains($0.pid) && !shellNames.contains($0.name) }
            if named.isEmpty, let leader = members.first(where: { $0.pid == group }) ?? members.first { named = [leader] }
            for record in named {
                if starter == nil {
                    var up = record.parent
                    while let parent = byPid[up], !frontPids.contains(parent.pid) { up = parent.parent }
                    starter = byPid[up]?.name
                }
                if record.ignoresHangup {
                    if !keeping.contains(record.name) { keeping.append(record.name) }
                } else if !stopping.contains(record.name) {
                    stopping.append(record.name)
                }
            }
        }
        let by = starter.map { " (started by “\($0)”)" } ?? ""
        if !stopping.isEmpty { note.stops.append(CloseText.names(stopping) + by) }
        if !keeping.isEmpty { note.keeps.append(CloseText.names(keeping) + by) }
        return note
    }

    static let interpreters: Set<String> = ["node", "nodejs", "bun", "deno", "ruby", "perl", "php", "python", "python2", "python3"]

    /// What the alerts call a process: the first word of its argv[0] (a dev server retitles itself
    /// "next-server (v16.4.0)", npm "npm run dev"), as a file name; for an interpreter, the script it runs
    /// ("node …/bin/claude" is "claude"). `command` is the kernel's short name, used when argv can't be read.
    public static func displayName(command: String, arguments: [String]) -> String {
        guard let first = arguments.first, !first.isEmpty else { return command }
        let word = first.split(separator: " ").first.map(String.init) ?? first
        var name = (word as NSString).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() } // a login shell, "-zsh"
        guard !name.isEmpty else { return command }
        let lower = name.lowercased()
        let isInterpreter = interpreters.contains(lower) || (lower.hasPrefix("python") && lower.dropFirst(6).allSatisfy { $0.isNumber || $0 == "." })
        if isInterpreter, arguments.count > 1, !arguments[1].isEmpty, !arguments[1].hasPrefix("-") {
            return (arguments[1] as NSString).lastPathComponent
        }
        return name
    }
}

/// What closing one tab does to what runs in it, for the close and quit alerts.
public struct CloseNote: Equatable, Sendable {
    /// "“claude” (running)", "“next-server” (started by “claude”)", "“vim notes.md” (suspended)".
    public var stops: [String]
    /// What the hangup leaves running (it ignores SIGHUP): "“python3 serve.py”".
    public var keeps: [String]

    public init(stops: [String] = [], keeps: [String] = []) {
        self.stops = stops
        self.keeps = keeps
    }

    public var isEmpty: Bool { stops.isEmpty && keeps.isEmpty }
}

public enum CloseText {
    /// The alert text for closing tabs with these notes: "<lead> “a” (running), “b”; “c” (suspended)." for what
    /// stops, then "“d” keeps running: it ignores hangups." Tabs past the first four are counted, not listed. With
    /// nothing to stop, `otherwise` stands for the first sentence (or nothing).
    public static func text(lead: String, notes: [CloseNote], otherwise: String = "") -> String {
        let listed = notes.filter { !$0.isEmpty }
        let shown = listed.prefix(4)
        let rest = listed.count - shown.count
        var stops = shown.filter { !$0.stops.isEmpty }.map { $0.stops.joined(separator: ", ") }
        if rest > 0 { stops.append("and more in \(rest) other tab\(rest == 1 ? "" : "s")") }
        let keeps = shown.flatMap(\.keeps)
        var sentences: [String] = []
        if stops.isEmpty {
            if !otherwise.isEmpty { sentences.append(otherwise) }
        } else {
            sentences.append(lead + " " + stops.joined(separator: "; ") + ".")
        }
        if !keeps.isEmpty {
            let one = keeps.count == 1
            sentences.append(names(keeps, quoted: false) + (one ? " keeps running: it ignores hangups." : " keep running: they ignore hangups."))
        }
        return sentences.joined(separator: " ")
    }

    /// "“a”", "“a” and “b”", "“a”, “b”, “c” and 2 more". `quoted` false: the items are quoted already.
    static func names(_ items: [String], quoted: Bool = true) -> String {
        let shown = items.prefix(3).map { quoted ? "“\($0)”" : $0 }
        let rest = items.count - shown.count
        if rest > 0 { return shown.joined(separator: ", ") + " and \(rest) more" }
        guard shown.count > 1, let last = shown.last else { return shown.first ?? "" }
        return shown.dropLast().joined(separator: ", ") + " and " + last
    }
}
