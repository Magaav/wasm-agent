// The proof-of-life primitive both serial lanes use: an exclusive SQLite lock the OS releases on
// death, plus the two process facts a decision may be taken from.
//
// WHY IT IS SHARED RATHER THAN COPIED. `scripts/gate-lane.mjs` (the serial gate's slot) and
// `scripts/landing-queue.mjs` (the canonical checkout's lander slot) must agree on exactly what
// "held" means, because both answer the same question - is the owner of this record still alive -
// and both must answer it the same way when a node is replaced mid-claim. The mechanism is the one
// this repository already uses for its own resources (`rust/wa-host/src/resources.rs`): a lock the
// kernel drops when the process holding it dies. A pid is *evidence*, never the latch: measured on
// wasm_the_first (lesson `les-dcbabb9d2835`), a lock file with a dead pid in it blocked every later
// deploy for 1h44 because nothing reclaimed it. A lease cannot do that: a dead holder's lease is
// free the moment it dies, and the reclaim is then a decision with logged evidence rather than a
// wait.
//
// WHAT A LEASE DOES NOT SAY. `leaseHeld` false proves the *process that took it* is gone (or has
// closed it); it says nothing about work that holder started. A gate or a build that outlives its
// owner is a survivor the caller must name and decide about - `gate-lane.mjs`'s orphaned
// vocabulary. A lease held by someone else says nothing about whether that owner is making
// progress: `heartbeat`/`expires_at` is the fact for that, and an expired-but-alive owner is a
// person's decision, never a silent steal.
import fs from 'node:fs';
import path from 'node:path';
import {DatabaseSync} from 'node:sqlite';

// Leases this process itself holds, so a re-entrant check does not open a second handle to a file
// it is already locking (SQLite would refuse and the answer would read as "held by someone else").
const held = new Map();

export function leaseFile(dir, uuid) { return path.join(dir, 'leases', `${uuid}.sqlite`); }

// Take the lease. BEGIN EXCLUSIVE is what makes this an OS-held fact: the write lock is released
// by the kernel when this process exits, however it exits.
export function holdLease(dir, uuid) {
  const db = new DatabaseSync(leaseFile(dir, uuid));
  db.exec('PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE');
  held.set(uuid, db);
  return db;
}

export function releaseLease(uuid) {
  const db = held.get(uuid);
  held.delete(uuid);
  if (!db) return;
  try { db.exec('ROLLBACK'); } catch {}
  try { db.close(); } catch {}
}

export function leaseHeld(dir, uuid) {
  if (held.has(uuid)) return true;
  const file = leaseFile(dir, uuid);
  if (!fs.existsSync(file)) return false;
  let probe;
  try { probe = new DatabaseSync(file); } catch { return true; }
  try { probe.exec('PRAGMA busy_timeout=0'); probe.exec('BEGIN EXCLUSIVE'); probe.exec('ROLLBACK'); return false; }
  catch { return true; } finally { try { probe.close(); } catch {} }
}

export function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch (error) { return error.code === 'EPERM' || error.code === 'EACCES'; }
}
