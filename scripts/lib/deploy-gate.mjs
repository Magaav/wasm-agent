// THE DEPLOY GATE: the deploy's own preconditions, decided on the tree a landing is about to push.
//
// WHY THIS EXISTS. A landing is the moment a commit becomes main, and main is what every node installs.
// On 2026-11-11 a landing made main undeployable: `rust/wa-sentinel` is its own cargo workspace with its
// own lock file (`rust/wa-sentinel/Cargo.toml`, its header says why), a crate it builds gained a
// workspace-internal edge, and the sentinel's lock was not updated in the same landing. `bash
// scripts/fast.sh` found nothing - it runs `cargo test --release --offline -p <crate>` for the crates a
// change touches inside `rust/Cargo.toml`, and the sentinel's workspace is only built when its own paths
// change - and `scripts/deploy.sh` builds it with `cargo build --release --offline --locked
// --manifest-path wa-sentinel/Cargo.toml`, which refuses a lock that needs an update. The next deploy
// therefore refused, the fix was a second landing (`abe54c90 fix(release): record wa-jobs' new
// wa-host-support edge in the sentinel lock`), and every miss costs a full cycle (~7 minutes of test,
// fix and re-land) on the node that found it.
//
// So the landing queue asks the deploy's questions before the push, on the merged tree, and rolls the
// merge back when the answer is "a deploy of this tree cannot work". The checks are the deploy's own:
//
//   lockfile      `cargo metadata --locked --offline` for every cargo workspace `scripts/deploy.sh`
//                 builds with `--locked`. A lock that needs an update is `undeployable_lockfile`, and
//                 the refusals the deploy gives it (`error: the lock file ... needs to be updated`)
//                 are named here instead of being discovered by a deploy. The workspace list is data
//                 (`DEPLOY_WORKSPACES`), and `scripts/test-landing-queue.mjs` parses deploy.sh and
//                 FAILS when it builds another `--locked` manifest that is not in it - adding one
//                 cannot silently escape this gate.
//   components    `components.lock` names every component the deploy installs, and `graph` among them;
//                 `scripts/deploy.sh` refuses `component_lock_incomplete`/`component_lock_empty`
//                 otherwise, i.e. it installs nothing at all. Pure parse, no build.
//   pin           the merged commit can be materialised the way a deploy pins it: a detached
//                 `git worktree add --detach` at that commit, read back from `rev-parse HEAD`. This is
//                 the deploy's `pin_failed`/`pin_mismatch` pair - a tree that cannot be checked out
//                 (a path that cannot exist on this filesystem, a case-only collision) is not
//                 installable, whatever its checks say.
//   compiled      the compiled-inputs classification the release manifest's `compiled_inputs=` digest is
//                 built from, from the deploy's own function (`scripts/lib/node-binaries.sh`,
//                 `wa_compiled_input`) over the tree's real paths, against the queue's classifier
//                 (`compiledInput`). They are two implementations of one rule, and a disagreement would
//                 let a release cover a commit that is not its build - exactly the install this
//                 repository refuses everywhere else. The two digests are NOT compared: they carry
//                 different schemas on purpose (`wasm-agent-compiled-inputs/1` for a release,
//                 `wasm-agent-retest-inputs/1` for a retest proof), so equal values were never the
//                 question; equal classification is.
//
// WHAT IT IS NOT. It does not install, build a binary, fetch a release, or decide whether a release
// exists: publishing stays the queue's post-push step (`publishNodeRelease`), and a machine without a
// toolchain does not get to call a landing deployable - a check that cannot run here is reported as
// `skipped` with the reason, never as a pass (and it is counted as a skip, the same rule the fast path
// uses).
//
// Cost, measured on wasm_the_first 2026-11-11: 2.1 s for the four checks on a Rust landing (0.9 s of it
// the lock resolution, 0.7 s the pinned worktree), 0.3 s for a Lua/docs landing. Seconds, against the
// minutes a deploy round costs.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {git, gitOk, compiledInput} from './landing-queue.mjs';

