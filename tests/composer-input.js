// Exercises the paste and drop handlers in ui/app.js against a stubbed DOM.
//
// No jsdom: the repo has no node_modules and adding one to a Lua/Rust project
// for a UI test is a poor trade. The stub implements only what app.js touches,
// so if app.js starts using a new DOM API this test fails loudly instead of
// silently testing nothing.
const fs = require("fs");
const vm = require("vm");

let failures = 0;
const check = (condition, label) => {
  console.log((condition ? "ok   " : "FAIL ") + label);
  if (!condition) failures++;
};

// ---- minimal DOM ---------------------------------------------------------
class El {
  constructor(tag = "div", id = "") {
    this.tagName = tag.toUpperCase();
    this.id = id;
    this.children = [];
    this.listeners = {};
    this.classList = {
      _set: new Set(),
      add(c) { this._set.add(c); },
      remove(c) { this._set.delete(c); },
      contains(c) { return this._set.has(c); },
      toggle(c, force) {
        const on = force === undefined ? !this._set.has(c) : force;
        if (on) this._set.add(c); else this._set.delete(c);
        return on;
      },
    };
    this.value = "";
    this.files = [];
    this.textContent = "";
    this.className = "";
    this.style = {};
    this.width = 0;
    this.height = 0;
  }
  getContext() { return { drawImage: () => {}, clearRect: () => {}, putImageData: () => {}, createImageData: () => ({ data: [] }), setTransform: () => {}, scale: () => {}, fillRect: () => {} }; }
  getBoundingClientRect() { return { top: 0, left: 0, right: 0, bottom: 0, width: 100, height: 100 }; }
  toDataURL() { return "data:image/png;base64,"; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  removeEventListener() {}
  remove() {}
  append(...nodes) { this.children.push(...nodes); }
  replaceChildren() { this.children = []; }
  setAttribute() {}
  getAttribute() { return null; }
  querySelector() { return null; }
  requestSubmit() { this.submitted = true; }
  focus() {}
  async fire(type, event = {}) {
    for (const fn of this.listeners[type] || []) await fn(event);
  }
}

const registry = new Map();
// `wa-menu` is a custom element app.js opens and closes; a bare div has no `close`, so the stub
// models the overlay contract for the ids index.html declares as menus.
class WaMenuStub extends El {
  constructor(id) {
    super("wa-menu", id);
    this.open = false;
    this.items = [];
  }
  show() { this.open = true; }
  close() { this.open = false; }
  toggle() { if (this.open) this.close(); else this.show(); }
  openAt() { this.open = true; }
  move() {}
  activate() { return false; }
}
const MENU_IDS = new Set(["user-menu", "context-menu", "command-menu"]);
const byId = (id) => {
  if (!registry.has(id)) registry.set(id, MENU_IDS.has(id) ? new WaMenuStub(id) : new El("div", id));
  return registry.get(id);
};

const documentStub = {
  getElementById: byId,
  createElement: (tag) => new El(tag),
  addEventListener: () => {},
  querySelector: () => null,
  querySelectorAll: () => [],
  body: new El("body"),
  documentElement: new El("html"),
};

// ---- file / reader stubs -------------------------------------------------
class FileStub {
  constructor(parts, name, options = {}) {
    this.name = name;
    this.type = options.type || "";
    this._data = parts.join("");
    this.size = this._data.length;
  }
  async text() { return this._data; }
}

// FileReader delivers the data URL asynchronously, as the browser does; a
// synchronous stub would let a missing await pass unnoticed.
class FileReaderStub {
  readAsDataURL(file) {
    setTimeout(() => {
      this.result = `data:${file.type};base64,` + Buffer.from(file._data).toString("base64");
      this.onload && this.onload();
    }, 0);
  }
}

// ---- sandbox -------------------------------------------------------------
const source = fs.readFileSync("ui/app.js", "utf8");
const sandbox = {
  document: documentStub,
  window: { addEventListener: () => {}, location: { reload: () => {} } },
  File: FileStub,
  FileReader: FileReaderStub,
  setTimeout,
  clearTimeout,
  console,
  // A real Response: app.js awaits .json()/.text() and the wasm renderer wants
  // an actual Response instance, not an object with the same methods.
  fetch: async () => new Response("{}", { status: 200, headers: { "content-type": "application/json" } }),
  Response,
  AbortController,
  EventSource: class { addEventListener() {} close() {} },
  localStorage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
  navigator: { clipboard: { writeText: async () => {} } },
  requestAnimationFrame: (fn) => setTimeout(fn, 0),
  setInterval: () => 0,
  clearInterval: () => {},
  URL: { createObjectURL: () => "blob:x", revokeObjectURL: () => {} },
};
sandbox.globalThis = sandbox;

// app.js declares `attachments` with const at top level; a vm const does not
// become a property of the context, so read it back by evaluating the name.
vm.createContext(sandbox);
try {
  vm.runInContext(source, sandbox, { filename: "ui/app.js" });
  check(true, "app.js loads in the stubbed DOM");
} catch (error) {
  check(false, "app.js loads in the stubbed DOM: " + error.message);
  console.log("---"); console.log(failures + " FAILURE(S)"); process.exit(1);
}

const attachments = vm.runInContext("attachments", sandbox);

const input = byId("input");
const panel = byId("panel");
const fileInput = byId("file");

const png = (name = "shot.png") =>
  new FileStub([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x01])], name, { type: "image/png" });

