import { DOWNLOAD_SIZE, INSTALLED_SIZE } from '../config';

/** Facts from src/config.ts that the Markdown pages write as {{NAME}}, so each is set in one place. */
export const FACTS: Record<string, string> = { DOWNLOAD_SIZE, INSTALLED_SIZE };

/** Markdown with every {{NAME}} filled in. A name that isn't a fact stops the build. */
export function withFacts(markdown: string, facts = FACTS) {
	return markdown.replace(/\{\{([A-Z][A-Z_]*)\}\}/g, (token, name: string) => {
		const value = facts[name];
		if (value === undefined) throw new Error(`${token} is not a fact: add it to FACTS in src/lib/facts.ts`);
		return value;
	});
}

type MarkdownNode = { type: string; value?: string; children?: MarkdownNode[] };

/**
 * A remark plugin that fills in the facts in a page's text (code is left as written). astro.config.mjs
 * passes FACTS to it as its options: Astro keeps a page's rendered HTML between builds until the page
 * or the config changes, and options are part of the config, so a new value renders every page again.
 */
export function remarkFacts(facts: Record<string, string> = FACTS) {
	const fill = (node: MarkdownNode) => {
		if (node.type === 'text' && node.value) node.value = withFacts(node.value, facts);
		node.children?.forEach(fill);
	};
	return fill;
}
