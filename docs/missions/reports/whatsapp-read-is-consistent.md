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

Fix (commit `75bdd7b9`): a dedupe claim may be **in-flight only**
(`EnqueueRequest::dedupe_in_flight()`, `Job::dedupe_in_flight`); it is released when the job settles
(done, dead, expired), `repair` does not resurrect it, and the encoding reads an old record that predates
the flag as the long-lived claim it was. `rust/wa-capabilities/src/whatsapp_query.rs` asks for it, so a
query answers the index as it is now; `whatsapp.send` keeps the long-lived claim, because a repeated send
must not go out twice (asserted both ways in `rust/wa-queue/src/tests.rs`, commit `75bdd7b9`).

**Not verified: the scratch-pair reproduction.** The cause was found by reading the code and is proven at
the queue and at the tool by tests (`75bdd7b9`, `97638750`), not by running two nodes against each other.
openclaw was read-only and I did not run a scratch pair, so I have not watched the old code answer 15:40
and 16:15 with the same call in a live process.

## B. The read contract, in the answer itself

`index::read_paced` / `index::search_paced` (`rust/components/wa-whatsapp/src/index.rs`, commit `8e3bcd7f`):

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

Tests (`ad77aa18`):
`index::tests::a_read_says_how_fresh_it_is_and_two_reads_in_a_row_never_go_backwards`,
`index::tests::a_search_says_how_new_its_newest_match_is_and_how_caught_up_the_writer_is`.

## C. READ YOUR WRITES

* The component now writes the record of its own send into the index **before the send answers**
  (`rust/components/wa-whatsapp/src/guest.rs`, the outbox `Ok(message_id)` arm, commit `8e3bcd7f`): it used
to hand it to the pipeline inbox and be written on a later tick, which is exactly the window in which a
read issued the moment the send answered answered from before the send. A refused write still answers the
send (the message *is* out) with `in_history: false` and hands the record to the inbox retry lane;
* `wa-whatsapp-outbox::Outcome` carries `in_history`, and `outbox::status` answers it
  (`rust/wa-whatsapp-outbox/src/lib.rs`, commit `b9ae53c8`), with `in_history_note` when it is false;
* the tool carries it through (`lua/core/whatsapp.lua`, commit `450fb287`) - both the single-id answer and
the `ids` wait entry rebuild their answers field by field, so without this the field would never have
reached a caller;
* a read that cannot show a message it already has names it in `pending` (test
  `index::tests::a_message_accepted_and_not_written_yet_is_named_pending_and_the_answer_says_it_is_behind`,
  `ad77aa18`).

## D. A voice or image record never answers an empty text

`rust/components/wa-whatsapp/src/view.rs` (`stand_in`, commit `8e3bcd7f`): a voice/audio record with no
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
`addresses` naming the pair when they are joined (commit `8e3bcd7f`). Before this, a read by `@lid` and a
read by the phone number were two different histories. Test:
`index::tests::one_chat_is_one_history_under_both_of_its_addresses` (`ad77aa18`).

## F. Tests and canaries

* queue: `tests::an_in_flight_claim_stops_answering_when_the_job_settles_and_a_send_claim_does_not`
  (`75bdd7b9`); tool: `whatsapp_query::tests::a_settled_read_is_not_replayed_to_the_next_caller`
  (`97638750`);
* component: the four tests named above (`ad77aa18`) plus the two view tests (`8e3bcd7f`);
* outbox: `status_says_whether_the_sent_message_is_in_the_history` (`b9ae53c8`);
* the WhatsApp index canary (`lua/core/canaries/whatsapp-index.lua`, commit `b9ae53c8`) now reads the
  newest chat twice on a live node and refuses a `read` answer with no `as_of`, no `order`, no `index`
  state, or a later read whose `as_of` went back. It stays read-only (two `host.whatsapp_read` calls, no
  send, no index write) and its report carries counts and times only - no chat, no id, no text.

