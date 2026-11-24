# whatsapp-acceptance - every WhatsApp tool and flow, one table

Mission: `whatsapp-acceptance` (brief in the mission directory; Fable 23/11 ~18:00Z, rows added 23/11
~23:00-23:55Z and ~19:55Z). Branch `change/whatsapp-acceptance`, rebased onto `origin/main`
`18b83398` - which CONTAINS the gate the brief waited for, `d2fbd140` (land-quick merge of
`change/whatsapp-read-return`, "whatsapp-read-is-consistent" with `full_text`/`text_cut`'s real
equivalents; see §4).

Victor's words: "ensure the whatsapp mcp works flawlessly". This is the phase-A deliverable: ONE script that
runs every cell and every flow and prints the table, plus the table this machine produces against the
rebased main, and the mapping from every cell that is not green to the brief that owns it and the canary
that has to keep it green. Phase B - the same script against the operator's own chat on the account node -
is the orchestrator's, with Fable's OK; §10 is the exact command and what Victor must do by hand.

## 1. What was built

| Path | What it is |
| --- | --- |
| `scripts/whatsapp-acceptance.mjs` | The one script. `--mode scratch` (default) starts three scratch nodes on this machine - account, laptop, work - each with its own home, a local rendezvous and a fleet roster signed by a key made for this run, all answered by the `wa` binary of this checkout. `--mode live --own-chat <jid>` runs the same rows against the node's OWN chat and refuses every other target. Prints PASS / FAIL (with the cause, file:line) / NOT-RUN (with the reason), the measured milliseconds, the bytes and the shape the MODEL receives. |
| `scripts/lib/whatsapp-acceptance-call.lua` | The in-node driver. Runs one plan of steps through the real Lua surface (`tools.dispatch` on `mcp_whatsapp_*`), and prints a measurement per step: verdict, ms, bytes of the answer the model receives, the answer's SHAPE (keys, types, array sizes) and an allow-list of scalar fields, everything redacted. Message text, chat JIDs, phone numbers and message ids never leave it. The own-chat guard is an allow-list checked BEFORE the dispatch; its one exception is a `synthetic` step, allowed past it only when the chat is NOT a well-formed JID (a validation probe on a shape no account can own - a well-formed foreign chat is still refused). |
| `scripts/test-whatsapp-acceptance.mjs` | The script's own contracts, no node started (45 checks): every verb of `lua/core/whatsapp.lua` is a row, live mode refuses a missing or malformed own-chat target, the own-chat guard sits in the driver BEFORE the dispatch and its synthetic bypass is limited to non-JID shapes, the driver redacts, a run in the node home refuses. Wired into `scripts/fast.sh` as the fast-path row `whatsapp-acceptance`. |

The scratch fleet is real, not a stub: three `wa serve` processes, a local rendezvous, a `wa fleet
keygen`/`fleet sign` roster (levels: account 1, the two callers 0), each node's policy being the SHIPPED
`policies/default.json` plus its mesh section - so a send in this table was decided by the real
`whatsapp.send` rule and its caps, not by a policy written for the test.

## 2. The surface: the brief's list, re-measured

The brief's list was: send, send_status, read, search, media, download, reactions, contacts, backfill,
approve. Measured against `lua/core/whatsapp.lua` (`M.TOOLS`, every one `mcp_whatsapp_<verb>`):

* eight are OFFERED to the model - `contacts`, `search`, `read`, `reactions`, `media`, `download`,
  `backfill`, `send`;
