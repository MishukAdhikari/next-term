import Foundation
import Testing
@testable import NextTermCore

/// The todo folder: `todo/` in the project (the main checkout for a linked worktree), made as the first task is added
/// and never outside the project; an absolute folder used only when it is there; files written create-only.
@Suite struct TodoFolderTests {
    /// A temporary folder of the test's own, spelled as the kernel spells it.
    func folder() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-todo-\(UUID().uuidString)"
        for folder in ["/project", "/home"] { try FileManager.default.createDirectory(atPath: dir + folder, withIntermediateDirectories: true) }
        return dir
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Protected places of a home inside the test's folder, so none of the user's is ever looked at.
    func places(_ dir: String) -> ProtectedPlaces { ProtectedPlaces(home: dir + "/home") }

    static let created = Date(timeIntervalSince1970: 1_792_068_127) // 2026-10-15 in Dhaka
    static let dhaka = TimeZone(identifier: "Asia/Dhaka")!

    func names(_ title: String) -> [String] { TodoFile.names(created: Self.created, title: title, timeZone: Self.dhaka) }

    @Test func theFolderIsTodoInTheProjectAndIsMadeWithTheFirstTask() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project"
        let resolution = TodoFolder.resolve(project: project, settings: TaskSettings(), places: places(dir), home: dir + "/home")
        #expect(resolution == .inProject(URL(fileURLWithPath: project + "/todo"), root: project, mustCreate: true))
        #expect(resolution.createsFolder && !exists(project + "/todo"))
        #expect(TodoFolder.shownFile("2026-10-15-x.md", in: resolution) == "todo/2026-10-15-x.md in project")
        let file = try TodoFolder.create("- [ ] x\n", names: names("x"), in: resolution)
        #expect(file.path == project + "/todo/2026-10-15-x.md" && FileManager.default.contents(atPath: file.path) == Data("- [ ] x\n".utf8))
        // As you make files: 0644 less the umask.
        let mode = ((try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == Int(0o644 & ~SafeWrite.umask))
        // Once it is there, nothing more is made.
        let again = TodoFolder.resolve(project: project, settings: TaskSettings(), places: places(dir), home: dir + "/home")
        #expect(again == .inProject(URL(fileURLWithPath: project + "/todo"), root: project, mustCreate: false) && !again.createsFolder)
    }

