// Falsification probe for "every refusal is typed and named, never the CDP wrapper".
// Runs the tip's own audioExpression under a stub page, so the shapes are exact.
import vm from "node:vm";
import { audioExpression, browserExceptionReason } from "../../scripts/whatsapp-audio.mjs";

const chat = "5511888888888@c.us";
const id = `false_${chat}_abc`;
async function run(item, behaviour) {
  const window = { require(name) {
    if (name === "WAWebMsgCollection") return { MsgCollection: { getModelsArray: () => [item] } };
    if (name === "WAWebDownloadManager") return { downloadManager: { downloadAndMaybeDecrypt: async () => {
      if (behaviour === "string") throw "the build refused";
      if (behaviour === "bag") throw { code: 42 };            // not an Error: no name, no message
      if (behaviour === "null-media") return Uint8Array.of(1, 2, 3, 4);
      throw Object.assign(new Error("refused"), { name: "InvalidMediaFileType" });
    } } };
    throw new Error("unexpected module " + name);
  } };
  return JSON.parse(await vm.runInNewContext(audioExpression(id, chat), { window, Uint8Array, AbortController, btoa }));
}
const base = { id: { remote: chat, id: "abc", fromMe: false }, type: "ptt",
  mediaData: { mediaStage: "RESOLVED" }, mimetype: "audio/ogg; codecs=opus" };

console.log("absent mediaData (benign byte copy): " + JSON.stringify(await run({ ...base, mediaData: null }, "null-media")));
console.log("absent mediaData, download rejects:  " + JSON.stringify(await run({ ...base, mediaData: null }, "typed")));
console.log("rejection is a bare string:          " + JSON.stringify(await run(base, "string")));
console.log("rejection is a non-Error object:     " + JSON.stringify(await run(base, "bag")));
console.log("typed rejection:                     " + JSON.stringify(await run(base, "typed")));
console.log("no mimetype at all:                  " + JSON.stringify(await run({ ...base, mimetype: "" }, "typed")));
console.log("view-once:                           " + JSON.stringify(await run({ ...base, isViewOnce: true }, "typed")));
console.log("oversized:                           " + JSON.stringify(await run({ ...base, size: 30 * 1024 * 1024 }, "typed")));
console.log("not audio:                           " + JSON.stringify(await run({ ...base, type: "image" }, "typed")));
// the CDP-level fallback, for the record: only a frame with no readable reason reaches the wrapper text
console.log("browserExceptionReason(no reason at all): " + JSON.stringify(browserExceptionReason({ text: "Uncaught (in promise)" })));
console.log("browserExceptionReason({}):               " + JSON.stringify(browserExceptionReason({})));
