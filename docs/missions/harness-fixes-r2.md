# harness-fixes round 2 — independent review of 62c3c064 (verdict: land after fixes)

Work in the same worktree/branch (change/harness-fixes, on top of 62c3c064). Each finding: fix + a test that
fails on 62c3c064 and passes after; append to REPORT.md. Commit locally; never push. Build here only.

1. BLOCKER — remote sessions count as the operator's session (item 4). workspaces.lua:60-65 `operator_session`
   only checks no parent/fork and objective ~= 'subagent'; a session started by another node
   (objective='remote', session_watch.lua:214) passes, and so does a root session of ANY principal (user_id
   never checked) -> remote callers skip wave admission. Accept only objective nil/'' , exclude 'remote',
   require the node owner as principal. Negative test through ensure(), not only wave_admission_outcome.
2. BLOCKER — the operator path crashes when allocating. workspaces.lua:409 sets start_state.wave_admission
   before `local start_state` exists (line 412): nil global index, ensure() throws; line 412 would overwrite it
   anyway. The path also creates a new worktree, which is not "in place" as claimed. Set it after 412; make
   "in place" true or reword it. Test through ensure().
3. BLOCKER — nodes with code mode off lose JS answers (item 1). Default mode is `only` (raw_code.lua:85);
   agent.lua:2599 reads blocks whenever a mode is set and take() retags under `only` (line 375), so on a node
   with code mode off every plain ```js sample in an answer becomes a failing codemode call
   (codemode_not_enabled). Use only(policy) for the retag; outside `only` act only on blocks tagged `js run`.
4. `unexecuted` false failures (item 2). raw_code.lua:208-225 scans every line including inside other blocks:
   a 4-space fence inside a list item (valid CommonMark), a `js run` example inside a ````md block, and plain
   `js` under `only` all fail a normal answer. Flag only fences outside any parsed block.
5. deploy no longer re-checks before install (item 9). deploy.sh:399 exports WA_RUNTIME_WORKTREE so the
   install-time check (line 1254) is skipped: the "clean and equal to main" re-check after a long build is
   gone. Keep the preflight value separately and re-run the check at install, comparing both.
6. A failed uncertainty mark is now silent (item 5). agent.lua ~1752: when `uncertain` fails and `finish`
   succeeds nobody hears it and finish deletes the claim and its uncertainty; the comment "both facts are
   reported" is false. Emit the uncertainty failure on its own.
7. The run-claim test proves less (item 5). test-run-claim-release.lua replaced the real end-to-end test with a
   fake host whose reconcile frees the key unchecked. Keep the real-host test too.
