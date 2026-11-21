# codeact-view: the model reads the lean result of a `run` script again

## What was wrong (measured 22/11 on this node's ledger: 1,976 `run` results of two days, 24 sessions)
`lua/core/tool_output.lua` gives a script result its lean view - a status line and exactly what the script
returned - only when the tool's name is `codemode`. The loop hands it the name the model used, and since
`run` became the one path that name is `run`. So no script result got the lean view. The model read the
whole stored envelope on every round, and re-read it on every later turn:

| | characters |
|---|---|
| what the model read (stored envelope) | 6,912k |
| what the lean view is for the same results | 4,643k |

The envelope carries each call's arguments and output a second time (`attempts`), the constant `backend` and
`context_policy` strings, and the output as an escaped JSON string instead of plain text.
The done gate's effect rule (`lua/core/agent.lua`) had the same literal name, so a read-only script was
judged by the generic rule instead of by what its calls did.

## The change
- `tool_output.is_script(name)`: one predicate (`codemode`, `run`), read by the view and by the effect rule.
- `scripts/test-run-view.lua` (17 checks; fails on the base at its first comparison): the real dispatcher
  and sandbox under the name `run`; plain text, output once, no bookkeeping, failures and objects, other
  tools untouched, the stored view read back byte for byte.

## The prompt cache
Nothing already sent changes. A result's view is computed once, when the call settles, and stored; later
turns send the stored bytes (`context_view` returns a row under the budget as it is). Only results produced
after the install are lean. No prompt, tool description or schema byte changes.

## Checks run
test-run-view, test-codemode-default, -model-boundary (664), -presentation, test-done-gate (89),
test-efficiency (119), test-session-vars (48), test-turnfeed, test-turn-signal, test-hotreload,
test-skill-content, test-experiment-verify, test-whatsapp-names: green.
test-envelope-outcomes, test-envelope-iteration, test-exec-timeout, test-read-batch fail in a bare
`WA_SCRIPT` invocation on this tree AND on unchanged main in the same words (all four are listed in
scripts/fast-path.exclude, so no gate runs them; that is its own finding, not this change.s)
No full fast run was made.

## Not in this change (measured, queued in ~/Work/missions/_queue/codeact-next.md)
- 490 results (25%) fall back to the JSON form only because they carry a `pending_backgrounded` or
  `pending_settled` note; waits for change/always-available, which changes that shape.
- `raw is not defined` (7 failures) and shell text inside JavaScript strings (about 35 syntax errors).

## How Victor tests it
Measure before and after with `python3 ~/Work/missions/codeact-stats.py 1` (line RESULTS).
By hand: in a NEW `wa chat` session ask "run `ls /` and tell me how many entries". Then
`sqlite3 ~/.wasm-agent/memory.db "select substr(content,1,80) from messages where role='tool' and tool_name='run' order by created_at desc limit 1"`
prints a line starting with `status 200`, not `{"attempts":`.
