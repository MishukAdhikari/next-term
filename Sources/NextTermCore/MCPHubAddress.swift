import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Where a remote MCP server may be (MCPHubRemote): on the internet, or on this Mac. Its URL's rules (https, or http to
/// this Mac only) are MCPHubRules'; these are the addresses its name resolves to, and the one Next Term connected to.
///
/// - A server named as this Mac (localhost, 127.x, ::1) must resolve to loopback addresses only.
/// - Any other name must resolve to public addresses only: no private, link-local, carrier-grade NAT, unique-local,
///   multicast or reserved one, an IPv4 address inside IPv6 counted as that IPv4 address. A URL that names such an
///   address itself is refused the same way, so a key is never sent into the user's own network on a URL's say.
/// - Rebinding: a name that resolved to a public address as it was checked and to a private one by the time it was
///   connected to is caught by the address the connection actually used (`connected`, MCPHubRemote), and its answer is thrown
///   away. With https, such a server would also need a certificate for the name, so the key never reaches it.
public enum MCPHubAddress {
    public enum Kind: Equatable, Sendable {
        case loopback, `private`, `public`
    }

    /// An address's kind: IPv4 as 4 bytes, IPv6 as 16.
    public static func kind(_ bytes: [UInt8]) -> Kind {
        if bytes.count == 4 { return kind4(bytes) }
        guard bytes.count == 16 else { return .private }
        if bytes == [UInt8](repeating: 0, count: 15) + [1] { return .loopback }
        if bytes.allSatisfy({ $0 == 0 }) { return .private } // ::
        // ::ffff:a.b.c.d (mapped), ::a.b.c.d (compatible) and 64:ff9b::a.b.c.d (NAT64) carry an IPv4 address.
        let v4 = Array(bytes[12..<16])
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF { return kind4(v4) }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return kind4(v4) }
        if bytes[0..<12] == [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0] { return kind4(v4) }
        if bytes[0] & 0xFE == 0xFC { return .private } // fc00::/7, unique local
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return .private } // fe80::/10, link-local
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return .private } // fec0::/10, site-local (deprecated)
        if bytes[0] == 0xFF { return .private } // multicast
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return .private } // 2001:db8::/32, documentation
        if bytes[0] & 0xE0 != 0x20 { return .private } // outside 2000::/3, the only global unicast block
        return .public
    }

    private static func kind4(_ b: [UInt8]) -> Kind {
        if b[0] == 127 { return .loopback }
        if b[0] == 0 || b[0] == 10 || b[0] >= 224 { return .private } // this network, private, multicast and reserved
        if b[0] == 100, b[1] & 0xC0 == 64 { return .private } // 100.64/10, carrier-grade NAT
        if b[0] == 169, b[1] == 254 { return .private } // link-local, cloud metadata among it
        if b[0] == 172, b[1] & 0xF0 == 16 { return .private }
        if b[0] == 192, b[1] == 168 { return .private }
        if b[0] == 192, b[1] == 0, b[2] == 0 || b[2] == 2 { return .private } // 192.0.0/24, 192.0.2/24
        if b[0] == 198, b[1] & 0xFE == 18 { return .private } // 198.18/15, benchmarking
        if b[0] == 198, b[1] == 51, b[2] == 100 { return .private }
        if b[0] == 203, b[1] == 0, b[2] == 113 { return .private }
        return .public
    }

    /// An address in text (1.2.3.4, ::1, [::1]), as bytes; nil when it isn't one.
    public static func bytes(_ text: String) -> [UInt8]? {
        let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, bare, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    /// Why a server at `host` can't be reached at these addresses (what its name resolved to, or the one connected to),
    /// as a sentence for the agent; nil when every one is allowed.
    public static func reason(host: String, addresses: [[UInt8]], name server: String) -> String? {
        guard !addresses.isEmpty else { return "\(server) can't be reached: \(host) has no address." }
        let kinds = addresses.map(kind)
        if MCPHubRules.isThisMac(host.lowercased()) {
            if kinds.allSatisfy({ $0 == .loopback }) { return nil }
            return "\(server) can't be reached: \(host) should be this Mac, and it resolves to another machine."
        }
        if kinds.allSatisfy({ $0 == .public }) { return nil }
        return "\(server) can't be reached: \(host) is an address in a private network (or resolves to one), and Next Term "
            + "reaches servers on the internet or on this Mac only, so a key is never sent into a network on a URL's say."
    }

    /// The addresses `host` resolves to, within `deadline`; nil when the lookup didn't end in time.
    public static func resolve(_ host: String, until deadline: Date) -> [[UInt8]]? {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let literal = bytes(bare) { return [literal] }
        final class Box: @unchecked Sendable { var found: [[UInt8]] = [] }
        let box = Box(), done = DispatchSemaphore(value: 0)
        // getaddrinfo has no timeout of its own: it runs on a thread of its own, and a lookup past the deadline is left to end.
        Thread {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(bare, nil, &hints, &list) == 0 {
                var node = list
                while let entry = node?.pointee {
                    if let address = entry.ai_addr { box.found.append(contentsOf: bytes(of: address).map { [$0] } ?? []) }
                    node = entry.ai_next
                }
                freeaddrinfo(list)
            }
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else { return nil }
        return box.found
    }

    static func bytes(of address: UnsafePointer<sockaddr>) -> [UInt8]? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var value = pointer.pointee.sin_addr
                return withUnsafeBytes(of: &value) { Array($0) }
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                var value = pointer.pointee.sin6_addr
                return withUnsafeBytes(of: &value) { Array($0) }
            }
        default: return nil
        }
    }

    /// The address a connection used, as URLSession's metrics give it ("1.2.3.4", "::1", sometimes with a %zone), as
    /// bytes; nil when it can't be read.
    public static func connected(_ text: String?) -> [UInt8]? {
        guard let text else { return nil }
        return bytes(String(text.split(separator: "%").first ?? ""))
    }
}
