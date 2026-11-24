# whatsapp-acceptance - every WhatsApp tool and flow, one table

Mission: `whatsapp-acceptance` (brief in the mission directory; Fable 23/11 ~18:00Z, rows added 23/11
~23:00-23:55Z and ~19:55Z). Branch `change/whatsapp-acceptance`, base `e832e152`.

Victor's words: "ensure the whatsapp mcp works flawlessly". This is the phase-A deliverable: ONE script that
runs every cell and every flow and prints the table, plus the table this machine can produce today, and the
mapping from every cell that is not green to the brief that owns it and the canary that has to keep it
green. Phase B - the same script against the operator's own chat on the account node - is the
orchestrator's, with Fable's OK.

## 1. What was built

| Path | What it is |
| --- | --- |
| `scripts/whatsapp-acceptance.mjs` | The one script. `--mode scratch` (default) starts three scratch nodes on this machine - account, laptop, work - each with its own home, a local rendezvous and a fleet roster signed by a key made for this run, all answered by the `wa` binary of this checkout. `--mode live --own-chat <jid>` runs the same rows against the node's OWN chat and refuses every other target. Prints PASS / FAIL (with the cause, file:line) / NOT-RUN (with the reason), the measured milliseconds, the bytes and the shape the MODEL receives. |
| `scripts/lib/whatsapp-acceptance-call.lua` | The in-node driver. Runs one plan of steps through the real Lua surface (`tools.dispatch` on `mcp_whatsapp_*`), and prints a measurement per step: verdict, ms, bytes of the answer the model receives, the answer's SHAPE (keys, types, array sizes) and an allow-list of scalar fields, everything redacted. Message text, chat JIDs, phone numbers and message ids never leave it. |
| `scripts/test-whatsapp-acceptance.mjs` | The script's own contracts, no node started: every verb of `lua/core/whatsapp.lua` is a row, live mode refuses a missing or malformed own-chat target, the own-chat guard sits in the driver BEFORE the dispatch, the driver redacts, a run in the node home refuses. Wired into `scripts/fast.sh` as the fast-path row `whatsapp-acceptance`. |

The scratch fleet is real, not a stub: three `wa serve` processes, a local rendezvous, a `wa fleet
keygen`/`fleet sign` roster (levels: account 1, the two callers 0), each node's policy being the SHIPPED
`policies/default.json` plus its mesh section - so a send in this table was decided by the real
`whatsapp.send` rule and its caps, not by a policy written for the test.

## 2. The surface: the brief's list, re-measured

The brief's list was: send, send_status, read, search, media, download, reactions, contacts, backfill,
approve. Measured against `lua/core/whatsapp.lua` (`M.TOOLS`, every one `mcp_whatsapp_<verb>`):

* eight are OFFERED to the model - `contacts`, `search`, `read`, `reactions`, `media`, `download`,
  `backfill`, `send`;
