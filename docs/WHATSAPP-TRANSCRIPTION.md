# Local WhatsApp audio transcription

`whatsapp-transcribe` is an opt-in scheduled job. Every 30 seconds it reads new
incoming `ptt`, `audio`, and `voice` messages from the same WhatsApp Web store
used by the copilot. It decrypts one recording at a time in that browser, runs
speech recognition locally, formats the result through the internal WASM plugin,
and sends the text to the original conversation through WhatsApp's injected
`WAWebSendTextMsgChatAction.sendTextMsgToChat` app action. It never opens/focuses the chat or dispatches input events.

No audio or transcript goes to an STT provider. The Python runner uses
`local_files_only=True` and the job sets `HF_HUB_OFFLINE=1`. Download the model
**before** enabling the job. The model is multilingual `small` by default and
runs on the CPU with int8 quantization. A different locally cached model can be
selected with `WA_WHATSAPP_STT_MODEL`. Recognition defaults to Portuguese
(`WA_WHATSAPP_STT_LANGUAGE=pt`) and uses beam size 5. Set the language to `auto`
to let Whisper detect the language, or to another Whisper language code such as
`en` for a different primary language. Beam size 5 may take longer than the old
beam size 1, trading some CPU time for better decoding on short clips. VAD keeps
short silence gaps within a spoken message; it is not a remedy for clipped or
noisy audio.

## Install the local recognizer

Install Python 3.9+ and `faster-whisper` into a private environment on the
machine with the WhatsApp browser. For example, on Windows PowerShell:

```powershell
$sttRoot = Join-Path $env:LOCALAPPDATA 'wasm-agent/stt'
py -3 -m venv $sttRoot
& "$sttRoot/Scripts/python.exe" -m pip install faster-whisper
$modelRoot = Join-Path $sttRoot 'models'
& "$sttRoot/Scripts/python.exe" -c "from faster_whisper import WhisperModel; WhisperModel('small', device='cpu', compute_type='int8', download_root=r'$modelRoot')"
$env:WA_WHATSAPP_STT_MODELS = $modelRoot
& "$sttRoot/Scripts/python.exe" scripts/whatsapp-stt-local.py --check
```

Set `WA_WHATSAPP_STT_PYTHON` to that interpreter and
`WA_WHATSAPP_STT_MODELS` to that model directory in the node's config `env`
file. Also bind `WA_WHATSAPP_ACCOUNT` and `WA_WHATSAPP_BROWSER_ENDPOINT` to the
account and explicit loopback DevTools page from a read-only lookup; sends refuse
when either is missing or mismatched. `WA_WHATSAPP_STORE_SEND_SCRIPT` can select
the installed sender (default: sibling `whatsapp-store-send.mjs`). The runner refuses to download a model during a message delivery.
Then enable the installed job with `wa-sentinel job enable whatsapp-transcribe`.
The first tick adopts the current store without replying to old messages.

## Plugin contract

The existing core-module ABI (`memory`, `alloc`, `describe`, `call`) remains the
same. A plugin may now declare `"surface":"internal"` in `describe()`. Such a
plugin can be called by trusted Lua through `host.invoke` but is absent from
the model's tool list. A standalone transcript is sent as `🎙️ _Copiloto-Transcritor_`,
followed by a newline and the recognized text; numbered parts retain their
part counter after the same header. The `whatsapp_transcript` plugin receives only the
recognized text and returns `{ "bodies": ["..."] }`; it has no filesystem,
browser, network, or send imports. The host owns those effects and the durable
reservation. This keeps the STT engine native and permits deterministic reply
formatting to be replaced without editing the ingestion code. Long transcripts
return numbered `bodies` of at most 3,300 characters each; the job persists
them before sending and confirms each part independently.

## Settlement and limits

- Incoming audio in a known direct or group conversation is processed, including
  archived chats. Broadcast/status or left conversations and view-once media
  are refused; the job reports their message ids and reasons.
- Audio is capped at 20 MiB. Each tick handles at most one pending recording;
  the pending list survives restarts and reaches below the read cursor.
- A failed download or recognition remains pending and is retried. The job's
  result names the failing step and message id. A confirmed send is recorded in
  `effect_sends`; an ambiguous send is recorded as `unknown` and is never
  replayed automatically.
- The new job is installed disabled. Enabling it authorizes transcript replies to source conversations through the store action; this does not clear unread markers. Human drafts and unsupported target metadata still refuse before dispatch.

`node scripts/test-whatsapp-transcribe.cjs` proves the Lua, SQLite, WASM,
reservation, retry, and no-duplicate path with fake media and send adapters.
`node scripts/test-whatsapp-audio.mjs` checks the browser-side media guards.
The raw app-action path has live read-only compatibility evidence, but no live
transcript message has been sent; explicit operator approval is required before that external-effect proof.

The WhatsApp copilot reader uses the same native recognizer and model settings
to put audio transcripts into `whatsapp_read` context before its responder runs.
It does not send a standalone transcript reply. Keep the separate
`whatsapp-transcribe` job disabled when using the copilot path.