// One row per manifest `scripts/deploy.sh` (or the publisher it calls) builds with `--locked`. The
// guard in scripts/test-landing-queue.mjs reads deploy.sh and this list against each other.
export const DEPLOY_WORKSPACES = ['rust/Cargo.toml', 'rust/wa-sentinel/Cargo.toml'];

const LOCK_REFUSAL = /needs to be updated|Cargo\.lock|--locked/i;

function run(command, args, {cwd, env = process.env, timeout = 300000, input} = {}) {
  // `cargo metadata` prints the whole resolve as one JSON document - megabytes for this workspace - and
  // a default (1 MB) buffer would turn a perfectly good answer into ENOBUFS, i.e. a silent "no opinion".
  const result = spawnSync(command, args, {cwd, env, encoding: 'utf8', timeout, input, windowsHide: true,
    maxBuffer: 256 * 1024 * 1024});
  return {
    ok: result.status === 0,
    status: result.status === null ? -1 : result.status,
    error: result.error ? String(result.error.code || result.error.message) : '',
    stdout: String(result.stdout || ''),
    stderr: String(result.stderr || ''),
  };
}

const lastLines = (text, count = 2) => text.trim().split('\n').slice(-count).join(' | ').slice(0, 300);

// `cargo metadata --locked --offline` in one workspace: the deploy's own build (and its `--locked`) in
// the cheapest form that can still refuse. Three outcomes, and the difference is the point:
//   ok      the lock is coherent with the manifests, so a `--locked` build cannot refuse on it;
//   lock    the lock needs an update or cannot be read: a deploy of this tree cannot build the
//           workspace the sentinel is built from. That is a refusal.
//   skip    cargo is absent, or the offline cache cannot answer, so this gate has no opinion and says
//           so. Never a pass: a skip is counted and printed.
function checkLockfile({root, manifest}) {
  const absolute = path.join(root, manifest);
  if (!fs.existsSync(absolute)) {
    return {state: 'skip', detail: `${manifest} is not in this tree, so there is no lock to check`};
  }
  const version = run('cargo', ['--version'], {cwd: root, timeout: 60000});
  if (version.error === 'ENOENT' || (!version.ok && /not found/.test(version.stderr))) {
    return {state: 'skip', detail: `cargo is not on PATH here, so ${manifest}'s lock cannot be checked (the deploy builds it --locked)`};
  }
  const started = Date.now();
  const metadata = run('cargo', ['metadata', '--locked', '--offline', '--format-version', '1',
    '--manifest-path', absolute], {cwd: root, timeout: 240000});
  const ms = Date.now() - started;
  if (metadata.ok) return {state: 'ok', detail: `${manifest}: the lock is coherent with its manifests (${ms} ms)`};
  const text = `${metadata.stdout}\n${metadata.stderr}`;
  if (LOCK_REFUSAL.test(text)) {
    return {state: 'refused',
      detail: `${manifest}: a \`--locked\` build needs a lock update, which is what a deploy of this tree`
        + ` would refuse (${lastLines(text)}). Update that workspace's Cargo.lock in the same branch`};
  }
  return {state: 'skip',
    detail: `${manifest}: cargo could not answer offline (${lastLines(text) || metadata.error || `exit ${metadata.status}`}), so this gate has no opinion on its lock`};
}