**Rows for `whatsapp-acceptance`: not added.** No artefact by that name exists in this tree (searched:
`rg -l whatsapp-acceptance`, `scripts/`, `docs/`), so I extended the canary instead and I am naming the gap
rather than inventing a file the factory would not run.


## The 24/11 additions (orchestrator + Fable, after the first report)

### C, with the evidence: a message this node sent is in SEARCH at once, not only in a read

The what-hurt was "delivery was confirmed only from the component log, search did not see the message". The
eager write (`8e3bcd7f`) puts the sent record in the index before the send answers, and the same store
answers a search for its text: `index::tests::a_message_this_node_sent_is_in_search_the_moment_its_record_is_written`
(`0c778d7f`) asserts the search finds it (with its chat and its `as_of`), and that a read of the chat holds
it too. `in_history` on the send answer is the receipt (`b9ae53c8`, `450fb287`).

### G: a search states its order and takes one

`seam::Order` (`relevance` | `newest`) on the request (`0c778d7f`): the seam refuses an unknown word
(`bad_order`) and refuses an `order` on any op but `search`, the order is part of the dedupe key (two orders
are two jobs) and it travels on the wire. The default is the question's own: **newest first for a search
scoped to one chat, or with no query terms**; relevance otherwise. The answer always carries
`order: {by, key, direction, note}` - `key: "ts"` and `direction: "newest_first"`, or `key: "score"` and
`direction: "best_first"` with the note that a relevance list is NOT in date order - beside `as_of`, so
"nothing newer" is never inferred from a relevance list. Every hit carries its sent time (`ts`, `at`,
`at_local`, `at_iso`) and its chat. The tool takes `order` and says so in its description (`0c778d7f`).
Tests: `a_search_order_is_relevance_or_newest_and_only_a_search_takes_one` (seam),
`a_chat_scoped_search_answers_newest_first_and_says_so` and
`a_search_with_no_terms_answers_newest_first_and_a_relevance_search_keeps_its_order` (component).

### B, added: the node-wide receive freshness in the same result

Every successful read and search answer also carries `last_received_s` (seconds since ANY message was
received and indexed on this node, from `health::last_index_ms`), `last_received_note`, `connected` (the
transport: the client this instance holds and its own bot state), and `connected_note` when it is down
(`0c778d7f`, `guest::receive_freshness` + the query lane). "This chat is quiet" and "the pipe is stuck"
are now told apart without a second call. It is measured by the canary on a live node (`read_no_connected`,
`read_no_receive_freshness` stages), not by a native test: the value comes from the transport, which a
`cargo test` process does not have.

### E, added: the answer names the id form it resolved

When the index knows both addresses, the read answer carries `resolved_form` ("lid -> phone" or
"phone -> lid") and `resolved_note` beside `addresses` (`0c778d7f`), so nobody tests the alias by hand.

### D, with the evidence: a text and a voice note in one thread

`index::tests::a_chat_whose_last_two_messages_are_a_text_and_a_voice_note_reads_both_with_the_transcript_inline`
(`0c778d7f`): the last two messages of a chat are a text and a voice note; the read returns both, newest
first, the note's `text` IS its transcript, and a search for a word in it finds the note.

**"Among messages from other chats":** `whatsapp_read` never mixes chats - it refuses without one
(`chat_required`, asserted in `a_search_that_mixes_chats_labels_every_hit_with_its_chat_and_a_read_never_mixes_them`,
`0c778d7f`), and a read is one thread by construction. `whatsapp_search` DOES mix chats, and every hit
carries `chat` and `chat_name`; the same test asserts both, so a row can never be read as belonging to the
conversation the reader had in mind.

## Test changes made to existing tests (nothing loosened)

* `rust/wa-capabilities/src/whatsapp_query/tests.rs`: three tests drove a settled answer by asking again
  (`ask_in` twice), which is now a **new** job by design. Their assertions are unchanged; the setup now
  decodes the settled job through the new `settled_answer(op, &job)` - the same function `settle` uses
  (`97638750`). The old behaviour is asserted the other way round by
  `a_settled_read_is_not_replayed_to_the_next_caller`.
