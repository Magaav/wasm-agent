# whatsapp-posting-toggle: the switch talks to the component, not to the removed Go connector

Branch `change/whatsapp-posting-toggle`, base `41d6420c`. Measured 2026-11-23 (local, -03:00) on `avell`.
**No live node was touched**: no `wa call`, no `tools.remote`, no `services` verb and no read of `openclaw`
ran from this round (FACTORY rule 13), so every fact below is either a read of this tree, a read of the
base commit in a separate worktree, or a measurement of a scratch node on this machine.

## 1. What the brief claimed, re-measured

| premise | verdict |
| --- | --- |
| posting is gated by `post_transcripts` + `post_allow` (`posting.rs:42-43`) | **true, unchanged**: `rust/components/wa-whatsapp/src/posting.rs:42-43`, read by `PostConfig::from_json` |
| the stored definition on `openclaw` has no `config` key | **not re-measured** (rule 13 forbids reading the live node from here). Accepted from `docs/missions/reports/whatsapp-transcription-works.md` and **reproduced**: the new row stores a definition with no `config` on a scratch node and reads back `posting=off`, `allow_count=0`, `posted=0` - the exact openclaw shape |
| the only operator door is `wa_whatsapp_posting`, `lua/core/server.lua:545` | **the defect is real, the line was stale**: on base `41d6420c` the function starts at `lua/core/server.lua:614`, reads `WA_WHATSAPP_POSTING_URL` at `:621` and POSTs `/operator/posting` at `:655` |
| that door points at the Go connector removed in Phase 4 (11/11) | **true**: `67c78621` "feat(whatsapp): retire the Go connector from the tree (Phase 4)", `2026-11-11T22:00:13-03:00`. `grep -rn 'operator/posting'` over `lua/`, `rust/` and `ui/` matches only my own prose and one test assertion; nothing calls it |
| the only path to turn posting on is a hand-edited definition (`disable` -> `put` -> `enable`) | **true**, read from `lua/core/services.lua`: `put` refuses `service_enabled: disable it before changing its definition`; `enable` starts the instance and only then stores `enabled=true` |

One more measurement the brief did not have: the old door needed **five** environment variables before
it would even try. With only `WA_WHATSAPP_POSTING_URL` and the read-token file set, it still answered
`whatsapp_posting_not_configured`; with all five it made **three** HTTP POSTs in one session, every one
to the configured URL.

### The old door's real answers (golden, rule 14)

Recorded from the base commit, in a separate worktree (`/tmp/wa-base-41d6420c`), by driving the real
`wa_whatsapp_posting` through a `WA_SCRIPT` probe with `host.getenv` and `host.http` stubbed. Kept as a
fixture the new row reads: `tests/fixtures/whatsapp-posting-old-door.json`.

```
OLD status (no connector env): {"error":"whatsapp_posting_not_configured"}
OLD status: {"connection":"connected","enabled":true,"ok":true}
OLD set on: {"enabled":true,"ok":true}
OLD set off: {"enabled":false,"ok":true}
OLD set non-boolean: {"error":"posting_enabled_boolean_required"}
OLD bad action: {"error":"invalid_posting_action"}
OLD bad body: {"error":"invalid_posting_request"}
OLD guest: {"error":"forbidden"}
OLD http calls: 3 http://127.0.0.1:1//status
```

The new door keeps every one of those *words*: `ok`, `enabled`, `connection`, `error`, and the refusal
codes `forbidden`, `invalid_posting_action`, `invalid_posting_request`, `posting_enabled_boolean_required`.
The row asserts that against that fixture, field by field and type by type.

## 2. What landed

