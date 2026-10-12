#if DEBUG
import AppKit
import NextTermCore
import SQLite3

/// Made-up projects for the sidebar's links, written from these strings into a temporary folder; nothing is copied
/// from this Mac. Every key value holds "NOT-A-", so a sweep for it finds any that reaches the screen.
private enum LinkFixtures {
    /// A Compose file that runs one service of this image, publishing `port` ("6334:6333").
    static func compose(_ service: String, _ image: String, _ port: String) -> String {
        "services:\n  \(service):\n    image: \(image)\n    ports:\n      - \"\(port)\"\n"
    }

    /// A JS app's Neon database, pulled with `vercel env pull`, and the Neon project `.neon` names.
    static let neonApp: [String: String] = [
        ".env.local": """
        # Created by Vercel CLI
        DATABASE_URL=postgres://shopuser:NOT-A-PASSWORD@ep-cool-dawn-123456-pooler.us-east-2.aws.neon.tech/neondb?sslmode=require
        """,
        ".neon": #"{"projectId": "cold-grass-40154007"}"#,
    ]

    /// A Python RAG project on this Mac: Qdrant in Compose, OpenAI, LangSmith and FastAPI. Its SQLite file is made apart.
    static let ragProject: [String: String] = [
        "pyproject.toml": """
        [project]
        name = "support-bot"
        dependencies = ["qdrant-client>=1.15", "openai", "langsmith", "fastapi[standard]"]
        """,
        ".env": """
        OPENAI_API_KEY=sk-test-NOT-A-KEY
        QDRANT_URL=http://qdrant:6333
        LANGSMITH_TRACING=true
        LANGSMITH_API_KEY=lsv2-test-NOT-A-KEY
        LANGSMITH_PROJECT=support-bot
        """,
        "compose.yaml": compose("qdrant", "qdrant/qdrant:v1.15.0", "6334:6333"),
    ]

    /// A JS app: Next.js on its dev script's port, Supabase, Upstash, Anthropic, and a linked Vercel project.
    static let jsApp: [String: String] = [
        "package.json": """
        {"dependencies": {"next": "^1.0.0", "@supabase/supabase-js": "^1.0.0", "@upstash/redis": "^1.0.0", \
        "@ai-sdk/anthropic": "^1.0.0"}, "scripts": {"dev": "next dev -p 3100"}}
        """,
        ".env.local": """
        NEXT_PUBLIC_SUPABASE_URL=https://abcdefghijklmnopqrst.supabase.co
        KV_REST_API_URL=https://wise-cat-12345.upstash.io
        KV_REST_API_TOKEN=NOT-A-TOKEN
        ANTHROPIC_API_KEY=NOT-A-KEY
        """,
        ".vercel/project.json": #"{"projectId": "prj_abc123", "orgId": "team_abc123", "projectName": "shop-web"}"#,
    ]

    /// The JS app's own Supabase database, written to its `.env` later: Supabase moves to the database row.
    static let supabaseDatabase = "DATABASE_URL=postgres://app:NOT-A-PASSWORD@db.abcdefghijklmnopqrst.supabase.co:5432/postgres\n"

    /// A Python agent project: LangGraph's dev server on 2100, Langfuse in Compose, Anthropic.
    static let agentProject: [String: String] = [
        "langgraph.json": #"{"graphs": {"agent": "./src/agent.py:graph"}}"#,
        "pyproject.toml": """
        [project]
        name = "agent"
        dependencies = ["langgraph", "langgraph-cli[inmem]", "anthropic", "langfuse"]

        [tool.poe.tasks]
        dev = "langgraph dev --port 2100"
        """,
        "compose.yaml": compose("langfuse-web", "langfuse/langfuse:3", "3030:3000"),
        ".env": """
        ANTHROPIC_API_KEY=NOT-A-KEY
        LANGFUSE_HOST=http://localhost:3030
        LANGFUSE_SECRET_KEY=sk-lf-NOT-A-KEY
        LANGFUSE_PUBLIC_KEY=pk-lf-NOT-A-KEY
        """,
    ]

    /// A Laravel site Herd serves as shop.test, and the same `.env` with a user and password in its `APP_URL`.
    static func laravel(appURL: String) -> String {
        "APP_NAME=Shop\nAPP_URL=\(appURL)\nDB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_DATABASE=shop\n"
    }

    static let herdSite: [String: String] = ["artisan": "#!/usr/bin/env php\n", ".env": laravel(appURL: "https://shop.test")]

    /// A Laravel site DDEV runs as shop.ddev.site, with Mailpit beside it.
    static let ddevSite: [String: String] = [".ddev/config.yaml": "name: shop\ntype: laravel\n", "artisan": "\n"]

    /// A Compose service that publishes a port, and nothing that names what it runs.
    static let portOnly: [String: String] = ["compose.yaml": compose("api", "example/api:1", "8000:8000")]

    /// Writes `files` into `folder`, with the folders they need.
    static func write(_ files: [String: String], in folder: URL) {
        let fm = FileManager.default
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A small SQLite file with one table: a Databases row above the Services group.
    static func sqlite(at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        sqlite3_open(url.path, &handle)
        sqlite3_exec(handle, "CREATE TABLE documents (id INTEGER PRIMARY KEY, title TEXT);", nil, nil, nil)
        sqlite3_close(handle)
    }
}

/// The sidebar's links, in made-up projects shown one after another in a project window of their own. A database row's
/// provider badges ("Neon", "Vercel") each open their own page, and a click on one leaves the selection as it was; the
/// pointer's tip over a badge is its page. The Services group sits below Databases, open the first time, its rows in
/// order; a badge, ⌘↓, a double-click, Open Service Page's key and the ⋯ menu's first item open the same page; closed
/// in one project it stays closed there; a changed compose.yaml shows in one scan; a port alone names nothing. No
/// made-up key value reaches a row, tooltip, label, badge or menu, and list_tabs gives agents a served address without
/// its token. Nothing opens: ServiceLinks records each page. Clicks and keys are made from CGEvents, as a hand's arrive,
/// and need the app in front; a menu a click opens is closed at once and fails its check. Run alone with
/// NEXTTERM_SELFTEST_ONLY=services.
extension SelfTest {
    static func serviceChecks(_ c: TerminalWindowController) async {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-selftest-services-\(getpid())")
        try? fm.removeItem(at: base)
        func project(_ name: String, _ files: [String: String]) -> URL {
            let folder = base.appendingPathComponent(name)
            LinkFixtures.write(files, in: folder)
            return folder
        }
        let neon = project("neon-app", LinkFixtures.neonApp)
        let rag = project("support-bot", LinkFixtures.ragProject)
        LinkFixtures.sqlite(at: rag.appendingPathComponent("data/support.sqlite"))
        let js = project("shop-web", LinkFixtures.jsApp)
        let agent = project("research-agent", LinkFixtures.agentProject)
        let herd = project("shop", LinkFixtures.herdSite)
        let ddev = project("ddev-shop", LinkFixtures.ddevSite)
        let api = project("plain-api", LinkFixtures.portOnly)

        let w = AppDelegate.shared.openWindow(directory: neon.path, project: neon.path)
        if !w.isSidebarVisible { w.toggleProjectSidebar(nil) }
        let shortcuts = KeyboardShortcuts.shared
        let savedBindings = shortcuts.bindings
        shortcuts.set(openServicePageKey, for: "sidebar.openServicePage")
        ServiceLinks.recordsOnly = true
        ServiceLinks.opened = []

        await databaseBadgeChecks(w, neon)
        await servicesRowChecks(w, rag)
        await servicesRefreshChecks(w, rag, other: js)
        await jsAppChecks(w, js)
        await agentProjectChecks(w, agent)
        await phpSiteChecks(w, herd: herd, ddev: ddev)
        await portAloneChecks(w, api)
        await servedURLChecks(w, api)

        ServiceLinks.recordsOnly = false
        ServiceLinks.opened = []
        shortcuts.bindings = savedBindings
        shortcuts.apply()
        // As SelfTestGitRefresh closes its window: a refused Close Project still closes it, so the checks after these
        // start with the windows they had, and the folder goes only once nothing watches it.
        func gone() -> Bool { !AppDelegate.shared.controllers.contains { $0 === w } }
        w.closeProject(nil)
        if await wait(5, gone) == false {
            w.window?.close()
            if await wait(5, gone) == false { note("links: the services window did not close") }
        }
        c.window?.makeKeyAndOrderFront(nil)
        try? fm.removeItem(at: base)
    }

