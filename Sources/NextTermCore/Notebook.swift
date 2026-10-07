import Foundation

/// A Jupyter notebook (`.ipynb`) read for display: its cells, their source, and what they showed the
/// last time they ran. Nothing here runs code. Outputs are cut down for reading: long text keeps its
/// first and last lines, and images stay base64 until they are drawn.
///
/// nbformat 4 is the format Jupyter has written since 2015; nbformat 3 (worksheets, `input`, `pyout`)
/// is read too.
public struct Notebook: Equatable, Sendable {
    /// Bigger than this is not read: such a notebook is mostly images and data.
    public static let maxFileSize = 50 * 1024 * 1024
    /// An output shows at most this many lines: its first ones, and its last `tailLines`.
    public static let maxOutputLines = 200
    public static let tailLines = 40
    /// A longer output line is cut (a printed list of a million numbers is one line).
    public static let maxLineLength = 5_000

    public var cells: [Cell]
    /// The kernel's language id, lowercased (`python`, `r`, `julia`, `typescript`); nil when the notebook
    /// does not say.
    public var language: String?
    /// The kernel as Jupyter names it ("Python 3 (ipykernel)").
    public var kernelName: String?
    /// The nbformat major version: 4, or 3 for old notebooks.
    public var format: Int

    public struct Cell: Equatable, Sendable {
        public enum Kind: String, Sendable { case code, markdown, raw }
        public var kind: Kind
        public var source: String
        /// The `n` in `In [n]:`; nil for a cell that never ran.
        public var executionCount: Int?
        public var outputs: [Output]

        public init(kind: Kind, source: String, executionCount: Int? = nil, outputs: [Output] = []) {
            self.kind = kind
            self.source = source
            self.executionCount = executionCount
            self.outputs = outputs
        }
    }

