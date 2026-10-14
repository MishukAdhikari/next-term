import Foundation
import Security

/// Who signed an app, as the install script checks it with `codesign -R`.
public struct CodeSignature: Equatable, Sendable {
    /// The designated requirement, as text: a team's id and the bundle id when a team signs it, the bundle
    /// id and the certificate's hash when a certificate with no team signs it (the self-signed release
    /// identity, docs/signing.md), or the code's own hashes when it is signed ad hoc.
    public var requirement: String
    /// The team that signed it; none when it is signed ad hoc or with a self-signed certificate.
    public var team: String?
    /// Signed ad hoc, with no certificate: its requirement names this one build and no signer.
    public var adHoc: Bool

    public init(requirement: String, team: String?, adHoc: Bool) {
        self.requirement = requirement
        self.team = team
        self.adHoc = adHoc
    }

    /// The signature of the app at `url`; nil when it is not signed.
    public static func of(_ url: URL) -> CodeSignature? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return of(code)
    }

    /// The signature of the running app; nil when it is not signed.
    public static func running() -> CodeSignature? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return of(staticCode)
    }

    /// What a staged update must meet. An app signed with a certificate takes only an update that meets
    /// its own designated requirement: from its own team under its own bundle id, or, with no team (the
    /// self-signed release identity), from the same certificate. An app signed ad hoc names no signer, so
    /// the update must be exactly the build read from the disk image whose checksum was checked; that is
    /// how a build signed ad hoc takes the first one signed with the release identity.
    public static func updateRequirement(running: CodeSignature, staged: CodeSignature) -> String {
        running.adHoc ? staged.requirement : running.requirement
    }

    private static func of(_ code: SecStaticCode) -> CodeSignature? {
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess else { return nil }
        let fields = info as? [String: Any]
        let team = fields?[kSecCodeInfoTeamIdentifier as String] as? String
        // Flags that can't be read count as a certificate's: an update must then meet this app's own
        // requirement, which refuses it rather than taking any signer.
        let raw = fields?[kSecCodeInfoFlags as String] as? NSNumber
        let adHoc = raw.map { SecCodeSignatureFlags(rawValue: $0.uint32Value).contains(.adhoc) } ?? false
        return CodeSignature(requirement: text as String, team: team, adHoc: adHoc)
    }
}
