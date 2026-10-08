import Foundation
import Testing
@testable import NextTermCore

@Suite struct FileReferenceTests {
    let files: Set<String> = ["/p/src/agent/graph.py", "/p/tests/test_eval.py", "/p/app.py", "/p/web/agent.ts"]
    func resolve(_ link: String, _ row: String? = nil) -> FileReference? {
        FileReference.resolve(link: link, row: row,
                              absolute: { $0.hasPrefix("/") ? $0 : "/p/" + ($0.hasPrefix("./") ? String($0.dropFirst(2)) : $0) },
                              exists: { files.contains($0) })
    }

    @Test func aPythonTracebackOpensAtItsLine() {
        let row = #"  File "/p/src/agent/graph.py", line 42, in call_model"#
        #expect(resolve("/p/src/agent/graph.py", row) == FileReference(path: "/p/src/agent/graph.py", line: 42))
        // Relative paths in a traceback, and the link being the quoted path.
        #expect(resolve("src/agent/graph.py", #"  File "src/agent/graph.py", line 7, in <module>"#)?.line == 7)
    }

    @Test func pytestMypyAndRuffPositionsAfterTheLink() {
        #expect(resolve("tests/test_eval.py", "tests/test_eval.py:42: in test_answer") == FileReference(path: "/p/tests/test_eval.py", line: 42))
        #expect(resolve("app.py", "app.py:42:7: error: Incompatible types") == FileReference(path: "/p/app.py", line: 42, column: 7))
        // When the terminal includes the numbers in the link itself.
        #expect(resolve("app.py:42:7:") == FileReference(path: "/p/app.py", line: 42, column: 7))
        #expect(resolve("tests/test_eval.py:42:") == FileReference(path: "/p/tests/test_eval.py", line: 42))
        // Lines as Copy Path with Line gives them: the first one.
        #expect(resolve("app.py:42-48") == FileReference(path: "/p/app.py", line: 42))
        #expect(resolve("app.py", "see app.py:42-48") == FileReference(path: "/p/app.py", line: 42))
    }

    @Test func aLanggraphGraphReferenceNamesASymbol() {
        #expect(resolve("./src/agent/graph.py:graph") == FileReference(path: "/p/src/agent/graph.py", symbol: "graph"))
        #expect(resolve("./web/agent.ts:graph")?.symbol == "graph")
        // Not a module: nothing to open.
        #expect(resolve("./src/agent/missing.py:graph") == nil)
        #expect(resolve("README:graph") == nil)
    }

    @Test func aPlainPathWithoutAPlaceOpensAtTheTop() {
        #expect(resolve("app.py", "see app.py for details") == FileReference(path: "/p/app.py"))
        #expect(resolve("nothing.py") == nil)
    }

    @Test func theRightFrameWhenARowNamesTheFileTwice() {
        // The traceback regex matches the frame for this link only.
        let row = #"  File "/p/app.py", line 3, in a; File "/p/src/agent/graph.py", line 9, in b"#
        #expect(resolve("/p/src/agent/graph.py", row)?.line == 9)
    }

    @Test func definitionsInPythonAndTypeScript() {
        let python = """
            from langgraph.graph import StateGraph

            def call_model(state):
                return state

            class Router:
                pass

            builder = StateGraph(dict)
            graph = builder.compile()
            graph_two: CompiledGraph = builder.compile()
            if graph == other: pass
            """
        #expect(FileReference.definitionLine(of: "call_model", in: python) == 3)
        #expect(FileReference.definitionLine(of: "Router", in: python) == 6)
        #expect(FileReference.definitionLine(of: "graph", in: python) == 10)
        #expect(FileReference.definitionLine(of: "graph_two", in: python) == 11)
        #expect(FileReference.definitionLine(of: "missing", in: python) == nil)
        let typescript = """
            import { StateGraph } from "@langchain/langgraph";
            export async function callModel() {}
            export const graph = workflow.compile();
            """
        #expect(FileReference.definitionLine(of: "callModel", in: typescript) == 2)
        #expect(FileReference.definitionLine(of: "graph", in: typescript) == 3)
        // A name with regex characters is taken literally.
        #expect(FileReference.definitionLine(of: "$state", in: "const $state = 1") == 1)
    }
}
