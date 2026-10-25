import Darwin
import Foundation

/// `nxtrm secret import [--from FORMAT] [FILE | -]`: the rules both ends share. It opens the import preview in the
/// running app for a file, which the app reads, or for keys piped in from a password manager's CLI that the user runs
/// in a visible tab. The keys never ride in a line: the header holds the format, the byte count and the importer's
/// argv, the app answers `ready`, and only then do the raw bytes follow, read on the app's side into one buffer that is
/// wiped once parsed. The importer prints counts in fixed sentences, never a name or a value.
public enum SecretImportPipe {
    /// The request's kind on the app's socket: answered on its own connection, never an MCP tool.
    public static let tool = "secret_import"
    public static let usage = "usage: nxtrm secret import [--from FORMAT] [FILE | -]"
    /// The most standard input may hold.
    public static let maxBytes = SecretSources.maxBytes

    /// `--from`'s values, as `nxtrm` spells them.
    public static let formatNames: [String] = ["1password", "bitwarden", "bws", "env", "json", "csv", "yaml", "toml"]

    /// Where the keys come from.
    public enum Input: Equatable, Sendable {
        /// A file, as typed: the app reads it, as Import From › A File… does.
        case file(String)
        case standardInput
    }

    public struct Invocation: Equatable, Sendable {
        /// The format `--from` names; nil reads it from the content.
        public var format: SecretSources.Format?
        public var input: Input

        public init(format: SecretSources.Format?, input: Input) {
            self.format = format
            self.input = input
        }
    }

    public enum Parsed: Equatable, Sendable {
        case run(Invocation)
        case help
        /// Bad arguments, or a terminal on standard input: the usage line and what was wrong.
        case usage(String)
    }

    /// The arguments after `secret import`. With no FILE, or `-`, the keys come on standard input; a terminal there is
    /// a usage error, so it never waits for keys typed on screen.
    public static func parse(_ arguments: [String], standardInputIsTerminal: Bool) -> Parsed {
        if arguments.count == 1, ["--help", "-h", "help"].contains(arguments[0]) { return .help }
        var format: SecretSources.Format?
        var inputs: [Input] = []
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let argument: String = arguments[index]
            index += 1
            if !optionsEnded, argument == "--" {
                optionsEnded = true
                continue
            }
            if !optionsEnded, argument == "--from" || argument.hasPrefix("--from=") {
                guard format == nil else { return .usage("--from is given twice") }
                let name: String
                if argument == "--from" {
                    guard index < arguments.count else { return .usage("--from takes a format") }
                    name = arguments[index]
                    index += 1
                } else {
                    name = String(argument.dropFirst("--from=".count))
                }
                guard let chosen = self.format(named: name) else {
                    return .usage("FORMAT is one of " + formatNames.joined(separator: ", "))
                }
                format = chosen
                continue
            }
            if !optionsEnded, argument == "-" {
                inputs.append(.standardInput)
                continue
            }
            if !optionsEnded, argument.hasPrefix("-") { return .usage("\(argument) is not an option of secret import") }
            inputs.append(.file(argument))
        }
        guard inputs.count <= 1 else { return .usage("give one FILE, or - for standard input") }
        let input: Input = inputs.first ?? .standardInput
        if input == .standardInput, standardInputIsTerminal {
            return .usage("pipe the keys in from a password manager\u{2019}s CLI, or give a FILE")
        }
        return .run(Invocation(format: format, input: input))
    }

    /// The format `--from` names, as `formatNames` spells it.
    public static func format(named name: String) -> SecretSources.Format? {
        guard formatNames.contains(name) else { return nil }
        return SecretSources.Format(rawValue: name)
    }

    /// Whether `arguments` (as the kernel has them) are Next Term's own importer: `…/NextTerm --cli secret import …`.
    public static func isImporter(_ arguments: [String]) -> Bool {
        guard arguments.count >= 4, (arguments[0] as NSString).lastPathComponent == "NextTerm" else { return false }
        return arguments[1] == "--cli" && arguments[2] == "secret" && arguments[3] == "import"
    }
}