* `rust/wa-queue/src/tests.rs::dedupe_key_names_one_job_per_queue` still asserts the long-lived claim for a
  job that did not ask for in-flight-only, which is unchanged behaviour.

## A pre-existing failure on the base (not mine)

`cargo test -p wa-capabilities --lib` does not compile at base `51b63d9a`: `rust/wa-capabilities/src/operations.rs`
calls `super::foreground(...)` with six arguments where the function takes seven (the `stdin` parameter was
added and two test call sites were not updated; the third was). Confirmed on the base commit
(`git show 51b63d9a:rust/wa-capabilities/src/operations.rs`, lines 3196 and 3249). Repaired in `97638750`
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
   `as_of_local`, `order`, `index`, `pending`, `pending_note`, `as_of_regressed`, `addresses`,
   `resolved_form`, `resolved_note`, `last_received_s`, `last_received_note`, `connected`,
   `connected_note`; search - `as_of`, `as_of_iso`, `as_of_scope`, `order{by,key,direction,note}`,
   `index`, `last_received_s`, `last_received_note`, `connected`, `connected_note`; a media record's view
   - `text_reason` (`transcript_pending` | `ocr_pending` | `unsupported`) and the stand-in sentences
   `transcript pending`, `ocr pending`, `not transcribed: <reason>`, `not read: <reason>`; send -
   `in_history`, `in_history_note`.
6. `lua/core/whatsapp.lua`, `mcp_whatsapp_search`, the new `order` parameter: "Omitted, a search of one
   chat or one with no q answers newest first, and a search with q across the account answers best match
   first. Say newest to get the tail of a conversation, or relevance to get the best match even when it
   is old."
7. `mcp_whatsapp_search` description, replaced sentence: "The answer also says how fresh it is: as_of
   (the time of the newest message it matched, with as_of_scope=matches), order (which key the hits are
   sorted by: newest first, or best match first - a relevance list is not a date list and says so), and
   index (state current or catching_up, how many records the component has accepted and not written yet,
   and lag_ms: how far behind the newest message it has seen this answer is). It also says whether the
   pipe is alive: last_received_s (seconds since ANY message was received and indexed on this node, so a
   quiet answer here can be told from a stuck pipe) and connected (the WhatsApp transport). Every hit
   carries when it was sent (at, at_local, at_iso) and the chat it came from, so a search across chats
   never mixes them unseen."
8. `mcp_whatsapp_read` description, added: "last_received_s (seconds since any message was received and
   indexed on this node) and connected (the transport) say whether a quiet answer is this chat or a
   stuck pipe." and "resolved_form says which one was resolved (lid -> phone or phone -> lid), so the
   alias never has to be tested by hand."
9. Answer sentences inside the component: "newest message first: the top of this list is the newest
   message that matched"; "best match first: this list is NOT in date order, so an older message may be
   above a newer one; as_of says how new the newest match is"; "this node last wrote a message into its
   index Ns ago, from any chat: a quiet answer here is this chat, not the pipe"; "this node has not
   written any message into its index since it started"; "the WhatsApp transport is not connected:
   nothing new can arrive until it reconnects, so an empty or old answer is the pipe and not the chat";
   "asked by lid; the same person is also known by phone here, and this answer holds both".
10. Canary report strings (`lua/core/canaries/whatsapp-index.lua`): "the index knows N chat(s); a read
   answers as_of, order, index state, receive freshness and the transport, and a later read is never
   older", and the refusal stages `read_capability_missing`,
   `read_no_chat`, `read_unreadable`, `read_refused`, `read_no_as_of`, `read_no_order`,
   `read_no_index_state`, `read_no_messages`, `read_no_receive_freshness`, `read_no_connected`, `read_went_backwards`, and the success line "a read answers as_of, order, index state, receive freshness and the transport, and a later read is never older".

## Checks run here (avell), narrowed as the brief asks