* two are HIDDEN doors, callable and not in any catalogue - `send_status` (the resume form of `send`) and
  `approve` (the operator's approval gate, `docs/APPROVE.md`).

**The component exposes nine names the brief's list does not have, and the surface does not offer them.**
`rust/components/mcp-whatsapp/src/main.rs` `tools()` lists `read_snapshot`, `read_newest`, `list_chats`,
`posting_status`, `read_field`, `lookup_self`, `inspect_chat`, `download_audio`, `send_message`; each is
answered by `M.renamed` with the one replacement name (`read_newest` -> `mcp_whatsapp_read`, and so on).
They are rows of the table below, NOT-RUN by construction, with the replacement they answer with.

Two premises from the orchestrator's message, re-measured on this main: **`full_text` and `text_cut` are not
fields in this tree** (searched: `rg full_text|text_cut` outside docs/reviews - nothing). The landed
contract's names are `transcript_full` (a pointer object `{tool: "whatsapp_message", ...}` for a long body),
the cut marker in the body itself, and `text_reason` (`transcript_pending`, `ocr_pending`,
`unsupported`); the row that covers them is `row/long-body-pointer` in §4.

## 3. The table (this node, `--mode scratch`, against `origin/main` 18b83398)

```
site      tool                          verdict  ms     bytes  what the model receives / why
--------  ----------------------------  -------  -----  -----  ---------------------------------------------
account   mcp_whatsapp_contacts         NOT-RUN  2087   879    no paired device on this machine: the capability queued the question as job 1 and answered whatsapp_contacts_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_search           NOT-RUN  2042   869    no paired device on this machine: the capability queued the question as job 2 and answered whatsapp_search_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_read             NOT-RUN  2050   859    no paired device on this machine: the capability queued the question as job 3 and answered whatsapp_read_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_reactions        NOT-RUN  2050   884    no paired device on this machine: the capability queued the question as job 4 and answered whatsapp_reactions_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_media            NOT-RUN  2053   864    no paired device on this machine: the capability queued the question as job 5 and answered whatsapp_media_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_download         NOT-RUN  10050  879    no paired device on this machine: the capability queued the question as job 6 and answered whatsapp_download_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_backfill         NOT-RUN  2039   879    no paired device on this machine: the capability queued the question as job 7 and answered whatsapp_backfill_slow (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)
account   mcp_whatsapp_send             PASS     33     283    {attempts:number,id:number,note:string(95),ok:boolean,queue_state:string(6),reads:number,resume:
account   mcp_whatsapp_send_status      PASS     23     151    {attempts:number,id:number,ok:boolean,reads:number,reason:string(33),served_by:string(7),state:s
account   mcp_whatsapp_approve          PASS     16     111    {drafts:{},ok:boolean,root:string(53),status:number,waiting:number}
account   mcp_whatsapp_send (same mes…  PASS     61     283    {attempts:number,id:number,note:string(95),ok:boolean,queue_state:string(6),reads:number,resume:
account   mcp_whatsapp_send (cancel a…  PASS     28     189    {attempts:number,cancelled:boolean,effect:string(34),id:number,ok:boolean,reason:string(33),serv
account   mcp_whatsapp_search (order:…  PASS     2046   869    {detail:string(80),effect:string(4),error:string(20),fix:string(216),id:number,input:string(80),
account   mcp_whatsapp_search (an unk…  PASS     12     508    {detail:string(33),effect:string(4),error:string(25),fix:string(198),input:string(33),message:st
account   mcp_whatsapp_search (no nar…  PASS     12     524    {detail:string(36),effect:string(4),error:string(27),fix:string(202),input:string(36),message:st
account   mcp_whatsapp_read (a malfor…  PASS     13     593    {detail:string(90),effect:string(4),error:string(22),fix:string(192),input:string(80),message:st
account   whatsapp_read (an older spe…  PASS     2      493    {effect:string(4),error:string(21),fix:string(103),input:string(34),message:string(99),note:stri
account   mcp_whatsapp_native_read_ne…  PASS     1      484    {effect:string(4),error:string(21),fix:string(103),input:string(2),message:string(99),note:strin
account   whatsapp_operator (retired)   PASS     1      478    {effect:string(4),error:string(21),fix:string(76),input:string(2),message:string(89),note:string
account   read_snapshot (component na…  NOT-RUN  1      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_search
account   read_newest (component name)  NOT-RUN  1      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_read
account   list_chats (component name)   NOT-RUN  1      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_contacts
account   posting_status (component n…  NOT-RUN  1      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_approve
account   read_field (component name)   NOT-RUN  1      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_media
account   lookup_self (component name)  NOT-RUN  1      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_contacts
account   inspect_chat (component nam…  NOT-RUN  1      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_read
account   download_audio (component n…  NOT-RUN  1      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_download
account   send_message (component nam…  NOT-RUN  1      0      not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with mcp_whatsapp_send
laptop    mcp_whatsapp_contacts         NOT-RUN  63     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_search           NOT-RUN  45     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_read             NOT-RUN  44     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_reactions        NOT-RUN  45     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_media            NOT-RUN  42     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_download         NOT-RUN  39     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_backfill         NOT-RUN  41     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_send             NOT-RUN  41     733    the step it resumes answered no job id here: reuse_unavailable:send
laptop    mcp_whatsapp_send_status      NOT-RUN  0      0      the step it resumes answered no job id here: reuse_unavailable:send
laptop    mcp_whatsapp_approve          NOT-RUN  106    755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
laptop    mcp_whatsapp_send (same mes…  NOT-RUN  82     733    the send it repeats never queued here, so there is no job to dedupe (see the send cell)
laptop    mcp_whatsapp_send (cancel a…  NOT-RUN  0      0      the send it cancels never queued here, so there is no job to take out (see the send cell)
laptop    mcp_whatsapp_search (order:…  NOT-RUN  45     755    the account node refused the caller's role (lua/core/server.lua:1034); the contract was not reached from this site
laptop    mcp_whatsapp_search (an unk…  NOT-RUN  43     755    the account node refused the caller's role (lua/core/server.lua:1034); the contract was not reached from this site
laptop    mcp_whatsapp_search (no nar…  NOT-RUN  39     755    the account node refused the caller's role (lua/core/server.lua:1034); the contract was not reached from this site
laptop    mcp_whatsapp_read (a malfor…  NOT-RUN  41     755    the account node refused the caller's role (lua/core/server.lua:1034); the contract was not reached from this site
laptop    whatsapp_read (an older spe…  PASS     2      493    {effect:string(4),error:string(21),fix:string(103),input:string(34),message:string(99),note:stri
laptop    mcp_whatsapp_native_read_ne…  PASS     2      484    {effect:string(4),error:string(21),fix:string(103),input:string(2),message:string(99),note:strin
laptop    whatsapp_operator (retired)   PASS     1      478    {effect:string(4),error:string(21),fix:string(76),input:string(2),message:string(89),note:string
work      mcp_whatsapp_contacts         NOT-RUN  59     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_search           NOT-RUN  43     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_read             NOT-RUN  40     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_reactions        NOT-RUN  41     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_media            NOT-RUN  49     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_download         NOT-RUN  47     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_backfill         NOT-RUN  35     755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_send             NOT-RUN  42     733    the step it resumes answered no job id here: reuse_unavailable:send
work      mcp_whatsapp_send_status      NOT-RUN  0      0      the step it resumes answered no job id here: reuse_unavailable:send
work      mcp_whatsapp_approve          NOT-RUN  101    755    the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached
work      mcp_whatsapp_send (same mes…  NOT-RUN  83     733    the send it repeats never queued here, so there is no job to dedupe (see the send cell)
work      mcp_whatsapp_send (cancel a…  NOT-RUN  0      0      the send it cancels never queued here, so there is no job to take out (see the send cell)
work      mcp_whatsapp_search (order:…  NOT-RUN  44     755    the account node refused the caller's role (lua/core/server.lua:1034); the contract was not reached from this site
work      mcp_whatsapp_search (an unk…  NOT-RUN  41     755    the account node refused the caller's role (lua/core/server.lua:1034); the contract was not reached from this site
work      mcp_whatsapp_search (no nar…  NOT-RUN  41     755    the account node refused the caller's role (lua/core/server.lua:1034); the contract was not reached from this site
work      mcp_whatsapp_read (a malfor…  NOT-RUN  40     755    the account node refused the caller's role (lua/core/server.lua:1034); the contract was not reached from this site
work      whatsapp_read (an older spe…  PASS     1      493    {effect:string(4),error:string(21),fix:string(103),input:string(34),message:string(99),note:stri
work      mcp_whatsapp_native_read_ne…  PASS     2      484    {effect:string(4),error:string(21),fix:string(103),input:string(2),message:string(99),note:strin
work      whatsapp_operator (retired)   PASS     2      478    {effect:string(4),error:string(21),fix:string(76),input:string(2),message:string(89),note:string

row                                     verdict  ms     why / code
--------------------------------------  -------  -----  ---------------------------------------------
guard/own-chat-account                  PASS     0      
flow/voice-reply                        NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by index::tests::a_voice_note_is_found_by_its_transcript_and_keeps_its_duration; view::tests::a_voice_note_with_a_transcript_answers_with_the_transcript_and_its_way_to_the_whole; code rust/components/wa-whatsapp/src/guest.rs (transcript -> tx/ record), src/posting.rs; owner whatsapp-transcription-works, whatsapp-posting-toggle
flow/deleted-after-index                NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by index::tests::a_delete_keeps_the_content_and_flags_it_beside_it; view::tests::a_deleted_message_says_so_and_carries_no_text; code rust/components/wa-whatsapp/src/index.rs (the delete event), rust/wa-whatsapp-index/src/lib.rs; owner whatsapp-hold-not-silent
flow/voice-deleted-before-reply         NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by outbox::tests::a_clean_quote_goes_out_and_no_deletion_refuses_a_send (the deletion fence, the send half); code rust/components/wa-whatsapp/src/posting.rs (the gate reads the source record); owner whatsapp-hold-not-silent
flow/picture-ocr                        NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by ocr::tests::an_image_is_ocred_attached_and_found_by_its_text; view::tests::media_is_metadata_with_a_name_a_size_and_the_caption; code rust/components/wa-whatsapp/src/ocr.rs, src/guest.rs ocr_tick; owner whatsapp-transcription-works
flow/large-image-one-call               NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by whatsapp_query tests (the download path over a real queue); the 512 KiB bound is seam::MAX_DOWNLOAD_BYTES; code rust/wa-capabilities/src/whatsapp_query.rs ask_download (MAX_DOWNLOAD_BYTES 512 KiB); owner run-images-two-node
flow/send-from-work                     NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by whatsapp_send tests (queue, dedupe, cancel) - the peer half is the row this table could not measure; code lua/core/whatsapp.lua M.send -> M.routed -> rust/wa-capabilities/src/whatsapp_send.rs; owner whatsapp-acceptance (this one) - it is the row that proves the peer hop
row/send-then-search                    NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by index::tests::a_message_this_node_sent_is_in_search_the_moment_its_record_is_written; index::tests::a_chat_scoped_search_answers_newest_first_and_says_so; code rust/components/wa-whatsapp/src/index.rs read_paced/search_paced (order {key, direction, cursor}), src/guest.rs (the eager write before the send answers); owner whatsapp-read-is-consistent
row/empty-chat-freshness                NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by index::tests::a_read_says_how_fresh_it_is_and_two_reads_in_a_row_never_go_backwards; the transport half (connected) is the canary's read_no_connected/read_no_receive_freshness stages; code rust/components/wa-whatsapp/src/guest.rs receive_freshness, src/index.rs index_state/order_block; owner whatsapp-read-is-consistent
row/text-and-voice                      NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by index::tests::a_chat_whose_last_two_messages_are_a_text_and_a_voice_note_reads_both_with_the_transcript_inline; code rust/components/wa-whatsapp/src/view.rs message shape (text IS the transcript; text_reason when it is not); owner whatsapp-transcription-works
row/cross-chat-labels                   NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by index::tests::a_search_that_mixes_chats_labels_every_hit_with_its_chat_and_a_read_never_mixes_them; code rust/components/wa-whatsapp/src/view.rs hit_json (chat + chat_name per hit); index.rs read refuses without a chat; owner whatsapp-read-is-consistent
row/send-then-read                      NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by index::tests::a_message_this_node_sent_is_in_search_the_moment_its_record_is_written (the read half is the same test); outbox::tests::status_says_whether_the_sent_message_is_in_the_history; code rust/components/wa-whatsapp/src/guest.rs (the outbox Ok(message_id) arm writes the record before the send answers); lua/core/whatsapp.lua carries in_history; owner whatsapp-read-is-consistent
row/three-reads                         NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by index::tests::a_read_says_how_fresh_it_is_and_two_reads_in_a_row_never_go_backwards; code rust/components/wa-whatsapp/src/index.rs observe_as_of + as_of_regressed; owner whatsapp-read-is-consistent
row/voice-text-in-read-and-search       NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by index::tests::a_voice_note_is_found_by_its_transcript_and_keeps_its_duration; view::tests::a_voice_note_with_no_transcript_says_so_instead_of_an_empty_text; code rust/components/wa-whatsapp/src/index.rs (the transcript is indexed as text), src/view.rs stand_in (text_reason instead of an empty text); owner whatsapp-transcription-works
row/both-id-forms                       NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by index::tests::one_chat_is_one_history_under_both_of_its_addresses; index::tests::alias_pairs_are_one_lid_and_one_phone_number; code rust/components/wa-whatsapp/src/index.rs read (ix/al alias merge), answer addresses/resolved_form; owner whatsapp-read-is-consistent
row/long-body-pointer                   NOT-RUN  0      no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so the tool-level cell is the G run's; on this main the contract is covered by view::tests::a_long_message_is_a_pointer_to_its_stored_text; index::tests::a_cut_transcript_says_so_and_the_two_exact_ops_return_it_whole; code rust/components/wa-whatsapp/src/view.rs (the cut marker + transcript_full {tool: whatsapp_message}); owner whatsapp-read-is-consistent
guard/own-chat-laptop                   PASS     0      
guard/own-chat-work                     PASS     0      

whatsapp-acceptance: 18 pass, 48 not-run, 0 fail, across 66 cells and 18 rows
```

Reading it: **18 PASS, 48 NOT-RUN, 0 FAIL**, across 66 cells and 18 rows.

* **Every read (contacts, search, read, reactions, media, download, backfill) is NOT-RUN, with the same
  measured cause**: the capability put the question on `whatsapp.query` as a job and answered
  `whatsapp_<op>_slow` (`rust/wa-capabilities/src/whatsapp_query.rs`), because nothing settles that queue
  here. The component that would settle it pairs with a phone: without a stored paired device its protocol
  task stops and the instance returns (`rust/components/wa-whatsapp/src/guest.rs`, "bot stopped: this
  instance takes no more work"), so a scratch node cannot be a fake account. What those cells DO prove is
  measured on them: validation and bounding before anything is queued, the queue write, the dedupe key, and
  the exact 859-884 bytes of refusal shape the model would receive.
* **The landed read contract's own refusals are green, with no device** - the cells this main made
  measurable: `search {order:"newest"}` is accepted and queued (the order travels); `order:"sideways"` is
  refused by name with `whatsapp_search_bad_order`; a search with no narrowing is refused with
  `whatsapp_search_empty_query`; a malformed chat (`1-2-3@g.us`) is refused with `whatsapp_read_bad_chat`.
  Those four are `rust/wa-whatsapp-index/src/lib.rs` + `wa-capabilities/src/whatsapp_query.rs` answering
  before any queue write, and a regression in them is exactly what a canary should catch.
* **The write path is proved end to end**: `send` queued one job and answered the pending shape (283 bytes);
  the same chat+text again answered the SAME job (dedupe, `lua/core/whatsapp.lua` `M.send`); the hidden
  `send_status` read it back; `cancel` took it out of the queue (`cancelled:true`); `approve {action:list}`
  answered the gate's empty draft list; the retired and renamed names (`whatsapp_operator`,
  `whatsapp_read`, `mcp_whatsapp_native_read_newest_<hash>`) each answered the one sentence that names the
  replacement; and the own-chat guard refused a target that was not the configured own chat on all three
  sites before any call.
* **The peer sites are NOT-RUN for a fleet reason, measured on the wire**: the hop was ADMITTED by the
  signed roster (`mesh recv ... verb=call decision=allow reason=hierarchy_allowed`, the account node's own
  audit line) and the account node then refused the caller's role - `lua/core/server.lua:1034`
  (`verify_peer` -> `forbidden_role`) - because a scratch rendezvous registers every node as a guest; it
  grants master only to the ids the operator lists for the network, and the `edit_admin_set` hook refuses a
  session that sets that list. That is a guard, not a bug this brief may work around (FACTORY rule 12). See
  §7 for the open question it leaves.

## 4. The six flows, Fable's rows, and what covers each on this main

Each row is in the table with the code it runs through. None of the CONTENT rows can be measured on a
machine with no paired device, and each says so with its own code path; the column "covered on this main
by" is the named test that already holds the contract at the layer below (all of them green in
`cargo test --lib` in `rust/components/wa-whatsapp`: **196 passed, 0 failed**).

