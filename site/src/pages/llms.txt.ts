import type { APIRoute } from 'astro';
import { DOWNLOAD_DMG, DOWNLOAD_SIZE, INSTALLED_SIZE, MIN_MACOS, RELEASES_LATEST, REPO, SUMMARY, TAGLINE, VERSION } from '../config';
import { comparisonsInOrder, docsInOrder, pageUrl } from '../lib/docs';

// /llms.txt in the llmstxt.org format: a summary, then the pages worth reading, with what each covers.
export const GET: APIRoute = async ({ site }) => {
	if (!site) throw new Error('Set `site` in astro.config.mjs');
	const docs = await docsInOrder();
	const comparisons = await comparisonsInOrder();
	const pages = [...docs, ...comparisons];
	const link = (id: string) => pages.find((entry) => entry.id === id);
	const line = (id: string) => {
		const entry = link(id);
		return entry ? `- [${entry.data.title}](${pageUrl(id, site)}): ${entry.data.description ?? ''}` : '';
	};
	const groups: [string, string[]][] = [
		['Get started', ['docs/getting-started', 'docs/switching', 'docs/updates']],
		['Agents', ['docs/agent-status', 'docs/agents', 'docs/orchestration']],
		['Editor and diffs', ['docs/editor', 'docs/diffs', 'docs/search', 'docs/layouts']],
		['Projects and git', ['docs/projects-and-git', 'docs/remote', 'docs/command-line']],
		['Guides', ['docs/langchain-and-langgraph']],
		['Reference', ['docs/keyboard-shortcuts', 'docs/settings', 'docs/security-and-privacy', 'docs/faq']],
		['Compared with other tools', comparisons.map((entry) => entry.id)],
	];
	const text = [
		'# Next Term',
		'',
		`> ${SUMMARY}`,
		'',
		`${TAGLINE}. Current version: ${VERSION}. Requires ${MIN_MACOS}, Apple Silicon or Intel (universal app: about ${DOWNLOAD_SIZE} to download, ${INSTALLED_SIZE} installed). Free and open source under the MIT licence. It brings no AI model of its own and needs no account: it runs the agent command-line tools the user installs (Claude Code, Codex, Gemini CLI, Qwen Code, Command Code, Junie, opencode and others).`,
		'',
		'Key facts:',
		'',
		'- Each terminal tab shows its agent’s state: a spinner while working (read from the agent’s own screen for Claude Code, Codex, Command Code and Gemini CLI, from output timing for other agents), a green check when done, an amber “!” when it waits on a decision, a red cross when a command failed. Decisions also arrive as macOS notifications.',
		'- Claude Code, Gemini CLI and Qwen Code connect to Next Term as their IDE (local only, fresh token per launch): they see the selected lines, and their proposed edits open as side-by-side diffs to accept (⌘↩) or reject.',
		'- Send to Agent (⌥⌘K) types a reference to the selection or files into any agent’s prompt in that agent’s syntax.',
		'- Next Term is an MCP server (`nxtrm mcp`, 18 local tools, plus 7 for servers) for orchestration: one agent can list every project and tab with each agent’s state, open projects, start agents in new tabs or split panes, send prompts and keys, wait for them, read their screens, answer their questions (guarded by a question id, so an answer never lands on a newer question), read the projects’ files, search them and see their git status and diffs (inside open projects only, secrets files refused and secret-looking values masked), and use the editor (selection, open files, open a file at a line). It registers itself in Claude Code, Codex, Gemini CLI, Qwen Code, Cursor Agent, opencode, Copilot CLI, Amp, Junie and Command Code. Local only: a 0600 Unix socket, no network port.',
		'- Remote tabs (File › New Remote Tab…, ⌥⌘T) open a terminal tab on the user’s own server through the system ssh and their ~/.ssh/config. With tmux or herdr the session keeps running while the Mac sleeps or the network drops, and the tab reconnects. Agents there get the same status marks, and 7 more MCP tools (list_hosts, add_host, remove_host, check_host, new_remote_tab, host_sessions, host_changes) let agents work with servers. Host keys are never accepted silently, no password is stored, nothing is installed on the server, every port forward is cleared, and Next Term’s MCP socket and editor links are never forwarded (ssh agent forwarding follows the user’s ssh config).',
		'- Agent sessions: the Welcome window (and ⌥⌘O) lists the conversations Claude Code, Codex, Command Code, Gemini CLI, Qwen Code, opencode, Cursor Agent and Copilot CLI kept for each project, to resume in a tab in the right folder (or fork, where the agent can), or to go to the tab a session is open in. An Agent Sessions group in the project sidebar shows the newest five with a running badge, and continues an agent’s latest session in the folder. Only titles, dates, branches and models are read.',
		'- Git: the branch popup (⌥⌘B) checks out, creates, updates, commits and pushes, asks before changing files under a working agent and stashes uncommitted changes when switching. The Git Log (⌥⌘L) shows the commit history as a graph in a tab, with text, branch, author, date and path filters, the selected commit in full and its diffs. View › Annotate with Git Blame shows who last changed each line beside the line numbers. Git › Git Commands lists every git command Next Term ran. The gutter marks added, changed and deleted lines against the last commit.',
		'- The editor colours code with 112 TextMate grammars (prompt placeholders and Jinja or Mustache templates inside Python strings, Prompty, Mermaid, Cypher, requirements files and more), opens Jupyter notebooks read-only with their saved outputs (no kernel, nothing runs), and opens JSON Lines, CSV and TSV files over 2 MB in a read-only head view of their first 1,000 rows. ⌘-click opens paths in terminal output at a line, Python tracebacks, pytest and ruff lines included.',
		'- Databases: a Databases group in the project sidebar lists the databases a project names in its own files (Laravel and Herd DB_* keys, DATABASE_URL and its family, Prisma, Drizzle, Supabase, Vercel-linked projects, SQLite files), found offline without running project code, local or remote by host, passwords masked. SQLite files open read-only in a viewer; hand-offs open TablePlus, or mysql or psql in a new tab for local databases. Passwords are never shown, logged, copied or handed to an agent.',
		'- Import (Next Term › Import Settings and Shortcuts…) reads VS Code, Cursor, Devin Desktop, JetBrains IDEs, Zed, iTerm2, Ghostty and Terminal: shortcut sets, the user’s own key changes, settings, fonts, terminal colours and recent projects, previewed first and undone in one click. It only reads, on this Mac, and never opens files that can hold secrets.',
		'- Also built in: split panes (⌘D, ⇧⌘D), Go to File (⌘P, fuzzy), side-by-side git diffs with hunk staging (⌥⌘G), a project sidebar with git status and +/− line counts, Find and Replace in Files, tabs that show a dev server’s port (File › Open Served URL), the `nxtrm` command, configurable layouts and shortcuts, and self-updates checked against the release key’s signature.',
		'- Install in one line: `curl -fsSL https://nxtrm.mishuk.me/install.sh | bash`. It checks that the release’s checksum is signed with the Next Term release key and that the download matches it, then copies the app to Applications, without sudo. On its own, Next Term makes only a daily update check to GitHub and a background `git fetch` from each open project’s own remotes; both can be turned off.',
		'- Not released yet: a server’s files in the editor and sidebar, and remote access to the MCP server for agents outside the Mac, coming later.',
		'',
		`Download (the latest disk image): ${DOWNLOAD_DMG}`,
		`Release notes: ${RELEASES_LATEST}`,
		`Source code: ${REPO}`,
		'',
		...groups.flatMap(([title, ids]) => [`## ${title}`, '', ...ids.map(line).filter(Boolean), '']),
		'## Optional',
		'',
		`- [All documentation in one file](${new URL('/llms-full.txt', site).href}): every page above as Markdown.`,
		`- [Documentation home](${new URL('/docs/', site).href}): an overview of every page.`,
		`- [Release notes](${REPO}/releases): what changed in each version.`,
		`- [README](${REPO}#readme): the project overview on GitHub.`,
		'',
	].join('\n');
	return new Response(text, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
