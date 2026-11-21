# one-run-path - `run(code=...)` is the only way to act

Branch `change/one-run-path`, base `97251587`. Operator (Victor, 21/11): "should we erase the other paths so we
 don't mistake this again and keep the best path which is proven?" - yes.

Committed locally only: this branch never pushes and nothing is deployed here.

## 1. What the tree does now

One transport. `run({code, raw})` is the only way to act, and every other door is gone:

| was | now |
|---|---|
| `WASM_AGENT_RAW_CODE` = `only, first, stop, on/1/true, e2, e3, bash, native, codemode, off/0/false/no` | the switch is gone; **every** value is refused by name at start (`run_switch_removed`), a removed one saying which door it named and an unknown one that no build ever had it |
| the fenced `js run` block channel (`M.take`, `take_native`, `render_history`, `retag`, `unexecuted`, `native_calls`, `script_for`, `list_content_column`) | gone. A run block, or a tool-call markup shape, written as TEXT is markup: one named continue naming the run tool, a second consecutive one fails the turn by name (`tool_call_markup_as_text`) |
| `only` / `first` narrowing the declared tool list (`without_generic`, `without_codemode`, `ONLY_GENERIC`) | gone: the tools a script can express are always declared beside `run` |
| the stop sequence and the A/B arms (`lua/core/ab_arms.lua`, `lua/core/arm_tag.lua`) | deleted |
| `raw_code.default_mode()` (native only for a provider with a row, else `only`) | the provider row decides, and a provider without a tool-call row is refused by name (`provider_cannot_call_tools`) with the one repair - add a row, or `wa conform <model>` |
| a thread frozen in a mode kept it | a thread frozen in a removed mode moves to the run tool with ONE `[session update]` note that names the mode; its earlier rows are byte-identical |

Kept, deliberately: the **leak safety net** (markers, the `<bash>/<run>/<invoke>` pairs, the reasoning-field
diagnosis), the `codemode` tool name (the same call's other name - dropping it would change the declared
tool list and cost every native thread its cache), and the three model-facing texts a native thread already
carries, **byte-identical** (proved below).

## 2. Premises, re-measured before writing code

| brief said | measured at `97251587` |
|---|---|
| `raw_code.lua` 1178 lines | true |
| `codemode_block.lua` 729 lines | **wrong: 1039.** It is also not the block channel - it is the transcript view of one code-mode call (`cli_view` draws through it) and it **stays** |
| `ab_arms.lua` 83 | true; `arm_tag.lua` (170) also serves only the arms and is deleted with them |
| Step 0: `lua/core/mission.lua:175` and `:548` export `codemode` | **already fixed on this base**: both lines say `unset WASM_AGENT_RAW_CODE`. The remaining exports were in `scripts/mission.sh` (`enter()` and the generated `run.sh`), and those are now `unset` too |
| the default is `only` for a provider with no row; only `opencode-go` has one | true (`model_profile.DEFAULT_TRANSPORTS`), and this fleet has exactly one provider, so no node is refused by the provider door today |
| a thread keeps the mode it started with (frozen with the prefix) | true (`prompt_cache` `raw_mode`, not part of the state hash) |

## 3. Before / after

| | base `97251587` | this branch (`46938061` + the commits above it) |
|---|---|---|
| `lua/core/raw_code.lua` | 1178 lines | **422** |
| `lua/core/ab_arms.lua` + `lua/core/arm_tag.lua` | 83 + 170 | **deleted** |
| `lua/core/agent.lua` | 4189 | 3969 |
| the commit as a whole | - | **492 insertions, 3458 deletions, 35 files** |
| `scripts/test-*.lua` files | 354 | 341 (14 deleted with their paths, 1 added) |
| rows in `scripts/test.sh` | 115 | 109 (9 mode rows out, 1 new row in, plus the real-process refusal) |
| `scripts/test.sh` lines | 2731 | 2720 |

The gate rows and the fast-path seconds are in section 6, which reports only what was run.

## 4. Where each claim lives

- the switch, its values and the two refusals: `lua/core/raw_code.lua` - `M.REMOVED_VALUES`, `M.switch_refusal()`,
  `M.transport_refusal()`; raised at start in `lua/core/agent.lua` (`build_context`, `error(refusal.text,0)`).
