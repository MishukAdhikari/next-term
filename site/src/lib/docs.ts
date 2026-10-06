import { getCollection, type CollectionEntry } from 'astro:content';

/** The documentation pages in reading order (the sidebar’s order in astro.config.mjs). */
export const DOCS_ORDER = [
	'docs/getting-started',
	'docs/updates',
	'docs/agent-status',
	'docs/agents',
	'docs/orchestration',
	'docs/editor',
	'docs/diffs',
	'docs/search',
	'docs/layouts',
	'docs/projects-and-git',
	'docs/command-line',
	'docs/keyboard-shortcuts',
	'docs/settings',
	'docs/security-and-privacy',
	'docs/faq',
] as const;

/** Every documentation page except the docs home, in reading order; pages not in the list come last. */
export async function docsInOrder(): Promise<CollectionEntry<'docs'>[]> {
	const entries = (await getCollection('docs')).filter((entry) => entry.id.startsWith('docs/'));
	const rank = (id: string) => {
		const index = (DOCS_ORDER as readonly string[]).indexOf(id);
		return index === -1 ? DOCS_ORDER.length : index;
	};
	return entries.sort((a, b) => rank(a.id) - rank(b.id) || a.id.localeCompare(b.id));
}

/** The comparison pages in reading order (the sidebar’s order in astro.config.mjs), index first. */
export const COMPARE_ORDER = [
	'compare',
	'compare/vs-code',
	'compare/jetbrains',
	'compare/phpstorm',
	'compare/pycharm',
	'compare/cursor',
	'compare/devin-desktop',
	'compare/zed',
	'compare/warp',
	'compare/iterm2',
	'compare/ghostty',
] as const;

/** Every comparison page, the index included, in reading order; pages not in the list come last. */
export async function comparisonsInOrder(): Promise<CollectionEntry<'docs'>[]> {
	const entries = (await getCollection('docs')).filter(
		(entry) => entry.id === 'compare' || entry.id.startsWith('compare/')
	);
	const rank = (id: string) => {
		const index = (COMPARE_ORDER as readonly string[]).indexOf(id);
		return index === -1 ? COMPARE_ORDER.length : index;
	};
	return entries.sort((a, b) => rank(a.id) - rank(b.id) || a.id.localeCompare(b.id));
}

/** A page’s public URL. */
export function pageUrl(id: string, site: URL) {
	return new URL(`/${id}/`, site).href;
}

/**
 * The Markdown of a page made readable as plain text for language models: inline HTML reduced to its
 * words, screenshots to their descriptions, and site links made absolute.
 */
export function markdownForLlms(body: string, site: URL) {
	return body
		.replace(/<span class="nt-soon">([^<]+)<\/span>\s*/g, '[$1] ')
		.replace(/<span class="nt-mark[^"]*">([^<]+)<\/span>\s*/g, '$1 ')
		.replace(/<kbd>([^<]+)<\/kbd>/g, '$1')
		.replace(/&#96;/g, '`')
		.replace(/!\[([^\]]*)\]\([^)]*\)/g, (_, alt: string) => (alt ? `[Screenshot: ${alt}]` : ''))
		.replace(/\]\((\/[^)\s]*)\)/g, (_, path: string) => `](${new URL(path, site).href})`)
		.replace(/\n{3,}/g, '\n\n')
		.trim();
}
