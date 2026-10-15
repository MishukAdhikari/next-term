import Foundation
import Testing
@testable import NextTermCore

@Suite struct CommandHistoryFileTests {
    typealias Entry = CommandHistory.Entry

    func temporary() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nt-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func history(_ entries: [Entry]) -> CommandHistory {
        var history = CommandHistory()
        history.load(entries)
        return history
    }

    func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    @Test func theLogRoundTrips() {
        let entries = [
            Entry(line: "git checkout main", lastRun: 1_700_000_000_123, count: 3, successes: 2, lastExit: 1, folder: "/tmp/a\tb\nc\\d",
                  repo: "/tmp/a/.git"),
            Entry(line: #"echo "a\b" | tr a b"#, lastRun: 5, count: 1, successes: 0, lastExit: nil, folder: nil, repo: nil),
            Entry(line: "ls", lastRun: 6, count: 1, successes: 1, lastExit: 0, folder: "/tmp/a\tb\nc\\d", repo: nil),
        ]
        let hash = CommandHistoryFile.hash(of: "kubectl get pods")
        let encoded = CommandHistoryFile.encode(history(entries), forgotten: [hash])
        let decoded = CommandHistoryFile.decode(encoded)
        #expect(!decoded.otherVersion && decoded.history.entries() == entries && decoded.forgotten == [hash])
        // The folder is named once, and the forgotten line by its hash only.
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.hasPrefix(CommandHistoryFile.header + "\n") && text.components(separatedBy: "\nf\t").count == 2)
        #expect(!text.contains("kubectl") && text.contains(#"/tmp/a\tb\nc\\d"#) && hash.count == 64)
        #expect(decoded.named.contains("f" + CommandHistoryFile.id(of: "/tmp/a\tb\nc\\d")))
    }

    @Test func anotherVersionIsLeftAsItIs() {
        let other = CommandHistoryFile.decode(data(["nextterm-history 2", "c\t1\t1\t1\t0\t-\t-\t-\tls"]))
        #expect(other.otherVersion && other.history.count == 0)
        #expect(CommandHistoryFile.decode(data(["something else"])).otherVersion)
        // Nothing, or a header cut short, is an empty log.
        #expect(!CommandHistoryFile.decode(Data()).otherVersion && !CommandHistoryFile.decode(Data("nextterm-hist".utf8)).otherVersion)
    }

    @Test func aDamagedLineIsSkipped() {
        let folder = CommandHistoryFile.id(of: "/p")
        let log = data([
            CommandHistoryFile.header,
            "f\t\(folder)\t/p",
            "c\t1\t1\t1\t0\t\(folder)\t-\t-\tmake",
            "c\tx\t1\t1\t0\t-\t-\t-\tbroken time",
            "c\t2\t1\t1\t0\t-\t-\t-\tbad \\q escape",
            "c\t3\t1\t1\t0\t-\t-",
            "z\twhat",
            "c\t4\t1\t1\t0\t\(CommandHistoryFile.id(of: "/unknown"))\t-\t-\tls",
            "x\tnot-a-hash",
            "c\t5\t1\t0\t-\t-\t-\t-\tpwd",
        ])
        var bytes = log
        bytes.append(contentsOf: [0x63, 0x09, 0xFF, 0x0A]) // a line that isn't UTF-8
        let decoded = CommandHistoryFile.decode(bytes)
        let entries = Dictionary(uniqueKeysWithValues: decoded.history.entries().map { ($0.line, $0) })
        #expect(Set(entries.keys) == ["make", "ls", "pwd"] && decoded.forgotten.isEmpty)
        #expect(entries["make"]?.folder == "/p" && entries["ls"]?.folder == nil && entries["pwd"]?.lastExit == nil)
    }

    @Test func theLastStateOfALineWins() {
        let log = data([CommandHistoryFile.header, "c\t1\t1\t0\t1\t-\t-\t-\tmake", "c\t9\t2\t1\t0\t-\t-\t-\tmake", "c\t5\t1\t1\t0\t-\t-\t-\tls"])
        let decoded = CommandHistoryFile.decode(log)
        #expect(decoded.history.entry(for: "make") == Entry(line: "make", lastRun: 9, count: 2, successes: 1, lastExit: 0))
        #expect(decoded.runs == 3 && decoded.history.count == 2)
        // A line cut short at the end (the read's cap) is not read.
        var cut = log
        cut.append(Data("c\t9\t2\t1\t0\t-\t-\t-\tpw".utf8))
        #expect(CommandHistoryFile.decode(cut).history.entry(for: "pw") == nil)
    }

