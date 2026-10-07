import { withFacts } from './facts';

/** A `<script type="application/ld+json">` head entry. `<` is escaped so no value can end the script. */
export function jsonLd(data: object) {
	return {
		tag: 'script' as const,
		attrs: { type: 'application/ld+json' },
		content: JSON.stringify(data).replace(/</g, '\\u003c'),
	};
}

/** Markdown (as written in these docs) to plain text, for structured data and llms.txt. */
export function plainText(markdown: string) {
	return markdown
		.replace(/<[^>]+>/g, '') // <kbd> and other inline HTML: keep the text
		.replace(/!\[[^\]]*\]\([^)]*\)/g, '') // images
		.replace(/\[([^\]]+)\]\([^)]*\)/g, '$1') // links: keep the words
		.replace(/`([^`]+)`/g, '$1')
		.replace(/\*\*([^*]+)\*\*/g, '$1')
		.replace(/^\s*(?:[-*]|\d+\.)\s+/gm, '')
		.replace(/\s+/g, ' ')
		.trim();
}

/** The questions (`## …?` or `### …?`) and their answers in a Markdown page, its facts filled in. */
export function faqItems(markdown: string) {
	const items: { question: string; answer: string }[] = [];
	let current: { question: string; lines: string[] } | undefined;
	const flush = () => {
		if (current) items.push({ question: current.question, answer: plainText(current.lines.join('\n')) });
		current = undefined;
	};
	for (const line of withFacts(markdown).split('\n')) {
		const question = /^#{2,3}\s+(.*\?)\s*$/.exec(line);
		if (question) {
			flush();
			current = { question: plainText(question[1]!), lines: [] };
		} else if (/^#{1,6}\s/.test(line)) {
			flush();
		} else if (current) {
			current.lines.push(line);
		}
	}
	flush();
	return items.filter((item) => item.answer.length > 0);
}
