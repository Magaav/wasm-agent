# Independent review — `change/subagent-return-hardening`

- Delivery tip: `a68dfede26ae9a3a1af3f6dd6aeb77e9804bcd7e` (tree `6bf4c510382a22b2643dac8de84e932cfe3817ae`), 1 commit ahead of `main` `e2a86bc`.
- Producer: `child:dispatch:1280e7bd-c677-4d26-826b-5f4879496ed7`.
- Reviewer: `child:dispatch:5b769995-9281-42ba-bcc2-8e00f95b0589` — did not produce this delivery.
- **Verdict: narrowed.** Every claim the delivery makes about the artefacts I was asked to attack is
  reproduced on the exact tree, and the fixes hold under revert. But two of the claims are still
  **narrower than stated** and the widened derivation has **new false-positive classes**.
- Model note: this node's provider refuses `gpt-6-luna`, so the reviewer and the producer ran on the
  same model family (`deepseek-v4.1-flash`/high). Independence here is the lane and the reviewer's own
  commits and probes, not the model.

Review environment: own worktree `wa-worktree-childdispatch5b769995-9281-42ba-bcc2-8e00f95b0589`,
branch `review/subagent-return-hardening`, reset to `a68dfed`. `rust/wa-sentinel` is **not** a
workspace member, so the suites need
`cargo build --release --offline --manifest-path rust/wa-sentinel/Cargo.toml` (9.8 s incremental
afterwards) — a full `scripts/test.sh` was not run.

## 1. What the delivered drift guard refuses (proved, verbatim)

Driver: `review/subagent-return-hardening/guard-attacks.sh`. Baseline in a clean clone of `a68dfed`:
`deploy shipped ok (76 checks; 15 rules from the installers, 27 from ship-wave.mjs)`, exit 0.
`--list` prints 15 rules and `crates built here: rust/plugins/whatsapp-transcript`.

| attack | result |
| --- | --- |
| manifest drops `directories: jobs/` | exit 1 — `FAIL the predicate covers jobs/whatsapp-copilot.json (rule jobs/whatsapp-*.json, copied by deploy.sh, from the tree)` |
| manifest drops `globs: scripts/whatsapp-*` | exit 1 — `FAIL the predicate covers scripts/whatsapp-adapter.mjs (rule scripts/whatsapp-*, …)` |
| manifest drops `globs: scripts/subagent-return-*` | exit 1 — `FAIL the predicate covers scripts/subagent-return-hook.mjs …` |
| manifest drops `files: scripts/upgrade.sh` | exit 1 — `FAIL the predicate covers scripts/upgrade.sh (rule scripts/upgrade.sh, upgrade.sh installs itself as $0, …)` |
| plain `cp "$ROOT/scripts/gate-lane.mjs" …` | exit 1 — names `scripts/gate-lane.mjs` |
| `install -m 644 "$ROOT/scripts/check-naming.sh" …` | exit 1 — names `scripts/check-naming.sh` |
| `mv "$ROOT/scripts/gate-lane.mjs" …` | exit 1 |
| `cp -f "$ROOT"/scripts/gate-lane.mjs` (quote-then-slash) | exit 1 |
| `cp -f $ROOT/scripts/gate-lane.mjs` (unquoted) | exit 1 |
| the `cargo build` line for the WhatsApp plugin commented out | exit 1 — `FAIL copies rust/plugins/whatsapp-transcript/target/wasm32-unknown-unknown/release/wa_plugin_whatsapp_transcript.wasm … this installer does not build it` |
| a copy from `rust/plugins/nobody-builds-this/target/…` | exit 1 — names the path |
| a crate only named in a **comment** (`# cargo build … only-commented`) | exit 1 — comments are stripped before the build is read |
| glob rule with **no** example in the tree | synthesised (`scripts/whatsapp-probe (synthesised: nothing in this tree matches the rule)`) and **still checked**: with the glob also removed from the manifest it is `exit 1`, with the glob present `exit 0` — no silent skip |
| `# cp -f "$ROOT/scripts/ghost.mjs" …` (commented-out copy) | exit 0 — a comment is not read as a copy |

Claim 1 (76/15, `--list`), claim 2 (a build output is checked as a build output) and claim 7 (the
number is corrected here and pinned at 76; the earlier commit is in `main` and cannot be amended)
hold. Dropping `files: scripts/lib/service-target.sh` stays green, and that is **correct**: the
`scripts/lib/*` glob still covers the path.

## 2. Holes that remain (unresolved findings)

