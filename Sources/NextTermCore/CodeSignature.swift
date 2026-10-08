import Foundation
import Security

/// Who signed an app, as the install script checks it with `codesign -R`.
public struct CodeSignature: Equatable, Sendable {
    /// The designated requirement, as text: a team's id and the bundle id when a team signs it, or the
    /// code's own hashes when it is signed ad hoc.
    public var requirement: String
    /// The team that signed it; none when it is signed ad hoc.
    public var team: String?

    public init(requirement: String, team: String?) {
        self.requirement = requirement
        self.team = team
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

    /// What a staged update must meet. A team-signed app takes only an update signed by its own team
    /// under its own bundle id. An app signed ad hoc has no team to name, so the update must be exactly
    /// the build read from the disk image whose checksum was checked.
    public static func updateRequirement(running: CodeSignature, staged: CodeSignature) -> String {
        running.team == nil ? staged.requirement : running.requirement
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
        return CodeSignature(requirement: text as String, team: team)
    }
}