const settle = () => new Promise((resolve) => setTimeout(resolve, 5));

(async () => {
  // ---- paste an image ----------------------------------------------------
  attachments.length = 0;
  await input.fire("paste", {
    clipboardData: { items: [{ kind: "file", getAsFile: () => png("image.png") }] },
    preventDefault() { this.defaulted = true; },
  });
  await settle();
  check(attachments.length === 1, "paste attaches one image");
  check(attachments[0] && attachments[0].kind === "image", "the pasted item is an image");
  check(/^pasted\./.test(attachments[0].name), "an unnamed clipboard image gets a name: " + (attachments[0] && attachments[0].name));
  check((attachments[0].data || "").startsWith("data:image/png;base64,"), "the pasted image is a png data URL");

  // ---- paste plain text must NOT be intercepted ---------------------------
  attachments.length = 0;
  let prevented = false;
  await input.fire("paste", {
    clipboardData: { items: [{ kind: "string", getAsFile: () => null }] },
    preventDefault() { prevented = true; },
  });
  await settle();
  check(attachments.length === 0, "a plain-text paste attaches nothing");
  check(!prevented, "a plain-text paste is not preventDefault'd (text still pastes)");

  // ---- drop a file -------------------------------------------------------
  attachments.length = 0;
  const dropped = png("dropped.png");
  await panel.fire("drop", {
    dataTransfer: { types: ["Files"], files: [dropped], dropEffect: "" },
    preventDefault() { this.defaulted = true; },
  });
  await settle();
  check(attachments.length === 1, "drop attaches one file");
  check(attachments[0].name === "dropped.png", "the dropped file keeps its name");

  // ---- dragover must preventDefault, or the browser cancels the drop -----
  let overPrevented = false;
  await panel.fire("dragover", {
    dataTransfer: { types: ["Files"], files: [], dropEffect: "" },
    preventDefault() { overPrevented = true; },
  });
  check(overPrevented, "dragover preventDefault is called (else the drop never fires)");

  // ---- dropping selected text must be ignored ----------------------------
  attachments.length = 0;
  await panel.fire("drop", {
    dataTransfer: { types: ["text/plain"], files: [], dropEffect: "" },
    preventDefault() { this.defaulted = true; },
  });
  await settle();
  check(attachments.length === 0, "dropping text/plain attaches nothing");

  // ---- the drop outline appears and clears -------------------------------
  await panel.fire("dragenter", { dataTransfer: { types: ["Files"] }, preventDefault() {} });
  check(panel.classList.contains("dropping"), "dragenter shows the drop outline");
  await panel.fire("drop", {
    dataTransfer: { types: ["Files"], files: [png()], dropEffect: "" },
    preventDefault() {},
  });
  await settle();
  check(!panel.classList.contains("dropping"), "the outline clears after the drop");

  // ---- an unsupported image type is refused, visibly ---------------------
  attachments.length = 0;
  const bmp = new FileStub([Buffer.from("BM")], "old.bmp", { type: "image/bmp" });
  await panel.fire("drop", {
    dataTransfer: { types: ["Files"], files: [bmp], dropEffect: "" },
    preventDefault() {},
  });
  await settle();
  check(attachments.length === 0, "a bmp is not attached");
  // Assert the real status text, not a grep of the source: the point is that the
  // refusal is *visible*, so the test must read what the user would see.
  const statusLine = vm.runInContext("statusLine", sandbox);
  const shown = statusLine ? String(statusLine.innerHTML) : "";
  check(/skipped/.test(shown) && /png/.test(shown), "the refusal is shown to the user: " + shown.slice(0, 80));
  // Regression: the drop handler used to setStatus("N file(s) attached") after
  // addFiles, which overwrote a refusal with a success message. A rejected file
  // reported as attached is the silent-success defect this project forbids.
  check(!/attached - press Enter/.test(shown), "a refusal is NOT overwritten by a success message");

  // A refusal alongside a good file must still report the refusal.
  attachments.length = 0;
  await panel.fire("drop", {
    dataTransfer: { types: ["Files"], files: [png("good.png"), bmp], dropEffect: "" },
    preventDefault() {},
  });
  await settle();
  check(attachments.length === 1, "the good file in a mixed drop is attached");
  const mixedStatus = String(vm.runInContext("statusLine", sandbox).innerHTML);
  check(/skipped/.test(mixedStatus), "the mixed drop still reports the skipped one: " + mixedStatus.slice(0, 70));

  // ---- the attach button still works (shared path) -----------------------
  attachments.length = 0;
  fileInput.files = [png("via-button.png")];
  await fileInput.fire("change", {});
  await settle();
  check(attachments.length === 1, "the attach button still attaches (same addFiles path)");
  check(fileInput.value === "", "the file input is cleared so the same file can be re-picked");

  // ---- undo / redo -------------------------------------------------------
  //
  // These drive the *keyboard*, which is the only control the draft has: the two footer
  // buttons were removed when the diff topic took the one toggle in the transcript (they
  // acted on the draft while sitting where a reader looks for "undo the last change").
  // What used to be asserted as `button.disabled` is now asserted on the stacks, which is
  // the same fact - "is there anything to undo" - read from the state rather than a widget.
  const form = byId("composer");
  const press = (key, extra = {}) => input.fire("keydown",
    Object.assign({ key, ctrlKey: true, shiftKey: false, preventDefault() {} }, extra));
  const canUndo = () => vm.runInContext("draftUndo.length > 0", sandbox);
  const canRedo = () => vm.runInContext("draftRedo.length > 0", sandbox);

  // Start from a known state: the drop/paste tests above have already pushed
  // steps, so asserting "nothing to undo" before clearing them would be
  // asserting something about the previous test, not about undo.
  const resetHistory = () => vm.runInContext(
    "draftUndo.length = 0; draftRedo.length = 0; draftNow = { text: input.value, attachments: attachments.slice() }; syncUndoButtons();",
    sandbox,
  );

  attachments.length = 0;
  input.value = "";
  resetHistory();
  check(canUndo() === false, "there is nothing to undo to start with");
  check(canRedo() === false, "and nothing to redo");

  // Undoing a drop.
  fileInput.files = [png("undo-me.png")];
  await fileInput.fire("change", {});
  await settle();
  check(attachments.length === 1, "a file is attached before undoing");
  check(canUndo() === true, "a step makes undo possible");

  await press("z");
  check(attachments.length === 0, "undo removes the dropped file");
  check(canRedo() === true, "redo becomes possible after an undo");
  await press("z", { shiftKey: true });
  check(attachments.length === 1, "redo puts the dropped file back");
  check(attachments[0].name === "undo-me.png", "redo restores the same file");

  // Undoing typed text, and that a new edit kills the redo branch.
  resetHistory();
  input.value = "first";
  await input.fire("input", {});
  vm.runInContext("typingTimer = null;", sandbox);
  input.value = "first second";
  await input.fire("input", {});
  vm.runInContext("typingTimer = null;", sandbox);
  await press("z");
  check(input.value === "first", "undo reverts one typing step, not one character: " + JSON.stringify(input.value));
  input.value = "something else";
  await input.fire("input", {});
  vm.runInContext("typingTimer = null;", sandbox);
  check(canRedo() === false, "a fresh edit clears the redo branch");

  // Ctrl+Z / Ctrl+Shift+Z on the textarea.
  resetHistory();
  input.value = "alpha";
  await input.fire("input", {});
  vm.runInContext("typingTimer = null;", sandbox);
  input.value = "alpha beta";
  await input.fire("input", {});
  vm.runInContext("typingTimer = null;", sandbox);
  let keyPrevented = false;
  await input.fire("keydown", { key: "z", ctrlKey: true, shiftKey: false, preventDefault() { keyPrevented = true; } });
  check(input.value === "alpha", "Ctrl+Z undoes (keyboard path)");
  check(keyPrevented, "Ctrl+Z preventDefault is called (no browser undo fight)");
  await input.fire("keydown", { key: "z", ctrlKey: true, shiftKey: true, preventDefault() {} });
  check(input.value === "alpha beta", "Ctrl+Shift+Z redoes (keyboard path)");
  // Ctrl+Y is the third spelling of *redo*. After that redo there is nothing
  // left to redo, so the correct behaviour is a no-op - and asserting an undo
  // here would have encoded a wrong expectation, not found a bug.
  await input.fire("keydown", { key: "y", ctrlKey: true, shiftKey: false, preventDefault() {} });
  check(input.value === "alpha beta", "Ctrl+Y is a no-op with an empty redo stack");
  await input.fire("keydown", { key: "z", ctrlKey: true, shiftKey: false, preventDefault() {} });
  check(input.value === "alpha", "Ctrl+Z undoes again after the redo");
  await input.fire("keydown", { key: "y", ctrlKey: true, shiftKey: false, preventDefault() {} });
  check(input.value === "alpha beta", "Ctrl+Y redoes once there is something to redo");

  // Plain typing must NOT be intercepted, or Enter-to-send breaks.
  let plainPrevented = false;
  await input.fire("keydown", { key: "a", ctrlKey: false, shiftKey: false, preventDefault() { plainPrevented = true; } });
  check(!plainPrevented, "an ordinary keypress is not preventDefault'd");

  // Sending clears the stack: an undone draft must not be resendable.
  resetHistory();
  input.value = "send me";
  await input.fire("input", {});
  vm.runInContext("typingTimer = null;", sandbox);
  await form.fire("submit", { preventDefault() {} });
  check(input.value === "", "a send clears the input");
  check(canUndo() === false, "a send clears undo (an already-sent draft must not come back)");
  check(canRedo() === false, "a send clears redo");

  console.log("---");
  console.log(failures === 0 ? "ALL PASS" : failures + " FAILURE(S)");
  process.exit(failures === 0 ? 0 : 1);
})();
