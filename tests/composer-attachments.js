// Unit test for the composer's attachment handling. Two halves of one rule: the read policy and the
// chips live in the shared <wa-chat-shell> (ui/components.js), and app.js delegates the inlining to it
// so the main conversation and a child pane cannot disagree about what `[file: name]` means. Both
// halves are read out of the real sources here rather than re-implemented, because the source of truth
// is the code that ships - asserted below, hole by hole.
const fs = require("fs");
let failures = 0;
const check = (condition, label) => {
  console.log((condition ? "ok   " : "FAIL ") + label);
  if (!condition) failures++;
};

const source = fs.readFileSync("ui/app.js", "utf8");
const shellSource = fs.readFileSync("ui/components.js", "utf8");

// The test is worthless if the functions drifted, so assert the same bodies.
check(/function composedText\(text\)/.test(source), "app.js still defines composedText");
check(/function composedBody\(text, options = \{\}\)/.test(source), "app.js still defines composedBody");
check(/chatShell\.composedText\(/.test(source), "app.js delegates the inlining rule to the shared shell");
check(/readAsDataURL/.test(shellSource), "the shared shell reads images as data URLs");
check(/attachment-thumb/.test(shellSource), "the shared shell renders a thumbnail");
check(/CHAT_IMAGE_TYPES\s*=\s*\["image\/png"/.test(shellSource), "the shared shell declares the accepted image types");

// The inlining rule, out of the shell: the method text is wrapped in an object literal so it can be
// evaluated on its own, with the attachment list as `this._attachments`.
const shellMethod = shellSource.match(/\n  composedText\(text\) \{[\s\S]*?\n  \}/)[0];
const makeShell = new Function("attachments", `
  const self = { _attachments: attachments, _ensure() {} };
  const method = ({ ${shellMethod} }).composedText;
  return { composedText: (text) => method.call(self, text) };
`);

// Pull the two functions out of app.js and evaluate them with stubs. `chatSession` is part of the
// sandbox because composedBody reads it: the thread a turn belongs to is named in the body, and a
// body that lost it would send the turn to whatever thread was newest instead.
const attachmentsRef = { current: [] };
const sandbox = new Function("attachments", "chatShell", `
  let chatSession = "";
  ${source.match(/function composedText\(text\)\s*\{[\s\S]*?\n\}/)[0]}
  ${source.match(/function composedBody\(text, options = \{\}\)\s*\{[\s\S]*?\n\}/)[0]}
  return { composedText, composedBody, setThread: (id) => { chatSession = id; } };
`);
const API = sandbox(attachmentsRef.current, makeShell(attachmentsRef.current));

// ---- text only: unchanged legacy behaviour -------------------------------
attachmentsRef.current.length = 0;
attachmentsRef.current.push({ kind: "text", name: "notes.txt", text: "hello" });
let out = API.composedText("look");
check(out.includes("[file: notes.txt]"), "text attachment is inlined");
check(out.includes("hello"), "text attachment body is included");
check(out.endsWith("look"), "the user's text comes last");

// ---- image only ----------------------------------------------------------
attachmentsRef.current.length = 0;
attachmentsRef.current.push({ kind: "image", name: "a.png", mime: "image/png", data: "data:image/png;base64,AAAA" });
let body = API.composedBody("what is this?");
check(body.contentType === "application/json", "an image switches the body to JSON");
const parsed = JSON.parse(body.body);
check(parsed.text === "what is this?", "the text survives into the JSON body");
check(parsed.images.length === 1, "the image is in the JSON body");
check(parsed.images[0].mime === "image/png", "the mime is carried");
check(parsed.images[0].data.startsWith("data:image/png;base64,"), "the data URL is carried");
check(!parsed.text.includes("base64"), "base64 is NOT inlined into the text");

// ---- no attachments: stays plain text (back-compat) ----------------------
attachmentsRef.current.length = 0;
body = API.composedBody("just words");
check(body.contentType.startsWith("text/plain"), "no attachments keeps the plain-text body");
check(body.body === "just words", "the plain body is the raw text");

// ---- mixed: text inlined, image structured ------------------------------
attachmentsRef.current.length = 0;
attachmentsRef.current.push({ kind: "text", name: "n.txt", text: "TEXTBODY" });
attachmentsRef.current.push({ kind: "image", name: "i.png", mime: "image/png", data: "data:image/png;base64,BBBB" });
body = API.composedBody("both");
const mixed = JSON.parse(body.body);
check(mixed.text.includes("TEXTBODY"), "the text file is inlined into the text field");
check(!mixed.text.includes("BBBB"), "the image is not inlined into the text field");
check(mixed.images.length === 1, "exactly one image part");
check(mixed.images[0].name === "i.png", "the image keeps its name");

// ---- image with no text at all ------------------------------------------
attachmentsRef.current.length = 0;
attachmentsRef.current.push({ kind: "image", name: "solo.png", mime: "image/png", data: "data:image/png;base64,CCCC" });
body = API.composedBody("");
const solo = JSON.parse(body.body);
check(solo.text === "", "an image-only turn sends an empty text field");
check(solo.images.length === 1, "an image-only turn still sends the image");

// ---- the thread a turn belongs to ---------------------------------------
// Named in the body, and only when there is one: the plain-text path is what the CLI, the ledger
// and peer relays use, so a window that is in no thread must still produce exactly that.
attachmentsRef.current.length = 0;
API.setThread("4ef4e372-8d84-4eff-b3e3-7f48f2a3c939");
body = API.composedBody("hello");
check(body.contentType === "application/json", "a named thread makes the body structured");
const threaded = JSON.parse(body.body);
check(threaded.thread === "4ef4e372-8d84-4eff-b3e3-7f48f2a3c939", "the body names the thread");
check(threaded.text === "hello", "and the message is still the message");
check(threaded.images === undefined, "with no pictures when none were attached");

body = API.composedBody("hello", { session: "turn-specific" });
check(JSON.parse(body.body).thread === "turn-specific", "an explicit session wins over the stored one");

API.setThread("");
body = API.composedBody("just words");
check(body.contentType.startsWith("text/plain"), "no thread and no attachments keeps the plain-text body");
check(body.body === "just words", "and the plain body is still the raw text");

console.log("---");
console.log(failures === 0 ? "ALL PASS" : failures + " FAILURE(S)");
process.exit(failures === 0 ? 0 : 1);