| Row | State here | Covered on this main by | Owner when it fails | Canary |
| --- | --- | --- | --- | --- |
| voice note -> transcript -> reply posted | NOT-RUN (no device) | `index::tests::a_voice_note_is_found_by_its_transcript_and_keeps_its_duration`, `view::tests::a_voice_note_with_a_transcript_answers_with_the_transcript_and_its_way_to_the_whole` | whatsapp-transcription-works, whatsapp-posting-toggle | `lua/core/canaries/whatsapp-transcription.lua`, `whatsapp-copilot-reply.lua` |
| deleted after indexed -> content kept + flagged | NOT-RUN | `index::tests::a_delete_keeps_the_content_and_flags_it_beside_it`, `view::tests::a_deleted_message_says_so_and_carries_no_text` | whatsapp-hold-not-silent | none exists - proposed `whatsapp-deletions.lua` |
| voice deleted before the reply -> reply skipped | NOT-RUN | `outbox::tests::a_clean_quote_goes_out_and_no_deletion_refuses_a_send` (the fence, send half) | whatsapp-hold-not-silent | `whatsapp-copilot-reply.lua` + proposed `whatsapp-deletions.lua` |
| picture -> OCR | NOT-RUN | `ocr::tests::an_image_is_ocred_attached_and_found_by_its_text`, `view::tests::media_is_metadata_with_a_name_a_size_and_the_caption` | whatsapp-transcription-works | none exists - proposed `whatsapp-media.lua` |
| a 120 KB image from a peer in ONE call | NOT-RUN | the download path over a real queue (`whatsapp_query` tests); the 512 KiB bound is `seam::MAX_DOWNLOAD_BYTES` | run-images-two-node | none exists - proposed `whatsapp-media.lua`, `whatsapp-peer-call.lua` |
| a send from work arrives | NOT-RUN (role refusal, §3) | `whatsapp_send` tests (queue, dedupe, cancel) - the peer half is the row this table could not measure | this brief | `lua/core/canaries/whatsapp-send.lua`, proposed `whatsapp-peer-call.lua` |
| send-then-search (newest first, order stated) | NOT-RUN | `index::tests::a_message_this_node_sent_is_in_search_the_moment_its_record_is_written`, `index::tests::a_chat_scoped_search_answers_newest_first_and_says_so` | whatsapp-read-is-consistent | `whatsapp-index.lua` |
| empty-chat read freshness (as_of, last_received_s, connected, index state) | NOT-RUN | `index::tests::a_read_says_how_fresh_it_is_and_two_reads_in_a_row_never_go_backwards`; the transport half is the canary's `read_no_connected`/`read_no_receive_freshness` stages | whatsapp-read-is-consistent | `whatsapp-index.lua` |
| text + voice note, both in order, transcript inline | NOT-RUN | `index::tests::a_chat_whose_last_two_messages_are_a_text_and_a_voice_note_reads_both_with_the_transcript_inline` | whatsapp-transcription-works | `whatsapp-transcription.lua` |
| a read across chats labels every row with its chat | NOT-RUN | `index::tests::a_search_that_mixes_chats_labels_every_hit_with_its_chat_and_a_read_never_mixes_them` | whatsapp-read-is-consistent | `whatsapp-index.lua` |
| send-then-read (the sent message is in the next read) | NOT-RUN | `index::tests::a_message_this_node_sent_is_in_search_the_moment_its_record_is_written`; `outbox::tests::status_says_whether_the_sent_message_is_in_the_history` | whatsapp-read-is-consistent | `whatsapp-send.lua` |
| three reads never older than the one before (`as_of_regressed` when they are) | NOT-RUN | `index::tests::a_read_says_how_fresh_it_is_and_two_reads_in_a_row_never_go_backwards` | whatsapp-read-is-consistent | `whatsapp-index.lua` |
| a voice record's text in read AND search (not empty) | NOT-RUN | `index::tests::a_voice_note_is_found_by_its_transcript_and_keeps_its_duration`, `view::tests::a_voice_note_with_no_transcript_says_so_instead_of_an_empty_text` | whatsapp-transcription-works | `whatsapp-transcription.lua` |
| both id forms give the same messages (`resolved_form`, `addresses`) | NOT-RUN | `index::tests::one_chat_is_one_history_under_both_of_its_addresses`, `index::tests::alias_pairs_are_one_lid_and_one_phone_number` | whatsapp-read-is-consistent | `whatsapp-index.lua` |
| a long body is a pointer, never a silent cut (`transcript_full`) | NOT-RUN | `view::tests::a_long_message_is_a_pointer_to_its_stored_text`, `index::tests::a_cut_transcript_says_so_and_the_two_exact_ops_return_it_whole` | whatsapp-read-is-consistent | `whatsapp-index.lua` |

