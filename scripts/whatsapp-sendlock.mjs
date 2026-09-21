// A cross-process lock for the one shared browser send resource.
//
// Two jobs, two sentinel processes, or a run and a job can each try to type into the same WhatsApp
// composer. The composer is a single resource, and "the job store dedupes deliveries" does not serialize
// two different jobs that both want it. So the reply tool takes an OS-level lock (an atomic `mkdir`)
// before it opens a chat, and releases it after the send settles.
//
// It is a *lock*, not a queue: when another holder is alive the tool reports `send_resource_busy` with the
// holder, rather than typing over it. A stale lock (a crashed process) is reclaimed after `staleMs`.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export function defaultLockPath() {
  const base = process.env.LOCALAPPDATA || process.env.HOME || os.tmpdir();
  return path.join(base, "wasm-agent", "whatsapp-send.lock");
}

function holderOf(dir) {
  try {
    const owner = JSON.parse(fs.readFileSync(path.join(dir, "owner.json"), "utf8"));
    return owner;
  } catch {
    return null;
  }
}

function stale(dir, now, staleMs) {
  try {
    const stat = fs.statSync(dir);
    return now - stat.mtimeMs > staleMs;
  } catch {
    return true;
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Acquire the lock. Returns `{ ok: true, release }` or `{ ok: false, holder }`. Never throws for a busy
// resource: a busy resource is a reported condition, not a crash.
export async function acquire(lockPath = defaultLockPath(), options = {}) {
  const now = Number(options.now) || Date.now();
  const pid = Number(options.pid) || process.pid;
  const staleMs = Number(options.staleMs) || 5 * 60 * 1000;
  const waitMs = Number(options.waitMs) || 0;
  const pollMs = Number(options.pollMs) || 250;
  const deadline = now + waitMs;
  for (;;) {
    try {
      fs.mkdirSync(lockPath, { recursive: false });
      const owner = { pid, started_at: new Date(now).toISOString(), host: os.hostname() };
      try { fs.writeFileSync(path.join(lockPath, "owner.json"), JSON.stringify(owner)); } catch { /* holder file is diagnostic */ }
      return {
        ok: true,
        path: lockPath,
        owner,
        release() {
          try { fs.rmSync(lockPath, { recursive: true, force: true }); } catch { /* already gone */ }
        },
      };
    } catch (error) {
      if (error && error.code !== "EEXIST") {
        return { ok: false, error: String((error && error.message) || error) };
      }
      if (stale(lockPath, Date.now(), staleMs)) {
        // A crashed holder must not lock the resource forever. Reclaim once, then re-check.
        try { fs.rmSync(lockPath, { recursive: true, force: true }); } catch { /* raced */ }
        continue;
      }
      const holder = holderOf(lockPath);
      if (Date.now() >= deadline) return { ok: false, holder };
      await sleep(pollMs);
    }
  }
}
