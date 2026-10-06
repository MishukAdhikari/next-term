import Foundation

/// A local server's address, as a dev server prints it: `http://localhost:5173/`, `http://127.0.0.1:2024`,
/// `http://0.0.0.0:8000` (shown as localhost, which is how to reach it), `http://[::1]:3000`. Only
/// loopback addresses: a network address or a remote host's URL is not "this tab serves".
public enum ServedURL {
    public static func find(in line: String) -> URL? {
        guard let match = line.firstMatch(of: #/(https?)://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):([0-9]{2,5})(/[^\s"'<>()\[\]{}`]*)?/#),
              let port = Int(match.3), (1...65535).contains(port) else { return nil }
        let host = match.2 == "0.0.0.0" ? "localhost" : String(match.2)
        var path = match.4.map(String.init) ?? ""
        // A sentence's full stop or comma is not part of the address.
        while let last = path.last, ".,;:!?".contains(last) { path.removeLast() }
        return URL(string: "\(match.1)://\(host):\(port)\(path)")
    }

    /// " · :5173": what a tab's title adds while it serves.
    public static func suffix(_ url: URL) -> String {
        url.port.map { " · :\($0)" } ?? ""
    }
}
