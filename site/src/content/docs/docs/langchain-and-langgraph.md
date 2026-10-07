---
title: Next Term for LangChain and LangGraph
description: "LangChain and LangGraph in Next Term: prompt templates in Python strings, notebooks, large datasets, langgraph dev tabs, tracebacks and LangSmith keys."
sidebar:
  label: LangChain and LangGraph
head:
  - tag: title
    content: LangChain and LangGraph in a macOS terminal — Next Term
---

There is nothing LangChain-specific to install. This page collects what Next Term’s editor and terminal already do for LangChain and LangGraph projects, and for other RAG projects (LlamaIndex, Haystack, CrewAI), and how to give your agents LangSmith.

## Prompts in Python strings

Prompt templates mostly live in Python strings, and the editor colours what is inside them:

- **Placeholders** such as `{context}` and `{question}` in a `ChatPromptTemplate` or any other string get their own colour, apart from the prompt’s text.
- **Jinja and Mustache templates** inside Python strings colour as templates: `{% for doc in documents %}`, `{{ doc.content }}`, `{# a note #}`, `{{name}}`. This works in plain, triple-quoted and raw strings. f-strings, where braces are Python, and docstrings are left alone, and an escaped JSON example such as `{{"nodes": [...]}}` is not taken for a template.
- **Template files** colour too: `.jinja`, `.j2` and `.jinja2`, Prompty (`.prompty`, with its front matter and `system:`/`user:` lines), Dotprompt (`.prompt`), Mustache and Handlebars.

## The other files in the project

| Files | How they open |
|---|---|
| `langgraph.json`, `package.json` | JSON |
| `pyproject.toml`, `uv.lock`, `poetry.lock`, `Pipfile` | TOML, keys coloured |
| `requirements.txt`, `requirements-dev.txt`, `constraints.txt` | pip requirements |
| `.env`, `.env.example`, `env.example` | dotenv, keys coloured |
| `SKILL.md`, `AGENTS.md`, Cursor rules (`.mdc`) | Markdown, front matter and code fences coloured from the moment the file opens |
| `.mmd`, and `mermaid` code fences | Mermaid, as `graph.get_graph().draw_mermaid()` writes it |
| `.cypher` (Neo4j), `.rq` (SPARQL), `.ttl` (Turtle) | Their own grammars |
| `.ipynb` | A notebook view (below) |
| `.jsonl`, `.csv`, `.tsv` over 2 MB | A head view of the first rows (below) |