* `cargo test --offline -p wa-queue --lib` - 37 passed (`75bdd7b9`).
* `cargo test --offline -p wa-capabilities --lib whatsapp_query` - 15 passed (`97638750`).
* `cargo test --offline -p wa-whatsapp-outbox` - 14 passed + 7 passed (the crate and its integration file), 0 failed (`b9ae53c8`).
* `cargo test --offline --manifest-path rust/components/wa-whatsapp/Cargo.toml` - 207 passed
  (`8e3bcd7f`, `ad77aa18`, `0c778d7f`).
* `cargo test --offline -p wa-whatsapp-index` - 31 + 2 + 8 passed (`0c778d7f`).
* `flock -o ~/Work/missions/.suite.lock env WA_FAST_ROWS=<rows> bash scripts/fast.sh` with the rows for the
  Lua files touched (`test-whatsapp-one-surface.lua`, `test-whatsapp-send.lua`, `test-whatsapp-one.lua`,
  `test-return-shapes.lua`, `test-prompt-tool-names.lua`, `test-host-return-docs.lua`): **135 checks, 6
  failed**, 837 s. The six, and what each is:
  * `check-component-pins` (2 FAILs: `wa-whatsapp` and `wa-email` source changed and the pin did not) -
    **mine, and fixed** (commit `3e273501`): `rust/wa-queue` is an input of both components, and the
    component sources changed, so I rebuilt the two from this tree with
    `WA_COMPONENTS_DIR=$PWD/build/components-pinned bash scripts/build-components.sh wa-whatsapp wa-email`
    and wrote their sha256 and size into `components.lock`. `bash scripts/test-component-pins.sh` then
    answered `11 of 11 pinned component(s) verified` and `the pinned bytes answer all 8 ops the seam
    defines`. Nothing was installed on this node's live component directory: the build wrote into this
    worktree's `build/components-pinned/`, which the pin check reads as one of its candidate sources.
  * `check-install-guards.log` (6 checks): every one is `wa upgrade` answering "refused inside a turn
    running on the node it would replace" where the test expected the override path. That is the guard
    doing its job in the environment the row ran in (a worker turn), not a code path this branch touches.
  * `test-edit-aliases.lua` (1 check): the `edit` tool's option names (`unsupported_edit_option`). No
    file this branch changes is on that path.
  * `check-esc-stops-pty.log`, `check-tui-chrome-pty.log`, `check-run-block-pty.log` (1 each): pty/timing
    rows, one assertion each, on a node that had a second mission running a build at the same time.

  None of the four non-pin failures reads a file this branch changes (`git diff --name-only 51b63d9a..HEAD`
  is the 14 files above). I did **not** re-run them against a base worktree, so I name them as unrelated and
  unproven-on-base rather than as "pre-existing": the one pre-existing failure I did prove is the
  `foreground` arity above.

### The narrowed run after the 24/11 items

`flock -o ~/Work/missions/.suite.lock env WA_FAST_ROWS=<rows> bash scripts/fast.sh` with
`test-whatsapp-one-surface.lua`, `test-whatsapp-send.lua`, `test-whatsapp-one.lua`,
`test-return-shapes.lua`, `test-prompt-tool-names.lua`, `test-host-return-docs.lua`,
`test-whatsapp-names.lua`: **137 checks, 1 failed**, 922 s.

* the one failure is `check-esc-stops-pty.log`: the `bash` Esc-stop timing row answered 680 ms against a
  limit of 436 ms at load 3.63 (its own log line) - a load-sensitive pty timing assertion on a node where
  another mission held the suite lock and built at the same time. No file this branch changes is on the
  Esc/stop path (`git diff --name-only origin/main..HEAD` is 16 files: the queue, the capability, the
  component, the outbox, the seam, the lua tool and the canary, the lock and this report).
* `check-component-pins` passed: `11 of 11 pinned component(s) verified`, and the pinned `wa-whatsapp`
  bytes answer all 8 ops (`3c81b28c`).

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
