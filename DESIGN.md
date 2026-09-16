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

The status balloon reports more than a token count. Minimum fields:

- active provider and model, and the base URL;
- context-window meter when a limit is known, plus last-turn prompt tokens;
- token totals: last turn (prompt/completion/total) and session
  (prompt/completion/total) and turn count;
- memory: memories, messages, ledger runs, sessions.

## 7. Component registry

| Element | Purpose | Key attributes / properties | Events |
| --- | --- | --- | --- |
| `<wa-balloon>` | Anchored floating panel. Owns the close rule (§3). | `open` (attr/bool), `anchor` (id) | `open`, `close` |
| `<wa-message>` | A chat message bubble. | `role` (`user`/`assistant`), `.body` | — |
| `<wa-tool>` | A tool-activity chip. | `name`, `.detail`, status class | — |
