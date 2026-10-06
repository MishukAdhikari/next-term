import { defineRouteMiddleware } from '@astrojs/starlight/route-data';
import { faqItems, jsonLd } from './lib/structured-data';

/** A `BreadcrumbList` for a trail of pages, home first. */
function breadcrumbs(trail: { name: string; item: string }[]) {
	return jsonLd({
		'@context': 'https://schema.org',
		'@type': 'BreadcrumbList',
		itemListElement: trail.map((crumb, index) => ({
			'@type': 'ListItem',
			position: index + 1,
			name: crumb.name,
			item: crumb.item,
		})),
	});
}

// Structured data for search engines, added to Starlight's <head> for each page.
export const onRequest = defineRouteMiddleware((context) => {
	const route = context.locals.starlightRoute;
	const site = context.site;
	if (!site) return;
	const id = route.id;
	const home = { name: 'Next Term', item: new URL('/', site).href };
	const here = { name: route.entry.data.title, item: new URL(context.url.pathname, site).href };

	// The not-found page is served at every missing address, so it has no address of its own: drop the
	// canonical link and og:url Starlight gives it (they would point at /404/, which is itself a 404).
	if (id === '404') {
		route.head = route.head.filter(
			({ tag, attrs }) =>
				!(tag === 'link' && attrs?.rel === 'canonical') && !(tag === 'meta' && attrs?.property === 'og:url')
		);
		return;
	}

	// Every documentation page: where it sits.
	if (id === 'docs' || id.startsWith('docs/')) {
		const section = { name: 'Documentation', item: new URL('/docs/', site).href };
		route.head.push(breadcrumbs(id === 'docs' ? [home, section] : [home, section, here]));
	}

	// Every comparison page: where it sits.
	if (id === 'compare' || id.startsWith('compare/')) {
		const section = { name: 'Next Term compared', item: new URL('/compare/', site).href };
		route.head.push(breadcrumbs(id === 'compare' ? [home, section] : [home, section, here]));
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
