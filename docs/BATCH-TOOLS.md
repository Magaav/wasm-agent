# Batching: code mode is the batch

Operator decision (12/11): the `*_many` tools are **retired**. There is one way to do several
independent things in one step - a script - and one sentence for anyone who asks for the old names:

```
retired: batch in code mode - Promise.all(items.map(x => tools.<single>(x)))
```

## The mapping

| retired name | the single tool it batched | the form that replaced it |
| --- | --- | --- |
| `read_many` | `read` | `await Promise.all(items.map(x => tools.read(x)))` |
| `grep_many` | `grep` | `await Promise.all(items.map(x => tools.grep(x)))` |
| `session_many` | `session` | `await Promise.all(items.map(x => tools.session(x)))` |
| `search_messages_many` | `search_messages` | `await Promise.all(items.map(x => tools.search_messages(x)))` |
| `symbol_source_many` | `graph` (`action:"symbol_source"`) | `await Promise.all(items.map(x => tools.graph({...x, action:"symbol_source"})))` |
| `write_many` | `write` | `for (const f of items) await tools.write(f)` (effects stay serial) |
| `edit_many` | `edit` | `for (const f of items) await tools.edit(f)` (effects stay serial) |

## Why the script is enough

- **Same data.** Each `tools.<single>(x)` is the primitive's own call through the same dispatcher: the
  same schema contract, the same role/profile/workspace checks, the same result object, the same exact
  evidence references. `scripts/test-retire-many.lua` asserts value-for-value parity for every retired
  name, including per-item errors and request order.
- **Same guards.** A workspace binding, a guest ceiling or a managed-capability refusal reads the same
  inside the loop as outside it, because both reach `M.dispatch`. A refused item arrives as a rejection:
  catch it (`p.then(r => r, e => ...)`) and the batch keeps its per-item outcomes.
- **Reads in parallel, effects one at a time.** `Promise.all` over reads is genuinely concurrent; the
  dispatcher admits effectful calls serially, which is what the mutating batches did one item at a time.
- **No 1-8 ceiling.** The bound was a property of a request array. A loop is bounded by the script's own
  clock (`timeout_ms`, default 30 s, max 300 s), and work that outlives a turn is a pending handle
  (`wait_s:0` then `wait(op)` - see [CODEMODE.md](CODEMODE.md), "Pending calls").
- **One contract instead of two.** The batch schemas were derived from the primitives' properties and
  still needed their own bounds, preflight, presentation and prose. That second contract is what the
  retirement removes; nothing about the capability is lost.

## What the retirement did not change

- `tool_call` with `calls:[...]` (1-8 known independent **reads** in one call, serially) is the outer
  facade's batch and stays. It is the paging surface in
  [CODEMODE-PRESENTATION.md](CODEMODE-PRESENTATION.md): a reply that exceeds the view budget keeps every
  item's outcome visible and returns `next_cursor`.
- `lua/core/read_batch.lua` stays, as the pager behind that `tool_call` batch.
- The peer protocol keeps its read set (`read`, `ls`, `grep`, `sessions`, `session`,
  `search_messages`, `recall`, read-only `bash`), and `remote` with `capability:"batch"` runs up to eight
  peer reads in one signed round trip. A retired batch name sent to a peer is answered with the one
  sentence, from the same dispatcher.

## Rules kept from the batch contract

- **A per-item outcome stays visible.** In a script, catch the rejection; a bare `await` inside
  `Promise.all` fails fast on the first refusal, which is a *stronger* default (no half-applied batch
  presented as a whole one).
- **Effects are never replayed.** A failed script is read, not rerun. `results.get`/`results.last` re-read
  what a call answered without re-running it.
- **No multi-file transaction is implied.** A serial loop of `write`/`edit` applies each call on its own;
  a late failure leaves the earlier applications recorded in the changeset, exactly as the mutating batch
  did.
- **Aggregate output can cost retrieval.** A large directory listing, history page or search result is
  bounded by the view budget; the original stays hash-addressed and is read back with `tool_result`.

## History

`docs/BATCH-TOOLS.md` used to describe six operator batch tools (and `read_many`'s paged cursor). The
measurements and journals that mention them (`docs/measurements/`, `docs/*-JOURNAL.md`) are dated
records of that design and are not edited; the live surfaces - the catalogue, the prompt, discovery,
skills and this doc - offer the script form only.
