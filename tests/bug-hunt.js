// Bug hunt: cross-feature interactions the suite does not cover.
//
// Each check states a hypothesis about ui/app.js. Two verdicts, kept apart on purpose:
//
//   FAIL   the app did not do what the hypothesis says
//   STUB   the harness could not test the hypothesis - its own model of the DOM is
//          missing something. That is not a finding about the app, and it is not a
//          pass either; it is the harness admitting its own gap.
//
// Waiting is on the app's own state (`busy`), never on a fixed sleep. The first
// version of this file slept 5ms and then asserted; a send still running from the
// previous scenario cleared `attachments` in the middle of the next one, which read
// as five app bugs and a crash. None of them were the app's. A FAIL here is only
// worth reading because the waits are on conditions.
const fs = require("fs");
const vm = require("vm");

let failures = 0;
let stubProblems = 0;
const check = (condition, label) => {
  console.log((condition ? "ok   " : "FAIL ") + label);
  if (!condition) failures++;
};
const stub = (condition, label) => {
  console.log((condition ? "stub ok " : "STUB ") + label);
  if (!condition) stubProblems++;
};

class El {
  constructor(tag = "div", id = "") {
    this.tagName = tag.toUpperCase(); this.id = id; this.children = [];
    this.listeners = {}; this.value = ""; this.files = []; this.textContent = "";
    this.className = ""; this.style = {}; this.width = 0; this.height = 0;
    this.disabled = false;
    this.classList = {
      _set: new Set(),
      add(c) { this._set.add(c); }, remove(c) { this._set.delete(c); },
      contains(c) { return this._set.has(c); },
      toggle(c, force) { const on = force === undefined ? !this._set.has(c) : force; if (on) this._set.add(c); else this._set.delete(c); return on; },
    };
  }
  getContext() { return { drawImage(){}, clearRect(){}, putImageData(){}, createImageData: () => ({ data: [] }), setTransform(){}, scale(){}, fillRect(){} }; }
  getBoundingClientRect() { return { top:0,left:0,right:0,bottom:0,width:100,height:100 }; }
  toDataURL() { return "data:image/png;base64,"; }
  addEventListener(t, f) { (this.listeners[t] ||= []).push(f); }
  removeEventListener() {}
  remove() {}
  append(...n) { this.children.push(...n); }
  replaceChildren() { this.children = []; }
  setAttribute() {} getAttribute() { return null; } querySelector() { return null; }
  requestSubmit() { this.submitted = true; } focus() {}
  async fire(type, event = {}) { for (const fn of this.listeners[type] || []) await fn(event); }
}
const reg = new Map();
const byId = (id) => {
  if (!reg.has(id)) reg.set(id, MENU_IDS.has(id) ? new WaMenuStub(id) : new El("div", id));
  return reg.get(id);
};

// wa-message is a custom element from components.js that builds .body when it is
// appended. The stub models just that much, because app.js writes into .body and a
// bare div would not have one.
class WaMessageStub extends El {
  constructor() {
    super("wa-message");
    this.body = new El("div");
  }
}

// wa-menu is the other custom element app.js talks to, and the stub was missing it: every id came
// back as a bare div, so `commandMenu.close()` on submit was a TypeError here while the real page -
// which declares `<wa-menu id="command-menu">` - was fine. The stub models the overlay contract
// (open/show/close, and the keyboard entry points), because app.js is entitled to call them and a
// harness that cannot run the code it is testing proves nothing about it.
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
const documentStub = {
  getElementById: byId,
  createElement: (t) => (String(t).toLowerCase() === "wa-message" ? new WaMessageStub() : new El(t)),
  addEventListener(){},
  querySelector: () => null, querySelectorAll: () => [], body: new El("body"), documentElement: new El("html"),
};
class FileStub {
  constructor(parts, name, options = {}) { this.name = name; this.type = options.type || ""; this._data = parts.join(""); this.size = this._data.length; }
  async text() { return this._data; }
}
class FileReaderStub {
  readAsDataURL(file) { setTimeout(() => { this.result = `data:${file.type};base64,` + Buffer.from(file._data).toString("base64"); this.onload && this.onload(); }, 0); }
}