* two are HIDDEN doors, callable and not in any catalogue - `send_status` (the resume form of `send`,
  `lua/core/whatsapp.lua` `M.status`) and `approve` (the operator's approval gate, `docs/APPROVE.md`).

So the brief's list is complete for the Lua surface; the correction is that `send_status` and `approve`
are not model-facing.

**The component exposes nine names the brief's list does not have, and the surface does not offer them.**
`rust/components/mcp-whatsapp/src/main.rs` `tools()` lists `read_snapshot`, `read_newest`, `list_chats`,
`posting_status`, `read_field`, `lookup_self`, `inspect_chat`, `download_audio`, `send_message`. They are
the MCP-native surface of the loopback connector; `lua/core/whatsapp.lua` `M.renamed` answers each of them
with the one replacement name (`read_newest` -> `mcp_whatsapp_read`, and so on). Each is a row of the table
below, NOT-RUN by construction, with the replacement it answers with.

## 3. The table (this node, `--mode scratch`, 2026-11-24)

```
site      tool                          verdict  ms     bytes  what the model receives / why
--------  ----------------------------  -------  -----  -----  ---------------------------------------------
account   mcp_whatsapp_contacts         NOT-RUN  2134   879    no paired device on this machine: the capability queued the question as job 1 and answered whatsapp_contacts_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_search           NOT-RUN  2029   869    no paired device on this machine: the capability queued the question as job 2 and answered whatsapp_search_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_read             NOT-RUN  2031   859    no paired device on this machine: the capability queued the question as job 3 and answered whatsapp_read_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_reactions        NOT-RUN  2041   884    no paired device on this machine: the capability queued the question as job 4 and answered whatsapp_reactions_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_media            NOT-RUN  2051   864    no paired device on this machine: the capability queued the question as job 5 and answered whatsapp_media_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_download         NOT-RUN  10041  879    no paired device on this machine: the capability queued the question as job 6 and answered whatsapp_download_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_backfill         NOT-RUN  2032   879    no paired device on this machine: the capability queued the question as job 7 and answered whatsapp_backfill_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_send             PASS     47     283    {attempts:number,id:number,note:string(95),ok:boolean,queue_state:string(6),reads:number,resume:
account   mcp_whatsapp_send_status      PASS     27     151    {attempts:number,id:number,ok:boolean,reads:number,reason:string(33),served_by:string(7),state:s
account   mcp_whatsapp_approve          PASS     20     111    {drafts:{},ok:boolean,root:string(53),status:number,waiting:number}
account   mcp_whatsapp_send (same mes…  PASS     81     283    {attempts:number,id:number,note:string(95),ok:boolean,queue_state:string(6),reads:number,resume:
account   mcp_whatsapp_send (cancel a…  PASS     32     189    {attempts:number,cancelled:boolean,effect:string(34),id:number,ok:boolean,reason:string(33),serv
account   whatsapp_read (an older spe…  PASS     1      493    {effect:string(4),error:string(21),fix:string(103),input:string(34),message:string(99),note:stri
account   mcp_whatsapp_native_read_ne…  PASS     2      484    {effect:string(4),error:string(21),fix:string(103),input:string(2),message:string(99),note:strin
account   whatsapp_operator (retired)   PASS     2      478    {effect:string(4),error:string(21),fix:string(76),input:string(2),message:string(89),note:string
account   read_snapshot (component na…  NOT-RUN  2      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_search
account   read_newest (component name)  NOT-RUN  2      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_read
account   list_chats (component name)   NOT-RUN  2      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_contacts
account   posting_status (component n…  NOT-RUN  2      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_approve
account   read_field (component name)   NOT-RUN  2      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_media
account   lookup_self (component name)  NOT-RUN  2      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_contacts
account   inspect_chat (component nam…  NOT-RUN  2      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_read
account   download_audio (component n…  NOT-RUN  2      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_download
account   send_message (component nam…  NOT-RUN  2      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_send
laptop    mcp_whatsapp_contacts         NOT-RUN  74     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_search           NOT-RUN  66     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_read             NOT-RUN  59     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_reactions        NOT-RUN  61     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_media            NOT-RUN  46     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_download         NOT-RUN  55     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_backfill         NOT-RUN  60     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_send             NOT-RUN  74     733    the step it resumes answered no job id here: reuse_unavailable:send
laptop    mcp_whatsapp_send_status      NOT-RUN  0      0      the step it resumes answered no job id here: reuse_unavailable:send
laptop    mcp_whatsapp_approve          NOT-RUN  163    755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_send (same mes…  NOT-RUN  144    733    the send it repeats never queued here, so there is no job to dedupe (see the send cell)
laptop    mcp_whatsapp_send (cancel a…  NOT-RUN  0      0      the send it cancels never queued here, so there is no job to take out (see the send cell)
laptop    whatsapp_read (an older spe…  PASS     2      493    {effect:string(4),error:string(21),fix:string(103),input:string(34),message:string(99),note:stri
laptop    mcp_whatsapp_native_read_ne…  PASS     2      484    {effect:string(4),error:string(21),fix:string(103),input:string(2),message:string(99),note:strin
laptop    whatsapp_operator (retired)   PASS     2      478    {effect:string(4),error:string(21),fix:string(76),input:string(2),message:string(89),note:string
work      mcp_whatsapp_contacts         NOT-RUN  74     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_search           NOT-RUN  71     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_read             NOT-RUN  66     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_reactions        NOT-RUN  50     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_media            NOT-RUN  65     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_download         NOT-RUN  61     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_backfill         NOT-RUN  55     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_send             NOT-RUN  72     733    the step it resumes answered no job id here: reuse_unavailable:send
work      mcp_whatsapp_send_status      NOT-RUN  0      0      the step it resumes answered no job id here: reuse_unavailable:send
work      mcp_whatsapp_approve          NOT-RUN  141    755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_send (same mes…  NOT-RUN  130    733    the send it repeats never queued here, so there is no job to dedupe (see the send cell)
work      mcp_whatsapp_send (cancel a…  NOT-RUN  0      0      the send it cancels never queued here, so there is no job to take out (see the send cell)
work      whatsapp_read (an older spe…  PASS     2      493    {effect:string(4),error:string(21),fix:string(103),input:string(34),message:string(99),note:stri
work      mcp_whatsapp_native_read_ne…  PASS     2      484    {effect:string(4),error:string(21),fix:string(103),input:string(2),message:string(99),note:strin
work      whatsapp_operator (retired)   PASS     3      478    {effect:string(4),error:string(21),fix:string(76),input:string(2),message:string(89),note:string

row                                     verdict  ms     why / code
--------------------------------------  -------  -----  ---------------------------------------------
guard/own-chat-account                  PASS     0      
flow/voice-reply                        NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code rust/components/wa-whatsapp/src/guest.rs (transcript -> tx/ record), src/posting.rs; owner whatsapp-transcription-works, whatsapp-posting-toggle
flow/deleted-after-index                NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code rust/components/wa-whatsapp/src/index.rs (the delete event), rust/wa-whatsapp-index/src/lib.rs; owner whatsapp-hold-not-silent
flow/voice-deleted-before-reply         NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code rust/components/wa-whatsapp/src/posting.rs (the gate reads the source record); owner whatsapp-hold-not-silent
flow/picture-ocr                        NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code rust/components/wa-whatsapp/src/ocr.rs, src/guest.rs ocr_tick; owner whatsapp-transcription-works
flow/large-image-one-call               NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code rust/wa-capabilities/src/whatsapp_query.rs ask_download (MAX_DOWNLOAD_BYTES 512 KiB); owner run-images-two-node
flow/send-from-work                     NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code lua/core/whatsapp.lua M.send -> M.routed -> rust/wa-capabilities/src/whatsapp_send.rs; owner whatsapp-acceptance (this one) - it is the row that proves the peer hop
row/send-then-search                    NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code rust/components/wa-whatsapp/src/index.rs search order (newest first); owner whatsapp-read-is-consistent
row/empty-chat-freshness                NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code rust/components/wa-whatsapp/src/alerts.rs, src/index.rs freshness fields; owner whatsapp-read-is-consistent
row/text-and-voice                      NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code rust/components/wa-whatsapp/src/view.rs message shape (transcript field); owner whatsapp-transcription-works
row/cross-chat-labels                   NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code rust/components/wa-whatsapp/src/view.rs hit_json (chat_name per row); owner whatsapp-read-is-consistent
row/send-then-read                      NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code lua/core/whatsapp.lua M.settle -> the read that follows; owner whatsapp-read-is-consistent
row/three-reads                         NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code lua/core/whatsapp.lua M.call (read), rust/wa-whatsapp-index/src/lib.rs; owner whatsapp-read-is-consistent
row/voice-text-in-read-and-search       NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code rust/components/wa-whatsapp/src/index.rs (transcript is indexed as text); owner whatsapp-transcription-works
row/both-id-forms                       NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this runs on the account's own node at G; code rust/components/wa-whatsapp/src/index.rs alias table; owner whatsapp-read-is-consistent
guard/own-chat-laptop                   PASS     0      
guard/own-chat-work                     PASS     0      

whatsapp-acceptance: 14 pass, 40 not-run, 0 fail, across 54 cells and 17 rows
```

Reading it: 14 PASS, 40 NOT-RUN, 0 FAIL, across 54 cells and 17 rows. Zero FAIL is not "everything works" -
it means nothing this machine CAN run is broken, and it says exactly which cells it cannot run and why:

* **Every read (contacts, search, read, reactions, media, download, backfill) is NOT-RUN, with the same
  measured cause**: the capability put the question on `whatsapp.query` as a job and answered
  `whatsapp_<op>_slow` (`rust/wa-capabilities/src/whatsapp_query.rs`), because nothing settles that queue
  here. The component that would settle it pairs with a phone: without a stored paired device its protocol
  task stops and the instance returns (`rust/components/wa-whatsapp/src/guest.rs`, "bot stopped: this
  instance takes no more work"), so a scratch node cannot be a fake account. What the cells DO prove is
  measured on them: validation and bounding before anything is queued, the queue write, the dedupe key, and
  the exact 859-884 bytes of refusal shape the model would receive.
* **The peer sites are NOT-RUN for a fleet reason, measured on the wire**: the hop was ADMITTED by the
  signed roster (`mesh recv ... verb=call decision=allow reason=hierarchy_allowed`, the account node's own
  audit line) and the account node then refused the caller's role - `lua/core/server.lua:1034`
  (`verify_peer` -> `forbidden_role`) - because a scratch rendezvous registers every node as a guest; it
  grants master only to the ids the operator lists for the network, and the `edit_admin_set` hook refuses a
  session that sets that list. That is a guard, not a bug this brief may work around (FACTORY rule 12). See
  §7 for what the same hop does on the real fleet, and the open question it leaves.
* **The write path is proved end to end**: `send` queued one job and answered the pending shape (283 bytes);
  the same chat+text again answered the SAME job (dedupe, `lua/core/whatsapp.lua` `M.send`); the hidden
  `send_status` read it back; `cancel` took it out of the queue (`cancelled:true`); `approve {action:list}`
  answered the gate's empty draft list; the retired and renamed names (`whatsapp_operator`,
  `whatsapp_read`, `mcp_whatsapp_native_read_newest_<hash>`) each answered the one sentence that names the
  replacement; and the own-chat guard refused a target that was not the configured own chat on all three
  sites before any call.

## 4. The six flows and the rows Fable added

Each row is in the table with the code it would run through. None of them can be measured on a machine with
no paired device, and each says so with its own code path - the content rows are the G run's to fill:

| Row | State here | Code path | Owner when it fails | Canary |
| --- | --- | --- | --- | --- |
| voice note -> transcript -> reply posted | NOT-RUN (no device) | `rust/components/wa-whatsapp/src/guest.rs`, `src/posting.rs` | whatsapp-transcription-works, whatsapp-posting-toggle | `lua/core/canaries/whatsapp-transcription.lua`, `whatsapp-copilot-reply.lua` |
| deleted after indexed -> content kept + flagged | NOT-RUN | `src/index.rs` (the delete event) | whatsapp-hold-not-silent | none exists - proposed `whatsapp-deletions.lua` |
| voice deleted before the reply -> reply skipped | NOT-RUN | `src/posting.rs` (the gate reads the record) | whatsapp-hold-not-silent | `whatsapp-copilot-reply.lua` + proposed `whatsapp-deletions.lua` |
| picture -> OCR | NOT-RUN | `src/ocr.rs`, `guest.rs` `ocr_tick` | whatsapp-transcription-works | none exists - proposed `whatsapp-media.lua` |
| a 120 KB image from a peer in ONE call | NOT-RUN | `rust/wa-capabilities/src/whatsapp_query.rs` `ask_download` (512 KiB bound) | run-images-two-node | none exists - proposed `whatsapp-media.lua`, `whatsapp-peer-call.lua` |
| a send from work arrives | NOT-RUN (role refusal, §3) | `lua/core/whatsapp.lua` `M.send` -> `M.routed` -> `whatsapp_send` | this brief | `lua/core/canaries/whatsapp-send.lua`, proposed `whatsapp-peer-call.lua` |
| send-then-search (newest first, order stated) | NOT-RUN | `src/index.rs` search order | whatsapp-read-is-consistent | `whatsapp-index.lua` |
| empty-chat read freshness (as_of, last_received_s, connected) | NOT-RUN | `src/alerts.rs`, `src/index.rs` | whatsapp-read-is-consistent | `whatsapp-index.lua` |
| text + voice note, both in order, transcript inline | NOT-RUN | `src/view.rs` message shape | whatsapp-transcription-works | `whatsapp-transcription.lua` |
| a read across chats labels every row with its chat | NOT-RUN | `src/view.rs` `hit_json` | whatsapp-read-is-consistent | `whatsapp-index.lua` |
| send-then-read | NOT-RUN | `M.settle` -> the read that follows | whatsapp-read-is-consistent | `whatsapp-send.lua` |
| three reads never older than the one before | NOT-RUN | `M.call` (read), `wa-whatsapp-index` | whatsapp-read-is-consistent | `whatsapp-index.lua` |
| a voice record's text in read AND search | NOT-RUN | `src/index.rs` (the transcript is indexed as text) | whatsapp-transcription-works | `whatsapp-transcription.lua` |
| both id forms of one chat give the same messages | NOT-RUN | `src/index.rs` alias table | whatsapp-read-is-consistent | `whatsapp-index.lua` |

**The content behind those rows is not untested - it is tested one layer below, in Rust, on this machine.**
`cargo test --lib` in `rust/components/wa-whatsapp` answers **196 passed, 0 failed** (0.15 s, the binary this
branch builds), and the tests that carry these rows are real:

* `index::tests::a_delete_keeps_the_content_and_flags_it_beside_it` - the deleted-after-index row;
* `index::tests::a_voice_note_is_found_by_its_transcript_and_keeps_its_duration` - the transcript row;
* `index::tests::a_cut_transcript_says_so_and_the_two_exact_ops_return_it_whole`;
* `index::tests::alias_pairs_are_one_lid_and_one_phone_number` - the both-id-forms row;
* `index::tests::the_address_book_and_the_messages_meet_in_either_order`;
* `ocr::tests::an_image_is_ocred_attached_and_found_by_its_text` - the picture->OCR row;
* `ocr::tests::an_oversized_image_is_refused_cleanly_and_the_reader_is_never_started`;
* `view::tests::a_deleted_message_says_so_and_carries_no_text`, `view::tests::the_header_names_the_chat_and_never_invents_an_unread_count`.

What that does NOT prove, and this brief will not claim it does: those are the index and the view over a
fake client (`Memory`), not a tool answer over a real account. The row stays NOT-RUN until the G run
against the operator's own chat, which is what the table is for.

## 5. What was verified, what was not

Verified on this node (measured, not asserted):

1. The scratch fleet comes up: three `wa serve` nodes + a local rendezvous + a signed roster, /health within
   the timeout, node names `account`/`laptop`/`work` from their own directories (`lua/core/nodes.lua`
   `M.worktree`).
2. Every one of the ten `mcp_whatsapp_*` names answers through the real path from all three sites, with the
   bytes and shape in the table.
3. The write path: queue, dedupe, resume, cancel, the approval gate's list, and the three name refusals.
4. The own-chat guard refuses another target before the call, on every site.
5. The table prints no chat id, phone number, message id or message text: the driver prints a shape and an
   allow-list, redacted; the script re-checks every value and exits 4 rather than print a JID or a run of
   five digits (`scrub`). The scratch run's own output was read line by line for that.
6. `scripts/test-whatsapp-acceptance.mjs`: 43 checks, green, wired into `scripts/fast.sh`.
7. That test DISCRIMINATES: on a separate worktree of the base commit `e832e152` it exits 1 with 31 of 33
   checks failing (nothing to test there), and on this branch it is green - measured, not assumed (rule 16).

Not verified (and not claimed):

* Any answer that needs a paired device (all reads, all six flows, the four Fable rows) - the reason is in
  every cell.
* The live mode has never run: it needs the operator's own chat on the account node, and it must not run
  from this brief. The refusal path (missing target, malformed target) IS tested.
* The peer hop's admission end to end: admitted by the roster, refused by role (`server.lua:1034`). Not a
  tool failure, but not a proved peer call either.
* Which chat is the account's OWN chat is not readable from the node: no configured own-chat source exists
  (searched: `WASM_AGENT_*`, `config/`, `lua/core`). The live run therefore takes `--own-chat` from the
  operator and can verify it only from the data: in a self-chat every message's `from.own` is true. The G
  run should read the own chat once and treat a page with any `from.own:false` row as "not the own chat -
  stop", which is what the brief's "never another person's chat" needs.

## 6. New or changed model- or operator-facing strings, verbatim (for approval)

1. `refused_not_own_chat` - the driver's error word for a step that names a chat other than the configured
   own chat (live mode). Nothing is called when it is answered.
2. `whatsapp-acceptance: mode <scratch|live>, binary <path>`
3. `  work root <path>`
4. `whatsapp-acceptance: refusing to run: <path> is inside the node home <path>`
5. `whatsapp-acceptance: refusing to run: no temporary directory outside the node home <path>`
6. `whatsapp-acceptance: refusing to print <where>: a value looks like a chat id or a phone number (<value>)`
7. `whatsapp-acceptance: no wa binary: pass --bin, or set WA_BIN (this run builds nothing)`
8. `--mode live needs --own-chat <jid>: the run touches the operator's own chat and nothing else`
9. `--own-chat is not an exact chat JID (<digits>@s.whatsapp.net, @lid or @g.us)`
10. `whatsapp-acceptance: <n> pass, <n> not-run, <n> fail, across <n> cells and <n> rows`
11. `test-whatsapp-acceptance: ok (<n> checks: every surface verb is a row, live mode refuses a missing or malformed target, the own-chat guard runs before the call, the driver redacts, and a run in the node home refuses)`
12. The verdict sentences the table prints (all in the table above): "no paired device on this machine: the
    capability queued the question as job N and answered whatsapp_<op>_slow ...", "the hop was admitted by
    the signed roster (mesh decision=allow) and the account node refused the caller's role ...", "one job for
    the repeated message (lua/core/whatsapp.lua M.send; the dedupe key is the request)", "the queued job was
    taken out of the queue before any worker held it (rust/wa-capabilities/src/whatsapp_send.rs, the cancel
    branch)".

## 7. Open question for Fable (not a fix in this branch)

The peer hop is admitted by the signed roster and then refused by role, because the mesh's attested caller
did not reach the handler: `lua/core/server.lua` `mesh_caller` returns the attested caller with
`role = "master"` (its own comment says so), and `verify_peer` fell through to
`nodeslib.verify_caller(..., {fresh = true})` (line 1032-1034) - the rendezvous answer - which is a guest on
a scratch fleet. On the operator's fleet the rendezvous itself grants master to the listed ids, so a peer
call works there through the same line; the attestation path is the fallback that does not. Two things to
decide, both outside this brief: (a) is a fleet roster alone supposed to admit a peer when the rendezvous
grants no master? (b) if yes, `mesh_caller` needs a test that fails when it returns nil for an admitted
call - there is none today (searched: `scripts/test-node-dispatch-wiring.lua`, `test-mesh-*` exercise the
mesh mount, not this pairing).

## 8. Proposed text (NOT written here)

`FACTORY.md`, "Phase A of an acceptance brief":

> A brief that produces an acceptance TABLE runs both halves of it: the scratch run (its own homes, a local
> rendezvous, a roster signed for that run, the shipped policy) on the branch's own binary, and the live run
> at G, by the orchestrator, against the configured own chat only. A cell that cannot be measured is NOT-RUN
> with the reason and the code path - never PASS, and never dropped from the table.

`HANDOVER.md`, WhatsApp section:

> The WhatsApp acceptance table is `docs/missions/reports/whatsapp-acceptance.md`; re-run it with
> `node scripts/whatsapp-acceptance.mjs --mode live --own-chat <the account's own chat>` on the account
> node. A red cell there is a release hold; a yellow one (NOT-RUN) is a cell the node cannot answer, and
> the report says which brief owns it.

## 9. Commits

- `ec984d89` - the one script (`scripts/whatsapp-acceptance.mjs`), the in-node driver
  (`scripts/lib/whatsapp-acceptance-call.lua`), the guard test (`scripts/test-whatsapp-acceptance.mjs`, 43
  checks) and its fast-path row in `scripts/fast.sh`.
- `5ee0498d` - this report, the table and the per-cell mapping.
- `6668a1cc` - the guard test's discrimination measured on a separate worktree of `e832e152` (exit 1, 31 of
  33 checks failing there).

The commit trailers name the model as `claude`: the session carries no exact model id, and inventing one
would be a false record.

