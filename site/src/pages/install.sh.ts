import type { APIRoute } from 'astro';
import script from '../install.sh?raw';
import { VERSION } from '../config';

// /install.sh, for `curl -fsSL https://nxtrm.mishuk.me/install.sh | bash`. The script refuses a
// "latest" older than the site's own version, so pointing GitHub's latest at an old release can't roll
// installs back.
export const GET: APIRoute = () => {
	if (!script.includes('@@MIN_VERSION@@')) throw new Error('install.sh lost its @@MIN_VERSION@@ slot');
	return new Response(script.replace('@@MIN_VERSION@@', VERSION), {
		headers: { 'Content-Type': 'text/x-shellscript; charset=utf-8' },
	});
};
