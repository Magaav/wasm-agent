// The durable record of one delivery: where it lives, and how it is written.
//
// WHY THIS STORE, AND NOT ONE OF MY OWN.
// The front of the merge lane needs one record per delivery that outlives the branch, the worktree
// and the clone that produced it. The repository already keeps exactly that class of thing in ONE
// place: the sentinel's own store, `<WASM_AGENT_HOME>/.wasm-agent/sentinel/` - `jobs.db` holds the
// job definitions and the durable queue, and `claimed/`, `done/`, `failed/` and `operations/` hold
// what each delivery did. A delivery record is the same kind of object as those: durable state about
// one queued/consumed occurrence, owned by nothing in git and read by an operator at a prompt.
//
// Two stores were deliberately NOT chosen:
//   * `jobs.db` itself. Its schema, its immediate-transaction semantics and its revision checks
//     belong to `rust/wa-jobs`; a second writer with a hand-written INSERT would be a second owner of
//     the same invariants, and a schema change there would silently break this.
//   * a tracked file (e.g. under `docs/` or next to the branch). A record that is part of the branch
//     cannot record the branch's own landing, and a landed-and-deleted branch would take its record
//     with it. The point of the record is to survive that.
//
// One JSON file per delivery, keyed by the delivery's own id (its branch name), rewritten in place
// (write temp + rename) - so "the record" is one path an operator can `cat`, and the update is
// atomic rather than a truncation another reader can catch half-done.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

/// The sentinel's store root, resolved the way `rust/wa-sentinel` resolves it: `WASM_AGENT_HOME`,
/// else `%USERPROFILE%` on Windows, else `$HOME`, each under `.wasm-agent/sentinel`.
export function sentinelDir(env = process.env) {
  const home = env.WASM_AGENT_HOME
    || (os.platform() === 'win32' ? env.USERPROFILE : undefined)
    || env.HOME
    || '..';
  return path.join(home, '.wasm-agent', 'sentinel');
}

/// `WA_DELIVERY_STORE` overrides the directory. It exists so a test or a rehearsal can run the whole
/// rule against a scratch store and touch nothing live; a run that used it says so in its output.
export function storeDir(env = process.env) {
  return env.WA_DELIVERY_STORE ? path.resolve(env.WA_DELIVERY_STORE) : path.join(sentinelDir(env), 'deliveries');
}

/// A delivery id is a branch name (`change/wa-session-<id>`), which is not a file name. The slug is
/// lossy in principle (two ids differing only in `/` vs `-`), so a collision is refused rather than
/// silently overwritten; the record keeps the true id in `delivery`.
export function slug(delivery) {
  return String(delivery).replace(/[^A-Za-z0-9._-]/g, '-');
}

export function recordPath(dir, delivery) {
  return path.join(dir, `${slug(delivery)}.json`);
}

export function readRecord(dir, delivery) {
  const file = recordPath(dir, delivery);
  if (!fs.existsSync(file)) return null;
  const record = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (record.delivery !== delivery) {
    throw Error(`delivery_store_collision: ${file} holds ${record.delivery}, not ${delivery}`);
  }
  return record;
}

export function listRecords(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter(name => name.endsWith('.json'))
    .sort()
    .map(name => {
      const file = path.join(dir, name);
      try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
      catch (error) { return {delivery: name, unreadable: String(error.message), path: file}; }
    });
}

/// Write the whole record back, atomically: a reader sees the old record or the new one, never a
/// half-written file. This is the "updated in place" the record promises.
export function writeRecord(dir, record) {
  fs.mkdirSync(dir, {recursive: true});
  const target = recordPath(dir, record.delivery);
  const temp = `${target}.${process.pid}.tmp`;
  record.updated_at = new Date().toISOString();
  fs.writeFileSync(temp, `${JSON.stringify(record, null, 2)}\n`);
  fs.renameSync(temp, target);
  return record;
}

/// Read-modify-write in one call, so a verb cannot forget the read or the write.
export function updateRecord(dir, delivery, change) {
  const record = readRecord(dir, delivery);
  if (!record) throw Error(`record_missing: no record for ${delivery} in ${dir}`);
  const next = change(record) || record;
  return writeRecord(dir, next);
}

export function nowIso() {
  return new Date().toISOString();
}
