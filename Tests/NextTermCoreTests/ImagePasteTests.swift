import Foundation
import Testing
@testable import NextTermCore

struct ImagePasteTests {
    @Test func aServerTabAlwaysCopiesItThere() {
        for agent in AgentKind.allCases.map(Optional.some) + [nil] {
            #expect(ImagePaste.way(remote: true, agent: agent, programs: agent.map { [$0.rawValue] } ?? []) == .copyToServer, "\(String(describing: agent))")
        }
    }

    @Test func agentsThatReadTheClipboardGetControlV() {
        for agent: AgentKind in [.claude, .codex, .commandCode, .gemini, .qwen, .opencode, .cursor] {
            #expect(ImagePaste.way(remote: false, agent: agent, programs: []) == .controlV, "\(agent)")
        }
        // As their programs are named.
        for program in ["claude", "claude.exe", "codex", "gemini", "qwen", "opencode", "cursor-agent"] {
            #expect(ImagePaste.way(remote: false, agent: AgentKind(program: program), programs: [program]) == .controlV, "\(program)")
        }
    }

    @Test func everythingElseHereGetsAPath() {
        #expect(ImagePaste.way(remote: false, agent: .copilot, programs: ["copilot"]) == .path)
        #expect(ImagePaste.way(remote: false, agent: nil, programs: []) == .path)
        for program in ["zsh", "vim", "tmux", "herdr", "cat"] {
            #expect(ImagePaste.way(remote: false, agent: nil, programs: [program]) == .path, "\(program)")
        }
    }

    @Test func aLoginElsewhereGetsNothing() {
        for program in ["ssh", "mosh", "mosh-client", "autossh", "et", "/usr/bin/ssh"] {
            #expect(ImagePaste.way(remote: false, agent: nil, programs: [program]) == .elsewhere, "\(program)")
        }
        // An alias's own name, and ssh behind it.
        #expect(ImagePaste.way(remote: false, agent: nil, programs: ["prod", "ssh"]) == .elsewhere)
        #expect(ImagePaste.loggedInElsewhere(["prod", "ssh"]) && !ImagePaste.loggedInElsewhere(["prod"]))
    }

    @Test func filesThenTextThenAnImage() {
        let file = "/Users/me/Desktop/shot.png"
        #expect(PasteContent.choose(files: [file], text: nil, image: true) == .files)
        // Finder writes the name beside the file: still the file.
        #expect(PasteContent.choose(files: [file], text: "shot.png", image: true) == .files)
        #expect(PasteContent.choose(files: [file, "/tmp/b.txt"], text: "shot.png\nb.txt", image: false) == .files)
        #expect(PasteContent.choose(files: [file], text: file, image: false) == .files)
        // Several names parted by a return, as Finder may write them.
        #expect(PasteContent.choose(files: [file, "/tmp/b.txt"], text: "shot.png\rb.txt", image: false) == .files)
        // A name with a line break of its own.
        #expect(PasteContent.choose(files: ["/tmp/two\nlines.txt"], text: "two\nlines.txt", image: false) == .files)
        // Text an app meant to paste, beside a file: the text.
        #expect(PasteContent.choose(files: [file], text: "see the screenshot", image: false) == .text)
        #expect(PasteContent.choose(files: [], text: "hello", image: true) == .text)
        #expect(PasteContent.choose(files: [], text: "", image: true) == .image)
        #expect(PasteContent.choose(files: [], text: nil, image: true) == .image)
        #expect(PasteContent.choose(files: [], text: nil, image: false) == .nothing)
        #expect(PasteContent.choose(files: [], text: "", image: false) == .nothing)
    }

    @Test func aKeptImageIsPrivateInItsOwnFolder() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("nt-paste-test-\(getpid())-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: parent) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try ImagePaste.keep(png, in: parent, at: date)
        let second = try ImagePaste.keep(png, in: parent, at: date)
        #expect(first != second && first.lastPathComponent == second.lastPathComponent)
        #expect(first.lastPathComponent == RemoteUpload.imageName(at: date))
        for file in [first, second] {
            #expect(FileManager.default.contents(atPath: file.path) == png)
            let fileMode = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
            #expect(fileMode == 0o600)
            #expect(PrivateFolder.isPrivate(file.deletingLastPathComponent().path))
            #expect(file.deletingLastPathComponent().lastPathComponent.hasPrefix(ImagePaste.prefix))
        }
    }

    @Test func oldImagesGoNewOnesStay() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("nt-paste-old-\(getpid())-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = try ImagePaste.keep(Data([1]), in: parent, at: Date())
        ImagePaste.removeOld(in: parent, now: Date())
        #expect(FileManager.default.fileExists(atPath: file.path))
        ImagePaste.removeOld(in: parent, now: Date().addingTimeInterval(ImagePaste.kept + 60))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aKeptImageNeedsAPrivateParent() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-paste-link-\(getpid())-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: base) }
        let elsewhere = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("next-term-paste")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { try ImagePaste.keep(Data([1]), in: link, at: Date()) }
        // Nothing left behind where the link leads, and the sweep never reaches through it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        ImagePaste.removeOld(in: link, now: Date().addingTimeInterval(ImagePaste.kept * 10))
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }
}

