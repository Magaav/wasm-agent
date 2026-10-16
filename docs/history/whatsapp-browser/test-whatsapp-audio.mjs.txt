// The browser-side audio guards, and the two things this lane got wrong on the live build: the download
// call omitted the declared mimetype (so the app rejected it as application/octet-stream for a ptt), and
// the caller reported CDP's wrapper text ("Uncaught (in promise)") instead of the rejection reason.
import assert from "node:assert/strict";
import vm from "node:vm";
import { audioExpression, browserExceptionReason } from "./whatsapp-audio.mjs";

const chat = "5511888888888@c.us";
const id = `false_${chat}_abc`;
// The mimetype is the live build's own value, verbatim: its ptt allowlist is
// [audio/ogg; codecs=opus, audio/mp4, audio/mpeg, audio/aac, audio/amr] and the check is a set lookup, so
// the parameters are part of the string that has to be passed through.
const MIMETYPE = "audio/ogg; codecs=opus";
function message(extra = {}) {
  return { id: { remote: chat, id: "abc", fromMe: false }, type: "ptt",
    mediaData: { mediaStage: "RESOLVED" }, mimetype: MIMETYPE, ...extra };
}
async function evaluate(item, options = {}) {
  const calls = [];
  const window = { require(name) {
    if (name === "WAWebMsgCollection") return { MsgCollection: { getModelsArray: () => [item] } };
    if (name === "WAWebDownloadManager") return { downloadManager: {
      downloadAndMaybeDecrypt: async (params) => {
        calls.push(params);
        if (options.fail) throw Object.assign(new Error(options.fail), { name: options.failName || "Error" });
        return Uint8Array.of(1, 2, 3, 4);
      },
    } };
    throw new Error("unexpected module " + name);
  } };
  const raw = await vm.runInNewContext(audioExpression(id, chat), { window, Uint8Array, AbortController, btoa });
  return { payload: JSON.parse(raw), calls };
}
const audio = await evaluate(message());
assert.deepEqual(Buffer.from(audio.payload.base64, "base64"), Buffer.from([1, 2, 3, 4]));
assert.equal(audio.payload.mime, MIMETYPE, "the declared mimetype is what the caller reports back");
assert.equal(audio.calls.length, 1, "the download is attempted exactly once");
assert.equal(audio.calls[0].mimetype, MIMETYPE,
  "the download carries the message's own mimetype: without it the build defaults to application/octet-stream and refuses every ptt");
assert.equal(audio.calls[0].type, "ptt");
assert.ok(audio.calls[0].signal instanceof AbortController.prototype.constructor || typeof audio.calls[0].signal === "object",
  "the download is still cancellable");

// A message that declares no mimetype fails closed and never reaches the download: guessing one would be
// exactly the silent default that made this lane fail.
const noMime = await evaluate(message({ mimetype: "" }));
assert.equal(noMime.payload.error, "audio_mimetype_missing");
assert.equal(noMime.calls.length, 0, "no mimetype means no download attempt");

// The app's own rejection is returned with its type and message, so the step result can name what the build
// refused instead of the wrapper text.
const refused = await evaluate(message(), { fail: "Unexpected mimetype application/octet-stream for media type ptt", failName: "InvalidMediaFileType" });
assert.equal(refused.payload.error, "audio_download_failed");
assert.equal(refused.payload.name, "InvalidMediaFileType");
assert.match(refused.payload.message, /Unexpected mimetype/);

// The measured shape of a rejection from the page: `text` is the wrapper, the reason is in the object's
// preview (its class name is minified, so the message is the only place it can come from).
const measured = { text: "Uncaught (in promise)", exception: { type: "object", className: "t", description: "t",
  preview: { properties: [
    { name: "message", value: "Unexpected mimetype application/octet-stream for media type ptt" },
    { name: "name", value: "InvalidMediaFileType" } ] } } };
assert.equal(browserExceptionReason(measured), "InvalidMediaFileType: Unexpected mimetype application/octet-stream for media type ptt");
assert.notEqual(browserExceptionReason(measured), "Uncaught (in promise)", "the wrapper text is never the reason");
assert.equal(browserExceptionReason({ text: "Uncaught (in promise)", exception: { description: "boom" } }), "boom");
assert.equal(browserExceptionReason({ text: "Uncaught (in promise)" }), "Uncaught (in promise)");

assert.equal((await evaluate(message({ id: { remote: "other@c.us", id: "abc", fromMe: false } }))).payload.error, "message_not_in_store");
assert.equal((await evaluate(message({ type: "image" }))).payload.error, "not_audio");
assert.equal((await evaluate(message({ isViewOnce: true }))).payload.error, "view_once_refused");
assert.equal((await evaluate(message({ size: 30 * 1024 * 1024 }))).payload.error, "audio_too_large");
console.log("whatsapp audio boundary ok (exact id, type, view-once, size, mimetype and rejection reason; 0 skipped)");
