import Foundation

/// Which grammar a file gets, and how its comments look. Ids are shiki's (TextMate grammar) language ids.
public enum EditorLanguage {
    static let byName: [String: String] = [
        "dockerfile": "docker", "containerfile": "docker", "makefile": "make", "gnumakefile": "make",
        "cmakelists.txt": "cmake", "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby", "vagrantfile": "ruby",
        "brewfile": "ruby", "commit_editmsg": "git-commit", "merge_msg": "git-commit", "tag_editmsg": "git-commit",
        "git-rebase-todo": "git-rebase", ".bashrc": "shellscript", ".bash_profile": "shellscript",
        ".zshrc": "shellscript", ".zshenv": "shellscript", ".zprofile": "shellscript", ".zlogin": "shellscript",
        ".profile": "shellscript", ".envrc": "shellscript", ".editorconfig": "ini", ".gitconfig": "ini",
        ".npmrc": "ini", ".vimrc": "viml", "tsconfig.json": "jsonc", "jsconfig.json": "jsonc",
        ".eslintrc": "jsonc", ".babelrc": "jsonc", "devcontainer.json": "jsonc", "artisan": "php",
        "go.mod": "go", "cargo.lock": "toml", "poetry.lock": "toml", "pipfile": "toml", ".prettierrc": "json",
        "justfile": "just", ".justfile": "just", "uv.lock": "toml", "pdm.lock": "toml", "bun.lock": "jsonc",
        "yarn.lock": "yaml", "composer.lock": "json", "flake.lock": "json", "deno.lock": "json",
        "package.resolved": "json",
        // Python tooling.
        "pipfile.lock": "json", "pixi.lock": "yaml", ".condarc": "yaml", ".flake8": "ini", ".pylintrc": "ini",
        ".pypirc": "ini", ".flaskenv": "dotenv", "env.example": "dotenv", "env.sample": "dotenv",
    ]

    static let byExtension: [String: String] = [
        "php": "php", "phtml": "php", "html": "html", "htm": "html", "xhtml": "html", "css": "css", "scss": "scss",
        "less": "less", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "ts": "typescript",
        "mts": "typescript", "cts": "typescript", "tsx": "tsx", "jsx": "jsx", "json": "json", "jsonc": "jsonc",
        "json5": "json5", "jsonl": "jsonl", "ndjson": "jsonl", "ipynb": "json", "md": "markdown", "markdown": "markdown",
        "yml": "yaml", "yaml": "yaml", "toml": "toml", "sh": "shellscript", "bash": "shellscript",
        "zsh": "shellscript", "command": "shellscript", "fish": "fish", "ps1": "powershell", "psm1": "powershell",
        "py": "python", "pyi": "python", "pyw": "python", "go": "go", "rs": "rust", "swift": "swift", "sql": "sql",
        "xml": "xml", "plist": "xml", "svg": "xml", "xsd": "xml", "xsl": "xml", "xib": "xml", "storyboard": "xml",
        "csproj": "xml", "java": "java", "kt": "kotlin", "kts": "kotlin", "c": "c", "h": "c", "cpp": "cpp",
        "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp", "cs": "csharp", "m": "objective-c",
        "lua": "lua", "vue": "vue", "svelte": "svelte", "graphql": "graphql", "gql": "graphql", "ini": "ini",
        "cfg": "ini", "properties": "ini", "diff": "diff", "patch": "diff", "env": "dotenv", "pl": "perl",
        "pm": "perl", "r": "r", "dart": "dart", "erl": "erlang", "hrl": "erlang", "hs": "haskell", "scala": "scala",
        "sc": "scala", "clj": "clojure", "cljs": "clojure", "cljc": "clojure", "edn": "clojure", "groovy": "groovy",
        "gradle": "groovy", "hcl": "hcl", "tf": "terraform", "tfvars": "terraform", "nix": "nix", "proto": "proto",
        "prisma": "prisma", "twig": "twig", "astro": "astro", "csv": "csv", "log": "log", "vim": "viml",
        "cmake": "cmake", "http": "http", "rest": "http", "dockerfile": "docker", "mk": "make", "rb": "ruby",
        "rake": "ruby", "gemspec": "ruby", "ru": "ruby", "zig": "zig", "ml": "ocaml", "mli": "ocaml", "jl": "julia",
        // Templates and framework languages.
        "mdx": "mdx", "liquid": "liquid", "hbs": "handlebars", "handlebars": "handlebars", "mustache": "handlebars",
        "jinja": "jinja", "jinja2": "jinja", "j2": "jinja", "njk": "jinja", "nunjucks": "jinja",
        "erb": "erb", "rhtml": "erb", "haml": "haml", "pug": "pug", "jade": "pug", "cshtml": "razor", "razor": "razor",
        "edge": "edge", "templ": "templ", "marko": "marko", "gjs": "glimmer-js", "gts": "glimmer-ts",
        "styl": "stylus", "stylus": "stylus", "sass": "sass", "pcss": "postcss", "postcss": "postcss",
        "coffee": "coffee", "just": "just", "ex": "elixir", "exs": "elixir", "svx": "markdown",
        // Data, docs, diagrams and graph queries in RAG projects. `.cql` stays plain: Neo4j and Cassandra both use it.
        "tsv": "tsv", "tab": "tsv", "rst": "rst", "mmd": "mermaid", "mermaid": "mermaid", "cypher": "cypher",
        "cyp": "cypher", "rq": "sparql", "sparql": "sparql", "ttl": "turtle", "jsonld": "json", "cff": "yaml",
        "ipy": "python",
        // Notebooks are JSON until they get a view of their own.
        "ipynb": "json",
        // Prompt files: Dotprompt is Handlebars under YAML front matter; Cursor rules are Markdown.
        "prompt": "handlebars", "prompty": "prompty", "mdc": "markdown",
        // No grammar of their own yet: HTML colours the markup around the template tags.
        "latte": "html", "tpl": "html", "gohtml": "html", "gotmpl": "html", "tmpl": "html", "ejs": "html", "eta": "html",
        "heex": "html", "eex": "html", "leex": "html",
    ]