    @Test func aPathInsideTheProjectIsMadeWithItsParents() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project"
        for setting in ["docs/todo", "./docs//todo/", "docs/notes/../todo"] {
            let resolution = TodoFolder.resolve(project: project, settings: TaskSettings(folder: setting), places: places(dir))
            #expect(resolution == .inProject(URL(fileURLWithPath: project + "/docs/todo"), root: project, mustCreate: true), "\(setting)")
        }
        let resolution = TodoFolder.resolve(project: project, settings: TaskSettings(folder: "docs/todo"), places: places(dir))
        _ = try TodoFolder.create("x\n", names: names("x"), in: resolution)
        #expect(exists(project + "/docs/todo/2026-10-15-x.md"))
    }

    @Test func aPathOutsideTheProjectOrInGitsFolderIsRefused() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project"
        try FileManager.default.createDirectory(atPath: dir + "/elsewhere", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project + "/link", withDestinationPath: dir + "/elsewhere")
        try Data("x".utf8).write(to: URL(fileURLWithPath: project + "/notes"))
        for setting in ["../x", "todo/../../x", "..", ".", "link", "link/todo", ".git/todo", "a/.GIT", "notes"] {
            let resolution = TodoFolder.resolve(project: project, settings: TaskSettings(folder: setting), places: places(dir))
            guard case .refused(let why) = resolution else {
                Issue.record("\(setting): \(resolution)")
                continue
            }
            #expect(!why.isEmpty && resolution.folder == nil, "\(setting)")
            #expect(throws: TodoFolder.Failure.outsideProject) { try TodoFolder.create("x", names: names("x"), in: resolution) }
        }
        // Settings › Tasks says so from the words as they are typed; a link it can't tell until a task is added.
        for setting in ["../x", "todo/../../x", "..", ".", ".git/todo", "a/.GIT"] { #expect(TodoFolder.problem(with: setting) != nil, "\(setting)") }
        for setting in ["todo", "docs/todo", "link/todo", "~/Notes", "/Volumes/Notes/Todo", ""] { #expect(TodoFolder.problem(with: setting) == nil, "\(setting)") }
        // Nothing was made anywhere.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir + "/elsewhere").isEmpty)
        #expect(!exists(dir + "/x") && !exists(project + "/.git"))
    }

    @Test func aLinkedWorktreesTasksGoToTheMainCheckout() throws {
        guard let git = GitRunner.locateGit() else { return }
        let repo = try TemporaryRepository(git: git)
        defer { repo.remove() }
        let linked = repo.base + "/xCloud-wt-login"
        repo.run(["worktree", "add", "-q", "-b", "fix/login", linked])
        let main = canonicalPath(repo.path)
        let places = ProtectedPlaces(home: repo.base + "/home")
        for project in [linked, main] {
            let resolution = TodoFolder.resolve(project: project, settings: TaskSettings(), places: places)
            #expect(resolution == .inProject(URL(fileURLWithPath: main + "/todo"), root: main, mustCreate: true), "\(project)")
        }
        let resolution = TodoFolder.resolve(project: linked, settings: TaskSettings(), places: places)
        #expect(TodoFolder.shownFile("2026-10-15-x.md", in: resolution) == "todo/2026-10-15-x.md in xCloud")
        let file = try TodoFolder.create("x\n", names: names("x"), in: resolution)
        #expect(file.path == main + "/todo/2026-10-15-x.md" && !exists(linked + "/todo"))
    }

    @Test func aBareRepositorysWorktreeKeepsItsTasksItself() throws {
        guard let git = GitRunner.locateGit() else { return }
        let repo = try TemporaryRepository(git: git)
        defer { repo.remove() }
        // proj/.bare is git's folder and proj/main its worktree: there is no main checkout to share.
        let bare = repo.base + "/proj/.bare", worktree = repo.base + "/proj/main"
        #expect(repo.run(["clone", "--bare", "-q", repo.path, bare]) == 0)
        #expect(repo.run(["-C", bare, "worktree", "add", "-q", worktree]) == 0)
        let main = canonicalPath(worktree)
        let places = ProtectedPlaces(home: repo.base + "/home")
        let resolution = TodoFolder.resolve(project: worktree, settings: TaskSettings(), places: places)
        #expect(resolution == .inProject(URL(fileURLWithPath: main + "/todo"), root: main, mustCreate: true))
        let file = try TodoFolder.create("x\n", names: names("x"), in: resolution)
        #expect(file.path == main + "/todo/2026-10-15-x.md" && !exists(bare + "/todo"))
    }

    @Test func aProjectFolderThatIsGoneIsNeverMadeAgain() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project"
        // Found while the project was there (the sheet stays open), then the folder was removed.
        let stale = TodoFolder.resolve(project: project, settings: TaskSettings(), places: places(dir))
        try FileManager.default.removeItem(atPath: project)
        let gone = TodoFolder.resolve(project: project, settings: TaskSettings(), places: places(dir))
        guard case .refused(let why) = gone else {
            Issue.record("\(gone)")
            return
        }
        #expect(why == "The project folder \(project) is not there.")
        #expect(throws: TodoFolder.Failure.projectMissing(project)) {
            try TodoFolder.create("x\n", names: names("x"), in: stale, home: dir + "/home")
        }
        #expect(!exists(project))
    }

    @Test func aFolderNextTermCantOpenIsNotCalledMissing() throws {
        let dir = try folder()
        let locked = dir + "/locked"
        try FileManager.default.createDirectory(atPath: locked + "/Todo", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
            try? FileManager.default.removeItem(atPath: dir)
        }
        // A folder above it can't be gone through (EACCES): the folder may be there, so it is not called missing.
        let shared = TodoFolder.Resolution.shared(URL(fileURLWithPath: locked + "/Todo", isDirectory: true), project: nil)
        #expect(throws: TodoFolder.Failure.unreadable(locked + "/Todo")) {
            try TodoFolder.create("x", names: names("x"), in: shared, home: "/nowhere")
        }
        // macOS's own refusal names the pane that allows it.
        let denied = TodoFolder.Failure.denied("~/Documents/Todo", .filesAndFolders).errorDescription ?? ""
        #expect(denied.hasSuffix("System Settings › Privacy & Security › Files and Folders."))
    }

    @Test func anAbsoluteFolderIsUsedOnlyWhenItIsThereAndNeverMade() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let project = dir + "/project", notes = dir + "/home/Notes/Todo"
        // Missing: said so, and nothing made.
        let missing = TodoFolder.resolve(project: project, settings: TaskSettings(folder: "~/Notes/Todo"), places: places(dir), home: dir + "/home")
        #expect(missing == .missing(URL(fileURLWithPath: notes)))
        #expect(throws: TodoFolder.Failure.missing("~/Notes/Todo")) {
            try TodoFolder.create("x", names: names("x"), in: missing, home: dir + "/home")
        }
        #expect(!exists(dir + "/home/Notes"))
        // There: one folder for every project, which the file then names.
        try FileManager.default.createDirectory(atPath: notes, withIntermediateDirectories: true)
        let shared = TodoFolder.resolve(project: project, settings: TaskSettings(folder: notes), places: places(dir), home: dir + "/home")
        #expect(shared == .shared(URL(fileURLWithPath: notes), project: project))
        #expect(TodoFolder.shownFile("2026-10-15-x.md", in: shared, home: dir + "/home") == "~/Notes/Todo/2026-10-15-x.md")
        _ = try TodoFolder.create("x\n", names: names("x"), in: shared)
        #expect(exists(notes + "/2026-10-15-x.md") && !exists(project + "/todo"))
        // A window with no project: the folder for those, or none.
        #expect(TodoFolder.resolve(project: nil, settings: TaskSettings(), places: places(dir)) == .noProject)
        let outside = TaskSettings(outsideFolder: notes)
        #expect(TodoFolder.resolve(project: nil, settings: outside, places: places(dir)) == .shared(URL(fileURLWithPath: notes), project: nil))
        // In a protected place it is not looked at before the user adds a task: it can't be told missing yet.
        let documents = dir + "/home/Documents/Todo"
        let protected = TodoFolder.resolve(project: project, settings: TaskSettings(folder: documents), places: places(dir))
        #expect(protected == .shared(URL(fileURLWithPath: documents, isDirectory: true), project: project))
        #expect(throws: TodoFolder.Failure.missing(documents)) { try TodoFolder.create("x", names: names("x"), in: protected, home: "/nowhere") }
        #expect(!exists(documents))
    }

    @Test func aTakenNameGetsTheNextNumberAndNoFileIsWrittenOver() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let resolution = TodoFolder.resolve(project: dir + "/project", settings: TaskSettings(), places: places(dir))
        let first = try TodoFolder.create("one\n", names: names("Same title"), in: resolution)
        let second = try TodoFolder.create("two\n", names: names("Same title"), in: resolution)
        #expect(first.lastPathComponent == "2026-10-15-same-title.md" && second.lastPathComponent == "2026-10-15-same-title-2.md")
        #expect(FileManager.default.contents(atPath: first.path) == Data("one\n".utf8))
        // A name taken by anything (a folder, a link) is passed over too.
        try FileManager.default.createDirectory(atPath: dir + "/project/todo/2026-10-15-same-title-3.md", withIntermediateDirectories: true)
        let fourth = try TodoFolder.create("four\n", names: names("Same title"), in: resolution)
        #expect(fourth.lastPathComponent == "2026-10-15-same-title-4.md")
        // Every name taken: refused, nothing written over.
        #expect(throws: TodoFolder.Failure.allNamesTaken) { try TodoFolder.create("five\n", names: Array(names("Same title").prefix(4)), in: resolution) }
        #expect(FileManager.default.contents(atPath: second.path) == Data("two\n".utf8))
    }

    @Test func aDuplicateWithinAMinuteIsFound() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let resolution = TodoFolder.resolve(project: dir + "/project", settings: TaskSettings(), places: places(dir))
        let file = try TodoFolder.create("x\n", names: names("Finish the login fix"), in: resolution)
        let made = Date(timeIntervalSince1970: 1_792_068_000)
        try FileManager.default.setAttributes([.creationDate: made, .modificationDate: made], ofItemAtPath: file.path)
        let folder = file.deletingLastPathComponent()
        let slug = "finish-the-login-fix"
        #expect(TodoFolder.recentDuplicate(slug: slug, in: folder, now: made.addingTimeInterval(59)))
        #expect(!TodoFolder.recentDuplicate(slug: slug, in: folder, now: made.addingTimeInterval(61)))
        #expect(!TodoFolder.recentDuplicate(slug: "finish-the-login", in: folder, now: made.addingTimeInterval(1)))
        #expect(!TodoFolder.recentDuplicate(slug: slug, in: URL(fileURLWithPath: dir + "/none"), now: made))
        // Its numbered copies count; other files do not.
        #expect(TodoFolder.isFile("2026-10-15-finish-the-login-fix-12.md", of: slug) && TodoFolder.isFile("2026-10-16-finish-the-login-fix.md", of: slug))
        #expect(!TodoFolder.isFile("finish-the-login-fix.md", of: slug) && !TodoFolder.isFile("2026-10-15-finish-the-login-fix-x.md", of: slug))
        #expect(!TodoFolder.isFile("2026-10-15-finish-the-login-fix.txt", of: slug) && !TodoFolder.isFile("2026-99-15-finish-the-login-fix.md", of: slug))
    }

    @Test func undoKnowsAFileThatWasEditedSince() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let resolution = TodoFolder.resolve(project: dir + "/project", settings: TaskSettings(), places: places(dir))
        let text = "- [ ] x\n"
        let file = try TodoFolder.create(text, names: names("x"), in: resolution)
        #expect(TodoFolder.isUnchanged(file, text))
        try Data("- [x] x\n".utf8).write(to: file)
        #expect(!TodoFolder.isUnchanged(file, text))
        try FileManager.default.removeItem(at: file)
        #expect(!TodoFolder.isUnchanged(file, text))
    }

    @Test func theSettingsReadTheirDefaults() throws {
        let (defaults, name) = try TestDefaults.make("tasks")
        defer { TestDefaults.remove(defaults, name) }
        #expect(TaskSettings(defaults: defaults) == TaskSettings())
        #expect(TaskSettings().folder == "todo" && TaskSettings().outsideFolder == nil && TaskSettings().includeContext)
        defaults.set("  ", forKey: TaskSettings.Key.folder)
        defaults.set("relative/not/allowed", forKey: TaskSettings.Key.outsideFolder)
        defaults.set(false, forKey: TaskSettings.Key.includeContext)
        #expect(TaskSettings(defaults: defaults) == TaskSettings(folder: "todo", outsideFolder: nil, includeContext: false))
        defaults.set("~/Notes/Todo", forKey: TaskSettings.Key.folder)
        defaults.set("/Volumes/Notes", forKey: TaskSettings.Key.outsideFolder)
        let read = TaskSettings(defaults: defaults)
        #expect(read.isShared && read.outsideFolder == "/Volumes/Notes" && !TaskSettings(folder: "docs/todo").isShared)
    }
}
