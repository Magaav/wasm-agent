# project-instructions-once - the same project instruction text is never put in the prompt twice

Branch `change/project-instructions-once`, base `41d6420c`. Everything below was measured on this node
(avell), on the trees named, with no model call.

Commits: `48c742dd` (loader + tests), `1f8aad90` (docs/LAYERED-PROMPT.md), `1682f326` (the probe reports
content and wire bytes).

## 1. Re-measured before writing code (brief item 1)

The premise holds, with two numbers that were slightly off in the brief:

- `/home/victor/wasm-agent/AGENTS.md` and `/home/victor/wasm-agent/checkout/AGENTS.md` are byte-identical
  (`cmp` prints nothing), 6,924 bytes each, re-measured 23/11 ~12:5xZ.
- A prompt built for an empty master session (the shape `scripts/probe-prompt-bytes.lua` builds: pinned code
  mode, no model call) with cwd `/home/victor/wasm-agent/checkout` was **27,540 content bytes (27,994 wire
  bytes)** and held two `project_instructions` frames, `path="/home/victor/wasm-agent/AGENTS.md"` and
  `path="/home/victor/wasm-agent/checkout/AGENTS.md"`, 6,924 bytes each.
  - The brief says "74 distinct long lines appear twice, 6,714 bytes of repeated lines"; counted over lines
    of 60 characters or more I measure **68 lines, 6,385 repeated bytes**. The difference is the threshold
    (shorter lines are not counted by mine). The conclusion is the same: 6,924/27,540 = **25.1%** of the
    prompt.
  - The brief says the empty scratch dir is 13,561 bytes; I measure **13,505 content / 13,755 wire bytes**.
    Same conclusion, 56 bytes apart (the environment-note path and the session's workdir line).

## 2. The change (commit `48c742dd`)

`lua/core/agent.lua M.project_instructions` still walks every ancestor, and now carries one frame per
distinct text: a file whose content is byte-identical to another one in the same list is dropped, the copy
**nearest the workdir** is the one kept (the chain is root-first, so the last occurrence of a text wins and
the most specific file keeps its place last), and every skipped path is named on the kept file
(`same_text_as`), which `agent.system_sections` renders as an attribute of the frame the model reads. No
prose is added.

- Two paths that resolve to one real file (a symlink, a hard link) are covered by the same rule: the loader
  compares what it read, not the path.
- The global `<config>/AGENTS.md` and the environment note ride the same list, so a seeded copy of a project
  file is carried once too (the project file kept).
- `docs/LAYERED-PROMPT.md` states the rule (commit `1f8aad90`).

The frames on this node, cwd `~/wasm-agent/checkout`, after the change:

```
<project_instructions path="AGENTS.omarchy.md">
<project_instructions path="/home/victor/wasm-agent/checkout/AGENTS.md" same_text_as="/home/victor/wasm-agent/AGENTS.md">
```

## 3. Worktrees (brief item 3)

A git worktree placed INSIDE its parent checkout got the parent's `AGENTS.md` plus its own copy: measured on
`/tmp/pi-parent/wt` (a real `git worktree add` inside a repo whose root carries an `AGENTS.md`), 13,705
content bytes, two 20-byte copies. After the change: 13,645 content bytes, one frame,
`path="/tmp/pi-parent/wt/AGENTS.md" same_text_as="/tmp/pi-parent/AGENTS.md"`. The mission worktree this round
runs in has no repo above it and never had a duplicate: 20,596 bytes before and after, one frame.

## 4. The prompt cache (brief item 4)

Same probe, content / wire bytes, base `41d6420c` vs this branch:

| cwd | before | after |
| --- | --- | --- |
| empty scratch dir | 13,505 / 13,755 | 13,505 / 13,755 (unchanged) |
| clean repo, one AGENTS.md | 13,596 / 13,853 | 13,596 / 13,853 (unchanged) |
| mission worktree, no duplicate | 20,596 | 20,596 (unchanged) |
| `~/wasm-agent/checkout` (had the duplicate) | 27,540 / 27,994 | **20,576 / 20,930** |

A session without a duplicate does not change by one byte (the prefix cache is untouched); a session that had
one changes once, smaller: **-6,964 content bytes (-25.3%), -7,064 wire bytes**. That is the ~6.9 KB the
context meter shows.

## 5. Tests (brief item 5)

`scripts/test-project-instructions.lua` (commit `48c742dd`), wired where it already ran: `scripts/test.sh:1307`.
The row now has 20 checks; the new ones are:

- two byte-identical ancestor files -> ONE frame, the copy nearest the workdir kept, the skipped path named in
  `same_text_as` and in the rendered frame;
- the same text reaches the prompt once (counted in the rendered `<project>` block);
- two DIFFERENT files at the same depths -> both, root-first (the rule is about bytes, not depth);
- a symlinked instruction file -> one frame;
- a git worktree inside its parent checkout -> one frame, the worktree's own file kept, the parent named.

On the base (`41d6420c`, separate worktree at `/tmp/pi-base`, this test file copied in) the row fails at its
first new check: `two byte-identical ancestor files are one frame, got 2`. On this branch: `project
instructions ok (20 checks, 0 skipped)`.

## 6. Which number is the real first request (planner amendment, 23/11 16:03Z)

The probe's number and the ledger's number are two counts of the same prompt, and neither is wrong:

- **`scripts/probe-prompt-bytes.lua` `system_bytes`** is `#tostring(messages[1].content)` - the CONTENT of the
  system message, the exact string the model reads. The code-mode block is already inside it (`system_sections`
  appends `codemode_policy.prompt(...)` when code mode is on) and is reported again separately as
  `codemode_bytes` = 1,388 B.
- **The ledger's `harness_events.prompt_shape.system_bytes`** is `#json.encode(message)`, the WIRE bytes of the
  same message (`lua/core/telemetry.lua:185-211`, `encoded = #json.encode(message)`). JSON framing and escapes
  add a measured **250 B** to a 13.5 KB prompt, **354 B** to 20.5 KB, **454 B** to 28 KB.

Measured both, same tree, same minute:

| cwd | content | wire |
| --- | --- | --- |
| empty scratch dir | 13,505 | 13,755 |
| clean repo, one AGENTS.md | 13,596 | 13,853 |
| `~/wasm-agent/checkout` before | 27,540 | 27,994 |
| `~/wasm-agent/checkout` after | 20,576 | 20,930 |

So: what the model actually receives on a real first request is the content string; what the ledger records is
that same message serialized (plus, for a real session, that session's own workdir/role/keys lines, which a
scratch home does not reproduce - that residual is ~145 B between my empty-dir wire figure and the ledger's
~13.9 KB and I did not verify it character by character). The ledger's ~13.9 KB is an empty-or-small-cwd
session; the 27,540 was a checkout session CONTENT with the duplicate still in, whose wire figure is 27,994.
The two numbers were never comparable: one content, one wire.

**Fixed:** `scripts/probe-prompt-bytes.lua` now prints `system_wire_bytes` next to `system_bytes`, and its
header says which count each one is and that the ledger counts the wire (commit `1682f326`). "Nothing the model
reads changes" checks stay on `system_bytes` (content is what the tokenizer and the cache see); a comparison
with the ledger uses `system_wire_bytes`.

**The +2.6 KB step from `5a4b1a29` I could NOT verify, and I did not fake it.**

- Measured: I built the pinned-code-mode prompt (the real shape) in one fixed empty cwd from three trees -
  `f05b3150` (before the step), `5a4b1a29` (where the ledger steps) and `41d6420c` (today) - with each tree's
  own code. Byte-identical in all three: content 13,505, wire 13,755, and the same section sizes (`generic`
  5,838, `stack` 2,857, `workflow` 1,424, `project` 1,788, `session` 200, code-mode block 1,388, deferred-index
  lines 44). For a session of that shape the step is not in the prompt those builds produce.
- Ruled out by inspection: `prompt_shape` itself did not change (`git log -S "function M.prompt_shape"` ->
  `43e8c0c8`, before the range); `5a4b1a29` touches no prompt text (its `lua/core/agent.lua` change is the audit
  spool flush and the secret-redaction record; `docs/HOST.md` is not in the prompt); `AGENTS.orchestrator.md`
  (the `<workflow>` frame) is unchanged across the range.
- What I could not read: the ledger. `sqlite3 -readonly <store>/memory.db` is refused for the agent's own tools
  - `secret_path_denied`, "this is the node's own store: it holds the MCP registry, every connector's approval
  and the session ledger, so an agent tool neither reads nor writes it" (`lua/core/secret_guard.lua`,
  `M.ROOTS`), where `<store>` is the data directory `wa paths` prints. No CLI surface projects `harness_events`
  either: `wa events --kind model_call --json` answers `wa events: refused(kind_unknown): model_call - the
  kinds are land, mission`. I did not go around the guard.
