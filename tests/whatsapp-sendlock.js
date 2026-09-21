// The shared browser send resource is serialized across processes.
//
// Two jobs, or two sentinel processes, can each want the same composer. This proves the lock excludes a
// live holder, reclaims a crashed one, and releases cleanly - all without a browser.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

let checked = 0;
const check = (value, label) => { assert.ok(value, label); checked += 1; };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

(async () => {
  const { acquire } = await import("../scripts/whatsapp-sendlock.mjs");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "wa-sendlock-"));
  const lock = path.join(root, "whatsapp-send.lock");

  const first = await acquire(lock, { pid: process.pid, waitMs: 0 });
  check(first.ok === true, "the first holder acquires the lock");

  const second = await acquire(lock, { pid: process.pid + 1, waitMs: 0 });
  check(second.ok === false, "a live holder excludes a second acquisition");
  check(second.holder && second.holder.pid === process.pid, "the busy result names the holder");

  // A bounded wait does acquire once the holder releases.
  const waiter = acquire(lock, { pid: process.pid + 2, waitMs: 2000, pollMs: 50 });
  await sleep(200);
  first.release();
  const waited = await waiter;
  check(waited.ok === true, "a waiter acquires after the holder releases");
  waited.release();
  check(fs.existsSync(lock) === false, "release removes the lock directory");

  // A crashed holder must not lock the resource forever.
  fs.mkdirSync(lock, { recursive: true });
  fs.writeFileSync(path.join(lock, "owner.json"), JSON.stringify({ pid: 999999 }));
  const past = new Date(Date.now() - 10 * 60 * 1000);
  fs.utimesSync(lock, past, past);
  const reclaimed = await acquire(lock, { pid: process.pid + 3, waitMs: 0, staleMs: 1000 });
  check(reclaimed.ok === true, "a stale lock is reclaimed");
  reclaimed.release();

  fs.rmSync(root, { recursive: true, force: true });
  console.log("ALL PASS");
  void checked;
})().catch((error) => {
  console.log("FAIL", (error && error.message) || error);
  console.log("1 FAILURE(S)");
  process.exitCode = 1;
});