| commit | what |
| --- | --- |
| `0f530bf9` | `lua/core/whatsapp_posting.lua` (the switch: gate, allow-list validation, write through the services registry, safe restart, health-line verification), `lua/core/whatsapp_posting_cli.lua` (`wa whatsapp posting`), the route in `lua/core/server.lua` (the connector transport removed), the `wa whatsapp posting` dispatch and its `wa help` line in `lua/core/init.lua`, `scripts/test-whatsapp-posting-toggle.lua`, `tests/fixtures/whatsapp-posting-old-door.json` |
| `541f8a12` | `docs/WHATSAPP-TRANSCRIPTION.md` ("The operator switch"), `docs/SERVICE-COMPONENTS.md`, the row in `scripts/test.sh`, the UI wording in `ui/components.js` |
| `ca0ae9b9` | the row (`scripts/test-whatsapp-posting-toggle.lua`, added in `0f530bf9`) loads the switch through `pcall`, so a tree without it fails on a **named check** (the shape `scripts/test-discriminates.sh` reads) instead of a raw load error |

No Rust was changed: the operator route already exists and is wired
(`rust/wa-capabilities/src/serve.rs:4166` -> `wa_whatsapp_posting`), and it was the handler's *target*
that was removed, not the route.

## 3. The verb

```text
wa whatsapp posting                       # status (default)
wa whatsapp posting on | off
wa whatsapp posting allow own             # or: *, 5511999999999@s.whatsapp.net, 1203...@g.us
wa whatsapp posting alerts on | off
wa whatsapp posting language en|pt|auto
wa whatsapp posting status --json         # the module's own answer
```

The operator endpoint is the same decision: `POST /whatsapp/posting` with
`{"action":"status"}` or `{"action":"set","enabled":true,"allow":["own"],"alerts":true,"language":"pt"}`.

What a `set` does, in order, and what it refuses to do:

1. **The gate**: master only (`require_master` on the route, `users.is_master` in the module, a child
   agent refused, a caller with no role refused). A refusal is `forbidden` and nothing is read.
2. **The allow-list** is validated as an allow-list of the forms the component's own gate matches:
   `own`, `*`, `<digits>@s.whatsapp.net`, `<digits>@lid`, `<id>@g.us`. An entry that is none of these is
   `posting_allow_invalid` and the refusal names the **position**, never the entry. An empty list is
   `posting_allow_required`, and so is turning posting **on** without a scope - `post_transcripts: true`
   with an empty list is exactly the shadow mode that made this mission necessary.
3. **The four keys it owns** are `post_transcripts`, `post_allow`, `alerts`, `language`. Every other key
   (`stream_edits`, `held_chats`, `pair_phone`, `health_every_seconds`, the index settings) is copied
   through untouched - measured in the row, which sets `stream_edits`, `health_every_seconds` and
   `held_chats` and reads them back after a verb that changed only `language`.
4. **The write** goes through the services registry: `disable` -> `put` -> `enable`, with the registry's
   compare-and-set revision re-read between the steps. If `put` is refused, the old definition is still
   stored and the component is started again on it; if `enable` is refused, the OLD definition is put
   back and started, and the answer says `restored=true`. A definition written but not runnable never
   survives the call.
