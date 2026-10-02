// One-thing-reverted mutations, applied to a throw-away clone of the tip. Each mutation undoes exactly one
// behaviour the delivery added, so a test that cannot fail would keep passing.
const fs = require("node:fs");
const path = require("node:path");

const clone = process.env.CLONE;
const id = process.argv[2];
const file = (rel) => path.join(clone, rel);
function patch(rel, from, to) {
  const p = file(rel);
  const before = fs.readFileSync(p, "utf8");
  if (!before.includes(from)) throw new Error(`mutation ${id}: anchor not found in ${rel}: ${from.slice(0, 60)}`);
  const after = before.split(from).join(to);
  fs.writeFileSync(p, after);
  if (before === after) throw new Error(`mutation ${id}: no change in ${rel}`);
}

const MUTATIONS = {
  // the original bug: the download call omits the message's declared mimetype
  "mime-omitted": () => patch("scripts/whatsapp-audio.mjs", "      mimetype:mime,\n", ""),
  // the original reporting bug: the typed reason is never read, only CDP's wrapper text
  "wrapper-only": () => patch("scripts/whatsapp-audio.mjs",
    "  const exception = details && details.exception;\n",
    '  return String((details && details.text) || "unknown").slice(0, 200);\n  const exception = details && details.exception;\n'),
  // the silent skip: the cursor advances past the note the pass could not settle
  "clamp-removed": () => patch("scripts/whatsapp-transcribe.lua",
    "  if at and at - 1 < advance then advance = math.max(cursor, at - 1) end\n", ""),
  // the silent drop: a swept note is no longer part of the step result
  "sweep-silent": () => patch("scripts/whatsapp-transcribe.lua",
    "if #stale_refused > 0 and result.ok then", "if false then"),
  // step 1 exits on "DevTools answered" without ever asking the preflight about the hook
  "fast-path-exit": () => patch("scripts/whatsapp-source-ensure.sh",
    '    preflight="$(timeout 90 bash "$PREFLIGHT" 2>&1 | head -1)"\n',
    '    preflight="whatsapp preflight ok cdp=127.0.0.1:9222 chats=7 bound=page hook=true"\n    verdict true "already-up" "cdp_answering" null\n    exit 0\n'),
  // drift is reported and nothing more
  "no-repair": () => patch("scripts/whatsapp-preflight.sh",
    'case "$trigger_line" in\n  *"drift=yes"*|*"pin=none"*)\n    repair_line="$(timeout 60 node "$ROOT/scripts/whatsapp-trigger.mjs" repair 2>/dev/null | tail -1)"\n    echo "whatsapp preflight trigger-repair ${repair_line:-no_verdict}"\n    ;;\nesac\n', ""),
  // re-queue replaces the pending row, throwing away the cached parts and the recorded failure
  "requeue-replace": () => patch("scripts/whatsapp-transcribe.lua",
    '      local queued = pending[id]\n      if type(queued) == "table" then', "      local queued = pending[id]\n      if false then"),
};

if (!MUTATIONS[id]) throw new Error("unknown mutation " + id);
MUTATIONS[id]();
console.log("mutated: " + id);