    /// Open Service Page's key for these checks (it has none by default): ⌃⌥⌘P, which nothing else uses.
    private static let openServicePageKey = KeyChord(key: "p", command: true, option: true, control: true)

    /// Shows `project` in the window's tree, and waits until its scan has been read and shown with none still going.
    private static func showProject(_ sidebar: ProjectSidebarView, _ project: URL) async -> Bool {
        sidebar.setRoot(project.path)
        let path = canonicalPath(project.path)
        return await wait(15) { sidebar.root?.path == path && scanSettled(sidebar) }
    }

    /// Every scan started has been read, and so shown (the read is noted as its rows are shown).
    private static func scanSettled(_ sidebar: ProjectSidebarView) -> Bool {
        let stats = sidebar.databaseScanStats
        return stats.started > 0 && stats.read == stats.started
    }

    private static func serviceNames(_ sidebar: ProjectSidebarView) -> [String] {
        sidebar.servicesGroup.items.map { (item: ServiceItem) -> String in item.row.name }
    }

    /// The service named `name`: its item, its row in the tree, scrolled into view, and its cell, laid out.
    private static func serviceRowView(_ sidebar: ProjectSidebarView, _ name: String) -> (item: ServiceItem, row: Int, cell: ServiceCellView)? {
        let outline = sidebar.outline
        guard let item = sidebar.servicesGroup.items.first(where: { $0.row.name == name }) else { return nil }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return nil }
        outline.scrollRowToVisible(row)
        outline.layoutSubtreeIfNeeded()
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? ServiceCellView else { return nil }
        cell.layoutSubtreeIfNeeded()
        return (item, row, cell)
    }

    /// The first database row, as `serviceRowView` gives a service's; with `group`, the Databases group's own row.
    private static func databaseRowView(_ sidebar: ProjectSidebarView, group: Bool = false) -> (row: Int, cell: DatabaseCellView)? {
        let outline = sidebar.outline
        let found: AnyObject?
        if group { found = sidebar.databasesGroup } else { found = sidebar.databasesGroup.items.first }
        guard let item = found else { return nil }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return nil }
        outline.scrollRowToVisible(row)
        outline.layoutSubtreeIfNeeded()
        guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? DatabaseCellView else { return nil }
        cell.layoutSubtreeIfNeeded()
        return (row, cell)
    }

    /// The pages ServiceLinks was asked to open since the last look, as written; the record starts again empty.
    private static func takeOpened() -> [String] {
        defer { ServiceLinks.opened = [] }
        return ServiceLinks.opened.map(\.absoluteString)
    }

    /// The app in front with `w`'s window key, as a hand's clicks and keys need; a note for `what` when it can't be.
    private static func front(_ w: TerminalWindowController, _ what: String) async -> Bool {
        guard let window = w.window else { return false }
        if await bringToFront(window) { return true }
        note("links: \(what) skipped, " + notFrontmost(window))
        return false
    }
}

// MARK: - Clicks, keys, tips and the sweep

extension SelfTest {
    /// Whether the clicks below came from CGEvents as asked, or (noted once) as AppKit's own events at the same place.
    private static var linkClicksNoted = false

    /// The menus the clicks below opened since the last look, by their first item's title. A click on a badge opens
    /// none (R4); each one that opens is closed at once, so a click that wrongly opens one (a double-click that reached a
    /// database row) fails its check instead of leaving the run waiting in the menu.
    private static var clickMenus: [String] = []

    private static func takeClickMenus() -> [String] {
        defer { clickMenus = [] }
        return clickMenus
    }

    /// A click as a hand makes one, from CGEvents at `point` in `view`: AppKit hit-tests it in the window as it would a
    /// real click, so one on a badge reaches the badge and one beside it the row. The mouse-up waits in the queue, where
    /// the view's tracking loop takes it. `count` 2 is a double-click's second click. False when the mouse-up was left
    /// over: the click never arrived. A menu it opens is noted in `clickMenus` and closed.
    @discardableResult
    private static func linkClick(_ view: NSView, at point: NSPoint, count: Int = 1) -> Bool {
        guard let down = linkMouseEvent(.leftMouseDown, view, point, count),
              let up = linkMouseEvent(.leftMouseUp, view, point, count) else { return false }
        var menus: [String] = []
        let center = NotificationCenter.default
        let watch = center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { (note: Notification) in
            guard let menu = note.object as? NSMenu, menu !== NSApp.mainMenu else { return }
            menus.append(menu.items.first?.title ?? "an empty menu")
            // Inside the menu's own tracking loop, which runs the common modes.
            menu.perform(#selector(NSMenu.cancelTrackingWithoutAnimation), with: nil, afterDelay: 0, inModes: [.common])
        }
        NSApp.postEvent(up, atStart: false)
        NSApp.sendEvent(down)
        center.removeObserver(watch)
        clickMenus += menus
        var tracked = true
        while let left = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast, inMode: .default, dequeue: true) {
            if left.type == .leftMouseUp { tracked = false }
        }
        return tracked
    }