5. **The verification** reads the stored definition back (`whatsapp_posting_store_unverified` if it does
   not read as asked) and then reads the **component's own health line**: `posting=<on|off> posted=<n>
   last_post=<...>`, the line `src/health.rs` prints at start. Only the tail after the run's own
   `clock:` line is parsed, so a health line inherited from an earlier instance is not evidence. A mode
   the component did not reach is `whatsapp_posting_not_effective`; a line that cannot be read is
   `whatsapp_posting_unverified` with `written=true` - unknown is not yes.
6. **Nothing changed** means nothing written and nothing restarted: `unchanged=true`.

## 4. Security

* **Who can change it**: a master on this node, and only a master. The route gates on `require_master`
  (the same authority as every other operator endpoint), the module re-checks with `users.is_master`,
  `services.control` refuses a guest and a child agent again for every write, and a caller with no role
  is refused. `admin` normalises to master exactly as it does everywhere else (`users.normalize`).
* **The allow-list never leaves the operator's own answer**: it is not logged (`host.log` is wrapped in
  the row and every line is checked), it is not echoed in a refusal (the refusal carries `index`, the
  position), and it is never written into this repository - the row and the fixture name only `own`,
  `*` and synthetic JIDs. The UI shows a count, not the list.
* **The removed transport cannot be reached**: the handler no longer reads any environment variable and
  no longer touches `host.http` (asserted on the function's own body), and a request that carries the
  removed API's fields (`account`, `generation`, `posting_url`, `target_url`) is refused by name,
  `whatsapp_posting_connector_removed`. A node whose environment still sets the connector's five
  variables is told so on every answer, by name, with no value printed.

## 5. Tests, and where they run

`scripts/test-whatsapp-posting-toggle.lua` - **120 checks**, run under `WA_SCRIPT` with its own scratch
`WASM_AGENT_HOME`, its own database, the node's real services registry and real SQL; only `host.service`
is a stub (see the row's header for why the shared contract fake does not cover it and what shapes it
copies from `rust/wa-kernel-runtime/src/services.rs`).

What it proves, in order: a definition with no `config` reports posting off (the openclaw shape);
turning posting on without a scope is refused; the switch turns it on and the **component's** health line
says `posting=on posted=3`; the exact four keys are what the component was started with; a no-op set
writes nothing and restarts nothing; other config keys survive; the allow-list forms and every refusal;
a guest, a child agent and a role-less caller are refused and the store is untouched; the route refuses a
guest session and answers a master; an unreadable health line is `..._unverified`; a component that
refuses to start gets the old definition back and keeps running it; the CLI's verbs and the `wa help`
line; the removed connector is never called even with its five variables set, and its API fields are
refused by name; and the recorded old-door answers keep their fields and words.

**Where it is wired.** (a) The fast path: `scripts/fast.sh` enumerates every `scripts/test-*.lua` that
`scripts/fast-path.exclude` does not name, so this row runs on every fast run, narrowed or not - no
registration needed, and `scripts/test.sh`'s row inventory is the same function. (b) The full gate: a
`WA_SCRIPT` line in `scripts/test.sh` next to the other `WA_SCRIPT` route rows, with its own scratch home
and a `GATE_ROOT` so the home guard can tell it from a real one.

**Does it fail on the code before the change?** Yes, measured twice:

* the row run against the base commit's Lua tree (`WASM_AGENT_LUA_ROOT=/tmp/wa-base-41d6420c`, this
  tree's row): `lua error: ...:57: WHATSAPP POSTING CHECK FAILED: the operator switch exists as a module
  (lua/core/whatsapp_posting.lua)`, exit 1 - a named assertion, the shape
  `scripts/test-discriminates.sh` reads as `discriminates`;
* the base's own handler still names the removed route: `grep -c '/operator/posting'
  /tmp/wa-base-41d6420c/lua/core/server.lua` = 1, which the row's section J refuses.

### One more measurement, through the real binary and the real host (not the row)

The row stubs `host.service`. To check the half a stub cannot check, the verb was run through the built
node binary, its own services store and its own `host.service`, in a scratch `WASM_AGENT_HOME` with a
stored definition and **no component artifact installed**:

```text
$ wa whatsapp posting allow own
posting   off
allow     own
alerts    off
language  pt
component not_running
health    unavailable (whatsapp_posting_component_not_running)
written   yes
note      the component is stored disabled, so nothing is running to report its posting mode; `wa services enable wa-whatsapp` starts it
$ wa whatsapp posting on        # exit 0, same shape, posting on
$ wa whatsapp posting status --json
{"alerts":false,"allow":["own"],"allow_count":1,"connection":"not_running","enabled":true,"language":"pt","live":false,"name":"wa-whatsapp","note":"...","ok":true,"posting":"unknown","stored":true,"unverified":"whatsapp_posting_component_not_running"}
$ wa whatsapp posting status    # before any definition is stored
whatsapp posting: status: whatsapp_posting_component_missing      (exit 1)
$ wa whatsapp             # the other door under the same word, unchanged
wa whatsapp archive <verb> [YYYY-MM] [--to <node|dir>] [--keep-local] [--json]
```

So the store half, the CLI dispatch, the `wa help` line and the honest "unknown, because nothing is
running" answer are measured against the real node, not only against the fake. What is **not** measured
here is an enabled definition starting for real: that needs a built `wa-whatsapp.wasm` and a live
WhatsApp session, which this round does not have (and must not touch).

## 6. The suite (the G-wave rule: no full gate, only the rows for the files touched)

The G-wave rule (`flock -o ~/Work/missions/.suite.lock`, only the rows the touched files map to): the
request named **40 rows** (every `scripts/test-*.lua` that reads `lua/core/server.lua` or
`lua/core/init.lua`, plus this mission's own row); the runner selected **67 of 342** Lua rows - the
never-dropped core rows are added by `scripts/lib/fast-rows.sh` - and every non-narrowable contract check
ran.

Measured: **155 checks, 1 failed, 0 skipped, 694 s** (`wa-fast-result.json`; evidence kept in
`.../wa-fast-evidence/20261123T134347Z-2373974`).

* The one failure is `esc-stops-pty`, an always-on PTY assertion in `scripts/fast.sh` ("Esc brings the
  prompt back at once ... never over 2000"), not a row of this round. It is **pre-existing under this
  machine's load, not this change**: the same check fails the same way against the BASE commit's Lua tree
  (`WASM_AGENT_LUA_ROOT=/tmp/wa-base-41d6420c`), 17 ok / 1 failed, at load average 32 on 16 cores while
  four other missions' fast runs queued on the same `.suite.lock`.
* Two earlier attempts at the same narrowed run produced no verdict: node installs (the orchestrator's
  deploys at ~13:5x and ~14:0x) restarted the node under them. One of them is why the run that did finish
  found the component fixtures (`graph hooks memory selfloop mesh codemode svc-echo`) already built and
  pinned from this tree.
* The runner **refused** the first request by name rather than silently dropping rows
  (`fast_narrow:unknown_row: scripts/test-session-isolation.lua is not a row this run can execute`), which
  is the behaviour `scripts/lib/fast-rows.sh` promises; three of my 43 candidate rows are
  `scripts/fast-path.exclude`d and were removed from the request, not run.

Not run, by the brief: the unnarrowed `scripts/fast.sh`, `scripts/test.sh`, `scripts/test-preflight.sh`
and `wa land --until gate`.

## 7. What I did not do, and what I could not verify

* **Nothing on a live node.** Posting on `openclaw` is still off and the definition there still has no
  `config` block. Turning it on is the orchestrator's call: `wa whatsapp posting on` +
  `wa whatsapp posting allow '*'` (the recovered connector configuration) on that node, or the same
  through `POST /whatsapp/posting` there.
* **Not pushed, not landed** (the brief: commit locally, Fable reviews).
* **No Rust test changed and no Rust test added**: the component's own `health.rs`/`posting.rs` tests
  already hold the two contracts this verb depends on (the line's format and the allow-list's semantics),
  and the row cites them instead of duplicating them.
* **The definition on the serving node was not read** (rule 13), so "the stored definition has no
  `config` key" is accepted from the previous mission and reproduced, not re-observed.
* **The `wa services list` defect** (the CLI reports `not_running` for a service running on the serving
  node, said in `lua/core/services_cli.lua`) is unchanged and still open; this verb only ever talks to
  the node it runs on.

## 8. Texts to approve

1. The CLI usage block (`lua/core/whatsapp_posting_cli.lua`):
   ```text
   wa whatsapp posting <verb> [--json]
     status    what is stored, whether the component runs, and what its health line reports
     on        post the transcript of every allowed chat
     off       post nothing (transcription keeps working)
     allow     the chats posting may reach: own, *, or exact chat JIDs, comma separated
     alerts    the own-chat alert when a note could not be transcribed: on|off
     language  the language the pipeline transcribes in: en|pt|auto
   ```
2. The `wa help` line: `whatsapp posting status|on|off|allow <chats>|alerts on|off|language <code>  the
   component's transcript posting switch`.
