// THE WEB VIEW DRAWS THE MODEL'S SCRIPT AS IT IS WRITTEN (operator, 21/11: "i want our wa agent (run
// code) to draw the JS as it used to do in raw code channel, so we can see it in real time writing js
// ... the promises waiting for coming back").
//
// The Lua half of this contract is scripts/test-run-live.lua; this file is the WINDOW half, and it runs
// the REAL functions from ui/app.js - the element, the per-call block, and the two branches of the
// event router - inside a minimal page scope, so what is asserted is the shipped code, not a copy.
//
// The input is the REAL recorded provider wire (tests/fixtures/provider/opencode-go-run-code-recorded.sse).
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const source = fs.readFileSync("ui/app.js", "utf8");

class FakeElement {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase();
    this.children = [];
    this.dataset = {};
    this._text = "";
    this.isConnected = true;
    this.className = "";
    const classes = new Set();
    this.classList = {
      add: (...names) => names.forEach((name) => classes.add(name)),
      remove: (...names) => names.forEach((name) => classes.delete(name)),
      contains: (name) => classes.has(name),
      get value() { return [...classes].join(" "); },
    };
  }
  append(...nodes) {
    for (const node of nodes) {
      if (typeof node === "string") { this._text += node; continue; }
      this.children.push(node);
      node.parentNode = this;
      // A browser runs connectedCallback when an element reaches the document; so does this, which
      // is what proves the element the page creates is the one it registered.
      if (typeof node.connectedCallback === "function" && !node._built) { node._built = true; node.connectedCallback(); }
    }
  }
  get textContent() { return this._text + this.children.map((c) => c.textContent || "").join(""); }
  set textContent(value) { this._text = String(value || ""); }
}
const customElements = {
  registry: new Map(),
  define(name, ctor) { this.registry.set(name, ctor); },
  get(name) { return this.registry.get(name); },
};
const body = new FakeElement("div");
const traceLog = [];
const context = {
  customElements,
  HTMLElement: FakeElement,
  // A browser builds the REGISTERED class for a custom element's tag, and a plain element otherwise.
  document: { createElement: (tag) => {
    const C = customElements.get(tag);
    if (!C) return new FakeElement(tag);
    const element = new C();
    element.tagName = String(tag).toUpperCase();   // a custom element knows its own tag
    return element;
  } },
  console,
  runBubble: { body },
  sealReasoning: () => traceLog.push("seal"),
  anchorRunStepContent: (node) => traceLog.push("anchor:" + (node.tagName || "?")),
  pin: () => traceLog.push("pin"),
  currentBubble: () => ({ body }),
  showRunStep: (key) => traceLog.push("step:" + key),
};
context.window = context;
vm.createContext(context);

function slice(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, "app.js still has " + startMarker);
  return source.slice(start, end);
}
const blockCode = slice("// A native run tool call draws its SCRIPT", "function addTool(");
vm.runInContext(blockCode + "\nthis.__runCodeBlock = runCodeBlock; this.__forget = forgetRunCodeBlocks;", context);

// The recorded turn, as the agent hands it to the window: tests/fixtures/provider/
// opencode-go-run-code-recorded.deltas.json is the decoder's own output for that wire (written by
// lua/core/run_stream.lua and asserted byte for byte in scripts/test-run-live.lua), so what streams
// below is exactly the text a live run emits - not a re-parse of the provider's JSON here.
const recorded = JSON.parse(fs.readFileSync(
  'tests/fixtures/provider/opencode-go-run-code-recorded.deltas.json', 'utf8'));
const pieces = recorded.deltas;
const script = recorded.code;
assert.ok(pieces.length > 1, 'the recorded turn streams several deltas: ' + pieces.length);
assert.equal(pieces.join(''), script, 'and they are the whole script, in order');

const callId = "call-run-1";
const block = context.__runCodeBlock(callId);
assert.deepEqual(traceLog.slice(0, 3), ["seal", "anchor:WA-RUN-CODE", "pin"],
  "the script's block is a step topic of its own: " + traceLog.join(","));
assert.equal(body.children.length, 1, "and it is in the bubble");
assert.equal(body.children[0], block, "which is the block the deltas land in");

let grown = 0;
for (const piece of pieces) { if (piece) { block.append(piece); grown += 1; } }
assert.ok(grown > 1, "the block grew over several deltas, not in one jump: " + grown);
assert.ok(block.script.includes("await tools.bash"), "the awaited call is visible: " + block.script);
assert.ok(!block.textContent.includes("Run(code="), "never behind a Run(code=...) wrapper");
assert.equal(body.children.length, 1, "and no second block was opened for the same call");

// ---- the tool event: a run call completes its block and opens NO wrapper row --------------
const toolBranch = source.slice(source.indexOf('if (event.name === "run") {'),
  source.indexOf('} else if (event.type === "tool_result") {'));
assert.ok(toolBranch.length > 0, "the tool handler still has the run branch");
const runBranch = toolBranch.slice(0, toolBranch.indexOf("} else {"));
assert.ok(runBranch.includes("runCodeBlock(event.call_id)"), "a run call completes ITS block");
assert.ok(!runBranch.includes("addTool("), "and opens no Run(code=...) row: " + runBranch);
assert.ok(toolBranch.slice(toolBranch.indexOf("} else {")).includes("addTool(event.name"),
  "every other tool still opens its own row (unchanged)");

block.script = "";
context.__runCodeBlock(callId).script = script;
assert.equal(block.script, script, "the complete arguments repair a block that missed a delta");

const second = context.__runCodeBlock("call-run-2");
assert.notEqual(second, block, "a second run call is its own script");
assert.equal(body.children.length, 2, "drawn as a second block, not appended to the first");
second.append("return 1;");
assert.equal(block.script, script, "and the first block kept its own script");

context.__forget();
const third = context.__runCodeBlock(callId);
assert.notEqual(third, block, "after a run ends, the same call id opens a NEW block");

console.log("run code UI ok (14 checks, 0 skipped; the real app.js functions against the recorded wire)");