    public struct Output: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Printed text; stderr is shown tinted.
            case stream(stderr: Bool)
            /// The value of the cell's last line, shown as `Out[n]:`.
            case result(executionCount: Int?)
            /// `display()`, plots.
            case display
            /// An exception. The traceback is the content.
            case error(name: String, value: String)
        }
        public var kind: Kind
        public var content: Content

        public init(kind: Kind, content: Content) {
            self.kind = kind
            self.content = content
        }
    }

    /// What an output shows, picked from the formats it carries: an image, else Markdown, else plain text,
    /// else HTML with its tags taken out.
    public enum Content: Equatable, Sendable {
        case text(Excerpt)
        case markdown(String)
        case image(Image)
        /// Something only Jupyter can show (a widget, a plot made of scripts): its type and size.
        case unsupported(mime: String, bytes: Int)
    }

    /// Long text cut down for reading: the first lines, and the last ones when lines were left out
    /// between them.
    public struct Excerpt: Equatable, Sendable {
        public var head: String
        /// Lines left out after `head`.
        public var omittedLines: Int
        /// The last lines, after the ones left out ("" when nothing was left out).
        public var tail: String

        public init(head: String, omittedLines: Int = 0, tail: String = "") {
            self.head = head
            self.omittedLines = omittedLines
            self.tail = tail
        }

        /// What is shown, with nothing marking the cut.
        public var shown: String { omittedLines == 0 ? head : head + "\n" + tail }
    }

    public struct Image: Equatable, Sendable {
        /// image/png, image/jpeg or image/gif.
        public var mime: String
        public var base64: String
        /// From the image's own header; nil if it could not be read.
        public var pixelWidth: Int?
        public var pixelHeight: Int?
        /// The size the notebook asks for (Jupyter's width and height metadata, as for a retina plot).
        public var width: Int?
        public var height: Int?

        /// About how many bytes the image is, decoded.
        public var byteCount: Int { base64.utf8.count / 4 * 3 }

        /// The image's bytes. Decoded only when asked: most images are never scrolled to.
        public func data() -> Data? { Data(base64Encoded: base64, options: .ignoreUnknownCharacters) }
    }

    public enum ReadError: Error, Equatable, LocalizedError {
        case tooLarge(bytes: Int)
        case unreadable
        /// The parser's reason ("Unexpected end of file around line 12, column 1.").
        case invalidJSON(String)
        case notANotebook

        public var errorDescription: String? {
            switch self {
            case let .tooLarge(bytes):
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                let limit = ByteCountFormatter.string(fromByteCount: Int64(Notebook.maxFileSize), countStyle: .file)
                return "This notebook is \(size), too large to show here (the limit is \(limit))."
            case .unreadable:
                return "The file could not be read."
            case let .invalidJSON(reason):
                return "This file is not valid JSON, so it cannot be shown as a notebook. \(reason)"
            case .notANotebook:
                return "This file is JSON, but not a Jupyter notebook: it has no cells."
            }
        }
    }

    public init(cells: [Cell], language: String? = nil, kernelName: String? = nil, format: Int = 4) {
        self.cells = cells
        self.language = language
        self.kernelName = kernelName
        self.format = format
    }

    // MARK: reading

    /// A Jupyter notebook by its name.
    public static func isNotebook(_ path: String) -> Bool { (path as NSString).pathExtension.lowercased() == "ipynb" }

    /// Reads a notebook file. Slow for a large one (tens of megabytes of JSON): call it off the main thread.
    public static func read(contentsOf url: URL) throws -> Notebook {
        guard isRegularFile(url.path) else { throw ReadError.unreadable } // a named pipe would block forever
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maxFileSize else { throw ReadError.tooLarge(bytes: size) }
        guard let data = try? Data(contentsOf: url) else { throw ReadError.unreadable }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> Notebook {
        guard data.count <= maxFileSize else { throw ReadError.tooLarge(bytes: data.count) }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            throw ReadError.invalidJSON(reason)
        }
        guard let root = json as? [String: Any] else { throw ReadError.notANotebook }
        let metadata = root["metadata"] as? [String: Any] ?? [:]
        let kernelspec = metadata["kernelspec"] as? [String: Any]
        let languageInfo = metadata["language_info"] as? [String: Any]
        var language = (kernelspec?["language"] as? String) ?? (languageInfo?["name"] as? String) ?? (metadata["language"] as? String)
        let kernelName = (kernelspec?["display_name"] as? String) ?? (kernelspec?["name"] as? String)

        if let cells = root["cells"] as? [Any] {
            let format = (root["nbformat"] as? Int) ?? 4
            return Notebook(cells: cells.compactMap { ($0 as? [String: Any]).map(cell) }, language: languageID(language),
                            kernelName: kernelName, format: format)
        }
        // nbformat 3: cells sit in worksheets; code cells name their own language.
        if let worksheets = root["worksheets"] as? [Any] {
            let raw = worksheets.compactMap { ($0 as? [String: Any])?["cells"] as? [Any] }.joined().compactMap { $0 as? [String: Any] }
            if language == nil { language = raw.first { $0["cell_type"] as? String == "code" }?["language"] as? String }
            return Notebook(cells: raw.map(cellV3), language: languageID(language), kernelName: kernelName, format: 3)
        }
        throw ReadError.notANotebook
    }

    /// A kernel's language name as a grammar id: `Python3` → `python`, `C++17` → `cpp`.
    static func languageID(_ name: String?) -> String? {
        guard let id = name?.trimmingCharacters(in: .whitespaces).lowercased(), !id.isEmpty else { return nil }
        if id.hasPrefix("python") || id.hasPrefix("ipython") { return "python" }
        if id.hasPrefix("c++") { return "cpp" }
        return id
    }

    /// Source and output text are a string, or a list of strings that join into one.
    static func joined(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let parts = value as? [Any] { return parts.compactMap { $0 as? String }.joined() }
        return ""
    }

    /// Source as the view lays it out: a notebook written on Windows can carry "\r\n" inside its strings.
    private static func source(_ value: Any?) -> String {
        let text = joined(value)
        return text.contains("\r") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
    }

    private static func cell(_ json: [String: Any]) -> Cell {
        let text = source(json["source"])
        switch json["cell_type"] as? String {
        case "code":
            let outputs = (json["outputs"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            return Cell(kind: .code, source: text, executionCount: json["execution_count"] as? Int, outputs: Self.outputs(outputs, version: 4))
        case "markdown":
            return Cell(kind: .markdown, source: text)
        default:
            return Cell(kind: .raw, source: text)
        }
    }

    private static func cellV3(_ json: [String: Any]) -> Cell {
        switch json["cell_type"] as? String {
        case "code":
            let outputs = (json["outputs"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            return Cell(kind: .code, source: source(json["input"]), executionCount: json["prompt_number"] as? Int,
                        outputs: Self.outputs(outputs, version: 3))
        case "markdown":
            return Cell(kind: .markdown, source: source(json["source"]))
        case "heading":
            let level = min(6, max(1, json["level"] as? Int ?? 1))
            return Cell(kind: .markdown, source: String(repeating: "#", count: level) + " " + source(json["source"]))
        default:
            return Cell(kind: .raw, source: source(json["source"]))
        }
    }

    /// nbformat 3 kept each format under a short key next to the output's type.
    private static let v3Formats: [String: String] = [
        "png": "image/png", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml", "text": "text/plain",
        "html": "text/html", "latex": "text/latex", "markdown": "text/markdown", "json": "application/json",
        "javascript": "application/javascript",
    ]

    private static func outputs(_ list: [[String: Any]], version: Int) -> [Output] {
        var outputs: [Output] = []
        // Jupyter shows consecutive prints to the same stream as one block.
        var stream: (stderr: Bool, text: String)?
        func flushStream() {
            if let pending = stream { outputs.append(Output(kind: .stream(stderr: pending.stderr), content: .text(excerpt(pending.text)))) }
            stream = nil
        }
        for json in list {
            let type = json["output_type"] as? String ?? ""
            if type == "stream" {
                let stderr = (json[version == 3 ? "stream" : "name"] as? String) == "stderr"
                let text = joined(json["text"])
                if let pending = stream, pending.stderr == stderr {
                    stream = (stderr, pending.text + text)
                } else {
                    flushStream()
                    stream = (stderr, text)
                }
                continue
            }
            flushStream()
            switch type {
            case "execute_result", "pyout":
                let count = json[version == 3 ? "prompt_number" : "execution_count"] as? Int
                outputs.append(Output(kind: .result(executionCount: count), content: content(of: json, version: version)))
            case "display_data", "update_display_data":
                outputs.append(Output(kind: .display, content: content(of: json, version: version)))
            case "error", "pyerr":
                let name = stripANSI(json["ename"] as? String ?? "Error")
                let value = stripANSI(json["evalue"] as? String ?? "")
                let traceback = (json["traceback"] as? [Any] ?? []).compactMap { $0 as? String }.joined(separator: "\n")
                let text = traceback.isEmpty ? (value.isEmpty ? name : "\(name): \(value)") : traceback
                outputs.append(Output(kind: .error(name: name, value: value), content: .text(excerpt(text))))
            default:
                continue
            }
        }
        flushStream()
        return outputs
    }

    /// The best of the formats an output carries, for a viewer that draws images and text but runs nothing.
    private static func content(of json: [String: Any], version: Int) -> Content {
        var data: [String: Any] = [:]
        var metadata: [String: Any] = [:]
        if version == 3 {
            for (key, mime) in v3Formats { if let value = json[key] { data[mime] = value } }
            metadata = json["metadata"] as? [String: Any] ?? [:]
        } else {
            data = json["data"] as? [String: Any] ?? [:]
            metadata = json["metadata"] as? [String: Any] ?? [:]
        }
        for mime in ["image/png", "image/jpeg", "image/gif"] {
            guard let encoded = data[mime].map(joined), !encoded.isEmpty else { continue }
            var image = Image(mime: mime, base64: encoded)
            if let size = pixelSize(ofBase64: encoded) { (image.pixelWidth, image.pixelHeight) = size }
            let sizing = (metadata[mime] as? [String: Any]) ?? metadata
            image.width = (sizing["width"] as? NSNumber)?.intValue
            image.height = (sizing["height"] as? NSNumber)?.intValue
            return .image(image)
        }
        if let markdown = data["text/markdown"].map(joined), !markdown.isEmpty { return .markdown(markdown) }
        for mime in ["text/plain", "text/latex"] {
            if let text = data[mime].map(joined), !text.isEmpty { return .text(excerpt(text)) }
        }
        if let html = data["text/html"].map(joined) {
            let text = textOfHTML(html)
            if !text.isEmpty { return .text(excerpt(text)) }
        }
        if let json = data["application/json"], JSONSerialization.isValidJSONObject(json),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            return .text(excerpt(String(decoding: pretty, as: UTF8.self)))
        }
        // Nothing this viewer can show: name the largest format, as the notebook's weight.
        let sizes = data.map { mime, value -> (String, Int) in
            let bytes = (value as? String).map { $0.utf8.count } ?? (value as? [Any]).map { joined($0).utf8.count }
                ?? ((try? JSONSerialization.data(withJSONObject: value)).map(\.count) ?? 0)
            return (mime, bytes)
        }
        let largest = sizes.max { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0 > $1.0) }
        return .unsupported(mime: largest?.0 ?? "unknown", bytes: largest?.1 ?? 0)
    }

    // MARK: text

    /// The first `maxOutputLines` lines (the first ones and the last `tailLines`), each as a terminal
    /// would leave it: colours stripped, a progress bar's `\r` redraws collapsed to the last one, and very
    /// long lines cut.
    public static func excerpt(_ text: String) -> Excerpt {
        // "\r\n" is one Character to Swift: as two, it splits like any other line end.
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() } // the final newline
        func clean<S: Sequence>(_ part: S) -> String where S.Element == Substring { part.map(cleanLine).joined(separator: "\n") }
        guard lines.count > maxOutputLines else { return Excerpt(head: clean(lines)) }
        let headCount = maxOutputLines - tailLines
        return Excerpt(head: clean(lines.prefix(headCount)), omittedLines: lines.count - maxOutputLines, tail: clean(lines.suffix(tailLines)))
    }

    private static func cleanLine(_ raw: Substring) -> String {
        var line = raw
        if line.contains("\r") {
            // `\r` returns to the start of the line: what shows is the last redraw (tqdm, pip).
            let redraws = line.split(separator: "\r", omittingEmptySubsequences: false)
            line = redraws.last { !$0.isEmpty } ?? ""
        }
        var text = stripANSI(String(line))
        if text.utf16.count > maxLineLength { text = String(text.prefix(maxLineLength)) + " …" }
        return text
    }

    /// Text without its terminal escape codes: colours (`ESC[0;31m`), titles and links (`ESC]…BEL`), and
    /// character-set switches. IPython colours every traceback this way.
    public static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "\u{1B}" else {
                out.append(scalars[i])
                i += 1
                continue
            }
            i += 1
            guard i < scalars.count else { break }
            switch scalars[i] {
            case "[": // CSI: parameters, then one final byte from @ to ~
                i += 1
                while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) { i += 1 }
                i += 1
            case "]": // OSC: up to BEL or ESC \
                i += 1
                while i < scalars.count, scalars[i] != "\u{07}", scalars[i] != "\u{1B}" { i += 1 }
                i += i < scalars.count && scalars[i] == "\u{1B}" ? 2 : 1
            case "(", ")", "*", "+", "-", ".", "/": // ESC ( B and friends
                i += 2
            default:
                i += 1
            }
        }
        return String(out)
    }

    /// An HTML output as readable text: no scripts or styles, a line per block, cells apart, the common
    /// entities decoded. For outputs that carry nothing better (a styled message, a table).
    public static func textOfHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)\b.*?</\1\s*>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?is)<!--.*?-->"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</(p|div|tr|li|h[1-6]|table|thead|tbody|pre)\s*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</t[dh]\s*>"#, with: "\t", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)<[^>]*>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Runs of blank lines (from nested blocks) collapse to one.
        var kept: [String] = []
        for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) { kept.append(line) }
        while kept.last?.isEmpty == true { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    // MARK: images

    /// Width and height from a base64 PNG, GIF or JPEG, decoding only the start of it.
    public static func pixelSize(ofBase64 base64: String) -> (Int, Int)? {
        // A PNG or GIF says it in its first 24 bytes; a JPEG's frame header can come after its metadata.
        for length in [32, 65_536] {
            var chunk = String.UnicodeScalarView()
            var count = 0
            for scalar in base64.unicodeScalars where !(scalar == "\n" || scalar == "\r" || scalar == " " || scalar == "\t") {
                chunk.append(scalar)
                count += 1
                if count == length { break }
            }
            let usable = String(String(chunk).prefix(count / 4 * 4))
            guard let bytes = Data(base64Encoded: usable).map([UInt8].init) else { return nil }
            if let size = pixelSize(of: bytes) { return size }
            if count < length { break } // that was all of it
        }
        return nil
    }

    static func pixelSize(of b: [UInt8]) -> (Int, Int)? {
        func be16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func be32(_ i: Int) -> Int { be16(i) << 16 | be16(i + 2) }
        if b.count >= 24, b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return (be32(16), be32(20)) }
        if b.count >= 10, b.starts(with: Array("GIF8".utf8)) { return (Int(b[6]) | Int(b[7]) << 8, Int(b[8]) | Int(b[9]) << 8) }
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 9 < b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue } // fill byte
            // Start of frame (baseline, progressive…), but not the Huffman, arithmetic or JPEG-LS tables.
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) { return (be16(i + 7), be16(i + 5)) }
            i += 2 + be16(i + 2)
        }
        return nil
    }
}

