import { DOWNLOAD_SIZE, INSTALLED_SIZE } from '../config';

/** Facts from src/config.ts that the Markdown pages write as {{NAME}}, so each is set in one place. */
const FACTS: Record<string, string> = { DOWNLOAD_SIZE, INSTALLED_SIZE };

/** Markdown with every {{NAME}} filled in. A name that isn't a fact stops the build. */
export function withFacts(markdown: string) {
	return markdown.replace(/\{\{([A-Z][A-Z_]*)\}\}/g, (token, name: string) => {
		const value = FACTS[name];
		if (value === undefined) throw new Error(`${token} is not a fact: add it to FACTS in src/lib/facts.ts`);
		return value;
	});
}

type MarkdownNode = { type: string; value?: string; children?: MarkdownNode[] };

/** A remark plugin that fills in the facts in a page's text (code is left as written). */
export function remarkFacts() {
	const fill = (node: MarkdownNode) => {
		if (node.type === 'text' && node.value) node.value = withFacts(node.value);
		node.children?.forEach(fill);
	};
	return fill;
}
