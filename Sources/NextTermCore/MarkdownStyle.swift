import Foundation

/// The markers a Markdown file already uses, so a formatting command writes the same ones: `**` or `__` for bold, `*`
/// or `_` for italic, `-`, `*` or `+` for a bullet, `.` or `)` after a number. Read from the start of the file. Without
/// any, `**`, `_`, `-` and `.`, which is what common formatters write, so a project's formatter never changes them back.
public struct MarkdownStyle: Equatable, Sendable {
    public var strong = "**"
    public var emphasis = "_"
    public var bullet = "-"
    public var orderedDelimiter = "."

    public init(strong: String = "**", emphasis: String = "_", bullet: String = "-", orderedDelimiter: String = ".") {
        self.strong = strong
        self.emphasis = emphasis
        self.bullet = bullet
        self.orderedDelimiter = orderedDelimiter
    }

    public static let standard = MarkdownStyle()
    /// How much of the file is read.
    public static let detectLength = 64 * 1024

    /// The markers the first 64 KB use most; a tie keeps the standard one.
    public static func detect(in text: String) -> MarkdownStyle {
        var source = text as NSString
        if source.length > detectLength {
            // Up to the last whole line in it.
            let cut = source.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: detectLength))
            source = source.substring(to: cut.location == NSNotFound ? detectLength : cut.location + 1) as NSString
        }
        let index = LineIndex(source as String)
        var strong: [UInt16: Int] = [:], emphasis: [UInt16: Int] = [:], bullets: [UInt16: Int] = [:], ordered: [UInt16: Int] = [:]
        var state = MarkdownSyntax.LineState()
        for number in 0..<index.count {
            let range = index.range(ofLine: number)
            let read = MarkdownSyntax.scan(source, range: range, after: state)
            state = read.state
            let line = read.line
            for span in line.spans where span.range.location > 0 && (span.style.contains(.strong) || span.style.contains(.emphasis)) {
                let marker = source.character(at: range.location + span.range.location - 1)
                guard marker == 0x2A || marker == 0x5F else { continue }
                if span.style.contains(.strong) { strong[marker, default: 0] += 1 } else { emphasis[marker, default: 0] += 1 }
            }
            if let item = line.item {
                if item.isOrdered { ordered[item.delimiter, default: 0] += 1 } else { bullets[item.delimiter, default: 0] += 1 }
            }
        }
        func most(_ counts: [UInt16: Int], _ standard: String, _ length: Int = 1) -> String {
            let standardUnit = standard.utf16.first ?? 0
            guard let top = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $1.key == standardUnit) }),
                  top.value > counts[standardUnit, default: 0] else { return standard }
            return String(repeating: String(decoding: [top.key], as: UTF16.self), count: length)
        }
        return MarkdownStyle(strong: most(strong, "**", 2), emphasis: most(emphasis, "_"), bullet: most(bullets, "-"),
                             orderedDelimiter: most(ordered, "."))
    }
}