// MARK: code cells

extension Notebook {
    /// The language a code cell is written in: the kernel's, unless an IPython cell magic on its first line
    /// says otherwise (`%%bash`, `%%html`, `%%writefile app.js`). Only Python kernels have magics.
    public func language(of cell: Cell) -> String? {
        guard language == "python", cell.source.hasPrefix("%%") else { return language }
        let words = cell.source.prefix { $0 != "\n" }.dropFirst(2).split(separator: " ")
        guard var magic = words.first?.lowercased() else { return language }
        if magic == "script", words.count > 1 { magic = (String(words[1]) as NSString).lastPathComponent.lowercased() } // %%script bash
        if magic == "writefile" || magic == "file" {
            return words.count > 1 ? EditorLanguage.id(forFileName: String(words[words.count - 1])) : language
        }
        return Self.cellMagics[magic] ?? language
    }

    private static let cellMagics: [String: String] = [
        "bash": "shellscript", "sh": "shellscript", "zsh": "shellscript", "html": "html", "javascript": "javascript",
        "js": "javascript", "latex": "latex", "markdown": "markdown", "sql": "sql", "svg": "xml", "perl": "perl",
        "ruby": "ruby", "python": "python", "python3": "python",
    ]

    /// An IPython line magic or shell escape (`%pip install …`, `!ls`, `%%time`): Python's grammar does not
    /// know them, so they are coloured as shell. Returns how long the `%pip`/`!` part is, or nil.
    public static func magicPrefixLength(_ line: some StringProtocol) -> Int? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(indent)
        if rest.first == "!" { return indent + (rest.hasPrefix("!!") ? 2 : 1) }
        guard rest.first == "%" else { return nil }
        let name = rest.prefix { $0 == "%" }.count
        let word = rest.dropFirst(name).prefix { $0.isLetter || $0.isNumber || $0 == "_" }.count
        return word > 0 ? indent + name + word : nil
    }

    /// A Markdown cell as blocks to lay out: what the release-notes reader makes of Markdown (headings,
    /// lists, code, paragraphs), with every section kept and each table's columns lined up as text.
    public static func markdownBlocks(_ source: String) -> [ReleaseNotes.Block] {
        var blocks: [ReleaseNotes.Block] = []
        var pending: [Substring] = []
        var table: [Substring] = []
        var inFence = false
        func flushText() {
            if !pending.isEmpty { blocks += ReleaseNotes.blocks(pending.joined(separator: "\n"), keepingEverySection: true) }
            pending = []
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.code(alignedTable(table))) }
            table = []
        }
        for line in source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, trimmed.hasPrefix("|") {
                flushText()
                table.append(line)
            } else {
                flushTable()
                pending.append(line)
            }
        }
        flushTable()
        flushText()
        return blocks
    }

    /// A Markdown table with its columns padded to line up in a monospaced font; the `|---|` row becomes a rule.
    static func alignedTable(_ lines: [Substring]) -> String {
        func cells(_ line: Substring) -> [String] {
            var row = line.trimmingCharacters(in: .whitespaces)
            if row.hasPrefix("|") { row.removeFirst() }
            if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
            var cells: [String] = [], current = "", escaped = false
            for character in row {
                if escaped { current.append(character); escaped = false } else if character == "\\" { escaped = true } else if character == "|" {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(character)
                }
            }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }
        let rows = lines.map(cells)
        let isRule = rows.map { row in row.allSatisfy { cell in !cell.isEmpty && cell.allSatisfy { "-:".contains($0) } } }
        let columns = rows.map(\.count).max() ?? 0
        var widths = Array(repeating: 0, count: columns)
        for (row, rule) in zip(rows, isRule) where !rule {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
        }
        return zip(rows, isRule).map { row, rule in
            if rule { return widths.map { String(repeating: "─", count: $0) }.joined(separator: "──") }
            return row.enumerated().map { i, cell in i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
