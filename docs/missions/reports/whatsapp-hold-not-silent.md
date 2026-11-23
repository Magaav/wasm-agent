# whatsapp-hold-not-silent: a deletion flags one message, and no chat is ever held

Mission branch `change/whatsapp-hold-not-silent` on worktree `wt`, base `b79da519`. Local commits only, never
pushed. Every id in this report is a FIXTURE (`5511999...@s.whatsapp.net`, `7210...@lid`,
`120363...@g.us`, `MSG1`); no real chat, phone, name or message body appears here, in a test or in a
commit.

## What this mission became

The brief as written asked for better words on a refusal and a read that lists chat holds. Halfway
through the same day the owner replaced that design (ADDED 17:05Z, verbatim: *"in case an audio gets
deleted right after, it should just skip the reply as it was deleted. we never should get hold from a
chat."*). So the answer is not a nicer message about a hold: **there is no hold any more**, and the
refusals that remain name the facts they are about.

## What is implemented, and where (each line cites the commit that does it)

| item | what it does | where |
| --- | --- | --- |
| A | a deleted message keeps its text, transcript, OCR text, media metadata and token keys, and gains `deleted`, `deleted_at`, `deleted_by`; an edit keeps `previous_text` and stores the new text; reads and search show the flag beside the content | `f746fc61` (`index::mark_deleted`, `record.rs`, `view.rs`) |
| B | the one automatic reply to a deleted message that was not posted yet is dropped by message id and recorded `skipped: source deleted`; a posted reply is left alone; a transcript that lands after the revoke still attaches | `f746fc61` (`guest::apply_notice`, `guest::dispatch`, `queue::drop_key`/`drop_where`) |
| C | no chat hold exists: no unproven, untargeted or owner-clear hold; `posting_held_chat` and `reply_source_deleted` are gone as refusals; an explicit send is never refused for a deletion; an unmatched notice is a counted, timed fact that changes nothing else | `f746fc61` (`notices.rs`, `outbox::dispatch_refusal`, `posting::gate`) |
| D | the first start lifts every hold the previous build left in ONE line, deletes the `holds` key and turns fenced message ids into deletions; the node policy allows `notices` and no longer `holds` | `f746fc61` (`guest::lift_holds`), `008a7806` (`policies/default.json`, `wa-grant-policy` contract row) |
| E | SERVICE-COMPONENTS, WHATSAPP-TRANSCRIPTION, WHATSAPP-OCR, QUEUE and WHATSAPP-COVERAGE state the new rule; the old-journal commands are recorded as removed with the reason | `008a7806` |
| F | tests: content kept + flag; delete before post → reply skipped; unmatched notice → no hold and an explicit send goes through; the migration's shape; a gate that fails if a hold writer exists | `f746fc61` (component tests), `008a7806` (`scripts/test-whatsapp-no-hold-writer.sh`) |
| G | matching is by MESSAGE ID across every chat spelling the store learned (`ix/al`, both ways), and a notice for a message this store does not hold leaves a tombstone by id (`ix/tomb/<id>`) that flags it on arrival under any form | `f746fc61` (`index::notice`, `index::chat_forms`, `index::key_tombstone`) |
| H | the health line carries `notices matched=<n> unmatched=<m> last_notice=<iso\|-> last_unmatched=<iso\|->`, persisted across restarts; the node's posting status parses them; above `UNMATCHED_PER_DAY = 5` unmatched notices in a day the component logs ONE line | `f746fc61`, `008a7806` (`health.rs`, `guest::apply_notice`, `lua/core/whatsapp_posting.lua`) |
| (a) | a refusal that survives names the message it is about: the job's stored reason is `code:id` (`reply_source_own:3EB0ABCD`), while the log keeps the code only | `f746fc61` (`outbox::Refusal`) |
| (c) | the old journal is labelled as the Go bridge's and stale; a tool that still reads it reports `state_moved` instead of answering holds | `008a7806` (`scripts/whatsapp-transcript-watchdog.mjs`, docs) |

## Facts re-measured before writing code (the brief's premises)

* The hold machinery was real and exactly as described: `holds.rs` (507 lines) held whole chats with
  three reasons, `guest::apply_mutation` wrote them, `outbox::dispatch_refusal` answered
  `posting_held_chat` with no facts, and `guest::process` alerted `post_held`. ✅ premise confirmed.
* The index ALREADY received every revoke as a `kind=delete` event record (`record::from_message`) and
  applied it, but through `redact()`, which CLEARED the text, the media and every token key - the exact
  behaviour the owner's decision reverses. So A was a change of an existing path, not a new one. ✅
* A per-chat tombstone already existed (`ix/pend/<chat>/<id>`), which is why the cross-form miss was
  possible at all: the row is keyed by the chat spelling the notice carried. G adds the by-id row. ✅
* `~/.local/state/wa-whatsapp/journal.db` was NOT read by this component: only `scripts/whatsapp-transcript-watchdog.mjs`
  (a live job, `jobs/whatsapp-transcript-watchdog.json`) and two comparison scripts open it. So (c) was a
  doc + tool change, not a code change in the component. ✅
* `reprove-holds`, `release-hold` and `requeue-held-audio` exist in this tree ONLY as documentation of
  the Go connector's commands: there is no Rust node code for them. The brief's (e) ("make them work
  against the live store") would have been building three commands that the design change then removed;
  they are documented as removed instead (`008a7806`). ✅ premise adjusted, and said here rather than
  silently.
* The watchdog's hold alarm would have kept reporting holds out of the dead journal on the account node:
  found and fixed (`008a7806`).

## Tests: what ran, and what it proves

Run on this node (avell), in the worktree, none against the fleet:

| run | result |
| --- | --- |
| `cargo test --lib` in `rust/components/wa-whatsapp` (native decisions) | **195 passed, 0 failed** (baseline before the change: 199 passed - `holds.rs`'s 10 tests left with the module, 6 new tests landed in its place) |
| `cargo check --target wasm32-wasip2` in the same crate | clean, exit 0 (the guest compiles for the real target) |
| `cargo test -p wa-grant-policy` | 47 passed + 1 doc-test |
| `cargo test -p wa-whatsapp-outbox -p wa-whatsapp-index` | 59 passed in 5 binaries |
| `node --test scripts/test-whatsapp-transcript-watchdog.mjs` | 10 passed (7 existing + 3 new staleness cases) |
| `bash scripts/test-whatsapp-no-hold-writer.sh` | ok on this branch |
| the same script against base `b79da519` (separate worktree in /tmp) | **fails**, naming `holds.rs`, `posting_held_chat`, `Gate::Held`, `struct Holds` - so the row discriminates |
| the posting-toggle Lua row (`WA_SCRIPT=scripts/test-whatsapp-posting-toggle.lua`, scratch `WASM_AGENT_HOME`) | `whatsapp posting toggle ok (120 checks)` |

New tests, by name:

* `notices::tests`: `a_notice_names_one_message_or_nothing`, `the_same_chat_under_another_spelling_is_the_same_chat`,
  `a_matched_notice_and_an_unmatched_one_are_counted_apart`, `the_daily_bound_on_unmatched_notices_is_crossed_once_and_resets_with_the_day`,
  `a_restart_keeps_the_counters`.
* `index::tests`: `a_delete_keeps_the_content_and_flags_it_beside_it` (replaces the old
  `a_delete_removes_the_text_the_media_and_every_token`, whose assertions were the old RULE),
  `a_revoke_that_arrives_before_its_message_flags_it_when_it_lands` (replaces
  `a_revoke_that_arrives_before_its_message_still_wins`), `a_notice_matches_the_message_under_the_other_spelling_of_the_same_chat`,
  `a_tombstone_flags_a_late_arrival_under_another_chat_form`, `an_untargeted_notice_changes_no_message_at_all`,
  `an_edit_keeps_the_earlier_text_and_stores_the_new_one`.
* `outbox::tests`: `a_clean_quote_goes_out_and_no_deletion_refuses_a_send`, `a_refusal_names_the_message_it_is_about_and_a_bare_code_is_a_bare_code`;
  `a_reply_source_must_be_exact_plain_text_by_someone_else` now asserts the id travels in the code.
* `posting::tests`: `the_gate_composes_the_allowlist_with_the_operators_own_blocked_list`,
  `no_mutation_on_the_wire_can_block_a_chat_any_more`.

Where they are wired: the two rewritten rule tests and every new component test live in the crate's
own `cargo test --lib` (the fast path's component row); `scripts/test-whatsapp-no-hold-writer.sh` is a
new row in **both** `scripts/test.sh` (`gate_run`, beside `test-whatsapp-go-retired.sh`) and `scripts/fast.sh`
(`check whatsapp-no-hold-writer`); the watchdog cases are in the existing `scripts/test-whatsapp-transcript-watchdog.mjs`
row (already in `scripts/test.sh`).

Two assertions were REWRITTEN, not deleted, and this is the one place to review closely: the two index
tests above asserted the rule the owner removed ("deleting a message deletes its text"). They now assert
the opposite rule, with the same protective intent (the flag exists, it is dated, and the content is
still there). No other assertion was loosened, and nothing was skipped.

## What I did NOT do (named, not hidden)

1. **H's registry row is not added.** The health line and the posting status carry the counters, but
   `config/features/features.json` has no row for "deletion notices", so `wa features` does not show it
   yet. A row needs a canary under `lua/core/canaries/` and the registry check
   (`node scripts/check-features-registry.mjs`) refuses a row without one; a canary that fabricates a
   component log would prove nothing. Proposed row is in the section below.
2. **The live node is not verified.** Nothing here was run on openclaw: the component behaviour is
   proved by native tests and a wasm `check`, not by a send. Victor's four steps in the brief are
   unexecuted by me.
3. **A deletion does not stop a decode that is already running.** The flag is read at admission and again
   right before the post; a job mid-decode finishes and its reply is skipped, which is the intended
   behaviour (B) but worth saying: the audio is not re-read to abort it.
4. **`deleted_by` is the notice's sender, not a proof of who deleted it.** In a group, a revoke carries
   the actor; this stores that string. It is empty when the wire said nothing.
5. **The media of a deleted message is not downloadable** (`whatsapp_download` still refuses with the
   reason `deleted`): WhatsApp stops serving it. The metadata and any text this node derived are kept.
6. **No `(b) holds read` op was built**, because the design change removed the thing it would list.
   What replaces it is the health line's `notices matched/unmatched` plus `ix/tomb/<id>` in the live kv.

## Texts to approve (verbatim, every new or changed model/operator-facing string)

1. Component log, per deletion notice: `notice unmatched <sha256 chat mark> kind=revoke target=<sha256 id mark>`,
   `notice untargeted <mark> kind=<kind> owner=<bool>`, `notice failed <mark> reason=<one line>`.
2. Component log, when the daily bound is passed: `notices: unmatched above bound count=<n> bound=5`.
3. Component log, per skipped reply: `reply skipped <mark> reason=source_deleted replies=<n>` and
   `reply skipped <mark> reason=source_deleted_unproven replies=<n>`.
4. Component log, once per start of the new build: `<N> chat holds lifted: holds were removed by the owner's decision of 23/11 (message fences became deletions: <M>)`.
5. Component log, transcription path: `transcript skipped <mark> reason=source_deleted`,
   `transcript not posted <mark> reason=skipped_source_deleted`, `transcript blocked ... reason=posting_blocked_by_config`.
6. Component start line, second half: `..., blocked chats <n> (operator configuration; no mutation can block a chat)`.
7. Health line (fields added at the end, v=1 kept): `notices matched=<n> unmatched=<m> last_notice=<ISO|-> last_unmatched=<ISO|->`.
8. Node-side refusal reason of an explicit send, stored and answered: `reply_source_own:<id>`,
   `reply_source_unsupported:<id>`, `reply_source_not_plain_text:<id>`, `reply_source_not_indexed:<id>`.
9. Index record fields a tool answer now carries: `deleted_at`, `deleted_at_iso`, `deleted_by`, `previous_text`.
10. Watchdog answer when the journal is stale: `{"ok":false,"reason":"state_moved","journal_ms":..,"index_ms":..,"journal":"...","live":"~/.wasm-agent/components/wa-whatsapp.state/kv.sqlite","note":"the old bridge journal: this watchdog no longer answers holds or posting from it"}`.
11. The gate's own line: `whatsapp-no-hold-writer: ok: no code path creates a chat hold; the deletion path is index::mark_deleted + notices.rs`
    and `whatsapp-hold-not-silent: the per-message rule of 23/11 is not what this tree implements (docs/WHATSAPP-TRANSCRIPTION.md)`.

## Proposed FACTORY.md / HANDOVER.md text (proposed, never written)

> **Chat holds no longer exist (23/11).** The `wa-whatsapp` component does not hold a chat for any
> mutation: a revoke or an edit flags the message it names (content kept, `deleted_at`, `deleted_by`),
> skips the one automatic reply that had not been posted, and leaves a tombstone by message id when the
> message is not in the store yet. `posting_held_chat` is not a refusal code any more, an explicit send
> is never refused for a deletion, and `scripts/test-whatsapp-no-hold-writer.sh` (in `test.sh` and
> `fast.sh`) fails if a hold writer comes back. The old bridge's `journal.db` is stale on the account
> node and no tool answers from it: `state_moved`.

## For the reviewer (Fable), in order of risk

1. **The two rewritten index assertions** (`f746fc61`): the only place where a test changed direction.
   They encode the owner's decision, and the old rule is cited in the new test's comment so the reversal
   is auditable.
2. **`reply_source_deleted` removed as a refusal** (`f746fc61`): I read C's "an explicit send the owner
   asks for is never refused for a deletion" literally, so quoting a deleted message now goes out. The
   other reply-source refusals (own, unsupported, not plain text) stay and now name the id. If the
   reviewer reads C more narrowly, this is the line to change back.
3. **The sender-wide skip window** (`f746fc61`): the queue's freshness window (5 min by default),
   documented in code and in WHATSAPP-TRANSCRIPTION.md. A different window is a one-constant change.
4. **`held_chats` survives as operator configuration** (`f746fc61`): the owner's decision enumerates the
   three DERIVED reasons, and the posting-toggle mission owns that config key, so I removed the derived
   hold path and left the hand-written list alone, documented as configuration only.
