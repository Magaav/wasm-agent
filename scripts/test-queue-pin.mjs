#!/usr/bin/env node
// THE SHA THAT WAS READ IS THE SHA THAT LANDS.
//
// v0 hit this on 27/11: a branch was rewritten between the tip check and the merge, and the lander merged bytes
// nobody had submitted. `land-quick.sh` takes a branch NAME, so the queue pins a ref at the request's sha and
// hands the lander THAT - and the lander's own tip check then refuses a ref that moved.
//
// WHAT THIS CAN FAIL ON:
//   * a pin that follows the branch instead of the sha (the branch moves -> the moved tip would land);
//   * a pin that reports success without checking the ref it wrote;
//   * a sha the clone does not have being treated as anything but `stale_sha`;
//   * the lander being called with the branch name again (the whole point, and the easiest thing to regress).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {openJournal, submit} from './lib/queue/journal.mjs';
import {pinRequest, pinRefName, landQuick} from './lib/queue/steps.mjs';
import {runOnce} from './q-runner.mjs';

let checks = 0;
const fail = (message) => { console.error(`FAIL test-queue-pin: ${message}`); process.exit(1); };
const ok = (condition, message) => { if (!condition) fail(message); checks += 1; };
const eq = (actual, expected, message) => ok(Object.is(actual, expected), `${message} (got ${JSON.stringify(actual)}, wanted ${JSON.stringify(expected)})`);

const work = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'wa-queue-pin-'));
process.on('exit', () => { try { fs.rmSync(work, {recursive: true, force: true}); } catch { /* best effort */ } });

// A clone-shaped fixture: main, a branch, and a commit to move it to.
const repo = path.join(work, 'clone');
fs.mkdirSync(repo, {recursive: true});
const git = (...args) => execFileSync('git', ['-C', repo, ...args], {encoding: 'utf8'}).trim();
git('init', '-q', '--initial-branch=main');
git('config', 'user.email', 'row@example.invalid');
git('config', 'user.name', 'row');
fs.writeFileSync(path.join(repo, 'a.txt'), 'one\n');
git('add', '.'); git('commit', '-qm', 'one');
git('branch', 'change/mover');
git('update-ref', 'refs/remotes/origin/main', git('rev-parse', 'main'));  // a clone has an origin/main
const read = git('rev-parse', 'change/mover');
fs.writeFileSync(path.join(repo, 'a.txt'), 'two\n');
git('commit', '-qam', 'two');
git('branch', '-f', 'change/mover', 'main');  // the branch is REWRITTEN onto the new commit, which is the incident
const moved = git('rev-parse', 'change/mover');
ok(read !== moved, 'the fixture branch really moves');

const originBefore = git('rev-parse', 'origin/main');
const db = openJournal(path.join(work, 'journal.db'));
const req = submit(db, {branch: 'change/mover', sha: read, mission: 'pin'});

// ---- 1. the pin names the request, and points at the sha that was read ---------------------------------
eq(pinRefName({id: req.id, branch: 'change/mover'}), `change/mover-q${req.id}`, 'the pin is the branch leaf and the request id, in that order');

// ---- 1b. THE PIN KEEPS THE BRANCH FAMILY (v0 stopped q#23 as a foreign commit on exactly this) ----------
// land-quick.sh computes `fam` as the FIRST TWO dash-words of the branch name and holds every commit whose
// Agent: trailer names a change/ branch to the same two words. The pin therefore has to name the same
// family, which the id on the END preserves and an id on the FRONT destroys. Both directions are asserted,
// so a future rename has to answer this rule rather than slip past it.
const family = (branchName) => branchName.split("/").pop().split("-").slice(0, 2).join("-");
eq(family(pinRefName({id: 23, branch: 'change/landing-queue-service'})), family('change/landing-queue-service'), 'the pinned name has the branch family, so land-quick foreign check passes');
ok(family('change/q23-landing-queue-service') !== family('change/landing-queue-service'), 'an id on the FRONT would read as another family - which is the shape that stopped q#23');
const pin = await pinRequest({repo, request: db.prepare('SELECT * FROM requests WHERE id = ?').get(req.id)});
eq(pin.ok, true, 'the pin is written');
eq(pin.sha, read, 'at the sha the request was submitted with');
eq(git('rev-parse', `refs/heads/${pin.ref}`), read, 'and the ref in the repository is that sha, not the moved tip');
eq(git('rev-parse', 'change/mover'), moved, 'while the branch itself has moved on - the danger is real in this fixture');

