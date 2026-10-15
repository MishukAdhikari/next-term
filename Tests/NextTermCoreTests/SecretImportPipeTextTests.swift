import Darwin
import Foundation
import Testing
@testable import NextTermCore

/// What `nxtrm secret import` prints, how much it reads, and the password managers' lines Next Term types. Every value
/// here is made up, from a provider's head and filler put together at run time.
@Suite struct SecretImportPipeTextTests {
    typealias P = SecretImportPipe
    typealias F = SecretSourcesFixtures

    @Test func itPrintsFixedSentencesWithCounts() {
        #expect(P.text(.found(7)).line == "Next Term: 7 keys found. Choose them in the Import window.")
        #expect(P.text(.found(1)).line == "Next Term: 1 key found. Choose it in the Import window.")
        #expect(P.text(.imported(3)) == (line: "Imported 3 keys.", exit: 0))
        #expect(P.text(.imported(1)).line == "Imported 1 key.")
        #expect(P.text(.nothing) == (line: "Nothing imported.", exit: 1))
        #expect(P.text(.imported(0)) == (line: "Nothing imported.", exit: 1))
        #expect(P.text(.tooLarge).line.contains("the input is over 5 MB"))
        let off: String = "Next Term is not running, or \u{201C}Let agents control Next Term\u{201D} is off in its Settings."
        #expect(P.text(.noSocket).line.contains(off))
        for ending in [P.Ending.refused, .busy, .closed, .noSocket, .peerCheck, .tooLarge, .empty, .nothing] {
            #expect(P.text(ending).exit == 1, "\(ending)")
        }
        #expect(P.text(.usage("made-up reason")).exit == 2)
        #expect(P.text(.moved).exit == 0)
    }

