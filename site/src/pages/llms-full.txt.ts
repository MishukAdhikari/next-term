import type { APIRoute } from 'astro';
import { DOWNLOAD_DMG, REPO, SUMMARY, VERSION } from '../config';
import { comparisonsInOrder, docsInOrder, markdownForLlms, pageUrl } from '../lib/docs';

// /llms-full.txt: every documentation page, then every comparison page, as Markdown in one file,
// generated from the same content as the HTML pages at build time, so the two never drift apart.
export const GET: APIRoute = async ({ site }) => {
	if (!site) throw new Error('Set `site` in astro.config.mjs');
	const pages = [...(await docsInOrder()), ...(await comparisonsInOrder())];
	const parts = [
		'# Next Term documentation',
		'',
		`> ${SUMMARY}`,
		'',
		`Version ${VERSION}. Download: ${DOWNLOAD_DMG}. Source: ${REPO}. Licence: MIT.`,
		`This file contains every page of ${new URL('/docs/', site).href} in reading order, then the comparisons with other tools from ${new URL('/compare/', site).href}.`,
		'',
	];
	for (const entry of pages) {
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
