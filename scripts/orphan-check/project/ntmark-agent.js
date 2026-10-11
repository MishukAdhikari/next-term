// Agent stand-in: runs in the tab's foreground like `claude`, and runs its tool commands the way Claude Code's
// Bash tool does (a shell spawned detached: its own session, no terminal), here `npm run dev` in the background.
// argv[2] == 'cleanup': on SIGHUP/SIGTERM it ends its tool commands' process groups first (a careful agent).
// The dev server is named after the agent ("agent" or "agentclean"), so the check can tell rows H and I apart.
const { spawn } = require('child_process'), fs = require('fs'), path = require('path');
const careful = process.argv[2] === 'cleanup';
const tag = careful ? 'agentclean' : 'agent';
const log = (m) => fs.appendFileSync(path.join(__dirname, 'signals.log'), `${Date.now()/1000} ${tag} ${process.pid} ${m}\n`);
const tool = spawn('/bin/zsh', ['-c', 'npm run dev -- ' + tag + ' > ' + path.join(__dirname, tag + '-dev.out') + ' 2>&1'],
  { cwd: __dirname, detached: true, stdio: 'ignore' });
console.log('agent stand-in', process.pid, 'tool shell', tool.pid);
if (careful) {
  for (const s of ['SIGHUP', 'SIGTERM']) process.on(s, () => { log('got ' + s + ', ending tools'); try { process.kill(-tool.pid, 'SIGTERM'); } catch {} process.exit(0); });
}
process.stdin.resume(); // reads the terminal, as an agent's UI does
setInterval(() => {}, 1000);
