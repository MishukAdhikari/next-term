import Foundation
import Testing
@testable import NextTermCore

@Suite struct GhostValidationTests {
    typealias Entry = CommandHistory.Entry
    let home = "/Users/me"
    let cwd = "/Users/me/project"

    /// A stand-in disk: these folders and files, these programs.
    func probe(folders: Set<String> = [], files: Set<String> = [], programs: Set<String> = []) -> GhostValidation.FileProbe {
        let all = folders.union(files).union(programs)
        return GhostValidation.FileProbe(exists: { all.contains(Self.normal($0)) }, isFolder: { folders.contains(Self.normal($0)) },
                                         isExecutable: { programs.contains(Self.normal($0)) })
    }

    static func normal(_ path: String) -> String { (path as NSString).standardizingPath }

    func valid(_ line: String, _ disk: GhostValidation.FileProbe) -> Bool {
        GhostValidation.check(line, cwd: cwd, home: home, probe: disk)
    }

    @Test func cdGoesSomewhereThatIsThere() {
        let disk = probe(folders: ["/Users/me/Code", "/Users/me/project", "/Users/me/project/src", "/Users/me"])
        #expect(!valid("cd gone", disk))
        #expect(!valid("cd .", disk) && !valid("cd /Users/me/project", disk) && !valid("cd /Users/me/project/", disk))
        #expect(valid("cd ~/Code", disk) && valid("cd src", disk) && valid("cd ..", disk) && valid("cd ~", disk))
        #expect(!valid("cd ~/old-project", disk))
        // Not one folder named: not checked.
        #expect(valid("cd", disk) && valid("cd -", disk) && valid("cd a b", disk) && valid("cd $OLD", disk))
    }

    @Test func pathArgumentsMustBeThere() {
        let disk = probe(folders: ["/Users/me/project/src", "/Users/me/my dir"], files: ["/Users/me/project/src/main.swift", "/Users/me/my dir/x"])
        #expect(!valid("vim src/missing.swift", disk) && valid("vim src/main.swift", disk))
        #expect(valid("git checkout main", disk) && valid("git push origin feature/x", disk))
        #expect(valid(#"cat "/Users/me/my dir/x""#, disk) && !valid(#"cat "/Users/me/my dir/y""#, disk))
        #expect(valid(#"cat ~/my\ dir/x"#, disk) && !valid("cat ./nope.txt", disk) && !valid("cat ../nope.txt", disk))
        // What the shell expands, URLs, flags and assignments are not checked.
        #expect(valid("cat $HOME/x", disk) && valid("ls src/*.gone", disk) && valid("curl https://example.com/a/b", disk))
        #expect(valid("make --file=/gone/Makefile", disk) && valid("env PATH=/gone/bin ls", disk))
        // A file a redirection writes may not be there yet.
        #expect(valid("ls > /Users/me/new/out.txt", disk) && !valid("ls > out.txt; cat /gone/x", disk))
        // An unclosed quote is not read as words.
        #expect(valid(#"echo "unclosed /gone"#, disk))
    }

    @Test func aProgramNamedByAPathMustBeThere() {
        let disk = probe(files: ["/Users/me/project/notes.txt"], programs: ["/Users/me/project/build.sh", "/usr/bin/env"])
        #expect(valid("./build.sh --release", disk) && !valid("./missing.sh", disk) && !valid("./notes.txt", disk))
        #expect(valid("/usr/bin/env ls", disk) && valid("FOO=1 ./build.sh", disk) && !valid("FOO=1 ./gone.sh", disk))
        #expect(valid("make && ./build.sh", disk) && !valid("make && ./gone.sh", disk))
    }

    @Test func whatTheRecordSays() {
        #expect(!GhostValidation.ranWell(Entry(line: "x", lastRun: 1, successes: 0, lastExit: 1)))
        #expect(GhostValidation.ranWell(Entry(line: "x", lastRun: 1, successes: 1, lastExit: 130)))
        #expect(!GhostValidation.ranWell(Entry(line: "x", lastRun: 1, successes: 3, lastExit: 127)))
        #expect(GhostValidation.ranWell(Entry(line: "x", lastRun: 1, successes: 0, lastExit: nil)))
        // The first that passes wins, in the record's order.
        let disk = probe(folders: ["/Users/me/project/src"])
        let candidates = [Entry(line: "cd gone", lastRun: 3, successes: 1, lastExit: 0), Entry(line: "cd failed", lastRun: 2, lastExit: 1),
                          Entry(line: "cd src", lastRun: 1, successes: 1, lastExit: 0)]
        #expect(GhostValidation.first(candidates, cwd: cwd, home: home, probe: disk, mayShow: { _ in true })?.line == "cd src")
        #expect(GhostValidation.first(candidates, cwd: cwd, home: home, probe: disk, mayShow: { $0 != "cd src" }) == nil)
    }
}
