// Stand-in for next-server (start-server.ts): sets the title, handles SIGINT/SIGTERM, not SIGHUP. Prints a line
// a second (a dev server's log) and watches its folder, like a dev server's file watcher.
const fs = require('fs'), path = require('path');
process.title = 'next-server (v16.4.0) ' + (process.argv[2] || 'fg');
const log = (m) => fs.appendFileSync(path.join(__dirname, 'signals.log'), `${Date.now()/1000} next-server ${process.pid} ${m}\n`);
const cleanup = (sig) => { log('got ' + sig); process.exit(sig === 'SIGINT' ? 130 : 143); };
process.on('SIGINT', cleanup); process.on('SIGTERM', cleanup);
process.stdout.on('error', (e) => log('stdout error ' + e.code));
fs.watch(__dirname, () => {});
let n = 0;
setInterval(() => { try { process.stdout.write(`ready - tick ${n++}\n`); } catch (e) { log('write threw ' + e.code); } }, 1000);
