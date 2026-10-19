import Foundation

/// A row of a terminal's screen as it shows: its text, and the background its cells are drawn on, in runs. Some agents
/// mark the choice they would take only by its background (OpenCode's row of buttons), which the text alone never says.
///
/// Colours are opaque numbers, only ever compared: a 24-bit colour as 0xRRGGBB, a 256-colour code as 0x1000000 + code,
/// the default background as `defaultColor`, and the default foreground (as a reversed cell shows it) as
/// `defaultForeground`.
public struct ScreenRow: Equatable, Sendable {
    /// `count` characters of the row's text from `start`, on one background.
    public struct BackgroundRun: Equatable, Sendable {
        public let start: Int
        public let count: Int
        public let color: Int

        public init(start: Int, count: Int, color: Int) {
            self.start = start
            self.count = count
            self.color = color
        }
    }

    public static let defaultColor = -1
    public static let defaultForeground = -2

    public static func trueColor(red: Int, green: Int, blue: Int) -> Int {
        let high: Int = (red & 0xFF) << 16
        let middle: Int = (green & 0xFF) << 8
        return high | middle | (blue & 0xFF)
    }

    public static func paletteColor(_ code: Int) -> Int {
        0x1000000 + (code & 0xFF)
    }

    /// The background a cell shows: its own, or its foreground when it is drawn reversed (SGR 7), as some themes draw
    /// a selection. Both as this type's numbers, a default foreground being `defaultForeground`.
    public static func background(_ background: Int, foreground: Int, reversed: Bool) -> Int {
        reversed ? foreground : background
    }

    public private(set) var text: String
    /// In the order of the text, none overlapping; a character in none is on the default background.
    public private(set) var backgrounds: [BackgroundRun]
    /// The text's length in characters, kept as it is built.
    private var length: Int

    public init(text: String = "", backgrounds: [BackgroundRun] = []) {
        self.text = text
        self.backgrounds = backgrounds
        length = text.count
    }

    /// Text alone, on the default background: where nothing can be told by colour.
    public init(_ text: String) {
        self.init(text: text)
    }

    /// `text` drawn one character per cell, `cells` the background of each. When a cell's character joins the one
    /// before it (so the text has fewer characters than cells), where each colour falls is unknown, and the row keeps
    /// no colours: what only a colour could tell stays untold.
    public init(text: String, cells: [Int]) {
        self.init(text: text)
        guard length == cells.count else { return }
        var runs: [BackgroundRun] = []
        for (offset, color) in cells.enumerated() {
            if let last = runs.last, last.color == color, last.start + last.count == offset {
                runs[runs.count - 1] = BackgroundRun(start: last.start, count: last.count + 1, color: color)
            } else {
                runs.append(BackgroundRun(start: offset, count: 1, color: color))
            }
        }
        backgrounds = runs
    }

    /// Adds `part` on `background`, joined to the last run when it has the same colour.
    public mutating func append(_ part: String, background: Int) {
        let added = part.count
        guard added > 0 else { return }
        text += part
        if let last = backgrounds.last, last.color == background, last.start + last.count == length {
            backgrounds[backgrounds.count - 1] = BackgroundRun(start: last.start, count: last.count + added, color: background)
        } else {
            backgrounds.append(BackgroundRun(start: length, count: added, color: background))
        }
        length += added
    }

    /// The background of the character at `offset`.
    public func background(at offset: Int) -> Int {
        let run = backgrounds.first { (run: BackgroundRun) -> Bool in offset >= run.start && offset < run.start + run.count }
        return run?.color ?? Self.defaultColor
    }
}

extension ScreenRow {
    /// Which of `labels`, drawn in this order on the row, shows selected by its background, as a person would tell:
    /// - three or more: the one whose background differs from the rest, when the rest share one;
    /// - two: the one on a background of its own while the other sits on the row's own, as drawn between them (past
    ///   the one cell of padding each button has).
    ///
    /// Nil whenever that is not plain: a label missing, a label's cells on more than one background, every label on one
    /// background, or more than two backgrounds among them. A selection never shown is never guessed.
    public func selected(among labels: [String]) -> Int? {
        guard labels.count >= 2, let spans = spans(of: labels) else { return nil }
        var colors: [Int] = []
        for span in spans {
            guard let color = uniformBackground(span) else { return nil }
            colors.append(color)
        }
        if labels.count >= 3 { return Self.oddOne(colors) }
        let after: Int = spans[0].upperBound + 1
        let before: Int = spans[1].lowerBound - 1
        guard after < before, let between = uniformBackground(after..<before) else { return nil }
        let own: [Int] = colors.indices.filter { (index: Int) -> Bool in colors[index] != between }
        return own.count == 1 ? own[0] : nil
    }

    /// Where each label is on the row, in characters, each found after the one before it; nil if one is not there.
    func spans(of labels: [String]) -> [Range<Int>]? {
        var spans: [Range<Int>] = []
        var from = text.startIndex
        var offset = 0
        for label in labels {
            guard !label.isEmpty, let found = text.range(of: label, range: from..<text.endIndex) else { return nil }
            let start: Int = offset + text.distance(from: from, to: found.lowerBound)
            let count: Int = label.count
            spans.append(start..<(start + count))
            from = found.upperBound
            offset = start + count
        }
        return spans
    }

    /// The one background every character in `span` is on; nil when they are on more than one.
    func uniformBackground(_ span: Range<Int>) -> Int? {
        let colors = Set(span.map { (offset: Int) -> Int in background(at: offset) })
        return colors.count == 1 ? colors.first : nil
    }

    /// The index of the one colour that differs, when all the others share one.
    static func oddOne(_ colors: [Int]) -> Int? {
        guard Set(colors).count == 2 else { return nil }
        let lone: [Int] = colors.indices.filter { (index: Int) -> Bool in
            colors.filter { (color: Int) -> Bool in color == colors[index] }.count == 1
        }
        return lone.count == 1 ? lone[0] : nil
    }
}
