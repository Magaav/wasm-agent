// Read-only forensic probe: what does the LIVE build actually hand back when the (pre-fix) download
// call omits the mimetype? Nothing is sent, no chat is opened, no event is dispatched, nothing is marked
// read. It evaluates the origin/main expression verbatim and prints the raw CDP frame shape.
import { pathToFileURL } from "node:url";

const OLD = process.env.OLD_AUDIO;
const { audioExpression } = await import(pathToFileURL(OLD).href);

const id = "false_112682812330026@lid_ACF41B7C289898821ABBD8921D0313B4";
const chat = "112682812330026@lid";

async function discover() {
  for (const host of ["127.0.0.1", "[::1]"]) {
    try {
      const origin = `http://${host}:9222`;
      const pages = await (await fetch(`${origin}/json/list`, { signal: AbortSignal.timeout(3000) })).json();
      const page = pages.find((p) => p.type === "page" && String(p.url || "").startsWith("https://web.whatsapp.com/"));
      if (page) return page.webSocketDebuggerUrl;
    } catch { /* other loopback stack */ }
  }
  throw new Error("no_whatsapp_cdp_page");
}

async function evaluate(expression) {
  const endpoint = await discover();
  const ws = new WebSocket(endpoint);
  await new Promise((r) => ws.addEventListener("open", r, { once: true }));
  const frame = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout")), 90000);
    ws.addEventListener("message", (event) => {
      const parsed = JSON.parse(event.data);
      if (parsed.id !== 1) return;
      clearTimeout(timer);
      resolve(parsed.result);
    });
    ws.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: {
      expression, returnByValue: true, awaitPromise: true } }));
  });
  ws.close();
  return frame;
}

const shape = (details) => {
  if (!details) return null;
  const exception = details.exception || {};
  return {
    text: details.text,
    exception_className: exception.className,
    exception_description: String(exception.description || "").slice(0, 140),
    exception_subtype: exception.subtype,
    preview_overridden: exception.preview ? exception.preview.overridden : undefined,
    preview_properties: ((exception.preview && exception.preview.properties) || [])
      .map((p) => ({ name: p.name, value: String(p.value).slice(0, 90) })),
  };
};

// 1. the pre-fix expression, live: raw frame, no interpretation
const preFix = await evaluate(audioExpression(id, chat));
console.log("PRE-FIX RAW FRAME:");
console.log(JSON.stringify({ exceptionDetails: shape(preFix.exceptionDetails),
  result_value: preFix.result ? String(preFix.result.value).slice(0, 160) : null }, null, 1));

// 2. what the tip's browserExceptionReason() would make of that very frame
const tipReason = await import(pathToFileURL(process.env.TIP_AUDIO).href);
console.log("TIP browserExceptionReason(frame) => " + JSON.stringify(
  tipReason.browserExceptionReason(preFix.exceptionDetails)));

// 3. the fields the fix depends on, read off the live message object (only these three fields)
const inspection = await evaluate(`(() => {
  const ID = ${JSON.stringify(id)}, CHAT = ${JSON.stringify(chat)};
  const messages = window.require('WAWebMsgCollection').MsgCollection.getModelsArray() || [];
  const message = messages.find((item) => {
    const key = item.id || {};
    return String(key.remote || '') === CHAT && String(key.id || '') === ID.split('_').pop();
  });
  if (!message) return JSON.stringify({ found: false });
  return JSON.stringify({ found: true, type: message.type,
    mimetype: message.mimetype === undefined ? '<undefined>' : String(message.mimetype),
    mediaData_mimetype: (message.mediaData && message.mediaData.mimetype) || '<none>',
    mediaStage: String((message.mediaData && message.mediaData.mediaStage) || ''),
    size: Number(message.size || 0) });
})()`);
console.log("LIVE MESSAGE FIELDS: " + String(inspection.result.value));

// 4. how many messages in the store declare no mimetype at all (reachability of the missing-mimetype refusal)
const missing = await evaluate(`(() => {
  const messages = window.require('WAWebMsgCollection').MsgCollection.getModelsArray() || [];
  const kinds = ['ptt','audio','voice'];
  let audio = 0, noMime = 0;
  for (const m of messages) {
    const k = String((m.media && m.media[0] && m.media[0].type) || m.type || '');
    if (!kinds.includes(k)) continue;
    audio += 1;
    if (!String(m.mimetype || (m.mediaData && m.mediaData.mimetype) || '').trim()) noMime += 1;
  }
  return JSON.stringify({ audio_messages: audio, audio_without_mimetype: noMime });
})()`);
console.log("MIMETYPE COVERAGE (counts only): " + String(missing.result.value));
