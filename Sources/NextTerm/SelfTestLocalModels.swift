#if DEBUG
import AppKit
import NextTermCore

/// Local model servers in Services (plan 044, items 2 and 3), in a made-up project whose .env names Ollama on a port of
/// the self-test's own: the row (name, detail, badge and its link), the quiet offer line when this look finds no
/// Ollama, the menu (Start Server in a Tab, Pull Model with the model the file names, Copy Base URL), Pull typed in a
/// new tab without Return, and the green dot while a listener of the self-test's own answers on that port, gone once it
/// stops. Menu items are called directly, never by a synthetic click. Start Server is checked, never run: it would
/// start this Mac's own Ollama. Run alone with NEXTTERM_SELFTEST_ONLY=localModels.
extension SelfTest {
    static func localModelsChecks(_ c: TerminalWindowController) async {
        let fm = FileManager.default
        guard let listener = LoopbackListener() else { return check(false, "local models: a listener on a free port") }
        let port = listener.port
        let folder = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-selftest-models-\(getpid())")
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "OLLAMA_HOST=http://localhost:\(port)\nOLLAMA_MODEL=llama3.2\n"
            .write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        SelfTestRunLook.look = {
            ProjectTools.Look(path: [], home: "/nonexistent", isExecutable: { _ in false }, entries: { _ in [] })
        }
        defer { SelfTestRunLook.look = nil }

        let w = AppDelegate.shared.openWindow(directory: folder.path, project: folder.path)
        if !w.isSidebarVisible { w.toggleProjectSidebar(nil) }
        w.window?.makeKeyAndOrderFront(nil)
        let sidebar = w.sidebar
        let group = sidebar.servicesGroup
        let listed = await wait(15) { group.items.map(\.row.id) == ["ollama.local"] }
        check(listed, "local models: .env's OLLAMA_HOST gives one Ollama row", "\(group.items.map(\.row.id))")
        guard let item = group.items.first else { return await close(w, c, folder, listener) }
        let row = item.row
        check(row.name == "Ollama" && row.detail == "AI model · .env" && row.isLocal,
              "local models: the row reads Ollama, AI model · .env, on this Mac", "\(row.name) \(row.detail)")
        check(row.link.badge == ":\(port)" && row.link.url.absoluteString == "http://localhost:\(port)/api/tags",
              "local models: its badge shows the port and opens /api/tags", "\(row.link.badge) \(row.link.url)")

        // No Ollama on this look's PATH or in /Applications: one quiet line above the row.
        let offered = await wait(5) { group.offers.map(\.offer.text) == ["Ollama isn’t installed"] }
        let offerText = group.offers.first.flatMap { offerCell(sidebar, $0)?.shownText }
        check(offered && offerText == "Ollama isn’t installed · Install…", "local models: a missing Ollama gets one quiet line",
              offerText ?? "\(group.offers.map(\.offer.text))")

        // The listener answers: the row gets its green dot.
        sidebar.checkServicePorts()
        let up = await wait(5) { item.running }
        let cell = modelCell(sidebar, item)
        check(up && cell?.runningDot.isHidden == false, "local models: a listening port puts a green dot on the row",
              "running \(item.running), dot hidden \(cell?.runningDot.isHidden ?? true)")
        check(cell?.tip(at: .zero).contains("running now") == true && cell?.accessibilityLabel()?.hasSuffix(", running") == true,
              "local models: its tooltip and label say it is running", cell?.accessibilityLabel() ?? "no cell")
        if let window = w.window { await screenshot(window, suffix: "-local-models") }

        // The menu.
        let menu = sidebar.serviceMenu(for: row)
        let titles = menu.items.map(\.title)
        check(titles == ["Open Ollama Models", "Start Server in a Tab", "Pull Model", "Copy Base URL", "Copy Service Name",
                         "Reveal Source File"], "local models: the row's menu", "\(titles)")
        let start = menu.items.first { $0.title == "Start Server in a Tab" }
        check(start?.representedObject as? String == "ollama serve" && start?.action == #selector(ProjectSidebarView.startServiceServer(_:)),
              "local models: Start Server in a Tab runs “ollama serve”", "\(start?.representedObject ?? "none")")
        let pulls = menu.items.first { $0.title == "Pull Model" }?.submenu
        check(pulls?.items.map(\.title) == ["llama3.2", "", "Other Model…"], "local models: Pull Model lists the file's model",
              "\(pulls?.items.map(\.title) ?? [])")

        // Copy Base URL.
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        if let index = menu.items.firstIndex(where: { $0.title == "Copy Base URL" }) { menu.performActionForItem(at: index) }
        let copied = pasteboard.string(forType: .string)
        check(copied == "http://localhost:\(port)", "local models: Copy Base URL copies the server's address", copied ?? "nothing")
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }

        // Pull llama3.2: typed in a new tab in the project's folder, named after it, not run.
        let before = Set(w.tabs.map(\.id))
        if let pulls, let index = pulls.items.firstIndex(where: { $0.title == "llama3.2" }) { pulls.performActionForItem(at: index) }
        let typed = await wait(20) {
            guard let tab = w.tabs.first(where: { $0.userTitle == "ollama pull llama3.2" }) else { return false }
            return tab.screenTail(6).contains { $0.contains("ollama pull llama3.2") }
        }
        let pullTab = w.tabs.first { $0.userTitle == "ollama pull llama3.2" }
        check(typed && pullTab.map { canonicalPath($0.directory) } == folder.path && pullTab?.status.running == false,
              "local models: Pull Model types “ollama pull llama3.2” in a new tab, for your Return",
              (pullTab?.screenTail(3).joined(separator: " | ") ?? "no tab") + " [tabs \(before.count)→\(w.tabs.count)]")

        // The listener stops: the dot goes at the next look.
        listener.stop()
        sidebar.checkServicePorts()
        let down = await wait(5) { !item.running }
        let after = modelCell(sidebar, item)
        check(down && after?.runningDot.isHidden == true, "local models: once the port stops answering the dot goes",
              "running \(item.running), dot hidden \(after?.runningDot.isHidden ?? false)")

        await close(w, c, folder, listener)
    }

    private static func close(_ w: TerminalWindowController, _ c: TerminalWindowController, _ folder: URL,
                              _ listener: LoopbackListener) async {
        listener.stop()
        func gone() -> Bool { !AppDelegate.shared.controllers.contains { $0 === w } }
        w.closeProject(nil)
        if await wait(5, gone) == false {
            w.window?.close()
            if await wait(5, gone) == false { note("local models: its window did not close") }
        }
        c.window?.makeKeyAndOrderFront(nil)
        try? FileManager.default.removeItem(at: folder)
    }

    private static func modelCell(_ sidebar: ProjectSidebarView, _ item: ServiceItem) -> ServiceCellView? {
        let row = sidebar.outline.row(forItem: item)
        guard row >= 0 else { return nil }
        sidebar.outline.scrollRowToVisible(row)
        sidebar.outline.layoutSubtreeIfNeeded()
        let cell = sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? ServiceCellView
        cell?.layoutSubtreeIfNeeded()
        return cell
    }

    private static func offerCell(_ sidebar: ProjectSidebarView, _ item: RunOfferItem) -> RunCellView? {
        let row = sidebar.outline.row(forItem: item)
        guard row >= 0 else { return nil }
        sidebar.outline.scrollRowToVisible(row)
        sidebar.outline.layoutSubtreeIfNeeded()
        let cell = sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? RunCellView
        cell?.layoutSubtreeIfNeeded()
        return cell
    }
}

/// A TCP listener on 127.0.0.1 at a free port, which accepts nothing: a connect still completes from its backlog,
/// which is all the "is it up" look asks.
final class LoopbackListener {
    let port: Int
    private var fd: Int32

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return nil
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        self.fd = fd
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func stop() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    deinit { stop() }
}
#endif
