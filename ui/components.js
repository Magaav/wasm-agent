// Reusable UI components. See DESIGN.md.
//
// Extend these before creating new markup in app.js. Each component is a custom
// element, exposes state through attributes/properties, and emits CustomEvents.

// <wa-overlay> — base for anything that floats and closes on an outside press.
// Implements the close rule from DESIGN.md §3: it closes only when the pointer
// *press* originates outside the overlay and its anchor. A press that starts
// inside and is released outside keeps it open.
class WaOverlay extends HTMLElement {
  static get observedAttributes() { return ["open"]; }

  constructor() {
    super();
    this._pressInside = false;
    this._pressTracked = false;
    this._onDown = this._onDown.bind(this);
    this._onUp = this._onUp.bind(this);
    this._onKey = this._onKey.bind(this);
  }

  connectedCallback() {
    this.hidden = !this.open;
    document.addEventListener("pointerdown", this._onDown, true);
    document.addEventListener("pointerup", this._onUp, true);
    document.addEventListener("keydown", this._onKey);
  }

  disconnectedCallback() {
    document.removeEventListener("pointerdown", this._onDown, true);
    document.removeEventListener("pointerup", this._onUp, true);
    document.removeEventListener("keydown", this._onKey);
  }

  attributeChangedCallback() { this.hidden = !this.open; }

  get open() { return this.hasAttribute("open"); }
  set open(value) {
    if (value) this.setAttribute("open", "");
    else this.removeAttribute("open");
  }

  get anchor() {
    const id = this.getAttribute("anchor");
    return id ? document.getElementById(id) : null;
  }

  static _within(node, target) {
    return Boolean(node) && target instanceof Node && node.contains(target);
  }

  _onDown(event) {
    if (!this.open) return;
    this._pressTracked = true;
    this._pressInside = WaOverlay._within(this, event.target)
      || WaOverlay._within(this.anchor, event.target);
  }

  _onUp() {
    if (!this.open || !this._pressTracked) return;
    this._pressTracked = false;
    if (!this._pressInside) this.close();
    this._pressInside = false;
  }

  _onKey(event) {
    if (event.key === "Escape" && this.open) this.close();
  }

  show() {
    if (this.open) return;
    this.open = true;
    this.dispatchEvent(new CustomEvent("open"));
  }

  close() {
    if (!this.open) return;
    this._pressTracked = false;
    this._pressInside = false;
    this.open = false;
    this.dispatchEvent(new CustomEvent("close"));
  }

  toggle() { this.open ? this.close() : this.show(); }
}
customElements.define("wa-overlay", WaOverlay);

// <wa-balloon> — an overlay anchored to a trigger element (`anchor` attribute).
class WaBalloon extends WaOverlay {}
customElements.define("wa-balloon", WaBalloon);

// <wa-menu> — an overlay positioned at a point, rendering `items`.
// Item shape: { label, action, danger?, separator? } for an action, or { element } for a
// control that belongs in the menu but is not a menu action - a field to edit, say. An
// element item is appended as it is: the menu does not wrap it in a button, because a
// click inside it must not be read as choosing the item.
class WaMenu extends WaOverlay {
  constructor() {
    super();
    this.items = [];
    this.selected = -1;
    this._buttons = [];
    this.classList.add("menu");
  }

  // `above: true` puts the menu's bottom edge at `y` instead of its top. A menu opened from
  // the footer has nowhere to go downward, and clamping it to the viewport bottom leaves it
  // covering the control that opened it.
  openAt(x, y, options = {}) {
    this.render();
    this.style.left = "0px";
    this.style.top = "0px";
    this.show();
    const rect = this.getBoundingClientRect();
    const maxX = window.innerWidth - rect.width - 5;
    const top = options.above ? y - rect.height - (options.inset || 0) : y;
    const maxY = window.innerHeight - rect.height - 5;
    this.style.left = Math.max(5, Math.min(x, maxX)) + "px";
    this.style.top = Math.max(5, Math.min(top, maxY)) + "px";
  }

  // The items a keyboard can land on: an item with no action is a heading, and a separator is
  // not a choice. Moving onto one would make Enter do nothing while the highlight said it would.
  _actionable() {
    const indexes = [];
    this.items.forEach((item, index) => {
      if (typeof item.action === "function") indexes.push(index);
    });
    return indexes;
  }

  // Keyboard selection lives here, not in the caller, because the highlight and the click
  // target must be the same thing: a menu whose arrow keys move something other than the item
  // a click would choose is a menu that lies about what Enter is about to do.
  move(delta) {
    const indexes = this._actionable();
    if (!indexes.length) return;
    const at = indexes.indexOf(this.selected);
    const next = at === -1
      ? (delta > 0 ? 0 : indexes.length - 1)
      : (at + delta + indexes.length) % indexes.length;
    this.selected = indexes[next];
    this._paint();
  }

  // Returns whether it chose anything, so a caller can decide what an Enter with no choice
  // means instead of guessing that it was handled.
  activate() {
    const item = this.items[this.selected];
    if (!item || typeof item.action !== "function") return false;
    this.close();
    item.action();
    return true;
  }

  _paint() {
    this.items.forEach((item, index) => {
      const button = this._buttons[index];
      if (button) button.classList.toggle("selected", index === this.selected);
    });
  }

  render() {
    this.replaceChildren();
    this.selected = -1;
    this._buttons = [];
    for (const item of this.items) {
      if (item.element) {
        this.append(item.element);
        this._buttons.push(null);
        continue;
      }
      if (item.separator) {
        const line = document.createElement("div");
        line.className = "menu-sep";
        this.append(line);
        this._buttons.push(null);
        continue;
      }
      const button = document.createElement("button");
      button.type = "button";
      button.className = "menu-item" + (item.danger ? " danger" : "") + (item.action ? "" : " muted");
      button.textContent = item.label;
      if (typeof item.action === "function") {
        button.addEventListener("click", () => {
          this.close();
          item.action();
        });
      } else {
        button.disabled = true;
      }
      this._buttons.push(button);
      this.append(button);
    }
  }
}
customElements.define("wa-menu", WaMenu);

// <wa-message> — a chat bubble. `role` is user|assistant; `.body` is writable.
class WaMessage extends HTMLElement {
  connectedCallback() { this._build(); }

  // Building is lazy so `element.body` works even before the element is in the
  // document. Reaching for `.body` right after createElement is the obvious
  // thing to do, and it used to throw ("Cannot read properties of undefined")
  // until the element happened to be connected.
  _build() {
    if (this._body) return;
    const role = this.getAttribute("role") === "user" ? "user" : "assistant";
    this.classList.add("msg", role);
    const who = document.createElement("div");
    who.className = "who";
    who.textContent = role === "user" ? "you" : "wasm-agent";
    this._body = document.createElement("div");
    this._body.className = "body";
    this.append(who, this._body);
  }

  get body() {
    this._build();
    return this._body;
  }
}
customElements.define("wa-message", WaMessage);

// <wa-trace> — one step's tool activity, collapsed into a topic.
//
// The transcript should read as steps, not as a wall of tool payloads: the
// header says what happened (how many calls, which tools, how long) and the body
// holds the sequential tool lines, hidden until the reader opens it. Failures are
// the exception - an error opens the topic, because a silent failure is worse
// than a noisy transcript (DESIGN.md).
// One topic header, in one place.
//
// <wa-trace>, <wa-run>, <wa-diff> and <wa-reasoning> are the same thing: a glyph, a label, a meta, a
// chevron that says it opens, and a body that starts hidden. Three of them built that by hand and the
// fourth - the thinking block - built a different one: taller, with its own padding, no chevron and no
// glyph, so it read as a different kind of thing rather than as another topic. The header *is* the
// standard, so it lives here and every topic asks for it.
function topicParts(host, options) {
  const { className, glyph, label, bodyTag = "div", bodyClass } = options;
  host.classList.add(className);
  const header = document.createElement("button");
  header.type = "button";
  header.className = "trace-head";
  header.setAttribute("aria-expanded", "false");
  const glyphEl = document.createElement("span");
  glyphEl.className = "trace-glyph";
  glyphEl.textContent = glyph;
  const labelEl = document.createElement("span");
  labelEl.className = "trace-label";
  labelEl.textContent = label;
  const metaEl = document.createElement("span");
  metaEl.className = "trace-meta";
  const chevron = document.createElement("span");
  chevron.className = "trace-chevron";
  chevron.textContent = "\u203a";
  header.append(glyphEl, labelEl, metaEl, chevron);
  const body = document.createElement(bodyTag);
  body.className = bodyClass;
  body.hidden = true;
  header.addEventListener("click", () => host.toggle());
  return { header, glyph: glyphEl, label: labelEl, meta: metaEl, chevron, body };
}

// The chevron is the whole of "this opens": it points right when closed and down when open.
function topicChevron(chevron, open) {
  if (chevron) chevron.textContent = open ? "\u2304" : "\u203a";
}

class WaTrace extends HTMLElement {
  static get observedAttributes() { return ["open"]; }

  constructor() {
    super();
    this._lines = new Map();
    this._pending = [];
    this._decisions = new Map();
    this._count = 0;
    this._errors = 0;
    this._started = Date.now();
  }

  connectedCallback() {
    if (this._built) return;
    this._built = true;
    const parts = topicParts(this, {
      className: "trace", glyph: "\u2699", label: "working\u2026", bodyTag: "ol", bodyClass: "trace-body",
    });
    this._header = parts.header;
    this._glyph = parts.glyph;
    this._label = parts.label;
    this._meta = parts.meta;
    this._chevron = parts.chevron;
    this._body = parts.body;
    this.append(this._header, this._body);
  }

  get open() { return this.hasAttribute("open"); }
  set open(value) {
    if (value) this.setAttribute("open", "");
    else this.removeAttribute("open");
  }

  attributeChangedCallback() {
    if (!this._body) return;
    this._body.hidden = !this.open;
    this._header.setAttribute("aria-expanded", String(this.open));
    this._chevron.textContent = this.open ? "\u2304" : "\u203a";
  }

  toggle() {
    // Remember the reader's choice: automatic collapsing must not fight it.
    this._userToggled = true;
    this.open = !this.open;
    this.dispatchEvent(new CustomEvent("toggle", { bubbles: true }));
  }

  // One click on a finished run should show the sequence, not another row of
  // collapsed headers.
  reveal() {
    this._userToggled = false;
    this.open = true;
  }

  // A streamed model decision is provisional until the matching `tool` event. Keep one row by
  // call id, then promote it in addTool() so selection appears before execution without duplication.
  addDecision(callId, name, argumentsText, complete, previousCallId) {
    const id = String(callId || "");
    const oldId = String(previousCallId || "");
    let decision = (oldId && this._decisions.get(oldId)) || this._decisions.get(id);
    if (!decision) {
      if (!this._userToggled) this.open = true;
      const line = document.createElement("li");
      line.className = "tool-line decision";
      const head = document.createElement("div");
      head.className = "tool-head";
      const label = document.createElement("span");
      label.className = "tool-title";
      const outcome = document.createElement("span");
      outcome.className = "tool-outcome";
      head.append(label, outcome);
      line.append(head);
      const output = document.createElement("div");
      output.className = "tool-output";
      line.append(output);
      const progress = document.createElement("div");
      progress.className = "tool-progress";
      progress.hidden = true;
      line.append(progress);
      decision = { line, label, output, progress, outcome };
      this._count += 1;
      this._body.append(line);
      this._header.classList.add("running");
    } else if (oldId && oldId !== id) {
      this._decisions.delete(oldId);
    }
    const strong = document.createElement("b");
    strong.textContent = name || "tool";
    decision.label.replaceChildren(strong);
    decision.output.textContent = argumentsText || "";
    decision.output.hidden = !argumentsText;
    decision.outcome.textContent = complete ? "selected" : "forming call";
    decision.line.classList.toggle("decision-complete", complete === true);
    this._decisions.set(id, decision);
    this._lines.set(name || "tool", decision.line);
    this._refresh();
  }

