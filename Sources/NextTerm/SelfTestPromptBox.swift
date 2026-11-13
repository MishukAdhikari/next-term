import AppKit
import NextTermCore

/// The prompt box under a tab's terminal (plan 039 U2): ⇧⌘I shows it with the keyboard; a prompt of two lines arrives
/// as one bracketed paste and then Return; ↑ in the empty box brings it back; Esc in the empty box reaches the program;
/// ⇧⌘I from the box hides it and gives the terminal the keyboard. The program is a stand-in that turns bracketed paste
/// on and writes what it reads to a file.
extension SelfTest {
    static func promptBoxChecks() async {
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-promptbox-\(getpid())"
        try? fm.removeItem(atPath: base)
        try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        let got = base + "/got"
        let holder = app.openWindow(directory: base)
        guard let tab = holder.tabs.first else { return check(false, "prompt box: the window has a tab") }
        defer {
            tab.view.send(txt: "\u{03}")
            holder.window?.close()
            try? fm.removeItem(atPath: base)
        }
        _ = await wait(20) { tab.status.integrated }
        // Under sh, not the tab's zsh, whose settings for the terminal may come back before cat runs; its modes are kept to say why
        // when a check fails.
        let script = "printf '\\033[?2004h'; stty raw -echo; stty -a > \(ShellQuote.quote(got)).stty; exec cat > \(ShellQuote.quote(got))"
        tab.view.send(txt: "/bin/sh -c \(ShellQuote.quote(script))\r")
        _ = await wait(10) { tab.view.getTerminal().bracketedPasteMode }
        func read() -> String { (try? String(contentsOfFile: got, encoding: .utf8)) ?? "" }
        holder.window?.makeKeyAndOrderFront(nil)
        holder.togglePromptBox(nil)
        guard let group = holder.groups.first(where: { $0.contains(tab) }), let box = group.paneView(tab).promptBox else {
            return check(false, "prompt box: ⇧⌘I shows the box")
        }
        check(group.paneView(tab).showsPromptBox && holder.window?.firstResponder === box.textView, "prompt box: it shows with the keyboard")
        box.text = "line one\nline two"
        box.submit()
        let sent = await wait(5) { read().contains("\u{1b}[200~line one\rline two\u{1b}[201~\r") }
        let modes = ((try? String(contentsOfFile: got + ".stty", encoding: .utf8)) ?? "no modes").split(separator: "\n").prefix(4).joined(separator: " ")
        check(sent, "prompt box: two lines arrive as one paste, then Return", read().debugDescription + " — " + modes)
        check(box.text.isEmpty, "prompt box: the box empties once sent")
        box.textView.doCommand(by: #selector(NSResponder.moveUp(_:)))
        check(box.text == "line one\nline two", "prompt box: ↑ brings back what was sent", box.text)
        box.text = ""
        box.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        let escaped = await wait(5) { read().hasSuffix("\u{1b}") }
        check(escaped, "prompt box: Esc in the empty box reaches the program", read().debugDescription)
        holder.togglePromptBox(nil)
        check(!group.paneView(tab).showsPromptBox && holder.window?.firstResponder === tab.view, "prompt box: ⇧⌘I from the box hides it, the terminal takes the keyboard")
    }
}