1. **A copy whose source is on a continuation line is invisible.**
   `cp -f \` ⟶ `  "$ROOT/scripts/gate-lane.mjs" \` ⟶ `  "$INSTALL_DIR/scripts/"` → `deploy shipped ok
   (76 checks; …)`, exit 0. Same for `mv` on the continuation form. `deploy.sh` itself already uses a
   continuation for the destination of the plugin copy, so this is a spelling the file already
   carries; "reads every copy-like line" is not true of it.
2. **Indirection is invisible.** `SHIP="$ROOT/scripts/gate-lane.mjs"; cp -f "$SHIP" …` → exit 0, and
   `cp -f "${ROOT}/scripts/gate-lane.mjs" …` → exit 0. Only `$ROOT`/`$SOURCE_ROOT`/`$SOURCE_UI` and
   the two installer variables (`DEPLOY_SRC`, `LIB_SRC`, `NEW`, `SOURCE_UI`) are resolved.
3. **`target/` is accepted for a crate the *other* installer builds.** The guard merges
   `builtCrates(deploy)+builtCrates(upgrade)` into one set and uses it for every rule, so a
   `cp -f "$ROOT/rust/only-upgrade-builds/target/release/thing.bin"` in `deploy.sh` **passes**
   (`built by this installer (rust/only-upgrade-builds)`, `deploy shipped ok (78 checks; 16 rules…)`)
   as soon as `upgrade.sh` builds that crate. The claim is "only for a crate the same installer
   builds", and the failure text says "this installer".
4. **`scripts/install.sh` is not read at all.** Dropping `deploy/` from the manifest stays green
   although `install.sh` installs `deploy/*.service`. `scripts/deploy-shipped.json` documents this
   entry as deliberately conservative rather than derived, so the guard does not enforce it — the
   "re-derived from the installers" claim is true of two installers, not of the install paths.

## 3. False positives on a legitimate tree (unresolved findings)

5. **Two assertions pin literal text, and equivalent respellings fail.**
   `check(text.includes('cp -f "$0"'), 'upgrade.sh still installs itself')` and
   `check(text.includes('"$SOURCE_ROOT"/skills/*'), 'upgrade.sh still installs skills/*')`.
   Respell the skills loop with the braced variable (`"${SOURCE_ROOT}"/skills/*`) → exit 1
   `FAIL upgrade.sh still installs skills/*`; replace the self-install with
   `install -m 755 "$0" …` → exit 1 `FAIL upgrade.sh still installs itself`. Both install exactly what
   they installed before, and the same commit claims to read every copy form "in every spelling".
6. **Every `$ROOT` path on a copy line becomes a rule, source or destination.** An in-tree staging
   step (`cp -f "$ROOT/scripts/lib/delivery-outbox.mjs" "$ROOT/scripts/lib/delivery-outbox.mjs.staged"`,
   `mv -f "$ROOT/scripts/lib/mod.gen.mjs" "$ROOT/scripts/lib/mod.mjs"`) is reported as
   `FAIL copies … which is not in the tree and this installer does not build it`. Prose inside a
   string is read as a copy too: `say "please install $ROOT/scripts/build-release.mjs by hand"` →
   exit 1 naming `scripts/build-release.mjs`. (Comment lines are stripped, but strings are not; the
   verb must merely be preceded by whitespace, which is why `fail "install …"` escapes and
   `say "please install …"` does not.)
7. **Documented exit code not implemented.** The header says "4 usage or an unreadable input"; an
   unreadable manifest and a missing `--installers` directory both exit **1** (with a `FAIL` line),
   while only a usage error exits 4.

## 4. The cursor (claim 3) — proved

Reverting the one line in `scripts/subagent-return-hook.mjs` to `effectExists(options, revision,
childId, event)` makes `node scripts/test-subagent-return-hook.cjs` red on exactly the named check:

```
AssertionError [ERR_ASSERTION]: a moved measurement still reconciles the intent through the payload it emitted ({"emitted":0,"duplicates":1,"reconciled":0,"errors":[]})
```

With the delivered line the suite passes `subagent return ok (206 checks; real sentinel, real git
checkouts, no model)`. Nothing is weakened: `effectExists` writes the payload it is handed to
`sentinel job receipt <job> <revision> <event_id> <file>`, and the call is scoped to
`pending.revision`, so the reconciliation asks the store whether *the event this pass emitted* is
queued — the only payload the receipt can confirm. `pending.payload || event` falls back to the old
behaviour for any state file written without a payload, and because a wake is also deduped by the
wake ledger, the change cannot lose a wake; it only converts "re-emits for ever (deduped, never
settled)" into "settles".

## 5. The ledger bound (claim 5) — proved, one residual

- Removing the prune makes the suite red on `AssertionError [ERR_ASSERTION]: the ledger is bounded
  after a wake (530 keys)` — the named revert.
- With it, the suite passes; a child whose key is inside the window is not re-woken across a
  revision change (`and the wake ledger still holds each child to one message`), and a child whose key
  left the window is woken exactly once (`a child whose key left the ledger is woken again (1)`).
- The give-up is stated where it is implemented (`WAKE_LEDGER_LIMIT` doc comment in
  `rust/wa-sentinel/src/jobs.rs`) and in `docs/JOBS.md`: "an id woken more than 512 wakes ago could be
  woken again if it somehow settled again".
- Residual (unresolved, low plausibility): the bound keeps the newest by `at` in **whole seconds**
  with a stable sort over the JSON map's key order, so a key written in the same second as ≥512
  others is ordered by name and *can* be the one truncated — the just-written key has no protection.
  I could not produce it: two seeded attempts (512 seeds at the current second, names sorting before
  the child) both left the new key strictly newest (`child_at=<seed second + 1>`), and 512 wakes in
  one second is far above this node's wake rates.

## 6. The supersede marker (claim 6) — proved

Removing the `.map(|value| { sync_completion_wake_marker(&s); value })` from the `enable`/`disable`
arm makes the suite fail after **3.2 s** on `AssertionError [ERR_ASSERTION]: job enable writes the
supersede marker with the enable, before any tick` — before the watcher exists in the fixture, so the
marker is not written by a tick. With it, `enable` writes and `disable` removes the marker with no
tick (`job disable removes the marker immediately, not on the next tick`), and the outbox suite
confirms the other end: `completion wake ok (real scheduler, mock inference, deduplication, one
failed-child notice, no recursive child, the hook supersedes the notice while its marker is
present)`. The residual `/jobs`-route window (~200 ms + one tick) is named in `docs/JOBS.md` rather
than hidden.
Corner (unresolved, unproven): `sync_completion_wake_marker` returns early when `store.list()` fails,
which leaves a stale marker in place — a *suppressing* marker with no enabled job. It needs a store
read to fail after a successful `enable`/`disable` (a race), and I could not construct it.

## 7. The floor and the 2-line proof-helper change (claims 4, 7) — proved

- `run_proof_fixture deployShipped 76` against the guard's real output → exit 0; against the same
  output with one check removed → `proof verdict refused: check count dropped: 75 < 76`, exit 1.
  `subagentReturn`'s floor is the suite's real 206 (`205 < 206` refused); `proof exit 1` and
  `unknown proof` are still refused.
- `scripts/lib/proof-verdict.cjs` changed by exactly one line (`numstat 1/1`): the added entry
  `deployShipped:'deploy shipped ok'`. No existing prefix, count, skip or failure-evidence rule was
  touched, an unknown kind still throws `unknown proof`, and every other proof's verdict is
  untouched — no verdict became cheaper to pass.
- `scripts/test.sh` is 6 insertions / 3 deletions (the "＋9" is changed lines, not pure insertions):
  the `subagentReturn` floor 168 → 206, and the guard's bare `gate_run` becomes
  `run_proof_fixture deployShipped 76 …`. The executed set is unchanged (`gate_run` literals 72 → 71,
  top-level proof fixtures 14 → 15 counting distinct kinds — which is what the commit body's numbers
  mean; call sites are 18 → 19).

## 8. Suites and trees, on the exact tip

- `node scripts/test-subagent-return-hook.cjs` → `subagent return ok (206 checks; real sentinel, real
  git checkouts, no model)`, exit 0.
- `node scripts/test-job-subagents.cjs` → `subagent integration ok (37 checks; real sentinel,
  protocol fixture, no paid inference)`, exit 0 — **only with the ambient
  `WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY` unset**: the fixture spreads `process.env` and its
  "deliberately without" case then reads `(env)` instead of `(file)`. That is a pre-existing fixture
  fragility, unrelated to this delivery (it is not in the diff), and it is why the bare run fails in a
  child's shell.
- `node scripts/test-completion-wake.cjs rust/target/release/wa.exe` → `completion wake ok …`, exit 0.
- `node scripts/check-deploy-shipped.mjs` → `deploy shipped ok (76 checks; 15 rules from the
  installers, 27 from ship-wave.mjs)`, exit 0.
- `git merge-tree --write-tree main HEAD` → exit 0, clean.
- Mutations that went red (≥3 required): the cursor revert, the marker-call removal, the prune
  removal, four manifest drops, eight installer-copy mutations, two literal-respelling mutations.
- Not run: the full `scripts/test.sh` (the whole gate), anything on the live node, any deploy, any
  push. Nothing was enabled.

## 9. Verdict

`narrowed`. The four substantive fixes I was pointed at (derivation width for the listed spellings,
the cursor settling through the emitted payload, the ledger bound with its give-up stated, the marker
written by the verbs themselves) are proved on this tree and each fails first under its named revert,
and the floor and the proof-helper change are additive. The guard still derives less than its own
header and docs claim (continuation lines, variable indirection, braced `$ROOT`, the cross-installer
`target/`, `install.sh`) and now refuses two legitimate respellings and two legitimate copy shapes, so
the guard should not be described as reading "every copy-like line in every spelling" until those are
closed.
