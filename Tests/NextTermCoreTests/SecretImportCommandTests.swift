import Foundation
import Testing
@testable import NextTermCore

/// The command the import writes into agents' configs must still work after a relaunch: never a path in a disk image or
/// a copy macOS translocated to run it, as MCP registration refuses. A link on PATH into a lasting app is used even
/// from such a copy; with none, the import refuses. Every path here is made up.
@Suite struct SecretImportCommandTests {
    static let applications = "/Applications/Next Term.app/Contents/Resources/bin/nxtrm"
    static let translocated = "/private/var/folders/xy/abc123/T/AppTranslocation/0A1B2C3D/d/Next Term.app/Contents/Resources/bin/nxtrm"
    static let diskImage = "/Volumes/Next Term/Next Term.app/Contents/Resources/bin/nxtrm"
    static let binary = "/Applications/Next Term.app/Contents/MacOS/NextTerm"

    func command(links: [(path: String, target: String)] = [], script: String? = nil, executable: String? = nil, appLasts: Bool,
                 there: Set<String> = [applications]) -> [String]? {
        SecretImport.wrapperCommand(links: links, script: script, executable: executable, appLasts: appLasts, exists: { there.contains($0) })
    }

    @Test func theInstalledAppUsesItsLinkThenItsScriptThenItsBinary() {
        let installed = (path: "/usr/local/bin/nxtrm", target: Self.applications)
        #expect(command(links: [installed], script: Self.applications, executable: Self.binary, appLasts: true) == ["/usr/local/bin/nxtrm"])
        #expect(command(script: Self.applications, executable: Self.binary, appLasts: true) == [Self.applications])
        #expect(command(executable: Self.binary, appLasts: true) == [Self.binary, "--cli"])
    }

    @Test func aTranslocatedOrDiskImageCopyNeverWritesItsOwnPath() {
        for script in [Self.translocated, Self.diskImage] {
            let executable = (script as NSString).deletingLastPathComponent + "/../../MacOS/NextTerm"
            // macOS says such a copy does not last; its own paths would be refused even if it said otherwise.
            #expect(command(script: script, executable: executable, appLasts: false) == nil, "\(script)")
            #expect(command(script: script, executable: executable, appLasts: true) == nil, "\(script)")
            // A link on PATH into it is gone with it.
            #expect(command(links: [("/usr/local/bin/nxtrm", script)], script: script, appLasts: false, there: [script]) == nil)
            // A link on PATH into the installed app works from any copy.
            let linked = (path: "/Users/someone/.local/bin/nxtrm", target: Self.applications)
            #expect(command(links: [linked], script: script, executable: executable, appLasts: false) == [linked.path])
        }
    }

    @Test func aLinkIntoAnAppThatIsGoneOrARelativePathIsNotUsed() {
        let gone = (path: "/Users/someone/.local/bin/nxtrm", target: "/Users/someone/Old/Next Term.app/Contents/Resources/bin/nxtrm")
        #expect(command(links: [gone], script: Self.applications, appLasts: true) == [Self.applications])
        #expect(command(links: [gone], appLasts: false) == nil)
        #expect(command(executable: "NextTerm", appLasts: true) == nil)
        #expect(command(links: [("bin/nxtrm", Self.applications)], appLasts: true) == nil)
        #expect(SecretImport.lasts(Self.applications) && !SecretImport.lasts(Self.translocated) && !SecretImport.lasts(Self.diskImage))
    }
}
