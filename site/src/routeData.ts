import { defineRouteMiddleware } from '@astrojs/starlight/route-data';
import { faqItems, jsonLd } from './lib/structured-data';

// Structured data for search engines, added to Starlight's <head> for each page.
export const onRequest = defineRouteMiddleware((context) => {
	const route = context.locals.starlightRoute;
	const site = context.site;
	if (!site) return;
	const id = route.id;

	// Every documentation page: where it sits.
	if (id === 'docs' || id.startsWith('docs/')) {
		const trail = [
			{ name: 'Next Term', item: new URL('/', site).href },
			{ name: 'Documentation', item: new URL('/docs/', site).href },
		];
		if (id !== 'docs') trail.push({ name: route.entry.data.title, item: new URL(context.url.pathname, site).href });
		route.head.push(
			jsonLd({
				'@context': 'https://schema.org',
				'@type': 'BreadcrumbList',
				itemListElement: trail.map((crumb, index) => ({
					'@type': 'ListItem',
					position: index + 1,
					name: crumb.name,
					item: crumb.item,
				})),
			})
		);
	}

	// The FAQ: questions and answers read from the page itself, so the two never differ.
	if (id === 'docs/faq' && route.entry.body) {
		route.head.push(
			jsonLd({
				'@context': 'https://schema.org',
				'@type': 'FAQPage',
				mainEntity: faqItems(route.entry.body).map(({ question, answer }) => ({
					'@type': 'Question',
					name: question,
					acceptedAnswer: { '@type': 'Answer', text: answer },
				})),
			})
		);
	}
});
