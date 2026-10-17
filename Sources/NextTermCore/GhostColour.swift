import Foundation

/// A suggestion's colour, from the terminal's own text and background: the text mixed halfway toward the background, then
/// moved away from the background until it reads against it at `floor` (3:1, or 4.5:1 under Increase Contrast, by WCAG's
/// contrast ratio). A fixed grey vanishes on some themes; this follows each one. Colours are 0xRRGGBB, sRGB.
public enum GhostColour {
    public static let floor = 3.0
    public static let increasedFloor = 4.5

    public static func derive(foreground: UInt32, background: UInt32, increaseContrast: Bool) -> UInt32 {
        let floor = increaseContrast ? increasedFloor : self.floor
        let muted = mix(foreground, background, 0.5)
        if contrast(muted, background) >= floor { return muted }
        // Toward the text, and past it toward white or black where the text itself is too close to the background.
        let away: UInt32 = luminance(background) < 0.5 ? 0xFFFFFF : 0x000000
        let towardText = closest(from: muted, to: foreground, background: background, floor: floor)
        if let towardText { return towardText }
        return closest(from: foreground, to: away, background: background, floor: floor) ?? away
    }

    /// The colour nearest `start` on the way to `end` that reads at `floor` against `background`; nil when even `end` doesn't.
    private static func closest(from start: UInt32, to end: UInt32, background: UInt32, floor: Double) -> UInt32? {
        guard contrast(end, background) >= floor else { return nil }
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let mid = (low + high) / 2
            if contrast(mix(end, start, mid), background) >= floor { high = mid } else { low = mid }
        }
        return mix(end, start, high)
    }

    /// `a` with `amount` of it, the rest `b`, channel by channel.
    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return UInt32((x * amount + y * (1 - amount)).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    /// WCAG's contrast ratio of two colours: 1 to 21.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// WCAG's relative luminance.
    static func luminance(_ colour: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let value = Double((colour >> shift) & 0xFF) / 255
            return value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }
}
