# Harness feedback register

Scope: collected reports, not a claim that every report is a genuine defect. Deduplication is by symptom/call site. `E<n>` below addresses the portable original-report excerpt in [harness-report-index.json](harness-report-index.json), keyed by E identifier under groups.entries with original reporter session and date. Excerpts are exact relevant fragments, not complete transcripts. Original raw artifact SHA256 `815276481d69b285ca0cc6413613fc06248d827f03b8b5dc081605ca2bf089d6` is provenance only; no local file is required. These are **report evidence**, not independently confirmed tool-call evidence unless stated. No extractor count is a defect count. `harness-feedback-all.json` is a second rough extraction, not an independent observation.

Status U = unverified report/hypothesis; I = intentional contract; F = fixture/caller mistake; B = baseline mechanism exists but deployment not established; P = focused patch verified. Out-of-scope entries are retained, not silently fixed. The check column states a falsifiable follow-up, not a passed test. Metrics are targets, not invented measurements.

| Symptom/call site | Evidence (original session in addressed artifact) | Status; subsystem/path | Falsifiable check; metric |
|---|---|---|---|
| unpublished delivery refresh | E1 | U; scripts/delivery-record.mjs | refresh local producer tip without remote branch; stale records zero |
| fake HTTP server blocks itself | E2 | F; fixture spawnSync | asynchronous child completes callback; timeout seconds decrease |
| long Bash command tail disappears | E3,27 | P; operations.rs | native probe below + refusal regression; silently shortened successful commands zero |
| scratch write denied | E3,8,43,49,66 | I/P; tools.lua/workspaces.lua | own write/edit accepted, traversal/other session/junction denied; staging heredocs decrease |
| Bash ignores allocated cwd | E4 | U; external harness vs tools.lua | observe effective cwd in bound session; source-tree cwd count zero |
| viewport/probe premature verdict | E5,7 | U; UI observation lane | await terminal probe at pinned CSS viewport; missing/running verdicts zero |
| atomic edit discards valid siblings | E6,9,92 | I; edit.lua | miss leaves file unchanged; retries per typo, retain atomicity |
| edit near-miss hint unrelated | E10 | U; edit.lua | quoted near-miss selects actual region; retries 2 to1 |
| BMP screenshot unreadable | E11,87 | U; wa-window screenshot | read screenshot directly; conversion calls zero |
| retired WhatsApp send route | E12,23,24,25,46,55 | U; app action route | approved send reaches verified receipt; blocked-send rate zero |
| installed UI fixtures stale | E13 | U; test-ui.ps1 | mismatched fixture hash refuses before test; hash-hunt calls zero |
| help query writes sentinel request | E14,116 | U; sentinel CLI | request --help leaves mailbox unchanged; writes per help zero |
| rg glob argument invalid on Windows | E15 | F; shell quoting | directory plus -g glob works; failed invocations zero |
| task context without prompt rejected | E16 | U; subagent schema | required prompt discoverable; duplicate brief calls zero |
| steering fences reads/effects | E17,18 | I/U; agent.lua (other lane) | measure superseded calls after steering; lost rounds decrease without stale effects |
| steer/message key undocumented | E19,21,31,45 | U; subagent schema | first follow-up with schema succeeds; refused retries zero |
| failed allocation/recovery disables session | E20,39,40 | B/U; workspaces.lua | status names recovery and failed binding stays fail-closed; recovery rounds decrease |
| false background-descendant refusal | E22,26 | B/U; operations.rs | shell exit/descendant state distinguished; spurious reruns zero |
| tail pipeline hides progress | E28,29,52 | F/U; shell buffering | direct durable output cursor shows progress; blind-wait minutes decrease |
| queued steering reported rejected | E30,38 | U; subagents | queued correction receipt matches eventual delivery; duplicate corrections zero |
| installed finish runner misses lane script | E32,33 | U; finish.mjs (other lane) | installed runner obtains slot; unavailable mode zero |
| Bash escaping changes bytes | E34,35 | U; shell payload | exact slash-heavy write/read comparison; failed escaping cycles zero |
| cancellation does not settle tree | E36,37,48,51,65 | U; operation supervisor | cancel then collect settled process tree; cancel-to-gone <=5s target |
| provider error loses reason | E41 | U; provider adapter (other lane) | retain actual error type/message; diagnosis rounds decrease |
| nested gate lane deadlock | E42,44 | F/B; finish/gate lane (other lane) | inherited admission no nested waiter; verdict latency bounded |
| detached process fixture premise | E47 | F; process fixture | distinguish contained and detached launch; probe scripts decrease |
| grep substitutes matched literal | E50 | U; host.grep | output line byte-equals source; literal substitution diffs zero |
| operation capacity blocks read-only shell | E51,53 | I/U; operation capacity | refusal identifies holders without arbitrary shell exemption; retries decrease |
| CRLF anchor mismatch | E54,90,100,108 | I/U; edit/read | exact bytes or range receipt preserve endings; failed edit rounds zero |
| POSIX path passed to native CLI | E56 | F; Windows arguments | native path without global conversion switch; bad-repo refusals zero |
| sentinel separate workspace omitted | E58 | U; contributor docs | documented manifest executes package; failed invocation rounds zero |
| approved model not servable | E59,71 | U; admission/catalog | reject before queued row; queued-then-failed launches zero |
| status repeats prompt/reasoning | E60 | U; subagent status | optional bounded view retains original pointers; bytes per status decrease |
| file URL lacks injected bridge | E61 | U; wa-window docs | loopback HTTP probe has bridge/heartbeat; diagnosis minutes decrease |
| explicit await returns at10s | E62 | B/U; operation await | started operation awaits settlement; polling calls to1 |
| postcommit graph sees empty diff | E63,64 | I/U; graph impact | explicit revision range or named empty-patch state; vacuous reviews zero |
| embedded Lua mistaken for source | E67,106 | B; host module loading | source-root run differs, unset warns; stale-module diagnosis rounds zero |
| remote deleted cwd | E68 | B/U; spawn fallback | missing cwd produces named fallback; failed spawn calls zero |
| child usage missing | E69 | U; subagent receipt | totals agree with durable message usage; reconstruction calls zero |
| preserved-tree execution refused | E70 | I; workspace binding | transfer fixture to own tree without changing original; unauthorized cwd acceptance zero |
| oversized session/search results | E72,103,104,107 | B/U; transcript tools | bounded view with exact original retrieval; bytes decrease with no lost evidence |
| node-only spell client claim | E73 | U; spells/resources | node-only spell has no client requirement; claim refusals zero |
| skip reasons far from verdict | E74 | U; gate lane (other lane) | verdict includes named skips; attribution greps zero |
| spell post JSON contract obscure | E75 | U; spells schema | valid JSON field expectations first attempt; failed saves zero |
| resource history inaccessible | E76,78 | U; resources | history exposes original recovery evidence; direct DB reads zero |
| pending upgrade candidate changes | E77 | U; sentinel install | hash at request and compare before install; untested candidate installs zero |
| client timeout retains claim | E79 | U; client/resources | prove settlement before release; subsequent unjustified busy calls zero |
| noisy history search | E80,112 | U; search_messages | targeted feedback query with source pointers; search calls decrease |
| browser redirect not verified | E81 | B/U; browser open | final URL/content checked; unnecessary retries decrease |
| gate pass yet descendants alive | E83 | B; operation command boundary | command verdict distinguished from settlement; unnecessary waits decrease |
| range edits wrong slice/drop lines | E84,85,86,89 | I/B; edit receipts | exact anchor/echo identifies actual replaced bytes; repair rounds decrease |
| gate inherits in-turn marker | E88 | F/B; test.sh | hermetic fixture strips marker only for subject; false reds zero |
| health lacks in-flight request | E91 | U; serve health | oldest path/age visible; attribution calls3 to1 |
| early-exit head leaves adopted grep | E93,94 | F/U; shell pipeline | rg bounded match count avoids pipe; adopted search receipts zero |
| deadline message fabricated cause | E95,96,97 | B; operations.rs | deadline_note_tests assert measured phases, no cause; misdiagnosis rounds zero |
| install unknown commit fails hash proof | E98 | I/U; verify-install | distinguish unverified source from verified hash; false claims zero |
| node-instance flaky check | E99 | U; node fixture | repeated deterministic fixture, retain failures; reruns per verdict decrease |
| injected UI script syntax silent | E101 | U; UI lane | parse before browser; syntax diagnosis rounds zero |
| module embed list omission late | E105 | U; build embed manifest | preflight disk/embed membership; wasted gate runs zero |
| gate implies unmeasured UI health | E109 | U; UI/gate lane | verdict names actual suite/skips; misleading UI passes zero |
| duplicate deploy cannot cancel safely | E110 | U; sentinel mailbox | explicit cancellation/idempotent receipt; redundant rebuilds zero |
| main guard remedy obscure | E111 | I/B; precommit docs | refusal names sanctioned merge path; integrator retries decrease |
| excessive whole-file read | E113 | F; caller navigation | bounded grep/read same evidence; returned bytes decrease |
| deploy root invisible | E114 | U; sentinel provenance | request/log name actual source root; trees investigated decrease |
| graph definition-less gaps noisy | E115 | U; graph audit | distinguish no callable coverage from failure; rereview rounds decrease |
| hidden browser timing artifact | E117 | F; observation fixture | assert visibility before timing; false timing defects zero |
| overloaded envelope term | E118 | F; navigation/docs | targeted cached_tokens query; search rounds decrease |
| job history lacks timestamps | E119 | U; sentinel job CLI | expose stored timestamps; diagnosis calls2 to1 |

