// The shared browser send resource is serialized across processes, and never reclaimed from a live holder.
//
// Two jobs, or two sentinel processes, can each want the same composer. These tests prove the lock
// excludes a live holder even when it is old, releases only for the owning nonce, fails closed on an
// unreadable/foreign/ownerless lock, reclaims a same-host dead PID safely, and lets exactly one racer win
// a stale reclaim. No browser.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

let checked = 0;
const check = (value, label) => { assert.ok(value, label); checked += 1; };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function deadPid() {
  // A child that has exited: reliably dead, and not reused inside this test window.
  const child = spawnSync(process.execPath, ["-e", "process.exit(0)"], { encoding: "utf8" });
  return child.pid;
}

(async () => {
  const { acquire } = await import("../scripts/whatsapp-sendlock.mjs");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "wa-sendlock-"));
  const lock = path.join(root, "nested", "whatsapp-send.lock");

  // The parent directory is created safely; the first holder acquires.
  const first = await acquire(lock, { pid: process.pid, waitMs: 0 });
  check(first.ok === true, "the first holder acquires and the parent directory is created");
  check(first.nonce, "the holder has a nonce");

  const second = await acquire(lock, { pid: process.pid, waitMs: 0 });
  check(second.ok === false && second.reason === "lock_held", "a live holder excludes a second acquisition");

  // A bounded wait does acquire once the holder releases.
  const waiter = acquire(lock, { pid: process.pid, waitMs: 2000, pollMs: 50 });
  await sleep(200);
  first.release();
  const waited = await waiter;
  check(waited.ok === true, "a waiter acquires after the holder releases");

  // A stale release must not delete the successor's lock.
  waited.release();
  const successor = await acquire(lock, { pid: process.pid, waitMs: 0 });
  check(successor.ok === true, "a successor acquires");
  check(waited.release() === false, "the previous holder's release does not remove the successor's lock");
  check(fs.existsSync(lock), "the successor's lock survives the stale release");
  successor.release();
  check(fs.existsSync(lock) === false, "the owner's release removes the lock");

  // A live holder is NOT reclaimed by age, however old the lock looks.
  fs.mkdirSync(lock, { recursive: true });
  fs.writeFileSync(path.join(lock, "owner.json"), JSON.stringify({ pid: process.pid, host: os.hostname(), nonce: "live" }));
  const past = new Date(Date.now() - 60 * 60 * 1000);
  fs.utimesSync(lock, past, past);
  const oldLive = await acquire(lock, { pid: process.pid, waitMs: 0 });
  check(oldLive.ok === false && oldLive.reason === "lock_held", "an old lock held by a live PID is not reclaimed");
  // Clean up with the owner's nonce, then remove the directory.
  fs.writeFileSync(path.join(lock, "owner.json"), JSON.stringify({ pid: process.pid, host: os.hostname(), nonce: "cleanup" }));
  fs.rmSync(lock, { recursive: true, force: true });

  // Unknown owner fails closed.
  fs.mkdirSync(lock, { recursive: true });
  const ownerless = await acquire(lock, { pid: process.pid, waitMs: 0 });
  check(ownerless.ok === false && ownerless.reason === "lock_corrupt", "a lock with no owner fails closed");
  fs.rmSync(lock, { recursive: true, force: true });

  // A foreign host cannot be checked, so it fails closed.
  fs.mkdirSync(lock, { recursive: true });
  fs.writeFileSync(path.join(lock, "owner.json"), JSON.stringify({ pid: process.pid, host: "some-other-host", nonce: "foreign" }));
  const foreign = await acquire(lock, { pid: process.pid, waitMs: 0 });
  check(foreign.ok === false && foreign.reason === "lock_foreign", "a foreign-host lock fails closed");
  fs.rmSync(lock, { recursive: true, force: true });

  // A same-host dead PID is reclaimed.
  const dead = deadPid();
  fs.mkdirSync(lock, { recursive: true });
  fs.writeFileSync(path.join(lock, "owner.json"), JSON.stringify({ pid: dead, host: os.hostname(), nonce: "dead" }));
  const reclaimed = await acquire(lock, { pid: process.pid, waitMs: 0 });
  check(reclaimed.ok === true, "a same-host dead PID is reclaimed");
  reclaimed.release();

  // Concurrent stale reclaim: exactly one racer wins the dead lock.
  const dead2 = deadPid();
  fs.mkdirSync(lock, { recursive: true });
  fs.writeFileSync(path.join(lock, "owner.json"), JSON.stringify({ pid: dead2, host: os.hostname(), nonce: "dead2" }));
  const [raceOne, raceTwo] = await Promise.all([
    acquire(lock, { pid: process.pid, waitMs: 400, pollMs: 20 }),
    acquire(lock, { pid: process.pid, waitMs: 400, pollMs: 20 }),
  ]);
  check([raceOne, raceTwo].filter((result) => result.ok).length === 1, "exactly one racer wins a stale reclaim");
  for (const result of [raceOne, raceTwo]) if (result.ok) result.release();

  fs.rmSync(root, { recursive: true, force: true });
  console.log("ALL PASS");
  void checked;
})().catch((error) => {
  console.log("FAIL", (error && error.message) || error);
  console.log("1 FAILURE(S)");
  process.exitCode = 1;
});
