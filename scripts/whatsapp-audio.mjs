// Read one incoming audio message from WhatsApp Web without opening its chat.
// The browser decrypts the media with its existing session; only bounded audio
// bytes cross CDP. The caller supplies the exact ledger message and chat ids.
import { createHash } from "node:crypto";
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { WebSocket } from "./lib/websocket-runtime.mjs";

const MAX_AUDIO_BYTES = 20 * 1024 * 1024;
const args = process.argv.slice(2);
const arg = (name) => { const at = args.indexOf(name); return at < 0 ? "" : String(args[at + 1] || ""); };
const messageId = arg("--message-id");
const chatId = arg("--chat");
const out = arg("--out");
const port = Number(process.env.WA_CDP_PORT) || 9222;

export function audioExpression(id, chat) {
  return `(async () => {
    const ID = ${JSON.stringify(id)};
    const CHAT = ${JSON.stringify(chat)};
    const messages = window.require('WAWebMsgCollection').MsgCollection.getModelsArray() || [];
    const message = messages.find((item) => {
      const key = item.id || {};
      const remote = String(key.remote || '');
      const participant = String(key.participant || '');
      const raw = String(key.id || '');
      const fallback = raw ? ((key.fromMe ? 'true' : 'false') + '_' + remote + (participant ? '_' + participant : '') + '_' + raw) : '';
      return String(key._serialized || fallback) === ID;
    });
    if (!message) return JSON.stringify({error:'message_not_in_store'});
    if (String(message.id.remote || '') !== CHAT || message.id.fromMe) return JSON.stringify({error:'message_identity_mismatch'});
    if (!['ptt','audio','voice'].includes(String(message.type || ''))) return JSON.stringify({error:'not_audio'});
    if (message.isViewOnce || message.isViewOnceV2) return JSON.stringify({error:'view_once_refused'});
    const stated = Number(message.size || message.fileSize || (message.mediaData && message.mediaData.fileSize) || 0);
    if (stated > ${MAX_AUDIO_BYTES}) return JSON.stringify({error:'audio_too_large'});
    if (!message.mediaData || message.mediaData.mediaStage === 'REUPLOADING') return JSON.stringify({error:'media_unavailable'});
    if (message.mediaData.mediaStage !== 'RESOLVED') {
      if (typeof message.downloadMedia !== 'function') return JSON.stringify({error:'download_action_missing'});
      await message.downloadMedia({downloadEvenIfExpensive:true, rmrReason:1});
    }
    if (/ERROR|FETCHING/.test(String(message.mediaData.mediaStage || ''))) return JSON.stringify({error:'media_download_incomplete'});
    const qpl = {addAnnotations(){return this},addPoint(){return this}};
    const raw = await window.require('WAWebDownloadManager').downloadManager.downloadAndMaybeDecrypt({
      directPath:message.directPath, encFilehash:message.encFilehash, filehash:message.filehash,
      mediaKey:message.mediaKey, mediaKeyTimestamp:message.mediaKeyTimestamp, type:message.type,
      signal:new AbortController().signal, downloadQpl:qpl
    });
    const bytes = raw instanceof Uint8Array ? raw : new Uint8Array(raw);
    if (!bytes.length || bytes.length > ${MAX_AUDIO_BYTES}) return JSON.stringify({error:'audio_size_invalid',bytes:bytes.length});
    let binary = '';
    for (let offset=0; offset<bytes.length; offset+=32768) {
      binary += String.fromCharCode(...bytes.subarray(offset, offset+32768));
    }
    return JSON.stringify({ok:true,base64:btoa(binary),bytes:bytes.length,mime:String(message.mimetype || 'audio/ogg')});
  })()`;
}

async function discover() {
  for (const host of ["127.0.0.1", "[::1]"]) {
    try {
      const origin = `http://${host}:${port}`;
      const version = await (await fetch(`${origin}/json/version`, { signal: AbortSignal.timeout(3000) })).json();
      if (!version.webSocketDebuggerUrl || !version.Browser) continue;
      const pages = await (await fetch(`${origin}/json/list`, { signal: AbortSignal.timeout(3000) })).json();
      const page = pages.find((item) => item.type === "page" && String(item.url || "").startsWith("https://web.whatsapp.com/"));
      if (page && page.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch { /* try the other loopback stack */ }
  }
  throw new Error("no_whatsapp_cdp_page");
}

async function main() {
  if (!messageId || !chatId || !out) throw new Error("message_id_chat_out_required");
  const endpoint = await discover();
  const ws = new WebSocket(endpoint);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", () => reject(new Error("cdp_connect_failed")), { once: true });
  });
  let result;
  try {
    result = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("audio_download_timeout")), 90000);
      ws.addEventListener("message", (event) => {
        let frame;
        try { frame = JSON.parse(event.data); } catch { return; }
        if (frame.id !== 1) return;
        clearTimeout(timer);
        frame.error ? reject(new Error("cdp_evaluate_failed")) : resolve(frame.result);
      });
      ws.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: {
        expression: audioExpression(messageId, chatId), returnByValue: true, awaitPromise: true,
      } }));
    });
  } finally { ws.close(); }
  if (result.exceptionDetails) throw new Error("audio_browser_exception:" + String(result.exceptionDetails.text || "unknown").slice(0, 100));
  const payload = JSON.parse(result.result.value);
  if (payload.error) throw new Error(payload.error);
  const bytes = Buffer.from(String(payload.base64 || ""), "base64");
  if (!bytes.length || bytes.length > MAX_AUDIO_BYTES || bytes.length !== payload.bytes) throw new Error("audio_bytes_invalid");
  const mime = String(payload.mime || "");
  if (!/^audio\//.test(mime)) throw new Error("audio_mime_invalid");
  writeFileSync(out, bytes, { flag: "wx", mode: 0o600 });
  console.log(JSON.stringify({ ok: true, bytes: bytes.length, mime, sha256: createHash("sha256").update(bytes).digest("hex") }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((error) => {
    console.log(JSON.stringify({ ok: false, error: String(error.message || error).slice(0, 160) }));
    process.exitCode = 1;
  });
}
