# Opt-in structured native presentation

`await showCall({version:1,call:N})` selects the Nth **admitted native tool call**
from this script for native structured presentation. It does not execute any tool,
read a live source, infer effects, retry a script, or enlarge authority. Discovery
and helper calls are attempts but do not increment N. Selection is idempotent.
Only version1 and those two keys are accepted. `describeTool('showCall')` is
on-demand help; the tool declarations/automatic guidance do not gain a catalogue.
See `skills/codemode-output/SKILL.md` for workflow and [CODEMODE.md](CODEMODE.md)
for VM/pinning/scope limits; [BATCH-TOOLS.md](BATCH-TOOLS.md) owns cached read paging.

```js
await tools.read_many({requests:[
  {path:'docs/A.md',offset:1,limit:120},
  {path:'docs/B.md',offset:1,limit:120}
]});
await showCall({version:1,call:1});
```

Instead of `text(await tools.read_many(...))`, the selected result appears as
`shown[i].result`, native JSON once, without the guest text item's extra JSON
string escaping. All original fields and JSON object/array/null shapes survive;
source content, paths, versions, selections and inclusive edit frames are not
shortened. `calls`, `attempts` and exact argument/result evidence stay distinguishable.
Raw/default behavior is unchanged when no call is selected. Other receipt-producing
calls can be selected too. A rejected tool normally throws in Pi; catch explicitly
if you need to select that admitted failure, without retrying it:

```js
try { await tools.read({path:'missing-file'}); } catch (_) {}
await showCall({version:1,call:1});
```

`ok` still describes script completion, **not** successful native effects or full
review. Always inspect individual call outcomes and source EOF/continuations.
Failures after a selection retain earlier output/receipts; nothing auto-replays.

## Encoded budget and incomplete awareness

The helper measures `#json.encode(final_native_result)` including the outer call
journal, paths, UTF-8 and escaping, against the unchanged tool-output budget
(default50KiB). The supervisor's8MiB ceiling and all VM/asset limits are unchanged.
The helper does not set a smaller read default, alter primitive schemas or create
a read cache. Original native result bytes are the existing hash-addressed evidence.

When everything fits, `shown[i].complete=true` means the *captured native result*
is entirely visible, not that every document/page was read. For a `read_many`
page, `next_cursor` still means later cached results remain unread. Follow it with
ordinary `read_many({cursor:...})` across scripts/process restarts without refetch.
Normal source byte/line continuations remain version-bound and separate.

If the encoded envelope would exceed the budget, `presentation_partial=true`
labels incomplete awareness. Native read batches pack whole items into `results`,
preserve exact top-level page `metadata` (including cached continuation and late
notes), and give every captured slot `coverage`: original index, visible flag,
error/effect/outcome/path fields where present, and an exact unread SHA-256/offset/
byte count. No partial source text or clipped receipt is offered as editable data.
Retrieve unread ranges with ordinary `tool_result`, following its `next_offset`
until that range is covered; later cached batch pages still use `read_many` cursor.
This high-boundary fallback can require extra artifact retrievals; it does not
claim arbitrary metadata always fits or replace the existing cursor mechanism.
If the journal/metadata itself cannot fit, the whole exact result is referenced
and labelled PARTIAL, including unread outcomes/effects. Never rerun effects to
recover output. Missing/corrupt evidence refuses visibly, not empty success.

This is a knob with awareness risk, not a universal token/speed/quality gain. The
private escaped-document fixture compares actual encoded model-facing bytes and
complete source/receipt coverage; it is not a paid model benchmark. Smaller bytes
alone do not justify dropping fields or making this the raw/default presentation.

## Formatter/stale reads

Use a fresh ordinary/native `read` of current source after formatting, inspect it,
then construct a new exact `edit` with the fresh selection/frame or unique exact
old_text. The prior receipt correctly refuses stale input with no writes. There
is no nearest-anchor rewrite, guessed whitespace repair, formatter-command parser,
mutating retry, rollback, or failed-script replay. A successful prior write followed
by refusal/unknown remains partial/unknown according to its original journal.

## Focused deterministic proof

```
node scripts/test-codemode-presentation.mjs <absolute-built-wa> <fresh-evidence>
node scripts/test-codemode-presentation.mjs --post <absolute-built-wa> <same-evidence>
```

The collector retains private source/standalone embedded seed/restart logs,
original artifacts/SQLite, tested source hashes and binary hash with Node absent
from child PATH. It tests encoded aggregate escaping/UTF-8, cached continuation
without live refetch, last-document caveat, exact receipt/typed equality, bounded
partial coverage and original recovery, stale formatter refusal/fresh edit,
partial-success/later refusal or unknown with no replay. Existing native and
read-batch tests remain necessary for authority/cache integrity fences. Failed
generations are retained, not overwritten. No live account data, service restart,
installation, full release gate or quality/billing claim is part of this proof.