    /// A click at the centre of `view` (a badge).
    @discardableResult
    private static func linkClick(_ view: NSView) -> Bool {
        linkClick(view, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
    }

    /// A mouse event made from a CGEvent, aimed at `view`'s window as the window server aims one (global coordinates,
    /// the window under the pointer). When AppKit reads another window or place from it, the same click is made as
    /// AppKit's own event, noted once: it still goes through the window's hit-testing, as a hand's does.
    private static func linkMouseEvent(_ type: NSEvent.EventType, _ view: NSView, _ point: NSPoint, _ count: Int) -> NSEvent? {
        guard let window = view.window else { return nil }
        let inWindow = view.convert(point, to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let cgType: CGEventType = type == .leftMouseDown ? .leftMouseDown : .leftMouseUp
        let source = CGEventSource(stateID: .hidSystemState)
        let global = CGPoint(x: onScreen.x, y: top - onScreen.y)
        if let made = CGEvent(mouseEventSource: source, mouseType: cgType, mouseCursorPosition: global, mouseButton: .left) {
            made.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            made.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            made.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            if let event = NSEvent(cgEvent: made), event.windowNumber == window.windowNumber,
               abs(event.locationInWindow.x - inWindow.x) < 1, abs(event.locationInWindow.y - inWindow.y) < 1 {
                return event
            }
        }
        if !linkClicksNoted {
            linkClicksNoted = true
            note("links: a CGEvent's click came without its window here; the clicks are AppKit's own events at the same place")
        }
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                                  pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// A key down made from a CGEvent, as SelfTestGitKeys presses its keys: AppKit reads its characters off the keyboard
    /// layout, as it does a real key's, and it goes to the window with the keyboard. `code` is the key's on a US layout
    /// (↓ 125, P 35); an arrow carries the keypad and fn flags a real arrow key has.
    private static func linkKey(code: UInt16, _ flags: NSEvent.ModifierFlags, arrow: Bool = false) {
        let masks: [(NSEvent.ModifierFlags, CGEventFlags)] = [(.command, .maskCommand), (.shift, .maskShift), (.option, .maskAlternate),
                                                              (.control, .maskControl)]
        guard let key = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: true) else { return }
        var cgFlags = CGEventFlags(masks.filter { flags.contains($0.0) }.map(\.1))
        if arrow { cgFlags.formUnion([.maskNumericPad, .maskSecondaryFn]) }
        key.flags = cgFlags
        guard let event = NSEvent(cgEvent: key) else { return }
        NSApp.sendEvent(event)
    }

    /// On a row's name: past its disclosure arrow and its icon.
    private static func linkNamePoint(_ outline: NSOutlineView, _ row: Int) -> NSPoint {
        let cell = outline.frameOfCell(atColumn: 0, row: row)
        return NSPoint(x: cell.minX + 40, y: cell.midY)
    }

    /// What the sidebar's one tooltip owner says at the centre of `view` (a badge), or at `point` in the outline.
    private static func tipAt(_ sidebar: ProjectSidebarView, _ view: NSView) -> String {
        tipAt(sidebar, view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: sidebar.outline))
    }

    private static func tipAt(_ sidebar: ProjectSidebarView, _ point: NSPoint) -> String {
        sidebar.view(sidebar.outline, stringForToolTip: 0, point: point, userData: nil)
    }

    /// Whether the window's hit-testing finds `view` at its centre, where the click goes: a detail for a failed click.
    private static func isOnTop(_ view: NSView) -> Bool {
        guard let frameView = view.window?.contentView?.superview else { return false }
        return frameView.hitTest(view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)) === view
    }
}

// MARK: - What the rows show, and the site's picture

extension SelfTest {
    /// Every string the Databases and Services rows show, say or offer: each cell's tooltip, label, text and badges' words,
    /// each badge's page and label, the tooltip owner over the row and over each badge, each menu's titles and tooltips,
    /// and both scans as printed.
    private static func linkStrings(_ sidebar: ProjectSidebarView) -> [String] {
        let outline = sidebar.outline
        var shown: [String] = [String(describing: sidebar.databaseScan), String(describing: sidebar.servicesGroup.scan)]
        for row in 0..<outline.numberOfRows {
            let item = outline.item(atRow: row)
            guard item is DatabaseItem || item is DatabasesGroup || ServicesGroup.holds(item) else { continue }
            outline.scrollRowToVisible(row)
            outline.layoutSubtreeIfNeeded()
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            cell.layoutSubtreeIfNeeded()
            var badges: [LinkBadge] = []
            if let database = cell as? DatabaseCellView {
                shown += [database.tipText, database.accessibilityLabel() ?? "", database.nameText, database.badge.text]
                badges = database.badge.badges
            } else if let service = cell as? ServiceCellView {
                shown += [service.tipText, service.accessibilityLabel() ?? "", service.nameText, service.badge.text]
                badges = service.badge.badges
            }
            for badge in badges {
                let page = badge.link?.url.absoluteString ?? ""
                shown += [badge.word, badge.tip ?? "", badge.accessibilityLabel() ?? "", tipAt(sidebar, badge), page]
            }
            let rect = outline.rect(ofRow: row)
            shown.append(tipAt(sidebar, NSPoint(x: rect.midX, y: rect.midY)))
            let menu = sidebarMenu(sidebar, row: row)
            shown += menu.items.flatMap { (item: NSMenuItem) -> [String] in
                let page = (item.representedObject as? ServiceLink)?.url.absoluteString ?? ""
                return [item.title, item.toolTip ?? "", page]
            }
        }
        return shown
    }

    /// No string the rows show or offer holds any of `secrets`.
    private static func checkNoLinkSecret(_ sidebar: ProjectSidebarView, _ secrets: [String], _ name: String) {
        let shown = linkStrings(sidebar)
        let leaks = shown.filter { (text: String) -> Bool in secrets.contains { text.contains($0) } }
        check(shown.count > 2 && leaks.isEmpty, name, leaks.first ?? "\(shown.count) strings")
    }

    /// The site's picture of the Services section: the window as it is on screen, cut to the sidebar's rows from Databases
    /// to the last Services row, saved beside the report with `-services-sidebar.png`. Made-up projects only.
    private static func servicesShot(_ sidebar: ProjectSidebarView) async {
        let args = CommandLine.arguments
        let outline = sidebar.outline
        guard let i = args.firstIndex(of: "--self-test"), i + 1 < args.count, let window = outline.window else { return }
        let rows = (0..<outline.numberOfRows).filter { (row: Int) -> Bool in
            let item = outline.item(atRow: row)
            return item is DatabasesGroup || item is DatabaseItem || ServicesGroup.holds(item)
        }
        guard let first = rows.first, let last = rows.last else { return note("services shot: no Databases or Services rows") }
        outline.deselectAll(nil)
        outline.scrollRowToVisible(last)
        outline.scrollRowToVisible(first)
        await pause(0.4)
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), options) else {
            return note("services shot: the window could not be captured")
        }
        let span = outline.convert(outline.rect(ofRow: first).union(outline.rect(ofRow: last)), to: nil).insetBy(dx: 0, dy: -6)
        let scale = CGFloat(image.width) / window.frame.width
        let top = (window.frame.height - span.maxY) * scale
        let cut = CGRect(x: span.minX * scale, y: top, width: span.width * scale, height: span.height * scale).integral
        guard let cropped = image.cropping(to: cut) else { return note("services shot: the rows are outside the window") }
        let path = (args[i + 1] as NSString).deletingPathExtension + "-services-sidebar.png"
        let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
        try? png?.write(to: URL(fileURLWithPath: path))
        note("screenshot: \(path)")
    }
}

// MARK: - A database row's badges

