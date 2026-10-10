import AppKit

/// Next Term › Acknowledgements: the open-source software the app includes, with each licence, read from the notices
/// that ship inside the app. About Next Term only points here, so it stays one line.
@MainActor
final class AcknowledgementsWindowController: NSWindowController {
    static var shared: AcknowledgementsWindowController?

    /// What the window shows first: the components by name and licence, before the full notices.
    static let summary = """
        Next Term is free software under the MIT License. It includes SwiftTerm (MIT), code from libsixel (MIT), \
        Unicode data (Unicode License v3), shiki-swift (MIT) with Oniguruma (BSD-2-Clause), TextMate grammars under \
        their own permissive licences, Material Icon Theme (MIT; icons from Pictogrammers MDI and Google Material \
        Symbols, Apache-2.0) and SwiftDraw (Zlib). Product and technology logos are trademarks of their owners and \
        are used only to identify file types.
        """

    let textView = NSTextView()

    static func show() {
        if shared == nil { shared = AcknowledgementsWindowController() }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        window.title = "Acknowledgements"
        window.minSize = NSSize(width: 420, height: 320)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Acknowledgements")
        textView.textStorage?.setAttributedString(Self.text())
        scroll.documentView = textView
        window.contentView = scroll
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The summary, then Next Term's own licence and the third-party notices as they ship in the app.
    static func text(resources: URL? = Bundle.main.resourceURL) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString(string: summary + "\n\n", attributes: [.font: body, .foregroundColor: NSColor.labelColor])
        let files = ["LICENSE", "THIRD_PARTY_NOTICES.md"].compactMap { name in
            resources.flatMap { try? String(contentsOf: $0.appendingPathComponent(name), encoding: .utf8) }
        }
        let notices = files.isEmpty
            ? "The full notices are in LICENSE and THIRD_PARTY_NOTICES.md in Next Term's source."
            : files.joined(separator: "\n\n")
        result.append(NSAttributedString(string: notices, attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
        return result
    }
}

extension SelfTest {
    /// Next Term › Acknowledgements opens a window with the summary, and About points to it.
    static func acknowledgementsChecks() {
        let item = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.title == "Acknowledgements" }
        check(item != nil, "acknowledgements: Next Term › Acknowledgements is in the menu")
        AcknowledgementsWindowController.show()
        let shown = AcknowledgementsWindowController.shared
        let text = shown?.textView.string ?? ""
        check(shown?.window?.isVisible == true && text.contains("SwiftTerm (MIT)") && text.contains("trademarks of their owners"),
              "acknowledgements: the window shows the components, their licences and the trademark note", String(text.prefix(80)))
        shown?.close()
    }
}
