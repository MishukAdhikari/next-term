import Foundation
import LocalAuthentication
import NextTermCore
import Security

/// Where Remote access keeps the Cloudflare tunnel token (R30, R44, KTD9). The token never goes anywhere else on disk:
/// not in preferences, a file or a log.
protocol RemoteAccessTokenStore: AnyObject, Sendable {
    /// The saved token. Silently, the read never shows a prompt: when macOS would ask (an update changed the app's
    /// signature, so the item's access list no longer names it), it fails with `needsPermission`, so a relaunch while
    /// the user is away never waits on a password dialog. Interactive, macOS may ask; it can block until the user
    /// answers, so it runs off the main thread.
    func read(interactive: Bool) -> Result<RemoteAccessTunnelConfig.Token, RemoteAccessTokenFailure>
    /// On paste, after the shape check. Replaces any saved token.
    func save(_ token: RemoteAccessTunnelConfig.Token) throws
    /// Remove Token. Nothing saved is no error.
    func remove() throws
    /// The saved token's tunnel id, all Settings shows of it, read without the token itself, so it never asks.
    var tunnelID: String? { get }
}

/// Why no token came back.
enum RemoteAccessTokenFailure: Error, Equatable {
    case missing
    case needsPermission
    case canceled
    case failed(String)

    /// What the status reducer is told.
    var read: RemoteAccessStatus.TokenRead {
        switch self {
        case .missing: return .missing
        case .needsPermission: return .needsPermission
        case .canceled: return .canceled
        case .failed(let reason): return .failed(reason)
        }
    }
}

/// A Keychain error, with macOS's own words for it. Never holds the token.
struct RemoteAccessKeychainError: Error, CustomStringConvertible {
    let status: OSStatus

    var description: String { RemoteAccessKeychain.message(status) }
}

/// The token as one generic password in the login keychain, under Next Term's own service name. Not
/// synchronizable, and with no data-protection keychain options: those need a team-signed app (KTD9). The tunnel
/// id goes in the item's comment, which can be read without the token.
final class RemoteAccessKeychain: RemoteAccessTokenStore {
    static let service = "Next Term Remote Access"
    static let account = "cloudflare-tunnel-token"
    static let unreadable = "The saved tunnel token is not a tunnel token. "
        + "Paste it again in Settings › Remote Access."

    /// The item, whatever it holds.
    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func read(interactive: Bool) -> Result<RemoteAccessTunnelConfig.Token, RemoteAccessTokenFailure> {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { query[kSecUseAuthenticationContext as String] = Self.silent() }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8),
                  case .success(let token) = RemoteAccessTunnelConfig.token(text) else {
                return .failure(.failed(Self.unreadable))
            }
            return .success(token)
        case errSecItemNotFound:
            return .failure(.missing)
        case errSecInteractionNotAllowed:
            return .failure(.needsPermission)
        case errSecUserCanceled, errSecAuthFailed:
            return .failure(interactive ? .canceled : .needsPermission)
        default:
            return .failure(.failed("The Keychain could not read the tunnel token: \(Self.message(status))"))
        }
    }

    func save(_ token: RemoteAccessTunnelConfig.Token) throws {
        let data = Data(token.value.utf8)
        let changes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrComment as String: token.tunnelID]
        var status = SecItemUpdate(item as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var added = item
            added[kSecValueData as String] = data
            added[kSecAttrComment as String] = token.tunnelID
            added[kSecAttrLabel as String] = Self.service
            added[kSecAttrDescription as String] = "Cloudflare tunnel token"
            added[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(added as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RemoteAccessKeychainError(status: status) }
    }

    func remove() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteAccessKeychainError(status: status)
        }
    }

    var tunnelID: String? {
        var query = item
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = Self.silent()
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrComment as String] as? String
    }

    /// A context that never shows UI: a read that would ask fails with `errSecInteractionNotAllowed` (R44; hand
    /// check H6 confirms it for a legacy-keychain item).
    private static func silent() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    static func message(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String?
        return text.map { "\($0) (\(status))" } ?? "error \(status)"
    }
}

/// The self-test's token store (KTD18): in memory, never the user's Keychain. It is used under `--self-test` in any
/// build, so no test run reads or writes the user's token.
final class RemoteAccessMemoryTokens: RemoteAccessTokenStore, @unchecked Sendable { // every field under `lock`
    private let lock = NSLock()
    private var saved: RemoteAccessTunnelConfig.Token?
    #if DEBUG
    private var failures: (silent: RemoteAccessTokenFailure?, every: RemoteAccessTokenFailure?)

    /// What the next reads give instead of the token, for the self-test's Keychain checks (U12): `silent` for the
    /// reads with the prompt suppressed only, `every` for every read. Nil for both reads the token again.
    func fail(silent: RemoteAccessTokenFailure?, every: RemoteAccessTokenFailure? = nil) {
        locked { failures = (silent, every) }
    }
    #endif

    func read(interactive: Bool) -> Result<RemoteAccessTunnelConfig.Token, RemoteAccessTokenFailure> {
        locked {
            #if DEBUG
            if let failure = failures.every { return .failure(failure) }
            if !interactive, let failure = failures.silent { return .failure(failure) }
            #endif
            guard let saved else { return .failure(.missing) }
            return .success(saved)
        }
    }

    func save(_ token: RemoteAccessTunnelConfig.Token) throws {
        locked { saved = token }
    }

    func remove() throws {
        locked { saved = nil }
    }

    var tunnelID: String? { locked { saved?.tunnelID } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
