# The installer data leak (24/11): a test paused the factory

## What happened

scripts/test-upgrade-idle.sh ran `scripts/upgrade.sh` with the inherited environment. upgrade.sh writes the
deploy-pending signal BEFORE it waits:

    DEPLOY_SIGNAL_DIR="${WASM_AGENT_DATA:-${WASM_AGENT_HOME:-$HOME}/.wasm-agent}"     # upgrade.sh:648
    wa_deploy_signal_write "$DEPLOY_SIGNAL_DIR" "${PREVIOUS_COMMIT:-unknown}" "${COMMIT:-unknown}" ...  # :659

so one run of the row wrote ~/.wasm-agent/deploy-pending.json with `to: unknown`, and every session on
this machine paused after its step. No install was coming, so no node resumed them; the operator had to.

## The audit (Fable's 19 rows): does it RUN the installer with the real data dir?

Method: for each row, the lines that execute the installer (bash/sh/source/. in front of a path ending
upgrade.sh or deploy.sh, or a variable holding one), excluding `bash -n`, grep/cat/sed reads, extracted
blocks and $WORK/stub-* stubs. Then: does the file set WASM_AGENT_DATA / WASM_AGENT_HOME / HOME?

  test-upgrade-idle.sh        YES, and it leaked (the row above). Fixed: HOME, WASM_AGENT_HOME and
                              WASM_AGENT_DATA now point into its scratch tree, and it asserts the real
                              signal file was neither created nor touched (existence + size:mtime).
  test-glibc-floor.sh         YES, at :216 - it runs a COPY of the real upgrade.sh. It does not leak today
                              because this case is refused at the glibc guard (upgrade.sh:172) long before
                              the signal write (:648); it is one case away, so it is isolated too.
  test-deploy-downgrade.sh    no - reads deploy.sh only
  test-deploy-policy-order.sh no - `bash -n` (parses, runs nothing)
  test-deploy-record.sh       no - runs $WORK/stub-upgrade.sh, its own stub
  test-deploy-gate-policy.sh  no - reads
  test-deploy-ship.sh         no - reads
  test-deploy-node-binaries.sh no - extracts blocks and runs those; the sentinel-install block writes no signal
  test-deploy-self-ship.sh    no - reads
  test-deploy-runtime-recheck.sh no - grep/line_of
  test-deploy-staging-sweep.sh no - reads
  test-deploy-signal.sh       no - calls the signal library with its own $WORK
  test-update-ring.sh         no - reads and extracts
  test-watchdog.sh            no - reads
  test-install-default-policy.sh no - reads
  test-plugin-staging.sh      no - reads
  test-land-signing.sh        no - reads
  test-publish-shared-commit.sh no - lists file names
  test-commit-id.sh           no - reads

## The lint (so it cannot come back)

scripts/test-installer-data-isolation.sh (wired in scripts/test.sh) applies the same test to every
scripts/test-*.sh: a row that executes the installer must name its own state dir. Measured: 146 row(s)
checked, 5 installer invocations, all isolated. It is red at 5bb28d8a, naming test-upgrade-idle.sh and
test-glibc-floor.sh.

## Does fast.sh / main-health isolate this row? Checked, not assumed

- fast.sh states the contract it gives every row (fast.sh:440): "every row gets its own scratch
  WASM_AGENT_HOME, WA_COMPONENTS_DIR inside it, ... no rendezvous or relay". So a row run by fast.sh cannot
  write the operator's signal.
- main-health runs the fast path as a whole (`bash scripts/fast.sh`, main-health.sh:105) - and
  test-upgrade-idle.sh is NOT in fast.sh at all (0 occurrences). So main-health has never run this row,
  and main-health has NOT been pausing the factory through it.
- test.sh runs the row through gate_run, and the gate's HOME is a mktemp dir (test.sh:97, GATE_HOME). So
  the suite's own runs were isolated too.
- The leak needed the one thing all three avoid: the row run SINGLY with the operator's home. That is what
  happened, twice, on 24/11.

## The pauses it caused, counted

Source: the per-session pause records (~/.wasm-agent/deploy-paused/*.json, which hold only the current
cycle) and the sentinel's install units (~/.wasm-agent/sentinel/deploy.out). Rule used: a pause at time T
was caused by an install only if that install's unit started at or before T and T is inside the unit's own
1800 s bound - a signal is written by upgrade.sh from INSIDE a deploy, so a unit that starts after the
pause cannot be its cause (a first pass with a loose +-10 min window credited exactly that mistake).

    to:unknown pause rows today: 10
    explained by an install already running: 6
    with NO install running: 4  (17:06:51Z, 17:06:53Z, 17:06:53Z, 17:06:54Z - four sessions in four
                                 seconds, the signature of ONE leaked signal, and they match the
                                 orchestrator's 17:06 report exactly)
    ambiguous, and said so: 16:48:35Z sits 15 minutes after a unit that started 16:33:10Z, whose own
    phases take about five minutes - most likely a second leaked signal from a run before the row was
    isolated, not an install still waiting. Counting it as a leak gives 5; counting it by the rule gives 4.

The store keeps only the current cycle, so this is today's count and not a 2-day count: the records from
23/11 are gone, and I will not present a number I cannot read. The row landed today (change/
updates-never-touch-leak), so the leaks it caused are today's.

## What changed

commit 1: test-upgrade-idle.sh runs with HOME/WASM_AGENT_HOME/WASM_AGENT_DATA in its scratch tree and
          asserts the real ~/.wasm-agent/deploy-pending.json is untouched; the scratch dir's signal is
          witnessed DURING the run (the health stub copies it aside), because upgrade.sh clears the marker
          when the wait ends.
commit 2: test-glibc-floor.sh isolated the same way; scripts/test-installer-data-isolation.sh added and
          wired into scripts/test.sh, red on base.