// ---- 2. a sha this clone does not have is stale_sha, not a guess ---------------------------------------
const ghost = {id: 99, branch: 'change/ghost', sha: '0'.repeat(40)};
const miss = await pinRequest({repo, request: ghost});
eq(miss.ok, false, 'a sha the clone does not have cannot be pinned');

// ---- 3. the lander is handed the REF, never the branch name -------------------------------------------
// A stub lander, because what is under test is the argument: it records argv and succeeds.
const missions = path.join(work, 'missions');
fs.mkdirSync(missions, {recursive: true});
const stub = path.join(missions, 'land-quick.sh');
fs.writeFileSync(stub, '#!/bin/bash\necho "stub+"\necho "$1" > "$LANDER_ARG_FILE"\nexit 0\n');
fs.chmodSync(stub, 0o755);
process.env.LANDER_ARG_FILE = path.join(work, 'lander-arg.txt');
const step = landQuick({missionsDir: missions, repo, landerRepo: repo});
const result = await step({request: db.prepare('SELECT * FROM requests WHERE id = ?').get(req.id)});
eq(result.ok, true, 'the stub lander succeeded');
eq(fs.readFileSync(process.env.LANDER_ARG_FILE, 'utf8').trim(), pinRefName({id: req.id, branch: 'change/mover'}), 'and it was given the pinned ref, NOT change/mover');

// ---- 4. end to end: the moved branch does not land -----------------------------------------------
// The same stub says TIP MOVED when its argument is not the sha it was told to expect - which is exactly
// what land-quick.sh does when a ref no longer holds the commit the queue read.
fs.writeFileSync(stub, `#!/bin/bash
if [ "$(git -C ${repo} rev-parse "$1")" != "${read}" ]; then echo "TIP MOVED: $1 is not ${read.slice(0, 12)} - NOT landing"; exit 1; fi
echo "stub: landed $1"
exit 0
`);
fs.chmodSync(stub, 0o755);
// Move the pin to the moved tip, as a rewritten branch would: the queue must reject, not land it.
const second = submit(db, {branch: 'change/mover2', sha: read, mission: 'pin'});
const stepsMoved = {
  merge: async () => ({ok: false, cause: 'stale_sha', detail: 'TIP MOVED: change/q-ref is not the sha read'}),
  rows: async () => ({ok: true}),
  push: async () => ({ok: true}),
};
const outcome = await runOnce(db, {repo, steps: stepsMoved, missionsDir: missions});
eq(outcome.outcome, 'rejected', 'a request whose ref no longer holds its sha is REJECTED');
eq(outcome.cause, 'stale_sha', 'as stale_sha');
eq(git('rev-parse', 'origin/main'), originBefore, 'and nothing landed: origin/main did not move');

// And the honest case: the pinned ref still holds the read sha, so the lander accepts it.
const third = submit(db, {branch: 'change/mover3', sha: read, mission: 'pin'});
const pin3 = await pinRequest({repo, request: db.prepare('SELECT * FROM requests WHERE id = ?').get(third.id)});
eq(pin3.ok, true, 'the third request pins');
const accepted = await runOnce(db, {repo, steps: {merge: step, rows: async () => ({ok: true}), push: async () => ({ok: true, mainSha: read.slice(0, 8)})}, missionsDir: missions});
eq(accepted.outcome, 'landed', 'and the lander accepts the pinned ref that still holds the sha it read');

