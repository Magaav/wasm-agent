BRIEF DONE
LANDED: 118q/bce287f4 LANDED on main (verified from origin/main: tool_arguments asks json_contract.field_intent and carries suggested_shape; json_contract has field_intent + shape_of). One gap left, named: the peer route answers path_required before the naming refusal for remote.

SCOPE, HONESTLY: this is the MECHANISM the brief names plus one row per tool. It now WIRES `edit`'s door and `operation`'s (was: did not wire `edit`'s own
refusal or the peer route to it - each is named in its row. I tried the `edit` wiring, `test-edit-aliases`
went red (35 checks), so I reverted it rather than ship a regression; that is the one thing I would do next
with another hour.

WHAT LANDED (lua/core/json_contract.lua, additive, 53 lines)
- `M.shape_of(property)` answers a field's exact shape: `array of {new_text, old_text}`, `string`, `object`.
- `M.field_intent(tool, sent, declared)` is the ONE owner of the suggestion: the nearest name by distance, then
  an INTENT table for the words a model uses for a field it has never seen (`new_str` -> `edits`, `name` ->
  `id`, ...). Textual distance cannot find these, which is why those refusals suggested nothing.
- No tool description changed: ZERO prompt bytes; the naming lives in a result.

GAPS, each named in the row that measures it
1. `edit` refuses an unknown option with its own sentence naming both accepted forms, but without
   did_you_mean/suggested_shape. Wiring it through tool_arguments regressed test-edit-aliases and was reverted.
2. `operation`: `label`/`description` pass tool_arguments.M.INTERNAL, so the handler fails on the missing id.
3. `remote`: the target capability's required-field check answers first (`path_required`), so `path_str` is
   never named as the wrong name for `path`.

ROWS: test-field-names-edit 7 (pins + gap), test-field-names-operation 8 (RED on main - field_intent absent,
GREEN here), test-field-names-remote 3 (pins + gap). Neighbours green: test-edit-aliases 35, tool-args-parity
976, tool-schema-fidelity 71, refusal-contract 18281.

PROGRESS: mechanism + rows committed, 90a3c500, READY. What is left is the three wirings above, each with its
row already in place waiting to assert the stronger answer.

WIRING DONE at bce287f4: the door asks the owner. The earlier withdrawals are kept below because the cause matters: the validator always refused; what was missing was the suggestion, and a row comparing error strings for EQUALITY read the improved refusal as a different one.

TRIED AND WITHDRAWN (twice): wiring `edit`'s door through the owner. Both attempts made test-edit-aliases read `unsupported_edit_option` from the handler instead of the validator's `unknown_argument:old_txt`, for a reason I could not pin down inside this session (the row's own wording was one cause and is now understood; the second cause is not). Per the rule about a step failing the same way twice, it is out, not half-in: git checkout of lua/core/tool_arguments.lua and scripts/test-edit-aliases.lua to 90a3c500, and all four rows re-run green.
