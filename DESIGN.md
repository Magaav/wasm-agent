# wasm-agent UI design contract

This file is **UI direction only**: components, tokens, spacing, balloons, what a view may do.
How the system is put together - instruction scope, capability tiers, where a concern belongs - is in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

Rules for the web UI (`ui/`) and any future surface (desktop shell, mobile, docs).
These are **enforced**, not suggestions: when a change conflicts with a rule here,
change the change — or amend this file first with a reason.

## Idle rendering

Polish comes from tonal depth, readable hierarchy and brief gesture feedback—not
continuous idle animation or full-window backdrop sampling. Resting surfaces are
static; hidden/off-screen work is suppressed without dropping transcript text,
searchability or live-stream state. [LIGHTWEIGHT-UI.md](docs/LIGHTWEIGHT-UI.md)
defines freshness, render virtualization, fallback and measurement limits.

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

**Whose context menu a window draws.** Which right-click menu appears is a property of the *page*, and the
rule is one sentence: a window draws **this app's** menu, and the **inspector** window draws the browser's.
The app's menu is the chat's own (collapse to avatar, reload the window, `inspect`, close) and the main window
offers the `inspect` item — the second wa-window on the node's page, where Chrome's own element inspection
lives — immediately after the reload. A **view** window (orchestrator, patch, control) is still this app's
page and draws the same menu, minus the item it could not carry out: `openInspectWindow` refuses from inside a
view, and a control that is always refused is worse than one that is not offered. The **inspector** view is the
exception, and it is the whole point of it: its webview keeps Chromium's default context menu
(`rust/wa-window/src/main.rs:506`; the main window disables it at `:611`), because `Inspect element` is in that
menu — a page that suppressed the event would leave a DOM panel and no inspector. The reuse is the shell's too:
`open_view` (`main.rs:404-421`, the title check at `:406`) refuses a second window for a view name it already
has open, so the inspector is reused rather than stacked.


## 4. Spacing

One scale: **5px**.

- **Inner padding:** every component pads its own content by **5px** minimum
  (multiples of 5 — `10px`, `15px` — are fine for larger surfaces).
- **Gaps:** between sibling elements the gap is **0** or **5px**. Never invent
  8px/12px/14px gaps.
- Sizes of square controls are multiples of 5 (`30px`, `40px`).
- Component radius: **3px**, defined once by `--radius`; `--radius-sm` and
  `--radius-lg` alias it. Circular glyphs/avatars remain circles, full-bleed regions square.
- Use the tokens `--space`, `--pad`, `--gap`, `--radius*` rather than literals.


## 5. Model selection shape

Providers are chosen first, models second.

- A **provider** select (`opencode-go`, `gpt`, …) — each provider is an
  OpenAI-compatible endpoint with its own base URL and key.
- A **model** select, populated from the selected provider's catalogue.
- Defaults: provider `opencode-go`, model `deepseek-v4.1-flash`.
- A provider is shown even when it has no key, but is marked unconfigured.


## 6. Status balloon contents

The compact footer trigger displays only `▤ 26%/1M`: one request's context
occupancy and capacity in millions, not cumulative session spending. `~` marks
current estimates, `??` unknown/mismatched context. Updates reuse stream events
and existing metadata reads. Provider/model stay inside the balloon, not beside
the trigger. A transparent resting surface gains a clickable border/background
on hover or keyboard focus; keyboard and balloon close behavior remain unchanged.

Commentary streams inside an open `wa-commentary` topic, with character count
updated per chunk. Only explicit per-item phase establishes commentary. Unknown
phase stays provisional. Commentary is never automatically closed or folded into
the run topic; manual closure survives completion/checkpoint repaint.


The status balloon is about **the model and harness observability**, not memory storage. Required
sections, in order:

1. **provider**, **model** (§5), and model-supported **reasoning** selects. A change here is
   seen by the **next** turn, never by the one in flight: the node pins provider, model and
   reasoning when a run starts, so while a run streams the three controls are locked and the
   balloon states the delay ("applies at the next turn") - a control that moves under a run
   misreports what that run used;
2. **context** — last measured request input and selected model capacity. Never
   substitute a whole run's cumulative input for one request's context;
3. **limits** — the provider's rolling windows: `5h` (`rolling`), `7d`
   (`weekly`), `30d` (`monthly`), each a percent with a meter and a reset
   estimate; "limits unavailable" when the provider exposes none;
