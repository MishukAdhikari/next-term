import type { APIRoute, GetStaticPaths } from 'astro';
import { INDEXNOW_KEY } from '../config';

// The IndexNow key file, /<key>.txt, holding the key and nothing else. Search engines that receive a ping
// from scripts/indexnow.mjs fetch it to check the ping came from this site.
export const getStaticPaths = (() => [{ params: { indexnow: INDEXNOW_KEY } }]) satisfies GetStaticPaths;

export const GET: APIRoute = () =>
	new Response(INDEXNOW_KEY, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
