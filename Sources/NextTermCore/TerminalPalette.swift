import Foundation

/// Terminal colours of the user's own (Settings › Terminal › Colours, or an import): any of the 16 ANSI
/// colours, the text, the background, the cursor and the selection, as 0xRRGGBB. A colour left nil keeps
/// Next Term's own, so a source that sets only a few changes only those.
public struct TerminalPalette: Equatable, Codable, Sendable {
    /// Normal then bright: black, red, green, yellow, blue, magenta, cyan, white. Always 16 entries.
    public var ansi: [UInt32?]
    public var foreground: UInt32?
    public var background: UInt32?
    public var cursor: UInt32?
    public var selection: UInt32?
    /// Where the colours came from, as Settings names them ("iTerm2, profile Default").
    public var name: String

    public init(name: String, ansi: [UInt32?] = Array(repeating: nil, count: 16), foreground: UInt32? = nil,
                background: UInt32? = nil, cursor: UInt32? = nil, selection: UInt32? = nil) {
        self.name = name
        var colours: [UInt32?] = Array(ansi.prefix(16))
        while colours.count < 16 { colours.append(nil) }
        self.ansi = colours.map { colour in colour.map { $0 & 0xFFFFFF } }
        self.foreground = foreground.map { $0 & 0xFFFFFF }
        self.background = background.map { $0 & 0xFFFFFF }
        self.cursor = cursor.map { $0 & 0xFFFFFF }
        self.selection = selection.map { $0 & 0xFFFFFF }
    }

    /// How many of the 20 colours it sets.
    public var count: Int {
        let others = [foreground, background, cursor, selection]
        return ansi.compactMap { $0 }.count + others.compactMap { $0 }.count
    }

    public var isEmpty: Bool { count == 0 }

    /// The ANSI names in order, as VS Code and Warp spell them (lowercased).
    public static let ansiNames = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]

    // MARK: storing

    /// As saved in UserDefaults.
    public var data: Data? { try? JSONEncoder().encode(self) }

    /// A saved palette, checked: 16 ANSI entries, colours within 24 bits, a short name. Nil for anything else,
    /// so a damaged value falls back to Next Term's colours.
    public static func decode(_ data: Data) -> TerminalPalette? {
        guard let palette = try? JSONDecoder().decode(TerminalPalette.self, from: data), palette.ansi.count == 16,
              palette.name.count <= 200 else { return nil }
        var colours: [UInt32] = palette.ansi.compactMap { $0 }
        colours += [palette.foreground, palette.background, palette.cursor, palette.selection].compactMap { $0 }
        return colours.allSatisfy { $0 <= 0xFFFFFF } ? palette : nil
    }

    // MARK: reading colours

    /// "#1e1f22", "1e1f22", "#abc", or with alpha "#1e1f2280" / "#abcd" (CSS order: alpha last). Returns the
    /// colour and its alpha (1 when there is none); nil for anything else.
    public static func hex(_ text: String) -> (rgb: UInt32, alpha: Double)? {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        switch digits.count {
        case 3, 4:
            let shift: UInt32 = digits.count == 4 ? 4 : 0
            let r: UInt32 = ((value >> (8 + shift)) & 0xF) * 17
            let g: UInt32 = ((value >> (4 + shift)) & 0xF) * 17
            let b: UInt32 = ((value >> shift) & 0xF) * 17
            let alpha = digits.count == 4 ? Double(value & 0xF) / 15 : 1
            return ((r << 16) | (g << 8) | b, alpha)
        case 8:
            return (value >> 8, Double(value & 0xFF) / 255)
        default:
            return (value, 1)
        }
    }

    /// Red, green and blue from 0 to 1 (a plist's colour components) as 0xRRGGBB; nil when one is missing
    /// or out of range.
    public static func rgb(_ red: Double?, _ green: Double?, _ blue: Double?) -> UInt32? {
        guard let red, let green, let blue else { return nil }
        let parts = [red, green, blue]
        guard parts.allSatisfy({ $0.isFinite && $0 >= -0.001 && $0 <= 1.001 }) else { return nil }
        let bytes = parts.map { UInt32((min(1, max(0, $0)) * 255).rounded()) }
        return bytes[0] << 16 | bytes[1] << 8 | bytes[2]
    }

    /// `colour` at `alpha` laid over `base`: what a see-through selection looks like on the background.
    public static func blend(_ colour: UInt32, alpha: Double, over base: UInt32) -> UInt32 {
        let a = min(1, max(0, alpha))
        func channel(_ shift: UInt32) -> UInt32 {
            let top = Double((colour >> shift) & 0xFF), bottom = Double((base >> shift) & 0xFF)
            return UInt32((top * a + bottom * (1 - a)).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    /// "#1E1F22", for a preview row.
    public static func display(_ rgb: UInt32) -> String {
        "#" + String(format: "%06X", rgb & 0xFFFFFF)
    }
}
