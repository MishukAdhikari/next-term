import Foundation
import Testing
@testable import NextTermCore

/// A drop or an image pasted into a remote tab, copied to the host first (RemoteUpload): the host's script, the limits,
/// and what is pasted.
@Suite struct RemoteUploadTests {
    @Test func theScriptHoldsNoNameAndMakesAPrivateFolder() {
        let script = RemoteUpload.script
        #expect(script.contains("umask 077") && script.contains("mktemp -d \"${TMPDIR:-/tmp}/next-term-drop.XXXXXX\""))
        #expect(script.contains("tar -xf - -C \"$nt_d\""))
        #expect(!script.contains("shot.png") && !script.contains("rm -rf"))
    }

    @Test func theAnswerIsTheFolderElseWhyAndACutAnswerIsAFailure() {
        let made = "\(RemoteShell.marker)\ndir\t/tmp/next-term-drop.Ab12Cd\nend\n"
        #expect(RemoteUpload.folder(made) == .success("/tmp/next-term-drop.Ab12Cd"))
        let failed = "noise\n\(RemoteShell.marker)\nfail\tNo space left on device\nend\n"
        #expect(RemoteUpload.folder(failed) == .failure(RemoteUpload.UploadError("The copy failed on the host: No space left on device. Nothing was pasted.")))
        #expect(RemoteUpload.folder("\(RemoteShell.marker)\ndir\t/tmp/x\n") == .failure(RemoteUpload.UploadError("The copy was cut off; nothing was pasted.")))
        #expect(RemoteUpload.folder("") == .failure(RemoteUpload.UploadError("The host did not answer.")))
    }

    @Test func pathsWithSpacesAndQuotesComeOutQuoted() {
        let pasted = RemoteUpload.pasted(folder: "/tmp/next-term-drop.Ab12Cd", names: ["shot.png", "my notes.txt", "it's.md"])
        #expect(pasted == #"'/tmp/next-term-drop.Ab12Cd/shot.png' '/tmp/next-term-drop.Ab12Cd/my notes.txt' '/tmp/next-term-drop.Ab12Cd/it'\''s.md' "#)
    }

    @Test func thirtyThreeItemsOrSixtyFiveMegabytesAreRefusedBeforeAnythingRuns() {
        #expect(RemoteUpload.refusal(items: 32, bytes: RemoteUpload.maxBytes) == nil)
        #expect(RemoteUpload.refusal(items: 33, bytes: 10)?.contains("32 at most") == true)
        #expect(RemoteUpload.refusal(items: 1, bytes: 65 * 1024 * 1024)?.contains("64 MB at most") == true)
        #expect(RemoteUpload.refusal(items: 0, bytes: 0) != nil)
        #expect(RemoteUpload.refusal(items: 2, bytes: 10, names: ["a.png", "a.png"])?.contains("same name") == true)
        #expect(RemoteUpload.imageName(at: Date(timeIntervalSince1970: 0)).hasPrefix("pasted-") && RemoteUpload.imageName(at: Date()).hasSuffix(".png"))
    }

    @Test func aTarStreamUnpacksIntoTheFolderTheScriptPrints() throws {
        // The host's side run here, under /bin/sh, with a stand-in TMPDIR: the stream comes on stdin.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-upload-\(UUID().uuidString)")
        let source = base.appendingPathComponent("src"), tmp = base.appendingPathComponent("tmp")
        for folder in [source, tmp] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        try "hello".write(to: source.appendingPathComponent("my notes.txt"), atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", "-", "-C", source.path, "my notes.txt"]
        let stream = Pipe()
        tar.standardOutput = stream
        try tar.run()
        let data = stream.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        let host = Process()
        host.executableURL = URL(fileURLWithPath: "/bin/sh")
        host.arguments = ["-c", RemoteUpload.script]
        host.environment = ["TMPDIR": tmp.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        host.standardInput = input
        host.standardOutput = output
        try host.run()
        input.fileHandleForWriting.write(data)
        try input.fileHandleForWriting.close()
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        host.waitUntilExit()
        let folder = try RemoteUpload.folder(said).get()
        #expect(folder.hasPrefix(tmp.path + "/next-term-drop."))
        #expect(try String(contentsOfFile: folder + "/my notes.txt", encoding: .utf8) == "hello")
        let mode = try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }
}
