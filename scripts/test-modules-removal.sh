#!/usr/bin/env bash
# The removal proof: adding a module is one directory, and removing it is deleting that directory.
#
#   bash scripts/test-modules-removal.sh            # the hermetic proof
#   bash scripts/test-modules-removal.sh --render   # and render the host page headlessly
#
# The four assertions, in the order the claim has to be proved:
#
#   (a) the module is listed and mounted while its directory exists;
#   (b) after the directory is deleted, no listing mentions it;
#   (c) the host mounts nothing for it and reports no error;
#   (d) no file outside modules/<id>/ names that module's id.
#
# (d) is the one worth writing down. "Removed completely" is a claim about the *rest of the tree*,
# not about the directory, and every registry, route table or import list that ever named a feature
# is what makes it false. So it is an assertion over every file in the tree, run before the deletion
# (nothing outside points in) and after it (nothing left behind points at nothing).
#
# It runs on a scratch copy of the tree - every tracked file plus the untracked ones git does not
# ignore - because a test of deletion must not be able to damage the tree it is testing. The copy is
# the input, not a convenience: the *repository* is what (d) is asserted about.
#
# It names no module: the module under test is the first directory under modules/ that carries a
# manifest, and its id comes from that directory. A proof that hard-codes the id could not be run
# after the thing it names is gone, which is the state it is most needed in.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RENDER=0
for argument in "$@"; do
  case "$argument" in
    --render) RENDER=1 ;;
    *) echo "unknown argument: $argument" >&2; exit 2 ;;
  esac
done

# Never inherit a node's provider, home or rendezvous: this script runs a node for its Lua, and a
# scratch run must not reach the operator's ledger or a real provider. WA_* here are this script's
# own inputs.
while IFS= read -r variable; do
  case "$variable" in
    WA_BIN|WA_OBSERVER|WA_CHROME|WA_RENDER_OUT) ;;
    WASM_AGENT_*|WA_*|OPENAI_*|OPENCODE_*|ANTHROPIC_*) unset "$variable" ;;
  esac
done < <(compgen -e)

BIN="${WA_BIN:-}"
# A native Windows build is `wa.exe` and the name without the extension is what the rest of the
# repository passes around: resolve it here rather than failing with "no node binary" on a tree that
# has one.
if [ -n "$BIN" ] && [ ! -x "$BIN" ] && [ -x "$BIN.exe" ]; then BIN="$BIN.exe"; fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  BIN=""
  for candidate in rust/target/release/wa.exe rust/target/release/wa; do
    if [ -x "$candidate" ]; then BIN="$candidate"; break; fi
  done
fi
if [ -z "$BIN" ]; then
  echo "  no node binary: build it first (cargo build --release --offline --manifest-path rust/Cargo.toml)" >&2
  exit 1
fi
echo "node binary: $BIN"
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

# A path a native Windows binary can open. /c/... is unusable as an argument, and the failure looks
# like a broken checkout rather than a bad path.
native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-modules-XXXXXX")"
RENDER_OUT="${WA_RENDER_OUT:-$WORK/render}"
cleanup() {
  local status=$?
  if [ "$status" != "0" ]; then
    echo "  scratch tree retained for diagnosis: $WORK" >&2
  else
    case "$WORK" in
      */wa-modules-??????) rm -rf -- "$WORK" 2>/dev/null || true ;;
    esac
  fi
  return "$status"
}
trap cleanup EXIT

# ---- the scratch tree ---------------------------------------------------------
TREE="$WORK/tree"
mkdir -p "$TREE" "$WORK/home"
copied=0
while IFS= read -r -d '' file; do
  mkdir -p "$TREE/$(dirname "$file")"
  cp -p "$file" "$TREE/$file"
  copied=$((copied + 1))
done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard)
echo "scratch tree: $copied files in $TREE"

