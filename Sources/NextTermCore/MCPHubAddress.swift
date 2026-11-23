import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Where a remote MCP server may be (MCPHubRemote), the one rule its URL (MCPHubRules.urlReason), the addresses its
/// name resolves to, and the address Next Term connected to are all checked against:
///
/// - **This Mac** (localhost, 127.x, ::1): http or https, and the name must resolve to loopback addresses only.
/// - **https with a domain name**: the internet, or the user's own network (RFC 1918, unique-local, carrier-grade NAT,
///   Tailscale's 100.64/10 among it), as the user sets it up: their own domain, a Cloudflare Tunnel, or Tailscale.
///   TLS is what makes a private address safe: the system's own certificate check, which Next Term never bypasses
///   (no trust or challenge handling of its own), so a name rebound into the user's network can't be answered by
///   anything without a certificate for that very name, and the key never reaches it.
/// - **http beyond this Mac**: only to a Tailscale MagicDNS name (`machine.tailnet.ts.net`) whose every address is
///   Tailscale's (100.64.0.0/10, fd7a:115c:a1e0::/48), which WireGuard encrypts end to end. Any other http is refused.
/// - **Never**: link-local (169.254/16, fe80::/10, cloud metadata among it), this network (0/8, ::), multicast,
///   reserved and documentation blocks; nor a name other than this Mac's that resolves to loopback. An IPv4 address
///   inside IPv6 counts as that IPv4 address.
/// - **IP literals** other than this Mac's: a public one over https only, a private one never (no certificate can be
///   checked for it in practice): the refusal says to use the server's own domain over https.
/// - Rebinding: the address the connection actually used (`connected`, MCPHubRemote) is held to the same rule, and an
///   answer from one it breaks is thrown away.
public enum MCPHubAddress {
    public enum Kind: Equatable, Sendable {
        /// `private`: the user's own network (RFC 1918, unique-local, carrier-grade NAT); `never`: link-local, this
        /// network, multicast, reserved and documentation blocks, never a server's.
        case loopback, `private`, never, `public`
    }

    /// What a refusal recommends instead.
    public static let recommendation = "Use https with your own domain, a Cloudflare Tunnel, or a Tailscale name (machine.tailnet.ts.net)."

