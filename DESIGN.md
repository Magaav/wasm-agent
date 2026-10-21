# wasm-agent UI design contract

This file is **UI direction only**: components, tokens, spacing, balloons, what a view may do.
How the system is put together - instruction scope, capability tiers, where a concern belongs - is in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

Rules for the web UI (`ui/`) and any future surface (desktop shell, mobile, docs).
These are **enforced**, not suggestions: when a change conflicts with a rule here,
change the change — or amend this file first with a reason.

## Idle rendering

Polish comes from tonal depth, readable hierarchy and brief gesture feedback—not
continuous idle animation or full-window backdrop sampling. Colored UI surfaces
(including popovers and hover/focus fills) and state text are opaque: use solid
colors rather than alpha fills or whole-element opacity. Layout-only containers,
unpainted glyphs and decorative shadows do not make content surfaces translucent.
Resting surfaces are static; hidden/off-screen work is suppressed without dropping transcript text,
searchability or live-stream state. [LIGHTWEIGHT-UI.md](docs/LIGHTWEIGHT-UI.md)
defines freshness, render virtualization, fallback and measurement limits.

## 1. Reuse before you create

Prefer a component, token, or pattern that already exists in this project over a
new one. Transcript topics share `topicParts()`, one `.topic` surface and the
`.trace-head` glyph/label/meta/chevron header. Subagent receipts use this pattern,
not a separate card. Component-owned `.topic-body` lists never inherit markdown
list margins or indentation; header padding follows the 5px scale on every host.


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

- **Inner padding:** use **5px**, shared by `--space` and `--pad`, including
  bubbles, composer, panels and promoted headers. The former 10px inner inset is
  reduced for compactness; do not shrink fonts, icons or control hit targets.
  Structural offsets, safe-area insets and Markdown indentation are not padding
  density controls.
- **Gaps:** between sibling elements the gap is **0** or **5px**. Never invent
  8px/12px/14px gaps.
- Sizes of square controls are multiples of 5 (`30px`, `40px`).
- Component radius: **5px**, defined once by `--radius`; `--radius-sm` and
  `--radius-lg` alias it. The native expanded shell clips to the same 5 logical
  pixels (GDI ellipse diameter10, scaled by DPI), not its former 18px radius.
  Circular glyphs/avatars remain circles, full-bleed/maximized regions square.
- Bubble run-status rows use the closed-topic outer height (30px), including
  live and settled states; counters retain exact content and narrow-screen fit.
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
occupancy and capacity in millions, not cumulative session spending. It and
the balloon share the same last provider-reported task input, exact capacity
format and percentage. Pending text/preparation estimates do not overwrite a
measured prompt; `??` means unknown/mismatched context. Raw integer counts and
percent remain visible in details, not rounded into a different denominator. Updates reuse stream events
and existing metadata reads. Provider/model stay inside the balloon, not beside
the trigger. An opaque resting surface blends into the composer and gains a
clickable border/background on hover or keyboard focus; keyboard and balloon close
behavior remain unchanged.

Actual model summary requests show a shared topic **Model is summarizing** inside
the bubble, including elapsed time; no debug toggle is needed. Queued steering is
one dashed topic per receipt at the bubble bottom immediately above status;
consumed steering becomes **Steered**, not a separate user bubble. Read means
entered context, never compliance. Main and children share this presentation.