    /// Every ending, with the counts a made-up `bws` list gives, prints none of its values or names.
    @Test func noLineHoldsAByteOfTheInput() {
        let input: String = ExportFixtures.bwsList
        var bytes: [UInt8] = Array(input.utf8)
        let report: SourceReport = SecretSources.read(&bytes, name: "standard input", format: .bws)
        let found: Int = report.rows.count
        #expect(found > 0)
        let endings: [P.Ending] = [.found(found), .unreadable, .moved, .imported(found), .imported(1), .nothing,
                                   .refused, .busy, .closed, .noSocket, .peerCheck, .tooLarge, .empty, .help]
        let secrets: [String] = [F.openAI, F.pinecone, ExportFixtures.noteToken, "made-up-db-pass-2026"]
        let names: [String] = ["OPENAI_API_KEY", "PINECONE_API_KEY", "DB_PASSWORD", "made-up-project"]
        for ending in endings {
            let line: String = P.text(ending).line
            for secret in secrets { #expect(!line.contains(secret), "\(ending)") }
            for name in names { #expect(!line.contains(name), "\(ending)") }
            // Not even a value's last four characters.
            for secret in secrets { #expect(!line.contains(String(secret.suffix(4))), "\(ending)") }
        }
    }

    @Test func standardInputIsReadToItsEndOrTheCap() throws {
        let small: [UInt8] = Array("made-up-\(UUID().uuidString)".utf8)
        var read: [UInt8] = []
        #expect(try Self.readThroughPipe(small, limit: 64, into: &read) == .ended)
        #expect(read == small)

        let exact: [UInt8] = [UInt8](repeating: 0x61, count: 64)
        #expect(try Self.readThroughPipe(exact, limit: 64, into: &read) == .ended)
        #expect(read.count == 64)

        let over: [UInt8] = [UInt8](repeating: 0x62, count: 65)
        #expect(try Self.readThroughPipe(over, limit: 64, into: &read) == .tooLarge)
        #expect(read.isEmpty)

        #expect(try Self.readThroughPipe([], limit: 64, into: &read) == .ended)
        #expect(read.isEmpty)
    }

    /// `nxtrm secret import --from env keys.json`: the format given wins over the file's name, for a file the app
    /// reads as Import From › A File… does.
    @Test func aFileGivenWithAFormatIsReadAsThatFormat() {
        let home = SecretImportFixtures.Home()
        defer { home.remove() }
        let path: String = home.write("made-up-app/keys.json", "MADE_UP_API_KEY=\(F.openAI)\n")
        #expect(SecretSources.readFile(path).unreadable == .notJSON)
        let forced: SourceReport = SecretSources.readFile(path, format: .env)
        #expect(forced.format == .env && forced.rows.map(\.name) == ["MADE_UP_API_KEY"])
        guard case .copy(let picked) = SecretSources.readPicked(path, home: home.path, format: .env) else {
            Issue.record("a file no agent reads is a copy")
            return
        }
        #expect(picked.format == .env && picked.rows.count == 1)
    }

    private static func readThroughPipe(_ bytes: [UInt8], limit: Int, into read: inout [UInt8]) throws -> P.ReadEnd {
        var ends: [Int32] = [0, 0]
        try #require(pipe(&ends) == 0)
        defer { close(ends[0]) }
        let written: Int = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return write(ends[1], base, raw.count)
        }
        close(ends[1])
        try #require(written == bytes.count)
        read = []
        return P.readAll(ends[0], into: &read, limit: limit)
    }
}

@Suite struct SecretImportPresetTests {
    typealias Preset = SecretImportPreset
    static let nxtrm = ["/Applications/Next Term.app/Contents/Resources/bin/nxtrm"]
    static let quoted = "'/Applications/Next Term.app/Contents/Resources/bin/nxtrm'"

    @Test func theLinesNextTermTypes() {
        let op: String = "op item list --categories \"API Credential,Password\" --format json | op item get - --format json "
            + "--reveal | \(Self.quoted) secret import --from 1password -"
        #expect(Preset.onePassword.line(nxtrm: Self.nxtrm, shell: "zsh") == op)
        let bw: String = "BW_SESSION=\"$(bw unlock --raw)\" bw list items | \(Self.quoted) secret import --from bitwarden -; "
            + "bw lock"
        #expect(Preset.bitwarden.line(nxtrm: Self.nxtrm, shell: "bash") == bw)
        let bws: String = "bws secret list --output json | \(Self.quoted) secret import --from bws -"
        #expect(Preset.bws.line(nxtrm: Self.nxtrm, shell: "fish") == bws)
        // A development build has no script: its binary in command line mode.
        let binary: String? = Preset.bws.line(nxtrm: ["/tmp/made-up/NextTerm", "--cli"], shell: "zsh")
        #expect(binary == "bws secret list --output json | /tmp/made-up/NextTerm --cli secret import --from bws -")
    }

    @Test func noLineCarriesACredentialNextTermStores() {
        for preset in Preset.allCases {
            let line: String = preset.line(nxtrm: Self.nxtrm, shell: "zsh") ?? ""
            #expect(!line.isEmpty)
            #expect(!line.contains("secret run"), "\(preset)")
            #expect(!line.contains("BWS_ACCESS_TOKEN"), "\(preset)")
            #expect(!line.contains("--session"), "\(preset)")
            #expect(!line.contains("\n") && !line.contains("\r"), "\(preset)")
            #expect(line.contains("secret import --from \(preset.format.rawValue) -"), "\(preset)")
        }
    }

    @Test func aShellThatCantReadTheLineGetsNone() {
        for shell in ["nu", "pwsh", "elvish", "xonsh", "tcsh", "csh"] {
            #expect(Preset.onePassword.line(nxtrm: Self.nxtrm, shell: shell) == nil, "\(shell)")
        }
        #expect(Preset.bitwarden.line(nxtrm: ["/tmp/a\u{7}b"], shell: "zsh") == nil)
    }

    @Test func eachPresetNamesItsAppAndDownloadPage() {
        #expect(Preset.onePassword.tabTitle == "Import from 1Password")
        #expect(Preset.bitwarden.tabTitle == "Import from Bitwarden")
        #expect(Preset.bws.tabTitle == "Import from Bitwarden Secrets Manager")
        #expect(Preset.allCases.map(\.program) == ["op", "bw", "bws"])
        let pages: [String] = Preset.allCases.map(\.download.absoluteString)
        #expect(pages == ["https://1password.com/downloads/command-line", "https://bitwarden.com/help/cli/",
                          "https://bitwarden.com/help/secrets-manager-cli/"])
        for page in Preset.allCases.map(\.download) { #expect(SafeWebLink.isAllowed(page)) }
        #expect(Preset(format: .bws) == .bws && Preset(format: .env) == nil)
    }
}