  // addTool(name, title, detail, bound) -> the line element, so the caller can fill the outcome.
  // `bound` is the call's deadline in seconds, when it has one: the line can then say how long it has
  // run *of* how long it may take, which is the question "bash" alone cannot answer.
  addTool(name, title, detail, bound, callId) {
    const decision = callId && this._decisions.get(String(callId));
    if (decision) {
      this._decisions.delete(String(callId));
      const strong = document.createElement("b");
      strong.textContent = name;
      decision.label.replaceChildren(strong, document.createTextNode(" " + (title || "")));
      decision.output.hidden = true;
      decision.output.textContent = "";
      decision.line.classList.remove("decision", "decision-complete");
      decision.line.classList.add("pending");
      decision.outcome.textContent = "";
      this._lines.set(name, decision.line);
      this._pending.push({ line: decision.line, output: decision.output, progress: decision.progress,
        outcome: decision.outcome, started: Date.now(), bound: bound || null, callId: String(callId) });
      if (!this._userToggled) this.open = true;
      this._refresh();
      this.setAge(0);
      return decision.line;
    }
    if (!this._userToggled) this.open = true;   // live: show the lines, not a count
    this._count += 1;
    const line = document.createElement("li");
    line.className = "tool-line pending";
    const head = document.createElement("div");
    head.className = "tool-head";
    const label = document.createElement("span");
    label.className = "tool-title";
    const strong = document.createElement("b"); strong.textContent = name;
    label.append(strong, document.createTextNode(" " + (title || "")));
    const outcome = document.createElement("span");
    outcome.className = "tool-outcome";
    head.append(label, outcome);
    line.append(head);
    const output = document.createElement("div");
    output.className = "tool-output";
    output.hidden = true;
    if (detail) output.textContent = detail;
    line.append(output);
    // The running operation's newest line, while the call is in flight. A clock alone cannot
    // tell a build that is compiling from one that has hung, and the node already has the line.
    const progress = document.createElement("div");
    progress.className = "tool-progress";
    progress.hidden = true;
    line.append(progress);
    this._lines.set(name, line);
    this._pending.push({ line, output, progress, outcome, started: Date.now(), bound: bound || null, callId: callId || "" });
    this._body.append(line);
    this._header.classList.add("running");
    this._refresh();
    this.setAge(0);
    return line;
  }

  // setAge(seconds, bound) paints how long the pending call has been running, and against what limit.
  // Called by the page's one shared ticker with no arguments (it reads the pending line's own clock),
  // and by the UI test with an explicit age so the text can be checked without waiting a real second.
  setAge(seconds, bound) {
    const target = this._pending[0];
    if (!target) return;
    const elapsed = seconds === undefined ? (Date.now() - target.started) / 1000 : seconds;
    const text = `${Math.max(0, Math.floor(elapsed))}s`;
    const limit = bound === undefined ? target.bound : bound;
    target.outcome.textContent = limit ? `${text} of ${Math.floor(limit)}s` : text;
  }

  // setProgress(text) paints the running operation's newest output line under the oldest
  // pending tool call. The settled result clears it, because that is the fuller answer.
  setProgress(text) {
    const target = this._pending[0];
    if (!target) return;
    target.progress.textContent = text || "";
    target.progress.hidden = !text;
  }

  get pending() { return this._pending.length > 0; }

  hasPendingCall(callId) {
    return this._pending.some((target) => target.callId === callId);
  }

  // Tool calls in one decision execute in order; replay adds them all before their
  // result rows, so settle the oldest pending line, not the most recently added one.
  settle(outcome, detail, failed) {
    const target = this._pending.shift();
    if (!target) return;
    target.progress.hidden = true;
    target.outcome.textContent = outcome || "";
    target.line.classList.remove("pending");
    target.line.classList.add(failed ? "err" : "ok");
    if (detail) target.output.textContent = detail;
    if (failed) {
      this._errors += 1;
      // An error is never hidden inside a collapsed topic.
      target.output.hidden = false;
      this.open = true;
    }
    this._refresh();
  }

  // A replayed decision with no tool row is evidence of a missing result, not a live call.
  // Do not leave its clock running or claim that the tool succeeded/failed.
  unrecorded() {
    for (const target of this._pending) {
      target.progress.hidden = true;
      target.outcome.textContent = "result not recorded";
      target.line.classList.remove("pending");
      target.line.classList.add("unrecorded");
    }
    this._pending = [];
    this._refresh();
  }

  finish() {
    for (const decision of this._decisions.values()) {
      decision.outcome.textContent = "not executed";
      decision.line.classList.remove("decision", "decision-complete");
      decision.line.classList.add("unrecorded");
    }
    this._decisions.clear();
    this._header.classList.remove("running");
    this._done = true;
    if (!this._userToggled) this.open = false;   // the step is over: fold it away
    this._elapsed = Date.now() - this._started;
    this._refresh();
  }

  _refresh() {
    const names = [...this._lines.keys()];
    if (this._done) {
      const seconds = this._elapsed >= 1000 ? `${(this._elapsed / 1000).toFixed(1)}s` : `${this._elapsed}ms`;
      this._label.textContent = `${this._count} tool ${this._count === 1 ? "call" : "calls"}`;
      this._meta.textContent = `${names.join(", ")} · ${seconds}`;
      this._glyph.textContent = this._errors ? "\u26a0" : "\u2699";
    } else {
      const last = names[names.length - 1] || "starting";
      this._label.textContent = `deciding…`;
      this._meta.textContent = `${this._count} call${this._count === 1 ? "" : "s"} · ${last}`;
    }
    this.classList.toggle("has-error", this._errors > 0);
  }
  get count() { return this._count; }
}
customElements.define("wa-trace", WaTrace);

// <wa-run> — the whole run's path, collapsed to one line at the top of the
// reply. A finished reply should read as an answer; how it got there (which
// steps, which tools) is one click away instead of pushing the answer off
// the screen.
class WaRun extends HTMLElement {
  static get observedAttributes() { return ["open"]; }

  connectedCallback() { this._build(); }

  _build() {
    if (this._body) return;
    const parts = topicParts(this, {
      className: "run", glyph: "\u2699", label: "run", bodyClass: "run-body",
    });
    this._header = parts.header;
    this._glyph = parts.glyph;
    this._label = parts.label;
    this._meta = parts.meta;
    this._chevron = parts.chevron;
    this._body = parts.body;
    this.append(this._header, this._body);
  }

  get body() { this._build(); return this._body; }
  get open() { return this.hasAttribute("open"); }
  set open(value) {
    if (value) this.setAttribute("open", "");
    else this.removeAttribute("open");
  }

  attributeChangedCallback() {
    this._build();
    this._body.hidden = !this.open;
    this._header.setAttribute("aria-expanded", String(this.open));
    topicChevron(this._chevron, this.open);
  }

  toggle() { this.open = !this.open; }

  setSummary(steps, calls, ms) {
    this._build();
    const seconds = ms == null ? null : (ms >= 1000 ? (ms / 1000).toFixed(1) + "s" : ms + "ms");
    const parts = [];
    if (steps > 0) parts.push(steps + (steps === 1 ? " step" : " steps"));
    parts.push(calls + (calls === 1 ? " tool call" : " tool calls"));
    this._label.textContent = "run";
    this._meta.textContent = parts.join(" · ") + (seconds == null ? "" : " · " + seconds);
  }
}
customElements.define("wa-run", WaRun);

// <wa-reasoning> — the model's own thinking, as a topic like every other one.
//
// It is the route to the reply, not the reply, so it folds away once the run moves on - but it stays a
// visible step, because a turn whose content was all reasoning must not read as a turn that only
// called tools. It used to be a bespoke <details> with its own header: taller than the tool-call topics
// beside it, with no chevron and no glyph. Now it is the same topic as the rest.
class WaReasoning extends HTMLElement {
  static get observedAttributes() { return ["open"]; }
  connectedCallback() { this._build(); }

  _build() {
    if (this._body) return;
    const parts = topicParts(this, {
      className: "reasoning", glyph: "\u2733", label: "thinking", bodyClass: "reasoning-body",
    });
    this._header = parts.header;
    this._label = parts.label;
    this._meta = parts.meta;
    this._chevron = parts.chevron;
    this._body = parts.body;
    this.append(this._header, this._body);
    this._sync();
  }

  get body() { this._build(); return this._body; }
  get open() { return this.hasAttribute("open"); }
  set open(value) {
    if (value) this.setAttribute("open", "");
    else this.removeAttribute("open");
  }

  attributeChangedCallback() { this._build(); this._sync(); }

  _sync() {
    if (!this._body) return;
    this._body.hidden = !this.open;
    this._header.setAttribute("aria-expanded", String(this.open));
    topicChevron(this._chevron, this.open);
  }

  toggle() { this.open = !this.open; }

  // The body is `pre-wrap`, so a trailing newline would draw an empty line and a provider ends a chunk
  // with them. The meta counts what the model produced, not what survives the trim.
  setText(text) {
    this._build();
    const raw = String(text || "");
    this._body.textContent = raw.replace(/\s+$/, "");
    this._meta.textContent = raw.length + " chars";
  }
}
customElements.define("wa-reasoning", WaReasoning);

// A Responses API commentary message is user-facing progress, not hidden
// reasoning and not the completed answer. Keep it as its own readable topic.
class WaCommentary extends HTMLElement {
  static get observedAttributes() { return ["open"]; }
  connectedCallback() { this._build(); }

  _build() {
    if (this._body) return;
    const parts = topicParts(this, {
      className: "commentary", glyph: "\u2726", label: "commentary", bodyClass: "commentary-body",
    });
    this._header = parts.header;
    this._label = parts.label;
    this._meta = parts.meta;
    this._chevron = parts.chevron;
    this._body = parts.body;
    this.append(this._header, this._body);
    this._sync();
  }

  get open() { return this.hasAttribute("open"); }
  set open(value) {
    if (value) this.setAttribute("open", "");
    else this.removeAttribute("open");
  }

  attributeChangedCallback() { this._build(); this._sync(); }

  _sync() {
    if (!this._body) return;
    this._body.hidden = !this.open;
    this._header.setAttribute("aria-expanded", String(this.open));
    topicChevron(this._chevron, this.open);
  }

  toggle() { this.open = !this.open; }

  setText(text) {
    this._build();
    const raw = String(text || "");
    this._body.textContent = raw.replace(/\s+$/, "");
    this._meta.textContent = raw.length + " chars";
  }
}
customElements.define("wa-commentary", WaCommentary);

// <wa-tool> — a tool-activity chip. `name` sets the label; `.detail` is writable.
class WaTool extends HTMLElement {
  connectedCallback() {
    if (this._detail) return;
    this.classList.add("tool");
    const title = document.createElement("div");
    title.className = "tool-name";
    title.textContent = "tool · " + (this.getAttribute("name") || "");
    this._detail = document.createElement("div");
    this._detail.className = "tool-detail";
    this.append(title, this._detail);
  }

  get detail() { return this._detail; }
}
customElements.define("wa-tool", WaTool);

// <wa-diff> — what the run changed on disk, collapsed to one line after the answer.
//
// The answer is what the reader wants; the change to their files is the thing they may need
// to *act* on, so the topic sits at the end of the bubble rather than the top. The header
// carries the totals GitHub-style (+N -M) and, at its right edge, the only control the
// topic has: one button that toggles between undoing the change and redoing it.
//
// One button, not two, and the glyph always says what the *next* click does. That is why
// there is no disabled state to guess at: when the patch is applied the button offers undo,
// when it is undone it offers redo, and it is disabled only when neither is possible -
// which the label states in words rather than leaving the reader clicking a dead control.
// <wa-diff> — what the run changed on disk, collapsed *below* the answer.
//
// This is the same topic as <wa-run> on purpose, down to the markup: a `trace-head` button
// holding glyph · label · meta · chevron, the same `attributeChangedCallback`, the same
// chevron swap, `open` as the attribute rather than a private flag. A topic is a topic; a
// second header style reads as a different kind of thing, which is what the first version of
// this component was - `diff-head`/`diff-expand` were its own invention and looked it.
//
// The one addition is the control at the right edge: a single button that toggles between
// undoing this change and redoing it. It is a *sibling* of the header button, never a child,
// because a button inside a button is invalid and swallows its own clicks - so `trace-head`
// keeps `flex: 1` and the toggle sits beside it, which is the only structural difference from
// <wa-run> and is why the header is wrapped in a row.
class WaDiff extends HTMLElement {
  static get observedAttributes() { return ["open"]; }

  constructor() {
    super();
    this._state = "applied";      // "applied" | "undone" | "locked"
    this._files = [];
    this._reason = "";
  }

  connectedCallback() { this._build(); }

  _build() {
    if (this._body) return;

    this._row = document.createElement("div");
    this._row.className = "diff-row";

    // The header is the real topic header, from the one place that builds them.
    const parts = topicParts(this, {
      className: "diff", glyph: "\u0394", label: "changes", bodyTag: "ul", bodyClass: "diff-body",
    });
    this._header = parts.header;
    this._glyph = parts.glyph;
    this._label = parts.label;
    this._meta = parts.meta;
    this._chevron = parts.chevron;
    this._body = parts.body;

    this._toggle = document.createElement("button");
    this._toggle.type = "button";
    this._toggle.className = "diff-toggle";
    this._toggle.disabled = true;

    this._row.append(this._header, this._toggle);

    this._toggle.addEventListener("click", () => this._act());

    this.append(this._row, this._body);
    this._paintToggle();
  }