4. **tokens** — durable session input, disjoint uncached/cache-read/cache-write
   categories, output including reasoning, and priced cost including summaries;
5. **harness diagnostics**, implemented as `<wa-harness-status>`: settings actually
   sent; model/tool/run latency and failures; context coverage and compaction;
   trace completeness, request/source/binary fingerprints, and paginated exports.

Use progressive disclosure and preserve expanded sections across refreshes.
Missing usage, cache details and prices are **unknown**, never free or zero.
Selected settings and the last observed request can differ; show that distinction.
Answered runs are not verified task success. No synthetic efficiency score.

The base URL and database path belong in the balloon footer line.


## 9. Modes and views

A **mode** is a full-view switch (chat ⇄ engine ⇄ shell ⇄ control).

**Keep concerns apart.** The status balloon diagnoses the *model and harness* (§6).
Management of the *machine or the fabric*
(nodes, spells, tool surface/request preview, jobs, accounts) lives in the **engine** view, reached
from the engine button in the topbar. Do not mix the two.

- The switch lives in the **topbar**, beside the collapse control — never in the
  composer footer, which is for per-message actions (send, mic, attach).
- Every mode must be escapable **three ways**: the topbar toggle (which stays
  visible in every mode), an explicit back control in the view's own header, and
  `Escape`.
- A view must never hide the control that opens it. Hiding the only way back is
  a defect, not a style choice.

**A device-local control lives in the engine, and says so.** The engine manages the machine and the
fabric; the one thing it must not pretend to manage centrally is a choice that belongs to the device
in front of you. The notification bell is the first of these: an engine topic whose state is in this
window's own storage, so switching it on at the desktop says nothing about the laptop. Its topic row
states the choice (`on for this device` / `off on this device`) so the state is readable without
opening the card, the node is never asked and does not know, and *off* means nothing is raised at all
— not raised and then hidden. Any other fact about one device (a sound, a window geometry) has the
same shape, and the same rule: the row says which device the choice belongs to.


## 10. Component registry