# ---- the module under test, found rather than named ---------------------------
MODULE_DIR=""
for candidate in "$TREE"/modules/*/; do
  if [ -f "${candidate}module.json" ]; then MODULE_DIR="${candidate%/}"; break; fi
done
if [ -z "$MODULE_DIR" ]; then
  echo "  (a) FAIL: no directory under modules/ carries a module.json - there is no module to remove" >&2
  exit 1
fi
ID="$(basename "$MODULE_DIR")"
echo "module under test: $ID ($MODULE_DIR)"

# Every file in the tree that names the module id, outside the module's own directory.
naming() { # naming <tree> <id>
  local tree="$1" id="$2" file
  if command -v rg >/dev/null 2>&1; then
    matches="$(cd "$tree" && rg -l --hidden --no-ignore -F "$id" . 2>/dev/null | sed 's|^\./||')"
  else
    matches="$(cd "$tree" && grep -rIl --exclude-dir=.git -F "$id" . 2>/dev/null | sed 's|^\./||')"
  fi
  local hits=0
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$file" in
      "modules/$id/"*) continue ;;
    esac
    hits=$((hits + 1))
    echo "  names the module: $file"
  done <<< "$matches"
  return "$hits"   # 0 = clean; the caller turns a nonzero into a verdict
}

# ---- listing and harness, both against the scratch tree ------------------------
env_run() { # env_run <script> <ask> <capabilities> <db>
  ( cd "$TREE" &&
    WASM_AGENT_LUA_ROOT="$(native "$TREE")" \
    WASM_AGENT_MODULES_DIR="$(native "$TREE/modules")" \
    WASM_AGENT_MODULES="$2" \
    WASM_AGENT_MODULE_CAPABILITIES="$3" \
    WASM_AGENT_HOME="$(native "$WORK/home")" \
    WASM_AGENT_LLM_BASE_URL=http://127.0.0.1:1 WASM_AGENT_LLM_API_KEY=fixture-only \
    WA_SCRIPT="$(native "$4")" \
    "$BIN" --db "$(native "$WORK/$5")" )
}

listing() { # listing <ask> <capabilities> <db>  -> the JSON a page would have fetched
  env_run "$TREE/scripts/modules-listing.lua" "$1" "$2" "$TREE/scripts/modules-listing.lua" "$3"
}

# json <file> <expression over `data`>: the alternative is parsing JSON with sed, which is how a
# check ends up asserting something other than what it says.
json() { node -e 'const data=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.stdout.write(String(eval(process.argv[2])))' "$1" "$2"; }

FAILED=0
verdict() { # verdict <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok   $1: $3"
  else
    echo "  FAIL $1: expected $2, got $3" >&2
    FAILED=1
  fi
}

echo
echo "(a) with modules/$ID/ present"
listing "$ID" "" present.db > "$WORK/present.json"
verdict "the listing reports at least one module" "true" "$(json "$WORK/present.json" 'data.available >= 1')"
verdict "the module is the mounted one" "$ID" "$(json "$WORK/present.json" 'data.mounted.join(",")')"
verdict "the manifest carries a tag" "true" "$(json "$WORK/present.json" 'data.modules[0].tag.length > 0')"
verdict "attaching to a surface is declared" "true" "$(json "$WORK/present.json" 'data.modules[0].attach.surface.length > 0')"
verdict "discovery reports no issue" "true" "$(json "$WORK/present.json" 'data.issues.length === 0')"

# The route's own harness, on the same tree: the listing, the file serving, the refusal of an
# unasked module and the refusal of a capability the host does not grant.
HARNESS="$(env_run "$TREE/scripts/test-modules.lua" "" "" "$TREE/scripts/test-modules.lua" harness.db 2>&1)"
case "$HARNESS" in
  *"module route ok"*"1 module(s)"*) echo "  ok   the route harness: $(echo "$HARNESS" | tail -1)" ;;
  *) echo "  FAIL the route harness: $HARNESS" >&2; FAILED=1 ;;
esac

echo
echo "(d) before the deletion: files outside modules/$ID/ that name it"
if naming "$TREE" "$ID" > "$WORK/naming-before.txt"; then
  echo "  ok   none of the $copied files outside modules/$ID/ names '$ID'"
else
  echo "  FAIL these files name the module, so removing it would need an edit:" >&2
  cat "$WORK/naming-before.txt" >&2
  FAILED=1
fi

echo
echo "(b), (c) after deleting modules/$ID/"
cp -a "$MODULE_DIR" "$WORK/module-backup"
FILES_BEFORE="$(find "$MODULE_DIR" -type f | wc -l)"
now_ms() { local stamp; stamp="$(date +%s%3N 2>/dev/null || true)"
  case "$stamp" in ''|*[!0-9]*) echo $((SECONDS * 1000)) ;; *) echo "$stamp" ;; esac; }
STARTED="$(now_ms)"
rm -rf "$MODULE_DIR"
REMOVED_MS=$(( $(now_ms) - STARTED ))
echo "  removed $FILES_BEFORE files in ${REMOVED_MS}ms: rm -rf modules/$ID"

listing "$ID" "" absent.db > "$WORK/absent.json"
verdict "the listing no longer counts it" "0" "$(json "$WORK/absent.json" 'data.available')"
verdict "the host mounts nothing for it" "" "$(json "$WORK/absent.json" 'data.mounted.join(",")')"
verdict "the ask that still names it is not an error" "true" "$(json "$WORK/absent.json" 'data.ok === true && data.issues.length === 0')"
verdict "the listing does not mention the id at all" "false" "$(json "$WORK/absent.json" "JSON.stringify(data).includes('$ID')")"
verdict "the host page is still served" "true" "$(json "$WORK/absent.json" 'data.exists === true')"

HARNESS_GONE="$(env_run "$TREE/scripts/test-modules.lua" "" "" "$TREE/scripts/test-modules.lua" harness-absent.db 2>&1)"
case "$HARNESS_GONE" in
  *"module route ok"*"0 module(s)"*) echo "  ok   the route harness on the empty tree: $(echo "$HARNESS_GONE" | tail -1)" ;;
  *) echo "  FAIL the route harness after deletion: $HARNESS_GONE" >&2; FAILED=1 ;;
esac

echo
echo "(d) after the deletion: any file left behind that names it"
if naming "$TREE" "$ID" > "$WORK/naming-after.txt"; then
  echo "  ok   no file outside modules/$ID/ names '$ID' (nothing points at what is gone)"
else
  echo "  FAIL a file still names the module after its directory is gone:" >&2
  cat "$WORK/naming-after.txt" >&2
  FAILED=1
fi

echo
echo "recovery: the same directory, put back from the copy taken before the deletion"
cp -a "$WORK/module-backup" "$TREE/modules/$ID"
if diff -r "$ROOT/modules/$ID" "$TREE/modules/$ID" >/dev/null 2>&1; then
  echo "  ok   the restored module is byte-for-byte the tree's own modules/$ID"
else
  echo "  FAIL the restored module differs from the tree's own" >&2
  FAILED=1
fi
listing "$ID" "" recovered.db > "$WORK/recovered.json"
verdict "the listing mounts it again" "$ID" "$(json "$WORK/recovered.json" 'data.mounted.join(",")')"
echo "  in git: git rm -r modules/$ID  |  git checkout <tag> -- modules/$ID  (the tag is in module.json)"

if [ "$RENDER" = "1" ]; then
  echo
  echo "render: the host page, headlessly"
  OBSERVER="${WA_OBSERVER:-}"
  if [ -z "$OBSERVER" ]; then
    echo "  --render needs the observer: WA_OBSERVER=<path to agent-benchmark-ui-observe.mjs>" >&2
    FAILED=1
  else
    mkdir -p "$RENDER_OUT"
    HELPER="$(native "$ROOT/scripts/test-modules-host.mjs")"
    render_case() { # render_case <name> <ask> <capabilities>
      # Native paths for the helper and the page it renders: bash paths are fine for this script's own
      # `diff`/`cp`, and `/tmp/...` handed to a native Windows node resolves somewhere else entirely.
      local args=(--tree "$(native "$TREE")" --out "$(native "$RENDER_OUT/$1")"
                  --observer "$(native "$OBSERVER")" --ask "$2" --capabilities "$3"
                  --bin "$(native "$BIN")" --label "$1")
      [ -n "${WA_CHROME:-}" ] && args+=(--chrome "$(native "$WA_CHROME")")
      if node "$HELPER" "${args[@]}"; then
        echo "  ok   render $1"
      else
        echo "  FAIL render $1" >&2
        FAILED=1
      fi
    }
    # The module is back in the tree by now, so all three enables can be seen in one run, and the
    # deleted case is rendered from a tree that is copied without it.
    render_case enabled "$ID" ""
    render_case disabled "" ""
    render_case granted "$ID" "$(json "$WORK/present.json" 'data.modules[0].capabilities.join(",")')"
    GONE_TREE="$WORK/tree-gone"
    mkdir -p "$GONE_TREE"
    cp -a "$TREE/." "$GONE_TREE/"
    rm -rf "$GONE_TREE/modules/$ID"
    if node "$HELPER" --tree "$(native "$GONE_TREE")" --out "$(native "$RENDER_OUT/deleted")" \
         --observer "$(native "$OBSERVER")" --ask "$ID" --capabilities "" --bin "$(native "$BIN")" \
         --label deleted ${WA_CHROME:+--chrome "$(native "$WA_CHROME")"}; then
      echo "  ok   render deleted"
    else
      echo "  FAIL render deleted" >&2
      FAILED=1
    fi
    echo "  artifacts: $RENDER_OUT"
  fi
fi

echo
if [ "$FAILED" = "0" ]; then
  echo "module removal proof ok ($copied files, $FILES_BEFORE removed in ${REMOVED_MS}ms)"
else
  echo "module removal proof FAILED" >&2
fi
exit "$FAILED"
