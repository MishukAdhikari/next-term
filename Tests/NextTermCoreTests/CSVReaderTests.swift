import Foundation
import Testing
@testable import NextTermCore

/// The import's CSV reader, as RFC 4180 writes a file: quoted fields, `""` for a quote, line breaks inside quotes, CRLF,
/// a byte-order mark, and a cap on rows. Every value here is made up.
@Suite struct CSVReaderTests {
    private static func records(_ text: String) -> [CSVReader.Record] {
        guard case .success(let records) = CSVReader.records(text) else {
            Issue.record("the text reads")
            return []
        }
        return records
    }

    private static func failure(_ text: String) -> CSVReader.Failure? {
        guard case .failure(let failure) = CSVReader.records(text) else { return nil }
        return failure
    }

    @Test func plainFieldsAndTheirLines() {
        let records = Self.records("name,value\nALPHA,one\nBETA,two\n")
        #expect(records.map(\.fields) == [["name", "value"], ["ALPHA", "one"], ["BETA", "two"]])
        #expect(records.map(\.line) == [1, 2, 3])
    }

    @Test func quotedCommasAndDoubledQuotes() {
        let records = Self.records("a,b\n\"one, two\",\"say \"\"hi\"\"\"\n")
        #expect(records.last?.fields == ["one, two", "say \"hi\""])
    }

    @Test func aLineBreakInsideQuotesStaysInTheField() {
        let records = Self.records("title,notes\nItem,\"first line\nsecond line\"\nNext,plain\n")
        #expect(records.count == 3)
        #expect(records[1].fields == ["Item", "first line\nsecond line"])
        // A record's line is where it starts.
        #expect(records[1].line == 2)
        #expect(records[2].line == 4)
    }

    @Test func crlfEndsARecordAndAByteOrderMarkIsDropped() {
        let records = Self.records("\u{FEFF}name,value\r\nALPHA,one\r\nBETA,\"two\r\nlines\"\r\n")
        #expect(records.first?.fields == ["name", "value"])
        #expect(records[1].fields == ["ALPHA", "one"])
        #expect(records[2].fields == ["BETA", "two\r\nlines"])
    }

    @Test func blankLinesAndAMissingLastLineBreak() {
        let records = Self.records("a,b\n\n1,2\n\n3,4")
        #expect(records.map(\.fields) == [["a", "b"], ["1", "2"], ["3", "4"]])
        #expect(records.map(\.line) == [1, 3, 5])
    }

    @Test func emptyFieldsAreKept() {
        let records = Self.records("a,b,c\n,,\n\"\",x,\n")
        #expect(records[1].fields == ["", "", ""])
        #expect(records[2].fields == ["", "x", ""])
    }

    @Test func textOutsideASCIIReadsWhole() {
        let records = Self.records("name,note\nCaf\u{E9},\"\u{201C}quoted\u{201D}, \u{1F511}\"\n")
        #expect(records.last?.fields == ["Caf\u{E9}", "\u{201C}quoted\u{201D}, \u{1F511}"])
    }

    @Test func aRaggedRowIsRefusedWithItsLine() {
        #expect(Self.failure("a,b\n1,2\n3\n") == .ragged(line: 3))
        #expect(Self.failure("a,b\n1,2,3\n") == .ragged(line: 2))
        #expect(CSVReader.Failure.ragged(line: 3).sentence.contains("line 3"))
    }

    @Test func aQuoteLeftOpenIsRefused() {
        #expect(Self.failure("a,b\n1,\"two\n3,4\n") == .openQuote(line: 2))
    }

    @Test func rowsPastTheCapAreRefused() {
        var text = "name,value\n"
        text.reserveCapacity(CSVReader.maxRows * 8)
        for _ in 0..<CSVReader.maxRows { text += "K,v\n" }
        #expect(Self.records(text).count == CSVReader.maxRows + 1)
        text += "K,v\n"
        #expect(Self.failure(text) == .tooManyRows)
    }

    @Test func nothingButAHeader() {
        #expect(Self.records("name,value\n").map(\.fields) == [["name", "value"]])
        #expect(Self.records("").isEmpty)
    }
}