  get body() { this._build(); return this._body; }
  get open() { return this.hasAttribute("open"); }
  set open(value) {
    if (value) this.setAttribute("open", "");
    else this.removeAttribute("open");
  }

  // Verbatim the <wa-run>/<wa-trace> behaviour, so the three topics open and close alike.
  attributeChangedCallback() {
    if (!this._body) return;
    this._body.hidden = !this.open;
    this._header.setAttribute("aria-expanded", String(this.open));
    topicChevron(this._chevron, this.open);
  }

  toggle() { this.open = !this.open; }

  // The glyph is the whole contract: undo when the change is applied, redo when it is not.
  _paintToggle() {
    if (!this._toggle) return;
    // "pending" is disabled too, but it is not locked: the difference is whether the reader is being
    // told no, or only told to wait. A disabled control with no explanation and a disabled control that
    // says why are different things.
    const can = this._state !== "locked" && this._state !== "pending";
    this._toggle.disabled = !can;
    this._toggle.dataset.act = this._state === "undone" ? "redo" : "undo";
    // Inline SVG rather than a font glyph: the two arrows are the only way the reader
    // knows which direction the next click goes, and a missing font must not take that away.
    this._toggle.innerHTML = this._state === "undone"
      ? '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 7H9.5a5.5 5.5 0 0 0 0 11H16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M12 4l3.5 3L12 10" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>'
      : '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 7H14.5a5.5 5.5 0 0 1 0 11H8" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M12 4 8.5 7 12 10" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    const act = this._state === "undone" ? "Redo this change" : "Undo this change";
    this._toggle.title = can ? act : this._reason;
    this._toggle.setAttribute("aria-label", can ? act : this._reason);
  }

  // What the toggle does is ask, not assume: the server owns the files, so the click
  // sends the intent and this waits to be told what happened.
  _act() {
    if (this._state === "locked") return;
    const act = this._state === "undone" ? "redo" : "undo";
    this._toggle.disabled = true;
    this.dispatchEvent(new CustomEvent("diff-act", {
      bubbles: true, detail: { act, done: (result) => this._settle(act, result) },
    }));
  }

  // The outcome is the server's answer, and it is rendered either way. A refusal is shown
  // on the topic rather than swallowed: "undo did nothing and said nothing" is the failure
  // this whole component exists to avoid.
  _settle(act, result) {
    if (result && result.ok) {
      this._state = act === "undo" ? "undone" : "applied";
      this._reason = "";
      this.classList.toggle("undone", this._state === "undone");
      this.setMessage(act === "undo" ? "undone - the files are back" : "redone - the change is applied");
    } else {
      // A refusal that cannot be retried (the file moved on) locks the control and says
      // why; the change is still on disk and the reader needs to know that, not a spinner.
      const why = (result && result.reason) || "failed";
      this._state = "locked";
      this.setMessage(act + " refused: " + why, true);
    }
    this._paintToggle();
  }

  // The files this topic is about. `_files` is the component's own; the app needs to name them in
  // an undo request, and reaching into a private field from outside is how a component stops being
  // one.
  get files() { return this._files; }

  // `summary` is the server's summary: {files:[{path,added,removed,created}], added, removed}.
  setSummary(summary) {
    this._build();
    this._files = (summary && summary.files) || [];
    const added = (summary && summary.added) || 0;
    const removed = (summary && summary.removed) || 0;
    // One row per path, even when the ledger holds the file twice.
    //
    // Turns recorded before the recorder merged repeats hold one entry per write, and those runs are
    // still in the ledger - the ledger is append-only and is never rewritten to make a view prettier. So
    // the view merges them and says so ("\u00d72"), instead of showing the same file twice and leaving the
    // reader to work out that it is one change. The counts are summed the same way, so the rows and the
    // header agree with each other.
    const byPath = new Map();
    for (const file of this._files) {
      const seen = byPath.get(file.path);
      if (seen) {
        seen.added += file.added || 0;
        seen.removed += file.removed || 0;
        seen.writes += 1;
        seen.created = seen.created && file.created === true;
      } else {
        byPath.set(file.path, {
          path: file.path, added: file.added || 0, removed: file.removed || 0,
          created: file.created === true, writes: 1,
        });
      }
    }
    const rows = Array.from(byPath.values());
    const totalAdded = rows.reduce((sum, file) => sum + file.added, 0);
    const totalRemoved = rows.reduce((sum, file) => sum + file.removed, 0);
    const count = rows.length;
    this._label.textContent = count === 1 ? "1 file changed" : count + " files changed";
    this._meta.textContent = "+" + totalAdded + " \u2212" + totalRemoved;
    this._meta.classList.toggle("no-change", totalAdded === 0 && totalRemoved === 0);

    this._body.replaceChildren();
    for (const file of rows) {
      // A button, not a list item: clicking a changed file is how you find out what changed in it. The
      // diff itself is not in the transcript (the run carries addresses, not bodies), so this click is
      // what asks the node to build it - which is why it is a real control and not a decoration.
      const row = document.createElement("button");
      row.type = "button";
      row.className = "diff-file";
      row.title = "what changed in " + file.path;
      const name = document.createElement("span");
      name.className = "diff-path";
      name.textContent = file.path;
      const stat = document.createElement("span");
      stat.className = "diff-stat";
      const plus = document.createElement("span");
      plus.className = "plus";
      plus.textContent = "+" + (file.added || 0);
      const minus = document.createElement("span");
      minus.className = "minus";
      minus.textContent = "\u2212" + (file.removed || 0);
      stat.append(plus, minus);
      row.append(name, stat);
      // "created" is shown because undo cannot remove a file: the host has no remove_file,
      // so a created file goes back to empty and the reader is told that up front.
      if (file.created) {
        const tag = document.createElement("span");
        tag.className = "diff-tag";
        tag.textContent = "new";
        row.append(tag);
      }
      // More than one write to the same file in one run: one change, and the reader is told how it was
      // recorded rather than being shown the same path twice.
      if (file.writes > 1) {
        const tag = document.createElement("span");
        tag.className = "diff-tag";
        tag.textContent = "\u00d7" + file.writes;
        tag.title = "this file was written " + file.writes + " times in this run";
        row.append(tag);
      }
      row.addEventListener("click", (event) => {
        event.stopPropagation();
        this.dispatchEvent(new CustomEvent("diff-file", {
          bubbles: true,
          detail: { path: file.path, anchor: row, file },
        }));
      });
      const item = document.createElement("li");
      item.append(row);
      this._body.append(item);
    }
    this._paintToggle();
  }

  // A line of what happened, under the files. Also how a refusal reaches the reader.
  setMessage(text, failed = false) {
    this._build();
    if (!this._message) {
      this._message = document.createElement("div");
      this._message.className = "diff-note";
      this.append(this._message);
    }
    this._message.textContent = text || "";
    this._message.classList.toggle("failed", !!failed);
    this._message.hidden = !text;
  }

  // The server says whether this change can still be undone (the file may have moved on
  // since the run). Until it says so the toggle stays disabled, so a click can never
  // promise something that will be refused.
  // "I do not know yet" is its own state, not a refusal.
  //
  // The first version passed `can = false, reason = "checking…"` and the refusal path rendered it as a
  // red failed note - a transient question displayed as an error, which is what it looked like. A state
  // that is neither yes nor no deserves neither styling nor a sentence.
  setPending() {
    this._build();
    if (this._state === "locked") return;
    this._state = "pending";
    this._reason = "";
    this.setMessage("");
    this._paintToggle();
  }

  setUndoable(can, reason) {
    this._build();
    if (this._state === "locked") return;
    if (can) {
      this._state = this._state === "undone" ? "undone" : "applied";
      this._reason = "";
      this.setMessage("");
    } else {
      this._state = "locked";
      this._reason = reason || "cannot be undone";
      this.setMessage(this._reason, true);
    }
    this._paintToggle();
  }
}
customElements.define("wa-diff", WaDiff);


// <wa-window> - a floating panel that moves, resizes and closes like a real window.
//
// The shell can spawn an actual second OS window (`native.openView`), and this is what the page
// uses when there is no shell to ask: a browser tab, or the harness. It is a component rather than
// markup in app.js because every view that wants to be its own window should behave the same -
// drag by its title bar, resize from any edge, close from its own button, and come back where you
// left it.
//
// Geometry is remembered per `name`, so a view that is reopened is where the reader put it. The
// handles are eight invisible strips (four edges, four corners) rather than the browser's single
// bottom-right grip, because a window that can only be resized from one corner is not a window.
class WaWindow extends HTMLElement {
  static get observedAttributes() { return ["open", "name"]; }

  constructor() {
    super();
    this._drag = null;
    this._resize = null;
    this._onMove = this._onMove.bind(this);
    this._onUp = this._onUp.bind(this);
  }

  connectedCallback() {
    if (this._built) return;
    this._built = true;
    const root = this.attachShadow({ mode: "open" });
    root.innerHTML = `
      <style>
        :host { position: fixed; inset: 0; pointer-events: none; z-index: 70; display: block; }
        :host([hidden]) { display: none; }
        .frame {
          position: absolute; pointer-events: auto; display: flex; flex-direction: column;
          box-sizing: border-box;
          min-width: 320px; min-height: 220px; overflow: hidden;
          background: var(--panel, #10131a); color: var(--text, #e6e9f0);
          border: 1px solid var(--line, #232936); border-radius: var(--radius, 10px);
          box-shadow: 0 24px 60px rgba(0,0,0,.6);
        }
        .bar {
          display: flex; align-items: center; gap: var(--gap, 5px); padding: var(--space, 5px) var(--pad, 10px);
          background: var(--panel-2, #161a23); border-bottom: 1px solid var(--line, #232936);
          cursor: grab; user-select: none; flex: none;
        }
        .bar:active { cursor: grabbing; }
        .title { font-size: 12px; color: var(--muted, #8b93a7); flex: 1; text-transform: lowercase; letter-spacing: .04em; }
        button {
          background: none; border: none; color: var(--muted, #8b93a7); cursor: pointer;
          font: inherit; font-size: 14px; line-height: 1; padding: 0 var(--space, 5px);
        }
        button:hover { color: var(--text, #e6e9f0); }
        .body { flex: 1; min-height: 0; overflow: auto; }
        .grip { position: absolute; pointer-events: auto; }
        .grip.n { top: 0; left: 8px; right: 8px; height: 4px; cursor: ns-resize; }
        .grip.s { bottom: 0; left: 8px; right: 8px; height: 4px; cursor: ns-resize; }
        .grip.w { left: 0; top: 8px; bottom: 8px; width: 4px; cursor: ew-resize; }
        .grip.e { right: 0; top: 8px; bottom: 8px; width: 4px; cursor: ew-resize; }
        .grip.nw { top: 0; left: 0; width: 8px; height: 8px; cursor: nwse-resize; }
        .grip.ne { top: 0; right: 0; width: 8px; height: 8px; cursor: nesw-resize; }
        .grip.sw { bottom: 0; left: 0; width: 8px; height: 8px; cursor: nesw-resize; }
        .grip.se { bottom: 0; right: 0; width: 8px; height: 8px; cursor: nwse-resize; }
      </style>
      <div class="frame">
        <div class="bar"><span class="title"></span><button class="close" title="Close">\u00d7</button></div>
        <div class="body"><slot></slot></div>
        <div class="grip n"></div><div class="grip s"></div><div class="grip w"></div><div class="grip e"></div>
        <div class="grip nw"></div><div class="grip ne"></div><div class="grip sw"></div><div class="grip se"></div>
      </div>`;
    this._frame = root.querySelector(".frame");
    this._title = root.querySelector(".title");
    root.querySelector(".close").addEventListener("click", () => this.close());
    root.querySelector(".bar").addEventListener("pointerdown", (event) => this._startDrag(event));
    for (const grip of root.querySelectorAll(".grip")) {
      grip.addEventListener("pointerdown", (event) => this._startResize(event, grip.className.replace("grip ", "")));
    }
    this._place();
    this.hidden = !this.open;
  }

  disconnectedCallback() { this._onUp(); }

  attributeChangedCallback(name) {
    if (name === "open") this.hidden = !this.open;
    if (name === "name" && this._built) this._place();
  }

  get open() { return this.hasAttribute("open"); }
  set open(value) {
    if (value) this.setAttribute("open", "");
    else this.removeAttribute("open");
  }

  get viewName() { return this.getAttribute("name") || "window"; }

