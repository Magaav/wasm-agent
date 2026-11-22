# The prefix records a thread froze on the BASE tree

These two files are REAL prefix records, written by the commit this branch starts from
(`97251587`, the tree before `change/one-run-path` landed), not reconstructions:

    git worktree add /tmp/base-only 97251587
    # a scratch home, then, with WASM_AGENT_RAW_CODE=<mode>:
    #   memory.start_session(...) -> agent.new(...):build_context() -> prompt_cache.enforce writes the row
    # the row's `value` column was copied out verbatim

| file | what it froze |
|---|---|
| `prefix-only.json` | `only`: the block channel was the only way to act, so the declared tool list is EMPTY (`tools: "[]"`) |
| `prefix-first.json` | `first`: `codemode` was not declared, and the empty list is what that left |

Both froze an empty list, which is why keeping those bytes refused the turn
(`no_dispatchable_tools`) instead of moving it - the defect review r1 item 2 names.
`scripts/test-one-run-path.lua` resumes both through the real loop with a provider stub that calls
`run`, and asserts: the call dispatches, ONE `[session update]` note names the mode, the earlier rows
are byte-identical, and a later unrelated change never repeats the sentence.

The record holds no session id of its own (the key does), so the test inserts it under the key of the
session it resumes: the BYTES are the base's, only the key is remapped.
