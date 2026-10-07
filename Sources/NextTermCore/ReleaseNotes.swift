import Foundation

/// A release's notes (GitHub-flavoured Markdown) as blocks the update window lays out itself. Inline
/// Markdown (bold, code, links) is left in each block's text for the window to render.
public enum ReleaseNotes {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        /// `depth` 0 is a top-level item; nested items are indented one step per level.
        case bullet(depth: Int, text: String)
        case numbered(depth: Int, number: String, text: String)
        /// A paragraph, indented to sit under a list item when `depth` > 0.
        case paragraph(depth: Int, text: String)
        case code(String)
    }

    /// Sections about getting the app (how to install a disk image, how to update from an older
    /// version) are for the release page; someone reading them in the app already has it.
    public static let pageOnlySections: Set<String> = ["install", "installation", "update", "updating", "download", "downloads"]

    /// `keepingEverySection` keeps what only belongs on a release page (install sections, the changelog
    /// link), for Markdown that is not release notes, such as a notebook's.
    public static func blocks(_ markdown: String, keepingEverySection: Bool = false) -> [Block] {
        var blocks: [Block] = []
        var skippingBelow: Int? // inside a dropped section: until a heading at this level or higher
        var fence: [String]?
        var open: Block? // a paragraph or list item that a following line can continue

        func flush() {
            if let block = open { blocks.append(block) }
            open = nil
        }

        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for raw in lines {
            let line = String(raw).replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let lines = fence {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    if skippingBelow == nil { blocks.append(.code(lines.joined(separator: "\n"))) }
                    fence = nil
                } else {
                    fence = lines + [line]
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                fence = []
                continue
            }
            if let (level, text) = heading(trimmed) {
                flush()
                if let below = skippingBelow, level > below { continue }
                skippingBelow = nil
                if !keepingEverySection, pageOnlySections.contains(text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":.!").union(.whitespaces))) {
                    skippingBelow = level
                    continue
                }
                blocks.append(.heading(level: level, text: text))
                continue
            }
            if skippingBelow != nil { continue }
            if trimmed.isEmpty || isRule(trimmed) || trimmed.hasPrefix("<!--") || (!keepingEverySection && trimmed.hasPrefix("**Full Changelog**")) {
                flush()
                continue
            }
            let indent = line.prefix { $0 == " " }.count
            let depth = min(3, indent / 2)
            if let text = bulletText(trimmed) {
                flush()
                open = .bullet(depth: depth, text: text)
            } else if let (number, text) = numberedText(trimmed) {
                flush()
                open = .numbered(depth: depth, number: number, text: text)
            } else if let block = open {
                // A line that carries on the paragraph or item above it.
                switch block {
                case let .bullet(d, text): open = .bullet(depth: d, text: text + " " + trimmed)
                case let .numbered(d, n, text): open = .numbered(depth: d, number: n, text: text + " " + trimmed)
                case let .paragraph(d, text): open = .paragraph(depth: d, text: text + " " + trimmed)
                default: break
                }
            } else {
                // After a list, an indented paragraph belongs to the item above it.
                let underItem: Bool
                switch blocks.last {
                case .bullet, .numbered: underItem = indent >= 2
                default: underItem = false
                }
                open = .paragraph(depth: underItem ? max(1, depth) : 0, text: trimmed)
            }
        }
        if let lines = fence, skippingBelow == nil { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        var text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func bulletText(_ line: String) -> String? {
        guard let first = line.first, "-*+".contains(first), line.dropFirst().first == " " else { return nil }
        let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func numberedText(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return (String(digits), rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let chars = line.filter { $0 != " " }
        return chars.count >= 3 && (Set(chars) == ["-"] || Set(chars) == ["*"] || Set(chars) == ["_"])
    }
}
