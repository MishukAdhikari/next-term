import Foundation
import Testing
@testable import NextTermCore

/// A home folder of a test's own, inside a folder of its own (so a walk can start above it), with what macOS guards in
/// it: Desktop, Documents, Downloads, Pictures and ~/Library with iCloud Drive. Removed afterwards.
final class FixtureHome {
    /// The folder the home is in.
    let outer: String
    let home: String
    let places: ProtectedPlaces

    init(name: String = "ada") {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nt-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url.appendingPathComponent(name), withIntermediateDirectories: true)
        outer = canonicalPath(url.path)
        home = outer + "/" + name
        places = ProtectedPlaces(home: home)
    }

    deinit { try? FileManager.default.removeItem(atPath: outer) }

    func path(_ relative: String) -> String { home + "/" + relative }

    func folder(_ relative: String) {
        try? FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    func write(_ relative: String, _ data: Data = Data("x\n".utf8)) {
        folder((relative as NSString).deletingLastPathComponent)
        FileManager.default.createFile(atPath: path(relative), contents: data)
    }

    /// A SQLite file's first bytes, so the Databases scan takes it for one.
    static let sqlite = Data("SQLite format 3\0".utf8) + Data(count: 84)
}

@Suite struct ProtectedPlacesTests {
    // MARK: never a project

    @Test func theFoldersEveryOtherOneIsInAreNeverAProject() {
        let home = "/Users/ada"
        for never in ["/", home, home + "/", "/Volumes", "/Volumes/", home + "/Library", "/Users/ada/./Library"] {
            #expect(ProjectRoot.isNeverRoot(never, home: home), "\(never)")
        }
        let may = [home + "/Code", home + "/Documents", home + "/Documents/site", home + "/Library/Caches", "/Volumes/Disk",
                   "/Users", "/tmp", "/Users/adam"]
        for folder in may {
            #expect(!ProjectRoot.isNeverRoot(folder, home: home), "\(folder)")
        }
    }

    /// A shell in the home folder, or /, has no project: the window shows "No project open" and reads nothing there. In a
    /// folder of its own it is that folder, and in a repository its work tree, as before.
    @Test func theProjectATabIsIn() throws {
        let fixture = FixtureHome()
        let home = fixture.home
        fixture.folder("Code/notes")
        fixture.folder("Code/app/src/deep")
        fixture.folder("Code/app/.git")
        fixture.folder("Library/Caches")
        #expect(ProjectRoot.project(from: home, home: home) == nil)
        #expect(ProjectRoot.project(from: home + "/", home: home) == nil)
        #expect(ProjectRoot.project(from: "/", home: home) == nil)
        #expect(ProjectRoot.project(from: "/Volumes", home: home) == nil)
        #expect(ProjectRoot.project(from: home + "/Library", home: home) == nil)
        #expect(ProjectRoot.project(from: home + "/Library/Caches", home: home) == home + "/Library/Caches") // gone there on purpose
        #expect(ProjectRoot.project(from: home + "/Code/notes", home: home) == home + "/Code/notes")
        #expect(ProjectRoot.project(from: home + "/Code/app/src/deep", home: home) == home + "/Code/app")
        #expect(ProjectRoot.project(from: fixture.outer, home: home) == fixture.outer)
    }

    /// Dotfiles kept in a repository at ~ make the home folder a work tree: still never a project, and a folder in it
    /// that is in no repository of its own is that folder, as outside one, not the whole home folder.
    @Test func aHomeFolderThatIsARepositoryIsNoProject() {
        let fixture = FixtureHome()
        let home = fixture.home
        fixture.folder(".git")
        fixture.folder("Code/notes")
        fixture.folder("Code/app/.git")
        #expect(ProjectRoot.find(from: home + "/Code/notes", home: home) == home) // the work tree
        #expect(ProjectRoot.project(from: home, home: home) == nil)
        #expect(ProjectRoot.project(from: home + "/Code/notes", home: home) == home + "/Code/notes")
        #expect(ProjectRoot.project(from: home + "/Code/app", home: home) == home + "/Code/app")
    }

    // MARK: protected places

