# The turn feed: the model's own complaints become the queue

Every answer this node produces ends with a `<turn>` block - what hurt the reasoning, what removing it
would buy, and the one harness optimisation the turn exposed (`lua/core/agent.lua`, the `turn` prompt
section). Every real fix this fleet landed began with one of them: an empty connector schema, a value
buried in an evidence envelope, `json_number_invalid` from a no-argument call, nameless tool calls, a
resumed turn re-deriving work that was already in flight. Until now they were found by a human reading
transcripts by chance.

`wa turns` is the reader. It parses the notes out of the ledger on this node and, over the mesh, on every
peer that answers; groups the ones that describe the same problem; ranks the groups by frequency x cost x
recency; and prints a brief per group: **problem**, **evidence**, **acceptance**.

```text
wa turns                            the top 10 clusters, all time
wa turns --since 24h                only notes written in the last day
wa turns --since 7d --top 25        a week, the whole list
wa turns --json --no-digest         the machine form, no file written
wa turns digest --since 24h         write today's digest and print its path
wa turns fixed <cluster> --sha <commit>   mark a cluster fixed by that commit
wa turns unfixed <cluster>                take the marker back
wa turns markers                          what is marked, and by which commit
```

## What a note is

The block, in the message that closes a turn:

```text
<turn>
**what hurt** — what in this turn damaged the reasoning, and what would have removed it
**what it buys** — fewer steps, or only better context, with a number
**focus** — exactly one harness optimisation
</turn>
```

The reader accepts every spelling the models here have used: `**what hurt** —`, `- **what hurt** -`,
`• what hurt —`, `**what hurt:**`, `1. **what hurt** —`. A `<turn>` block has to **open a line**: a
message that mentions the tag inside a sentence ("every answer ends with a `<turn>` note") is talking
about the section, not writing one, and one real message that did exactly that was collected as a note
that quoted itself.

A block with no labels is read as a note only when it is closed with `</turn>` - the shape the prompt
itself asks for when nothing hurt ("say so in one line and stop").

## What one record holds

| field | where it comes from |
| --- | --- |
| `node`, `session`, `message`, `seq`, `at` | the ledger row the note was found in |
| `model` | the turn's own trace (`context.model`), else the session's last `model_call` event |
| `hurt`, `buys`, `focus`, `quote` | the note, **redacted** (see below), capped at 1200 bytes |
| `measured.steps`, `.tool_calls`, `.tool_errors`, `.retries`, `.tokens` | the turn's span in `messages`: every row after the user's message up to and including the answer |
| `cost`, `delta` | `tool_errors + retries + floor(steps/10) + delta`; `delta` is the note's own "5 → 2" when it states one |

`cost` is measured, not estimated from prose: a failed tool call is a call the model had to pay for
again, and a provider retry is a whole model call. The one number the note contributes is the step delta
it states itself, whichever of its three parts says it.

## Grouping: deterministic, explainable, no model call

Each note is reduced to **named signals** - tool and capability names, snake-cased error codes, file
paths (weight 3) - and ordinary words (weight 1).

* A signal that appears in **three quarters** of the notes cannot name a group; it is the shape of the
  fleet's prose, not the shape of the problem (`scripts/fast.sh` and `bash` are in most notes here).
  The filter needs at least five notes before it applies, because in a handful "three quarters" is every
  pair.
* A bare file name that is the tail of exactly one full path in the run **is** that path: `fast.sh` and
  `scripts/fast.sh` are one signal, and a name that matches several paths is left alone.
* A note joins the cluster it is most similar to when they share a named signal and at least a fifth of
  their weight (Dice coefficient), or when half their weight agrees on words alone. Otherwise it starts
  its own.

So "why are these together?" has one answer, printed with the cluster: the signals it names. The
cluster's id is a short hash of those signals - **content-derived**, so the same problem seen on another
node or another month answers with the same id, which is what makes a `fixed` marker addressable.

## Ranking

`score = count × (1 + summed cost) × recency`, all three printed:

* `count` - how many notes describe the problem;
* `cost` - the sum of the notes' measured cost, so a cheap annoyance seen ten times does not outrank an
  expensive one seen five times;
* `recency` - `1 + 1/(1 + age_days/7)`: 2.0 for a note written today, approaching 1.0 as it ages. A
  problem nobody has hit in a month is not the top of today's queue.

A tie in score breaks towards the newer cluster, then by id, so two runs over the same ledger print the
same order.

## Closing the loop: fixed, still hurting, quiet

A marker is two facts: which cluster, and **the time of the commit that claims it** (`git show -s
--format=%ct`, resolved when the marker is written). The report then counts the cluster's notes newer
than that time:

```text
status: unfixed
status: still hurting: 2 note(s) after 4dd6ddee (1.4 days since the fix)
status: quiet since 4dd6ddee (6.0 days)
```

A node with no repository to ask records `at_source: marked_at` and says *"mark time: no repository
here"* rather than pretending the mark time is the commit's. Markers live on the node that wrote them
(`<config>/turns/fixed.json`), never in a repository, and are removed with `wa turns unfixed`.

## Privacy

Notes are the model's own words about the harness, but a model writes "the message said ..." and that
message may be somebody else's. Every record is redacted **at collection**, so no later surface - the
terminal, the digest, a peer's answer - can print what was stripped:

| rule | what it removes |
| --- | --- |
| `notice` | a `[Sentinel notice]` body |
| `bearer`, `key` | `Bearer <token>` and `sk-...` credentials |
| `email` | addresses, replaced by `<email>` |
| `phone` | 9+ digit numbers, replaced by `<phone>`; dates and clock times are protected first |
| `payload` | a field carrying a person's message (`From:`, `Subject:`, `jid:`, `body:`, `text:` ...) |
| `quoted` | any quotation of 24 characters or more, replaced by `<quoted>` |

The digest never contains a transcript, a message body or a third-party payload: it contains tool names,
error codes, file paths, counts, and the model's own sentences with the above removed. The same holds for
the peer capability - a peer answers its **own** notes, already redacted, and never a transcript.

## The peer half

`wa turns` asks every online peer for its notes through the mesh, with the capability `turns` (graded
`read`: the handler opens the ledger for `SELECT` and writes nothing). It is admitted for a managed node
and for a roster+grant decision, and it may travel inside a code-mode read set and a `calls` batch.

A peer that does not answer is **named** in the report (`peer <name>: not collected (<reason>)`) rather
than skipped: a fleet report that silently covers one node is a report about that node only.
`--no-peers` reports this node alone; `--nodes a,b` picks peers by name.

## The digest

Every report also writes today's digest to the node's reports directory
(`<config>/reports/turns-<YYYY-MM-DD>.md`), the same ranking as markdown for a reader who was not at the
terminal. `WA_TURNS_REPORTS` and `WA_TURNS_STATE` relocate the digest and the marker store (the suites use
them; an operator keeping a second range can too).

## What this is not

It does not decide anything. It ranks what the models reported and measures whether a cluster went quiet
after the commit that claims it; the fix, the mission and its acceptance are still a human's or a
session's call. `docs/HARNESS-EVALUATOR.md` is the sibling evidence: that one freezes a task and replays
it against a candidate binary, this one reads what the sessions already said about the harness.