- the leak net: `lua/core/raw_code.lua` - `M.markup_in_text`, `M.text_action`, `M.in_thinking`,
  `M.thinking_notice`/`thinking_failure`; the loop's one continue in `lua/core/agent.lua` (`local leaked`).
- the old-thread move: `lua/core/prompt_cache.lua` - `removed_mode`, the `native` reason, the sentence in
  `compose`; the record is read, never rewritten (`raw_mode` is not part of the state hash).
- the raw binding bug: `lua/core/raw_code.lua` `M.native_run` binds `const raw = __raw`, and `raw` is in
  `RAW_RESERVED` so a block named `raw` is refused instead of failing to compile.
- no launcher, unit or script sets the switch any more: `scripts/mission.sh` (`enter()` and the generated
  `run.sh` now `unset` it), and the probes in `scripts/fleet-install.sh` and `scripts/lua-swap.sh` check that
  the loaded Lua is this build and that the node does not still export the switch.

## 5. Texts to approve (verbatim, model- or operator-facing)

1. `run_switch_removed: WASM_AGENT_RAW_CODE=<value> is gone: <what it named>. run(code=...) is the only way to
   act (Victor 21/11), so there is no mode to set and no other path to fall back to. Remove
   WASM_AGENT_RAW_CODE from this node's environment - and from any launcher, unit or script that exports it.
   This run is refused by name and exits non-zero rather than acting through a path this build does not have.`
2. `provider_cannot_call_tools: this provider cannot call tools; add a row or measure it with `wa conform
   <model>`. run(code=...) is the only way to act on this node, so a provider that cannot answer with a tool
   call has no path here; the run is refused by name rather than moved to another transport.`
3. The one continue for the action written as text (unchanged shape, now also reached by a run block):
   `[Harness notice] Your message carried <marker> tool-call markup as text, so nothing ran. Act by calling the
   run tool with the script in its code argument; a message with no tool call is your answer.`
4. The failure after a second consecutive one: `native_markup_continue: tool_call_markup_as_text (<marker>)`.
5. The reasoning-field notice now names the tool instead of the block: `[Harness notice] This message had no
   answer: <reason>. Act by calling the run tool with the script in its code argument; a message with no tool
   call is your answer.`
6. The reasoning-only notice: `[Harness notice] This message had no answer: you reasoned and then stopped, so
   nothing ran. Write your next step in your ANSWER: call the run tool with the script in its code argument, or
   write the answer itself and why.`
7. `finish_contract`'s markup notice now says `... Act by calling the run tool with the script in its `code`
   argument.` and its failure `tool_call_markup_as_text: ... the harness asked for the run tool once already ...`.
8. The old-thread note: `[session update] ... - This session was started in the mode "only", and this node no
   longer has it: the fenced run block and the switch that chose between code paths are gone, so run(code=...)
   is the only way to act. Call the run tool with the script in its code argument; a run block, or any other
   tool-call markup written as text, runs nothing and earns one notice naming this. Your earlier messages are
   unchanged.`
9. `run` tool description and the guidance sentence: **unchanged on purpose** (cache parity). The description
   still says "the same way a fenced js run block does", which is now an analogy rather than a door. Rewording
   it is a prompt change with its own cache miss for every native thread, so it is **not** smuggled into this
   branch: it is proposed here and left for the next one.

## 6. Verification

(see the run recorded at the end of this file)

## 7. Not done here, and known holes

- No fleet node was touched: no release, no deploy, no `wa call`, no peer. The switch inventory across the
  fleet (Step 1's table) needs each node's service environment, and reading it means reaching nodes this
  branch is not allowed to touch from here (rule 13). Today's tree has one provider and every launcher in the
  repo is fixed; a node that still exports the switch will refuse by name, loudly, which is the intended way to
  find it.
- `WASM_AGENT_CODEMODE` (off/native) and `WA_CODEMODE_COMPONENT` were **kept**: they decide whether code mode
  exists at all, not which of two transports runs. With code mode off, `run` is still the only acting door - see
  the open question below.
- Open: a node with `WASM_AGENT_CODEMODE=off` cannot run a script, so its only acting path is the ordinary
  tools. That is a hole against "one path" and it is named here rather than fixed silently.
- `wa conform` still measures two transports and builds a block-flavoured harness; nothing reads its transport
  decision for the door any more (the row does). It is a follow-up, not a hole in this branch's rule.
