# whatsapp-read-is-consistent (Victor, 23/11): a read never goes backwards, says how fresh it is, shows what was just sent

Branch `change/whatsapp-read-is-consistent`, base `51b63d9a`. Worktree
`/home/victor/Work/missions/whatsapp-read-is-consistent/wt`. Nothing is pushed.

## A. Root cause of the backwards reads: a settled query answer was a cache

Not the transport, not catch-up, not the index write order. The read path is a **job on the shared queue**
(`rust/wa-capabilities/src/whatsapp_query.rs`, `whatsapp.query`), and every query was enqueued with a
dedupe key that outlived the job that carried it:

* `enqueue` (`rust/wa-queue/src/queue.rs:79-90`) answers a dedupe key that already names a job **whatever
  state that job is in** - including `done` - so the tool got the settled `result` back;
* the claim was released only by `Queue::reap` (`queue.rs`, done retention `Policy::done_retention_ms =
  3_600_000`, `rust/wa-queue/src/lib.rs:556`) - one hour.

So for an hour, an identical `whatsapp_read` call answered with the picture taken the first time it was
asked; a call with any different argument (`limit`, `before`, a different chat spelling) created its own
job with its own, later, picture. Three reads in a row therefore answered three different histories
(15:40, 16:15, 15:44 in the work node's note), each one silently old, and a read issued after a send could
answer from before the send. The component log the orchestrator measured is consistent with this: the
component was healthy and writing one record at a time, and the reads were answered by jobs that had run
minutes earlier.

Fix (commit `49e2bde2`): a dedupe claim may be **in-flight only**
(`EnqueueRequest::dedupe_in_flight()`, `Job::dedupe_in_flight`); it is released when the job settles
(done, dead, expired), `repair` does not resurrect it, and the encoding reads an old record that predates
the flag as the long-lived claim it was. `rust/wa-capabilities/src/whatsapp_query.rs` asks for it, so a
query answers the index as it is now; `whatsapp.send` keeps the long-lived claim, because a repeated send
must not go out twice (asserted both ways in `rust/wa-queue/src/tests.rs`, commit `49e2bde2`).

**Not verified: the scratch-pair reproduction.** The cause was found by reading the code and is proven at
the queue and at the tool by tests (`49e2bde2`, `856762fd`), not by running two nodes against each other.
openclaw was read-only and I did not run a scratch pair, so I have not watched the old code answer 15:40
and 16:15 with the same call in a live process.

## B. The read contract, in the answer itself

`index::read_paced` / `index::search_paced` (`rust/components/wa-whatsapp/src/index.rs`, commit `92faddba`):

* `as_of` (ms), `as_of_iso`, `as_of_local` - the time of the newest message the index holds for that chat
  (null when it holds none, because a time is not a missing fact);
* `order` - `{key:"ts", direction:"newest_first", cursor:"next_before"}`, so two answers can be compared
  and paged;
* `index` - `{state: "current"|"catching_up", pending: <count>, lag_ms, newest_seen_ms}`: `lag_ms` is the
  distance between the newest message the component has **seen** and the newest it has **written**, and
  `catching_up` is the component saying it knows it is behind (records accepted and not written, or a
  history sync queued). It is never a guess about messages that never arrived;
* `pending`: the ids the component has accepted and not written yet (this chat only), with
  `pending_note`;
* `as_of_regressed: {was_ms, was_iso, now_ms, now_iso, reason}` - present only when this answer is older
  than one this process already gave for the same chat: records leaving the index (a retention pass, a
  restored month) is the only honest way a read may go backwards, and now it is named instead of silent
  (`index::observe_as_of`, a bounded thread-local memory of the highest `as_of` answered per chat).

A search carries `as_of` + `as_of_iso` + `as_of_scope: "matches"` (a search is not one chat, so the scope
is said), the same `order`, and the same `index` block.

Tests (`4e18b5e9`):
`index::tests::a_read_says_how_fresh_it_is_and_two_reads_in_a_row_never_go_backwards`,
`index::tests::a_search_says_how_new_its_newest_match_is_and_how_caught_up_the_writer_is`.

## C. READ YOUR WRITES

* The component now writes the record of its own send into the index **before the send answers**
  (`rust/components/wa-whatsapp/src/guest.rs`, the outbox `Ok(message_id)` arm, commit `92faddba`): it used
to hand it to the pipeline inbox and be written on a later tick, which is exactly the window in which a
read issued the moment the send answered answered from before the send. A refused write still answers the
send (the message *is* out) with `in_history: false` and hands the record to the inbox retry lane;
* `wa-whatsapp-outbox::Outcome` carries `in_history`, and `outbox::status` answers it
  (`rust/wa-whatsapp-outbox/src/lib.rs`, commit `e3f9a882`), with `in_history_note` when it is false;
* the tool carries it through (`lua/core/whatsapp.lua`, commit `a6c68650`) - both the single-id answer and
the `ids` wait entry rebuild their answers field by field, so without this the field would never have
reached a caller;
* a read that cannot show a message it already has names it in `pending` (test
  `index::tests::a_message_accepted_and_not_written_yet_is_named_pending_and_the_answer_says_it_is_behind`,
  `4e18b5e9`).

## D. A voice or image record never answers an empty text

`rust/components/wa-whatsapp/src/view.rs` (`stand_in`, commit `92faddba`): a voice/audio record with no
text and no transcript answers `text: "transcript pending"`, `text_reason: "transcript_pending"`; with a
stated reason it answers `"not transcribed: media_too_large"` (or `view_once`, `ephemeral_media_not_retained`, …)
and `text_reason: "unsupported"`; an image/video/sticker says `ocr pending` / `not read: <reason>`.
A record that **has** a transcript keeps answering with it as `text` (4012380f's work), and a long one
keeps its cut marker plus `transcript_full` (the exact `whatsapp_message` call). A deleted text message
still answers an empty text with `deleted: true`, which is its own fact.
Tests: `view::tests::a_voice_note_with_no_transcript_says_so_instead_of_an_empty_text`,
`view::tests::a_voice_note_with_a_transcript_answers_with_the_transcript_and_its_way_to_the_whole`.

## E. One chat is one history under both addresses

`index::read` merges the addresses the index learned for a chat (`ix/al`, `remember_alias`) instead of
reading one prefix: the requested address plus its alias, interleaved by inverted time and deduplicated by
message id, with quotes and folded reactions looked up under both, `as_of` the max over both, and
`addresses` naming the pair when they are joined (commit `92faddba`). Before this, a read by `@lid` and a
read by the phone number were two different histories. Test:
`index::tests::one_chat_is_one_history_under_both_of_its_addresses` (`4e18b5e9`).

## F. Tests and canaries

* queue: `tests::an_in_flight_claim_stops_answering_when_the_job_settles_and_a_send_claim_does_not`
  (`49e2bde2`); tool: `whatsapp_query::tests::a_settled_read_is_not_replayed_to_the_next_caller`
  (`856762fd`);
* component: the four tests named above (`4e18b5e9`) plus the two view tests (`92faddba`);
* outbox: `status_says_whether_the_sent_message_is_in_the_history` (`e3f9a882`);
* the WhatsApp index canary (`lua/core/canaries/whatsapp-index.lua`, commit `e3f9a882`) now reads the
  newest chat twice on a live node and refuses a `read` answer with no `as_of`, no `order`, no `index`
  state, or a later read whose `as_of` went back. It stays read-only (two `host.whatsapp_read` calls, no
  send, no index write) and its report carries counts and times only - no chat, no id, no text.

**Rows for `whatsapp-acceptance`: not added.** No artefact by that name exists in this tree (searched:
`rg -l whatsapp-acceptance`, `scripts/`, `docs/`), so I extended the canary instead and I am naming the gap
rather than inventing a file the factory would not run.

## Test changes made to existing tests (nothing loosened)

* `rust/wa-capabilities/src/whatsapp_query/tests.rs`: three tests drove a settled answer by asking again
  (`ask_in` twice), which is now a **new** job by design. Their assertions are unchanged; the setup now
  decodes the settled job through the new `settled_answer(op, &job)` - the same function `settle` uses
  (`856762fd`). The old behaviour is asserted the other way round by
  `a_settled_read_is_not_replayed_to_the_next_caller`.
* `rust/wa-queue/src/tests.rs::dedupe_key_names_one_job_per_queue` still asserts the long-lived claim for a
  job that did not ask for in-flight-only, which is unchanged behaviour.

## A pre-existing failure on the base (not mine)

`cargo test -p wa-capabilities --lib` does not compile at base `51b63d9a`: `rust/wa-capabilities/src/operations.rs`
calls `super::foreground(...)` with six arguments where the function takes seven (the `stdin` parameter was
added and two test call sites were not updated; the third was). Confirmed on the base commit
(`git show 51b63d9a:rust/wa-capabilities/src/operations.rs`, lines 3196 and 3249). Repaired in `856762fd`
by passing `None` at both call sites - test-only, no assertion touched.

## Texts to approve (model- or operator-facing, verbatim)

1. `lua/core/whatsapp.lua`, `mcp_whatsapp_read` description, added sentence: "The answer says how fresh it
   is in the answer itself: as_of (the time of the newest message the index holds for this chat, null when
   it holds none), as_of_iso and as_of_local, order (the key the page is sorted by, newest first), and
   index (state current or catching_up, pending count, lag_ms). pending lists the ids the component has
   accepted and not written yet - a message just sent appears there rather than being silently missing, so
   read again in a second when it is not empty; as_of_regressed appears only when this answer is older than
   one the node already gave for the chat. One person under two addresses (@lid and phone number) is one
   history: a read by either returns the same messages, and addresses names both when they are joined."
2. `lua/core/whatsapp.lua`, `mcp_whatsapp_search` description, added sentence: "The answer also says how
   fresh it is: as_of (the time of the newest message it matched, with as_of_scope=matches), order (the key
   the hits are sorted by), and index (state current or catching_up, how many records the component has
   accepted and not written yet, and lag_ms: how far behind the newest message it has seen this answer is)."
3. `lua/core/whatsapp.lua`, `mcp_whatsapp_send` description, added sentence: "The answer also says whether
   the message is in the history a read answers from: in_history=true (the index holds it, so
   mcp_whatsapp_read on that chat returns it now) or in_history=false with in_history_note (sent, not
   indexed yet), which means reading the chat may not show it for a moment - nothing else does."
4. `lua/core/whatsapp.lua`, `mcp_whatsapp_send_status` (hidden) description: "the same answer as
   mcp_whatsapp_send({id, wait_s:0}), including in_history for the message id it reports."
5. New answer fields (not a sentence, quoted so the operator can see them): read - `as_of`, `as_of_iso`,
   `as_of_local`, `order`, `index`, `pending`, `pending_note`, `as_of_regressed`, `addresses`; search -
   `as_of`, `as_of_iso`, `as_of_scope`, `order`, `index`; a media record's view - `text_reason`
   (`transcript_pending` | `ocr_pending` | `unsupported`) and the two stand-in sentences
   `transcript pending`, `ocr pending`, `not transcribed: <reason>`, `not read: <reason>`; send -
   `in_history`, `in_history_note`.
6. Canary report strings (`lua/core/canaries/whatsapp-index.lua`): "the index knows N chat(s); a read
   answers as_of, order newest-first and a current writer", and the refusal stages `read_capability_missing`,
   `read_no_chat`, `read_unreadable`, `read_refused`, `read_no_as_of`, `read_no_order`,
   `read_no_index_state`, `read_no_messages`, `read_went_backwards`.

## Checks run here (avell), narrowed as the brief asks

* `cargo test --offline -p wa-queue --lib` - 37 passed (`49e2bde2`).
* `cargo test --offline -p wa-capabilities --lib whatsapp_query` - 15 passed (`856762fd`).
* `cargo test --offline -p wa-whatsapp-outbox` - all passed (`e3f9a882`).
* `cargo test --offline --manifest-path rust/components/wa-whatsapp/Cargo.toml` - 202 passed
  (`92faddba`, `4e18b5e9`).
* `flock -o ~/Work/missions/.suite.lock env WA_FAST_ROWS=<rows> bash scripts/fast.sh` with the rows for the
  Lua files touched (`test-whatsapp-one-surface.lua`, `test-whatsapp-send.lua`, `test-whatsapp-one.lua`,
  `test-return-shapes.lua`, `test-prompt-tool-names.lua`, `test-host-return-docs.lua`) - result recorded
  below this line when it finished.

## What I did not do or could not verify

* No scratch-pair reproduction (see A). The fix is proven by unit and crate tests, not end to end.
* openclaw's build: the brief says it still runs v0.1.1. Whether its installed component carries 4012380f
  (the transcript on the record) and this fix is a deploy question; I did not read openclaw's component
  state beyond nothing at all, and I make no claim about it.
* `as_of` for a search is scoped to the matched records, not to the whole index (there is no cheap
  "newest record overall" scan in this kv); the field says so with `as_of_scope`.
* The monotonic guard (`as_of_regressed`) is per process and bounded to 512 chats: a restart forgets it, and
  a very busy node drops the memory rather than grow it. The answer simply omits the field then.

## Proposed (not written) FACTORY.md / HANDOVER.md text

For `HANDOVER.md`, under the WhatsApp section:

    A WhatsApp read answers from the index the component writes, through a queue job. A settled query job
    releases its dedupe claim (`dedupe_in_flight`), so `whatsapp_read`/`_search` always read the index as it
    is now; a send keeps its long-lived claim so a repeat cannot send twice. If a read question looks stale,
    check `as_of` and `index.state` in the answer before suspecting the transport: `catching_up` and a
    non-zero `lag_ms` mean the component has records it has not written yet; `pending` names them.

For `FACTORY.md`, nothing: the factory's scripts are untouched by this branch.