## 5. What was verified, what was not

Verified on this node against the rebased main (measured, not asserted):

1. The scratch fleet comes up: three `wa serve` nodes + a local rendezvous + a signed roster, /health within
   the timeout, node names `account`/`laptop`/`work` from their own directories (`lua/core/nodes.lua`
   `M.worktree`), all built from this branch's `wa` (`cargo build -p wa-host`, 51.6 s, on the rebased tip).
2. Every one of the ten `mcp_whatsapp_*` names answers through the real path from all three sites, with the
   bytes and shape in the table.
3. The write path: queue, dedupe, resume, cancel, the approval gate's list, and the three name refusals.
4. The landed read contract's four refusals by name (order, unknown order, no narrowing, malformed chat).
5. The own-chat guard refuses another target before the call, on every site.
6. The table prints no chat id, phone number, message id or message text: the driver prints a shape and an
   allow-list, redacted; the script re-checks every value and exits 4 rather than print a JID or a run of
   five digits (`scrub`). The run's own output was read line by line for that.
7. `scripts/test-whatsapp-acceptance.mjs`: 45 checks, green, wired into `scripts/fast.sh` as
   `whatsapp-acceptance`; it DISCRIMINATES - on a separate worktree of the base commit `e832e152` it exits 1
   with 31 of 33 checks failing (measured before this rebase; the checks only grew).

