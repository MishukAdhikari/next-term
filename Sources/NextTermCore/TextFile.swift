import Foundation

/// How a text file is stored on disk, so saving writes it back byte for byte the same way.
public struct TextFormat: Equatable, Sendable {
    public enum Encoding: Equatable, Sendable { case utf8, utf8BOM, utf16LE, utf16BE }
    public enum LineEnding: String, Equatable, Sendable {
        case lf = "\n", crlf = "\r\n"
    }

    public var encoding: Encoding
    /// The whole file uses this line ending: the editor works with "\n" and saving restores it.
    /// nil: mixed or old Mac ("\r") line endings, kept exactly as they are.
    public var lineEnding: LineEnding?

    public init(encoding: Encoding = .utf8, lineEnding: LineEnding? = .lf) {
        self.encoding = encoding
        self.lineEnding = lineEnding
    }

    /// Another copy of the file (the last commit's) as the editor holds this one: with "\n" line endings
    /// when this file uses "\r\n" throughout. Lines are counted the same either way.
    public func editorText(_ stored: String) -> String {
        lineEnding == .crlf ? stored.replacingOccurrences(of: "\r\n", with: "\n") : stored
    }
}

/// Reading and writing source files for the editor.
public enum TextFile {
    /// A NUL byte this early means a binary file (as git and grep decide).
    public static let sniffLength = 8000
    /// Bigger than this opens elsewhere: an editor is the wrong tool for a 50 MB log.
    public static let maxEditableSize = 32 * 1024 * 1024

    /// The text (with "\n" line endings when the file uses one style throughout) and how to save it,
    /// or nil for a binary file or an encoding other than UTF-8 and UTF-16 with a BOM.
    public static func decode(_ data: Data) -> (text: String, format: TextFormat)? {
        var format = TextFormat()
        let raw: String?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            format.encoding = .utf8BOM
            raw = String(data: data.dropFirst(3), encoding: .utf8)
        } else if data.starts(with: [0xFF, 0xFE]) {
            format.encoding = .utf16LE
            raw = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            format.encoding = .utf16BE
            raw = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            if data.prefix(sniffLength).contains(0) { return nil }
            raw = String(data: data, encoding: .utf8) // nil unless valid UTF-8
        }
        guard let raw else { return nil }

        var crlf = 0, lf = 0, cr = 0
        var previousWasCR = false
        for byte in raw.utf8 {
            switch byte {
            case 0x0A:
                if previousWasCR { crlf += 1; cr -= 1 } else { lf += 1 }
                previousWasCR = false
            case 0x0D:
                cr += 1
                previousWasCR = true
            default:
                previousWasCR = false
            }
        }
        if cr > 0 || (crlf > 0 && lf > 0) {
            format.lineEnding = nil
            return (raw, format)
        }
        if crlf > 0 {
            format.lineEnding = .crlf
            return (raw.replacingOccurrences(of: "\r\n", with: "\n"), format)
        }
        format.lineEnding = .lf
        return (raw, format)
    }

    /// The bytes to write for `text` in `format`.
    public static func encode(_ text: String, as format: TextFormat) -> Data {
        var body = text
        if format.lineEnding == .crlf {
            // Normalise first, so a pasted "\r\n" does not become "\r\r\n".
            body = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        }
        switch format.encoding {
        case .utf8: return Data(body.utf8)
        case .utf8BOM: return Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)
        case .utf16LE: return Data([0xFF, 0xFE]) + (body.data(using: .utf16LittleEndian) ?? Data())
        case .utf16BE: return Data([0xFE, 0xFF]) + (body.data(using: .utf16BigEndian) ?? Data())
        }
    }

    /// Writes atomically to the file a path points at (through symlinks, so a link stays a link) and
    /// keeps its permissions, so a script stays executable.
    public static func write(_ data: Data, to url: URL) throws {
        let target = URL(fileURLWithPath: canonicalPath(url.path))
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try data.write(to: target, options: .atomic)
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
    }
}

/// Identifies one version of a file on disk, to notice when something else (an agent, git) changes it.
public struct FileStamp: Equatable, Sendable {
    public let seconds: Int
    public let nanoseconds: Int
    public let size: Int64
    public let inode: UInt64

    public init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        seconds = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
        size = info.st_size
        inode = info.st_ino
    }
}

/// Where each line starts, as UTF-16 offsets (the positions NSString and NSTextView use), kept up to
/// date edit by edit. A line ends after "\n".
public struct LineIndex: Equatable, Sendable {
    /// Offset of the first character of each line; the first is always 0.
    public private(set) var starts: [Int] = [0]
    public private(set) var length = 0

    public init(_ text: String = "") {
        replace(NSRange(location: 0, length: 0), with: text)
    }

    public var count: Int { starts.count }

    /// The 0-based line holding `offset` (the last line for the end of the text).
    public func line(at offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The line's characters including its "\n".
    public func range(ofLine line: Int) -> NSRange {
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] : length
        return NSRange(location: start, length: end - start)
    }

    /// Updates the index after the characters in `range` were replaced by `replacement`.
    public mutating func replace(_ range: NSRange, with replacement: String) {
        let added = (replacement as NSString).length
        let delta = added - range.length
        let end = range.location + range.length
        // Starts that followed a "\n" inside the replaced range go; later ones move.
        let first = line(at: range.location) + 1
        let firstAfter = line(at: end) + 1
        var inserted: [Int] = []
        let units = Array(replacement.utf16)
        for (i, unit) in units.enumerated() where unit == 0x0A { inserted.append(range.location + i + 1) }
        let moved = starts[firstAfter...].map { $0 + delta }
        starts.replaceSubrange(first..., with: inserted + moved)
        length += delta
    }
}
