# wasm-agent UI design contract

This file is **UI direction only**: components, tokens, spacing, balloons, what a view may do.
How the system is put together - instruction scope, capability tiers, where a concern belongs - is in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

Rules for the web UI (`ui/`) and any future surface (desktop shell, mobile, docs).
These are **enforced**, not suggestions: when a change conflicts with a rule here,
change the change — or amend this file first with a reason.

## 1. Reuse before you create

Prefer a component, token, or pattern that already exists in this project over a
new one.


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

**Two containers, one panel.** A floating panel has two possible homes, and the
UI must be able to choose between them and say which it chose:

- **In-page `<wa-balloon>` — the default.** Instant, anchored to its trigger,
  and it owns the close rule above. Bounded by the viewport with its own
  scrolling, so it is never cut off. When it needs more room than the window
  has, the page may ask the shell for a bigger window (and give the size back
  when the balloon closes) — the shell is the only thing that can change the
  window, and a DOM element cannot paint outside it.
- **A view window (`native.openView`) — for content that wants space.** A real
  OS window: resizable, movable, snappable, Alt-Tab-able, and it survives the
  chat being collapsed. It is a client of the node like any other surface, so it
  fetches its own data rather than receiving it from the main window. It closes
  the way a window closes (its own control, or the OS), which is a *different*
  rule from the one above — do not pretend otherwise in the UI.

Promotion is decided by the content and by the reader, never silently: a long
patch opens a window and says so, and every panel that can be promoted also
offers the other container as a control. Never move a panel under the reader's
pointer without telling them.


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

The status balloon is about **the model and harness observability**, not memory storage. Required
sections, in order:

1. **provider**, **model** (§5), and model-supported **reasoning** selects;
2. **context** — last measured request input and selected model capacity. Never
   substitute a whole turn's cumulative input for one request's context;
3. **limits** — the provider's rolling windows: `5h` (`rolling`), `7d`
   (`weekly`), `30d` (`monthly`), each a percent with a meter and a reset
   estimate; "limits unavailable" when the provider exposes none;
4. **tokens** — durable session input, disjoint uncached/cache-read/cache-write
   categories, output including reasoning, and priced cost including summaries;
5. **harness diagnostics**, implemented as `<wa-harness-status>`: settings actually
   sent; model/tool/turn latency and failures; context coverage and compaction;
   trace completeness, request/source/binary fingerprints, and paginated exports.

Use progressive disclosure and preserve expanded sections across refreshes.
Missing usage, cache details and prices are **unknown**, never free or zero.
Selected settings and the last observed request can differ; show that distinction.
Answered turns are not verified task success. No synthetic efficiency score.

The base URL and database path belong in the balloon footer line.


## 9. Modes and views

A **mode** is a full-view switch (chat ⇄ engine ⇄ shell ⇄ control).

**Keep concerns apart.** The status balloon diagnoses the *model and harness* (§6).
Management of the *machine or the fabric*
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


## 12. Composer undo/redo

Two `.icon-btn` controls in the composer footer, where §9 puts per-message
actions, plus `Ctrl+Z` / `Ctrl+Shift+Z` / `Ctrl+Y` while the textarea has focus.

**What it undoes is the draft, and only the draft**: the text you have typed and
the files you have pasted, dropped or attached but not yet sent. It does not
touch the transcript and it does not touch the ledger.

That boundary is deliberate, not a limitation to be "fixed" later. The turn
ledger is append-only: a conversation is what the model was actually shown, and
letting someone silently delete a turn would make the transcript a claim about
history that history cannot support. Undoing a *sent* turn would also have to
reach the provider, the FTS index and every peer that mirrored the turn. If that
is ever wanted it is a separate feature with its own design, not a wider
interpretation of this button.

Consequences worth knowing:

- Typing is grouped into steps: a burst of keystrokes is one undo, not one per
  character. A pause starts a new step.
- A batch of files dropped together is one step, so one `Ctrl+Z` removes the
  whole drop.
- Sending clears both stacks. An already-sent draft must not be resurrected into
  the composer, where pressing Enter would send it twice.
- A refused file (an unsupported image type) does not create a step: an undo
  entry that visibly does nothing is worse than no entry.
- The buttons are disabled when their stack is empty, and disabled buttons do
  not take the hover accent — a control must not claim an undo that is not
  available.
