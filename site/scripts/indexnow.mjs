#!/usr/bin/env node
// Tells the IndexNow search engines (Bing, Yandex, Seznam, Naver, Yep and others; not Google) which pages
// changed, so they recrawl them within minutes instead of days. Bing's index also feeds ChatGPT search,
// Copilot and DuckDuckGo.
//
// Run it yourself, after a deploy is live. Nothing else runs it: not the build, not CI.
//
//   npm run indexnow                          every page in the live sitemap
//   npm run indexnow -- / /docs/agents/       only the pages that changed (preferred for small updates)
//   npm run indexnow -- --dry-run             show what would be sent; send nothing
//
// Options: --endpoint <url> sends to another IndexNow endpoint (default https://api.indexnow.org/indexnow,
// which shares each ping with every participating engine).
//
// It reads the site's address from astro.config.mjs (SITE) and the key from src/config.ts (INDEXNOW_KEY),
// checks that https://<site>/<key>.txt is live, then POSTs the URLs. Node 22 or later; no dependencies.
// Protocol: https://www.indexnow.org/documentation

import { readFileSync } from 'node:fs';

const DEFAULT_ENDPOINT = 'https://api.indexnow.org/indexnow';
const MAX_URLS_PER_POST = 10_000;
const root = new URL('..', import.meta.url);

function fail(message) {
	console.error(`indexnow: ${message}`);
	process.exit(1);
}

function readConstant(file, name) {
	const text = readFileSync(new URL(file, root), 'utf8');
	const match = new RegExp(`const ${name} = '([^']+)'`).exec(text);
	if (!match) fail(`could not find ${name} in ${file}`);
	return match[1];
}

// Arguments --------------------------------------------------------------------------------------------
const args = process.argv.slice(2);
let dryRun = false;
let endpoint = DEFAULT_ENDPOINT;
const paths = [];
for (let i = 0; i < args.length; i++) {
	const arg = args[i];
	if (arg === '--dry-run') dryRun = true;
	else if (arg === '--endpoint') endpoint = args[++i] ?? fail('--endpoint needs a URL');
	else if (arg === '--help' || arg === '-h') {
		console.log('Usage: npm run indexnow -- [--dry-run] [--endpoint <url>] [path or URL …]');
		process.exit(0);
	} else if (arg.startsWith('--')) fail(`unknown option ${arg}`);
	else paths.push(arg);
}

const site = new URL(readConstant('astro.config.mjs', 'SITE'));
const key = readConstant('src/config.ts', 'INDEXNOW_KEY');
if (!/^[A-Za-z0-9-]{8,128}$/.test(key)) fail('INDEXNOW_KEY must be 8–128 letters, digits or dashes');
const keyLocation = new URL(`/${key}.txt`, site).href;

async function get(url) {
	const response = await fetch(url, { signal: AbortSignal.timeout(20_000), redirect: 'follow' });
	return { status: response.status, text: await response.text() };
}

/** Every <loc> in the live sitemap index and the sitemaps it lists. */
async function sitemapUrls() {
	const locs = (xml) =>
		[...xml.matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/g)].map((m) => m[1].replaceAll('&amp;', '&'));
	const index = await get(new URL('/sitemap-index.xml', site));
	if (index.status !== 200) fail(`${site.origin}/sitemap-index.xml answered ${index.status}`);
	const urls = [];
	for (const sitemap of locs(index.text)) {
		const page = await get(sitemap);
		if (page.status !== 200) fail(`${sitemap} answered ${page.status}`);
		urls.push(...locs(page.text));
	}
	return urls;
}

// URLs -------------------------------------------------------------------------------------------------
let urls;
if (paths.length) {
	urls = paths.map((path) => {
		const url = new URL(path, site);
		if (url.host !== site.host) fail(`${path} is not on ${site.host}`);
		return url.href;
	});
} else {
	urls = await sitemapUrls();
}
urls = [...new Set(urls)];
if (urls.length === 0) fail('no URLs to send');

// The key file must be live, or every engine rejects the ping (403).
const keyFile = await get(keyLocation).catch((error) => ({ status: 0, text: String(error) }));
const keyLive = keyFile.status === 200 && keyFile.text.trim() === key;
if (!keyLive) {
	const problem = `${keyLocation} is not live (HTTP ${keyFile.status}${keyFile.status === 200 ? ', wrong contents' : ''}). Deploy the build first.`;
	if (!dryRun) fail(problem);
	console.warn(`warning: ${problem}`);
}

// Send -------------------------------------------------------------------------------------------------
const meaning = {
	200: 'OK: the URLs were received.',
	202: 'Accepted: received; the key is still being checked.',
	400: 'Bad request: the format is invalid.',
	403: 'Forbidden: the key file was not found or does not match the key.',
	422: 'Unprocessable: a URL is not on this host, or the key does not match the schema.',
	429: 'Too many requests: wait before sending again.',
};

for (let start = 0; start < urls.length; start += MAX_URLS_PER_POST) {
	const body = { host: site.host, key, keyLocation, urlList: urls.slice(start, start + MAX_URLS_PER_POST) };
	if (dryRun) {
		console.log(`Would POST ${body.urlList.length} URL(s) to ${endpoint}:`);
		console.log(JSON.stringify(body, null, 2));
		continue;
	}
	const response = await fetch(endpoint, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json; charset=utf-8' },
		body: JSON.stringify(body),
		signal: AbortSignal.timeout(30_000),
	});
	const detail = (await response.text()).trim();
	console.log(`${endpoint}: HTTP ${response.status}. ${meaning[response.status] ?? ''}`.trim());
	for (const url of body.urlList) console.log(`  ${url}`);
	if (detail) console.log(detail);
	if (response.status >= 400) process.exit(1);
}
