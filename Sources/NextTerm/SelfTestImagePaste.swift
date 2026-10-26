import AppKit
import NextTermCore

/// ⌘V with an image, on a pasteboard of the self-test's own (the user's clipboard is never read or changed): a stand-in
/// claude gets the ⌃V its own key sends; at a shell (cat) the image is kept 0600 in a private folder and
/// its path typed; text beside an image pastes the text; a file Finder copied pastes as its full path; a stand-in ssh
/// gets no image, the image being on this Mac, and a copied file's name rather than its path.
extension SelfTest {
    static func imagePasteChecks(_ tab: TerminalTab, dir: URL) async {
        let board = NSPasteboard(name: NSPasteboard.Name("nt-selftest-paste-\(getpid())"))
        NextTermView.pasteboard = board
        defer {
            NextTermView.pasteboard = .general
            board.releaseGlobally()
        }
        guard let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==") else {
            return check(false, "image paste: a PNG to paste")
        }
        let bin = dir.appendingPathComponent("paste-bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func standIn(_ name: String, _ body: String) {
            let url = bin.appendingPathComponent(name)
            try? "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o755)
        }
        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        func image() {
            board.clearContents()
            board.setData(png, forType: .png)
        }
        /// `cat > out` given the paste, ended once `typed` shows on the screen; what it wrote.
        func catting(_ name: String, paste: () -> Void, until typed: String) async -> String {
            let out = dir.appendingPathComponent(name)
            tab.view.send(txt: "cat > \(out.path)\r")
            _ = await wait(3) { tab.status.running }
            paste()
            tab.view.paste(self)
            _ = await wait(5) { tab.screenTail(4).joined(separator: "\n").contains(typed) }
            tab.view.send(txt: "\u{04}\u{04}") // the line as it is, then the end
            _ = await wait(4) { !tab.status.running }
            return read(out)
        }

        // An agent that reads the clipboard on ⌃V: exactly that byte.
        standIn("claude", #"stty raw -echo; : > "$OUT.ready"; dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' > "$OUT"; stty sane"#)
        let key = dir.appendingPathComponent("agent-key")
        tab.view.send(txt: "PATH=\(bin.path):$PATH OUT=\(key.path) claude\r")
        let running: Bool = await wait(6) { tab.status.running && tab.localAgent == .claude }
        // Its terminal raw before the paste: in the line discipline's own mode ⌃V would be eaten as "next literally".
        let raw: Bool = await wait(6) { FileManager.default.fileExists(atPath: key.path + ".ready") }
        image()
        tab.view.paste(self)
        if !(await wait(4) { !read(key).isEmpty }) { tab.view.send(txt: "\u{03}") } // a plain byte in raw mode: it ends
        check(running && raw && read(key) == "16", "image paste: ⌘V with an image alone sends an agent that reads the clipboard the ⌃V its own key sends",
              "agent \(running), raw \(raw), read \(read(key).debugDescription)")
        _ = await wait(4) { !tab.status.running }

        // At a shell: kept 0600 in a private folder, its quoted path typed.
        let typed: String = await catting("image-path", paste: image, until: "pasted-")
        let path: String = typed.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        let header: Bool = FileManager.default.contents(atPath: path)?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true
        let mode: Int? = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
        let folder: String = (path as NSString).deletingLastPathComponent
        check(path.contains("/\(ImagePaste.parentName)/\(ImagePaste.prefix)") && path.hasSuffix(".png") && header && mode == 0o600
              && PrivateFolder.isPrivate(folder),
              "image paste: at a shell the image is kept 0600 in a private folder and its path typed", typed.debugDescription)
        // Only ever the folder the paste made: never whatever another path typed there might name.
        if folder.hasPrefix(ImagePaste.parent.path + "/" + ImagePaste.prefix), PrivateFolder.isPrivate(folder) {
            try? FileManager.default.removeItem(atPath: folder)
        }

        // Text beside an image: the text.
        let text: String = await catting("image-text", paste: {
            board.clearContents()
            board.declareTypes([.string, .png], owner: nil)
            board.setString("hello", forType: .string)
            board.setData(png, forType: .png)
        }, until: "hello")
        check(text == "hello", "image paste: text beside an image pastes the text", text.debugDescription)

        // A file Finder copied: its full path, as a drop gives it, not its name.
        let file = dir.appendingPathComponent("shot.png")
        try? png.write(to: file)
        let named: String = await catting("image-file", paste: {
            board.clearContents()
            board.writeObjects([file as NSURL])
            board.setString(file.lastPathComponent, forType: .string)
        }, until: "shot.png")
        check(named.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'")) == file.path,
              "image paste: a file Finder copied pastes as its full path", named.debugDescription)

        // Logged in elsewhere (a stand-in ssh): nothing, the image being on this Mac.
        standIn("ssh", #"cat > "$OUT""#)
        let elsewhere = dir.appendingPathComponent("image-ssh")
        tab.view.send(txt: "PATH=\(bin.path):$PATH OUT=\(elsewhere.path) ssh\r")
        let logged: Bool = await wait(4) { tab.status.running && tab.status.program == "ssh" }
        image()
        tab.view.paste(self)
        await pause(1)
        let nothing: Bool = read(elsewhere).isEmpty && !tab.screenTail(3).joined().contains("pasted-")
        // There, a file Finder copied pastes as its name: this Mac's path means nothing on the other machine.
        board.clearContents()
        board.writeObjects([file as NSURL])
        board.setString(file.lastPathComponent, forType: .string)
        tab.view.paste(self)
        _ = await wait(4) { tab.screenTail(3).joined().contains("shot.png") }
        tab.view.send(txt: "\u{04}\u{04}")
        _ = await wait(4) { !tab.status.running }
        let name: String = read(elsewhere).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        check(logged && nothing && name == "shot.png",
              "image paste: a tab logged in to another machine by hand gets no image, and a copied file's name rather than its path",
              "logged \(logged), nothing \(nothing), file \(read(elsewhere).debugDescription)")
    }
}