3. The refusal codes this verb adds: `whatsapp_posting_component_missing`,
   `whatsapp_posting_connector_removed`, `posting_allow_required`, `posting_allow_invalid`,
   `posting_allow_too_many`, `posting_language_invalid`, `posting_alerts_boolean_required`,
   `posting_change_required`, `whatsapp_posting_write_refused`, `whatsapp_posting_start_refused`,
   `whatsapp_posting_store_unverified`, `whatsapp_posting_unverified`,
   `whatsapp_posting_not_effective`, `whatsapp_posting_health_unreadable`,
   `whatsapp_posting_component_unavailable`. Kept verbatim from the old door: `forbidden`,
   `invalid_posting_request`, `invalid_posting_action`, `posting_enabled_boolean_required`.
4. The one refusal sentence that carries the security rule, verbatim: "one allow-list entry is not an
   accepted form. Accepted: \"own\", \"*\", or one exact chat JID (<digits>@s.whatsapp.net,
   <digits>@lid, <id>@g.us). The refused entry is not repeated here on purpose: the allow list is never
   echoed back".
5. The empty-list sentence: "posting cannot be turned on with an empty allow list: an empty list posts
   nowhere. Name the chats it may reach - \"own\" for the account's own chat, \"*\" for every chat, or
   exact JIDs - or turn posting off with enabled=false".
