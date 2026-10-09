---
name: history-search
description: Retrieve original past requests, decisions, corrections or execution evidence efficiently. Use when recalling previous conversations or investigating historical failures.
---

# Original history, on demand

For personal facts call `recall` first. For dialogue use `search_messages` with
short distinctive terms; defaults are dialogue snippets grouped across sessions.
Use `roles:["user"]` to find an original request, `sort:"newest"` for chronology,
and `match:"phrase"` only for an exact phrase. Filters are explicit; never guess
that a failed/no-match search proves an event did not happen.

For a failed run, use `session {session_id,message_id,view:"full"}` directly when
its row is known; otherwise newest `view:"full",limit:1` or a small range around
the failure. Do not begin failure diagnosis with compact discovery. Oversized
rows expose a last-failed-span excerpt; follow the exact row reference for the
full error/trace. An excerpt is not full execution evidence.

For commands/results use `scope:"evidence"`, optionally `tool_name`. `scope:"all"`
also exposes retrieval echoes, summaries and automatic notices. Echoes are copies,
not independent confirmation. `group_by:"message"` removes the two-hits-per-session
presentation cap when investigating a particular thread.

Read the exact hit and context using `session {session_id,around_seq:seq}`. Batch
selected originals with `message_ids` within one authorized session. Follow exact
row/artifact references for large output. Excerpts are original text, not the whole
history and not settlement proof. Follow `next_offset` for more hits; live ranks
can move after appended or replicated corrections. No automatic memory injection.

Contract: [../../docs/HISTORY-SEARCH.md](../../docs/HISTORY-SEARCH.md).

## Verify a retrieval change

Run `node <repo>/scripts/test-history-search.cjs <absolute-built-wa>
<fresh-absolute-evidence-dir>`, then the same CLI with `--post` before its arguments.
Keep failures, source/log/binary hashes, known-source recall and measured latency
alongside bytes; this is not a paid-model quality or release certificate.
The recorded `history-search-focused-check` spell parameterizes these consecutive
steps (`runner_arg`, `binary_arg`, `evidence_arg`, each shell-quoted). Its post checks
retained hashes rather than rerunning tests. Replay correctly refuses enforced
session workspaces (`workspace_execution_context_unsupported`), so use the verified
direct CLI until replay itself passes; do not weaken the binding or prefer an
unverified spell. No recurring job or effect retry belongs in history search.
