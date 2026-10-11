// Ignores SIGHUP (a handler that does nothing), reads the terminal and writes to it every second: what happens to
// such a survivor once its terminal is gone (does it spin?).
const fs = require('fs'), path = require('path');
process.title = 'ntmark-hupnode';
const log = (m) => fs.appendFileSync(path.join(__dirname, 'signals.log'), `${Date.now()/1000} hupnode ${process.pid} ${m}\n`);
process.on('SIGHUP', () => log('got SIGHUP, ignoring'));
process.stdin.on('data', () => {}); process.stdin.on('end', () => log('stdin end')); process.stdin.on('error', (e) => log('stdin error ' + e.code));
process.stdout.on('error', (e) => log('stdout error ' + e.code));
let n = 0, errs = 0;
setInterval(() => { try { process.stdout.write(`tick ${n++}\n`); } catch (e) { if (errs++ < 3) log('write threw ' + e.code); } }, 1000);