  close() {
    this.removeAttribute("open");
    this.dispatchEvent(new CustomEvent("close", { bubbles: true }));
  }

  set title(value) { this._title.textContent = value || this.viewName; }

  // Where this view was left, or a sensible first place: a little in from the top left, so it is
  // visibly not the panel and does not sit under the pointer.
  _place() {
    const key = "wa-window-" + this.viewName;
    let saved = null;
    try { saved = JSON.parse(localStorage.getItem(key) || "null"); } catch (error) { saved = null; }
    const geometry = saved || { x: 60, y: 60, w: 720, h: 520 };
    this._apply(geometry);
    this._title.textContent = this.viewName;
  }

  _geometry() {
    return {
      x: this._frame.offsetLeft, y: this._frame.offsetTop,
      w: this._frame.offsetWidth, h: this._frame.offsetHeight,
    };
  }

  _apply(geometry) {
    const maxW = Math.max(320, window.innerWidth - 20);
    const maxH = Math.max(220, window.innerHeight - 20);
    const w = Math.min(Math.max(320, geometry.w), maxW);
    const h = Math.min(Math.max(220, geometry.h), maxH);
    const x = Math.min(Math.max(0, geometry.x), Math.max(0, window.innerWidth - w));
    const y = Math.min(Math.max(0, geometry.y), Math.max(0, window.innerHeight - h));
    Object.assign(this._frame.style, { left: x + "px", top: y + "px", width: w + "px", height: h + "px" });
    return { x, y, w, h };
  }

  _remember() {
    try { localStorage.setItem("wa-window-" + this.viewName, JSON.stringify(this._geometry())); }
    catch (error) { /* private mode */ }
  }

  _startDrag(event) {
    if (event.button !== 0) return;
    // The title bar is the handle; a press on the close button is not a drag.
    if (event.target.closest("button")) return;
    const geometry = this._geometry();
    this._drag = { pointerId: event.pointerId, dx: event.clientX - geometry.x, dy: event.clientY - geometry.y };
    this._capture(event);
    document.addEventListener("pointermove", this._onMove);
    document.addEventListener("pointerup", this._onUp);
  }

  _startResize(event, edge) {
    if (event.button !== 0) return;
    event.preventDefault();
    this._resize = { pointerId: event.pointerId, edge, geometry: this._geometry(), x: event.clientX, y: event.clientY };
    this._capture(event);
    document.addEventListener("pointermove", this._onMove);
    document.addEventListener("pointerup", this._onUp);
  }

  // Pointer capture keeps a drag alive when the pointer leaves the window. It throws on a
  // synthetic event (a harness dispatching pointer events has no real pointer to capture), and a
  // throw here would abort the drag before it started - so a failed capture is not a failed drag.
  _capture(event) {
    try { event.target.setPointerCapture?.(event.pointerId); } catch (error) { /* synthetic pointer */ }
  }

  _onMove(event) {
    if (this._drag) {
      this._apply({
        x: event.clientX - this._drag.dx, y: event.clientY - this._drag.dy,
        w: this._frame.offsetWidth, h: this._frame.offsetHeight,
      });
      return;
    }
    if (this._resize) {
      const start = this._resize.geometry;
      const dx = event.clientX - this._resize.x;
      const dy = event.clientY - this._resize.y;
      const edge = this._resize.edge;
      let { x, y, w, h } = start;
      if (edge.includes("e")) w = start.w + dx;
      if (edge.includes("s")) h = start.h + dy;
      if (edge.includes("w")) { w = start.w - dx; x = start.x + dx; }
      if (edge.includes("n")) { h = start.h - dy; y = start.y + dy; }
      // A window cannot be dragged past its own minimum: the far edge stays put, which is what a
      // real window does, instead of flipping inside out.
      if (w < 320) { w = 320; if (edge.includes("w")) x = start.x + start.w - 320; }
      if (h < 220) { h = 220; if (edge.includes("n")) y = start.y + start.h - 220; }
      this._apply({ x, y, w, h });
    }
  }

  _onUp() {
    if (this._drag || this._resize) this._remember();
    this._drag = null;
    this._resize = null;
    document.removeEventListener("pointermove", this._onMove);
    document.removeEventListener("pointerup", this._onUp);
  }
}
customElements.define("wa-window", WaWindow);

// A diagnostic surface, not an agent-quality score. Every number has a scope;
// estimates, unreported provider fields and incomplete traces stay distinguishable.
class WaHarnessStatus extends HTMLElement {
  set data(settings) {
    const opened = new Set([...this.querySelectorAll('details[open]')].map(x => x.dataset.section));
    this.replaceChildren();
    const report = settings.observability || {};
    const note = text => { const el=document.createElement('p'); el.className='usage-note'; el.textContent=text; this.append(el); };
    const n = x => x == null ? 'unknown' : Number(x).toLocaleString();
    const ms = x => x == null ? 'unknown' : (Number(x)/1000).toFixed(2)+'s';
    const hash = x => x ? String(x).slice(0,16) : 'unknown';
    const section = (title,rows) => {
      const d=document.createElement('details'); d.dataset.section=title; d.open=opened.has(title);
      const heading=document.createElement('summary'); heading.textContent=title; d.append(heading);
      const dl=document.createElement('dl'); dl.className='harness-grid';
      for (const [label,value] of rows) {
        const dt=document.createElement('dt'),dd=document.createElement('dd');
        dt.textContent=label; dd.textContent=String(value ?? 'unknown'); dl.append(dt,dd);
      }
      d.append(dl); this.append(d);
    };
    note(report.available ? `Observed session ${report.session_id}. Since ${new Date(report.since*1000).toLocaleString()}. Historical usage before instrumentation is not backfilled.`
      : 'No durable observations for this session yet. Missing records do not mean zero usage.');
    const request=report.last_request || {}, last=report.last || {}, effective=request.settings || {};
    section('Configuration actually sent',[
      ['last request', `${request.provider || '?'} / ${request.model || '?'}`],
      ['reasoning sent',effective.reasoning?.selected || 'unknown'],
      ['output cap sent',n(effective.output_limit)],
      ['selected output ceiling',n(settings.output_limit)],
      ['compatibility metadata',settings.reasoning?.source || 'unknown'],
      ['finish / request id',`${last.finish_reason || '?'} / ${last.request_id || 'not reported'}`],
      ['reported reasoning tokens',n(last.normalized?.reasoning)],
      ['first content/tool delta',ms(last.ttft_ms)],
    ]);
    if (request.model && (request.model!==settings.model || request.provider!==settings.provider))
      note('The last measured request used a different configuration from the current selection.');
    const t=report.total || {}, c=report.compaction || {}, i=report.inference || {};
    section('Latency, calls and failures',[
      ['model calls / failed',`${n(t.calls)} / ${n(t.failed)}`],
      ['inference / summaries',`${n(i.calls)} / ${n(c.calls)}`],
      ['model latency p50 / p95',`${ms(report.request_p50_ms)} / ${ms(report.request_p95_ms)}`],
      ['run wall time p50 / p95',`${ms(report.run_p50_ms)} / ${ms(report.run_p95_ms)}`],
      ['inference / summary time',`${ms(i.ms)} / ${ms(c.ms)}`],
      ['tools / failed',`${n(report.tool_calls)} / ${n(report.tool_failures)}`],
      ['tool time',ms(report.tool_ms)],
      ['repeated tool arguments',`${n(report.repeated_tools)} (signal, not proof of waste)`],
      ['recorded runs / incomplete',`${n(report.runs)} / ${n(report.incomplete_runs)}`],
      ['starts without ends',`${n(report.pending)} (running or interrupted)`],
    ]);
    const ctx=report.context || {}, compact=report.last_compaction || {};
    const shape=request.prompt_shape || {};
    section('Context and compaction',[
      ['capacity / source',`${n(settings.context_limit)} / ${settings.context_source || '?'}`],
      ['compact at / keep recent',`${n(settings.compact_trigger)} / ${n(settings.compact_keep)} tokens`],
      ['unsummarized rows',n(ctx.unsummarized_rows)],
      ['summary watermark / bytes',`${n(ctx.summary_watermark)} / ${n(ctx.summary_bytes)}`],
      ['last request estimate',`${n(request.context_tokens_estimate)} (${request.context?.estimate_source || 'bytes/4'})`],
      ['last compaction before / after',`${n(compact.before)} / ${n(compact.after_estimate)} (estimate)`],
      ['summary tokens billed',n((c.prompt || 0)+(c.output || 0))],
      ['failed compactions',n(report.compaction_failures)],
      ['system / schema estimates',`${n(request.system_tokens_estimate)} / ${n(request.schema_tokens_estimate)}`],
      ['request system / schema bytes',`${n(shape.system_bytes)} / ${n(shape.schema_bytes)}`],
      ['request user / assistant bytes',`${n(shape.user_bytes)} / ${n(shape.assistant_bytes)}`],
      ['request tool-result bytes',n(shape.tool_result_bytes)],
      ['assistant reasoning / tool-argument source bytes',`${n(shape.reasoning_source_bytes)} / ${n(shape.tool_arguments_source_bytes)}`],
      ['tool calls / results in request',`${n(shape.tool_calls)} / ${n(shape.tool_results)}`],
    ]);
    note('Request composition is measured in JSON bytes, not tokens. Reasoning and argument source bytes are subsets of assistant bytes; provider token usage remains authoritative.');
    note('Summaries are lossy model interpretations; the original ledger remains the evidence. Full oversized tool results are stored on the originating node.');
    const runtime=request.runtime || report.runtime || {};
    section('Trace quality and runtime',[
      ['missing usage / cache fields',`${n(t.missing_usage)} / ${n(t.missing_cache)} calls`],
      ['unpriced calls / unknown reasoning',`${n(t.unpriced)} / ${n(t.reasoning_unknown)}`],
      ['request bytes / messages / tools',`${n(request.request_bytes)} / ${n(request.messages)} / ${n(request.tools)}`],
      ['request hash',hash(request.request_hash)],['system / schema hashes',`${hash(request.system_hash)} / ${hash(request.schema_hash)}`],
      ['Lua source / mode',`${hash(runtime.source_hash)} / ${runtime.lua_mode || '?'}`],
      ['binary / process',`${hash(runtime.native?.binary_sha256)} / ${n(runtime.native?.process_id)}`],
      ['recent failures',(report.errors || []).map(e=>`${e.kind}: ${e.error || e.name || e.code || 'unspecified'}`).join('\n') || 'none recorded'],
    ]);
    note('Answer completion is not verified task success. No efficiency score is claimed without judging the actual work. Exports contain metadata and errors; review before sharing.');
    const actions=document.createElement('div'); actions.className='harness-actions';
    for (const [label,scope] of [['Export session','session'],['Export node · 48h','node']]) {
      const button=document.createElement('button'); button.type='button'; button.textContent=label;
      button.disabled=scope==='session' && !report.session_id;
      button.addEventListener('click',()=>this.dispatchEvent(new CustomEvent('export',{detail:{scope},bubbles:true})));
      actions.append(button);
    }
    this.append(actions);
  }
}
customElements.define('wa-harness-status',WaHarnessStatus);