- The query that settles it, for the operator (run it outside the agent's tools):

```sql
sqlite3 -readonly <store>/memory.db "
select id, datetime(created_at,'unixepoch'),
       json_extract(data,'$.prompt_shape.system_bytes'),
       json_extract(data,'$.prompt_shape.project_bytes'),
       json_extract(data,'$.model')
from harness_events
where kind='model_call'
order by id desc limit 40;"
```

  Read it with the session's own context: if the stepping sessions run in a checkout/worktree whose ancestors
  carry an `AGENTS.md`, their `<project>` frame alone moves by 1.8 KB to 7.0 KB, which is session shape and not
  a commit. If the numbers step for one fixed cwd, that is a ledger finding of its own, not of this round.

### The guard refusal, as evidence (the operator asked for it in the report)

Writing this report the natural way - a `cat <<'EOF' > <report path>` heredoc in a shell call whose *text*
contained the store path (inside the sql query above) - was refused whole: `tools.bash failed:
lua/core/secret_guard.lua refused bash: secret path denied (secret_path_denied)`. The command would have
written a file outside the store and only quoted the path as inert text; the guard matches the command string,
so the write died with the mention. I wrote the file with the file-writing tool instead, and this report uses
`<store>` in place of the literal path for the same reason. That is the shape `secret-guard-scripts-root` is
about: a legitimate target denied because of a string in an argument.

## 7. Rows run

The suite rule allows a single test file to run without the suite lock, and that is how the rows for the
touched files ran. The narrowed `fast.sh` run was attempted and did not land a verdict, which is stated here
rather than smoothed over:

1. first attempt (`flock -o ... WA_FAST_ROWS=/tmp/pi-rows.txt bash scripts/fast.sh`, 5 rows): queued for the
   suite lock, ran, and the deploy pause of that minute detached the operation's owner, so its output went to
   a closed descriptor. Its work directory was cleaned on exit and its verdict is **unknown** - I did not
   replay it blindly and I do not report it as green;
2. second attempt: REFUSED by the runner, exit 2, nothing ran - my request named `scripts/test-prompt-layers.lua`,
   which is in `scripts/fast-path.exclude:40` (`# lua error: [...] :49: assertion failed!`). My error: an
   excluded file is not a row, and `scripts/lib/fast-rows.sh` refuses the whole request by name instead of
   dropping it;
3. third attempt: REFUSED the same way - `scripts/test-prompt-docs.lua` is not a row either; the prompt-docs
   check is a `check` line inside `scripts/fast.sh` (`scripts/sync-prompt-docs.sh --check`);
4. fourth attempt (the four real rows): queued behind a suite another mission held and cancelled by me after
   ~20 minutes without the lock - nothing ran, no partial effects to reconcile. The four rows had already run
   green singly (below), which is the same work the narrowed run would have added.

Rows run singly (each with its own scratch `WASM_AGENT_HOME`, on this tree at `1682f326`):

| row | verdict |
| --- | --- |
| `scripts/test-project-instructions.lua` | `project instructions ok (20 checks, 0 skipped)` |
| `scripts/test-environment-notes.lua` | `environment notes ok (48 checks, 0 skipped)` |
| `scripts/test-prompt-tool-names.lua` | `prompt tool names ok (288 checks, 0 skipped)` |
| `scripts/test-prompt-cache.lua` | `prompt cache ok (195 checks, 0 skipped, 15 captured requests)` |

Contract checks run directly, as `scripts/fast.sh` runs them, after the last commit:

- `bash scripts/sync-prompt-docs.sh --check` -> `sync-prompt-docs: ok (4 blocks current)`;
- `node scripts/check-instructions.mjs` -> `check-instructions: PASS (79 checks, 384 files, 10 deferred, 0 allowed)`.

The merge's `land-quick` runs the never-dropped core rows (the land rows) - that is the landing machine's own
row, not this round's.

Pre-existing failure, named because I met it: `scripts/test-prompt-layers.lua` fails on the BASE tree
(`41d6420c`, `/tmp/pi-base`) exactly as it fails here when invoked by hand
(`lua error: [...]:5: read is native main-loop bootstrap`) - its envelope needs components provisioned the way
`scripts/fast.sh` does, which a hand invocation does not provide, and the row is excluded from the fast path
with its own recorded reason (`scripts/fast-path.exclude:40`). Not mine, and I did not touch or loosen it.



## 8. Texts to approve

1. The new frame attribute name, rendered as `same_text_as="/path/of/the/copy/dropped"` (model-facing: an
   attribute on an existing section, no new prose). It costs 56 bytes on the one frame it lands on - the
   accounting is exact: the dropped frame plus its join was 7,020 bytes, the attribute 56, and
   7,020 - 56 = 6,964 = 27,540 - 20,576.
2. The paragraph added to `docs/LAYERED-PROMPT.md` under `<project>` (operator-facing, commit `1f8aad90`): "A
   file whose content is byte-identical to another one in that list is carried ONCE, and the copy nearest the
   workdir is the one that stays (the walk is root-first, so the last occurrence of a text wins); each skipped
   path is named in the kept frame's `same_text_as` attribute, never in prose the model reads. That is what
   keeps a git worktree placed inside its parent checkout, a copied tree or a symlinked file from putting the
   same instruction text in the prompt twice."
3. The probe header lines (operator-facing, commit `1682f326`) that name both counts: `system_bytes` (the
   content the model reads) and `system_wire_bytes` (the same message JSON-encoded, which is what the ledger's
   `prompt_shape.system_bytes` counts).

## 9. Proposed FACTORY.md text (NOT written)

> **One text, one frame.** A file the prompt injects - project instructions, an environment note, a role file -
> is injected once per distinct text. When two ancestors carry the same bytes (a worktree inside its parent
> checkout, a copied tree, a symlink), the copy nearest the workdir is kept and the skipped path is named in the
> kept frame's attribute, never in prose the model reads. A prompt measurement states which count it is:
> content bytes (what the model reads) or wire bytes (what the ledger records).

## 10. Proposed HANDOVER.md text (NOT written)

> When a prompt-size number in a report disagrees with the ledger's `prompt_shape.system_bytes`, the two are
> different counts: the ledger counts the JSON wire bytes of the message (`telemetry.prompt_shape`), a probe
> counts the content string. `scripts/probe-prompt-bytes.lua` prints both (`system_bytes`, `system_wire_bytes`).
> The ledger is a guarded file for an agent's tools: an agent says so, quotes the refusal and hands the operator
> the query - it does not read it, and it does not route around the guard with a helper script.

## 11. What is not done / not claimed

- The +2.6 KB ledger step is NOT attributed to a commit. Measured: the prompt content of a fixed-cwd session
  did not move across `f05b3150`..`41d6420c`. Not verified: what the real sessions' cwd/role was, because the
  ledger is refused to my tools (section 6).
- No landing, no release, no fleet action, no push. FACTORY rule 12 respected: nothing installed into
  `~/.local/bin`, `installed.txt` untouched.
- Fable's review of the model-facing attribute is owed: it removes 6,964 bytes from what the model reads in
  this node's most common cwd.
