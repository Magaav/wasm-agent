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
  connectedCallback() {
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

  get body() { return this._body; }
}
customElements.define("wa-message", WaMessage);

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
