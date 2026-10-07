import Foundation
import Testing
@testable import NextTermCore

/// Where a .env file's values are, for drawing them hidden; and which files count as env files.
@Suite struct EnvValuesTests {
    /// The text of each value range.
    func values(_ text: String) -> [String] {
        EnvFile.valueRanges(in: text).map { (text as NSString).substring(with: $0) }
    }

    @Test func valuesAfterTheFirstEquals() {
        #expect(values("A=1\nB=two words\n") == ["1", "two words"])
        #expect(values("export KEY=abc\nexport\tTAB=x\n") == ["abc", "x"])
        #expect(values("SPACED = value   \n") == ["value"])
        #expect(values("Q=a=b==c\nKEY==x\nURL=postgres://h/db?sslmode=require\n") == ["a=b==c", "=x", "postgres://h/db?sslmode=require"])
        #expect(values("\u{FEFF}A=1") == ["1"])
    }

    @Test func quotesAreIncluded() {
        #expect(values("S='single # not a comment'\n") == ["'single # not a comment'"])
        #expect(values(#"D="dou\"ble""#) == [#""dou\"ble""#])
        #expect(values("B=`back`\n") == ["`back`"])
        // A quote that never closes: the rest of the line, and the next line is a line of its own.
        #expect(values("U=\"abc\nNEXT=2\n") == ["\"abc", "2"])
    }

    @Test func commentsAndKeysStayVisible() {
        #expect(values("# KEY=hidden\n  # also=a comment\n").isEmpty)
        #expect(values("A=val # note\nB=\"q\" # note\nC='x'#tight\n") == ["val", "\"q\"", "'x'"])
        // A # inside a value, with no blank before it, is part of it.
        #expect(values("C=a#b\nURL=postgres://u:p#w@h/db\n") == ["a#b", "postgres://u:p#w@h/db"])
        // Right after the =, some readers take it as the value: hidden.
        #expect(values("D=#x\nE= #only a comment\n") == ["#x"])
        // Lines that are not KEY=value.
        #expect(values("not a line\nhas space=x\n=novalue\nDB_HOST\n").isEmpty)
        #expect(values("1BAD=x\n") == ["x"])
    }

    @Test func emptyValuesHaveNoRange() {
        #expect(values("A=\nB=   \nC= # c\n").isEmpty)
        #expect(values("C=\"\"\nD=''\n") == ["\"\"", "''"])
    }

    @Test func windowsLineEndings() {
        let text = "A=1\r\nB=\"two\"\r\nC=x # c\r\nD=\r\n"
        #expect(values(text) == ["1", "\"two\"", "x"])
        #expect(!values(text).contains { $0.contains("\r") })
        #expect(values("KEY=\"a\r\nb\"\r\nN=1") == ["\"a\r\nb\"", "1"])
        // The reader splits the same lines, so a value ends where its range does.
        #expect(EnvFile.values(EnvFile.parse("A=1\r\nB=2\r\n")) == ["A": "1", "B": "2"])
        #expect(EnvFile.values(EnvFile.parse("KEY=\"a\r\nb\"\r\nN=1")) == ["KEY": "a\nb", "N": "1"])
    }

    @Test func aQuotedValueOverSeveralLinesIsOneRange() {
        let text = "KEY=\"-----BEGIN KEY-----\nabc\n-----END KEY-----\"\nAFTER=1\n"
        #expect(values(text) == ["\"-----BEGIN KEY-----\nabc\n-----END KEY-----\"", "1"])
        // It ends where the reader ends it.
        #expect(EnvFile.values(EnvFile.parse(text))["KEY"] == "-----BEGIN KEY-----\nabc\n-----END KEY-----")
    }

    @Test func rangesCountUTF16() {
        let text = "E=héllo 👋\nK=v"
        let ranges = EnvFile.valueRanges(in: text)
        #expect(ranges == [NSRange(location: 2, length: 8), NSRange(location: 13, length: 1)])
        #expect(values(text) == ["héllo 👋", "v"])
    }

    @Test func envFileNames() {
        for name in [".env", ".env.local", ".ENV.Production", ".env.example", "prod.env", "docker.env", ".flaskenv"] {
            #expect(EnvFile.isEnvFile(named: name), "\(name)")
        }
        for name in ["env", ".envrc", "env.example", "environment.yml", "env.ts", ".environment", "flaskenv"] {
            #expect(!EnvFile.isEnvFile(named: name), "\(name)")
        }
    }

    @Test func theEditorLinkNeverSharesEnvFiles() {
        for path in ["/p/.env", "/p/.env.local", "/p/deploy/prod.env", "/p/docker.env", "/p/.flaskenv", "/p/certs/tls.key",
                     "/p/server.pem", "/Users/me/.ssh/id_rsa", "/p/.npmrc", "/Users/me/.netrc"] {
            #expect(IDELink.isSensitive(path), "\(path)")
        }
        for path in ["/p/.env.example", "/p/README.md", "/p/src/env.ts", "/p/.envrc", "/p/id_rsa.pub", "/p/environment.yml"] {
            #expect(!IDELink.isSensitive(path), "\(path)")
        }
    }
}