extension SelfTest {
    /// A JS app's Neon database, pulled with `vercel env pull`: two badges, "Neon" and "Vercel", each opening its own page.
    /// The tip over "Neon" is its page, and the row's elsewhere; a click on a badge opens its page once and leaves the
    /// selection as it was; the row's menu starts with both pages, the first on Open Service Page's key, as the key itself
    /// opens it. Without `.neon`, "Neon" opens Neon's projects page.
    private static func databaseBadgeChecks(_ w: TerminalWindowController, _ project: URL) async {
        let sidebar = w.sidebar
        let outline = sidebar.outline
        let neonPage = "https://console.neon.tech/app/projects/cold-grass-40154007"
        guard await showProject(sidebar, project) else {
            return check(false, "links: the Neon app's files are read", "\(sidebar.databaseScanStats)")
        }
        func words() -> [String] { databaseRowView(sidebar)?.cell.badge.badges.map(\.word) ?? [] }
        let two = await wait(10) { words() == ["Neon", "Vercel"] }
        check(two, "links: a Neon database pulled from Vercel shows two badges, “Neon” and “Vercel”", words().joined(separator: ", "))
        guard two, let shown = databaseRowView(sidebar), shown.cell.badge.badges.count == 2 else { return }
        let neon = shown.cell.badge.badges[0]
        let vercel = shown.cell.badge.badges[1]
        let neonTip = tipAt(sidebar, neon)
        let rowTip = tipAt(sidebar, linkNamePoint(outline, shown.row))
        check(neonTip == "Open Neon Console: project cold-grass-40154007" && !rowTip.isEmpty && rowTip == shown.cell.tipText,
              "links: the tip over “Neon” is its page, and the row's elsewhere on the row", "\(neonTip) / \(rowTip)")
        check(neon.accessibilityRole() == .link && neon.accessibilityLabel() == neonTip,
              "links: VoiceOver reads “Neon” as a link, in its tip's words", neon.accessibilityLabel() ?? "none")

        if await front(w, "a click on a database row's badges") {
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let before = outline.selectedRowIndexes
            _ = takeOpened()
            _ = takeClickMenus()
            let arrived = linkClick(neon)
            let opened = takeOpened()
            let menus = takeClickMenus()
            let onBadge = opened == [neonPage] && outline.selectedRowIndexes == before && menus.isEmpty
            check(onBadge, "links: a click on “Neon” opens the Neon project, and leaves the selection as it was, with no menu",
                  "opened \(opened), selected \(Array(outline.selectedRowIndexes)), menus \(menus), arrived \(arrived), "
                      + "on top \(isOnTop(neon))")
            // Only when the click stayed on the badge: one that reached the row makes this a double-click on a Postgres
            // row, which shows the row's menu.
            if onBadge {
                linkClick(neon)
                linkClick(neon, at: NSPoint(x: neon.bounds.midX, y: neon.bounds.midY), count: 2)
                let doubled = takeOpened()
                let doubleMenus = takeClickMenus()
                check(doubled == [neonPage] && doubleMenus.isEmpty && outline.selectedRowIndexes == before,
                      "links: a double-click on a badge opens its page once, with no menu", "\(doubled), menus \(doubleMenus)")
            } else {
                note("links: the double-click on “Neon” is skipped, as the single click did not stay on the badge")
            }
            let storage = vercel.link?.url.absoluteString ?? "no page"
            linkClick(vercel)
            let byVercel = takeOpened()
            let vercelMenus = takeClickMenus()
            check(byVercel == [storage] && outline.selectedRowIndexes == before && vercelMenus.isEmpty,
                  "links: a click on “Vercel” opens its own page, with no menu",
                  "\(byVercel), selected \(Array(outline.selectedRowIndexes)), menus \(vercelMenus)")
        }

        let menu = sidebarMenu(sidebar, row: shown.row)
        let titles = menu.items.prefix(3).map { (item: NSMenuItem) -> String in item.isSeparatorItem ? "—" : item.title }
        let pageKey = menu.items.first.flatMap(KeyboardShortcuts.chord(of:))?.display ?? "none"
        check(titles == ["Open Neon Console", "Open Vercel Storage", "—"] && pageKey == openServicePageKey.display,
              "links: the row's menu starts with its two pages, the first showing Open Service Page's key",
              titles.joined(separator: ", ") + ", key " + pageKey)
        let all = menu.items.map(\.title)
        if let tablePlus = all.firstIndex(where: { (title: String) -> Bool in title.hasPrefix("Open in TablePlus") }) {
            check(tablePlus > 2, "links: the pages sit above Open in TablePlus", all.joined(separator: ", "))
        }
        _ = takeOpened()
        if let first = menu.items.first, let action = first.action { NSApp.sendAction(action, to: first.target, from: first) }
        let byMenu = takeOpened()
        check(byMenu == [neonPage], "links: the menu's first item opens the Neon project", "\(byMenu)")
        let more = databaseRowView(sidebar)?.cell.onMenu?() ?? NSMenu()
        let moreTitles = more.items.prefix(2).map(\.title)
        let moreKey = more.items.first.flatMap(KeyboardShortcuts.chord(of:))?.display ?? "none"
        if let first = more.items.first, let action = first.action { NSApp.sendAction(action, to: first.target, from: first) }
        let byMore = takeOpened()
        check(moreTitles == ["Open Neon Console", "Open Vercel Storage"] && moreKey == openServicePageKey.display && byMore == [neonPage],
              "links: the row's ⋯ menu starts with the same two pages, its first showing the key and opening the Neon project",
              moreTitles.joined(separator: ", ") + ", key \(moreKey), opened \(byMore)")
        if let window = w.window, await front(w, "Open Service Page's key on a database row") {
            outline.selectRowIndexes(IndexSet(integer: shown.row), byExtendingSelection: false)
            window.makeFirstResponder(outline)
            _ = takeOpened()
            linkKey(code: 35, [.command, .option, .control])
            let byKey = takeOpened()
            check(byKey == [neonPage], "links: Open Service Page's key on a database row opens its first page", "\(byKey)")
        }
        let groupRow = outline.row(forItem: sidebar.databasesGroup)
        let audit = sidebarMenuKeyAudit([(menu: sidebarMenu(sidebar, row: shown.row), row: "Neon"),
                                         (menu: sidebarMenu(sidebar, row: groupRow), row: "Databases")])
        check(audit.wrong.isEmpty, "links: every item of the row's menu, its pages too, is a command showing its key",
              audit.wrong.joined(separator: "; "))
        checkNoLinkSecret(sidebar, ["NOT-A-"], "links: no password in the Neon app's rows, tips, badges, pages or menus")

        try? FileManager.default.removeItem(at: project.appendingPathComponent(".neon"))
        let projects = "https://console.neon.tech/app/projects"
        let plain = await wait(10) { databaseRowView(sidebar)?.cell.badge.badges.first?.link?.url.absoluteString == projects }
        let plainTip = databaseRowView(sidebar)?.cell.badge.badges.first.map { (badge: LinkBadge) -> String in tipAt(sidebar, badge) }
        check(plain && plainTip == "Open Neon Console", "links: without .neon, “Neon” opens Neon's projects page", plainTip ?? "no badge")
    }
}

// MARK: - A Python RAG project's Services rows

