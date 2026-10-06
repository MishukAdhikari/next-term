import type { APIRoute } from 'astro';

// Everyone may crawl everything. AI crawlers are named explicitly, so the intent is clear to them and to
// anyone reading this file.
const AI_CRAWLERS = [
	'GPTBot',
	'OAI-SearchBot',
	'ChatGPT-User',
	'ClaudeBot',
	'Claude-SearchBot',
	'Claude-User',
	'anthropic-ai',
	'PerplexityBot',
	'Perplexity-User',
	'Google-Extended',
	'Applebot-Extended',
	'CCBot',
];

export const GET: APIRoute = ({ site }) => {
	if (!site) throw new Error('Set `site` in astro.config.mjs');
	const text = [
		'User-agent: *',
		'Allow: /',
		'',
		...AI_CRAWLERS.flatMap((agent) => [`User-agent: ${agent}`]),
		'Allow: /',
		'',
		`Sitemap: ${new URL('/sitemap-index.xml', site).href}`,
		'',
	].join('\n');
	return new Response(text, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