    /// The grammar for a file, from its name, and for scripts without an extension, its `#!` line.
    public static func id(forFileName name: String, firstLine: String = "") -> String? {
        let lower = name.lowercased()
        if lower.hasSuffix(".blade.php") { return "blade" }
        if lower.hasSuffix(".component.html") { return "angular-html" }
        if lower.hasSuffix(".component.ts") { return "angular-ts" }
        if let known = byName[lower] { return known }
        if lower == ".env" || lower.hasPrefix(".env.") { return "dotenv" }
        if lower.hasPrefix("dockerfile.") || lower.hasSuffix(".dockerfile") { return "docker" }
        // pip's requirement files, by the names VS Code's Python extension gives them.
        if lower.contains("requirements") && (lower.hasSuffix(".txt") || lower.hasSuffix(".in"))
            || lower.contains("constraints") && lower.hasSuffix(".txt")
            || lower.hasPrefix("requirements") && lower.hasSuffix(".lock") { return "pip-requirements" }
        // A copy kept as an example (connections.json.example, phpunit.xml.dist): the name inside decides.
        for suffix in [".example", ".sample", ".template", ".dist"] where lower.hasSuffix(suffix) && lower.count > suffix.count {
            return id(forFileName: String(name.dropLast(suffix.count)), firstLine: firstLine)
        }
        let ext = (lower as NSString).pathExtension
        if !ext.isEmpty, let known = byExtension[ext] { return known }
        return shebang(firstLine)
    }

    static let byInterpreter: [String: String] = [
        "sh": "shellscript", "bash": "shellscript", "zsh": "shellscript", "dash": "shellscript", "ksh": "shellscript",
        "fish": "fish", "python": "python", "pypy": "python", "node": "javascript", "bun": "javascript",
        "deno": "javascript", "php": "php", "ruby": "ruby", "perl": "perl", "lua": "lua",
    ]

    static func shebang(_ line: String) -> String? {
        guard line.hasPrefix("#!") else { return nil }
        let words = line.dropFirst(2).split(separator: " ").map { ($0 as Substring).split(separator: "/").last.map(String.init) ?? "" }
        let program = words.first == "env" ? words.dropFirst().first { !$0.hasPrefix("-") } ?? "" : words.first ?? ""
        let stem = program.replacingOccurrences(of: #"[0-9.]+$"#, with: "", options: .regularExpression)
        // A PEP 723 script: `#!/usr/bin/env -S uv run --script`.
        if stem == "uv" { return words.contains("run") ? "python" : nil }
        return byInterpreter[stem]
    }

    /// The languages named on a Markdown file's code fences ("```python", "``` py", "~~~yaml"), lowercased.
    /// The grammar colours a fence only once that language is loaded, and the engine loads it only when it
    /// sees the name on the line being coloured with no space after the backticks: so the editor loads these
    /// before the first line instead.
    public static func fenceLanguages(in text: String) -> Set<String> {
        let source = text as NSString
        return Set(fence.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            source.substring(with: $0.range(at: 1)).lowercased()
        })
    }