extension SelfTest {
    /// A Python RAG project on this Mac: Services below Databases, open the first time, its rows in order with their
    /// badges and tips; Qdrant's dashboard opens every way there is to it; its menus' items are commands; Copy Service
    /// Name copies the name and Reveal Source File selects compose.yaml; nothing secret shows. Then the site's picture.
    private static func servicesRowChecks(_ w: TerminalWindowController, _ project: URL) async {
        let sidebar = w.sidebar
        let outline = sidebar.outline
        let group = sidebar.servicesGroup
        let names = ["OpenAI", "Qdrant", "LangSmith", "FastAPI"]
        guard await showProject(sidebar, project) else {
            return check(false, "links: the RAG project's files are read", "\(sidebar.databaseScanStats)")
        }
        let listed = await wait(10) { serviceNames(sidebar) == names && outline.isItemExpanded(group) }
        check(listed, "links: Services lists OpenAI, Qdrant, LangSmith and FastAPI in that order, open the first time",
              serviceNames(sidebar).joined(separator: ", ") + ", open \(outline.isItemExpanded(group))")
        guard listed else { return }
        let databasesRow = outline.row(forItem: sidebar.databasesGroup)
        let servicesRow = outline.row(forItem: group)
        let inTree = (outline.parent(forItem: group) as? FileNode) === sidebar.root
        check(databasesRow >= 0 && servicesRow > databasesRow && inTree, "links: the Services group sits below Databases in the project's tree",
              "Databases at row \(databasesRow), Services at \(servicesRow)")
        let words = names.map { (name: String) -> String in serviceRowView(sidebar, name)?.cell.badge.text ?? "none" }
        check(words == ["Platform", ":6334", "Projects", ":8000"], "links: each service row has its badge", words.joined(separator: ", "))
        guard let qdrant = serviceRowView(sidebar, "Qdrant"), let badge = qdrant.cell.badge.badges.first else {
            return check(false, "links: Qdrant's row shows its badge")
        }
        let page = "http://localhost:6334/dashboard"
        let row = qdrant.item.row
        let badgeTip = tipAt(sidebar, badge)
        let rowTip = tipAt(sidebar, linkNamePoint(outline, qdrant.row))
        let tipsRight = badgeTip == row.link.tooltip && rowTip == row.tooltip && rowTip.contains("(from compose.yaml)")
        check(row.link.url.absoluteString == page && tipsRight,
              "links: Qdrant's tip is its page over the badge, and names compose.yaml elsewhere on the row", "\(badgeTip) / \(rowTip)")
        func rowTipOf(_ name: String) -> String {
            serviceRowView(sidebar, name).map { (shown: (item: ServiceItem, row: Int, cell: ServiceCellView)) -> String in
                tipAt(sidebar, linkNamePoint(outline, shown.row))
            } ?? "no row"
        }
        let langsmith = rowTipOf("LangSmith")
        let fastAPI = rowTipOf("FastAPI")
        check(langsmith.contains("Project: support-bot") && fastAPI.contains("(default port)"),
              "links: LangSmith's tip names its project, and FastAPI's says its port is the default", "\(langsmith) / \(fastAPI)")
        check(badge.accessibilityRole() == .link && qdrant.cell.accessibilityLabel() == row.accessibilityLabel,
              "links: VoiceOver reads Qdrant's row by name and kind, and its badge as a link", qdrant.cell.accessibilityLabel() ?? "none")
        await serviceOpens(w, "Qdrant", page)
        await cloudAndDocsPages(w)
        await serviceMenuChecks(w, names, project: project)
        checkNoLinkSecret(sidebar, ["NOT-A-"], "links: no key value in the RAG project's rows, tips, badges, pages or menus")
        rowFitChecks(sidebar)
        await servicesShot(sidebar)
    }

    /// The service's page, every way to it: a click on its badge (the selection stays as it was), ⌘↓ on its selected row,
    /// a double-click on the row (once), Open Service Page's key, and the ⋯ menu's first item, which shows that key.
    private static func serviceOpens(_ w: TerminalWindowController, _ name: String, _ page: String) async {
        let sidebar = w.sidebar
        let outline = sidebar.outline
        if let window = w.window, await front(w, "\(name)'s clicks and keys"),
           let shown = serviceRowView(sidebar, name), let badge = shown.cell.badge.badges.first {
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let before = outline.selectedRowIndexes
            _ = takeOpened()
            _ = takeClickMenus()
            let arrived = linkClick(badge)
            let byBadge = takeOpened()
            let menus = takeClickMenus()
            check(byBadge == [page] && outline.selectedRowIndexes == before && menus.isEmpty,
                  "links: a click on \(name)'s badge opens \(page), and leaves the selection as it was, with no menu",
                  "opened \(byBadge), selected \(Array(outline.selectedRowIndexes)), menus \(menus), arrived \(arrived), "
                      + "on top \(isOnTop(badge))")
            outline.selectRowIndexes(IndexSet(integer: shown.row), byExtendingSelection: false)
            window.makeFirstResponder(outline)
            linkKey(code: 125, [.command], arrow: true)
            let byOpenKey = takeOpened()
            check(byOpenKey == [page], "links: ⌘↓ on \(name)'s selected row opens it", "\(byOpenKey)")
            let point = linkNamePoint(outline, shown.row)
            linkClick(outline, at: point)
            linkClick(outline, at: point, count: 2)
            let byDoubleClick = takeOpened()
            let rowMenus = takeClickMenus()
            check(byDoubleClick == [page] && rowMenus.isEmpty, "links: a double-click on \(name)'s row opens it once",
                  "\(byDoubleClick), menus \(rowMenus)")
            window.makeFirstResponder(outline)
            linkKey(code: 35, [.command, .option, .control])
            let byPageKey = takeOpened()
            check(byPageKey == [page], "links: Open Service Page's key on \(name)'s row opens it", "\(byPageKey)")
        }
        guard let shown = serviceRowView(sidebar, name) else { return check(false, "links: \(name)'s row for its ⋯ menu") }
        let menu = shown.cell.onMenu?() ?? NSMenu()
        let first = menu.items.first
        let key = first.flatMap(KeyboardShortcuts.chord(of:))?.display ?? "none"
        _ = takeOpened()
        if let first, let action = first.action { NSApp.sendAction(action, to: first.target, from: first) }
        let byMenu = takeOpened()
        check(byMenu == [page] && first?.title == shown.item.row.link.title && key == openServicePageKey.display,
              "links: the ⋯ menu's first item, “\(first?.title ?? "none")”, opens \(name)'s page, showing Open Service Page's key",
              "opened \(byMenu), key \(key)")
    }

    /// The RAG project's other pages (AE1): LangSmith opens smith.langchain.com, and FastAPI its docs on the default port,
    /// from their rows' links and from a click on each badge.
    private static func cloudAndDocsPages(_ w: TerminalWindowController) async {
        let sidebar = w.sidebar
        let names = ["LangSmith", "FastAPI"]
        let pages = ["https://smith.langchain.com", "http://localhost:8000/docs"]
        let links = names.map { (name: String) -> String in
            sidebar.servicesGroup.items.first { (item: ServiceItem) -> Bool in item.row.name == name }?.row.link.url.absoluteString ?? "none"
        }
        check(links == pages, "links: LangSmith opens smith.langchain.com, and FastAPI its docs on :8000", links.joined(separator: ", "))
        guard await front(w, "a click on LangSmith's and FastAPI's badges") else { return }
        _ = takeOpened()
        _ = takeClickMenus()
        var clicked: [String] = []
        for name in names {
            if let badge = serviceRowView(sidebar, name)?.cell.badge.badges.first { linkClick(badge) }
            clicked += takeOpened()
        }
        let menus = takeClickMenus()
        check(clicked == pages && menus.isEmpty, "links: a click on LangSmith's badge, then FastAPI's, opens those pages",
              "\(clicked), menus \(menus)")
    }
}

// MARK: - Menus, a changed file, a closed group, files gone

