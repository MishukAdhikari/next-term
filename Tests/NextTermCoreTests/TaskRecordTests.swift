import Foundation
import Testing
@testable import NextTermCore

@Suite struct TaskRecordTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(_ slug: String = "fix-login", kind: TaskDestination.Kind = .github, key: String = "acme/api",
               at: Date? = nil, project: String? = "/Users/test/api", itemID: String? = nil) -> TaskRecord.Entry {
        TaskRecord.Entry(at: at ?? now, kind: kind, key: key, title: "Fix login", slug: slug, project: project,
                         itemID: itemID, waited: false)
    }

    /// Named nt-* so the test script's sweep removes it; each test also removes its own.
    func folder() throws -> URL {
        let name = "nt-taskrecord-" + UUID().uuidString
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func aLineRoundTripsAndBadLinesAreSkipped() throws {
        let first = entry(itemID: "x-1")
        let second = entry("other", kind: .reminders, key: "list-1")
        let line: Data = try TaskRecord.line(first)
        #expect(!line.dropLast().contains(UInt8(ascii: "\n")))
        #expect(line.last == UInt8(ascii: "\n"))
        let unknown = Data(#"{"at":"2027-01-15T08:00:00Z","kind":"fax","key":"k","title":"t","slug":"s","waited":false}"#.utf8)
        let lines: [Data] = [line, unknown, Data("\n".utf8), try TaskRecord.line(second)]
        var data = lines.reduce(Data(), +)
        let truncated: Data = try TaskRecord.line(entry("third"))
        data.append(Data(truncated.prefix(truncated.count / 2)))
        let parsed = TaskRecord.parse(data)
        #expect(parsed == [first, second])
    }

    @Test func aRepeatWithinAMinuteToTheSameDestinationIsADuplicate() {
        let entries = [entry(at: now.addingTimeInterval(-40))]
        #expect(TaskRecord.recentDuplicate(entries, kind: .github, key: "acme/api", slug: "fix-login", now: now) != nil)
        let older = [entry(at: now.addingTimeInterval(-70))]
        #expect(TaskRecord.recentDuplicate(older, kind: .github, key: "acme/api", slug: "fix-login", now: now) == nil)
    }

    @Test func anotherKeyOrKindIsNotADuplicate() {
        let entries = [entry(at: now.addingTimeInterval(-10))]
        #expect(TaskRecord.recentDuplicate(entries, kind: .github, key: "acme/web", slug: "fix-login", now: now) == nil)
        #expect(TaskRecord.recentDuplicate(entries, kind: .gitlab, key: "acme/api", slug: "fix-login", now: now) == nil)
        #expect(TaskRecord.recentDuplicate(entries, kind: .github, key: "acme/api", slug: "fix-logout", now: now) == nil)
    }

    @Test func linesOlderThanThirtyDaysArePruned() {
        let day: TimeInterval = 86_400
        let old = entry("old", at: now.addingTimeInterval(-31 * day))
        let kept = entry("kept", at: now.addingTimeInterval(-29 * day))
        #expect(TaskRecord.pruned([old, kept], now: now) == [kept])
    }

    @Test func todayIsTheLocalCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let midnight = calendar.startOfDay(for: now)
        let noon = midnight.addingTimeInterval(12 * 3600)
        let lateYesterday = entry("late", at: midnight.addingTimeInterval(-60))
        let earlyToday = entry("early", at: midnight.addingTimeInterval(60))
        let otherProject = entry("elsewhere", at: midnight.addingTimeInterval(120), project: "/Users/test/web")
        let all = [lateYesterday, earlyToday, otherProject]
        #expect(TaskRecord.today(all, project: "/Users/test/api", now: noon, calendar: calendar) == [earlyToday])
        #expect(TaskRecord.today(all, project: nil, now: noon, calendar: calendar).count == 2)
    }

    @Test func aBigRecordIsReadFromItsEndToTheCap() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = TaskRecordFile(support: base)
        let filler = entry("filler", at: now.addingTimeInterval(-3600))
        let line: Data = try TaskRecord.line(filler)
        let count = (3 << 20) / line.count + 1
        var data = Data(capacity: count * line.count)
        for _ in 0..<count { data.append(line) }
        try file.ensure()
        try data.write(to: URL(fileURLWithPath: file.path))
        chmod(file.path, 0o600)
        let newest = entry("newest")
        try file.append(newest)
        let read = try file.read(cap: 2 << 20)
        #expect(read.count < count)
        #expect(read.last == newest)
        #expect(read.first == filler)
    }

    @Test func theFileIsPrivateAndALinkIsRefused() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = TaskRecordFile(support: base)
        try file.append(entry())
        var info = stat()
        #expect(lstat(file.folder.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        #expect(lstat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        try FileManager.default.removeItem(atPath: file.path)
        let target = base.appendingPathComponent("elsewhere.txt")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: target.path)
        #expect(throws: TaskRecordFile.Failure.self) { try file.append(entry()) }
        #expect(throws: TaskRecordFile.Failure.self) { try file.read() }
        #expect(try Data(contentsOf: target).isEmpty)
    }

    @Test func removingAnItemDropsItsLineAndPruningRewrites() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = TaskRecordFile(support: base)
        let day: TimeInterval = 86_400
        try file.append(entry("old", at: now.addingTimeInterval(-40 * day)))
        try file.append(entry("reminder", kind: .reminders, key: "list-1", itemID: "item-9"))
        try file.append(entry("kept"))
        try file.remove(itemID: "item-9", kind: .reminders)
        #expect(try file.read().map(\.slug) == ["old", "kept"])
        try file.prune(now: now)
        #expect(try file.read().map(\.slug) == ["kept"])
        var info = stat()
        #expect(lstat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }

    @Test func aLineCutShortDoesNotSwallowTheNextOne() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = TaskRecordFile(support: base)
        try file.ensure()
        try Data(#"{"at":"2027"#.utf8).write(to: URL(fileURLWithPath: file.path))
        chmod(file.path, 0o600)
        let next = entry()
        try file.append(next)
        #expect(try file.read() == [next])
    }

    @Test func aLinkOrAnOpenFolderAtTheFoldersNameIsRefused() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        chmod(elsewhere.path, 0o700)
        let file = TaskRecordFile(support: base)
        try FileManager.default.createSymbolicLink(atPath: file.folder.path, withDestinationPath: elsewhere.path)
        #expect(throws: TaskRecordFile.Failure.notPrivate) { try file.append(entry()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        try FileManager.default.removeItem(atPath: file.folder.path)
        try FileManager.default.createDirectory(at: file.folder, withIntermediateDirectories: true)
        chmod(file.folder.path, 0o755)
        #expect(throws: TaskRecordFile.Failure.notPrivate) { try file.append(entry()) }
    }

    @Test func aHardLinkAtTheFilesNameIsRefused() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = TaskRecordFile(support: base)
        try file.ensure()
        let target = base.appendingPathComponent("elsewhere.jsonl")
        try Data().write(to: target)
        chmod(target.path, 0o600)
        #expect(link(target.path, file.path) == 0)
        #expect(throws: TaskRecordFile.Failure.refused) { try file.append(entry()) }
        #expect(throws: TaskRecordFile.Failure.refused) { try file.read() }
        #expect(try Data(contentsOf: target).isEmpty)
    }

    @Test func aRewriteOfABigRecordKeepsItsNewestLines() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = TaskRecordFile(support: base)
        let line: Data = try TaskRecord.line(entry("filler", at: now.addingTimeInterval(-3600)))
        let count = (3 << 20) / line.count + 1
        var data = Data(capacity: count * line.count)
        for _ in 0..<count { data.append(line) }
        try file.ensure()
        try data.write(to: URL(fileURLWithPath: file.path))
        chmod(file.path, 0o600)
        try file.append(entry("newest", kind: .reminders, key: "list-1", itemID: "item-1"))
        try file.append(entry("last"))
        try file.remove(itemID: "item-1", kind: .reminders)
        let read = try file.read()
        #expect(!read.isEmpty)
        #expect(read.last?.slug == "last")
        #expect(!read.contains { $0.slug == "newest" })
    }

    @Test func oneLineLongerThanTheCapIsNeverWipedByARewrite() throws {
        let base = try folder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = TaskRecordFile(support: base)
        try file.ensure()
        let long = Data(repeating: UInt8(ascii: "a"), count: 4096)
        try long.write(to: URL(fileURLWithPath: file.path))
        chmod(file.path, 0o600)
        try file.rewrite(cap: 1024) { _ in [] }
        #expect(try Data(contentsOf: URL(fileURLWithPath: file.path)) == long)
    }

    @Test func anEntryIsMaskedAndItsSlugTakenFromTheMaskedTitle() {
        let raw = TaskRecord.Entry(at: now, kind: .github, key: "acme/api", title: "Rotate key sk-12345",
                                   slug: "rotate-key-sk-12345", project: nil, waited: false)
        let masked = raw.masked { $0.replacingOccurrences(of: "sk-12345", with: "••••") }
        #expect(masked.title == "Rotate key ••••")
        #expect(masked.slug == TodoFile.slug("Rotate key ••••"))
        #expect(!masked.slug.contains("12345"))
        #expect(TaskRecord.slug(title: "Rotate key sk-12345") { _ in "Rotate key ••••" } == masked.slug)
    }
}