const source = fs.readFileSync("ui/app.js", "utf8");
const sandbox = {
  document: documentStub,
  window: { addEventListener(){}, location: { reload(){} } },
  File: FileStub, FileReader: FileReaderStub, setTimeout, clearTimeout, console,
  // A real fetch stub, not a JSON one: app.js asks for render.wasm at startup, and
  // answering it with `{}` made the renderer log a WebAssembly error - noise that
  // looks like a failure in a harness whose job is to report failures.
  fetch: async (url) => String(url).includes("render.wasm")
    ? new Response(null, { status: 404 })
    : new Response("{}", { status: 200, headers: { "content-type": "application/json" } }),
  Response, AbortController,
  EventSource: class { addEventListener(){} close(){} },
  localStorage: { getItem: () => null, setItem(){}, removeItem(){} },
  navigator: { clipboard: { writeText: async () => {} } },
  requestAnimationFrame: (fn) => setTimeout(fn, 0), setInterval: () => 0, clearInterval(){},
  URL: { createObjectURL: () => "blob:x", revokeObjectURL(){} },
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(source, sandbox, { filename: "ui/app.js" });

// Read the app's array fresh every time. app.js both mutates it (live().length
// = 0 in the submit handler) and reassigns it (attachments = [] inside send), so a
// captured reference goes stale on the first send - and then every later assertion
// reads a dead array and passes for the wrong reason.
const live = () => vm.runInContext("attachments", sandbox);
const busy = () => vm.runInContext("busy", sandbox);
const input = byId("input");
const fileInput = byId("file");
const form = byId("composer");
const chips = () => byId("attachments").children;
const removeButton = (chip) => (chip && chip.children ? chip.children.find((c) => c.tagName === "BUTTON") : null);
const png = (name) => new FileStub([Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,0x00])], name, { type: "image/png" });
const resetHistory = () => vm.runInContext(
  "draftUndo.length = 0; draftRedo.length = 0; draftNow = { text: input.value, attachments: attachments.slice() }; syncUndoButtons();", sandbox);
// The draft's undo/redo are the keyboard's: the two footer buttons were removed when the
// diff topic took the transcript's one toggle. The hypotheses below use undo to *produce a
// restored list*, so they still undo - through the control that remains.
const undoDraft = () => input.fire("keydown", { key: "z", ctrlKey: true, shiftKey: false, preventDefault() {} });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Poll for a condition rather than guessing a duration. Returns false and records a
// stub problem on timeout, so a wait that never happens cannot look like a pass.
const until = async (predicate, label, ms = 2000) => {
  const started = Date.now();
  while (Date.now() - started < ms) {
    if (predicate()) return true;
    await sleep(5);
  }
  stub(false, "timed out waiting for " + label);
  return false;
};

