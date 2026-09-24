import assert from "node:assert/strict";
import vm from "node:vm";
import { audioExpression } from "./whatsapp-audio.mjs";

const chat = "5511888888888@c.us";
const id = `false_${chat}_abc`;
function message(extra = {}) {
  return { id: { remote: chat, id: "abc", fromMe: false }, type: "ptt",
    mediaData: { mediaStage: "RESOLVED" }, mimetype: "audio/ogg", ...extra };
}
async function evaluate(item) {
  const window = { require(name) {
    if (name === "WAWebMsgCollection") return { MsgCollection: { getModelsArray: () => [item] } };
    if (name === "WAWebDownloadManager") return { downloadManager: {
      downloadAndMaybeDecrypt: async () => Uint8Array.of(1, 2, 3, 4),
    } };
    throw new Error("unexpected module " + name);
  } };
  const raw = await vm.runInNewContext(audioExpression(id, chat), { window, Uint8Array, AbortController, btoa });
  return JSON.parse(raw);
}
assert.deepEqual(Buffer.from((await evaluate(message())).base64, "base64"), Buffer.from([1, 2, 3, 4]));
assert.equal((await evaluate(message({ id: { remote: "other@c.us", id: "abc", fromMe: false } }))).error, "message_not_in_store");
assert.equal((await evaluate(message({ type: "image" }))).error, "not_audio");
assert.equal((await evaluate(message({ isViewOnce: true }))).error, "view_once_refused");
assert.equal((await evaluate(message({ size: 30 * 1024 * 1024 }))).error, "audio_too_large");
console.log("whatsapp audio boundary ok (exact id, type, view-once and size; 0 skipped)");
