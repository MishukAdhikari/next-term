import { defineCollection } from 'astro:content';
import { docsLoader, i18nLoader } from '@astrojs/starlight/loaders';
import { docsSchema, i18nSchema } from '@astrojs/starlight/schema';

export const collections = {
	docs: defineCollection({ loader: docsLoader(), schema: docsSchema() }),
	// English UI strings that differ from Starlight’s defaults (src/content/i18n/en.json).
	i18n: defineCollection({ loader: i18nLoader(), schema: i18nSchema() }),
};
