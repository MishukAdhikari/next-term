// @ts-check
import { readFileSync } from 'node:fs';
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { ExpressiveCodeTheme } from '@astrojs/starlight/expressive-code';

// The site's address, in one place. Canonical URLs, Open Graph tags, the sitemap, robots.txt,
// llms.txt and the JSON-LD all read it from here (as Astro's `site`). To move the site, change
// this line and the server name in your web server config; nothing else.
const SITE = 'https://next-term.mishuk.me';
const REPO = 'https://github.com/MishukAdhikari/next-term';

// Code blocks use the app's own colours (Next Dark) in dark mode.
const nextDark = ExpressiveCodeTheme.fromJSONString(
	readFileSync(new URL('./src/themes/next-dark.json', import.meta.url), 'utf8')
);

export default defineConfig({
	site: SITE,
	trailingSlash: 'always',
	integrations: [
		starlight({
			title: 'Next Term',
			description:
				'Next Term is a native macOS terminal and code editor for running AI coding agents side by side, with status for every tab.',
			logo: { src: './src/assets/logo.png', alt: '' },
			favicon: '/favicon.png',
			social: [{ icon: 'github', label: 'Next Term on GitHub', href: REPO }],
			editLink: { baseUrl: `${REPO}/edit/main/site/` },
			lastUpdated: true,
			credits: false,
			disable404Route: true,
			titleDelimiter: '—',
			customCss: ['./src/styles/custom.css'],
			routeMiddleware: './src/routeData.ts',
			components: {
				Footer: './src/components/Footer.astro',
			},
			expressiveCode: {
				themes: [nextDark, 'github-light'],
				styleOverrides: {
					borderRadius: '6px',
					codeFontFamily: "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Monaco, Consolas, monospace",
					uiFontFamily:
						"-apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, Roboto, 'Helvetica Neue', Arial, sans-serif",
				},
			},
			head: [
				{ tag: 'link', attrs: { rel: 'apple-touch-icon', href: '/apple-touch-icon.png' } },
				{ tag: 'meta', attrs: { name: 'theme-color', content: '#1E1F22' } },
				{ tag: 'meta', attrs: { name: 'author', content: 'Mishuk Adhikari' } },
				{ tag: 'meta', attrs: { property: 'og:image', content: `${SITE}/og.jpg` } },
				{ tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
				{ tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
				{
					tag: 'meta',
					attrs: {
						property: 'og:image:alt',
						content:
							'Next Term: a macOS window with a project sidebar, Claude’s proposed edit shown as a side-by-side diff with Accept and Reject, and terminal tabs below.',
					},
				},
				{ tag: 'meta', attrs: { name: 'twitter:image', content: `${SITE}/og.jpg` } },
				{ tag: 'link', attrs: { rel: 'describedby', type: 'text/plain', href: '/llms.txt', title: 'llms.txt' } },
			],
			sidebar: [
				{
					label: 'Get started',
					items: [
						{ slug: 'docs', label: 'Overview' },
						{ slug: 'docs/getting-started' },
						{ slug: 'docs/switching' },
						{ slug: 'docs/updates' },
					],
				},
				{
					label: 'Agents',
					items: [{ slug: 'docs/agent-status' }, { slug: 'docs/agents' }, { slug: 'docs/orchestration' }],
				},
				{
					label: 'Editor & diffs',
					items: [
						{ slug: 'docs/editor' },
						{ slug: 'docs/diffs' },
						{ slug: 'docs/search' },
						{ slug: 'docs/layouts' },
					],
				},
				{
					label: 'Projects & git',
					items: [{ slug: 'docs/projects-and-git' }, { slug: 'docs/command-line' }],
				},
				{
					label: 'Reference',
					items: [
						{ slug: 'docs/keyboard-shortcuts' },
						{ slug: 'docs/settings' },
						{ slug: 'docs/security-and-privacy' },
						{ slug: 'docs/faq' },
					],
				},
				{
					label: 'Compare',
					items: [
						{ slug: 'compare', label: 'Overview' },
						{ slug: 'compare/vs-code' },
						{ slug: 'compare/jetbrains' },
						{ slug: 'compare/phpstorm' },
						{ slug: 'compare/pycharm' },
						{ slug: 'compare/cursor' },
						{ slug: 'compare/devin-desktop' },
						{ slug: 'compare/zed' },
						{ slug: 'compare/warp' },
						{ slug: 'compare/iterm2' },
						{ slug: 'compare/ghostty' },
					],
				},
			],
		}),
	],
});