extension SelfTest {
    /// Every item of the Services rows' menus and of the group's is a command showing its key; Copy Service Name copies
    /// the name alone, and Reveal Source File selects compose.yaml in the tree.
    private static func serviceMenuChecks(_ w: TerminalWindowController, _ names: [String], project: URL) async {
        let sidebar = w.sidebar
        let outline = sidebar.outline
        var menus: [(menu: NSMenu, row: String)] = []
        for name in names {
            if let shown = serviceRowView(sidebar, name) { menus.append((menu: sidebarMenu(sidebar, row: shown.row), row: name)) }
        }
        menus.append((menu: sidebarMenu(sidebar, row: outline.row(forItem: sidebar.servicesGroup)), row: "Services"))
        let audit = sidebarMenuKeyAudit(menus)
        let unseen = ["Copy Service Name", "Reveal Source File", "Refresh Services"].filter { (title: String) -> Bool in
            !audit.titles.contains(title)
        }
        check(menus.count == names.count + 1 && audit.wrong.isEmpty && unseen.isEmpty,
              "links: each item of a Services row's menu, and of the group's, is a command showing its key",
              (audit.wrong + unseen.map { (title: String) -> String in "no \(title)" }).joined(separator: "; "))
        guard let qdrant = serviceRowView(sidebar, "Qdrant") else { return }
        let menu = sidebarMenu(sidebar, row: qdrant.row)
        func perform(_ title: String) {
            guard let item = menu.items.first(where: { (item: NSMenuItem) -> Bool in item.title == title }), let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        perform("Copy Service Name")
        let copied = pasteboard.string(forType: .string) ?? "nothing"
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
        check(copied == "Qdrant", "links: Copy Service Name copies the service's name alone", copied)
        perform("Reveal Source File")
        let compose = canonicalPath(project.appendingPathComponent("compose.yaml").path)
        let revealed = await wait(5) {
            outline.selectedRowIndexes.count == 1 && (outline.item(atRow: outline.selectedRow) as? FileNode)?.path == compose
        }
        let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.path ?? "row \(outline.selectedRow)"
        check(revealed, "links: Reveal Source File selects compose.yaml in the tree", selected)
    }

    /// A changed compose.yaml moves Qdrant to its new port in one scan of the sidebar's gated refresh. The group closed in
    /// this project stays closed after a rescan that changes its rows (one that changes nothing draws nothing) and a visit
    /// to `other`, where it opens; it goes when the files that named its services do.
    private static func servicesRefreshChecks(_ w: TerminalWindowController, _ project: URL, other: URL) async {
        let sidebar = w.sidebar
        let outline = sidebar.outline
        let group = sidebar.servicesGroup
        guard await showProject(sidebar, project), await wait(10, { serviceNames(sidebar).count == 4 }) else {
            return check(false, "links: the RAG project's rows, for the refresh checks", serviceNames(sidebar).joined(separator: ", "))
        }
        func qdrantPage() -> String {
            group.items.first { (item: ServiceItem) -> Bool in item.row.name == "Qdrant" }?.row.link.url.absoluteString ?? "none"
        }
        let compose = project.appendingPathComponent("compose.yaml")
        func setPort(_ port: String) {
            try? LinkFixtures.compose("qdrant", "qdrant/qdrant:v1.15.0", port).write(to: compose, atomically: true, encoding: .utf8)
        }
        // The last scan's gate is over: the change below sets off one gated scan, at most 5 s after the last plus 1 s
        // to settle.
        await pause(1.5)
        _ = await wait(6) { scanSettled(sidebar) }
        let scans = sidebar.databaseScanToken
        let changed = Date()
        setPort("6335:6333")
        let moved = await wait(10) { qdrantPage() == "http://localhost:6335/dashboard" }
        let took = Date().timeIntervalSince(changed)
        let ran = sidebar.databaseScanToken - scans
        let word = serviceRowView(sidebar, "Qdrant")?.cell.badge.text ?? "none"
        check(moved && word == ":6335" && ran == 1 && took < 7, "links: a changed compose.yaml moves Qdrant to its new port in one scan",
              "\(qdrantPage()), badge \(word), \(ran) scans in " + String(format: "%.1f s", took))

        // Closed, then a scan that changes its rows, so the group is drawn again while closed.
        outline.collapseItem(group)
        setPort("6334:6333")
        let redrawn = await wait(10) { qdrantPage() == "http://localhost:6334/dashboard" }
        await pause(0.5)
        let closedAfterScan = redrawn && !outline.isItemExpanded(group)
        let away = await showProject(sidebar, other)
        let openThere = await wait(10) { !group.items.isEmpty && outline.isItemExpanded(group) }
        let back = await showProject(sidebar, project)
        let listedAgain = await wait(10) { serviceNames(sidebar).count == 4 }
        await pause(0.5)
        let stillClosed = listedAgain && !outline.isItemExpanded(group)
        check(away && back && closedAfterScan && openThere && stillClosed,
              "links: the Services group closed in one project stays closed there, after a rescan that changes its rows and a visit "
                  + "to another where it opens",
              "after the rescan \(closedAfterScan ? "closed" : redrawn ? "open" : "not seen"), "
                  + "in the other project \(openThere ? "open" : "closed"), back \(stillClosed ? "closed" : "open")")
        outline.expandItem(group)

        for name in ["pyproject.toml", ".env", "compose.yaml"] {
            try? FileManager.default.removeItem(at: project.appendingPathComponent(name))
        }
        let gone = await wait(12) { group.items.isEmpty && outline.row(forItem: group) < 0 }
        check(gone, "links: the Services group goes when the files that named its services do", serviceNames(sidebar).joined(separator: ", "))
    }
}

// MARK: - A JS app and a Python agent project

extension SelfTest {
    /// A JS app: Anthropic, Next.js on its dev script's port (not a default one), Supabase opening its project, Upstash,
    /// and Vercel naming the linked project. With its own Supabase database, the database row carries Supabase's badge,
    /// the group's row Vercel's, and Services no longer lists Supabase.
    private static func jsAppChecks(_ w: TerminalWindowController, _ project: URL) async {
        let sidebar = w.sidebar
        let outline = sidebar.outline
        let names = ["Anthropic", "Next.js", "Supabase", "Upstash", "Vercel"]
        guard await showProject(sidebar, project) else {
            return check(false, "links: the JS app's files are read", "\(sidebar.databaseScanStats)")
        }
        let listed = await wait(10) { serviceNames(sidebar) == names }
        check(listed, "links: a JS app lists Anthropic, Next.js, Supabase, Upstash and Vercel", serviceNames(sidebar).joined(separator: ", "))
        guard listed else { return }
        let words = names.map { (name: String) -> String in serviceRowView(sidebar, name)?.cell.badge.text ?? "none" }
        check(words == ["Console", ":3100", "Dashboard", "Console", "Dashboard"], "links: each of the JS app's rows has its badge",
              words.joined(separator: ", "))
        let next = serviceRowView(sidebar, "Next.js")
        let nextBadge = next?.cell.badge.badges.first
        let nextTip = nextBadge.map { (badge: LinkBadge) -> String in tipAt(sidebar, badge) } ?? "no badge"
        let nextRow = next.map { (shown: (item: ServiceItem, row: Int, cell: ServiceCellView)) -> String in
            tipAt(sidebar, linkNamePoint(outline, shown.row))
        } ?? "no row"
        check(nextTip == "Open Next.js at localhost:3100 (from package.json's dev script)" && !nextRow.contains("default port"),
              "links: Next.js opens on its dev script's port, not a default one", "\(nextTip) / \(nextRow)")
        let vercelTip = serviceRowView(sidebar, "Vercel").map { (shown: (item: ServiceItem, row: Int, cell: ServiceCellView)) -> String in
            tipAt(sidebar, linkNamePoint(outline, shown.row))
        } ?? "no row"
        check(vercelTip.contains("Project: shop-web"), "links: Vercel's tip names the linked project", vercelTip)
        let supabasePage = "https://supabase.com/dashboard/project/abcdefghijklmnopqrst"
        if await front(w, "a click on Supabase's badge"), let badge = serviceRowView(sidebar, "Supabase")?.cell.badge.badges.first {
            _ = takeOpened()
            linkClick(badge)
            let opened = takeOpened()
            check(opened == [supabasePage], "links: Supabase's badge opens its project's dashboard", "\(opened)")
        }
        checkNoLinkSecret(sidebar, ["NOT-A-"], "links: no key value in the JS app's rows, tips, badges, pages or menus")

        let env = project.appendingPathComponent(".env")
        try? LinkFixtures.supabaseDatabase.write(to: env, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: env) }
        let moved = await wait(12) { !serviceNames(sidebar).contains("Supabase") && databaseRowView(sidebar) != nil }
        let rowBadge = databaseRowView(sidebar)?.cell.badge.badges.first
        let rowPage = rowBadge?.link?.url.absoluteString ?? "none"
        check(moved && rowBadge?.word == "Supabase" && rowPage == supabasePage,
              "links: with its Supabase database, the database row carries Supabase's badge and Services no longer lists it",
              serviceNames(sidebar).joined(separator: ", ") + "; badge \(rowBadge?.word ?? "none") \(rowPage)")
        let groupBadges = databaseRowView(sidebar, group: true)?.cell.badge.badges ?? []
        let groupWords = groupBadges.map(\.word)
        check(groupWords == ["Vercel"] && groupBadges.first?.link != nil,
              "links: the Databases group's row of a Vercel-linked app has Vercel's badge, a link", groupWords.joined(separator: ", "))
        if let vercel = groupBadges.first, let page = vercel.link?.url.absoluteString, await front(w, "a click on the group's Vercel badge") {
            _ = takeOpened()
            linkClick(vercel)
            let opened = takeOpened()
            check(opened == [page], "links: the group's Vercel badge opens its page", "\(opened)")
        }
        checkNoLinkSecret(sidebar, ["NOT-A-"], "links: no password in the JS app's database rows, tips, badges, pages or menus")
    }

