// A tmux server belongs to ONE test process, and it dies with it.
//
// MEASURED 23/11 on avell: `tmux -L wa-run-live-1304985` was still running 41 HOURS after its parent died,
// holding a session called 'live' and a live `wa --db ~/.wasm-agent/tmp/wa-run-live-PNgegf/ledger.db`. It was
// started by `scripts/test-discriminates.mjs` from a base tree, and the orchestrator removed it by hand with
// `kill-server`. Nothing in the process could have run: the parent was killed outright, so neither the row's
// `finally` nor an `exit` handler fires.
//
// So there are two mechanisms, and neither is enough alone:
//
//   * THE HANDLERS below cover a normal exit, SIGINT, SIGTERM, SIGHUP and an uncaught exception - every path a
//     row, a node or a CI cancellation takes.
//   * THE RECLAIM covers the SIGKILL path that nothing inside the process can catch. The socket name carries
//     the owning pid, so "is the owner alive" is asked of the kernel (`kill(pid, 0)`) rather than trusted to a
//     heartbeat, and a server whose owner is gone is killed by the next row that starts one.
//
// A SOCKET IS KILLED ONLY WHEN NO PROCESS HAS ITS PID, which is what makes the reclaim safe enough to run at
// the start of every pty row. The residual risk is pid reuse - a live process that happens to carry a dead
// owner's pid - and the window is the length of one test run; the alternative is a server alive for days.
//
//   import {tmuxSession} from './lib/tmux-session.mjs';
//   const {SOCKET, tmux} = tmuxSession('wa-run-live');
//   const r = tmux(['new-session', '-d', '-s', 'live', ...]);
//   // the server is now killed on every path this process can take, and a server left by a SIGKILLed
//   // sibling is reclaimed here.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

// A socket name this helper owns: `<family>-<pid>`. The reclaim looks for the same shape, so a row that starts
// a server through this helper is also the row that cleans up after a killed sibling.
const OURS = /^(wa-[a-z0-9-]+)-(\d+)$/;
const claimed = new Set();
let handlersInstalled = false;

function socketDir() {
  // `tmux -L <name>` puts the socket in $TMUX_TMPDIR or /tmp, under a per-uid directory. Not TMPDIR: tmux
  // does not read it (measured on this node: the row's sockets land in /tmp/tmux-1000 whatever TMPDIR says).
  const base = process.env.TMUX_TMPDIR || '/tmp';
  let uid = '';
  try { uid = String(os.userInfo().uid); } catch { uid = process.env.UID || ''; }
  return path.join(base, 'tmux-' + uid);
}

export function killServer(socket) {
  try { spawnSync('tmux', ['-L', socket, 'kill-server'], { encoding: 'utf8', timeout: 10000 }); } catch {}
  // AND THE SOCKET FILE, which outlives the server (measured 23/11: 1,340 `wa-*` socket FILES in
  // /tmp/tmux-1000, every one of them answering 'no server running on ...'). tmux unlinks the file when
  // a server exits cleanly and leaves it behind when one is killed, so removing it here is the
  // difference between a leak check and a count of history. It is safe for the two callers there are:
  // our own socket (this process is ending) and a socket whose owning pid no longer exists.
  try { fs.unlinkSync(path.join(socketDir(), socket)); } catch {}
}

// A PID THAT ANSWERS kill(pid, 0) IS NOT ALWAYS ALIVE: a zombie does too, and it can never clean up after
// itself (measured on the first run of the leak probe: the SIGKILLed owner was a zombie in its parent's table,
// so the reclaim skipped the server it had just been asked to remove). A dead owner is a dead owner.
export function ownerAlive(pid) {
  try { process.kill(pid, 0); } catch (error) { return error.code === 'EPERM'; }
  try {
    const stat = fs.readFileSync('/proc/' + pid + '/stat', 'utf8');
    const close = stat.lastIndexOf(')');
    if (close > 0 && stat.slice(close + 2, close + 3) === 'Z') return false;
  } catch {}
  return true;
}

// Kill every server of this helper's shape whose owning pid is gone. Called at the start of a session: what a
// SIGKILLed sibling left behind is removed before this row creates anything of its own.
export function reclaimStaleServers() {
  let names = [];
  try { names = fs.readdirSync(socketDir()); } catch { return []; }
  const reclaimed = [];
  for (const name of names) {
    const match = OURS.exec(name);
    if (!match) continue;
    const owner = Number(match[2]);
    if (owner === process.pid) continue;
    if (ownerAlive(owner)) continue;
    killServer(name);
    reclaimed.push(name);
  }
  return reclaimed;
}

export function tmuxSession(family) {
  if (!/^wa-[a-z0-9-]+$/.test(family)) throw new Error('tmuxSession: a family name, not a path: ' + family);
  const SOCKET = family + '-' + process.pid;
  claimed.add(SOCKET);
  const tmux = args => spawnSync('tmux', ['-L', SOCKET, ...args], { encoding: 'utf8' });
  reclaimStaleServers();
  if (!handlersInstalled) {
    handlersInstalled = true;
    const killAll = () => { for (const socket of claimed) killServer(socket); };
    process.on('exit', killAll);
    for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
      process.on(signal, () => { killAll(); process.exit(128 + (signal === 'SIGINT' ? 2 : signal === 'SIGTERM' ? 15 : 1)); });
    }
    process.on('uncaughtException', error => {
      killAll();
      console.error(error && error.stack ? error.stack : String(error));
      process.exit(1);
    });
  }
  return { SOCKET, tmux, killServer: () => killServer(SOCKET) };
}