    static let fence = try! NSRegularExpression(pattern: #"^[ \t]*(?:`{3,}|~{3,})[ \t]*([A-Za-z0-9_+#.-]+)"#, options: [.anchorsMatchLines])

    /// How a language comments out a line: a prefix, or for markup a prefix and suffix around it.
    public struct CommentStyle: Equatable, Sendable {
        public let prefix: String
        public let suffix: String
    }

    public static func commentStyle(for language: String?) -> CommentStyle? {
        guard let language else { return nil }
        switch language {
        case "php", "javascript", "typescript", "tsx", "jsx", "go", "rust", "swift", "java", "kotlin", "c", "cpp",
             "csharp", "objective-c", "scss", "less", "dart", "scala", "groovy", "proto", "prisma", "jsonc", "json5",
             "zig", "stylus", "sass", "templ", "angular-ts", "glimmer-js", "glimmer-ts", "cypher":
            return CommentStyle(prefix: "//", suffix: "")
        case "python", "ruby", "shellscript", "fish", "powershell", "yaml", "toml", "perl", "r", "make", "docker",
             "dotenv", "cmake", "nix", "hcl", "terraform", "julia", "graphql", "git-commit", "git-rebase", "ini",
             "coffee", "just", "elixir", "sparql", "turtle", "pip-requirements":
            return CommentStyle(prefix: "#", suffix: "")
        case "mermaid": return CommentStyle(prefix: "%%", suffix: "")
        case "rst": return CommentStyle(prefix: "..", suffix: "")
        case "sql", "lua", "haskell": return CommentStyle(prefix: "--", suffix: "")
        case "clojure": return CommentStyle(prefix: ";;", suffix: "")
        case "erlang": return CommentStyle(prefix: "%", suffix: "")
        case "viml": return CommentStyle(prefix: "\"", suffix: "")
        case "html", "html-derivative", "xml", "markdown", "vue", "svelte", "astro":
            return CommentStyle(prefix: "<!--", suffix: "-->")
        case "css": return CommentStyle(prefix: "/*", suffix: "*/")
        case "blade", "edge": return CommentStyle(prefix: "{{--", suffix: "--}}")
        case "twig", "jinja", "prompty": return CommentStyle(prefix: "{#", suffix: "#}")
        case "handlebars": return CommentStyle(prefix: "{{!--", suffix: "--}}")
        case "erb": return CommentStyle(prefix: "<%#", suffix: "%>")
        case "razor": return CommentStyle(prefix: "@*", suffix: "*@")
        case "pug": return CommentStyle(prefix: "//-", suffix: "")
        case "haml": return CommentStyle(prefix: "-#", suffix: "")
        case "mdx", "liquid", "angular-html", "marko": return CommentStyle(prefix: "<!--", suffix: "-->")
        case "ocaml": return CommentStyle(prefix: "(*", suffix: "*)")
        default: return nil
        }
    }

    /// Comments out the lines (each without its line break), or uncomments them if every non-blank line
    /// is already commented: ⌘/ in an IDE. The comment mark goes at the shallowest indent, so the block
    /// keeps its shape.
    public static func toggleComment(_ lines: [String], style: CommentStyle) -> [String] {
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return lines }
        func isCommented(_ line: String) -> Bool {
            let body = line.drop { $0 == " " || $0 == "\t" }
            return body.hasPrefix(style.prefix) && (style.suffix.isEmpty || body.trimmingCharacters(in: .whitespaces).hasSuffix(style.suffix))
        }
        if content.allSatisfy(isCommented) {
            return lines.map { line in
                guard isCommented(line) else { return line }
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                var body = String(line.dropFirst(indent.count).dropFirst(style.prefix.count))
                if body.hasPrefix(" ") { body.removeFirst() }
                if !style.suffix.isEmpty {
                    let trailing = body.reversed().prefix { $0 == " " || $0 == "\t" }.count
                    body = String(body.dropLast(trailing).dropLast(style.suffix.count))
                    if body.hasSuffix(" ") { body.removeLast() }
                }
                return indent + body
            }
        }
        let indent = content.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        return lines.map { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            let head = line.prefix(indent)
            let body = line.dropFirst(indent)
            return head + style.prefix + " " + body + (style.suffix.isEmpty ? "" : " " + style.suffix)
        }
    }

    /// The indent unit a file already uses: a tab, or the most common step between space indents.
    public static func indentUnit(of text: String, default fallback: String = "    ") -> String {
        var tabs = 0, spaced = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        var scanned = 0
        text.enumerateLines { line, stop in
            scanned += 1
            if scanned > 2000 { stop = true }
            if line.hasPrefix("\t") { tabs += 1; return }
            let spaces = line.prefix { $0 == " " }.count
            guard spaces < line.count else { return } // blank or whitespace-only lines say nothing
            if spaces > 0 { spaced += 1 }
            let step = abs(spaces - previous)
            if step == 2 || step == 4 || step == 8 { steps[step, default: 0] += 1 }
            previous = spaces
        }
        if tabs > spaced { return "\t" }
        guard spaced > 0, let common = steps.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key else { return fallback }
        return String(repeating: " ", count: common)
    }
}