    /// A Python agent project: Anthropic, Langfuse on the port its files set, and LangGraph's Studio for the dev server's
    /// port; "Studio" opens Studio for it. The keys' values never show.
    private static func agentProjectChecks(_ w: TerminalWindowController, _ project: URL) async {
        let sidebar = w.sidebar
        let names = ["Anthropic", "Langfuse", "LangGraph"]
        guard await showProject(sidebar, project) else {
            return check(false, "links: the agent project's files are read", "\(sidebar.databaseScanStats)")
        }
        let listed = await wait(10) { serviceNames(sidebar) == names }
        check(listed, "links: a Python agent project lists Anthropic, Langfuse and LangGraph", serviceNames(sidebar).joined(separator: ", "))
        guard listed else { return }
        let words = names.map { (name: String) -> String in serviceRowView(sidebar, name)?.cell.badge.text ?? "none" }
        let langfuse = sidebar.servicesGroup.items.first { (item: ServiceItem) -> Bool in item.row.name == "Langfuse" }
        let langfusePage = langfuse?.row.link.url.absoluteString ?? "none"
        check(words == ["Console", ":3030", "Studio"] && langfusePage == "http://localhost:3030",
              "links: Langfuse opens on the port its files set, LangGraph in Studio", words.joined(separator: ", ") + "; " + langfusePage)
        let studio = "https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2100"
        if await front(w, "a click on LangGraph's Studio badge"), let badge = serviceRowView(sidebar, "LangGraph")?.cell.badge.badges.first {
            _ = takeOpened()
            linkClick(badge)
            let opened = takeOpened()
            check(opened == [studio], "links: “Studio” opens LangGraph Studio for the dev server's port", "\(opened)")
        }
        checkNoLinkSecret(sidebar, ["NOT-A-"], "links: no key value in the agent project's rows, tips, badges, pages or menus")
    }
}

// MARK: - PHP sites, and a port that names nothing

extension SelfTest {
    /// A Laravel site: with Herd here, the database row's badge (herdChecks); without, Valet's row (valetChecks). Either
    /// way an APP_URL with a user and password is refused, unseen. A DDEV project lists DDEV, opening its site, with
    /// Mailpit on its own port as its menu's second page, which only the first of shows Open Service Page's key.
    private static func phpSiteChecks(_ w: TerminalWindowController, herd: URL, ddev: URL) async {
        let sidebar = w.sidebar
        if Databases.herdIsInstalled {
            await herdChecks(w, herd)
        } else {
            note("links: Herd is not installed here; its badge's checks are skipped, and the site is checked as Valet's")
            await valetChecks(w, herd)
        }
        guard await showProject(sidebar, ddev) else {
            return check(false, "links: the DDEV project's files are read", "\(sidebar.databaseScanStats)")
        }
        let listed = await wait(10) { serviceNames(sidebar) == ["DDEV"] }
        check(listed, "links: a DDEV project lists DDEV", serviceNames(sidebar).joined(separator: ", "))
        guard listed, let shown = serviceRowView(sidebar, "DDEV") else { return }
        let pages = shown.item.row.links.map { (link: ServiceLink) -> String in link.url.absoluteString }
        check(pages == ["https://shop.ddev.site", "https://shop.ddev.site:8026"] && shown.cell.badge.text == "Site",
              "links: DDEV's badge opens its site, and Mailpit has its own port", pages.joined(separator: ", ") + "; " + shown.cell.badge.text)
        let menu = sidebarMenu(sidebar, row: shown.row)
        let pageItems = menu.items.filter { (item: NSMenuItem) -> Bool in item.representedObject is ServiceLink }
        let audit = sidebarMenuKeyAudit([(menu: menu, row: "DDEV")])
        check(pageItems.count == 2 && audit.wrong.isEmpty, "links: DDEV's menu lists both pages, the first on Open Service Page's key",
              pageItems.map(\.title).joined(separator: ", ") + "; " + audit.wrong.joined(separator: "; "))
        if let mailpit = pageItems.last, let action = mailpit.action {
            _ = takeOpened()
            NSApp.sendAction(action, to: mailpit.target, from: mailpit)
            let opened = takeOpened()
            check(opened == ["https://shop.ddev.site:8026"], "links: the menu's Mailpit item opens Mailpit", "\(opened)")
        }
    }

