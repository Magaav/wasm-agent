# wasm-agent design contract

Rules for the web UI (`ui/`) and any future surface (desktop shell, mobile, docs).
These are **enforced**, not suggestions: when a change conflicts with a rule here,
change the change — or amend this file first with a reason.

## 1. Reuse before you create

Prefer a component, token, or pattern that already exists in this project over a
new one.

1. Search `ui/components.js` and `ui/style.css` first.
2. If something is close but not a fit, **extend the existing component** (add a
   property, a slot, a variant) instead of forking it.
3. Only add a brand-new component when nothing existing can carry the behaviour.
   When you do, you must:
   - implement it as a custom element in `ui/components.js`;
   - style it with the shared tokens in `:root`;
   - document it in the "Component registry" below in the same change.

Duplicated markup that should have been a component is a defect.

## 2. Web components are the default pattern

Reusable UI is a **custom element** (`<wa-…>`), not a block of `document.createElement`
calls scattered through `app.js`.

- One file: `ui/components.js` (loaded before `app.js`).
- Light DOM by default, so the shared stylesheet and the WASM markdown renderer
  keep working. Use shadow DOM only when encapsulation is genuinely required.
- Expose state through **attributes** and **properties**, and talk to the app
  through **`CustomEvent`s**, never by reaching into the app's globals.
- `app.js` composes components; it does not build their internals.

## 3. Balloons (popovers)

A balloon is any floating panel anchored to a trigger (the status balloon, model
picker, future menus). All balloons use `<wa-balloon>`.

**Close rule — the one that matters:** a balloon closes only when the pointer
**press** originates outside the balloon and its anchor.

- Press **outside** → release anywhere ⇒ closes.
- Press **inside** → release **outside** ⇒ **stays open** (e.g. dragging a slider,
  selecting text, picking from a native dropdown).
- Press on the **anchor** ⇒ the anchor toggles it; the balloon does not
  double-handle it.
- `Escape` always closes it.

Never implement close-on-`click` by target alone: a click that starts inside and
ends outside is reported against a common ancestor and would wrongly close.

## 4. Spacing

One scale: **5px**.

- **Inner padding:** every component pads its own content by **5px** minimum
  (multiples of 5 — `10px`, `15px` — are fine for larger surfaces).
- **Gaps:** between sibling elements the gap is **0** or **5px**. Never invent
  8px/12px/14px gaps.
- Sizes of square controls are multiples of 5 (`30px`, `40px`).
- Radii: `5px`, `10px`, `15px`.
- Use the tokens `--space`, `--pad`, `--gap`, `--radius*` rather than literals.

## 5. Model selection shape

Providers are chosen first, models second.

- A **provider** select (`opencode-go`, `gpt`, …) — each provider is an
  OpenAI-compatible endpoint with its own base URL and key.
- A **model** select, populated from the selected provider's catalogue.
- Defaults: provider `opencode-go`, model `deepseek-v4.1-flash`.
- A provider is shown even when it has no key, but is marked unconfigured.

## 6. Status balloon contents

The status balloon is about **the model and its budget**, not storage. Required
sections, in order:

1. **provider** select, **model** select (§5);
2. **context** — tokens sent on the last turn (`taken`) vs the context budget
   (`WASM_AGENT_LLM_CONTEXT`), with a meter;
3. **limits** — the provider's rolling windows: `5h` (`rolling`), `7d`
   (`weekly`), `30d` (`monthly`), each a percent with a meter and a reset
   estimate; "limits unavailable" when the provider exposes none;
4. **tokens** — last turn (in/out/total), session (in/out/total), turn count.

The base URL and database path belong in the balloon footer line.

## 7. Memory is on demand

Memory is a feature the agent uses when a task calls for it, not a dashboard.
The UI must not foreground memory: no memory counters in the status balloon, the
header, or the empty state. Surface memory only inside a turn (a `recall` tool
chip) or when the user explicitly asks for it.

## 8. Capability tiers

Tools are grouped by the role that may call them (§ see `lua/core/tools.lua`):

Roles are `master` (full) and `guest` (on demand memory); `admin` is a legacy
alias for `master`. Binding between nodes is `master:master` or `master:guest`.

| Tier | Tools | Roles |
| --- | --- | --- |
| memory | `remember`, `recall` | everyone |
| capabilities | `capabilities` (list what this role may call) | everyone |
| environment (pi) | `bash`, `read`, `write`, `edit`, `ls`, `grep` | master |
| shell | `shell` (shell on the client host, also the UI terminal) | master |
| ledger | `search_messages`, `conversation`, `list_conversations` | master |
| client | `client` (screenshot, frame, mouse, keyboard, shell, CDP) | master |
| nodes | `nodes`, `remote` | master |
| spells | `spell_save`, `spell_run`, `spell_list`, `spell_get`, `spell_forget` (crystallized macros) | master |
| plugins | every WASM plugin | master |

Never expose a master tier to a non-master turn; filter schemas *and* re-check in
`dispatch`, because the model can ask for a tool it was not offered.
The `client` and `shell` tools drive a real machine — the highest-risk tiers.

## 9. Modes and views

A **mode** is a full-view switch (chat ⇄ engine ⇄ shell ⇄ control).

**Keep concerns apart.** The status balloon is only about the *model* (provider,
context, limits, tokens — §6). Anything about the *machine or the fabric*
(nodes, spells, tools/envelope, accounts) lives in the **engine** view, reached
from the engine button in the topbar. Do not mix the two.

- The switch lives in the **topbar**, beside the collapse control — never in the
  composer footer, which is for per-message actions (send, mic, attach).
- Every mode must be escapable **three ways**: the topbar toggle (which stays
  visible in every mode), an explicit back control in the view's own header, and
  `Escape`.
- A view must never hide the control that opens it. Hiding the only way back is
  a defect, not a style choice.

## 10. Component registry

| Element | Purpose | Key attributes / properties | Events |
| --- | --- | --- | --- |
| `<wa-balloon>` | Anchored floating panel. Owns the close rule (§3). | `open` (attr/bool), `anchor` (id) | `open`, `close` |
| `<wa-message>` | A chat message bubble. | `role` (`user`/`assistant`), `.body` | — |
| `<wa-tool>` | A tool-activity chip. | `name`, `.detail`, status class | — |

The engine view's topics (nodes, spells, tools) are expandable cards rendered in
`app.js`; each loads its data on first expand (`GET /nodes`, `/spells`, `/tools`).

## 11. Attachments

Attachments ride through the composer's existing `.attachment` chip, extended
rather than forked (§1): an image adds `.attachment-image` and an
`.attachment-thumb` preview so you can see what you are about to send.

Two kinds, and they travel differently:

- **text** — read as UTF-8 and inlined into the prompt (`[file: name]`), as before.
- **image** — sent as a *structured part*, not inlined. The request body becomes
  `{"text": …, "images": [{name, mime, data}]}`; the plain-text body is kept for
  every turn without images, so the CLI and peer relays are unaffected.

Accepted image types are `png`, `jpeg`, `webp`, `gif` — the set the provider
gateway itself accepts. Anything else is refused with a visible error rather
than sent and rejected mid-turn.

On the node, bytes are stored content-addressed by sha256 under
`~/.wasm-agent/attachments/` and referenced from the turn; they are never stored
in `turns.content`, which is FTS-indexed. `build_context` rebuilds the vision
part on every replay, and a file that has gone missing is reported inside the
text part — never silently dropped.