    @Test func whatIsProtected() {
        let places = ProtectedPlaces(home: "/Users/ada")
        let held = ["/Users/ada/Desktop", "/Users/ada/Documents/site", "/Users/ada/Downloads/sdk/bin", "/Users/ada/Pictures",
                    "/Users/ada/Pictures/Photos Library.photoslibrary", "/Users/ada/Movies", "/Users/ada/Music/Music",
                    "/Users/ada/Library", "/Users/ada/Library/Mobile Documents/com~apple~CloudDocs",
                    "/Users/ada/Library/CloudStorage/Dropbox", "/Volumes", "/Volumes/Backup/project", "/Users/ada/Documents/"]
        for path in held { #expect(places.holds(path), "\(path)") }
        let free = ["/Users/ada", "/Users/ada/Code", "/Users/ada/Documents-old", "/Users/ada/Desktopper", "/Users/ada/.config",
                    "/Users/ada/Code/Library", "/Users/ada/Code/app/Documents", "/Users", "/", "/tmp", "/VolumesX"]
        for path in free { #expect(!places.holds(path), "\(path)") }
    }

    /// What a walk leaves out depends on where it starts: from the home folder each protected place in it, from /Users the
    /// same a folder down, from a folder inside one nothing (the user chose it), and from / the volumes too.
    @Test func whatAWalkLeavesOut() {
        let fixture = FixtureHome()
        let home = fixture.home
        let fromHome = Set(fixture.places.below(home))
        #expect(fromHome == Set(ProtectedPlaces.homeFolders))
        let name = (home as NSString).lastPathComponent
        let fromAbove = Set(fixture.places.below(fixture.outer))
        #expect(fromAbove == Set(ProtectedPlaces.homeFolders.map { name + "/" + $0 }))
        #expect(fixture.places.below(home + "/Documents/site").isEmpty)
        #expect(fixture.places.below(home + "/Code").isEmpty)
        #expect(Set(fixture.places.below(home + "/Library")) == ["Mobile Documents", "CloudStorage"])
        #expect(fixture.places.below("/").contains("Volumes"))
        #expect(fixture.places.below("/Volumes/Disk").isEmpty)

        let walk = fixture.places.walk(from: home)
        for folder in ["Code", "Code/app", ".config", "Public", "Documents-old"] { #expect(walk.mayEnter(folder), "\(folder)") }
        for folder in ["Desktop", "Documents", "Documents/site", "Library", "Library/Caches", "Pictures/Photos Library.photoslibrary"] {
            #expect(!walk.mayEnter(folder), "\(folder)")
        }
        #expect(fixture.places.walk(from: home + "/Documents/site").mayEnter("src"))
        #expect(fixture.places.walk(from: home + "/Code").gitPathspecs.isEmpty)
        let pathspecs = walk.gitPathspecs
        #expect(pathspecs.first == "." && pathspecs.contains(":(exclude,literal)Documents")
            && pathspecs.contains(":(exclude,literal)Library/Mobile Documents") && pathspecs.count == ProtectedPlaces.homeFolders.count + 1)
    }

    // MARK: the walks

    /// The Databases scan from a folder that holds a home folder lists no protected place in it, and finds the SQLite
    /// files elsewhere; a project the user opened inside Documents is scanned as any other.
    @Test func theSQLiteSearchSkipsProtectedPlacesBelowItsRoot() {
        let fixture = FixtureHome()
        fixture.write("Documents/notes.sqlite", FixtureHome.sqlite)
        fixture.write("Desktop/app.db", FixtureHome.sqlite)
        fixture.write("Library/Application Support/Mail/mail.db", FixtureHome.sqlite)
        fixture.write("Code/app.sqlite", FixtureHome.sqlite)
        fixture.write("Documents/site/database/database.sqlite", FixtureHome.sqlite)
        func names(_ root: String) -> [String] {
            let scan = Databases.scan(root: root, herdInstalled: false, protected: fixture.places)
            return scan.databases.map(\.name).sorted()
        }
        #expect(names(fixture.outer) == ["app.sqlite"]) // ada/Code/app.sqlite, and nothing in ada/Documents or ada/Library
        #expect(names(fixture.home) == ["app.sqlite"])
        #expect(names(fixture.path("Documents/site")) == ["database.sqlite"])
        #expect(names(fixture.path("Documents")) == ["database.sqlite", "notes.sqlite"]) // gone into on purpose
    }

    /// File changes in a protected place below the root (~/Library, which changes all the time) set off no scan; in a
    /// project inside one they do, as anywhere.
    @Test func changesInProtectedPlacesSetOffNoScan() {
        let places = ProtectedPlaces(home: "/Users/ada")
        func may(_ folder: String, _ root: String) -> Bool { Databases.scanMayChange(after: folder, root: root, protected: places) }
        #expect(!may("/Users/ada/Library/Preferences/", "/Users/ada"))
        #expect(!may("/Users/ada/Documents/", "/Users/ada"))
        #expect(!may("/Users/ada/Desktop/x/", "/Users"))
        #expect(may("/Users/ada/Code/", "/Users/ada"))
        #expect(may("/Users/ada/Documents/site/", "/Users/ada/Documents/site"))
        #expect(may("/Users/ada/Documents/site/database/", "/Users/ada/Documents/site"))
    }

    /// Find in Files' and Go to File's walks, where git can't list the files, leave out the same places.
    @Test func searchWalksSkipProtectedPlaces() {
        let fixture = FixtureHome()
        fixture.write("Documents/secret.txt")
        fixture.write("Downloads/sdk/readme.txt")
        fixture.write("Library/Caches/x.txt")
        fixture.write("Code/app/main.swift")
        fixture.write("notes.txt")
        let searched = ProjectSearch.files(in: fixture.home, git: nil, protected: fixture.places)
        #expect(searched == ["Code/app/main.swift", "notes.txt"])
        let listed = FileWalker.files(in: fixture.home, protected: fixture.places).paths.sorted()
        #expect(listed == ["Code/app/main.swift", "notes.txt"])
        // A root the user chose inside one: searched as any other.
        #expect(ProjectSearch.files(in: fixture.path("Documents"), git: nil, protected: fixture.places) == ["secret.txt"])
        #expect(FileWalker.files(in: fixture.path("Downloads"), protected: fixture.places).paths == ["sdk/readme.txt"])
    }

    /// git leaves out the protected places too: its status of a home folder kept as a repository reads no Desktop, and
    /// a window on a folder in it reads no status at all.
    @Test func gitLeavesProtectedPlacesOut() throws {
        guard let git = GitRunner.locateGit() else { return } // no git on this machine
        let fixture = FixtureHome()
        func sh(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", fixture.home, "-c", "init.defaultBranch=main"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        sh(["init", "-q"])
        fixture.write(".zshrc")
        fixture.write("Desktop/todo.txt")
        fixture.write("Documents/letter.txt")
        fixture.write("Code/notes/a.txt")
        let snapshot = try #require(GitRunner.snapshot(for: fixture.home, git: git, protected: fixture.places))
        #expect(snapshot.files[".zshrc"] == .untracked)
        #expect(snapshot.change(at: "Code", isDirectory: true) == .untracked)
        #expect(snapshot.change(at: "Desktop", isDirectory: true) == nil && snapshot.change(at: "Documents", isDirectory: true) == nil)
        #expect(GitRunner.snapshot(for: fixture.path("Code/notes"), git: git, protected: fixture.places) == nil)
        // git's own file list for a search from there leaves them out as well.
        let listed = ProjectSearch.files(in: fixture.home, git: git, protected: fixture.places)
        #expect(listed.contains(".zshrc") && !listed.contains { $0.hasPrefix("Desktop/") || $0.hasPrefix("Documents/") }, "\(listed)")
    }

    // MARK: launch

    /// A recent project in Documents, or on a disk in /Volumes, is listed as saved, never looked at: the look would set
    /// off macOS's prompt before anything was opened. Elsewhere a folder that is gone is still left out.
    @Test func recentProjectsInProtectedPlacesAreNotLookedAt() {
        let fixture = FixtureHome()
        fixture.folder("Code/app")
        let saved = [fixture.path("Documents/site"), fixture.path("Code/app"), fixture.path("Code/gone"), "/Volumes/Backup/old"]
        let recent = RecentProjects(saved)
        #expect(recent.existing(protected: fixture.places) == [fixture.path("Documents/site"), fixture.path("Code/app"), "/Volumes/Backup/old"])
        var history = ProjectHistory()
        for (index, path) in saved.enumerated() { history.record(opened: path, at: Date(timeIntervalSince1970: TimeInterval(100 + index))) }
        let listed: Set<String> = Set(history.existing(protected: fixture.places).map(\.path))
        #expect(listed == [fixture.path("Documents/site"), fixture.path("Code/app"), "/Volumes/Backup/old"])
    }

    /// The PATH probe for `nxtrm` at launch passes over a folder in Downloads (a tool unzipped there), as unseen.
    @Test func thePathProbePassesOverProtectedFolders() {
        let home = "/Users/ada"
        var looked: [String] = []
        let plan = CommandLineLink.plan(path: [home + "/Downloads/sdk/bin", home + "/Desktop/bin", home + "/.local/bin", "/usr/bin"],
                                        home: home, script: "/Applications/Next Term.app/Contents/Resources/bin/nxtrm",
                                        isWritable: { $0 == home + "/.local/bin" || $0.hasPrefix(home + "/D") },
                                        entry: { (path: String) -> CommandLineLink.Entry in
                                            looked.append(path)
                                            return .nothing
                                        })
        #expect(plan == .link(home + "/.local/bin/nxtrm"))
        #expect(!looked.contains { $0.hasPrefix(home + "/Downloads") || $0.hasPrefix(home + "/Desktop") }, "\(looked)")
    }

    // MARK: windows with no project

    /// New Terminal, ⌘N and "Open a new terminal" at launch start where ⌘T with no window does (Settings › Terminal ›
    /// New tabs): a folder chosen there while it is there, else the home folder (nil: the shell's own, which is home).
    @Test func whereANewWindowStarts() {
        let home = "/Users/ada"
        func start(_ folder: StartFolder, exists: Bool = true) -> String? { folder.newWindowDirectory(home: home) { _ in exists } }
        #expect(start(.standard) == nil)
        #expect(start(.project) == nil)
        #expect(start(.current) == nil)
        #expect(start(.home) == home)
        #expect(start(.folder("/Users/ada/Code")) == "/Users/ada/Code")
        #expect(start(.folder("/Users/ada/gone"), exists: false) == nil)
    }

    /// An agent in a window with no project, in the home folder: offered once, never while off, in a project window, on
    /// a server, or in another folder.
    @Test func theOfferForAnAgentInTheHomeFolder() throws {
        let home = "/Users/ada"
        let agent = HomeAgentOffer.Tab(directory: home, runsAgent: true)
        func offers(on: Bool = true, project: String? = nil, offered: Bool = false, _ tabs: [HomeAgentOffer.Tab]) -> Bool {
            HomeAgentOffer.offers(on: on, windowProject: project, offered: offered, tabs: tabs, home: home)
        }
        #expect(offers([agent]))
        #expect(offers([HomeAgentOffer.Tab(directory: home + "/", runsAgent: true)]))
        #expect(offers([HomeAgentOffer.Tab(directory: home + "/Code", runsAgent: true), agent]))
        #expect(!offers(on: false, [agent]))
        #expect(!offers(offered: true, [agent]))
        #expect(!offers(project: home + "/Code/app", [agent]))
        #expect(!offers([HomeAgentOffer.Tab(directory: home, runsAgent: false)]))
        #expect(!offers([HomeAgentOffer.Tab(directory: home, runsAgent: true, remote: true)]))
        #expect(!offers([HomeAgentOffer.Tab(directory: home + "/Code", runsAgent: true)]))
        #expect(HomeAgentOffer.text(agent: "Claude Code") == "Claude Code is working in your home folder. Open a project for it?")
        // On until Don't Ask Again.
        let (defaults, name) = try TestDefaults.make("home-agent-offer")
        defer { TestDefaults.remove(defaults, name) }
        #expect(HomeAgentOffer.isOn(defaults))
        HomeAgentOffer.turnOff(defaults)
        #expect(!HomeAgentOffer.isOn(defaults))
    }
}