Commentary streams inside an open `wa-commentary` topic, with character count
updated per chunk. That topic is the thinking topic: one component (`WaTopic` in
`ui/components.js`) builds both `<wa-reasoning>` and `<wa-commentary>`, so they
collapse/expand, count characters and render their body identically - a second
copy would drift. A topic's body is the transcript's one Markdown renderer, the
same HTML a reply contains (raw HTML stays escaped, so `<text>` is text); there
is no plain-text topic body. Only explicit per-item phase establishes commentary.
Unknown phase stays provisional. A sentence whose phase resolves to commentary
keeps the place it streamed in - the provisional block becomes that topic where
it stands, same parent and same sibling index, and the string is not re-created
elsewhere in the bubble. It is then an ordinary topic, indistinguishable from the
thinking one: the header row is drawn ABOVE the body, so the text moves DOWN by
that row's height, exactly as it does when a tool or thinking topic appears, and
the body carries the topic's own padding, border and height cap, and the
transcript's own text measure - a body is prose at the size the answers are read at,
because a commentary body IS the answer's text box when its step stops without a tool
call (below), and a smaller measure inside the topic made that conversion paint the
answer at one typography and a later repaint of the ledger paint it again at another.
There is no
second visual state for a topic that only exists while the run is live, no
reversed layout and no marker row below the text: that state is how a commentary
was rendered with its header under its prose and its prose outside its box. The
bubble is `width: fit-content`, so a body at the topic's own measure makes the
commentary's line narrower than the answer segment it replaced - the same width a
replayed row of the same commentary draws, which is the point. Commentary stays
outside the run topic while the run is stepping: nothing folds into the topic
until the final
answer, which nests the whole history (commentary included) and is the only thing
that stays outside it. Its own manual fold survives;
only the final answer stays outside activity topics (alongside the status row).
The request's own tool surface decides where its first content prose streams: a request that
carried no tools is answering, so its prose is the answer in the bubble as before; a request that
carried tools has no provider label for that prose, so it streams INSIDE a provisional commentary
topic from the first token. A tool call settles that label with nothing moving. A step that ends
with no tool call is answering: in one frame the run's earlier steps and commentary fold into the
run topic and that same prose block is moved out of it to sit directly under the topic as the
answer - exactly one conversion per run. The answer's text box is measured across that move
(`getBoundingClientRect` and computed font-size/line-height/padding); it must not change metrics,
because a conversion that re-lays the answer out under the reader is the defect. That box is the
answer's own measure - the same font-size and line-height a no-tool run's answer has - from the
first token, so the conversion changes no typography either. A reply that has no streamed block
draws the same shell (`answerShell`), which is how a repaint of the durable rows lands on the same
box instead of a second one: the pass that used to re-render the answer a moment after the run is
the same paint, or it does not happen. At the conversion
a tall answer (more than ~80% of the chat viewport) anchors its first line and overflows downward, a
short one does not move the reader, and a reader already in scrollback is never pulled back.
The identified answer also emits `onFinalAnswer` once per run (ids and lengths only); see
[HOOK-EVENTS.md](docs/HOOK-EVENTS.md).
Run-to-answer spacing uses one5px flex gap, never an additional segment margin.
A confirmed final answer's first visible line stays at the chat content top while
it grows, including short answers. Late-confirmed finals smoothly reveal their
beginning after completion (instant with reduced motion). Completed answers retain
that reading position; manual scrolling always takes priority. Container-local
trailing space supplies the necessary scroll range, not a sticky overlay or a
second transcript. Main and child use the same policy.
Main header shows the model (and an explicit remote target), not `local` or provider;
provider selection/diagnostics remain in the status balloon.


The status balloon is about **the model and harness observability**, not memory storage. Required
sections, in order:

1. **provider**, **model** (§5), and model-supported **reasoning** selects. A change here is
   seen by the **next** turn, never by the one in flight: the node pins provider, model and
   reasoning when a run starts, so while a run streams the three controls are locked and the
   balloon states the delay ("applies at the next turn") - a control that moves under a run
   misreports what that run used;
2. **context** — last measured request input and selected model capacity. Never
   substitute a whole run's cumulative input for one request's context;
   bubble `◈` separately shows **net context added this turn**, not cache rereads
   or billed usage, before `✧ ⚒ ◷` both live and completed (one compact line, each glyph
   glued to its value). Exact measured
   post-request endpoints remain in details; missing historical baselines stay unknown;
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


## Secure inline Go entry (explicit human-requested exception)

`/provider` embeds `<wa-vault-entry>` inside the OpenCode Go section. The actual
password/enrollment inputs and Save to vault button belong to a **different-origin,
vault-owned document**, not the parent light DOM or composer. This scoped exception
to ordinary component-owned forms is required to keep both secrets out of the node
and parent app while satisfying inline entry. There is no parent-owned substitute
when provisioning/identity/TLS/framing fails. The full operator page stays unframeable;
only the dedicated Go form permits the explicitly configured exact parent origin.

