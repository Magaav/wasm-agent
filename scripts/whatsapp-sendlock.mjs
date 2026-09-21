// A cross-process lock for the one shared browser send resource.
//
// Two jobs, two sentinel processes, or a run and a job can each try to type into the same WhatsApp
// composer. The composer is a single resource, and "the job store dedupes deliveries" does not serialize
// two different jobs that both want it. So the reply tool takes an OS-level lock (an atomic `mkdir`)
// before it opens a chat, and releases it after the send settles.
//
// Safety rules, each learned from the failure it prevents:
//   - **A live holder is never reclaimed by age.** A browser that stalls for six minutes is still the
//     holder; reclaiming by age is how two senders type at once.
//   - **A lock is released only by its owner.** The owner file carries a random nonce; a stale holder
//     that wakes up cannot delete the successor's lock.
//   - **An unreadable, foreign or ownerless lock fails closed.** We cannot prove it is dead, so we do
//     not take it; the error names the path.
//   - **Only a same-host dead PID is reclaimed**, atomically (a rename wins exactly one reclaimer).
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export function defaultLockPath() {
  const base = process.env.LOCALAPPDATA || process.env.HOME || os.tmpdir();
  return path.join(base, "wasm-agent", "whatsapp-send.lock");
}

function readOwner(dir) {
  try {
    return JSON.parse(fs.readFileSync(path.join(dir, "owner.json"), "utf8"));
  } catch {
    return null;
  }
}

// `kill(pid, 0)` proves liveness, not identity. An EPERM means the process exists but is not ours, which
// is still alive; anything else (ESRCH) means it is gone. A foreign host cannot be checked at all.
function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return !!(error && error.code === "EPERM");
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Acquire the lock. Returns `{ ok: true, nonce, release }` or `{ ok: false, reason, holder }`. Never
// throws for a busy resource: a busy resource is a reported condition, not a crash.
export async function acquire(lockPath = defaultLockPath(), options = {}) {
  const now = Number(options.now) || Date.now();
  const pid = Number(options.pid) || process.pid;
  const host = options.host || os.hostname();
  const nonce = options.nonce || crypto.randomBytes(16).toString("hex");
  const waitMs = Number(options.waitMs) || 0;
  const pollMs = Number(options.pollMs) || 250;
  const deadline = now + waitMs;

  // The parent directory is shared and safe to create idempotently; the lock itself is not.
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });

  for (;;) {
    try {
      fs.mkdirSync(lockPath, { recursive: false });
      try {
        fs.writeFileSync(path.join(lockPath, "owner.json"), JSON.stringify({ pid, host, nonce, started_at: new Date().toISOString() }));
      } catch (error) {
        try { fs.rmSync(lockPath, { recursive: true, force: true }); } catch { /* raced */ }
        return { ok: false, reason: "lock_owner_write_failed", detail: String((error && error.message) || error) };
      }
      return {
        ok: true,
        path: lockPath,
        nonce,
        release() {
          // Only the nonce that owns the lock may remove it: an old holder must not delete its successor.
          const owner = readOwner(lockPath);
          if (!owner || owner.nonce !== nonce) return false;
          try { fs.rmSync(lockPath, { recursive: true, force: true }); } catch { return false; }
          return true;
        },
      };
    } catch (error) {
      if (!error || error.code !== "EEXIST") {
        return { ok: false, reason: "lock_error", detail: String((error && error.message) || error) };
      }
    }

    const owner = readOwner(lockPath);
    // Unknown owner: fail closed. A lock we cannot attribute is a lock we cannot safely take.
    if (!owner || typeof owner.pid !== "number" || owner.pid <= 0) {
      return { ok: false, reason: "lock_corrupt", holder: owner, path: lockPath };
    }
    if (owner.host && owner.host !== host) {
      return { ok: false, reason: "lock_foreign", holder: owner, path: lockPath };
    }
    if (pidAlive(owner.pid)) {
      // A live holder is never reclaimed by age.
      if (Date.now() >= deadline) return { ok: false, reason: "lock_held", holder: owner, path: lockPath };
      await sleep(pollMs);
      continue;
    }
    // Same host, dead PID: reclaim atomically. `rename` wins for exactly one reclaimer; the loser sees
    // ENOENT and retries, finding either our new lock or another's.
    const graveyard = `${lockPath}.reclaim.${nonce}`;
    try {
      fs.renameSync(lockPath, graveyard);
    } catch {
      if (Date.now() >= deadline) return { ok: false, reason: "lock_held", holder: owner, path: lockPath };
      await sleep(pollMs);
      continue;
    }
    try { fs.rmSync(graveyard, { recursive: true, force: true }); } catch { /* best effort */ }
    continue;
  }
}
