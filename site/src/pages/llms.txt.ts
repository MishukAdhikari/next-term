import type { APIRoute } from 'astro';
import { DOWNLOAD_DMG, MIN_MACOS, RELEASES_LATEST, REPO, SUMMARY, TAGLINE, VERSION } from '../config';
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
		['Get started', ['docs/getting-started', 'docs/updates']],
		['Agents', ['docs/agent-status', 'docs/agents', 'docs/orchestration']],
		['Editor and diffs', ['docs/editor', 'docs/diffs', 'docs/search', 'docs/layouts']],
		['Projects and git', ['docs/projects-and-git', 'docs/remote', 'docs/command-line']],
		['Reference', ['docs/keyboard-shortcuts', 'docs/settings', 'docs/security-and-privacy', 'docs/faq']],
		['Compared with other tools', comparisons.map((entry) => entry.id)],
	];
	const text = [
		'# Next Term',
		'',
		`> ${SUMMARY}`,
		'',
		`${TAGLINE}. Current version: ${VERSION}. Requires ${MIN_MACOS}, Apple Silicon or Intel (universal app, about 3 MB). Free and open source under the MIT licence. It brings no AI model of its own and needs no account: it runs the agent command-line tools the user installs (Claude Code, Codex, Gemini CLI, Qwen Code, Command Code, Junie, opencode and others).`,
		'',
		'Key facts:',
		'',
		'- Each terminal tab shows its agent’s state: a spinner while working (read from the agent’s own screen), a green check when done, an amber “!” when it waits on a decision, a red cross when a command failed. Decisions also arrive as macOS notifications.',
		'- Claude Code, Gemini CLI and Qwen Code connect to Next Term as their IDE (local only, fresh token per launch): they see the selected lines, and their proposed edits open as side-by-side diffs to accept (⌘↩) or reject.',
		'- Send to Agent (⌥⌘K) types a reference to the selection or files into any agent’s prompt in that agent’s syntax.',
		'- Next Term is an MCP server (`nxtrm mcp`, 13 tools) for orchestration: one agent can list every project and tab with each agent’s state, open projects, start agents in new tabs or split panes, send prompts and keys, wait for them, read their screens, and use the editor (selection, open files, open a file at a line). It registers itself in Claude Code, Codex, Gemini CLI, Qwen Code, Cursor Agent, opencode, Copilot CLI, Amp, Junie and Command Code. Local only: a 0600 Unix socket, no network port.',
		'- Built in: split panes (⌘D, ⇧⌘D), Go to File (⌘P, fuzzy), a code editor for 112 languages, side-by-side git diffs with hunk staging (⌥⌘G), a project sidebar with git status and +/− line counts, Find and Replace in Files, the `nxtrm` command, configurable layouts and shortcuts, and checksum-verified self-updates.',
		'- Not released yet: agent sessions per project (coming next) and remote access to the MCP server for agents outside the Mac (coming later).',
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
