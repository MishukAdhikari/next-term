import type { APIRoute } from 'astro';
import { RELEASES_LATEST, REPO, SUMMARY, VERSION } from '../config';
import { docsInOrder, markdownForLlms, pageUrl } from '../lib/docs';

// /llms-full.txt: every documentation page as Markdown in one file, generated from the same content
// as the HTML pages at build time, so the two never drift apart.
export const GET: APIRoute = async ({ site }) => {
	if (!site) throw new Error('Set `site` in astro.config.mjs');
	const docs = await docsInOrder();
	const parts = [
		'# Next Term documentation',
		'',
		`> ${SUMMARY}`,
		'',
		`Version ${VERSION}. Download: ${RELEASES_LATEST}. Source: ${REPO}. Licence: MIT.`,
		`This file contains every page of ${new URL('/docs/', site).href} in reading order.`,
		'',
	];
	for (const entry of docs) {
		parts.push(
			'---',
			'',
			`# ${entry.data.title}`,
			'',
			`URL: ${pageUrl(entry.id, site)}`,
			'',
			entry.data.description ? `${entry.data.description}\n` : '',
			markdownForLlms(entry.body ?? '', site),
			''
		);
	}
	return new Response(parts.join('\n'), { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
