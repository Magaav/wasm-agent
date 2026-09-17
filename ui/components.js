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
// Item shape: { label, action, danger?, separator? }.
class WaMenu extends WaOverlay {
  constructor() {
    super();
    this.items = [];
    this.classList.add("menu");
  }

  openAt(x, y) {
    this.render();
    this.style.left = "0px";
    this.style.top = "0px";
    this.show();
    const rect = this.getBoundingClientRect();
    const maxX = window.innerWidth - rect.width - 5;
    const maxY = window.innerHeight - rect.height - 5;
    this.style.left = Math.max(5, Math.min(x, maxX)) + "px";
    this.style.top = Math.max(5, Math.min(y, maxY)) + "px";
  }

  render() {
    this.replaceChildren();
    for (const item of this.items) {
      if (item.separator) {
        const line = document.createElement("div");
        line.className = "menu-sep";
        this.append(line);
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
    this.open = !this.open;
    this.dispatchEvent(new CustomEvent("toggle", { bubbles: true }));
  }

  // addTool(name, title) -> the line element, so the caller can fill the outcome.
  addTool(name, title, detail) {
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
}
customElements.define("wa-trace", WaTrace);

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