// Jobs are automation rules. They are not the operations used to execute their actions.
class WaJobs extends HTMLElement {
  set items(items) {
    this.replaceChildren();
    if (!items.length) {
      this.textContent = 'No jobs configured. Add a reviewed definition with wa-sentinel job put <file.json>. New or edited jobs are disabled.';
      return;
    }
    for (const job of items) {
      const row = document.createElement('section'); row.className = 'job-row';
      const label = document.createElement('label'); label.className = 'job-toggle';
      const toggle = document.createElement('input'); toggle.type = 'checkbox'; toggle.checked = job.enabled === true;
      toggle.setAttribute('aria-label', `Enable job ${job.name || job.id}`);
      const name = document.createElement('strong'); name.textContent = job.name || job.id;
      label.append(toggle, name);
      toggle.addEventListener('change', () => {
        const enabled = toggle.checked;
        toggle.checked = job.enabled === true; toggle.disabled = true;
        this.dispatchEvent(new CustomEvent('job-toggle', { bubbles: true, detail: { id: job.id, enabled, control: toggle } }));
      });
      const status = document.createElement('div'); status.className = 'job-status';
      status.textContent = `${job.enabled ? 'enabled' : 'disabled'} · ${job.trigger?.kind || '?'} → ${job.action?.kind === 'wake' ? 'agent wake' : 'deterministic execution'} · ${job.queued || 0} queued`;
      const source = document.createElement('div'); source.textContent = job.source_status || 'source not observed';
      const last = document.createElement('div');
      last.textContent = job.last_delivery ? `Last delivery: ${job.last_delivery.state} · ${job.last_delivery.detail || ''}` : 'No deliveries yet';
      const details = document.createElement('details'); const summary = document.createElement('summary'); summary.textContent = 'Review trigger and instruction';
      const config = document.createElement('pre'); config.textContent = JSON.stringify({controls: job.controls, trigger: job.trigger, action: job.action, revision: job.revision}, null, 2);
      details.append(summary, config); row.append(label, status, source, last);
      // A job's controls are the numbers the operator chose for a deterministic step - how old a message may
      // be and still be answered. They are on the surface because a number nobody can see is a number nobody
      // can change, and they are the part of a definition that is meant to be tuned. What a field holds is
      // sent as it is: an empty field sends null rather than a zero nobody typed, and the store is the only
      // thing that judges a range or the relation between two values. A second copy of those rules here
      // would be a second thing to disagree with it, so a refusal is shown in the store's own words.
      const declared = job.controls && typeof job.controls === 'object' && !Array.isArray(job.controls) ? Object.keys(job.controls) : [];
      if (declared.length) {
        const block = document.createElement('div'); block.className = 'job-controls';
        const fields = new Map();
        for (const controlName of declared) {
          const field = document.createElement('label'); field.className = 'job-control';
          const caption = document.createElement('span'); caption.textContent = controlName;
          const input = document.createElement('input'); input.type = 'number'; input.step = '1'; input.value = String(job.controls[controlName]);
          input.setAttribute('aria-label', `Control ${controlName} for job ${job.name || job.id}`);
          field.append(caption, input); fields.set(controlName, input); block.append(field);
        }
        const save = document.createElement('button'); save.type = 'button'; save.textContent = 'Set controls';
        save.addEventListener('click', () => {
          const values = {};
          for (const [controlName, input] of fields) values[controlName] = input.value.trim() === '' ? null : Number(input.value);
          save.disabled = true;
          this.dispatchEvent(new CustomEvent('job-controls', { bubbles: true, detail: { id: job.id, control: save, controls: values } }));
        });
        const warning = document.createElement('div'); warning.className = 'job-control-note';
        warning.textContent = 'Saving a control is an edit: the revision moves, queued deliveries are cancelled, and the job is left disabled until you enable it again.';
        block.append(save, warning); row.append(block);
      }
      row.append(details); this.append(row);
    }
    const note = document.createElement('p'); note.textContent = 'Disabling cancels queued deliveries. An action already admitted may have effects; running scripts receive cancellation. Re-enabling does not replay cancelled deliveries. Browser events are untrusted data.'; this.append(note);
  }
}
customElements.define('wa-jobs', WaJobs);

// Execution is owned by the node. This component emits intent and renders receipts;
// changing conversations or closing the Engine never cancels a task.
class WaTasks extends HTMLElement {
  connectedCallback() {
    if (this.form) return;
    this.form = document.createElement('form'); this.form.className = 'task-form';
    const field = (label, element) => {
      const wrapper = document.createElement('label'); wrapper.textContent = label;
      element.setAttribute('aria-label', label); wrapper.append(element); this.form.append(wrapper); return element;
    };
    this.parent = field('Parent conversation', document.createElement('select'));
    this.profile = field('Approved profile', document.createElement('select'));
    this.prompt = field('Task and completion criteria', document.createElement('textarea'));
    this.prompt.required = true; this.prompt.rows = 3;
    this.start = document.createElement('button'); this.start.type = 'submit'; this.start.textContent = 'Start child task';
    this.form.append(this.start);
    this.form.addEventListener('submit', event => {
      event.preventDefault();
      const prompt = this.prompt.value.trim(), parent = this.parent.value, profile = this.profile.value;
      if (!prompt || !parent || !profile || this.start.disabled) return;
      const fingerprint = JSON.stringify({prompt, parent, profile});
      if (this.submission?.fingerprint !== fingerprint) this.submission = {fingerprint, key: crypto.randomUUID()};
      this.pending = true; this.start.disabled = true;
      this.emit('start', {prompt, parent, profile, key: this.submission.key, control: this.start});
    });
    const refresh = document.createElement('button'); refresh.type = 'button'; refresh.textContent = 'Refresh tasks';
    refresh.addEventListener('click', () => this.emit('refresh'));
    this.notice = document.createElement('p'); this.notice.setAttribute('role','status');
    this.list = document.createElement('div'); this.list.className = 'task-list';
    this.evidence = document.createElement('pre'); this.evidence.className = 'task-evidence'; this.evidence.hidden = true;
    this.more = document.createElement('button'); this.more.type='button'; this.more.hidden=true;
    this.more.textContent='Load more output';
    this.more.addEventListener('click',()=>this.emit('more-output',{...this.outputCursor,control:this.more}));
    const create=document.createElement('details');
    const summary=document.createElement('summary'); summary.textContent='New child task';
    create.append(summary,this.form);
    this.append(create,refresh,this.notice,this.list,this.evidence,this.more);
  }
  emit(action, detail = {}) { this.dispatchEvent(new CustomEvent('task-action',{bubbles:true,detail:{action,...detail}})); }
  set message(text) { this.notice.textContent = text; }
  showEvidence(value, cursor) {
    this.evidence.hidden = false;
    this.evidence.textContent = typeof value === 'string' ? value : JSON.stringify(value,null,2);
    this.outputCursor=cursor; this.more.hidden=!cursor;
  }
  finishSubmission() { this.pending=false; this.start.disabled=!this.parent.value || !this.profile.value; }
  set data({sessions = [], tasks = [], profiles = [], runs = {}, current = ''}) {
    const options = (select, rows, preferred) => {
      const selected = select.value || preferred;
      select.replaceChildren(...rows.map(row => {const option=document.createElement('option'); option.value=row.id; option.textContent=row.title || row.description || row.id; return option;}));
      if (rows.some(row=>row.id===selected)) select.value=selected;
    };
    options(this.parent,sessions.filter(s=>!s.parent_session_id),current);
    options(this.profile,profiles.filter(p=>p.available!==false));
    this.start.disabled = this.pending || !this.parent.value || !this.profile.value;
    const titles = new Map(sessions.map(s=>[s.id,s.title || s.id]));
    const cards = [];
    const add = (title, state, detail, controls) => {
      const card=document.createElement('section'); card.className='task-card'; card.dataset.state=state;
      let heading=document.createElement('strong'); heading.textContent=title;
      if(title.length>160) {
        heading=document.createElement('details'); heading.className='task-objective';
        const summary=document.createElement('summary'); summary.textContent=title.slice(0,120)+'…';
        const full=document.createElement('p'); full.textContent=title;
        heading.append(summary,full);
      }
      const status=document.createElement('span'); status.className='task-state'; status.textContent=state;
      const text=document.createElement('p'); text.textContent=detail;
      const actions=document.createElement('div'); actions.className='task-actions';
      for (const [label,action,data] of controls) {
        const button=document.createElement('button'); button.type='button'; button.textContent=label;
        button.addEventListener('click',()=>this.emit(action,{...data,control:button})); actions.append(button);
      }
      card.append(heading,status,text,actions); cards.push(card);
    };
    for (const task of tasks) {
      const controls=[['Open conversation','open',{session:task.session_id}],['Inspect result','result',{id:task.subagent_id}]];
      if (task.parent_session_id) controls.push(['Open parent','open',{session:task.parent_session_id}]);
      if (!task.settled && task.state!=='unknown') controls.push(['Cancel task','cancel',{id:task.subagent_id}]);
      add(task.prompt || `${task.profile} · ${task.subagent_id}`,task.state,
        `Parent: ${titles.get(task.parent_session_id) || task.parent_session_id || 'none'}${task.error ? ' · '+task.error : ''}`,controls);
    }
    for (const conversation of sessions) {
      const records=runs[conversation.id] || [];
      for (const run of records.filter(r=>['running','queued','unknown','not_started','failed'].includes(r.state))) {
        const detail={session:conversation.id,runId:run.run_id};
        const controls=[['Open conversation','open',detail],['Inspect run','inspect-run',detail]];
        if (['running','queued'].includes(run.state)) controls.push(['Cancel run','cancel-run',detail]);
        add(conversation.title || conversation.id,run.state,
          run.state==='unknown' ? 'Execution was interrupted. Inspect effects before continuing.' :
          run.state==='not_started' ? 'This request did not start. Inspect it before submitting again.' : `Run ${run.run_id}`,controls);
      }
    }
    const rank={running:0,accepted:0,queued:1,unknown:2,not_started:2,failed:3};
    cards.sort((a,b)=>(rank[a.dataset.state] ?? 4)-(rank[b.dataset.state] ?? 4));
    const history=cards.filter(card=>['completed','cancelled'].includes(card.dataset.state));
    const currentCards=cards.filter(card=>!history.includes(card));
    if (!currentCards.length) { const empty=document.createElement('p'); empty.textContent='No delegated tasks or runs needing attention.'; currentCards.push(empty); }
    if(history.length) {
      const details=document.createElement('details'); details.className='task-history';
      details.open=!!this.list.querySelector('.task-history')?.open;
      const summary=document.createElement('summary'); summary.textContent=`Settled task history (${history.length})`;
      details.append(summary,...history); currentCards.push(details);
    }
    this.list.replaceChildren(...currentCards);
  }
}
customElements.define('wa-tasks', WaTasks);

// <wa-chat-shell> - the one chat surface, shared by the main conversation and every child pane.
//
// The main chat and a subagent's panel are the *same* chat furniture, not two of them: the message
// list, the composer, the attachment strip, the model strip and the notification sound live here
// once, so an improvement to any of them is one edit instead of two (DESIGN.md §1, §10).
//
// The shell owns the furniture and the gestures: the transcript region, the composer and its
// controls, the attach/paste/drop intake, the attachment chips, the draft textarea's mechanics
// (autosize, Enter sends), the send button's busy state, the model readout and picker, and the
// chime. What it deliberately does *not* own is what a send means - thread, transport, streaming -
// and how one ledger row becomes a bubble: those are the host's, and a host hears about the former
// through CustomEvents only (`chat-send`, `chat-files`, `chat-attachments`), never by reaching into
// this element's internals.
//
// A host may author its own children. They are distributed by `data-slot`:
//   (none)        the transcript region - a jump control, an empty state
//   footer-left   before the attach control, in authored order
//   footer-right  before the model readout
//   balloon       inside the composer, so an author-provided <wa-balloon> keeps its anchor and its
//                 measured position (`.composer` is the positioning context)
// The primary shell (`primary`) also takes the ids this app and its tests have always addressed
// (`messages`, `composer`, `input`, `send`, `attach`, `file`, `attachments`, `composer-model`).
// A second shell must not duplicate ids in one document, so it carries classes only.

// §11's accepted image set: the types the provider gateway itself takes. Anything else that claims
// to be an image is refused where it can be reported, rather than sent and rejected mid-run.
const CHAT_IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp", "image/gif"];

function chatIsImage(file) { return CHAT_IMAGE_TYPES.includes(String((file && file.type) || "").toLowerCase()); }

function chatHasFiles(event) {
  const types = event.dataTransfer && event.dataTransfer.types;
  return types ? Array.from(types).includes("Files") : false;
}

function chatReadAsDataURL(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ""));
    reader.onerror = () => reject(reader.error || new Error("read_failed"));
    reader.readAsDataURL(file);
  });
}

const CHAT_SHELL_MARKUP = `
  <div class="messages" data-part="content"></div>
  <div class="chat-host" data-part="host"></div>
  <form class="composer" data-part="composer">
    <div class="attachments" data-part="attachments"></div>
    <div class="composer-row">
      <textarea rows="1" data-part="input" placeholder="Message wasm-agent…"></textarea>
      <button class="send" type="submit" data-part="send" title="Send" aria-label="Send">
        <svg class="icon-send" viewBox="0 0 24 24" aria-hidden="true"><path d="M2 21 23 12 2 3v7l15 2-15 2z"/></svg>
        <svg class="icon-stop" viewBox="0 0 24 24" aria-hidden="true"><rect x="6" y="6" width="12" height="12" rx="2"/></svg>
      </button>
    </div>
    <div class="composer-footer">
      <div class="footer-left" data-part="footer-left">
        <button class="icon-btn" type="button" data-part="attach" title="Append a file" aria-label="Append a file">
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16.5 6.6 8.7 14.4a1.5 1.5 0 0 0 2.1 2.1l7.8-7.8a3.5 3.5 0 0 0-5-5l-8.1 8.1a5.5 5.5 0 0 0 7.8 7.8l6.7-6.7-1.4-1.4-6.7 6.7a3.5 3.5 0 0 1-5-5l8.1-8.1a1.5 1.5 0 0 1 2.1 2.1z"/></svg>
        </button>
        <input type="file" data-part="file" hidden multiple />
      </div>
      <div class="footer-right" data-part="footer-right">
        <span class="composer-model" data-part="model" title="Model used for the latest request">connecting…</span>
      </div>
    </div>
  </form>`;

