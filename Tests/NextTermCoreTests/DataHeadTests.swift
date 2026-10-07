import Darwin
import Foundation
import Testing
@testable import NextTermCore

@Suite struct DataHeadTests {
    /// Every record a scanner finds when the bytes arrive `size` at a time (1: every boundary is tested).
    static func scan(_ text: String, kind: DataFileKind, delimiter: UInt8 = 0x2C, chunk size: Int) -> [DataRecord] {
        var scanner = RecordScanner(kind: kind, delimiter: delimiter, start: .start, limit: .max)
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            scanner.feed(Data(bytes[i..<min(bytes.count, i + size)]))
            i += size
        }
        scanner.finish()
        return scanner.records
    }

    /// The process's memory, as Activity Monitor counts it.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    @Test func jsonLinesKeepKeyOrderAndReportBadLines() throws {
        let project = FixtureProject()
        let text = [
            #"{"id": 1, "question": "What is RAG?", "meta": {"source": "a.md", "page": 3}, "tags": ["x", "y"]}"#,
            "",
            #"{"id": 2, "question": "Line\nbreak \"quoted\"", "score": 0.5}"#,
            #"{"id": 3, "question": oops}"#,
            "  ",
            #"[1, 2, 3]"#,
            #"{"zeta": true, "alpha": null}"#,
        ].joined(separator: "\r\n") + "\r\n"
        project.write("eval.jsonl", text)
        let page = try DataHead.page(at: project.root + "/eval.jsonl", kind: .jsonLines)
        #expect(page.records.count == 5 && page.isAtEnd)
        let first = page.records[0]
        #expect(first.line == 1 && first.keys == ["id", "question", "meta", "tags"] && first.error == nil)
        #expect(first.fields == ["1", "\"What is RAG?\"", #"{"source": "a.md", "page": 3}"#, #"["x", "y"]"#])
        #expect(first.raw.hasSuffix("]}")) // the "\r" of the CRLF is not part of it
        #expect(page.records[1].line == 3 && DataHead.displayValue(page.records[1].value(for: "question") ?? "") == "Line\nbreak \"quoted\"")
        #expect(page.records[2].line == 4 && page.records[2].error?.hasPrefix("Not valid JSON") == true && page.records[2].keys.isEmpty)
        #expect(page.records[3].line == 6 && page.records[3].keys.isEmpty && page.records[3].fields == ["[1, 2, 3]"])
        #expect(page.records[4].keys == ["zeta", "alpha"] && page.records[4].value(for: "alpha") == "null")
        #expect(DataHead.columns(of: page.records) == ["id", "question", "meta", "tags", "score", "zeta", "alpha"])

        // Page by page: each page starts where the last ended, with the right line numbers.
        let one = try DataHead.page(at: project.root + "/eval.jsonl", kind: .jsonLines, limit: 2)
        #expect(one.records.map(\.line) == [1, 3] && !one.isAtEnd && one.end.line == 4)
        let two = try DataHead.page(at: project.root + "/eval.jsonl", kind: .jsonLines, from: one.end, limit: 2)
        #expect(two.records.map(\.line) == [4, 6] && !two.isAtEnd)
        let three = try DataHead.page(at: project.root + "/eval.jsonl", kind: .jsonLines, from: two.end, limit: 2)
        #expect(three.records.map(\.line) == [7] && three.isAtEnd)
    }

    @Test func csvQuotesNewlinesAndCRLF() throws {
        let text = "id,question,answer\r\n"
            + "1,\"What, exactly?\",\"He said \"\"hi\"\"\"\r\n"
            + "2,\"two\nlines\",plain\r\n"
            + "\r\n"
            + "3,,\"\"\r\n"
            + "4,last,no newline"
        let expected: [[String]] = [["id", "question", "answer"], ["1", "What, exactly?", "He said \"hi\""],
                                    ["2", "two\nlines", "plain"], ["3", "", ""], ["4", "last", "no newline"]]
        for size in [1, 2, 3, 7, 1000] {
            let records = Self.scan(text, kind: .delimited, chunk: size)
            #expect(records.map(\.fields) == expected, "chunks of \(size)")
            #expect(records.map(\.line) == [1, 2, 3, 6, 7], "chunks of \(size)")
        }
        let records = Self.scan(text, kind: .delimited, chunk: 1000)
        #expect(records[2].raw == "2,\"two\nlines\",plain" && records.allSatisfy { $0.error == nil })

        // Old Mac line endings, and a quote that is never closed.
        let mac = Self.scan("a,b\r1,2\r3,\"open", kind: .delimited, chunk: 1)
        #expect(mac.map(\.fields) == [["a", "b"], ["1", "2"], ["3", "open"]])
        #expect(mac.last?.error?.contains("quote") == true)
        // A quote inside an unquoted field is kept as it is.
        #expect(Self.scan("5 \"inch\",x\n", kind: .delimited, chunk: 1).first?.fields == ["5 \"inch\"", "x"])
    }

    @Test func csvFilesPageAcrossChunksWithBOMAndSemicolons() throws {
        let project = FixtureProject()
        var text = "\u{FEFF}name;note;value\r\n"
        for i in 1...6000 { text += "row \(i);\"a; \"\"quoted\"\"\r\nnote \(i)\";\(i),5\r\n" } // about 230 KB: crosses the 256 KB chunks
        for i in 6001...9000 { text += "row \(i);plain;\(i),5\r\n" }
        project.write("eu.csv", text)
        let path = project.root + "/eu.csv"
        var page = try DataHead.page(at: path, kind: .delimited)
        #expect(page.delimiter == 0x3B && page.records.count == 1000)
        #expect(page.records[0].fields == ["name", "note", "value"]) // no BOM in the first name
        #expect(DataHead.looksLikeHeader(page.records.map(\.fields)))
        var all = page.records
        while !page.isAtEnd {
            page = try DataHead.page(at: path, kind: .delimited, from: page.end, delimiter: page.delimiter)
            all += page.records
        }
        #expect(all.count == 9001)
        let wrong = all.dropFirst().enumerated().first { offset, record in
            let i = offset + 1
            let note = i <= 6000 ? "a; \"quoted\"\r\nnote \(i)" : "plain"
            return record.fields != ["row \(i)", note, "\(i),5"]
        }
        #expect(wrong == nil, "row \(wrong?.offset ?? 0): \(wrong?.element.fields ?? [])")
        #expect(all[6000].line == 12_000 && all.last?.line == 15_001)
    }

    @Test func delimitersAndHeaders() {
        #expect(DataHead.detectDelimiter(Array("a,b,c\n1,2,3\n".utf8), fallback: 0x09) == 0x2C)
        #expect(DataHead.detectDelimiter(Array("a\tb\tc\n1\t2,5\t3\n".utf8), fallback: 0x2C) == 0x09)
        #expect(DataHead.detectDelimiter(Array("a;b;c\n1,5;2,3;4\n".utf8), fallback: 0x2C) == 0x3B)
        #expect(DataHead.detectDelimiter(Array("\"x,y\";b\n\"1,2\";3\n".utf8), fallback: 0x2C) == 0x3B)
        #expect(DataHead.detectDelimiter(Array("just text\n".utf8), fallback: 0x09) == 0x09)
        #expect(DataHead.looksLikeHeader([["id", "score"], ["1", "0.5"], ["2", "0.7"]]))
        #expect(DataHead.looksLikeHeader([["", "question", "answer"], ["0", "Why?", "Because."]]))
        #expect(!DataHead.looksLikeHeader([["1", "0.5"], ["2", "0.7"]]))
        #expect(!DataHead.looksLikeHeader([["a", "a"], ["1", "2"]]))
        #expect(!DataHead.looksLikeHeader([[String(repeating: "long sentence ", count: 8), "x"], ["y", "z"]]))
    }

    @Test func logsLongLinesAndBinaries() throws {
        let project = FixtureProject()
        let long = String(repeating: "é", count: DataHead.maxRecordBytes) // 2 bytes each: twice the limit
        project.write("app.log", "first\n" + long + "\nthird")
        let page = try DataHead.page(at: project.root + "/app.log", kind: .lines)
        #expect(page.records.map(\.line) == [1, 2, 3] && page.records.map(\.isTruncated) == [false, true, false])
        #expect(page.records[1].raw.utf8.count <= DataHead.maxRecordBytes && page.records[1].raw.allSatisfy { $0 == "é" })
        #expect(page.records[2].raw == "third" && page.isAtEnd)

        let jsonl = Self.scan("{\"v\": \"" + long + "\"}\n{\"v\": 1}\n", kind: .jsonLines, chunk: 100_000)
        #expect(jsonl.count == 2 && jsonl[0].isTruncated && jsonl[0].error != nil && jsonl[1].keys == ["v"])
        let csv = Self.scan("a,\"" + long + "\nb,c\n", kind: .delimited, chunk: 100_000)
        #expect(csv.count == 2 && csv[0].isTruncated && csv[0].error?.contains("quote") == true && csv[1].fields == ["b", "c"])

        try Data([0x41, 0x00, 0x42]).write(to: URL(fileURLWithPath: project.root + "/blob.log"))
        #expect(throws: DataHeadError.binary) { try DataHead.page(at: project.root + "/blob.log", kind: .lines) }
        try Data([0xFF, 0xFE, 0x41, 0x00]).write(to: URL(fileURLWithPath: project.root + "/wide.tsv"))
        #expect(throws: DataHeadError.utf16) { try DataHead.page(at: project.root + "/wide.tsv", kind: .delimited) }
        #expect(!DataHead.isText(project.root + "/blob.log") && DataHead.isText(project.root + "/app.log"))
        #expect(throws: DataHeadError.notAFile) { try DataHead.page(at: project.root, kind: .lines) }
    }

    @Test func estimatesAndCopies() {
        #expect(DataHead.estimatedTotal(records: 1000, through: DataPosition(offset: 100_000, line: 1001), fileSize: 10_000_000, lineCount: nil) == 100_000)
        #expect(DataHead.estimatedTotal(records: 1000, through: DataPosition(offset: 100_000, line: 2001), fileSize: 10_000_000, lineCount: 50_000) == 25_000)
        #expect(DataHead.estimatedTotal(records: 3, through: DataPosition(offset: 30, line: 4), fileSize: 30, lineCount: 3) == 3)
        #expect(DataExport.jsonLines([#"{"a":1}"#]) == "{\"a\":1}\n")
        #expect(DataExport.jsonLines([#"{"a":1}"#, #"{"a":2}"#]) == "[\n  {\"a\":1},\n  {\"a\":2}\n]\n")
        #expect(DataExport.csv(columns: ["q", "a"], rows: [["x, y", nil]]) == "q,a\n\"x, y\",\n")
        #expect(DataExport.objects(columns: ["q"], rows: [["1"]]) == "[\n  {\"q\": \"1\"}\n]\n")
        #expect(DataHead.displayValue("\"tab\\there\"") == "tab\there" && DataHead.displayValue("[1,2]") == "[1,2]")
        #expect(DataFileKind(path: "/x/a.NDJSON") == .jsonLines && DataFileKind(path: "b.tsv") == .delimited && DataFileKind(path: "c.log") == .lines)
    }

    /// A 200 MB file: the first page comes back fast without reading the rest, and the line count streams.
    @Test func twoHundredMegabytes() throws {
        let project = FixtureProject()
        let path = project.root + "/corpus.jsonl"
        var block = ""
        var perBlock = 0
        while block.utf8.count < 1 << 20 {
            let embedding = (0..<16).map { String(format: "%.4f", Double(($0 * 7 + perBlock) % 100) / 100) }.joined(separator: ",")
            block += #"{"id":\#(perBlock),"text":"chunk \#(perBlock) of the corpus","embedding":[\#(embedding)],"meta":{"source":"doc-\#(perBlock).md"}}"# + "\n"
            perBlock += 1
        }
        let data = Data(block.utf8)
        FileManager.default.createFile(atPath: path, contents: nil)
        let out = try #require(FileHandle(forWritingAtPath: path))
        for _ in 0..<200 { out.write(data) }
        try out.close()
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        #expect(size >= 200 << 20)

        let before = Self.footprint()
        let started = Date()
        let page = try DataHead.page(at: path, kind: .jsonLines)
        let elapsed = Date().timeIntervalSince(started)
        let grew = Int64(Self.footprint()) - Int64(before)
        #expect(page.records.count == 1000 && page.records[0].value(for: "id") == "0" && page.records[999].value(for: "id") == "999")
        #expect(page.records.allSatisfy { $0.error == nil } && page.records[0].keys == ["id", "text", "embedding", "meta"])
        #expect(!page.isAtEnd && page.end.line == 1001 && page.end.offset < 1 << 20)
        #expect(elapsed < 3, "the first page took \(elapsed) s")
        #expect(grew < 64 << 20, "memory grew by \(grew >> 20) MB")

        let more = try DataHead.page(at: path, kind: .jsonLines, from: page.end)
        #expect(more.records.first?.value(for: "id") == "1000" && more.records.first?.line == 1001)

        let counting = Date()
        var reports = 0
        let lines = DataHead.countLines(path) { _, _ in reports += 1 }
        let countTime = Date().timeIntervalSince(counting)
        #expect(lines == perBlock * 200 && reports >= 50)
        #expect(countTime < 20, "counting took \(countTime) s")
        let estimate = DataHead.estimatedTotal(records: 1000, through: page.end, fileSize: UInt64(size), lineCount: lines)
        #expect(estimate == perBlock * 200)

        // Cancelling stops the count at the next read.
        let cancel = DataCancellation()
        var seen = 0
        let stopped = DataHead.countLines(path, cancellation: cancel) { _, _ in
            seen += 1
            cancel.cancel()
        }
        #expect(stopped == nil && seen == 1)
        withExtendedLifetime(project) {}
    }

    /// A line longer than a page may read (a minified file, a log line with no break): memory stays flat,
    /// the page ends partway through it, and the next page goes on along the same line.
    @Test func aLineLongerThanAPageReads() throws {
        let project = FixtureProject()
        let path = project.root + "/minified.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        let out = try #require(FileHandle(forWritingAtPath: path))
        out.write(Data("first\n".utf8))
        let block = Data(repeating: 0x78, count: 4 << 20)
        for _ in 0..<((DataHead.maxScanBytes >> 22) + 8) { out.write(block) } // 32 MB past the limit
        out.write(Data("\nlast\n".utf8))
        try out.close()
        let size = UInt64((try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)

        let before = Self.footprint()
        let page = try DataHead.page(at: path, kind: .lines)
        let grew = Int64(Self.footprint()) - Int64(before)
        #expect(grew < 48 << 20, "memory grew by \(grew >> 20) MB")
        #expect(page.records.map(\.line) == [1, 2] && page.records[1].isTruncated && !page.isAtEnd)
        #expect(page.end.line == 2 && page.end.offset >= UInt64(DataHead.maxScanBytes) && page.end.offset < size)

        let rest = try DataHead.page(at: path, kind: .lines, from: page.end)
        #expect(rest.records.map(\.line) == [2, 3] && rest.records[0].isTruncated && rest.records[1].raw == "last")
        #expect(rest.isAtEnd)

        // Stopping a page: a cut record ends where the reading is, one still being read is left for the next.
        let long = Data(repeating: 0x61, count: DataHead.maxRecordBytes + 10)
        for kind in [DataFileKind.lines, .delimited] {
            var scanner = RecordScanner(kind: kind, delimiter: 0x2C, start: .start, limit: .max)
            scanner.feed(Data("a,b\n".utf8) + long)
            scanner.stop()
            #expect(scanner.isFull && scanner.records.count == 2 && scanner.records[1].isTruncated, "\(kind)")
            #expect(scanner.position == DataPosition(offset: UInt64(4 + long.count), line: 2), "\(kind)")
            var partial = RecordScanner(kind: kind, delimiter: 0x2C, start: .start, limit: .max)
            partial.feed(Data("a,b\nc,d".utf8))
            partial.stop()
            #expect(partial.records.count == 1 && partial.position == DataPosition(offset: 4, line: 2), "\(kind)")
        }
        withExtendedLifetime(project) {}
    }
}