    /// A Laravel site Herd serves: the database row's "Herd" badge opens https://shop.test, and Services leaves it to that
    /// badge. An APP_URL with a user and password is refused: the badge opens Herd's services docs, and neither the user
    /// nor the password shows anywhere.
    private static func herdChecks(_ w: TerminalWindowController, _ project: URL) async {
        let sidebar = w.sidebar
        guard await showProject(sidebar, project) else {
            return check(false, "links: the Laravel site's files are read", "\(sidebar.databaseScanStats)")
        }
        func badge() -> LinkBadge? { databaseRowView(sidebar)?.cell.badge.badges.first }
        let site = await wait(10) { badge()?.word == "Herd" && badge()?.link?.url.absoluteString == "https://shop.test" }
        let tip = badge().map { (herd: LinkBadge) -> String in tipAt(sidebar, herd) } ?? "no badge"
        check(site && tip == "Open shop.test, the site Herd serves" && serviceNames(sidebar).isEmpty,
              "links: the Laravel database row's “Herd” badge opens the site Herd serves, and Services leaves it to that badge",
              tip + "; services " + serviceNames(sidebar).joined(separator: ", "))
        if site, await front(w, "a click on Herd's badge"), let herd = badge() {
            _ = takeOpened()
            linkClick(herd)
            let opened = takeOpened()
            check(opened == ["https://shop.test"], "links: a click on “Herd” opens https://shop.test", "\(opened)")
        }
        let env = LinkFixtures.laravel(appURL: "http://admin:NOT-A-PASSWORD@shop.test")
        try? env.write(to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let docs = "https://herd.laravel.com/docs/macos/herd-pro-services/services"
        let refused = await wait(10) { badge()?.link?.url.absoluteString == docs }
        check(refused, "links: an APP_URL with a user and password is refused, and “Herd” opens Herd's services docs",
              badge()?.link?.url.absoluteString ?? "no badge")
        checkNoLinkSecret(sidebar, ["NOT-A-", "admin"], "links: neither the APP_URL's user nor its password shows anywhere")
    }

    /// The same Laravel site on a Mac without Herd: Valet's row opens https://shop.test, its tip naming .env. An APP_URL
    /// with a user and password names no site, so the row goes, and neither the user nor the password shows anywhere.
    private static func valetChecks(_ w: TerminalWindowController, _ project: URL) async {
        let sidebar = w.sidebar
        let group = sidebar.servicesGroup
        guard await showProject(sidebar, project) else {
            return check(false, "links: the Laravel site's files are read", "\(sidebar.databaseScanStats)")
        }
        let listed = await wait(10) { serviceNames(sidebar) == ["Valet"] }
        let shown = serviceRowView(sidebar, "Valet")
        let badge = shown?.cell.badge.badges.first
        let page = badge?.link?.url.absoluteString ?? "none"
        let tip = badge.map { (valet: LinkBadge) -> String in tipAt(sidebar, valet) } ?? "no badge"
        let word = shown?.cell.badge.text ?? "none"
        check(listed && page == "https://shop.test" && tip == "Open Valet Site at shop.test (from .env)" && word == "Site",
              "links: without Herd, the Laravel site's .test APP_URL lists Valet, whose “Site” opens it",
              serviceNames(sidebar).joined(separator: ", ") + "; \(word) \(page); \(tip)")
        if listed, let badge, await front(w, "a click on Valet's badge") {
            _ = takeOpened()
            linkClick(badge)
            let opened = takeOpened()
            check(opened == ["https://shop.test"], "links: a click on Valet's “Site” opens https://shop.test", "\(opened)")
        }
        let env = LinkFixtures.laravel(appURL: "http://admin:NOT-A-PASSWORD@shop.test")
        try? env.write(to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let refused = await wait(10) { group.items.isEmpty && sidebar.outline.row(forItem: group) < 0 }
        check(refused, "links: without Herd, an APP_URL with a user and password names no site, and Valet's row goes",
              serviceNames(sidebar).joined(separator: ", "))
        checkNoLinkSecret(sidebar, ["NOT-A-", "admin"], "links: without Herd, neither the APP_URL's user nor its password shows anywhere")
    }

    /// A Compose service that publishes a port, and nothing that names what it runs, makes no Services row.
    private static func portAloneChecks(_ w: TerminalWindowController, _ project: URL) async {
        let sidebar = w.sidebar
        guard await showProject(sidebar, project) else {
            return check(false, "links: the Compose-only project's files are read", "\(sidebar.databaseScanStats)")
        }
        await pause(0.5)
        let group = sidebar.servicesGroup
        check(group.items.isEmpty && sidebar.outline.row(forItem: group) < 0, "links: a Compose port alone names no service",
              serviceNames(sidebar).joined(separator: ", "))
    }
}

// MARK: - A served address's token, as agents see it

extension SelfTest {
    /// AE11 (R17): a tab whose command printed Jupyter's address with its token. `list_tabs`, called through `nxtrm mcp`
    /// as an agent calls it, reports `served_url` without the query, and nowhere in its answer is the token; the tab's
    /// tooltip leaves it out too. The tab keeps the address as printed, which File › Open Served URL opens (not opened
    /// here). The command line holds neither "token=" nor the token, so either one in the answer is the address's.
    private static func servedURLChecks(_ w: TerminalWindowController, _ project: URL) async {
        let server = MCPControlServer.shared
        guard server.isRunning, let mcp = MCPTestClient(socket: server.path) else {
            return check(false, "served URL: `nxtrm mcp` starts, for list_tabs")
        }
        defer { mcp.close() }
        let tab = w.addTab(directory: project.path)
        defer { w.remove(tab) }
        guard await wait(20, { tab.status.integrated }) else { return check(false, "served URL: the tab's shell starts") }
        tab.view.send(txt: "printf '    http://localhost:%s/lab?%s=NOT-A-%s\\n' 8888 token TOKEN; sleep 15\r")
        let printed = "http://localhost:8888/lab?token=NOT-A-TOKEN"
        let seen = await wait(8) { tab.servedURL?.absoluteString == printed }
        check(seen && tab.title.hasSuffix(" · :8888"), "served URL: the tab keeps Jupyter's address as printed, for File › Open Served URL",
              (tab.servedURL?.absoluteString ?? "none") + "; " + tab.title)
        guard seen else { return }
        let hello: [String: Any] = ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                    "clientInfo": ["name": "selftest", "version": "1"]]
        _ = await mcp.call(1, "initialize", hello)
        let reply = await mcp.call(2, "tools/call", ["name": "list_tabs", "arguments": [String: Any]()])
        let result = reply?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        let tabs = (json?["windows"] as? [[String: Any]] ?? []).flatMap { (window: [String: Any]) -> [[String: Any]] in
            window["tabs"] as? [[String: Any]] ?? []
        }
        let id = tab.id.uuidString.lowercased()
        let listed = tabs.first { (info: [String: Any]) -> Bool in info["id"] as? String == id }
        let served = listed?["served_url"] as? String ?? "none"
        let leaks = ["NOT-A-TOKEN", "token="].filter { (secret: String) -> Bool in text.contains(secret) }
        check(served == "http://localhost:8888/lab" && leaks.isEmpty, "served URL: list_tabs gives agents the address without its token",
              "served_url \(served), found \(leaks)" + (text.isEmpty ? ", no answer" : ""))
        let tip = tab.tooltip
        check(tip.contains("Serving http://localhost:8888/lab") && !tip.contains("NOT-A-TOKEN") && !tip.contains("token="),
              "served URL: the tab's tooltip leaves the token out", tip.replacingOccurrences(of: "\n", with: " | "))
        tab.view.send(txt: "\u{3}") // the sleep
        _ = await wait(5) { !tab.status.running }
    }
}
#endif
