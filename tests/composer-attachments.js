// Unit test for the composer's attachment handling, extracted from ui/app.js.
// This reproduces composedText/composedBody exactly as app.js defines them, so
// a regression in the real functions is caught here only if they are kept in
// step - the source of truth is the copy in app.js, asserted below.
const fs = require("fs");
let failures = 0;
const check = (condition, label) => {
  console.log((condition ? "ok   " : "FAIL ") + label);
  if (!condition) failures++;
};

const source = fs.readFileSync("ui/app.js", "utf8");

// The test is worthless if the functions drifted, so assert the same bodies.
check(/function composedText\(text\)/.test(source), "app.js still defines composedText");
check(/function composedBody\(text\)/.test(source), "app.js still defines composedBody");
check(/readAsDataURL/.test(source), "app.js reads images as data URLs");
check(/attachment-thumb/.test(source), "app.js renders a thumbnail");
check(/IMAGE_TYPES\s*=\s*\["image\/png"/.test(source), "app.js declares the accepted image types");

// Pull the two functions out of app.js and evaluate them with stubs.
const attachmentsRef = { current: [] };
const sandbox = new Function("attachments", `
  ${source.match(/function composedText\(text\)\s*\{[\s\S]*?\n\}/)[0]}
  ${source.match(/function composedBody\(text\)\s*\{[\s\S]*?\n\}/)[0]}
  return { composedText, composedBody };
`);
const API = sandbox(attachmentsRef.current);

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

console.log("---");
console.log(failures === 0 ? "ALL PASS" : failures + " FAILURE(S)");
process.exit(failures === 0 ? 0 : 1);