    @Test func aMergeKeepsEachLinesLaterState() {
        let mine = history([Entry(line: "make", lastRun: 5, count: 2), Entry(line: "ls", lastRun: 1)])
        let theirs = history([Entry(line: "make", lastRun: 7, count: 3), Entry(line: "pwd", lastRun: 2), Entry(line: "ls", lastRun: 1)])
        let merged = CommandHistoryFile.merge(mine, theirs, dropping: ["pwd"])
        #expect(merged.entry(for: "make")?.lastRun == 7 && merged.entry(for: "ls") != nil && merged.entry(for: "pwd") == nil)
        #expect(CommandHistoryFile.hasNews(theirs, for: mine) && !CommandHistoryFile.hasNews(mine, for: merged))
    }

    // MARK: the folder

    @Test func theFolderIsPrivate() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = CommandHistoryFolder(support: base)
        try folder.ensure()
        #expect(PrivateFolder.isPrivate(folder.url.path) && folder.url.lastPathComponent == "History.noindex")
        try folder.append(Data("c\t1\t1\t1\t0\t-\t-\t-\tls\n".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: folder.logPath)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try folder.read()?.data == data([CommandHistoryFile.header, "c\t1\t1\t1\t0\t-\t-\t-\tls"]))

        // A link at the folder's name is refused, never followed.
        let linked = temporary()
        defer { try? FileManager.default.removeItem(at: linked) }
        let elsewhere = temporary()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(atPath: linked.appendingPathComponent("History.noindex").path, withDestinationPath: elsewhere.path)
        let refused = CommandHistoryFolder(support: linked)
        #expect(throws: CommandHistoryFolder.Failure.notPrivate) { try refused.ensure() }
        #expect(throws: CommandHistoryFolder.Failure.notPrivate) { try refused.append(Data("x\n".utf8)) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: elsewhere.path))?.isEmpty == true)
    }

    @Test func aLogThatIsNotAPlainOwnFileIsRefused() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = CommandHistoryFolder(support: base)
        try folder.ensure()
        let target = base.appendingPathComponent("target")
        try data([CommandHistoryFile.header]).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: folder.logPath, withDestinationPath: target.path)
        #expect(throws: CommandHistoryFolder.Failure.refused) { try folder.read() }
        #expect(throws: CommandHistoryFolder.Failure.refused) { try folder.append(Data("c\n".utf8)) }
        #expect(try Data(contentsOf: target) == data([CommandHistoryFile.header]))
        // A second hard link: whoever holds that name could change it.
        try FileManager.default.removeItem(atPath: folder.logPath)
        try data([CommandHistoryFile.header]).write(to: URL(fileURLWithPath: folder.logPath))
        try FileManager.default.linkItem(atPath: folder.logPath, toPath: base.appendingPathComponent("second").path)
        #expect(throws: CommandHistoryFolder.Failure.refused) { try folder.read() }
        #expect(throws: CommandHistoryFolder.Failure.refused) { try folder.append(Data("c\n".utf8)) }
    }

    @Test func aReadStopsAtItsCap() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = CommandHistoryFolder(support: base)
        try folder.ensure()
        let line = "c\t1\t1\t1\t0\t-\t-\t-\techo " + String(repeating: "abc ", count: 250) + "\n"
        FileManager.default.createFile(atPath: folder.logPath, contents: Data((CommandHistoryFile.header + "\n").utf8),
                                       attributes: [.posixPermissions: 0o600])
        let handle = try #require(FileHandle(forWritingAtPath: folder.logPath))
        handle.seekToEndOfFile()
        let block = Data(String(repeating: line, count: 1024).utf8)
        while handle.offsetInFile < 70 * 1024 * 1024 { handle.write(block) }
        try handle.close()
        let read = try #require(try folder.read())
        #expect(read.data.count == CommandHistoryFile.maxReadBytes && !read.whole)
        #expect(CommandHistoryFile.decode(read.data).history.count == 1)
        // A log too big to read whole is never compacted.
        #expect(try folder.compact { _ in Data("lost".utf8) } == nil)
        #expect(folder.size > CommandHistoryFile.maxReadBytes)
    }

    /// Two copies of Next Term on one folder: each one's appends land in the log both read.
    @Test func twoCopiesAppendToOneLog() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let a = CommandHistoryFolder(support: base), b = CommandHistoryFolder(support: base)
        var named: Set<String> = []
        try a.append(CommandHistoryFile.entryLines(Entry(line: "make", lastRun: 1, folder: "/p"), named: &named))
        var theirs: Set<String> = []
        try b.append(CommandHistoryFile.entryLines(Entry(line: "ls", lastRun: 2, folder: "/p"), named: &theirs))
        for folder in [a, b] {
            let decoded = CommandHistoryFile.decode(try #require(try folder.read()).data)
            #expect(decoded.history.entry(for: "make")?.folder == "/p" && decoded.history.entry(for: "ls")?.folder == "/p")
        }
    }

    /// A compaction a write got in ahead of reads the log again and merges once more: the other copy's line is kept.
    @Test func aCompactionKeepsALineAppendedMeanwhile() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let a = CommandHistoryFolder(support: base)
        var named: Set<String> = []
        try a.append(CommandHistoryFile.entryLines(Entry(line: "make", lastRun: 1), named: &named))
        let mine = history([Entry(line: "make", lastRun: 1), Entry(line: "pwd", lastRun: 3)])
        var once = true
        a.beforeWrite = {
            guard once else { return }
            once = false
            // The other copy's append, as it lands in the log.
            let handle = FileHandle(forWritingAtPath: a.logPath)
            handle?.seekToEndOfFile()
            handle?.write(Data("c\t2\t1\t1\t0\t-\t-\t-\tls\n".utf8))
            try? handle?.close()
        }
        var merges = 0
        let written = try a.compact { current in
            merges += 1
            let log = CommandHistoryFile.decode(current ?? Data())
            return CommandHistoryFile.encode(CommandHistoryFile.merge(mine, log.history), forgotten: [])
        }
        let decoded = CommandHistoryFile.decode(try #require(written))
        #expect(merges == 2 && decoded.history.entry(for: "ls") != nil && decoded.history.entry(for: "pwd") != nil)
        #expect(CommandHistoryFile.decode(try #require(try a.read()).data).history.count == 3)
    }

    @Test func forgetAndClearLeaveNothingOnDisk() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = CommandHistoryFolder(support: base)
        var named: Set<String> = []
        for entry in [Entry(line: "echo forget-me", lastRun: 1), Entry(line: "ls", lastRun: 2)] {
            try folder.append(CommandHistoryFile.entryLines(entry, named: &named))
        }
        var mine = CommandHistoryFile.decode(try #require(try folder.read()).data).history
        mine.forget("echo forget-me")
        try folder.compact { current in
            let log = CommandHistoryFile.decode(current ?? Data())
            return CommandHistoryFile.encode(CommandHistoryFile.merge(mine, log.history, dropping: ["echo forget-me"]), forgotten: [])
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: folder.logPath))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("forget-me") && String(decoding: bytes, as: UTF8.self).contains("ls"))
        try folder.clear()
        #expect(!FileManager.default.fileExists(atPath: folder.logPath))
        // Clearing a folder that isn't there makes none.
        let none = CommandHistoryFolder(support: base.appendingPathComponent("none"))
        try none.clear()
        #expect(!FileManager.default.fileExists(atPath: none.url.path))
    }

    // MARK: who typed it

    @Test func onlyYourLinesAreYours() {
        #expect(CommandAuthor.decide(flags: .keptOut, ownLine: nil, typed: "npm test") == .agent)
        #expect(CommandAuthor.decide(flags: [], ownLine: "npm test", typed: "npm test") == .agent)
        #expect(CommandAuthor.decide(flags: [], ownLine: "npm test", typed: "npm test -w") == .you)
        #expect(CommandAuthor.decide(flags: [], ownLine: nil, typed: "npm test") == .you)
        #expect(CommandAuthor.decide(flags: .jobResume, ownLine: nil, typed: "npm run dev") == nil)
        #expect(CommandAuthor.decide(flags: [.keptOut, .jobResume], ownLine: nil, typed: "npm run dev") == nil)
    }
}
