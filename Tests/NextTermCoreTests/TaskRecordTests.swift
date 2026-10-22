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

    func folder() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("taskrecord-" + UUID().uuidString)
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
        let file = TaskRecordFile(support: try folder())
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
        let file = TaskRecordFile(support: try folder())
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
}