class WaChatShell extends HTMLElement {
  connectedCallback() { this._ensure(); }

  _ensure() {
    if (this._built) return;
    this._built = true;
    // The host's authored children survive the template: they are moved back into the region that
    // `data-slot` names.
    const seed = Array.from(this.childNodes);
    this.innerHTML = CHAT_SHELL_MARKUP;
    const part = (name) => this.querySelector('[data-part="' + name + '"]');
    this._content = part("content");
    this._host = part("host");
    this._form = part("composer");
    this._attachmentsEl = part("attachments");
    this._input = part("input");
    this._send = part("send");
    this._attach = part("attach");
    this._file = part("file");
    this._footerLeft = part("footer-left");
    this._footerRight = part("footer-right");
    this._modelEl = part("model");
    this._attachments = [];
    this._busy = false;
    this._epoch = 0;
    const left = [], right = [], balloons = [];
    for (const node of seed) {
      const slot = node.nodeType === 1 ? node.getAttribute("data-slot") : null;
      if (slot === "footer-left") left.push(node);
      else if (slot === "footer-right") right.push(node);
      else if (slot === "balloon") balloons.push(node);
      else this._content.append(node);
    }
    this._footerLeft.prepend(...left);
    this._footerRight.prepend(...right);
    this._form.append(...balloons);
    if (this.hasAttribute("placeholder")) this._input.placeholder = this.getAttribute("placeholder");
    if (this.hasAttribute("label")) this._input.setAttribute("aria-label", this.getAttribute("label"));
    if (this.hasAttribute("primary")) this._legacyIds();
    this._wire();
  }

  // The ids the app and its tests address. Deliberately not on every instance: two shells in one
  // document would make `getElementById` a lie about which chat it returned.
  _legacyIds() {
    const ids = { content: "messages", composer: "composer", input: "input", send: "send",
      attach: "attach", file: "file", attachments: "attachments", model: "composer-model" };
    for (const [name, id] of Object.entries(ids)) {
      const node = this.querySelector('[data-part="' + name + '"]');
      if (node && !node.id) node.id = id;
    }
  }

  _wire() {
    // Enter sends, Shift+Enter is a newline. A host whose Enter means something else (the main chat's
    // `/` command list, a run in flight keeping the draft) sets `enterLocked` or leaves `busy` set,
    // and the shell leaves the key alone for the host's own listener.
    this._input.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" || event.shiftKey || event.ctrlKey || event.metaKey || event.altKey) return;
      if (this._busy || this.enterLocked) return;
      event.preventDefault();
      this._form.requestSubmit();
    });
    this._input.addEventListener("input", () => this.autosize());
    this._input.addEventListener("paste", (event) => this._paste(event));
    this._attach.addEventListener("click", () => this._file.click());
    this._file.addEventListener("change", () => { this._acceptFiles(this._file.files); this._file.value = ""; });
    // The form's own submit is the one path a click, an Enter and a `requestSubmit()` all take, so
    // the host is told once, wherever it came from.
    this._form.addEventListener("submit", (event) => {
      event.preventDefault();
      this.emit("chat-send", { text: this._input.value.trim(), busy: this._busy });
    });
    let depth = 0;
    const clearDrop = () => { depth = 0; this.classList.remove("dropping"); };
    this.addEventListener("dragenter", (event) => {
      if (!chatHasFiles(event)) return;
      event.preventDefault();
      depth += 1;
      this.classList.add("dropping");
    });
    this.addEventListener("dragover", (event) => {
      if (!chatHasFiles(event)) return;
      // Without preventDefault on dragover the browser refuses the drop entirely.
      event.preventDefault();
      event.dataTransfer.dropEffect = "copy";
    });
    this.addEventListener("dragleave", (event) => {
      if (!chatHasFiles(event)) return;
      depth = Math.max(0, depth - 1);
      if (depth === 0) this.classList.remove("dropping");
    });
    this.addEventListener("drop", (event) => {
      if (!chatHasFiles(event)) return;
      event.preventDefault();
      clearDrop();
      this._acceptFiles(event.dataTransfer.files);
    });
  }

  emit(name, detail = {}) { this.dispatchEvent(new CustomEvent(name, { detail })); }

  // ---- the transcript region and the host's own rows ----------------------
  get content() { this._ensure(); return this._content; }
  get host() { this._ensure(); return this._host; }

  // ---- the composer ------------------------------------------------------
  get form() { this._ensure(); return this._form; }
  get input() { this._ensure(); return this._input; }
  get send() { this._ensure(); return this._send; }
  get attach() { this._ensure(); return this._attach; }
  get file() { this._ensure(); return this._file; }
  get footerLeft() { this._ensure(); return this._footerLeft; }
  get footerRight() { this._ensure(); return this._footerRight; }
  get modelEl() { this._ensure(); return this._modelEl; }

  get busy() { this._ensure(); return this._busy; }
  set busy(value) {
    this._ensure();
    this._busy = value === true;
    // One button, two meanings: the glyph and the name say which send it is, so Stop is never a
    // second control the reader has to find.
    this._send.classList.toggle("busy", this._busy);
    this._send.title = this._busy ? "Stop" : "Send";
    this._send.setAttribute("aria-label", this._send.title);
  }

  autosize() {
    this._ensure();
    this._input.style.height = "auto";
    this._input.style.height = Math.min(this._input.scrollHeight, 180) + "px";
  }

  // ---- attachments (§11) -------------------------------------------------
  get attachments() { this._ensure(); return this._attachments; }
  get attachmentsEl() { this._ensure(); return this._attachmentsEl; }

  // One path for every way a file can arrive - the attach button, a paste, a drop - so the three
  // cannot drift apart in what they accept or how they name it. `stillCurrent` is the host's own
  // notion of "the draft this read belongs to still exists": the shell knows when its *list* was
  // cleared, but only the host knows when its draft was sent (DESIGN.md §12's stacks). Returns what
  // it took, what it refused, and what belonged to a draft that had already gone out.
  async addFiles(files, stillCurrent) {
    this._ensure();
    const epoch = this._epoch;
    const current = () => epoch === this._epoch && (typeof stillCurrent !== "function" || stillCurrent());
    let added = 0, refused = 0;
    const stale = [];
    const before = this._attachments.length;
    for (const file of files || []) {
      if (!current()) { stale.push(file.name); continue; }
      if (chatIsImage(file)) {
        try {
          const data = await chatReadAsDataURL(file);
          if (!current()) { stale.push(file.name); continue; }
          this._attachments.push({ kind: "image", name: file.name, mime: file.type, data });
          added += 1;
        } catch (error) { refused += 1; }
        continue;
      }
      if (String(file.type || "").startsWith("image/")) { refused += 1; continue; }
      try {
        const text = await file.text();
        if (!current()) { stale.push(file.name); continue; }
        this._attachments.push({ kind: "text", name: file.name, text: text.slice(0, 20000) });
      } catch (error) {
        this._attachments.push({ kind: "text", name: file.name, text: "" });
      }
      added += 1;
    }
    if (added > 0) this.emit("chat-attachments", { action: "added", added, attachments: this._attachments });
    this.renderAttachments();
    if (this._attachments.length > before) this._epoch += 1;
    return { added, refused, stale };
  }

  // The chips are the shell's, so a host cannot grow a second strip that agrees with this one only
  // some of the time.
  renderAttachments() {
    this._ensure();
    this._attachmentsEl.replaceChildren();
    this._attachments.forEach((file, index) => {
      const chip = document.createElement("span");
      chip.className = "attachment" + (file.kind === "image" ? " attachment-image" : "");
      const name = document.createElement("b");
      if (file.kind === "image") {
        const thumb = document.createElement("img");
        thumb.className = "attachment-thumb";
        thumb.src = file.data;
        thumb.alt = file.name;
        chip.append(thumb);
      }
      name.textContent = file.name;
      const remove = document.createElement("button");
      remove.type = "button";
      remove.textContent = "×";
      remove.title = "Remove";
      remove.addEventListener("click", () => {
        // Announced *before* the change, so a host that keeps an undo stack can record the state to
        // come back to. A chip removed by hand is the easiest way to lose a pasted screenshot.
        this.emit("chat-attachments", { action: "remove", index, attachments: this._attachments });
        this._attachments.splice(index, 1);
        this.renderAttachments();
      });
      chip.append(name, remove);
      this._attachmentsEl.append(chip);
    });
  }

  clearAttachments() {
    this._ensure();
    // The epoch moves, so a file still being read for the draft that has just been sent cannot land
    // in the composer afterwards.
    this._epoch += 1;
    this._attachments.length = 0;
    this.renderAttachments();
    this.emit("chat-attachments", { action: "cleared", attachments: this._attachments });
  }

  // Text attachments are inlined into the prompt (DESIGN.md §11). One implementation, so the main
  // conversation and a delegated child message cannot disagree about what `[file: name]` means.
  composedText(text) {
    this._ensure();
    const files = this._attachments.filter((file) => file.kind !== "image");
    if (files.length === 0) return text;
    const bodies = files.map((file) => "[file: " + file.name + "]\n" + file.text);
    return bodies.join("\n\n") + (text ? "\n\n" + text : "");
  }

  _acceptFiles(list) {
    const files = Array.from(list || []);
    if (files.length === 0) return;
    this.emit("chat-files", { files });
  }

  // A screenshot pasted from the clipboard arrives as a blob with no filename; an unnamed chip would
  // be unreadable, and the name is what the run shows the model.
  _paste(event) {
    const data = event.clipboardData;
    if (!data) return;
    const files = [];
    for (const item of data.items || []) {
      if (item.kind !== "file") continue;
      const file = item.getAsFile();
      if (file) files.push(file);
    }
    if (files.length === 0) return;   // ordinary text paste: let it through
    event.preventDefault();
    const stamped = files.map((file, index) => {
      if (file.name && file.name !== "image.png") return file;
      const extension = String(file.type || "").split("/")[1] || "png";
      const suffix = files.length > 1 ? "-" + (index + 1) : "";
      return new File([file], "pasted" + suffix + "." + extension, { type: file.type });
    });
    this._acceptFiles(stamped);
  }

  // ---- the model strip ---------------------------------------------------
  // A host with a chip of its own (the main chat authors the status chip and its §6 balloon) sets
  // only the readout. A host without one asks for the picker and gives the facts it can show: the
  // chip and balloon are then built here, so a child pane shows the same control without a second
  // copy of this markup. Facts, not controls, because in this app the provider/model store is the
  // node's and a child runs with the model it was delegated.
  setModelPicker(facts, label) {
    this._ensure();
    if (!this._modelChip) {
      const chip = document.createElement("button");
      chip.type = "button";
      chip.className = "chip";
      chip.setAttribute("aria-haspopup", "true");
      chip.setAttribute("aria-expanded", "false");
      chip.title = "Model and settings this conversation runs with";
      const dot = document.createElement("span");
      dot.className = "chip-dot";
      this._chipLabel = document.createElement("span");
      this._chipLabel.className = "chip-label";
      chip.append(dot, this._chipLabel);
      this._footerLeft.prepend(chip);
      const balloon = document.createElement("wa-balloon");
      balloon.className = "popover";
      const anchor = "wa-chat-model-" + (WaChatShell._instances += 1);
      chip.id = anchor;
      balloon.setAttribute("anchor", anchor);
      this._form.append(balloon);
      chip.addEventListener("click", () => {
        balloon.toggle();
        chip.setAttribute("aria-expanded", String(balloon.open));
      });
      balloon.addEventListener("close", () => chip.setAttribute("aria-expanded", "false"));
      this._modelChip = chip;
      this._modelBalloon = balloon;
    }
    this._chipLabel.textContent = label || "model unknown";
    this._modelBalloon.replaceChildren(...(facts || []).map((fact) => {
      const row = document.createElement("div");
      row.className = "pop-row";
      const head = document.createElement("span");
      head.className = "pop-head";
      head.textContent = fact.label;
      const value = document.createElement("span");
      value.className = "pop-value";
      value.textContent = fact.value;
      row.append(head, value);
      return row;
    }));
    return this._modelChip;
  }
  get modelChip() { this._ensure(); return this._modelChip || null; }

  // ---- the notification sound --------------------------------------------
  // The one notification sound, built from the platform's own audio so the shell carries no asset and
  // two surfaces cannot drift into two tones. Silent until a gesture has unlocked audio in this
  // window, and it never throws: a chime that breaks a chat is worse than no chime.
  notify() {
    try {
      const AudioContext = window.AudioContext || window.webkitAudioContext;
      if (!AudioContext) return false;
      if (!this._audio) this._audio = new AudioContext();
      const context = this._audio;
      if (context.state === "suspended") context.resume().catch(() => {});
      const now = context.currentTime;
      for (const [offset, tone] of [[0, 660], [0.16, 880]]) {
        const oscillator = context.createOscillator();
        const gain = context.createGain();
        oscillator.type = "sine";
        oscillator.frequency.value = tone;
        gain.gain.setValueAtTime(0.0001, now + offset);
        gain.gain.exponentialRampToValueAtTime(0.09, now + offset + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.0001, now + offset + 0.14);
        oscillator.connect(gain).connect(context.destination);
        oscillator.start(now + offset);
        oscillator.stop(now + offset + 0.16);
      }
      return true;
    } catch (error) { return false; }
  }
}
WaChatShell._instances = 0;
customElements.define("wa-chat-shell", WaChatShell);