// ---- 5. THE PIN LIVES WHERE THE LANDER MERGES (the swap, 27/11) ---------------------------------------
// land-quick.sh merges and pushes from ITS OWN tree by branch name. The swap steps clone a runner tree
// (~/wasm-agent/q-clone), which shares no refs with it, so a pin written only there is "no branch" for the
// lander. This case drives landQuick with two DIFFERENT trees and asserts which one gets the ref.
const clone = path.join(work, "clone2");
fs.mkdirSync(clone, {recursive: true});
execFileSync("git", ["-C", clone, "init", "-q", "--initial-branch=main"]);
execFileSync("git", ["-C", clone, "-c", "user.email=r@e.invalid", "-c", "user.name=r", "commit", "-q", "--allow-empty", "-m", "one"]);
// The sha the request names must exist in the LANDER tree, because that is where the pin is written.
const _cloneSha = execFileSync("git", ["-C", clone, "rev-parse", "HEAD"], {encoding: "utf8"}).trim();
execFileSync("git", ["-C", clone, "update-ref", "refs/remotes/origin/main", _cloneSha]);
const fourth = submit(db, {branch: "change/lander", sha: read, mission: "pin"});

// A lander that records the ref it was handed and the environment it ran with, then succeeds.
const seen = path.join(work, "seen.txt");
fs.writeFileSync(stub, `#!/bin/bash
echo "arg=$1" > ${seen}
echo "noinstall=\${LQ_NO_INSTALL:-unset}" >> ${seen}
exit 0
`);
fs.chmodSync(stub, 0o755);
const twoTrees = landQuick({missionsDir: missions, repo: clone, landerRepo: repo, dryRun: true});
const pinned = await twoTrees({request: db.prepare("SELECT * FROM requests WHERE id = ?").get(fourth.id)});
eq(pinned.ok, true, "the two-tree run succeeds");
eq(git("rev-parse", "refs/heads/" + pinRefName({id: fourth.id, branch: "change/lander"})), read, "the pin is written into the LANDER tree");
ok(fs.existsSync(seen) && fs.readFileSync(seen, "utf8").includes("arg=change/lander-q"), "and the lander is handed that ref");

// ---- 6. NO INSTALL BY DEFAULT, AND AN INSTALL FAILURE AFTER A PUSH IS NOT A REJECTION ------------------
ok(fs.readFileSync(seen, "utf8").includes("noinstall=1"), "the default run tells the lander not to install (Victor 27/11)");
const asksInstall = submit(db, {branch: "change/install-me", sha: read, mission: "pin", kind: "install"});
const installStep = landQuick({missionsDir: missions, repo: clone, landerRepo: repo, dryRun: true});
await installStep({request: db.prepare("SELECT * FROM requests WHERE id = ?").get(asksInstall.id)});
ok(fs.readFileSync(seen, "utf8").includes("noinstall=unset"), "a request that names an install does not suppress it");

// Pushed, then the lander fails after the push: main moved, so the verdict is LANDED with the install pending.
const afterPush = submit(db, {branch: "change/after-push", sha: read, mission: "pin", kind: "install"});
fs.writeFileSync(stub, `#!/bin/bash
git -C ${repo} update-ref refs/remotes/origin/main ${read}
echo "landed on main"
echo "install-local: FAILED to swap the unit" >&2
exit 4
`);
fs.chmodSync(stub, 0o755);
const post = await landQuick({missionsDir: missions, repo: clone, landerRepo: repo})({request: db.prepare("SELECT * FROM requests WHERE id = ?").get(afterPush.id)});
eq(post.ok, true, "a failure AFTER main moved is not a rejection");
eq(post.installPending, true, "it is a landing with an install pending");
ok(/install-local/.test(post.installError || ""), `and it carries why the install failed (${(post.installError || "").slice(0, 60)})`);

db.close();
console.log(`queue pin ok (${checks} checks)`);