The frame uses opaque 5px-scale surfaces, labelled password fields, wrapped destination
identity, no unmasking or idle animation, and a bounded scrollable region. Enter submits
only the private form, never chat; Escape/parent close destroys transient input without
claiming cancellation of an already dispatched/uncertain write. Node/account changes
destroy the frame; busy runs disable new intents. Re-renders preserve the live frame
rather than discarding an in-flight operation. Cross-origin messages carry only typed
public channel/scope/operation/generation evidence; parent verifies the actual frame,
origin, current authority, and fresh effective-route receipt before displaying success.

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
| `<wa-trace>` | A step's tool trace inside a reply bubble. `.body`, and `.setAge(seconds, bound)` on the in-flight line so `bash` reads `42s of 300s`, not just `bash`. A row also carries the file it touched and, for a change that applied, the `-`/`+` lines it made: `addTool(…, change)` and `settle(outcome, detail, failed, cancelled, paths)`. | — |
| `<wa-run>` | The collapsible topic a run's tool lines live in. | — | — |
| `<wa-subagent>` | Shared topic for native/legacy delegation receipts, with a branch glyph, recorded profile/state/session and an expanded conversation link. A receipt is not task completion. | `.receipt`, `.body`, `open` | `subagent-open` (`{session}`) |
| `<wa-diff>` | The file changes a run made, below its answer. | — | — |
| `<wa-window>` | A promoted panel in its own OS window (§3). | — | — |
| `<wa-harness-status>` | §6's harness diagnostics. | — | `export` |
| `<wa-tasks>` | Concurrent child tasks, run recovery and cancellation. | `.data`, `.message`, `showEvidence()` | `task-action` |
| `<wa-orchestrator>` | External workspace with node priority controls, an active-only agent sidebar whose cards are grouped by lane (the child's recorded branch or worktree, with that lane's end-state checklist) and stable tiled sessions. Two of that checklist's four outcomes are measurements of that record (`retired` from the recorded workspace state, `main-only` from whether the lane holds a branch or worktree of its own); `merged` and `clean` are git facts about refs which this view is never given, so they read `unknown` with the reason for every lane - they are not outcomes it is withholding. | `.data`, `.message`, `.configure(fleet)`, `.policy`, `.panes`, `.windows` (promoted conversations), `.allPanes()`, `.promote(pane)`, `.unpin(key, pane)` | `orchestrator-action` |
| `<wa-chat-shell>` | **The** chat surface: transcript region, composer (text area, send, attach/paste/drop intake), attachment chips, model readout and picker, notification sound. The main conversation and every child session host the same element, so a chat improvement lands in one place. | `.content`, `.region` (the transcript's own box: the chat content rect a `data-slot="float"` control is pinned to), `.host` (the host's own rows between transcript and composer), `.form`, `.input`, `.send`, `.attach`, `.file`, `.attachments` (the live list), `.attachmentsEl`, `.modelEl`, `modelChip`, `.busy`, `.enterLocked`, `.addFiles(files)`, `.renderAttachments()`, `.clearAttachments()`, `.composedText(text)`, `.autosize()`, `.notify()`, `.setModelPicker(facts, label)`; author-provided children take `data-slot` (`float`, `footer-left`, `footer-right`, `balloon`, or none for the transcript) | `chat-send` (`{text, busy}`), `chat-files` (`{files}`), `chat-attachments` (`{action, …}`) |
| `<wa-agent-session>` | Child conversation and original live-journal/tool evidence using the shared composer/status/topic renderer. **Hosts the shared `<wa-chat-shell>`** rather than its own composer; its own header is the panel's two controls (close as an `x`, expand as a square that promotes it into its own `<wa-window>`), never the window's topbar. Its transcript is drawn by the window's own renderer (`app.js`'s `paintChildTranscript`), so a child's bubble, its run topic and its run-status footer are the same DOM as the main chat's - one implementation, not a parallel one. | `.task`, `.promoted`, `.clearDraft()`, `.input`, `.form`, `.transcript`, `.notice` (shared warning), `.statusLine` (shared renderer getter) | `agent-action` |
| `<wa-chat-actions>` | **The** row of per-message actions a chat footer carries. Steering and dedicated Cancel task buttons are removed on all chat surfaces; the shared Send/Stop is the sole submit action. One element on both surfaces, and its controls come from the shell's own `chatControl()` factory, so an action and the append-file control beside it are the same control - one class, `.chat-control`, is the whole box in `style.css`, and a change to one moves all of them. A host authors *declarations* (one child per action: `data-action`, its label as its text, and any `id`/`title`/`hidden` it addresses) and hears `chat-action`, never one particular button. | `data-slot="footer-right"` on the row, `data-action` on a declaration; `.controls`; `#steer` is the main chat's own control | `chat-action` (`{action, control}`) |
| `<wa-mcps>` | Explicit app-capability extensions, selected tools, disabled definitions, probe/approval/errors; no scheduler. Engine topic before Jobs. | `.inventory`, `.message`, `.configureScope()`, `.busy` | `mcp-action` |
| `<wa-jobs>` | Reviewed automation definitions, enabled state, queue/source/outcome evidence. Engine topic immediately after tools. | `.items` | `job-toggle` |
| `<wa-provider-manager>` | Deterministic operator provider recovery; two friendly routes, source/presence/unknown, explicit selection and native device flow, vault-owned cross-origin Go entry. | `.data`, `.message`, `.pending`, `.login`, `.entryAllowed`, `clearEntry()` | `provider-action`, `vault-entry` (public receipt/control only) |
| `<wa-vault-entry>` | Cross-origin dedicated password/enrollment form; no parent/node secret access or secret events. | `configure({url,vault,scope,broker})`, `.allowed`, `clear()` | `vault-entry` (whitelisted nonsecret metadata) |
| `<wa-hook-events>` | Read-only lifecycle inventory after Jobs: producers, boundaries, configured handlers and reliability limits; evaluated absent events are labelled, not advertised as working. | `.catalogue`, `.message` | — |