6. The four UI strings changed in `ui/components.js`: "Reading the posting switch..."; "The component is
   running; transcripts of the allowed chats are posted."; "Component <state>."; "Transcript replies
   enabled for the allowed chats." (with "Transcript replies disabled." unchanged).
7. The two documentation sections: `docs/WHATSAPP-TRANSCRIPTION.md` -> "The operator switch: posting on
   the component (2026-11-23)", and the paragraph added to `docs/SERVICE-COMPONENTS.md` under the
   component's configuration table.

## 9. Proposals (never written)

**FACTORY.md:**

> A switch's answer is the component's, never the request's. When an operator verb changes a component's
> configuration, it answers with what the component reports afterwards - its health line, its own
> counters - and refuses by name when it cannot read them, even though the write succeeded. 23/11:
> `wa whatsapp posting` writes `post_transcripts`/`post_allow` through the services registry and answers
> `posting=on posted=<n>` from the line the component printed after the restart, because "the definition
> says on" and "the component posts" were two different facts for twelve days and only the second one
> delivered a transcript.

> If a feature is gated by a config key, that key has a supported operator verb, and the answer to
> "is it on" comes from the thing that does the work. The verb owns its keys by name and copies every
> other key through, so a policy change cannot silently rewrite the pipeline's tuning.

**HANDOVER.md:**

> WhatsApp posting is switched on and off on the **component**, not on a connector:
> `wa whatsapp posting status|on|off|allow <chats>|alerts on|off|language en|pt|auto` (the same decision
> behind `POST /whatsapp/posting`). It writes the definition through `wa services`'s registry
> (`disable` -> `put` -> `enable`), restarts the component and answers with the health line it prints
> (`posting=on|off posted=<n>`). The Go connector's `/operator/posting` door is gone and a request that
> still carries its fields is refused by name. The allow-list is master-only, never logged and never
> echoed in a refusal. On `openclaw` the definition still has no `config` block, so posting is off until
> an orchestrator runs `wa whatsapp posting on` and `wa whatsapp posting allow '*'` there.
