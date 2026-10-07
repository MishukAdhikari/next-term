import Foundation
import Testing
@testable import NextTermCore

@Suite struct NotebookTests {
    /// A 4×3 PNG.
    static let png = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAYAAAC09K7GAAAAEklEQVR4nGM4EaDxHxkzEBQAAKyxGvWvi7wBAAAAAElFTkSuQmCC"

    /// Shaped like LangChain's RAG tutorial as saved by JupyterLab: nbformat 4.5, cell ids, source as lists
    /// of lines, a `%pip` cell, prints, a value, a graph drawn as a PNG, and a failed call.
    static let langchainRAG = #"""
    {
     "cells": [
      {
       "cell_type": "markdown",
       "id": "a1b2c3",
       "metadata": {},
       "source": [
        "# Build a Retrieval Augmented Generation (RAG) App\n",
        "\n",
        "This tutorial shows how to build a simple **Q&A** app over a [text data source](https://lilianweng.github.io/posts/2023-06-23-agent/).\n",
        "\n",
        "### Installation\n",
        "\n",
        "- `langchain-text-splitters`\n",
        "- `langgraph`\n",
        "\n",
        "| Component | Package |\n",
        "|---|---|\n",
        "| Loader | langchain-community |\n",
        "| Graph | langgraph |"
       ]
      },
      {
       "cell_type": "code",
       "execution_count": 1,
       "id": "d4e5f6",
       "metadata": {},
       "outputs": [
        {
         "name": "stdout",
         "output_type": "stream",
         "text": [
          "Note: you may need to restart the kernel to use updated packages.\n"
         ]
        }
       ],
       "source": [
        "%pip install --quiet --upgrade langchain-text-splitters langchain-community langgraph"
       ]
      },
      {
       "cell_type": "code",
       "execution_count": null,
       "id": "g7h8i9",
       "metadata": {},
       "outputs": [],
       "source": "import getpass\nimport os\n\nif not os.environ.get(\"OPENAI_API_KEY\"):\n  os.environ[\"OPENAI_API_KEY\"] = getpass.getpass(\"Enter API key for OpenAI: \")"
      },
      {
       "cell_type": "code",
       "execution_count": 3,
       "id": "j1k2l3",
       "metadata": {},
       "outputs": [
        {
         "name": "stdout",
         "output_type": "stream",
         "text": [
          "Total characters: 43047\n"
         ]
        },
        {
         "name": "stdout",
         "output_type": "stream",
         "text": [
          "Split blog post into 66 sub-documents.\n"
         ]
        },
        {
         "name": "stderr",
         "output_type": "stream",
         "text": [
          "USER_AGENT environment variable not set, consider setting it to identify your requests.\n"
         ]
        },
        {
         "data": {
          "text/html": [
           "<div><b>66</b></div>"
          ],
          "text/plain": [
           "66"
          ]
         },
         "execution_count": 3,
         "metadata": {},
         "output_type": "execute_result"
        }
       ],
       "source": [
        "import bs4\n",
        "from langchain_community.document_loaders import WebBaseLoader\n",
        "\n",
        "loader = WebBaseLoader(web_paths=(\"https://lilianweng.github.io/posts/2023-06-23-agent/\",))\n",
        "docs = loader.load()\n",
        "print(f\"Total characters: {len(docs[0].page_content)}\")\n",
        "len(all_splits)"
       ]
      },
      {
       "cell_type": "code",
       "execution_count": 4,
       "id": "m4n5o6",
       "metadata": {},
       "outputs": [
        {
         "data": {
          "image/png": "\#(NotebookTests.png)",
          "text/plain": [
           "<IPython.core.display.Image object>"
          ]
         },
         "metadata": {
          "image/png": {
           "width": 200
          }
         },
         "output_type": "display_data"
        }
       ],
       "source": [
        "from IPython.display import Image, display\n",
        "\n",
        "display(Image(graph.get_graph().draw_mermaid_png()))"
       ]
      },
      {
       "cell_type": "code",
       "execution_count": 5,
       "id": "p7q8r9",
       "metadata": {},
       "outputs": [
        {
         "ename": "KeyError",
         "evalue": "'question'",
         "output_type": "error",
         "traceback": [
          "\u001b[0;31m---------------------------------------------------------------------------\u001b[0m",
          "\u001b[0;31mKeyError\u001b[0m                                  Traceback (most recent call last)",
          "Cell \u001b[0;32mIn[5], line 1\u001b[0m\n\u001b[0;32m----> 1\u001b[0m response \u001b[38;5;241m=\u001b[39m graph\u001b[38;5;241m.\u001b[39minvoke({\u001b[38;5;124m\"\u001b[39m\u001b[38;5;124mquery\u001b[39m\u001b[38;5;124m\"\u001b[39m: \u001b[38;5;124m\"\u001b[39m\u001b[38;5;124mWhat is Task Decomposition?\u001b[39m\u001b[38;5;124m\"\u001b[39m})\n",
          "\u001b[0;31mKeyError\u001b[0m: 'question'"
         ]
        }
       ],
       "source": [
        "response = graph.invoke({\"query\": \"What is Task Decomposition?\"})"
       ]
      },
      {
       "cell_type": "raw",
       "id": "s1t2u3",
       "metadata": {},
       "source": [
        "---\n",
        "sidebar_position: 0\n",
        "---"
       ]
      }
     ],
     "metadata": {
      "kernelspec": {
       "display_name": "Python 3 (ipykernel)",
       "language": "python",
       "name": "python3"
      },
      "language_info": {
       "codemirror_mode": {"name": "ipython", "version": 3},
       "file_extension": ".py",
       "mimetype": "text/x-python",
       "name": "python",
       "nbconvert_exporter": "python",
       "pygments_lexer": "ipython3",
       "version": "3.11.9"
      }
     },
     "nbformat": 4,
     "nbformat_minor": 5
    }
    """#

    @Test func readsALangChainRAGNotebook() throws {
        let notebook = try Notebook.parse(Data(Self.langchainRAG.utf8))
        #expect(notebook.format == 4 && notebook.language == "python" && notebook.kernelName == "Python 3 (ipykernel)")
        #expect(notebook.cells.map(\.kind) == [.markdown, .code, .code, .code, .code, .code, .raw])
        #expect(notebook.cells[0].source.hasPrefix("# Build a Retrieval Augmented Generation (RAG) App\n\nThis tutorial"))
        #expect(notebook.cells[1].executionCount == 1 && notebook.cells[2].executionCount == nil)
        // Source given as one string.
        #expect(notebook.cells[2].source.hasPrefix("import getpass\nimport os\n\nif not os.environ"))
        #expect(notebook.cells[2].outputs.isEmpty)

        // Two prints to stdout are one block, as Jupyter shows them; stderr is its own; the value prefers plain text.
        let run = notebook.cells[3].outputs
        #expect(run.count == 3)
        #expect(run[0] == .init(kind: .stream(stderr: false), content: .text(.init(head: "Total characters: 43047\nSplit blog post into 66 sub-documents."))))
        #expect(run[1].kind == .stream(stderr: true))
        #expect(run[2] == .init(kind: .result(executionCount: 3), content: .text(.init(head: "66"))))

        // The image stays base64 until drawn; its size comes from its header, and the notebook's width is kept.
        guard case let .image(image) = notebook.cells[4].outputs.first?.content else { return #expect(Bool(false), "an image output") }
        #expect(image.mime == "image/png" && image.pixelWidth == 4 && image.pixelHeight == 3 && image.width == 200 && image.height == nil)
        #expect(image.data()?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)

        // The error: name and message, and the traceback without its colour codes.
        let error = try #require(notebook.cells[5].outputs.first)
        #expect(error.kind == .error(name: "KeyError", value: "'question'"))
        guard case let .text(traceback) = error.content else { return #expect(Bool(false), "a traceback") }
        #expect(!traceback.head.contains("\u{1B}") && !traceback.head.contains("[0;31m"))
        #expect(traceback.head.contains("----> 1 response = graph.invoke({\"query\": \"What is Task Decomposition?\"})"))
        #expect(traceback.head.hasSuffix("KeyError: 'question'"))
        #expect(notebook.cells[6].source == "---\nsidebar_position: 0\n---")
    }

    @Test func otherKernelsAndMissingMetadata() throws {
        let deno = #"{"cells": [{"cell_type": "code", "execution_count": 1, "metadata": {}, "outputs": [], "source": ["const x: number = 1;"]}],"#
            + #""metadata": {"kernelspec": {"display_name": "Deno", "language": "typescript", "name": "deno"}}, "nbformat": 4, "nbformat_minor": 2}"#
        #expect(try Notebook.parse(Data(deno.utf8)).language == "typescript")
        // Only language_info, as some tools write it.
        let info = #"{"cells": [], "metadata": {"language_info": {"name": "R"}}, "nbformat": 4, "nbformat_minor": 4}"#
        #expect(try Notebook.parse(Data(info.utf8)).language == "r")
        let cling = #"{"cells": [], "metadata": {"kernelspec": {"language": "C++17", "name": "xcpp17"}}, "nbformat": 4, "nbformat_minor": 4}"#
        #expect(try Notebook.parse(Data(cling.utf8)).language == "cpp")
        // Nothing at all: the cells still read, without a language.
        let bare = #"{"cells": [{"cell_type": "code", "source": "print(1)"}, {"cell_type": "mystery", "source": "?"}]}"#
        let notebook = try Notebook.parse(Data(bare.utf8))
        #expect(notebook.language == nil && notebook.kernelName == nil)
        #expect(notebook.cells == [.init(kind: .code, source: "print(1)"), .init(kind: .raw, source: "?")])
    }

    @Test func readsNbformat3() throws {
        let old = #"""
        {
         "metadata": {"name": "old"},
         "nbformat": 3,
         "nbformat_minor": 0,
         "worksheets": [
          {
           "cells": [
            {"cell_type": "heading", "level": 2, "metadata": {}, "source": ["Setup"]},
            {"cell_type": "markdown", "metadata": {}, "source": ["Some *text*."]},
            {
             "cell_type": "code", "collapsed": false, "input": ["import numpy as np\n", "np.arange(3)"], "language": "python",
             "metadata": {}, "prompt_number": 2,
             "outputs": [
              {"output_type": "stream", "stream": "stdout", "text": ["hello\n"]},
              {"metadata": {}, "output_type": "pyout", "prompt_number": 2, "text": ["array([0, 1, 2])"]},
              {"metadata": {}, "output_type": "display_data", "png": "\#(NotebookTests.png)", "text": ["<matplotlib.figure.Figure at 0x10>"]},
              {"ename": "NameError", "evalue": "name 'y' is not defined", "output_type": "pyerr",
               "traceback": ["\u001b[1;31mNameError\u001b[0m: name 'y' is not defined"]}
             ]
            }
           ],
           "metadata": {}
          }
         ]
        }
        """#
        let notebook = try Notebook.parse(Data(old.utf8))
        #expect(notebook.format == 3 && notebook.language == "python")
        #expect(notebook.cells.map(\.kind) == [.markdown, .markdown, .code])
        #expect(notebook.cells[0].source == "## Setup")
        let code = notebook.cells[2]
        #expect(code.source == "import numpy as np\nnp.arange(3)" && code.executionCount == 2)
        #expect(code.outputs.count == 4)
        #expect(code.outputs[0] == .init(kind: .stream(stderr: false), content: .text(.init(head: "hello"))))
        #expect(code.outputs[1] == .init(kind: .result(executionCount: 2), content: .text(.init(head: "array([0, 1, 2])"))))
        guard case let .image(image) = code.outputs[2].content else { return #expect(Bool(false), "the plot") }
        #expect(image.pixelWidth == 4 && image.pixelHeight == 3)
        #expect(code.outputs[3] == .init(kind: .error(name: "NameError", value: "name 'y' is not defined"),
                                          content: .text(.init(head: "NameError: name 'y' is not defined"))))
    }

    @Test func malformedFilesSayWhy() {
        // Cut off halfway, as an interrupted save leaves it.
        let cut = String(Self.langchainRAG.prefix(400))
        let error = #expect(throws: Notebook.ReadError.self) { try Notebook.parse(Data(cut.utf8)) }
        guard case let .invalidJSON(reason) = error else { return #expect(Bool(false), "invalid JSON, not \(String(describing: error))") }
        #expect(!reason.isEmpty && error?.errorDescription?.contains("not valid JSON") == true, "\(reason)")
        #expect(throws: Notebook.ReadError.notANotebook) { try Notebook.parse(Data(#"{"name": "package.json"}"#.utf8)) }
        #expect(throws: Notebook.ReadError.notANotebook) { try Notebook.parse(Data("[1, 2]".utf8)) }
        #expect(Notebook.ReadError.tooLarge(bytes: 60_000_000).errorDescription?.contains("too large") == true)
    }

    @Test func readsFromDisk() throws {
        let dir = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-nb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rag.ipynb")
        try Data(Self.langchainRAG.utf8).write(to: file)
        #expect(try Notebook.read(contentsOf: file).cells.count == 7)
        #expect(throws: Notebook.ReadError.unreadable) { try Notebook.read(contentsOf: dir) }
        #expect(throws: Notebook.ReadError.unreadable) { try Notebook.read(contentsOf: dir.appendingPathComponent("gone.ipynb")) }
    }

    @Test func longOutputsKeepTheirStartAndEnd() {
        let text = (1...1000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let excerpt = Notebook.excerpt(text)
        let head = excerpt.head.components(separatedBy: "\n"), tail = excerpt.tail.components(separatedBy: "\n")
        #expect(head.count == Notebook.maxOutputLines - Notebook.tailLines && head.first == "line 1" && head.last == "line 160")
        #expect(excerpt.omittedLines == 800)
        #expect(tail.count == Notebook.tailLines && tail.first == "line 961" && tail.last == "line 1000")
        // Short text is whole, without its final newline.
        #expect(Notebook.excerpt("a\nb\n") == .init(head: "a\nb"))
        // A progress bar redrawn with \r shows its last state; a huge line is cut.
        #expect(Notebook.excerpt("  0%|   | 0/3\r 33%|█  | 1/3\r100%|███| 3/3\r\ndone\n").head == "100%|███| 3/3\ndone")
        let long = Notebook.excerpt(String(repeating: "7", count: 20_000)).head
        #expect(long.count == Notebook.maxLineLength + 2 && long.hasSuffix(" …"))
    }

    @Test func stripsTerminalEscapes() {
        #expect(Notebook.stripANSI("\u{1B}[0;31mKeyError\u{1B}[0m: 'x'") == "KeyError: 'x'")
        #expect(Notebook.stripANSI("\u{1B}[38;5;241m=\u{1B}[39m") == "=")
        #expect(Notebook.stripANSI("\u{1B}]8;;https://x.dev\u{07}link\u{1B}]8;;\u{1B}\\ end") == "link end")
        #expect(Notebook.stripANSI("\u{1B}(Bplain\u{1B}[?25l") == "plain")
        #expect(Notebook.stripANSI("no escapes ✓") == "no escapes ✓")
    }

    @Test func picksWhatAViewerCanShow() throws {
        func output(_ data: String, metadata: String = "{}") throws -> Notebook.Content? {
            let json = #"{"cells": [{"cell_type": "code", "source": "", "outputs": [{"output_type": "display_data", "data": \#(data), "metadata": \#(metadata)}]}]}"#
            return try Notebook.parse(Data(json.utf8)).cells.first?.outputs.first?.content
        }
        #expect(try output(#"{"text/markdown": "**Answer:** 42", "text/plain": "<IPython.core.display.Markdown object>"}"#)
                == .markdown("**Answer:** 42"))
        // HTML alone: its text, a row per line.
        #expect(try output(#"{"text/html": "<table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2 &amp; 3</td></tr></table><script>alert(1)</script>"}"#)
                == .text(.init(head: "a\tb\n1\t2 & 3")))
        #expect(try output(#"{"application/json": {"b": [1, 2], "a": "x"}}"#) == .text(.init(head: "{\n  \"a\" : \"x\",\n  \"b\" : [\n    1,\n    2\n  ]\n}")))
        // A widget with nothing to fall back on.
        let widget = #"{"application/vnd.jupyter.widget-view+json": {"model_id": "abc", "version_major": 2, "version_minor": 0}}"#
        guard case let .unsupported(mime, bytes) = try output(widget) else { return #expect(Bool(false), "a widget") }
        #expect(mime == "application/vnd.jupyter.widget-view+json" && bytes > 20)
    }

    @Test func imageSizesFromTheirHeaders() {
        #expect(Notebook.pixelSize(ofBase64: Self.png).map { [$0.0, $0.1] } == [4, 3])
        // Wrapped at 76 columns, as older notebooks store it.
        let wrapped = stride(from: 0, to: Self.png.count, by: 20).map { i in
            String(Self.png.dropFirst(i).prefix(20))
        }.joined(separator: "\n")
        #expect(Notebook.pixelSize(ofBase64: wrapped).map { [$0.0, $0.1] } == [4, 3])
        // A JPEG's frame header after its JFIF block: 500×300.
        #expect(Notebook.pixelSize(ofBase64: "/9j/4AAQSkZJRgABAQAAAQABAAD/wAARCAEsAfQDASIAAhEBAxEB/9k=").map { [$0.0, $0.1] } == [500, 300])
        #expect(Notebook.pixelSize(ofBase64: "R0lGODlhCgAUAIAAAP///wAAACwAAAAACgAUAAACAkQBADs=").map { [$0.0, $0.1] } == [10, 20])
        #expect(Notebook.pixelSize(ofBase64: "bm90IGFuIGltYWdl") == nil)
        #expect(Notebook.pixelSize(ofBase64: "") == nil)
    }

    @Test func markdownCellsKeepEverySectionAndLineUpTables() {
        let blocks = Notebook.markdownBlocks("## Installation\n\n```bash\n| not a table |\n```\n\n| Model | Score |\n|:--|--:|\n| gpt-4o | 0.91 |\n| llama | 0.8 |\nAfter.")
        #expect(blocks == [
            .heading(level: 2, text: "Installation"),
            .code("| not a table |"),
            .code("Model   Score\n" + String(repeating: "─", count: 6 + 2 + 5) + "\ngpt-4o  0.91\nllama   0.8"),
            .paragraph(depth: 0, text: "After."),
        ])
        // Release notes still drop what belongs on the release page.
        #expect(ReleaseNotes.blocks("## Installation\nRun it.") == [])
    }

    @Test func ipythonMagics() throws {
        let notebook = Notebook(cells: [], language: "python")
        func language(_ source: String) -> String? { notebook.language(of: .init(kind: .code, source: source)) }
        #expect(language("import os") == "python")
        #expect(language("%%bash\nls -la") == "shellscript")
        #expect(language("%%script bash\necho hi") == "shellscript")
        #expect(language("%%html\n<b>hi</b>") == "html")
        #expect(language("%%writefile app.js\nconsole.log(1)") == "javascript")
        #expect(language("%%time\nsum(range(10))") == "python")
        // Only Python kernels have magics.
        #expect(Notebook(cells: [], language: "r").language(of: .init(kind: .code, source: "%%bash\nls")) == "r")

        #expect(Notebook.magicPrefixLength("%pip install -qU langchain") == 4)
        #expect(Notebook.magicPrefixLength("!pip install faiss-cpu") == 1)
        #expect(Notebook.magicPrefixLength("    !ls") == 5)
        #expect(Notebook.magicPrefixLength("%%capture") == 9)
        #expect(Notebook.magicPrefixLength("x = 5 % 2") == nil)
        #expect(Notebook.magicPrefixLength("% 2") == nil)
        #expect(Notebook.magicPrefixLength("") == nil)
    }
}