function agentTaskTitle(task) {
  const text=String(task.title || task.prompt || '').replace(/\s+/g,' ').trim();
  return text ? (text.length>90 ? text.slice(0,87)+'…' : text) : 'Untitled task';
}
function agentElapsed(ms) {
  const seconds=Math.max(0,Math.floor(ms/1000));
  return Math.floor(seconds/60)+':'+String(seconds%60).padStart(2,'0');
}
// A session pane owns its draft and scroll position, never the execution.
//
// The chat inside it is the shared <wa-chat-shell>: the same transcript region, composer, attachment
// strip, model strip, send button and notification sound as the main conversation. What this element
// adds is what belongs to a *child*: its own header (close it, promote it), the live readout of the
// task it is following, and the two child-only actions (Steer, Cancel task) - all of which talk to
// the app through the same `agent-action` event as before.
//
// The transcript is drawn by app.js's own renderer (`paintChildTranscript`), not here: this element
// owns the container, and the window owns what a ledger row looks like. A second renderer in this
// file is what grew the pane an `Earlier messages` control and a `Load original message 3` button
// that the chat it is a view of never had.
class WaAgentSession extends HTMLElement {
  connectedCallback() {
    if (this.shell) { this.startClock(); return; }
    // The header holds the two controls that act on the *panel*: an x closes it, a squared button
    // promotes this conversation into its own window. The topbar's controls - engine, shell,
    // orchestrator window, collapse-to-avatar - belong to the window, not to a conversation inside it.
    this.innerHTML = '<header class="agent-pane-head"><strong></strong><span></span>'
      + '<button type="button" class="icon-btn" data-action="expand" title="Open this conversation in its own window" aria-label="Open in its own window">'
      + '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 5h14v14H5z" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/></svg></button>'
      + '<button type="button" class="icon-btn" data-action="collapse" title="Close this panel" aria-label="Close this panel">'
      + '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/></svg></button>'
      + '</header>';
    this.shell = document.createElement("wa-chat-shell");
    this.shell.setAttribute("placeholder", "Talk to this agent…");
    this.shell.setAttribute("label", "Message this agent");
    this.append(this.shell);
    this.form = this.shell.form;
    this.input = this.shell.input;
    this.transcript = this.shell.content;
    // The transcript keeps the pane's own measurement hooks, so its rules still apply to it.
    this.transcript.classList.add("agent-transcript");
    // The pane's live readout, between the transcript and the composer.
    this.preview = document.createElement("div"); this.preview.className = "agent-preview";
    this.statusLine = document.createElement("div"); this.statusLine.className = "status chat-content-run-status";
    this.statusLine.innerHTML = '<span class="spinner"></span><span class="chat-content-run-label"></span><span class="chat-content-run-elapsed"></span>';
    this.statusLine.setAttribute("role", "status");
    this.notice = document.createElement("div"); this.notice.className = "agent-notice"; this.notice.setAttribute("role", "status");
    this.shell.host.append(this.preview, this.statusLine, this.notice);
    // Steer and Cancel are the panel's own: they reach the child routes, and they sit where the main
    // chat keeps its per-message actions.
    const actions = document.createElement("div");
    actions.className = "chat-actions";
    for (const [action, label] of [["steer", "Steer"], ["cancel", "Cancel task"]]) {
      const button = document.createElement("button");
      button.type = "button"; button.className = "chat-action"; button.dataset.action = action; button.textContent = label;
      actions.append(button);
    }
    this.shell.footerRight.prepend(actions);
    this.startClock();
    // `Send` and `Steer` are one draft leaving in two ways, so they are one path with a name: the
    // shell hands over the text and the attachments, and this element decides what a child accepts.
    this.shell.addEventListener("chat-send", () => this.sendDraft());
    this.shell.addEventListener("chat-files", (event) => this.collectFiles(event.detail.files));
    this.querySelectorAll('[data-action]').forEach(button => button.addEventListener('click', () => {
      if (button.dataset.action === 'steer') this.sendDraft('steer');
      else this.emit(button.dataset.action);
    }));
  }
  // The same text reuses the same idempotency key, so a retry after a lost answer cannot arrive twice.
  sendDraft(action = 'message') {
    const text = this.input.value.trim();
    if (!text && this.shell.attachments.length === 0) return;
    const pictures = this.shell.attachments.filter(file => file.kind === 'image');
    // A picture has no structured part on the child route; refusing it here is visible, dropping it
    // silently is how a reader sends a screenshot nobody ever sees.
    if (pictures.length) {
      this.notice.textContent = pictures.length + ' picture(s) cannot ride into a delegated message yet; nothing was sent.';
      return;
    }
    const body = this.shell.composedText(text);
    if (!this.submission || this.submission.text !== body) this.submission = { text: body, key: crypto.randomUUID() };
    this.emit(action, this.submission);
  }
  // Text attachments ride into the delegated message for the same reason they ride into a run (§11):
  // they are inlined, and the shell is where that one rule lives.
  async collectFiles(files) {
    const receipt = await this.shell.addFiles(files);
    const parts = [];
    if (receipt.added > 0) parts.push(receipt.added + ' file(s) attached - press Enter to send');
    if (receipt.refused > 0) parts.push(receipt.refused + ' image(s) skipped - only png, jpeg, webp and gif are accepted');
    if (receipt.stale.length) parts.push('the draft was sent while ' + receipt.stale[0] + ' was reading - it was not attached');
    if (parts.length) this.notice.textContent = parts.join('; ');
  }
  // What a host clears when it has accepted the draft. One call, because the draft is not just text.
  clearDraft() {
    this.input.value = '';
    this.submission = null;
    this.shell.autosize();
    this.shell.clearAttachments();
  }
  // A pane that is already its own window has nothing to promote to.
  set promoted(value) {
    this._promoted = value === true;
    this.connectedCallback();
    const expand = this.querySelector('[data-action="expand"]');
    if (expand) expand.hidden = this._promoted;
  }
  get promoted() { return this._promoted === true; }
  startClock() { if(!this.clock)this.clock=setInterval(()=>this.updateClock(),1000); }
  disconnectedCallback() { clearInterval(this.clock);this.clock=null; }
  updateClock() {
    if(!this._task)return;
    const task=this._task, started=Number(task.started_at)*1000;
    const end=task.settled ? Number(task.settled_at)*1000 : Date.now();
    const duration=started && end ? agentElapsed(end-started) : 'duration unknown';
    this.statusLine.querySelector('.chat-content-run-elapsed').textContent=duration;
    // The in-flight call's own age, on the line the shared renderer drew. A child streams to the node,
    // so this element is the only thing polling and the node's own report of the call (`started_at`,
    // the bound it enforces) is the measurement: `42s of 300s` is readable, a clock nobody runs is not.
    const live=task.preview?.tool;
    if(live?.started_at) {
      const traceElement=this.transcript?.querySelector('wa-trace');
      if(traceElement?.pending) traceElement.setAge((Date.now()/1000)-live.started_at,
        live.timeout_ms ? Math.round(live.timeout_ms/1000) : undefined);
    }
  }
  emit(action,detail={}) { this.dispatchEvent(new CustomEvent('agent-action',{bubbles:true,detail:{action,pane:this,...detail}})); }
  set task(value) {
    this.connectedCallback();
    const previous=this._task;
    this._task=value;
    this.querySelector('strong').textContent=agentTaskTitle(value);
    this.querySelector('.agent-pane-head span').textContent=[value.profile,value.model,value.reasoning || 'reasoning unknown',value.node_name || value.execution_node || 'local',value.state].filter(Boolean).join(' · ');
    // The model strip is the shared one: the readout every shell has, plus a picker built from facts,
    // because a child runs with the model it was delegated rather than one this panel can choose.
    const model=[value.model || 'model unknown',value.reasoning || 'reasoning unknown'].join(' · ');
    this.shell.modelEl.textContent=model;
    this.shell.modelEl.title='Model this conversation runs with: '+model+' · '+(value.profile || 'profile unknown');
    this.shell.setModelPicker([{label:'model',value:value.model || 'model unknown'},
      {label:'reasoning',value:value.reasoning || 'reasoning unknown'},
      {label:'profile',value:value.profile || 'profile unknown'},
      {label:'node',value:value.node_name || value.execution_node || 'local'},
      {label:'state',value:value.state || 'unknown'}], value.model || 'model unknown');
    this.querySelector('[data-action="cancel"]').disabled=!!value.settled || value.state==='unknown';
    this.querySelector('[data-action="steer"]').disabled=!!value.settled || value.state==='unknown';
    this.preview.textContent=[value.preview?.reasoning,value.preview?.commentary,value.preview?.text].filter(Boolean).join('\n');
    this.preview.hidden=!this.preview.textContent;
    // The pane's own run readout, for what the shared transcript cannot say while a child is working:
    // a child streams to the node rather than to this window, so the state and the preview come from
    // the poll. A settled child says nothing here - its `completed`/`unfinished`/`failed` footer and
    // its duration are drawn inside its own bubble by the shared renderer, which is where the
    // window's own chat says the same thing.
    this.statusLine.querySelector('.chat-content-run-label').textContent=value.preview?.status || value.state || 'unknown';
    this.statusLine.querySelector('.spinner').hidden=!!value.settled || value.state==='unknown';
    this.statusLine.hidden=!!value.settled || value.state==='unknown';
    // A child that has just finished is the one thing worth hearing while the reader is looking at
    // something else. The shell owns the sound; this is the pane's only call into it.
    if(previous && !previous.settled && value.settled)this.shell.notify();
    this.updateClock();
  }
  get task() { return this._task; }
}
customElements.define('wa-agent-session',WaAgentSession);

