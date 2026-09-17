# Image attachments — implementation plan

## Goal
Drop an image into the composer, add text, and the model sees both.
Current model (`deepseek-v4.1-flash`) is vision-capable — verified by probe.

## What exists today (do not break)
- `app.js:855`  `await file.text()` — every attachment read as UTF-8 text.
- `app.js:478`  `composedText()` flattens to one `[file: name]\n<text>` string.
- `app.js:502`  POST /chat body = `text/plain`, one string.
- `agent.lua:turn(text)`  appends `{role=user, content=text}` and calls build_context.
- `agent.lua:build_context` replays turns as `{role="user", content=turn.content}`.
- `provider.lua` sends `messages` straight through (OpenAI-compatible).
- `turns.content` is TEXT and is FTS-indexed (turns_fts) — base64 must NOT go here.

## Design
1. **Store bytes on disk, not in the DB.**
   `~/.wasm-agent/attachments/<sha256[0:2]>/<sha256>.<ext>` written as base64 text.
   Content-addressed => re-dropping the same image costs nothing, and the path is
   stable for replay. sha256 comes from `host.sha256` (hex, already exists).

2. **Reference images from the turn, in a way that cannot poison FTS.**
   Turn content stays a human string. Images travel as a *separate* field on the
   turn payload and are persisted as JSON in the existing `trace` column?
   NO — trace is the assistant observability payload. Instead: extend
   `append_turn` with an `images` array stored in a NEW column `images` (TEXT,
   JSON array of {mime, sha256, name, size}). Migration: ALTER TABLE ... ADD
   COLUMN, guarded, since schema.sql is CREATE TABLE IF NOT EXISTS.

3. **build_context rebuilds the vision part.**
   user turn with images => `content = { {type="text",text=...}, {type="image_url",...} }`
   Reading the file at replay time. If the file is missing, emit a visible
   marker in the text part rather than silently dropping the image
   (AGENTS.md: failures must be visible).

4. **UI.**
   - `fileInput` gains `multiple` (probably already) and image detection by type.
   - Images: `FileReader.readAsDataURL` -> keep `{kind:"image", mime, dataUrl, name}`.
   - Text files: unchanged path (`file.text()`).
   - `composedText` splits: images go into a structured payload, text stays text.
   - Transport: POST /chat body becomes JSON when images are present:
     `{"text": "...", "images":[{mime,name,b64}]}`.
     Keep `text/plain` working for the no-image case (back-compat, and the
     ledger/peer paths send plain text).

5. **Wire format note.** Provider is OpenAI-compatible:
   `content:[{type:"text",...},{type:"image_url",image_url:{url:"data:<mime>;base64,<b64>"}}]`

## Open question for the human
- Keep base64 in the request (simple, larger) vs. upload once and reference by
  sha (smaller, needs an endpoint). Start with base64 in-request; the disk copy
  is for replay, not for transport.
