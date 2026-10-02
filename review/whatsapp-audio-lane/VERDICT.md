# Independent review: `change/whatsapp-audio-lane`

Reviewer: `child:dispatch:c4f1ab4b-2537-42c4-bbba-a98f5c6b7c69` (INDEPENDENT - the producer was
`child:dispatch:0af707dc-4791-40b7-9484-32e0fb17c052`).
Delivery: branch `change/whatsapp-audio-lane`, tip `484061ea69562d6e9e9a1b0c73da1dee174d1da1`, tree
`593c1ba934ac13f28ff178c0fda9dd5e63f47131`, 1 commit ahead of `origin/main` `5b1ffdc`. Not pushed.
Review worktree: `C:/Users/Victor/.wasm-agent/wa-worktree-childdispatchc4f1ab4b-2537-42c4-bbba-a98f5c6b7c69`
(branch `review/whatsapp-audio-lane`, based on the tip).
Store inspected with the `whatsapp-module-inspection` skill: read-only CDP against the existing
authorized page, no reload, no chat opened, nothing sent, nothing marked read.

**Verdict: `passed`.** Every claim the commit makes is reproduced on the tip's own files, and each new
test fails when its behaviour is removed. Findings recorded below are real but none blocks landing.

Model note: this node refuses `gpt-6-luna` (`model_not_servable`), so this review ran on
`deepseek-v4.1-flash`/high - the same family as the producer. Independence here is the lane and the
evidence, not the model; the producer's report was treated as a claim to attack, not as verification.

## What was run (exact commands, verbatim results)

Live CDP: Chrome 154, page `https://web.whatsapp.com/` target `2310333E0984BB911E02CE90D9C168F4`, port 9222.

### 1. The download on all three ids - reproduced, byte counts match

Run from the review worktree with the tip's `scripts/whatsapp-audio.mjs`:

```
node scripts/whatsapp-audio.mjs --message-id false_112682812330026@lid_ACF41B7C289898821ABBD8921D0313B4 --chat 112682812330026@lid --out <tmp>/a.ogg
{"ok":true,"bytes":50433,"mime":"audio/ogg; codecs=opus","sha256":"1e7e3a9befd376a2f62b9aa0813d60f341081cf1953d5e937715995acf9268d3"}
node ... --message-id false_104234712326257@lid_3A1A46A2BAE4873061B7 --chat 104234712326257@lid ...
{"ok":true,"bytes":74845,"mime":"audio/ogg; codecs=opus","sha256":"81353be4b124962518ee752e204f6d2f3c9198c692b303df2711c787b0c08c9b"}
node ... --message-id false_104234712326257@lid_3A219A85E73725F93A9D --chat 104234712326257@lid ...
{"ok":true,"bytes":180918,"mime":"audio/ogg; codecs=opus","sha256":"1ad4d7e6e2f0a69e7214af54c87e183d24c49635466444ec954090b98cdb9df9"}
```

Claimed `50433/74845/180918` - **exact match on all three**, and `ls -l` confirmed real files of those
sizes. The three sha256 values are new evidence the producer did not publish.

### 2. The pre-fix failure and the mechanism, measured on the live build

`origin/main`'s adapter, run unchanged against the same page (a whole tree extracted with
`git archive origin/main`):

```
node <main-tree>/scripts/whatsapp-audio.mjs --message-id false_112682812330026@lid_ACF41B7C289898821ABBD8921D0313B4 ...
{"ok":false,"error":"audio_browser_exception:Uncaught (in promise)"}
node <main-tree>/scripts/whatsapp-audio.mjs --message-id false_104234712326257@lid_3A219A85E73725F93A9D ...
{"ok":false,"error":"audio_browser_exception:Uncaught (in promise)"}
```

So the claim "the same command failed with the wrapper text before the fix" is **confirmed on two ids**.

The raw CDP frame for that failure (`review/whatsapp-audio-lane/probe.mjs`, read-only):

```
"exceptionDetails": {
 "text": "Uncaught (in promise)",
 "exception_className": "t",              <- minified, as the commit says
 "exception_description": "t",
 "preview_properties": [
  {"name":"message","value":"Unexpected mimetype application/octet-stream for media type ptt"},
  {"name":"name","value":"InvalidMediaFileType"},
  {"name":"mediaType","value":"ptt"},
  {"name":"mimeType","value":"application/octet-stream"}   <- the build's default when mimetype is omitted
 ]}
TIP browserExceptionReason(frame) => "InvalidMediaFileType: Unexpected mimetype application/octet-stream for media type ptt"
LIVE MESSAGE FIELDS: {"type":"ptt","mimetype":"audio/ogg; codecs=opus","mediaData_mimetype":"audio/ogg; codecs=opus","mediaStage":"RESOLVED","size":50433}
MIMETYPE COVERAGE (counts only): {"audio_messages":48,"audio_without_mimetype":0}
```

This proves the commit's mechanism verbatim: the declared mimetype exists on the live message, the build
defaults to `application/octet-stream`, the rejection is a typed `InvalidMediaFileType` whose class name is
minified and whose reason is only in the preview - and the tip's `browserExceptionReason` reads exactly that
reason off exactly that frame.

