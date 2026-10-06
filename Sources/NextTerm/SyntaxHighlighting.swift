import AppKit
import NextTermCore
import Shiki

/// The grammar engine: VS Code's TextMate grammars, tokenized natively by shiki-swift, over the
/// licence-checked grammars in Resources/Highlighting. One per app; grammars load on first use.
final class SyntaxEngine {
    static let theme = "next-dark"
    /// nil if the grammar folder is missing (a broken build): files then open as plain text.
    static let shared: SyntaxEngine? = {
        guard let folder = resourceFolder, let bundle = Bundle(url: folder),
              let assets = try? BundledShikiAssets(bundle: bundle),
              let highlighter = try? ShikiHighlighter(defaultTheme: theme, assets: assets) else {
            NSLog("Next Term: syntax highlighting unavailable")
            return nil
        }
        return SyntaxEngine(assets: assets, highlighter: highlighter)
    }()

    /// Contents/Resources/Highlighting in the app; the source tree's copy for `swift run`.
    static var resourceFolder: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Highlighting"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/Highlighting"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("language-manifest.json").path)
        }
    }

    let assets: BundledShikiAssets
    let highlighter: ShikiHighlighter
    private var colors: [String: NSColor] = [:]
    private var options = TokenizeWithThemeOptions()

    private init(assets: BundledShikiAssets, highlighter: ShikiHighlighter) {
        self.assets = assets
        self.highlighter = highlighter
        // A minified bundle's 300 kB line is not worth colouring; the rest of the file still is.
        options.tokenizeMaxLineLength = 5_000
        options.tokenizeTimeLimit = 200
    }

    /// The shipped grammar for a language id or alias, or nil.
    func language(_ id: String?) -> String? {
        id.flatMap { assets.canonicalLanguageID(for: $0) }
    }

    /// Tokens of one line (without its line break), continuing from the state the previous line ended
    /// in. Offsets are UTF-16, from the start of the line.
    func tokenize(line: String, language: String, after state: ShikiGrammarState?) -> (tokens: [ThemedToken], state: ShikiGrammarState?)? {
        guard let result = try? highlighter.codeToTokens(line, language: language, theme: Self.theme, options: options, grammarState: state) else {
            return nil
        }
        return (result.tokens.first ?? [], result.grammarState as? ShikiGrammarState)
    }

    func color(_ hex: String?) -> NSColor? {
        guard let hex else { return nil }
        if let cached = colors[hex] { return cached }
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        let color = NSColor(srgbRed: CGFloat(rgba >> 24 & 0xFF) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255,
                            blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
        colors[hex] = color
        return color
    }
}

/// Colours one document as it is edited. Each line's tokens depend on where the previous line left the
/// grammar (inside a comment, a string, a heredoc), so the state at the end of every line is kept: an
/// edit re-tokenizes from its line until a line ends in the same state as before, which for ordinary
/// typing is the one line. Colours are layout-manager temporary attributes: no undo entries, no change
/// to the text.
final class DocumentHighlighter {
    /// Above this, a file opens as plain text: colouring it would cost more than it helps.
    static let maxLength = 4 * 1024 * 1024
    /// Work done in one go before yielding to the run loop, so typing never waits on a long file.
    static let sliceBudget: TimeInterval = 0.008

    private let engine: SyntaxEngine
    let language: String
    private weak var layoutManager: NSLayoutManager?
    private let storage: NSTextStorage
    /// State at the end of each line; nil until that line is tokenized.
    private var states: [ShikiGrammarState?]
    /// Lines before this are tokenized and coloured.
    private var validUpTo = 0
    /// Lines up to here must be redone even if a state matches: an edit changed them.
    private var mustRedoThrough = -1
    private var scheduled = false
    private let lines: () -> LineIndex

    init(engine: SyntaxEngine, language: String, storage: NSTextStorage, layoutManager: NSLayoutManager, lines: @escaping () -> LineIndex) {
        self.engine = engine
        self.language = language
        self.storage = storage
        self.layoutManager = layoutManager
        self.lines = lines
        states = Array(repeating: nil, count: lines().count)
        mustRedoThrough = states.count - 1
        schedule()
    }

    /// Call from the text storage's didProcessEditing, with the index already updated.
    func textEdited(oldLineRange: ClosedRange<Int>, newLineCount lineCount: Int, firstLine: Int, lastLineNow: Int) {
        // Lines oldLineRange were replaced by firstLine...lastLineNow.
        let removed = oldLineRange.count
        let added = lastLineNow - firstLine + 1
        if states.indices.contains(oldLineRange.lowerBound), oldLineRange.upperBound < states.count {
            states.replaceSubrange(oldLineRange, with: Array(repeating: nil, count: added))
        } else {
            states = Array(repeating: nil, count: lineCount)
        }
        if states.count != lineCount { states = Array(repeating: nil, count: lineCount); validUpTo = 0 }
        let shift = added - removed
        if validUpTo > mustRedoThrough {
            mustRedoThrough = -1 // the last edit's lines are done: only this one's must be redone
        } else if mustRedoThrough > oldLineRange.upperBound {
            mustRedoThrough += shift
        }
        mustRedoThrough = max(mustRedoThrough, lastLineNow)
        validUpTo = min(validUpTo, firstLine)
    }

    /// Lines still to colour (0 when the whole file is done).
    var pendingLines: Int { states.count - validUpTo }

    /// Colours what is pending, within one time slice, then keeps going on later run-loop turns.
    func run() {
        guard let layoutManager else { return }
        let index = lines()
        guard index.count == states.count else {
            states = Array(repeating: nil, count: index.count)
            validUpTo = 0
            mustRedoThrough = index.count - 1
            return run()
        }
        let text = storage.string as NSString
        let deadline = Date().addingTimeInterval(Self.sliceBudget)
        while validUpTo < states.count {
            let line = validUpTo
            var range = index.range(ofLine: line)
            if range.length > 0, text.character(at: range.location + range.length - 1) == 0x0A { range.length -= 1 }
            let before = line > 0 ? states[line - 1] : nil
            guard let (tokens, state) = engine.tokenize(line: text.substring(with: range), language: language, after: before) else {
                validUpTo = states.count // the grammar failed: leave the rest plain
                break
            }
            apply(tokens, at: range, in: layoutManager)
            let unchanged = line > mustRedoThrough && states[line].map { old in state.map { old.isEquivalent(to: $0) } ?? false } ?? false
            states[line] = state
            validUpTo = line + 1
            if unchanged {
                // Everything after ended the same way before: already right.
                validUpTo = states.firstIndex(where: { $0 == nil }) ?? states.count
            }
            if Date() > deadline { break }
        }
        if validUpTo < states.count { schedule() }
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.run()
        }
    }

    private func apply(_ tokens: [ThemedToken], at line: NSRange, in layoutManager: NSLayoutManager) {
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: line)
        for token in tokens {
            let length = (token.content as NSString).length
            guard length > 0, let color = engine.color(token.color) else { continue }
            let start = token.offset
            guard start >= 0, start + length <= line.length else { continue }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: NSRange(location: line.location + start, length: length))
        }
    }
}