(async () => {
  // ---- stub sanity --------------------------------------------------------
  // The hypotheses below are only worth reading if the model of the DOM can support
  // them. These checks describe the harness, not the app.
  const reader = new FileReaderStub();
  let loaded = false;
  reader.onload = () => { loaded = true; };
  reader.readAsDataURL(png("sanity.png"));
  await until(() => loaded, "FileReaderStub to fire onload");
  stub(String(reader.result || "").startsWith("data:image/png;base64,"), "FileReaderStub produces a data URL");
  const chipEl = documentStub.createElement("span");
  chipEl.append(documentStub.createElement("b"), documentStub.createElement("button"));
  stub(chipEl.children.length === 2 && chipEl.children[1].tagName === "BUTTON", "createElement + append model a chip");
  stub(typeof byId("attach").addEventListener === "function", "the stub registry returns elements that accept listeners");

  // HYPOTHESIS 1: a send clears the composer in the DOM, not only in the array.
  live().length = 0; input.value = ""; resetHistory();
  fileInput.files = [png("a.png")];
  await fileInput.fire("change", {});
  await until(() => live().length === 1, "the attachment to register");
  check(live().length === 1, "one attachment before send");
  await form.fire("submit", { preventDefault(){} });
  await until(() => busy() === false, "the send to finish");
  check(live().length === 0, "the array is cleared on send");
  check(chips().length === 0, "the DOM chips are cleared on send too (not just the array)");

  // HYPOTHESIS 2: the remove-chip button captures `index` from the forEach, so after
  // an undo that restores a list, a stale chip's handler could splice the wrong one.
  live().length = 0; input.value = ""; resetHistory();
  fileInput.files = [png("one.png"), png("two.png")];
  await fileInput.fire("change", {});
  await until(() => live().length === 2, "both attachments to register");
  check(live().length === 2, "two attachments for the index test");
  if (!until(() => removeButton(chips()[0]) !== null, "the first chip to render a remove button", 250)) {
    // recorded as STUB above
  } else {
    await removeButton(chips()[0]).fire("click", {});
    check(live().length === 1, "clicking × removes one");
    check(live()[0] && live()[0].name === "two.png", "it removed the right one (the first)");
    await undoDraft();
    await until(() => live().length === 2, "undo to restore both attachments");
    check(live().length === 2, "undo restores both attachments");
    check(live()[0] && live()[0].name === "one.png", "undo restores the order");

    // HYPOTHESIS 3: the restored chips must be rebuilt against the restored array.
    const restoredRemove = removeButton(chips()[1]);
    if (!restoredRemove) {
      stub(false, "a second restored chip with a remove button");
    } else {
      await restoredRemove.fire("click", {});
      check(live().length === 1, "removing from a restored chip removes one");
      check(live()[0] && live()[0].name === "one.png",
        "removing the SECOND restored chip removed 'two.png' (stale-index bug?)");
    }
  }

  // HYPOTHESIS 4: typing, then attaching, then undo - does undo revert the text as
  // well as the attachment, or only one half of the draft?
  live().length = 0; input.value = ""; resetHistory();
  input.value = "keep me";
  await input.fire("input", {});
  vm.runInContext("typingTimer = null;", sandbox);
  fileInput.files = [png("late.png")];
  await fileInput.fire("change", {});
  await until(() => live().length === 1, "the late attachment to register");
  await undoDraft();
  check(live().length === 0, "undo after attach removes the attachment");
  check(input.value === "keep me", "undo keeps the text typed before the attach: " + JSON.stringify(input.value));

  // HYPOTHESIS 5: an image read still in flight when the user sends must not
  // repopulate the composer afterwards.
  live().length = 0; input.value = ""; resetHistory();
  input.value = "send now";
  await input.fire("input", {});
  vm.runInContext("typingTimer = null;", sandbox);
  fileInput.files = [png("slow.png")];
  const slowRead = fileInput.fire("change", {});   // deliberately not awaited: start it, then send
  await form.fire("submit", { preventDefault(){} });
  await slowRead;
  await until(() => busy() === false, "the send to finish");
  check(live().length === 0, "a file read still in flight at send time does not repopulate the composer");

  console.log("---");
  if (stubProblems > 0) {
    console.log(stubProblems + " STUB problem(s): the harness could not test everything it claims");
  }
  // "ALL PASS (with stub gaps)" was a green verdict the suites grep for, so a run that
  // could not test everything reported as a run that tested everything. The word PASS
  // appears here only when nothing was skipped and nothing was left untested.
  const verdict = failures === 0 && stubProblems === 0
    ? "ALL PASS"
    : failures + " FAILURE(S), " + stubProblems + " STUB GAP(S)";
  console.log(verdict);
  process.exit(failures === 0 && stubProblems === 0 ? 0 : 1);
})();