### 3. Falsification attempts on the refusals

Live, through the tip's adapter:

```
--message-id false_999999999999999@lid_DEADBEEF            -> {"ok":false,"error":"message_not_in_store"}
--message-id false_112682812330026@lid_0000...0000         -> {"ok":false,"error":"message_not_in_store"}
(no --message-id)                                          -> {"ok":false,"error":"message_id_chat_out_required"}
```

Hermetic (`review/whatsapp-audio-lane/falsify.mjs`, the tip's own expression under a stub page):

```
absent mediaData (benign byte copy): {"error":"media_unavailable"}
absent mediaData, download rejects:  {"error":"media_unavailable"}
rejection is a bare string:          {"error":"audio_download_failed","name":"Error","message":"the build refused"}
rejection is a non-Error object:     {"error":"audio_download_failed","name":"Error","message":"[object Object]"}
typed rejection:                     {"error":"audio_download_failed","name":"InvalidMediaFileType","message":"refused"}
no mimetype at all:                  {"error":"audio_mimetype_missing"}
view-once:                           {"error":"view_once_refused"}
oversized:                           {"error":"audio_too_large"}
not audio:                           {"error":"not_audio"}
browserExceptionReason(no reason at all): "Uncaught (in promise)"
browserExceptionReason({}):               "unknown"
```

**Could not falsify "every refusal is typed and named"**: no path I could construct returns the CDP wrapper
for an app rejection, because the whole expression is inside one `try`/`catch`, so the wrapper frame is
unreachable for this expression. Two honest limits:
* a rejection that is **not** an `Error` degrades to `name:"Error", message:"[object Object]"` - typed, but
  naming nothing. Not reachable with the app's own error classes on this build.
* `browserExceptionReason` still falls back to the wrapper text when a frame has no readable reason - the
  fix's claim is that the reason is *preferred*, and that holds.

### 4. The silent-loss rule

The delivery's own test, then six independent one-thing-reverted mutations on a clean clone
(`git archive HEAD` + `review/whatsapp-audio-lane/mutate.cjs`):

```
node scripts/test-whatsapp-audio-loss.cjs     -> whatsapp audio loss ok (25 checks, 0 failed, 0 skipped ...)
M3 clamp-removed   (drop the cursor clamp)    -> exit=1 AssertionError: the cursor did not advance past the note it could not download (cursor 1790968343 vs note 1790968343)
M4 sweep-silent    (drop the ok flip)         -> exit=1 AssertionError: a pass that lost a queued note does not report ok: {"cursor":1790968354,"ok":true,"pending":0,"processed":0,"refused":[{"attempts":1,"error":"audio_browser_exception:InvalidMedia...   (my grep truncated the line at 210 chars; the mutation restores ok:true over a refused note)
M7 requeue-replace (re-create the pending row)-> exit=1 AssertionError: cached parts resume without running STT again: {"error":"local_stt_failed",...,"state":"retryable","step":"transcribe"}
```

and the same test against `origin/main`'s Lua:

```
AssertionError: the cursor did not advance past the note it could not download (cursor 1790968459 vs note 1790968459)
```

The test therefore cannot pass on the code the commit replaced, and each of the three Lua behaviours is
individually pinned.

My own independent fixture (`review/whatsapp-audio-lane/adversarial-loss.cjs`, different shape, **28 checks,
0 failed**) constructs the loss itself:

* **S1** a note fails to download, then *fresher traffic* arrives in the same window: the cursor still holds
  (`cursor < now-200`), the refusal is `step=download`, `state=retryable`, `message_id=loud1`,
  `error` contains `InvalidMediaFileType`, and the next pass settles the very same note.
* **S2** the window moves under the queued note: the pass reports `ok=false` with the id, the step and the
  underlying error, the `refused[]` entry carries `reason=stale_audio` + `step` + `error` + `attempts`, the
  durable `transcription_refused` row exists, and **the exact old shape
  `{ok:true,pending:0,refused:[]}` is unreachable**.
* **S3** two failing notes settle exactly once each; two notes, two `transcribed_sent` decisions, two sends -
  the clamp does not cause a replay. (I could not construct a re-exposure of an already-settled note at all:
  the scan requires `at > cursor` and the clamp keeps the cursor below every pending note, so the invariant
  holds.)
* **S4 (observation, not a blocker)** if the source read fails in the same pass as the sweep, the step result
  carries `step=read` and *not* the swept note's step/error; the loss survives as the durable refusal only.
  The pass still fails loudly, so no note is lost silently.

Running the same fixture against `origin/main` fails at the first cursor assertion
(`S1 cursor did NOT advance past the failing note: cursor=... note=...`) - the pre-fix skip is real.

### 5. Preflight / source-ensure / trigger

```
node scripts/test-whatsapp-hook-rebind.cjs <canonical wa-sentinel.exe>
-> whatsapp hook rebind ok (24 checks, 0 failed, 0 skipped; fake DevTools endpoint, real adapter/trigger/preflight, real sentinel CLI)

M5 fast-path-exit (restore the exit on "DevTools answered")
-> exit=1 AssertionError: and says the verdict came from the preflight, not from "DevTools answered": {"ok":true,"action":"already-up","reason":"cdp_answering",...}
M6 no-repair (delete the preflight's repair block)
-> exit=1 AssertionError: the preflight repaired it rather than reporting it: whatsapp preflight ok ... | whatsapp preflight trigger id=whatsapp-even...
```

0 skipped because I passed the sentinel explicitly; `scripts/test.sh` builds it at line 233 and calls this
test at line 1867, so the re-pin section also runs in the real gate.

The pinned-vs-live comparison, read live and read-only (no repair was run against the live node):

```
node scripts/whatsapp-trigger.mjs status --line
trigger id=whatsapp-events enabled=true status=listening_to_explicit_CDP_binding
  pin=ws://localhost:9222/devtools/page/2310333E0984BB911E02CE90D9C168F4 live_target=2310333E0984BB911E02CE90D9C168F4 drift=no
```

A **correct pin yields `drift=no`**, so the preflight's `case "$trigger_line" in *"drift=yes"*|*"pin=none"*)`
does not fire and writes nothing - the re-pin does not fight a live, correct pin. The hermetic test also
asserts the second repair is `{"action":"none",...}`. `repairPlan` itself, exercised directly:

```
no job at all               {"action":"install","pinnedId":"","liveId":"LIVE"}
pin on the live target      {"action":"none","pinnedId":"LIVE","liveId":"LIVE"}
pin on a dead target        {"action":"re-pin","pinnedId":"DEAD","liveId":"LIVE"}
pin on a browser-level url  {"action":"install","pinnedId":"","liveId":"LIVE"}
pin with no url             {"action":"install","pinnedId":"","liveId":"LIVE"}
```

### 6. `scripts/test.sh`

```
git show origin/main:scripts/test.sh | grep -c gate_run  -> 63
grep -c gate_run scripts/test.sh                         -> 65
comm -23 <(old gate_run lines) <(new gate_run lines)      -> (empty: nothing removed)
comm -13 ...                                              -> test-whatsapp-audio-loss.cjs, test-whatsapp-hook-rebind.cjs
```

No check removed, no suite dropped; the two new files are added as `gate_run` lines with the same
`"$BIN" "$PLUGINS/whatsapp-transcript.wasm"` shape as their neighbours. I did **not** run the full gate
(it belongs to the release). The new loss test's arguments are the same as the transcribe test's, and the
plugin is staged immediately above it, so it runs under the gate's own fixtures.

## Findings recorded in the delivery record (none blocks landing)

1. `review-fidelity` / unresolved: `status --line` computes `drift = pinnedId && pinnedId !== target.id`, so
   a pin that names no page target at all (e.g. a `/devtools/browser/...` url) prints `pin=<url> drift=no`
   and the preflight leaves it alone, while `repairPlan` calls the same pin `install`. The two notions of
   drift are not the same function. Narrow, and outside the commit's stated claim ("a pin that names a dead
   target"), but it is the one shape where the prevention does not fire.
2. `report-fidelity` / unresolved: when the source read fails in the same pass as the stale sweep, the step
   result carries `step=read` and drops the swept note's step/error (durable refusal still recorded).
   Evidence: my fixture's S4.
3. `test-coverage` / unresolved: `test-whatsapp-hook-rebind.cjs` does not assert the preflight's
   `trigger-repair` line for the *failed* repair (it asserts only the direct `repair` verb's exit 6), so a
   preflight that silently swallowed the repair failure would still pass the test.
4. `typing-edge` / unresolved: a rejection that is not an `Error` reports `name:"Error",
   message:"[object Object]"` - typed but uninformative. Not reachable with this build's error classes.
5. `comment` / unresolved: in `scripts/test.sh` the added block replaced the *first* line of the deploy
   test's comment, leaving a dangling fragment ("# be installed beside it, ..."). Cosmetic; no check moved.
6. `unproven-live` / unresolved: the `audio_mimetype_missing` refusal is unreachable on this build (48 audio
   messages, 0 without a mimetype), so it is proven only hermetically, in the delivery's own vm test and in
   my `falsify.mjs`. Stated as a limit, not a defect.

## Proved vs unproven

Proved on the tip's own tree: the three downloads and byte counts; the mimetype omission as the cause (live
frame + pre-fix failure on two ids); the typed reason recovered from the preview; the cursor clamp holding a
failed note across fresher traffic; the aged-out refusal carrying id+step+error; the absence of the old
`{ok:true,pending:0,refused:[]}` shape; step 1 now asking the preflight; the preflight re-pinning a dead pin;
`test.sh` additivity; and that each of the four test files fails when its behaviour is removed (6 mutations
+ the pre-fix tree).

Unproven: the `audio_mimetype_missing` refusal against the live build (unreachable there by construction);
the full `scripts/test.sh` gate (deliberately not run - it belongs to the release); and any behaviour of a
WhatsApp build other than the one inspected (Chrome 154 session, target `2310333E...`).

Not done, by instruction: no send to any chat, no message dispatched, no chat opened, nothing marked read,
no push, no deploy, no restart of the window, no edit to the canonical tree, no full-gate run.