| Element | Purpose | Key attributes / properties | Events |
| --- | --- | --- | --- |
| `<wa-overlay>` | Base for anything that floats. Owns the §3 close rule. | `open` (attr/bool), `anchor` (id) | `open`, `close` |
| `<wa-balloon>` | Anchored floating panel. | `open` (attr/bool), `anchor` (id) | `open`, `close` |
| `<wa-menu>` | A list of choices at a point or above its anchor. | `.items` (`{label, action, danger?, separator?, element?}`), `.selected`, `.openAt(x, y, {above, inset})`, `.move(±1)`, `.activate()` | `open`, `close` |
| `<wa-message>` | A chat message bubble. | `role` (`user`/`assistant`), `.body` | — |
| `<wa-step>` | A turn's observed phase inside its message bubble, with running/finished state and measured elapsed time. | `.setStep(label, state, ms)` | — |
| `<wa-chat-warning>` | Exception-only yellow uncertainty overlay at the shared chat viewport top; outside transcript, no scroll shift. | `.message` (empty hides), `role="status"` | — |
| `<wa-retry>` | Shared transport-recovery topic inside the turn bubble/run history; numbered attempts, cycle, safe text reasons and reconnect countdown. Restoration is not task completion. | `.update(event)`, `.setAge()`, `.interrupt(state)`, `.freeze()`, `open` | — |
| `<wa-tool>` | A tool-activity chip. | `name`, `.detail`, status class | — |
| `<wa-trace>` | A step's tool trace inside a reply bubble. `.body`, and `.setAge(seconds, bound)` on the in-flight line so `bash` reads `42s of 300s`, not just `bash`. | — |
| `<wa-run>` | The collapsible topic a run's tool lines live in. | — | — |
| `<wa-diff>` | The file changes a run made, below its answer. | — | — |
| `<wa-window>` | A promoted panel in its own OS window (§3). | — | — |
| `<wa-harness-status>` | §6's harness diagnostics. | — | `export` |
| `<wa-tasks>` | Concurrent child tasks, run recovery and cancellation. | `.data`, `.message`, `showEvidence()` | `task-action` |
| `<wa-orchestrator>` | External workspace with node priority controls, an active-only agent sidebar whose cards are grouped by lane (the child's recorded branch or worktree, with that lane's end-state checklist) and stable tiled sessions. Two of that checklist's four outcomes are measurements of that record (`retired` from the recorded workspace state, `main-only` from whether the lane holds a branch or worktree of its own); `merged` and `clean` are git facts about refs which this view is never given, so they read `unknown` with the reason for every lane - they are not outcomes it is withholding. | `.data`, `.message`, `.configure(fleet)`, `.policy`, `.panes`, `.windows` (promoted conversations), `.allPanes()`, `.promote(pane)`, `.unpin(key, pane)` | `orchestrator-action` |
| `<wa-chat-shell>` | **The** chat surface: transcript region, composer (text area, send, attach/paste/drop intake), attachment chips, model readout and picker, notification sound. The main conversation and every child session host the same element, so a chat improvement lands in one place. | `.content`, `.host` (the host's own rows between transcript and composer), `.form`, `.input`, `.send`, `.attach`, `.file`, `.attachments` (the live list), `.attachmentsEl`, `.modelEl`, `modelChip`, `.busy`, `.enterLocked`, `.addFiles(files)`, `.renderAttachments()`, `.clearAttachments()`, `.composedText(text)`, `.autosize()`, `.notify()`, `.setModelPicker(facts, label)`; author-provided children take `data-slot` (`footer-left`, `footer-right`, `balloon`, or none for the transcript) | `chat-send` (`{text, busy}`), `chat-files` (`{files}`), `chat-attachments` (`{action, …}`) |
| `<wa-agent-session>` | Child conversation, original tool evidence, live preview and independent composer. **Hosts the shared `<wa-chat-shell>`** rather than its own composer; its own header is the panel's two controls (close as an `x`, expand as a square that promotes it into its own `<wa-window>`), never the window's topbar. Its transcript is drawn by the window's own renderer (`app.js`'s `paintChildTranscript`), so a child's bubble, its run topic and its run-status footer are the same DOM as the main chat's - one implementation, not a parallel one. | `.task`, `.promoted`, `.clearDraft()`, `.input`, `.form`, `.transcript`, `.notice`, `.preview`, `.statusLine` | `agent-action` |
| `<wa-chat-actions>` | **The** row of per-message actions a chat footer carries. Steering buttons are removed on all surfaces; a child pane retains Cancel task. One element on both surfaces, and its controls come from the shell's own `chatControl()` factory, so an action and the append-file control beside it are the same control - one class, `.chat-control`, is the whole box in `style.css`, and a change to one moves all of them. A host authors *declarations* (one child per action: `data-action`, its label as its text, and any `id`/`title`/`hidden` it addresses) and hears `chat-action`, never one particular button. | `data-slot="footer-right"` on the row, `data-action` on a declaration; `.controls`; `#steer` is the main chat's own control | `chat-action` (`{action, control}`) |
| `<wa-jobs>` | Reviewed automation definitions, enabled state, queue/source/outcome evidence. Engine topic immediately after tools. | `.items` | `job-toggle` |
| `<wa-hook-events>` | Read-only lifecycle inventory after Jobs: producers, boundaries, configured handlers and reliability limits; evaluated absent events are labelled, not advertised as working. | `.catalogue`, `.message` | — |

Keyboard selection belongs to `<wa-menu>`, not to its caller: the highlight and the click target
must be the same item, or Enter chooses something other than what the list shows.