**A tool row says which file, and what changed.** A row that named, wrote or read a file carries the path
on the row itself — in the row's own title where the call's arguments state it (`read`, `write`, `edit`,
`ls`, `grep` and the `_many` batches), and in a `.tool-path` chip when only the *result* reports it.
The path is drawn as its last two segments (`…/ui/style.css`) whatever its length: a row shares its line
with the outcome, and the full path belongs in the element's `title`/`aria-label`, in the row's hover text
and in the result payload the row already holds. For `edit`, `edit_many`, `write` and `write_many` the row
also draws the change its arguments describe, through the one `patchLineRow()` renderer the file balloon
and the patch window use: `+` lines carry `--diff-add`, `-` lines carry `--diff-del`, and a line the call
kept is on neither side. It is bounded at 40 lines inline and never clips silently — the lines left out are
counted in the note, which names the change topic under the answer as the place to read the whole patch.
A call that did not apply draws no change, a tool that touches no file is unchanged, and both hosts draw
this through the same renderer, so a child pane shows the same row.

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
All content/composer/topic/run-status/warning styles and rendering are shared;
child transcript identity has no separate paint rules. The Send/Stop uses the
operator-preferred dark child color on all hosts. Only the main has node/account
menus; child task transport remains owner-scoped. [SHARED-CHAT.md](docs/SHARED-CHAT.md)
owns state/clock/journal isolation and parity verification.

**One footer, one control — for the controls the shell owns.** `chatControl()` in `components.js` builds the
append-file control the shell ships and every button of `<wa-chat-actions>`; all of them are `.chat-control`,
and `style.css` states that box once (one place, and no other rule may state it: the orchestrator's generic
`button` rule excludes `.chat-control` by selector rather than out-specifying it). The action row is
`<wa-chat-actions>` on the main chat and in every child pane, authored the same way (a `data-slot="footer-right"`
child of the shell). A labelled control is the same height, border and radius and differs only in the width its
own label needs; an icon control is the square `--control-size` (30px). The **host's own** footer children are
not part of this: the audio control (`#mic`), the account chip and the status chip are authored by `app.js` and
styled with `.icon-btn` and the chip classes, because they are not per-message controls the shell
builds. All footer controls nevertheless share the `--control-size` height (30px), including the account,
context/model, mic and append-file controls on both hosts. Footer chips center their contents with no
vertical padding so avatar/text intrinsic sizes cannot change that height. "One implementation" here
means one factory and one box for what the factory makes, not every button that happens to sit on that row.

The engine view's topics (nodes, spells, tools) are expandable cards rendered in
`app.js`; each loads its data on first expand (`GET /nodes`, `/spells`, `/tools`).
MCPs precede Jobs and load configuration-only `GET /mcp` through an independent
read interpreter, even during main/child activity. Opening never probes/starts a
server. Explicit edits/probes remain disabled and visible failures retain the last
inventory and node/account-specific editor draft. See [MCP.md](docs/MCP.md).
Jobs follow tools and load `GET /jobs` even during a run: disabling automation must
not wait for the work it stops. Toggles remain pending until persistence succeeds;
errors never paint a successful change. Event/configuration text is rendered as text,
not HTML. Jobs are automation definitions, not external process operations.


## 11. Attachments

Attachments ride through the composer's existing `.attachment` chip, extended
rather than forked (§1): an image adds `.attachment-image` and an
`.attachment-thumb` preview so you can see what you are about to send.
Cards are square (`--attachment-size`), without visible filenames/descriptions;
the remove × sits at the top right. Names remain in hover/accessibility metadata
and the outgoing payload. Text files use a file glyph. Successful intake never
creates run-status text or an elapsed timer: the cards are its acknowledgement.
Refused/failed/stale intake remains visible. Main and child use this one shell.

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
