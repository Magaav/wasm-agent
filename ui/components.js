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
    this._pressInside = WaOverlay._within(this, event.target)
      || WaOverlay._within(this.anchor, event.target);
  }

  _onUp() {
    if (!this.open) return;
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

// <wa-trace> — one decision's tool activity, collapsed into a topic.
//
// The transcript should read as decisions, not as a wall of tool payloads: the
// header says what happened (how many calls, which tools, how long) and the body
// holds the sequential tool lines, hidden until the reader opens it. Failures are
// the exception - an error opens the topic, because a silent failure is worse
// than a noisy transcript (DESIGN.md).
class WaTrace extends HTMLElement {
  static get observedAttributes() { return ["open"]; }

  constructor() {
    super();
    this._lines = new Map();
    this._pending = null;
    this._count = 0;
    this._errors = 0;
    this._started = Date.now();
  }

  connectedCallback() {
    if (this._built) return;
    this._built = true;
    this.classList.add("trace");

    this._header = document.createElement("button");
    this._header.type = "button";
    this._header.className = "trace-head";
    this._header.setAttribute("aria-expanded", "false");
    this._glyph = document.createElement("span");
    this._glyph.className = "trace-glyph";
    this._glyph.textContent = "\u2699";
    this._label = document.createElement("span");
    this._label.className = "trace-label";
    this._label.textContent = "working…";
    this._meta = document.createElement("span");
    this._meta.className = "trace-meta";
    this._chevron = document.createElement("span");
    this._chevron.className = "trace-chevron";
    this._chevron.textContent = "\u203a";
    this._header.append(this._glyph, this._label, this._meta, this._chevron);

    this._body = document.createElement("ol");
    this._body.className = "trace-body";
    this._body.hidden = true;

    this._header.addEventListener("click", () => this.toggle());
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

  // addTool(name, title) -> the line element, so the caller can fill the outcome.
  addTool(name, title, detail) {
    if (!this._userToggled) this.open = true;   // live: show the lines, not a count
    this._count += 1;
    const line = document.createElement("li");
    line.className = "tool-line pending";
    const head = document.createElement("div");
    head.className = "tool-head";
    const label = document.createElement("span");
    label.className = "tool-title";
    label.innerHTML = `<b>${name}</b> ${title}`;
    const outcome = document.createElement("span");
    outcome.className = "tool-outcome";
    head.append(label, outcome);
    line.append(head);
    const output = document.createElement("div");
    output.className = "tool-output";
    output.hidden = true;
    if (detail) output.textContent = detail;
    line.append(output);
    this._lines.set(name, line);
    this._pending = { line, output, outcome };
    this._body.append(line);
    this._header.classList.add("running");
    this._refresh();
    return line;
  }

  // settle(outcome, detail, failed) finishes the most recent tool line.
  settle(outcome, detail, failed) {
    const target = this._pending;
    if (!target) return;
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
    this._pending = null;
    this._refresh();
  }

  finish() {
    this._header.classList.remove("running");
    this._done = true;
    if (!this._userToggled) this.open = false;   // the decision is over: fold it away
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

// <wa-run> — the whole turn's path, collapsed to one line at the top of the
// reply. A finished reply should read as an answer; how it got there (which
// decisions, which tools) is one click away instead of pushing the answer off
// the screen.
class WaRun extends HTMLElement {
  static get observedAttributes() { return ["open"]; }

  connectedCallback() { this._build(); }

  _build() {
    if (this._body) return;
    this.classList.add("run");
    this._header = document.createElement("button");
    this._header.type = "button";
    this._header.className = "trace-head";
    this._glyph = document.createElement("span");
    this._glyph.className = "trace-glyph";
    this._glyph.textContent = "\u2699";
    this._label = document.createElement("span");
    this._label.className = "trace-label";
    this._label.textContent = "run";
    this._meta = document.createElement("span");
    this._meta.className = "trace-meta";
    this._chevron = document.createElement("span");
    this._chevron.className = "trace-chevron";
    this._chevron.textContent = "\u203a";
    this._header.append(this._glyph, this._label, this._meta, this._chevron);
    this._body = document.createElement("div");
    this._body.className = "run-body";
    this._body.hidden = true;
    this._header.addEventListener("click", () => this.toggle());
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
    this._chevron.textContent = this.open ? "\u2304" : "\u203a";
  }

  toggle() { this.open = !this.open; }

  setSummary(decisions, calls, ms) {
    this._build();
    const seconds = ms >= 1000 ? (ms / 1000).toFixed(1) + "s" : ms + "ms";
    const parts = [];
    if (decisions > 0) parts.push(decisions + (decisions === 1 ? " decision" : " decisions"));
    parts.push(calls + (calls === 1 ? " tool call" : " tool calls"));
    this._label.textContent = "run";
    this._meta.textContent = parts.join(" · ") + " · " + seconds;
  }
}
customElements.define("wa-run", WaRun);

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

// <wa-diff> — what the turn changed on disk, collapsed to one line after the answer.
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
// <wa-diff> — what the turn changed on disk, collapsed *below* the answer.
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
    this.classList.add("diff");

    this._row = document.createElement("div");
    this._row.className = "diff-row";

    // The header is the real topic header: one button, exactly as <wa-run> builds it.
    this._header = document.createElement("button");
    this._header.type = "button";
    this._header.className = "trace-head";
    this._header.setAttribute("aria-expanded", "false");
    this._glyph = document.createElement("span");
    this._glyph.className = "trace-glyph";
    this._glyph.textContent = "\u0394";
    this._label = document.createElement("span");
    this._label.className = "trace-label";
    this._label.textContent = "changes";
    this._meta = document.createElement("span");
    this._meta.className = "trace-meta";
    this._chevron = document.createElement("span");
    this._chevron.className = "trace-chevron";
    this._chevron.textContent = "\u203a";
    this._header.append(this._glyph, this._label, this._meta, this._chevron);

    this._toggle = document.createElement("button");
    this._toggle.type = "button";
    this._toggle.className = "diff-toggle";
    this._toggle.disabled = true;

    this._row.append(this._header, this._toggle);

    this._body = document.createElement("ul");
    this._body.className = "diff-body";
    this._body.hidden = true;

    this._header.addEventListener("click", () => this.toggle());
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
    this._chevron.textContent = this.open ? "\u2304" : "\u203a";
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
    // Turns recorded before the recorder merged repeats hold one entry per write, and those turns are
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
      // diff itself is not in the transcript (the turn carries addresses, not bodies), so this click is
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
      // More than one write to the same file in one turn: one change, and the reader is told how it was
      // recorded rather than being shown the same path twice.
      if (file.writes > 1) {
        const tag = document.createElement("span");
        tag.className = "diff-tag";
        tag.textContent = "\u00d7" + file.writes;
        tag.title = "this file was written " + file.writes + " times in this turn";
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
  // since the turn). Until it says so the toggle stays disabled, so a click can never
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
      ['turn wall time p50 / p95',`${ms(report.turn_p50_ms)} / ${ms(report.turn_p95_ms)}`],
      ['inference / summary time',`${ms(i.ms)} / ${ms(c.ms)}`],
      ['tools / failed',`${n(report.tool_calls)} / ${n(report.tool_failures)}`],
      ['tool time',ms(report.tool_ms)],
      ['repeated tool arguments',`${n(report.repeated_tools)} (signal, not proof of waste)`],
      ['recorded turns / incomplete',`${n(report.turns)} / ${n(report.incomplete_turns)}`],
      ['starts without ends',`${n(report.pending)} (running or interrupted)`],
    ]);
    const ctx=report.context || {}, compact=report.last_compaction || {};
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
    ]);
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
