# Refusals

What a model reads when this node refuses a call, and the one place that renders it.

## Why it is a contract

Measured on node `work`, 13/11, in one session:

- a code-mode call with no argument failed with `json_contract_invalid:json_number_invalid`
  (`json_contract.lua:44`) - three modules away from its cause, the component loop handing the parser
  the text `undefined`. The model spent about five calls finding it;
- `notes_write` called as `{content="..."}` answered `notes_text_required` and nothing else: the
  accepted name was nowhere in the answer, and the model guessed three times;
- `schema_extra:arguments.foo` named the extra argument and not one name the tool does take.

A refusal that names the parser, hides the accepted names or omits the next step is a call the model
pays for twice. So every refusal a model can read carries four fields:

| field | what it is |
| --- | --- |
| `error` | the stable code a test or a client already matches. **Never renamed.** |
| `message` | one sentence naming the real cause **and** the module that refused it, so the model does not chase the layer that noticed the problem. |
| `input` | the offending value or argument text, bounded to 80 characters, one line, redacted. |
| `fix` | what to change, naming something that exists: the accepted argument names from the tool's own schema, the range, the allowed actions, an example, the peers online. |

Codes stay stable: this adds fields, it never renames one. A result that already carries its own
`message`, `fix` or `input` keeps them - a site knows more than a table does - and a result with no
`error` is returned untouched.

## Where it is rendered

One helper, `lua/core/refusal.lua`, called at the four boundaries every refusal crosses. No site copies
these sentences.

| boundary | what it covers |
| --- | --- |
| `tools.dispatch`'s wrapper (`lua/core/tools.lua`) | every Lua tool refusal, including one made *inside* another call (code mode's `await tools.bash(...)`, `tool_call`, one item of a batch) and the two early refusals (a hook deny, the canonical-checkout guard) |
| `native_run` (`lua/core/codemode.lua`) | the native code-mode loop: a global, the fence, the argument contract, a nested tool call |
| `component_run` (`lua/core/codemode.lua`) | the component code-mode loop, for the same four cases and for the seam's `refusal` case |
| the tool loop (`lua/core/agent.lua`) | the two shapes that never reach the dispatcher: a tool that raised, and a call refused before dispatch (a missing name, arguments that do not parse) |

## Two tiers, and the number is measured

| tier | how the sentence is made | codes today |
| --- | --- | --- |
| `code` | written against the site that raises the code, after reading it | 279 |
| `family` | read from the shape of the name: `*_required` is a missing argument, `*_must_be_*` states the rule it broke | 225 |
| `shape` | a code nobody has taught the table yet: the code's own words, the module, and the next step its condition implies | 0 |
| `message` | a tool that raised: its own Lua text, which already names the line, carried as the cause | 0 |

The counts are printed by `scripts/test-refusal-contract.lua` on every run, and the test refuses to let
the `code` count fall below its recorded floor: promoting a code from `family` to `code` is a visible
change, and dropping one of those sentences has to be said out loud. `shape` and `message` are exercised
by fixtures in the same test, so a code added tomorrow answers with a cause and a next step instead of
nothing.

## The inventory

`lua/core/refusal_codes.lua` is generated: every refusal code a model call can reach, and the module
that raises it, taken from the `dofile` closure of `tools.lua`, `codemode.lua` and `agent.lua`. It is
what lets a message name where the refusal came from without every site repeating it.

```
lua5.4 scripts/gen-refusal-codes.lua --write   # regenerate
lua5.4 scripts/gen-refusal-codes.lua --check   # exit 1 when it is stale
```

The set is an over-approximation on purpose: a module reachable from the loop can be reached by a tool,
so a code in it may reach a result. Over-approximating costs one table row; under-approximating costs
the model the call the map exists to save. `scripts/test-refusal-contract.lua` recomputes it with the
same scan, so a code added to one of those modules without regenerating is a red test.

Codes returned rather than assigned (`json_contract.lua` answers `schema_extra:arguments.foo`, it does
not set an `error` field) are invisible to that scan; `refusal.lua` names their origin by rule, in one
place, next to the table.

## The gate

`scripts/test-refusal-contract.lua` walks the inventory and the catalogue:

- every code renders a `message`, an `input` and a `fix` - bounded, one line, one sentence, no empty
  placeholder left behind;
- every catalogue tool, refused for a missing or an extra argument, names the arguments it *does* take;
- a `fix` only names things that exist: a file in this tree, a code, a tool, or a word the tree's own
  sources use;
- the real boundary does it: a refused `tools.dispatch` carries the four fields, and the code it carried
  before this change is unchanged.

The dispatch half needs a node (`tools.dispatch` needs the host). Under `scripts/fast.sh` it always
runs; a bare `lua5.4` run reports it as not measured rather than as passed.
