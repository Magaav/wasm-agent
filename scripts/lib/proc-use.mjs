// Is a live process using this directory? The POSIX evidence, decided once for every sweep that removes
// temp state (scripts/reclaim-disk.mjs, scripts/merge-lane.mjs).
//
// On POSIX a rename is metadata-only and succeeds with a process working inside, so it proves nothing;
// /proc is the evidence: a process whose cwd, or any open file, is inside the directory.
//
// THE UNREADABLE RULE (30/10). Not every /proc entry can be read: another user's processes (root's, other
// accounts') refuse `cwd` and `fd`. Those are SKIPPED AND COUNTED, never treated as proof of use: the
// directories these sweeps remove are this user's private temp state, which another user cannot work
// inside. An unreadable process of THIS user is different - it could be working inside - so it makes
// the answer unproven, and the caller keeps the directory. Except where the kernel hides it BECAUSE it is
// more privileged than this user: a setuid program (effective uid not ours), one holding capabilities
// (`systemd --user`), or one marked non-dumpable (`(sd-pam)`, whose /proc links then belong to root).
// Every systemd host runs those as the user, so counting them as "could be working inside" kept every
// family forever again (measured on a desktop, 30/10). They are skipped and counted as privileged; the
// fixtures these sweeps clean are made by ordinary processes of this user, which /proc does show. A
// zombie has no cwd or files and is not counted at all. Before this rule one unreadable process (192
// on openclaw, 169 on a desktop) made every family "liveness unproven", so a Linux pass never freed a byte.
//
//   procUse(dir) -> { holder: { pid, why } | null, unreadableOwn, skippedOtherUser, skippedPrivileged, scanned, error? }
//     holder           a readable process works in or holds a file inside `dir` (keep it)
//     unreadableOwn    processes of this user that could not be inspected (keep it: unproven)
//     skippedOtherUser processes of other users that could not be inspected (named, not decisive)
//     skippedPrivileged this user's setuid / capability-holding / non-dumpable processes (named, not decisive)
//     error            /proc or `dir` could not be read at all (keep it: unproven)
import fs from 'node:fs';

// What `status` (readable by any user) says about a process: its uids (real, effective, saved, fs), its
// effective capabilities and its state. null when it cannot be read - the process exited, or /proc refuses.
function statusOf(procRoot, pid) {
  let text;
  try { text = fs.readFileSync(`${procRoot}/${pid}/status`, 'utf8'); } catch { return null; }
  const uid = /^Uid:\s+(.*)$/m.exec(text);
  if (!uid) return null;
  const cap = /^CapEff:\s+([0-9a-f]+)$/m.exec(text);
  const state = /^State:\s+(\S)/m.exec(text);
  return { uids: uid[1].trim().split(/\s+/).map(Number), capEff: cap ? cap[1] : '0', state: state ? state[1] : '?' };
}

const gone = error => error && (error.code === 'ENOENT' || error.code === 'ESRCH');

export function procUse(dir, { procRoot = '/proc', uid = process.getuid ? process.getuid() : null } = {}) {
  const result = { holder: null, unreadableOwn: 0, skippedOtherUser: 0, skippedPrivileged: 0, scanned: 0 };
  let target;
  try { target = fs.realpathSync(dir); } catch (error) { return { ...result, error: `cannot resolve ${dir}: ${error.code || error.message}` }; }
  const inside = link => link === target || link.startsWith(`${target}/`);
  let pids;
  try { pids = fs.readdirSync(procRoot).filter(name => /^\d+$/.test(name)); } catch { return { ...result, error: `no ${procRoot} on this platform` }; }
  // One unreadable process, classified by owner. A process that exited meanwhile is simply not counted.
  const unreadable = pid => {
    const status = statusOf(procRoot, pid);
    if (status === null) {
      if (!fs.existsSync(`${procRoot}/${pid}`)) return;
      result.unreadableOwn += 1; return; // owner unknown: not provably someone else's
    }
    if (status.state === 'Z' || status.state === 'X') return;
    if (uid === null || !status.uids.includes(uid)) { result.skippedOtherUser += 1; return; }
    let linkOwner = null;
    try { linkOwner = fs.lstatSync(`${procRoot}/${pid}/cwd`).uid; } catch {}
    const privileged = status.uids[1] !== uid || !/^0+$/.test(status.capEff) || (linkOwner !== null && linkOwner !== uid);
    if (privileged) result.skippedPrivileged += 1;
    else result.unreadableOwn += 1;
  };
  for (const pid of pids) {
    result.scanned += 1;
    let cwd;
    try { cwd = fs.readlinkSync(`${procRoot}/${pid}/cwd`); } catch (error) { if (!gone(error)) unreadable(pid); continue; }
    if (inside(cwd)) return { ...result, holder: { pid: Number(pid), why: `pid ${pid} works in it (cwd ${cwd})` } };
    let fds;
    try { fds = fs.readdirSync(`${procRoot}/${pid}/fd`); } catch (error) { if (!gone(error)) unreadable(pid); continue; }
    for (const fd of fds) {
      let link;
      try { link = fs.readlinkSync(`${procRoot}/${pid}/fd/${fd}`); } catch { continue; }
      if (inside(link)) return { ...result, holder: { pid: Number(pid), why: `pid ${pid} holds ${link} open` } };
    }
  }
  return result;
}

// The one-line summary a report prints beside the verdict.
export function procUseNote(use) {
  const parts = [];
  if (use.skippedOtherUser) parts.push(`${use.skippedOtherUser} other-user process(es) not readable, skipped`);
  if (use.skippedPrivileged) parts.push(`${use.skippedPrivileged} privileged process(es) of this user not readable, skipped`);
  if (use.unreadableOwn) parts.push(`${use.unreadableOwn} process(es) of this user not readable`);
  return parts.join('; ');
}