**One chat, two hosts.** `<wa-chat-shell>` is the chat surface, and the main conversation and every
child session instantiate it rather than building a composer each. The shell owns the furniture and the
gestures (transcript region, exception-only warning overlay, composer controls, attach/paste/drop intake, attachment chips, model strip,
send button's busy state, the notification sound) and speaks to its host only through
`chat-send`/`chat-files`/`chat-attachments`. The host owns what a send *means* — thread, transport,
streaming — and how one ledger row becomes a bubble, because those are what actually differ between a
window's own conversation and a delegated child. A child panel therefore differs from the main chat in
one place only: its header, which is the panel's own two controls (close, expand into its own window)
instead of the window's topbar (engine, shell, orchestrator window, collapse-to-avatar).

**One footer, one control — for the controls the shell owns.** `chatControl()` in `components.js` builds the
append-file control the shell ships and every button of `<wa-chat-actions>`; all of them are `.chat-control`,
and `style.css` states that box once (one place, and no other rule may state it: the orchestrator's generic
`button` rule excludes `.chat-control` by selector rather than out-specifying it). The action row is
`<wa-chat-actions>` on the main chat and in every child pane, authored the same way (a `data-slot="footer-right"`
child of the shell). A labelled control is the same height, border and radius and differs only in the width its
own label needs; an icon control is the square `--control-size` (30px). The **host's own** footer children are
not part of this: the audio control (`#mic`), the account chip and the status chip are authored by `app.js` and
styled as they were (`.icon-btn` and the chip classes), because they are not per-message controls the shell
builds. "One implementation" here means one factory and one box for what the factory makes, not every button
that happens to sit on that row.

The engine view's topics (nodes, spells, tools) are expandable cards rendered in
`app.js`; each loads its data on first expand (`GET /nodes`, `/spells`, `/tools`).
Jobs follow tools and load `GET /jobs` even during a run: disabling automation must
not wait for the work it stops. Toggles remain pending until persistence succeeds;
errors never paint a successful change. Event/configuration text is rendered as text,
not HTML. Jobs are automation definitions, not external process operations.


## 11. Attachments

Attachments ride through the composer's existing `.attachment` chip, extended
rather than forked (§1): an image adds `.attachment-image` and an
`.attachment-thumb` preview so you can see what you are about to send.

Two kinds, and they travel differently:

- **text** — read as UTF-8 and inlined into the prompt (`[file: name]`), as before.
- **image** — sent as a *structured part*, not inlined. The request body becomes
  `{"text": …, "images": [{name, mime, data}]}`; the plain-text body is kept for
  every run without images, so the CLI and peer relays are unaffected.

Accepted image types are `png`, `jpeg`, `webp`, `gif` — the set the provider
gateway itself accepts. Anything else is refused with a visible error rather
than sent and rejected mid-run.

On the node, bytes are stored content-addressed by sha256 under
`~/.wasm-agent/attachments/` and referenced from the message; they are never stored
in `messages.content`, which is FTS-indexed. `build_context` rebuilds the vision
part on every replay, and a file that has gone missing is reported inside the
text part — never silently dropped.


## 12. Composer undo/redo

`Ctrl+Z` / `Ctrl+Shift+Z` / `Ctrl+Y` while the textarea has focus, and no
buttons: the gesture is the keyboard's, and a status line already reports what each one did
("undone - press Enter to send"). A control that claimed an undo the composer could not perform
was worse than none.

**What it undoes is the draft, and only the draft**: the text you have typed and
the files you have pasted, dropped or attached but not yet sent. It does not
touch the transcript and it does not touch the ledger.

That boundary is deliberate, not a limitation to be "fixed" later. The run
ledger is append-only: a conversation is what the model was actually shown, and
letting someone silently delete a run would make the transcript a claim about
history that history cannot support. Undoing a *sent* run would also have to
reach the provider, the FTS index and every peer that mirrored the run. If that
is ever wanted it is a separate feature with its own design, not a wider
interpretation of this gesture.

Consequences worth knowing:

- Typing is grouped into steps: a burst of keystrokes is one undo, not one per
  character. A pause starts a new step.
- A batch of files dropped together is one step, so one `Ctrl+Z` removes the
  whole drop.
- Sending clears both stacks. An already-sent draft must not be resurrected into
  the composer, where pressing Enter would send it twice.
- A refused file (an unsupported image type) does not create a step: an undo
  entry that visibly does nothing is worse than no entry.
- There is no button to disable, and nothing claims an undo it cannot perform:
  the stacks are reported by the status line when a gesture moves them.

## 13. Composer commands

A command is a word typed into the composer rather than one more control in the footer, which §9
keeps for per-message actions. `/` opens the list of what can be run, typing filters it, `↑`/`↓`
choose, `Enter` runs the chosen one, and `Escape` closes it (§3 owns the close rule). The panel is
`<wa-menu>` (§10), anchored above the field so it does not cover what is being typed.

The first match is chosen before any arrow key is pressed, so the list shows what `Enter` is about
to do instead of waiting to be told.

What a command may do is bounded by §12: the transcript ledger is append-only, so nothing here deletes a
transcript. `/new` starts a **thread** — this window's transcript is cleared and the next run
names the new thread — and the thread it leaves behind is untouched and still listed in the engine
view. The empty transcript says so, because an empty transcript with no explanation reads as lost
work rather than as a new start.

A message that merely begins with `/` is not trapped: a newline ends the command line, and a
command that matches nothing closes the list and leaves the text alone.
