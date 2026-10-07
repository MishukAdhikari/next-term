// Facts about Next Term that several pages repeat. Change them here when a release ships.
// The site's own address is not here: it is `site` in astro.config.mjs (read as `Astro.site`).

export const APP_NAME = 'Next Term';
export const TAGLINE = 'The missing IDE for the terminal';
export const VERSION = '0.9.0';
export const MIN_MACOS = 'macOS 13 or later';
/**
 * The newest release's size, rounded, in MB as Finder counts them (1,000,000 bytes): its disk image
 * (NextTerm-x.y.z.dmg in `gh release view vX.Y.Z --json assets`) and the app once installed (Get Info
 * on Next Term.app). The release step measures both again when it sets VERSION; README.md says them
 * once too. Markdown pages write them as {{DOWNLOAD_SIZE}} and {{INSTALLED_SIZE}} (see src/lib/facts.ts).
 * Measured on 0.9.0: 16,216,508 and 43,125,169 bytes.
 */
export const DOWNLOAD_SIZE = '16 MB';
export const INSTALLED_SIZE = '43 MB';
export const AUTHOR = 'Mishuk Adhikari';
export const AUTHOR_URL = 'https://github.com/MishukAdhikari';
export const REPO = 'https://github.com/MishukAdhikari/next-term';
/** Always the newest release page; the DMG is attached there as NextTerm-x.y.z.dmg. */
export const RELEASES_LATEST = `${REPO}/releases/latest`;
/** The newest release's disk image itself: every release also carries NextTerm.dmg under that fixed name. */
export const DOWNLOAD_DMG = `${REPO}/releases/latest/download/NextTerm.dmg`;
export const DOWNLOAD_SHA256 = `${REPO}/releases/latest/download/NextTerm.dmg.sha256`;
export const RELEASE_NOTES = `${REPO}/releases/tag/v${VERSION}`;
export const LICENSE_URL = `${REPO}/blob/main/LICENSE`;

/**
 * The IndexNow key. The build publishes it as /<key>.txt, and scripts/indexnow.mjs sends it with each
 * ping so Bing and the other IndexNow engines can check the ping came from this site. It is public by
 * design (anyone can read the file); to change it, put any 8–128 letters, digits or dashes here.
 */
export const INDEXNOW_KEY = '851176fab7f883cc1789f08a5ef768c0';

/** One-sentence description used for the home page, JSON-LD and llms.txt. */
export const SUMMARY =
	'Next Term is a free, open-source (MIT) macOS IDE for AI coding agents: a native terminal and code editor that runs Claude Code, Codex, Gemini CLI and others side by side, shows which agent is working, done or waiting on you, and lets one agent run the others over MCP.';
