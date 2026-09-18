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

  render() {
    this.replaceChildren();
    for (const item of this.items) {
      if (item.element) {
        this.append(item.element);
        continue;
      }
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
    event.target.setPointerCapture?.(event.pointerId);
    document.addEventListener("pointermove", this._onMove);
    document.addEventListener("pointerup", this._onUp);
  }

  _startResize(event, edge) {
    if (event.button !== 0) return;
    event.preventDefault();
    this._resize = { pointerId: event.pointerId, edge, geometry: this._geometry(), x: event.clientX, y: event.clientY };
    event.target.setPointerCapture?.(event.pointerId);
    document.addEventListener("pointermove", this._onMove);
    document.addEventListener("pointerup", this._onUp);
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