Not verified (and not claimed):

* Any answer that needs a paired device (all reads, all six flows, Fable's rows) - the reason is in every
  cell.
* The live mode has never run: it needs the operator's own chat on the account node. Its refusals (missing
  target, malformed target) ARE tested, and §10 is the command.
* The peer hop's admission end to end: admitted by the roster, refused by role (`server.lua:1034`).
* Which chat is the account's OWN chat is not readable from the node: no configured own-chat source exists
  (searched: `WASM_AGENT_*`, `config/`, `lua/core`). The live run takes `--own-chat` from the operator and
  can verify it only from the data: in a self-chat every message's `from.own` is true. The G run should
  treat a page with any `from.own:false` row as "not the own chat - stop".

## 6. One observation that is not a failing cell

`mcp_whatsapp_search` takes `order` in its request builder and the answer states its order
(`lua/core/whatsapp.lua`, `request = function(args) ... order = args.order`), but the tool's PARAMETERS do
not declare `order` - so a model reading the schema cannot know it may ask for `newest`. The call works
today only because `lua/core/tool_arguments.lua` is in STEP 1 ("a key the schema does not declare is
RECORDED, not refused"); when STEP 2 enforces, every `order` argument becomes a refusal. Owner:
whatsapp-read-is-consistent (one schema line), noted here rather than fixed - a tool-description change also
owes the prompt tool-name row and a canary.

## 7. Open question for Fable (not a fix in this branch)

The peer hop is admitted by the signed roster and then refused by role, because the mesh's attested caller
did not reach the handler: `lua/core/server.lua` `mesh_caller` returns the attested caller with
`role = "master"` (its own comment says so), and `verify_peer` fell through to
`nodeslib.verify_caller(..., {fresh = true})` (lines 1032-1034) - the rendezvous answer - which is a guest on
a scratch fleet. On the operator's fleet the rendezvous itself grants master to the listed ids, so a peer
call works there through the same line; the attestation path is the fallback that does not. Two things to
decide, both outside this brief: (a) is a fleet roster alone supposed to admit a peer when the rendezvous
grants no master? (b) if yes, `mesh_caller` needs a test that fails when it returns nil for an admitted
call - there is none today.

## 8. New or changed model- or operator-facing strings, verbatim (for approval)

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
11. `test-whatsapp-acceptance: ok (<n> checks: every surface verb is a row, live mode refuses a missing or
    malformed target, the own-chat guard runs before the call, the driver redacts, and a run in the node home
    refuses)`
12. The verdict sentences the table prints (all in the table above): "no paired device on this machine: the
    capability queued the question as job N and answered whatsapp_<op>_slow ...", "the hop was admitted by
    the signed roster (mesh decision=allow) and the account node refused the caller's role ...", "the order
    travelled: the seam queued the search (no device settles it here)", "refused by name with
    whatsapp_search_bad_order", "one job for the repeated message (lua/core/whatsapp.lua M.send; the dedupe
    key is the request)", "the queued job was taken out of the queue before any worker held it".

## 9. Commits

- `6955ef85` (rebased; formerly `ec984d89`) - the one script, the in-node driver, the guard test, and its
  fast-path row in `scripts/fast.sh`.
- `d5082ca1` - this report, the table and the per-cell mapping.
- `b6ea3b28` - the guard test's discrimination measured on a separate worktree of `e832e152`.
- `76fd4820` - the report naming the commits that built it.
- `da233b24` - the table re-run against the read contract (origin/main `4615449f`, the gate `d2fbd140`), the
  four contract cells, the twelve covered rows, the synthetic probe's one exception, and §10.
- the commit that carries this second rebase: the same table re-run on `18b83398` (same 18 pass / 48
  not-run / 0 fail, orphan-tests green with 361 wired), and this section.

The commit trailers name the model as `claude`: the session carries no exact model id, and inventing one
would be a false record.

## 10. Phase B: the exact command, and what Victor does by hand

Phase B runs on the account node (openclaw), against Victor's OWN chat only. It is the orchestrator's, with
Fable's OK:

```
cd <checkout> && node scripts/whatsapp-acceptance.mjs \
  --mode live --own-chat '<the account's own chat JID>' \
  --bin "$(command -v wa)" \
  --json /tmp/whatsapp-acceptance-G.json
```

Rules the script enforces at that moment, and that the run must be judged by:

* without `--own-chat` it exits 2 and prints nothing else; with a target that is not an exact chat JID
  (`<digits>@s.whatsapp.net`, `@lid`, `@g.us`) it exits 2 as well;
* every step whose chat is not that exact JID is refused by the driver with `refused_not_own_chat` before
  any call - and the `guard/other-chat` row must answer exactly that, or the run is red;
* the only exception is a validation probe on a shape no account can own (`1-2-3@g.us`), which the seam
  refuses by name before any queue write; its cell must stay `whatsapp_read_bad_chat`;
* the table prints no chat, no phone number, no message id, no message text - shapes, counts and bytes only.

**What Victor must do by hand, during that run**, because four rows need a live message to exist:

1. In the account's own chat ("Message yourself"), send a **voice note of at least 15 seconds**. With
   transcript posting on for the own chat, the first recognised segments go out as a reply within seconds
   and the same message is edited as more arrive - that is `flow/voice-reply` and `row/text-and-voice`.
2. Then send a **short text message** in the same chat, so the last two messages are a text and a voice note
   (the read row asks for exactly that pair, newest first, with the note's transcript inline).
3. Send **one picture** in the same chat, so `flow/picture-ocr` has an image to read.
4. Do not type anything in any other chat while the run is going: only the own chat is read or written.

If a row needs a deletion (`flow/deleted-after-index`, `flow/voice-deleted-before-reply`), that is a
destructive act on a real message: Victor decides it, one message, and the row is read from the index after
it - never from another person's chat.
