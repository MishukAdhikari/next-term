// Stand-in for `next dev` (packages/next/src/cli/next-dev.ts): fork() the server with stdio 'inherit' (same
// process group and session), forward SIGINT/SIGTERM to it, no SIGHUP handler; kill the child on 'exit'.
const { fork } = require('child_process');
const path = require('path');
const fs = require('fs');
const log = (m) => fs.appendFileSync(path.join(__dirname, 'signals.log'), `${Date.now()/1000} nextdev ${process.pid} ${m}\n`);
const child = fork(path.join(__dirname, 'ntmark-nextserver.js'), [process.argv[2] || 'fg'], { stdio: 'inherit' });
const stop = (sig) => { log('got ' + sig); child.kill(sig); setTimeout(() => child.kill('SIGKILL'), 100); child.on('exit', () => process.exit(0)); };
process.on('SIGINT', () => stop('SIGINT'));
process.on('SIGTERM', () => stop('SIGTERM'));
process.on('exit', () => child.kill('SIGKILL'));
console.log('next dev stand-in', process.pid, 'forked next-server', child.pid);