    /// An address's kind: IPv4 as 4 bytes, IPv6 as 16.
    public static func kind(_ bytes: [UInt8]) -> Kind {
        if bytes.count == 4 { return kind4(bytes) }
        guard bytes.count == 16 else { return .never }
        if bytes == [UInt8](repeating: 0, count: 15) + [1] { return .loopback }
        if bytes.allSatisfy({ $0 == 0 }) { return .never } // ::
        if let v4 = embedded4(bytes) { return kind4(v4) }
        if bytes[0] & 0xFE == 0xFC { return .private } // fc00::/7, unique local (Tailscale's fd7a:115c:a1e0::/48 among it)
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return .never } // fe80::/10, link-local
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return .never } // fec0::/10, site-local (deprecated)
        if bytes[0] == 0xFF { return .never } // multicast
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return .never } // 2001:db8::/32, documentation
        if bytes[0] & 0xE0 != 0x20 { return .never } // outside 2000::/3, the only global unicast block
        return .public
    }

    /// ::ffff:a.b.c.d (mapped), ::a.b.c.d (compatible) and 64:ff9b::a.b.c.d (NAT64) carry an IPv4 address.
    private static func embedded4(_ bytes: [UInt8]) -> [UInt8]? {
        let v4 = Array(bytes[12..<16])
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF { return v4 }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return v4 }
        if bytes[0..<12] == [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0] { return v4 }
        return nil
    }

    private static func kind4(_ b: [UInt8]) -> Kind {
        if b[0] == 127 { return .loopback }
        if b[0] == 0 || b[0] >= 224 { return .never } // this network, multicast and reserved
        if b[0] == 169, b[1] == 254 { return .never } // link-local, cloud metadata among it
        if b[0] == 192, b[1] == 0, b[2] == 0 || b[2] == 2 { return .never } // 192.0.0/24, 192.0.2/24
        if b[0] == 198, b[1] & 0xFE == 18 { return .never } // 198.18/15, benchmarking
        if b[0] == 198, b[1] == 51, b[2] == 100 { return .never }
        if b[0] == 203, b[1] == 0, b[2] == 113 { return .never }
        if b[0] == 10 { return .private }
        if b[0] == 100, b[1] & 0xC0 == 64 { return .private } // 100.64/10, carrier-grade NAT (Tailscale's among it)
        if b[0] == 172, b[1] & 0xF0 == 16 { return .private }
        if b[0] == 192, b[1] == 168 { return .private }
        return .public
    }

    /// Whether an address is Tailscale's: 100.64.0.0/10, or fd7a:115c:a1e0::/48 (an IPv4 inside IPv6 as that IPv4).
    public static func isTailscale(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 { return bytes[0] == 100 && bytes[1] & 0xC0 == 64 }
        guard bytes.count == 16 else { return false }
        if let v4 = embedded4(bytes) { return isTailscale(v4) }
        return bytes[0..<6] == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
    }

    /// Whether `host` is a Tailscale MagicDNS name: `machine.tailnet.ts.net`.
    public static func isTailscaleName(_ host: String) -> Bool {
        let name = bare(host)
        return name.hasSuffix(".ts.net") && name.count > ".ts.net".count && bytes(name) == nil
    }

    /// `host` lowercased, without brackets or a final dot.
    static func bare(_ host: String) -> String {
        var name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// Why a URL with `scheme` (https or http) and `host` can't be used, before any lookup, as the end of a sentence
    /// ("… is http:// to another machine"); nil when only its addresses are left to check.
    public static func hostReason(scheme: String, host: String) -> String? {
        let name = bare(host)
        if MCPHubRules.isThisMac(name) { return nil }
        let secure = scheme.lowercased() == "https"
        if let literal = bytes(name) {
            switch kind(literal) {
            case .loopback: return nil
            case .public: return secure ? nil : "is http:// to another machine, which would send what it is sent unencrypted. " + recommendation
            case .private, .never:
                return "names an address in a private network, where no certificate can be checked for it. "
                    + "Use the server\u{2019}s own domain over https, a Cloudflare Tunnel, or a Tailscale name (machine.tailnet.ts.net)."
            }
        }
        if secure || isTailscaleName(name) { return nil }
        return "is http:// to another machine, which would send what it is sent unencrypted. " + recommendation
    }

    /// Why a server at a URL with `scheme` and `host` can't be reached at these addresses (what its name resolved to,
    /// or the one connected to), as a sentence for the agent; nil when every one is allowed. The one rule: the URL's
    /// (`hostReason`), then each address's.
    public static func reason(scheme: String, host: String, addresses: [[UInt8]], name server: String) -> String? {
        if let why = hostReason(scheme: scheme, host: host) { return "\(server) can\u{2019}t be reached: its URL " + why }
        guard !addresses.isEmpty else { return "\(server) can\u{2019}t be reached: \(host) has no address." }
        let kinds = addresses.map(kind)
        if MCPHubRules.isThisMac(bare(host)) {
            if kinds.allSatisfy({ $0 == .loopback }) { return nil }
            return "\(server) can\u{2019}t be reached: \(host) should be this Mac, and it resolves to another machine."
        }
        if kinds.contains(.loopback) {
            return "\(server) can\u{2019}t be reached: \(host) resolves to this Mac. For a server on this Mac, use localhost."
        }
        if kinds.contains(.never) {
            return "\(server) can\u{2019}t be reached: \(host) resolves to a link-local or reserved address (cloud metadata among them), "
                + "which is never a server\u{2019}s."
        }
        if scheme.lowercased() == "https" { return nil }
        // http reaches this far only for a Tailscale name: every address must be Tailscale's.
        if addresses.allSatisfy(isTailscale) { return nil }
        return "\(server) can\u{2019}t be reached: \(host) is a Tailscale name that resolves outside Tailscale\u{2019}s addresses, "
            + "so http:// to it would leave the tailnet unencrypted. Use https, or check the name in Tailscale."
    }

    /// `reason(scheme:host:addresses:name:)` for a URL.
    public static func reason(url: URL, addresses: [[UInt8]], name server: String) -> String? {
        reason(scheme: url.scheme ?? "", host: url.host ?? "", addresses: addresses, name: server)
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
