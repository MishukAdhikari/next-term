import Foundation
import Testing
@testable import NextTermCore

struct ImagePasteTests {
    @Test func aServerTabAlwaysCopiesItThere() {
        for agent in AgentKind.allCases.map(Optional.some) + [nil] {
            #expect(ImagePaste.way(remote: true, agent: agent, program: agent?.rawValue) == .copyToServer, "\(String(describing: agent))")
        }
    }

    @Test func agentsThatReadTheClipboardGetControlV() {
        for agent: AgentKind in [.claude, .codex, .commandCode, .gemini, .qwen, .opencode, .cursor] {
            #expect(ImagePaste.way(remote: false, agent: agent, program: nil) == .controlV, "\(agent)")
        }
        // As their programs are named.
        for program in ["claude", "claude.exe", "codex", "gemini", "qwen", "opencode", "cursor-agent"] {
            #expect(ImagePaste.way(remote: false, agent: AgentKind(program: program), program: program) == .controlV, "\(program)")
        }
    }

    @Test func everythingElseHereGetsAPath() {
        #expect(ImagePaste.way(remote: false, agent: .copilot, program: "copilot") == .path)
        for program in [nil, "zsh", "vim", "tmux", "herdr", "cat"] {
            #expect(ImagePaste.way(remote: false, agent: nil, program: program) == .path, "\(program ?? "the prompt")")
        }
    }

    @Test func aLoginElsewhereGetsNothing() {
        for program in ["ssh", "mosh", "mosh-client", "autossh", "et", "/usr/bin/ssh"] {
            #expect(ImagePaste.way(remote: false, agent: nil, program: program) == .elsewhere, "\(program)")
        }
    }

    @Test func filesThenTextThenAnImage() {
        let file = "/Users/me/Desktop/shot.png"
        #expect(PasteContent.choose(files: [file], text: nil, image: true) == .files)
        // Finder writes the name beside the file: still the file.
        #expect(PasteContent.choose(files: [file], text: "shot.png", image: true) == .files)
        #expect(PasteContent.choose(files: [file, "/tmp/b.txt"], text: "shot.png\nb.txt", image: false) == .files)
        #expect(PasteContent.choose(files: [file], text: file, image: false) == .files)
        // Text an app meant to paste, beside a file: the text.
        #expect(PasteContent.choose(files: [file], text: "see the screenshot", image: false) == .text)
        #expect(PasteContent.choose(files: [], text: "hello", image: true) == .text)
        #expect(PasteContent.choose(files: [], text: "", image: true) == .image)
        #expect(PasteContent.choose(files: [], text: nil, image: true) == .image)
        #expect(PasteContent.choose(files: [], text: nil, image: false) == .nothing)
        #expect(PasteContent.choose(files: [], text: "", image: false) == .nothing)
    }

    @Test func aKeptImageIsPrivateAndNeverOverwrites() throws {
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
}