// `components.lock`: the deploy installs exactly the names it pins and refuses to install anything else
// (`scripts/deploy.sh`, `wa_components_shipped`). A landing that empties it or drops `graph` makes main
// installable-by-name-only, which is the same failure one step later.
export function pinnedComponents(root) {
  const file = path.join(root, 'components.lock');
  if (!fs.existsSync(file)) return null;
  const names = [];
  for (const raw of fs.readFileSync(file, 'utf8').split('\n')) {
    const line = raw.replace(/#.*$/, '').trim();
    if (line === '' || line.startsWith('[')) continue;
    const name = line.split(/[=\s]/)[0].trim();
    if (/^[a-z0-9][a-z0-9._-]*$/i.test(name)) names.push(name);
  }
  return [...new Set(names)];
}

function checkComponents({root}) {
  const pinned = pinnedComponents(root);
  if (!pinned) return {state: 'skip', detail: 'components.lock is not in this tree, so there are no pinned components to check'};
  if (pinned.length === 0) {
    return {state: 'refused', detail: 'components.lock pins no component, which a deploy refuses (component_lock_empty): nothing would install'};
  }
  if (!pinned.includes('graph')) {
    return {state: 'refused',
      detail: `components.lock does not pin graph (component_lock_incomplete); every host.graph_* call runs it, so a deploy refuses this tree. Pinned: ${pinned.join(', ')}`};
  }
  return {state: 'ok', detail: `components.lock pins ${pinned.length} component(s) including graph`};
}

// The deploy's pin mechanics, on the commit this landing would push: a detached worktree at exactly
// that commit, read back and compared, then removed. It proves what `pin_failed`/`pin_mismatch` are
// about - the tree can be materialised and says which commit it is.
function checkPin({root, commit, dir}) {
  const pinRoot = path.join(dir, 'pin-check', commit.slice(0, 12));
  const cleanup = () => {
    spawnSync('git', ['-C', root, 'worktree', 'remove', '--force', pinRoot], {encoding: 'utf8', windowsHide: true});
    try { fs.rmSync(pinRoot, {recursive: true, force: true}); } catch {}
    spawnSync('git', ['-C', root, 'worktree', 'prune'], {encoding: 'utf8', windowsHide: true});
  };
  try {
    fs.mkdirSync(path.dirname(pinRoot), {recursive: true});
    if (fs.existsSync(pinRoot)) cleanup();
    const started = Date.now();
    const added = run('git', ['-C', root, 'worktree', 'add', '--detach', '--force', pinRoot, commit], {cwd: root, timeout: 120000});
    if (!added.ok) {
      return {state: 'refused',
        detail: `the merged commit cannot be pinned the way a deploy pins it (${lastLines(added.stderr || added.stdout) || `exit ${added.status}`}), so a deploy would refuse it (pin_failed)`};
    }
    const head = gitOk(pinRoot, ['rev-parse', 'HEAD']).trim();
    if (head !== commit) {
      return {state: 'refused',
        detail: `the pinned worktree reads ${head.slice(0, 12)} and not ${commit.slice(0, 12)} (pin_mismatch): a deploy would refuse to build something that cannot say what it is`};
    }
    return {state: 'ok', detail: `pinned ${commit.slice(0, 12)} as a detached worktree and read the same commit back (${Date.now() - started} ms)`};
  } finally {
    cleanup();
  }
}

// The compiled-inputs classification, from the deploy's own function. `wa_compiled_input` is the ONE
// definition of "a change to this path changes the compiled binary" (scripts/lib/node-binaries.sh says
// why), and the queue's `compiledInput` is the second implementation of it; the release manifest's
// `compiled_inputs=` digest is built out of the first, so a disagreement would let a release cover a
// commit that is not its build. The comparison is over the SET of compiled paths in the tree, not over
// the digest value: the two digests deliberately use different schemas
// (`wasm-agent-compiled-inputs/1` for a release, `wasm-agent-retest-inputs/1` for the retest proof), so
// equal digests were never the question - equal classification is.
function checkCompiledInputs({root, commit}) {
  const lib = path.join(root, 'scripts', 'lib', 'node-binaries.sh');
  if (!fs.existsSync(lib)) {
    return {state: 'skip', detail: 'scripts/lib/node-binaries.sh is not in this tree, so the deploy\'s compiled-inputs classification cannot be asked here'};
  }
  const listing = spawnSync('git', ['-C', root, 'ls-tree', '-r', '--name-only', '-z', '--full-tree', commit],
    {encoding: 'utf8', timeout: 120000, windowsHide: true, maxBuffer: 64 * 1024 * 1024});
  if (listing.status !== 0) {
    return {state: 'skip', detail: `the tree of ${commit.slice(0, 12)} could not be listed (${lastLines(listing.stderr) || `exit ${listing.status}`})`};
  }
  const paths = String(listing.stdout || '').split('\0').filter(Boolean);
  if (paths.length === 0) return {state: 'skip', detail: `the tree of ${commit.slice(0, 12)} lists no file, so there is nothing to classify`};
  // One bash process for the whole list: the loop body is a builtin call, which is why the deploy's own
  // function is written this way (it measured 24 s with a fork per line).
  const shell = run('bash', ['-c', '. "$1" && while IFS= read -r path; do [ -n "$path" ] || continue; wa_compiled_input "$path" && printf "%s\\n" "$path"; done; :',
    '_', lib], {cwd: root, timeout: 240000, input: `${paths.join('\n')}\n`});
  if (!shell.ok) {
    return {state: 'skip', detail: `the deploy's classifier could not be run here (${lastLines(shell.stderr) || `exit ${shell.status}`})`};
  }
  const theirs = new Set(shell.stdout.split('\n').filter(Boolean));
  const mine = new Set(paths.filter(file => compiledInput(file)));
  const onlyShell = [...theirs].filter(file => !mine.has(file));
  const onlyQueue = [...mine].filter(file => !theirs.has(file));
  if (onlyShell.length || onlyQueue.length) {
    const shown = [...onlyShell.map(file => `deploy-only ${file}`), ...onlyQueue.map(file => `queue-only ${file}`)].slice(0, 6);
    return {state: 'refused',
      detail: `the deploy's classifier and the queue's disagree about ${onlyShell.length + onlyQueue.length} path(s) of ${commit.slice(0, 12)}: ${shown.join(', ')}. A release manifest's compiled_inputs digest is built from the deploy's classifier, so a disagreement here decides which commits a published binary covers`};
  }
  // The digest the release manifest would carry, for the record (not compared: the schemas differ).
  const digestOf = run('bash', ['-c', '. "$1" && wa_compiled_inputs_digest "$2" "$3"', '_', lib, root, commit], {cwd: root, timeout: 240000});
  const digest = digestOf.stdout.trim().split('\n').pop() || '';
  return {state: 'ok', digest,
    detail: `${mine.size} of ${paths.length} path(s) are compiled inputs and both classifiers agree${digest ? ` (release digest ${digest.slice(0, 12)})` : ''}`};
}

// The whole gate. `dir` is the queue's state directory (the pinned worktree is made under it, never
// inside a tree anyone reads). Every check runs; the answer names each one, so a reader can see what
// was proved, what was refused and what this machine could not check.
export function deployGate({root, commit, dir, say = () => {}, quiet = false}) {
  const checks = [
    {name: 'lockfile', run: () => DEPLOY_WORKSPACES.map(manifest => ({...checkLockfile({root, manifest}), manifest}))},
    {name: 'components', run: () => [checkComponents({root})]},
    {name: 'pin', run: () => [checkPin({root, commit, dir})]},
    {name: 'compiled-inputs', run: () => [checkCompiledInputs({root, commit})]},
  ];
  const results = [];
  for (const check of checks) {
    for (const result of check.run()) {
      results.push({name: result.manifest ? `${check.name} ${result.manifest}` : check.name, ...result});
    }
  }
  const refused = results.filter(result => result.state === 'refused');
  const skipped = results.filter(result => result.state === 'skip');
  const ok = refused.length === 0;
  const why = refused.length
    ? refused.map(result => `${result.name}: ${result.detail}`).join('; ')
    : `${results.length - skipped.length} check(s) passed${skipped.length ? `, ${skipped.length} skipped` : ''}`;
  const line = `deploy gate ${ok ? 'ok' : 'REFUSED'} (${results.map(result => `${result.name}=${result.state}`).join(', ')})`;
  if (!quiet) say(line);
  return {ok, checks: results, refused, skipped, why, line};
}