See [112 languages](/docs/editor/#112-languages) for the full list.

## Notebooks

A Jupyter notebook opens as a notebook, read-only: Markdown laid out, code cells coloured in the kernel’s language, and each cell’s saved output below it, errors in red and images scaled to fit. Nothing runs; Next Term has no kernel. **Open as JSON** opens the file itself, and the view follows the file when an agent or Jupyter saves it. See [Jupyter notebooks](/docs/editor/#jupyter-notebooks).

## Datasets and exports

Evaluation sets, traces exported as JSON Lines and CSV results get big. A `.jsonl`, `.ndjson`, `.csv` or `.tsv` file over 2 MB opens in a read-only head view: the first 1,000 rows as a table, as quickly for a 2 GB file as for a small one, with a column per top-level key in JSON Lines.

- A line that is not JSON is marked in red with the reason; the rest of the file still reads.
- **Load More** reads the next 1,000 rows, and **Search** filters the loaded ones.
- **Copy As** copies the selected rows as JSON or CSV, and <kbd>⌥⌘K</kbd> sends the file to your agent at the selected rows’ lines.

Smaller files open in the editor, with colours. See [Large data files](/docs/editor/#large-data-files).

## `langgraph dev` in a tab

Run `langgraph dev` (or `npm run dev`, `uvicorn`, `langgraph up`) in a tab. Once it prints its address, the tab’s title shows the port, such as “langgraph · :2024”, and **Shell › Open Served URL** opens `http://127.0.0.1:2024` in your browser.

- **No spinner while it serves.** The spinner is for agents. A server that stops with an error while you are in another tab gets a red cross.
- **Links in its output open with <kbd>⌘</kbd>-click:** the API, the API docs and the Studio UI. The Studio link, with the server’s address nested inside it (`https://smith.langchain.com/studio/?baseUrl=http://127.0.0.1:2024`), is found as one link, and so are LangSmith run links, Weights & Biases Weave links and MLflow run links.
- **Studio and Safari.** Links open in your default browser. LangChain’s docs say Safari cannot load Studio for a server on your Mac, because it blocks an HTTPS page from reaching plain-HTTP `127.0.0.1`. Copy the Studio link into Chrome or another Chromium browser instead (in Chrome 142 and later, allow “Local network access” in the site’s settings), or start the server with `langgraph dev --tunnel` and add the tunnel’s address to Studio’s allowed origins.
- **Agents can run it too.** An orchestrating agent can start `langgraph dev` in a new tab (`new_tab`), find its address in `list_tabs` (`served_url`) and read its output (`read_tab`). See [Orchestrate agents (MCP)](/docs/orchestration/).

## Tracebacks and graph references

<kbd>⌘</kbd>-click a path in terminal output to open it in the editor:

- A Python traceback’s `File "/…/src/agent/graph.py", line 42, in call_model` opens at line 42, at the frame you clicked.
- pytest’s `tests/test_graph.py:42:` and ruff’s `graph.py:42:7:` open at their line.
- A graph reference as `langgraph.json` writes it, `./src/agent/graph.py:graph`, opens at the definition of `graph`: a `def`, a `class`, or an assignment such as `graph = builder.compile()`.

## API keys

- **Agent session titles** in the Welcome window show ••• in place of a LangSmith key (`lsv2_pt_…`, `lsv2_sk_…`), and of OpenAI, Anthropic, Hugging Face, Groq, Tavily, Replicate, xAI and Pinecone keys.
- **Imports** never bring over a value that looks like a key.
- **The MCP tools** never read environment files (`.env`, `.env.local`, `prod.env`; `.env.example` is read), and mask keys in the file text, search results and diffs they hand an agent.
- **The IDE link** never sends a selection from a `.env` file to Claude Code, Gemini CLI or Qwen Code.

What Next Term does not do: it does not hide keys a program prints in the terminal, and an agent can still read `.env` with its own tools. See [Security and privacy](/docs/security-and-privacy/).

## Folders that stay out of the way

In a git repository, Go to File and [Find in Files](/docs/search/#which-files-are-searched) list the files git does, so your `.gitignore` decides (LangGraph’s project template ignores `.langgraph_api/`). Outside a repository they skip the state that LangGraph, MLflow, Weights & Biases and Jupyter write next to a project: `.langgraph_api`, `mlruns`, `mlartifacts`, `wandb` and `.ipynb_checkpoints`, along with `.venv`, `__pycache__` and `node_modules`.

## Give your agents LangSmith

Next Term does not add LangSmith’s MCP server, or any other vendor’s, to your agents’ settings: its own MCP server is for running agents. LangChain publishes its own way in for each agent ([LangSmith Remote MCP](https://docs.langchain.com/langsmith/langsmith-remote-mcp)):

- **Claude Code:** in Claude Code, `/plugin marketplace add langchain-ai/langchain-plugins`, then `/plugin install langsmith-mcp@langchain-plugins` for the hosted MCP server, or `langsmith-skills@langchain-plugins` for LangSmith’s skills. Or add the server yourself, then run `/mcp` in Claude Code to sign in:

  ```sh
  claude mcp add --transport http -s user langsmith https://api.smith.langchain.com/mcp
  ```

  Accounts in the EU use `https://eu.api.smith.langchain.com/mcp`.
- **Codex:** LangSmith’s docs say its hosted MCP server does not work with Codex, and point to the [`langsmith` command-line tool](https://github.com/langchain-ai/langsmith-cli) instead. LangSmith’s skills come to Codex through the same plugin marketplace, [`langchain-ai/langchain-plugins`](https://github.com/langchain-ai/langchain-plugins): `codex plugin marketplace add langchain-ai/langchain-plugins`, then `codex plugin add langsmith-skills@langchain-plugins`.

If traces do not arrive in LangSmith, check three things the Python SDK is strict about:

- `LANGSMITH_TRACING=true` must be lowercase; `True` does nothing.
- A leftover `LANGCHAIN_TRACING_V2=false` turns tracing off, even with `LANGSMITH_TRACING=true`.
- `LANGSMITH_ENDPOINT` takes no trailing slash.