Excluded as non-complaints: E57 (explicit no friction), E82/E102 (template text). Repeated reports retain every evidence address in their dedup row. All E1–E119 are accounted for; this does not certify every underlying allegation.

## Direct mechanism evidence in recovery session

Native probe `scripts/reproduce-bash-command-limit.cjs` produced private artifact `C:/Users/Victor/AppData/Local/Temp/wa-command-limit-2YRRcN/results.json`. 7900 bytes direct `-c`: exit0, stdout `REACHED\n`, stderr empty. 8200/8300/10000 bytes: exit0, stdout/stderr empty, sentinel absent. File launch of the exact same bytes: exit0, sentinel present. This is command transport loss, not captured output clipping. Threshold depends on wrapper/program quoting; original draft's claimed8200 success is not generalized.

Recovery preserves draft intent from child9306399f at dc271bb plus dirty files (original seq149–150 inspected). Rather than persist possibly credential-bearing command text automatically or change `$0`, the patch uses named preflight refusal before launch; the exact script can be staged with write and executed explicitly. Source Lua regression derives the original draft sentinel/script-byte/short-command/stderr checks and collects descendant settlement. Scratch IDs use injective hex encoding instead of draft punctuation stripping; nearest-existing-ancestor canonical checks fail closed on junctions. This is coordination, not an OS sandbox or TOCTOU-proof authorization against hostile concurrent filesystem mutation.
