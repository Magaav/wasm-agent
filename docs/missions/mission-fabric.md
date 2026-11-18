# Mission change/mission-fabric — how missions run, as code and docs in the repo (deterministic workflow)

Victor 18/11: "bring this evolution as knowledge and deterministic workflow to our code fabric". Today the
orchestration lives in an operator's head and ad-hoc scripts. Put it in the repo:
1. `scripts/mission.sh` (one entry): `stage <name> <base> <brief>`, `start <name>`, `status [name]`,
   `report <name>`, `verify <name> <cmd...>`, `clean <name>`. It encodes, as mechanism not prose:
   toolchain on PATH; codemode; run from the mission dir, not the repo; build on this node only with the
   mission's own CARGO_TARGET_DIR; one fresh session per launch (a resume on a held lock is not retried
   blindly); a `done` marker with the rc; `status` counts real failures (`^! run_failed`), commits since base,
   and changed files; no `pgrep -f`/`pkill -f` that can match its own command line.
2. `docs/MISSIONS.md`: the loop as it ran on 18/11, with the measured failure behind every rule (cargo
   missing -> builds on the laptop at load 27; CodeAct loop on session_worktree; wave registration refusal;
   guard killing a legitimate wait; pkill self-match; duplicate main worktree blocking deploy; GLIBC 2.39 on
   mail): brief -> launch -> watch -> independent review -> fix round -> integrate -> land -> deploy canary
   -> fleet. Each step names its command.
3. A fixture test for scripts/mission.sh (stage/start/status/clean against a scratch repo and a stub `wa`).
Keep it small (KISS); no new daemon. Commit locally; never push.