class WaOrchestrator extends HTMLElement {
  connectedCallback() {
    if(this.sidebar)return;
    // The live list comes first because it is the answer to "what is running": the dispatch table
    // below it holds the placement records, and a child with no placement record appears only here
    // (see the note the host writes into it, and app.js's liveChildRows).
    this.innerHTML='<header class="orchestrator-head"><strong>Orchestrator</strong><span class="orchestrator-status" role="status"></span><button type="button" data-action="refresh">Refresh</button><button type="button" data-action="close">Back to main chat</button></header><div class="orchestrator-body"><aside class="orchestrator-sidebar"><details class="live-children" open><summary>Live children</summary><p class="live-children-counts" role="status"></p><div class="live-children-list"></div><p class="live-children-foot"></p></details><details class="placement"><summary>Node order and limits</summary><p>Fill in order. A limit of 0 keeps a device out of background execution.</p><label><input type="checkbox" class="placement-enabled"> Use ordered placement</label><div class="placement-nodes"></div><button type="button" data-action="save-placement">Save placement</button></details><nav aria-label="Agents"></nav></aside><main class="orchestrator-canvas"><p class="orchestrator-empty">Agents appear here when delegated from the main chat. Select a card to follow its conversation.</p></main></div>';
    this.sidebar=this.querySelector('nav'); this.canvas=this.querySelector('main'); this.panes=new Map(); this.drafts=new Map();
    // Promoted conversations: each is a <wa-window> reading the same task as the pane it came from.
    this.windows=new Map();
    this.querySelectorAll('[data-action]').forEach(button=>button.addEventListener('click',()=>{
      this.dispatchEvent(new CustomEvent('orchestrator-action',{bubbles:true,detail:{action:button.dataset.action}}));
    }));
    this.addEventListener('agent-action',event=>{
      const {action,pane}=event.detail;
      if(action==='collapse')this.unpin(pane.dataset.key,pane);
      if(action==='expand')this.promote(pane);
    });
  }
  set message(text) { this.connectedCallback(); this.querySelector('.orchestrator-status').textContent=text; }
  // Every child the node reports as not settled, from either source, with the machine it runs on.
  //
  // `payload` is {rows, counts, note} from the host. The rows carry the state and the detail in the
  // node's own words, the node's name (never a bare id), and the session id - which is the handle a
  // reader needs, because a child with no dispatch record cannot be addressed by a subagent id at
  // all. A row that came from a dispatch record is clickable, because that is a child this node can
  // steer and cancel; a row that came from the ledger alone is not, and says so, rather than
  // offering a control that would fail.
  set live(payload) {
    this.connectedCallback();
    const rows=payload?.rows || [], counts=payload?.counts || '', note=payload?.note || '';
    this.liveRows=rows;
    this.querySelector('.live-children-counts').textContent=counts;
    this.querySelector('.live-children-foot').textContent=note;
    const list=this.querySelector('.live-children-list');
    if(!rows.length) {
      const empty=document.createElement('p'); empty.className='live-children-empty';
      empty.textContent='No child is running or unfinished that this node reports.';
      list.replaceChildren(empty);
      return;
    }
    list.replaceChildren(...rows.map(row=>{
      const element=document.createElement(row.task ? 'button' : 'div');
      if(row.task) element.type='button';
      element.className='live-child';
      element.dataset.state=row.state || 'unknown';
      element.dataset.session=row.session_id || '';
      element.dataset.node=row.node || '';
      element.dataset.source=row.source || '';
      if(row.subagent_id)element.dataset.subagent=row.subagent_id;
      const mission=document.createElement('span');mission.className='live-child-title';
      mission.textContent=row.title || row.session_id || 'Untitled child';
      mission.title=mission.textContent;
      const head=document.createElement('span');head.className='live-child-head';
      const state=document.createElement('span');state.className='live-child-state';state.textContent=row.state || 'unknown';
      const node=document.createElement('span');node.className='live-child-node';
      node.textContent=row.node_name || row.node || 'node unknown';
      node.title=(row.node_peer ? 'peer' : 'local')+' · '+row.node_source;
      head.append(state,node);
      const id=document.createElement('span');id.className='live-child-id';id.textContent=row.session_id || 'no session id';
      id.title='session id';
      element.append(head,mission,id);
      if(row.detail) { const detail=document.createElement('span');detail.className='live-child-detail';detail.textContent=row.detail; element.append(detail); }
      element.setAttribute('aria-label',`${mission.textContent} · ${state.textContent} on ${node.textContent} · ${id.textContent}`);
      if(row.task) element.addEventListener('click',()=>this.pin(row.task));
      return element;
    }));
  }
  // The window's agents, grouped by LANE.
  //
  // A lane is the checkout a child was given, and it is the unit a reader reasons about: one
  // worktree, the children working in it, and what is still owed on it. The lane travels on the task
  // (`task.lane`), read by the host from the session ledger, because what a lane *is* - a recorded
  // branch and worktree - is a fact about the node's records rather than about this element. A child
  // with no branch of its own is in the `main` lane, which is stated, not inferred.
  set data(tasks) {
    this.connectedCallback();
    // Follow-up tasks share a session. One card per conversation, newest run.
    const sessions=new Map();
    for(const task of tasks || []) {
      const key=(task.execution_node || 'local')+':'+(task.session_id || task.subagent_id);
      const old=sessions.get(key);
      if(!old || task.created_at>=old.created_at)sessions.set(key,task);
    }
    this.tasks=[...sessions.values()];
    const lanes=new Map();
    for(const task of this.tasks) this.groupByLane(lanes,task);
    this.sidebar.replaceChildren(...[...lanes.values()].map(group=>this.laneElement(group)));
    for(const task of this.tasks) {
      for(const pane of this.panes.values()) {
        if(pane.task.session_id && pane.task.session_id===task.session_id && pane.task.execution_node===task.execution_node) pane.task=task;
        else if(pane.task.subagent_id===task.subagent_id)pane.task=task;
      }
    }
  }
  groupByLane(lanes,task) {
    const lane=task.lane || {key:'no recorded checkout',label:'no recorded checkout',checklist:[]};
    const group=lanes.get(lane.key) || {lane,tasks:[]};
    group.tasks.push(task);
    lanes.set(lane.key,group);
  }
  // One lane: its key, the children it holds, and its end-state checklist. Every entry is a
  // measurement or an explicit `unknown` carrying the host's reason (`task.lane.checklist`) - a lane
  // drawn as merged and clean when nobody could read its checkout is the mistake that list exists to
  // prevent, so the three states a reader can act on (`yes`, `no`, `unknown`) are attributes of the
  // row rather than words this element invents.
  laneElement(group) {
    const lane=group.lane;
    const section=document.createElement('section');
    section.className='lane';
    section.dataset.lane=lane.key;
    const head=document.createElement('header');head.className='lane-head';
    const key=document.createElement('span');key.className='lane-key';
    key.textContent=lane.label || lane.key;key.title=key.textContent;
    const count=document.createElement('span');count.className='lane-count';
    count.textContent=group.tasks.length+(group.tasks.length===1 ? ' child' : ' children');
    head.append(key,count);
    if(lane.worktree) {
      const path=document.createElement('span');path.className='lane-path';
      path.textContent=lane.worktree;path.title=lane.worktree;
      head.append(path);
    }
    section.append(head);
    const children=document.createElement('div');children.className='lane-children';
    for(const task of group.tasks) children.append(this.cardElement(task));
    section.append(children);
    const checklist=document.createElement('ul');checklist.className='lane-checklist';
    for(const item of lane.checklist || []) {
      const row=document.createElement('li');row.className='lane-check';
      row.dataset.outcome=item.outcome;row.dataset.state=item.state;
      const name=document.createElement('span');name.className='lane-check-name';name.textContent=item.outcome;
      const state=document.createElement('span');state.className='lane-check-state';state.textContent=item.state;
      row.append(name,state);
      row.title=[item.outcome,item.state,item.detail].filter(Boolean).join(' · ');
      checklist.append(row);
    }
    section.append(checklist);
    return section;
  }
  cardElement(task) {
    const card=document.createElement('button'); card.type='button'; card.className='agent-card';
    const state=task.state || 'unknown';
    card.dataset.state=state;
    const mission=document.createElement('span');mission.className='agent-card-mission';
    mission.textContent=agentTaskTitle(task);
    mission.title=mission.textContent;
    const details=document.createElement('span');details.className='agent-card-details';
    const model=document.createElement('span');model.className='agent-card-model';model.textContent=[task.model || 'model unknown',task.reasoning || 'reasoning unknown'].join(' · ');
    const status=document.createElement('span');status.className='agent-card-status';status.textContent=state;
    details.append(model,status);card.append(mission,details);
    card.setAttribute('aria-label',`${mission.textContent} · ${model.textContent} · ${state}`);
    card.addEventListener('click',()=>this.pin(task));
    return card;
  }
  // A pane must say which machine it is reading, by name. The task travels unchanged apart from that
  // one display field, so nothing downstream (steer, cancel, the model strip) sees a different task.
  named(task) {
    if(!task || !this.nodeNames) return task;
    const name=this.nodeNames.get(task.execution_node || 'local');
    return name ? {...task,node_name:name} : task;
  }
  pin(task) {
    task=this.named(task);
    const existing=[...this.panes.values()].find(pane=>pane.task.subagent_id===task.subagent_id ||
      (task.session_id && pane.task.session_id===task.session_id && pane.task.execution_node===task.execution_node));
    if(existing) { existing.input.focus(); return existing; }
    const pane=document.createElement('wa-agent-session');
    const key=task.subagent_id; pane.dataset.key=key; pane.task=task;
    pane.input.value=this.drafts.get(key) || '';
    this.panes.set(key,pane); this.canvas.append(pane); this.layout();
    this.dispatchEvent(new CustomEvent('orchestrator-action',{bubbles:true,detail:{action:'layout'}}));
    return pane;
  }
  // Every conversation this workspace is following: the tiled panes and the promoted windows. A host
  // refreshes through here, so a promoted window is a reader of the same task rather than a snapshot
  // of what it looked like when it was opened.
  allPanes() { return [...this.panes.values(),...[...this.windows.values()].map(entry=>entry.pane)]; }
  // Expand promotes a conversation into its own <wa-window>: a frame the reader can move, resize and
  // close, with the same task and its own chat shell inside. The workspace pane stays where it was,
  // and says what happened, because nothing moves out from under the pointer unannounced (DESIGN.md §3).
  promote(pane) {
    const key=pane.dataset.key;
    const existing=this.windows.get(key);
    if(existing) { existing.window.open=true; return existing.pane; }
    const frame=document.createElement('wa-window');
    frame.setAttribute('name','agent-'+key);
    document.body.append(frame);
    const promoted=document.createElement('wa-agent-session');
    promoted.dataset.key=key;
    promoted.promoted=true;
    frame.append(promoted);
    if(pane.task)promoted.task=this.named(pane.task);
    frame.title=agentTaskTitle(pane.task);
    frame.open=true;
    frame.addEventListener('close',()=>{
      this.windows.delete(key);
      this.dispatchEvent(new CustomEvent('orchestrator-action',{bubbles:true,detail:{action:'layout'}}));
    });
    this.windows.set(key,{window:frame,pane:promoted});
    if(pane.notice)pane.notice.textContent='Open in its own window.';
    // The host refreshes panes when the layout changes, which is how the promoted frame gets the
    // conversation without this component ever fetching anything itself.
    this.dispatchEvent(new CustomEvent('orchestrator-action',{bubbles:true,detail:{action:'layout'}}));
    return promoted;
  }
  unpin(key,pane) {
    // Closing a promoted frame closes the frame - the workspace pane it came from is not the panel
    // the reader clicked the x on.
    const promoted=this.windows.get(key);
    if(promoted && pane===promoted.pane) { promoted.window.close(); return; }
    const tiled=this.panes.get(key);
    if(tiled)this.drafts.set(tiled.task.subagent_id,tiled.input.value);
    tiled?.remove(); this.panes.delete(key); this.layout();
    this.dispatchEvent(new CustomEvent('orchestrator-action',{bubbles:true,detail:{action:'layout'}}));
  }
  layout() {
    this.querySelector('.orchestrator-empty').hidden=this.panes.size>0;
    this.canvas.dataset.count=String(this.panes.size);
  }
  configure(fleet) {
    if(this.configured)return;
    this.configured=true; this.querySelector('.placement-enabled').checked=!!fleet.policy?.enabled;
    // The machine a child runs on is a name, not an id: a peer's 32-hex id told a reader nothing.
    // Kept here so a pane that this panel opens can name its node too.
    this.nodeNames=new Map([['local',(fleet.nodes||[]).find(node=>node.local_node)?.name || 'local']]);
    for(const node of fleet.nodes || []) { this.nodeNames.set(node.node_id || node.id,node.name); if(node.id)this.nodeNames.set(node.id,node.name); }
    const selected=fleet.policy?.nodes || [];
    const nodes=selected.map(item=>({...item,name:fleet.nodes?.find(n=>n.node_id===item.node)?.name || item.node}));
    for(const node of fleet.nodes || []) {
      const id=node.local_node ? 'local' : node.node_id;
      if(!nodes.some(item=>item.node===id))nodes.push({node:id,name:node.name,max_tasks:0});
    }
    const container=this.querySelector('.placement-nodes');
    for(const node of nodes) {
      const row=document.createElement('div'); row.className='placement-node'; row.dataset.node=node.node;
      const label=document.createElement('label'); label.textContent=node.name+' ';
      const input=document.createElement('input');input.type='number';input.min='0';input.max='128';input.step='1';input.value=node.max_tasks;
      input.setAttribute('aria-label',node.name+' task limit'); label.append(input);
      const up=document.createElement('button');up.type='button';up.textContent='↑';up.title='Higher priority';
      const down=document.createElement('button');down.type='button';down.textContent='↓';down.title='Lower priority';
      up.onclick=()=>{if(row.previousElementSibling)container.insertBefore(row,row.previousElementSibling);};
      down.onclick=()=>{if(row.nextElementSibling)container.insertBefore(row.nextElementSibling,row);};
      row.append(label,up,down);container.append(row);
    }
  }
  get policy() {
    return {enabled:this.querySelector('.placement-enabled').checked,nodes:[...this.querySelectorAll('.placement-node')].map(row=>({node:row.dataset.node,max_tasks:Number(row.querySelector('input').value)}))};
  }
}
customElements.define('wa-orchestrator',WaOrchestrator);
