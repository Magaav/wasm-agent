#!/usr/bin/env bash
# Do deploys bring a release's NEW policy rules into a node that already has a `policy.json` - without
# overwriting a rule the operator wrote? (`docs/GRANT-POLICY.md`, "The shipped default".)
#
# The failure this pins (openclaw, 07/11). `policy.json` had been installed from an older shipped default.
# A later release added `ix/*` to `wa-whatsapp`'s `kv.write` allow list. The deploy kept the node's file -
# correct, an operator's edits are never overwritten - and so the new rule never arrived: every index
# write was refused until it was added by hand. The unit of "never overwrite" is the RULE, not the file.
#
# The rules this measures, by RUNNING the code the deploy runs (`scripts/lib/install-default-policy.sh`
# and `scripts/lib/policy-merge.mjs`) against fixture trees and scratch state directories:
#
#   1. a state directory with no policy file gets the shipped default, byte for byte, and the base it was
#      installed from is recorded beside it (`policy.base.json` + its sha256);
#   2. a rule the release ADDED arrives (`ix/*` in a rule the node never touched);
#   3. a rule the node EDITED is kept as the node wrote it, and the release's other changes still land;
#   4. a rule BOTH sides changed is a conflict: the node's version is kept, the deploy continues, and the
#      conflict is named in the report and in `policy_merge_warnings` (which the deploy puts in
#      `installed.txt` as `policy_warnings=`);
#   5. a node with no provable base gets an ADDITIONS-ONLY merge: new rules/components are added, an
#      existing rule is never modified, and the entries the release has and the node lacks are named;
#   6. a node installed before the base record existed is given the OLDEST default in
#      `policies/default.json`'s history whose bytes are its own file as base;
#   7. running it again is a no-op: "kept", the file not rewritten (content, mode, mtime), and the base
#      unchanged;
#   8. the old contract survives: a broken file, a directory, an operator's own component and a tree with
#      no default are still never touched, and a file that is still an unmodified shipped default is
#      refreshed (byte for byte) when the rule merge cannot run.
#
# Fixture histories, not the real `policies/default.json`: the merge is measured on three releases whose
# difference is exactly the shapes above (an added allow entry, an added component, a changed rule).
# Hermetic: temp directories, no cargo, no network, no node server. `node` runs the merge tool, so without
# it the merge cases are reported SKIPPED and the file says so - it is never reported as a run that tested
# them.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT_DIR/scripts/lib/install-default-policy.sh"
TOOL="$ROOT_DIR/scripts/lib/policy-merge.mjs"
DEFAULT="$ROOT_DIR/policies/default.json"
DEPLOY="$ROOT_DIR/scripts/deploy.sh"

checks=0
skipped=0
fail() { echo "test-install-default-policy: $*" >&2; exit 1; }
ok() { checks=$((checks + 1)); echo "ok   $1${2:+ - $2}"; }
skip() { skipped=$((skipped + 1)); echo "SKIP $1 - $2"; }
# File identity for "untouched": content, size, permission bits and mtime. `stat` is GNU here and
# BSD there; either answer is fine, a missing one is not (an unmeasurable file is not "unchanged").
stamp() { # file -> content|size|mode|mtime
  local file="$1" content size mode mtime
  content="$(cksum < "$file")" || fail "cannot read $file"
  size="$(wc -c < "$file" | tr -d ' ')" || fail "cannot size $file"
  mode="$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null)"
  mtime="$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)"
  [ -n "$mode" ] && [ -n "$mtime" ] || fail "cannot stat $file"
  printf '%s|%s|%s|%s' "$content" "$size" "$mode" "$mtime"
}
# One value out of a policy file, as JSON text (`<absent>` when it is not there). The path is `:`-separated
# because a capability name is `kv.write`, which a `.`-separated path would read as two keys. The file path
# is passed as an argument, so the platform's own path translation applies.
jget() { # file path/in/the/document
  node -e '
const fs = require("node:fs");
let cur = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const key of process.argv[2].split(":")) cur = cur === undefined || cur === null ? undefined : cur[key];
process.stdout.write(cur === undefined ? "<absent>" : JSON.stringify(cur));
' "$1" "$2"
}

[ -f "$HELPER" ] || fail "no $HELPER to test"
[ -f "$TOOL" ] || fail "no $TOOL: the per-rule merge the deploy runs is missing"
[ -f "$DEFAULT" ] || fail "no $DEFAULT: the release ships no default policy"
[ -f "$DEPLOY" ] || fail "no $DEPLOY to test"
# shellcheck disable=SC1090
. "$HELPER" || fail "cannot source $HELPER"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-default-policy-XXXXXX")" || fail "no scratch directory"
trap 'rm -rf "$WORK"' EXIT

# --- the shipped file itself -------------------------------------------------------------------
# The merge copies and compares JSON, so the parseability of the shipped file is checked where it is
# enforced (`cargo test -p wa-governance node_policy::tests`, which also drives the calls the components
# in this tree make). What is checked here is that the file is a policy the deploy can name.
[ -s "$DEFAULT" ] || fail "policies/default.json is empty"
grep -q '"version": 1' "$DEFAULT" || fail "policies/default.json does not declare schema version 1"
for component in wa-whatsapp mcp-whatsapp svc-echo mcp-echo; do
  grep -q "\"$component\"" "$DEFAULT" || fail "policies/default.json does not name $component"
done
ok "the shipped default names the components this tree installs"

# --- fixture releases ---------------------------------------------------------------------------
# Three releases of a small policy, differing in exactly the shapes a deploy has to carry:
#   v1 -> v2  adds `ix/*` to a rule the node may or may not have touched, and a new component;
#   v2 -> v3  adds one more component (an addition with no rule change at all).
fixture_v1() {
  cat <<'JSON'
{
  "version": 1,
  "sensitive_capabilities": [],
  "components": {
    "wa-fixture": {
      "note": "fixture release 1",
      "capabilities": {
        "kv.write": {
          "allow": ["dev", "tx/*"],
          "rate": { "per_minute": 240, "burst": 480 }
        },
        "net.dial": {
          "allow": ["127.0.0.1:*"],
          "rate": { "per_minute": 60 }
        }
      }
    }
  }
}
JSON
}
fixture_v2() {
  cat <<'JSON'
{
  "version": 1,
  "sensitive_capabilities": [],
  "components": {
    "wa-fixture": {
      "note": "fixture release 2",
      "capabilities": {
        "kv.write": {
          "allow": ["dev", "tx/*", "ix/*"],
          "rate": { "per_minute": 240, "burst": 480 }
        },
        "net.dial": {
          "allow": ["127.0.0.1:*"],
          "rate": { "per_minute": 60 }
        }
      }
    },
    "mcp-fixture": {
      "note": "fixture component added in release 2",
      "capabilities": {
        "kv.read": {}
      }
    }
  }
}
JSON
}
fixture_v3() {
  cat <<'JSON'
{
  "version": 1,
  "sensitive_capabilities": [],
  "components": {
    "wa-fixture": {
      "note": "fixture release 2",
      "capabilities": {
        "kv.write": {
          "allow": ["dev", "tx/*", "ix/*"],
          "rate": { "per_minute": 240, "burst": 480 }
        },
        "net.dial": {
          "allow": ["127.0.0.1:*"],
          "rate": { "per_minute": 60 }
        }
      }
    },
    "mcp-fixture": {
      "note": "fixture component added in release 2",
      "capabilities": {
        "kv.read": {}
      }
    },
    "svc-fixture": {
      "note": "fixture component added in release 3",
      "capabilities": {
        "kv.read": {}
      }
    }
  }
}
JSON
}
# A node's own edit of ONE rule of v1: its own per-minute cap on the dial, a rule release 2 does not touch.
fixture_v1_net_edited() {
  cat <<'JSON'
{
  "version": 1,
  "sensitive_capabilities": [],
  "components": {
    "wa-fixture": {
      "note": "fixture release 1",
      "capabilities": {
        "kv.write": {
          "allow": ["dev", "tx/*"],
          "rate": { "per_minute": 240, "burst": 480 }
        },
        "net.dial": {
          "allow": ["127.0.0.1:*"],
          "rate": { "per_minute": 5 }
        }
      }
    }
  }
}
JSON
}
# A node's own edit of the rule release 2 DOES change: both sides changed it.
fixture_v1_kv_narrowed() {
  cat <<'JSON'
{
  "version": 1,
  "sensitive_capabilities": [],
  "components": {
    "wa-fixture": {
      "note": "fixture release 1",
      "capabilities": {
        "kv.write": {
          "allow": ["dev"],
          "rate": { "per_minute": 240, "burst": 480 }
        },
        "net.dial": {
          "allow": ["127.0.0.1:*"],
          "rate": { "per_minute": 60 }
        }
      }
    }
  }
}
JSON
}
# A node's own file that matches no default this tree ever shipped: a hand-written policy.
fixture_handwritten() {
  cat <<'JSON'
{
  "version": 1,
  "components": {
    "wa-fixture": {
      "capabilities": {
        "kv.write": { "allow": ["dev"], "rate": { "per_minute": 60 } }
      }
    }
  }
}
JSON
}

# A fixture tree: `policies/default.json` (the release being installed) plus `policies/shipped/*.json` (the
# release records) plus, when asked, the git history of `policies/default.json` (v1, v2, v3) - which is what
# gives a node installed before the base record existed its base.
make_tree() { # directory [history]
  local tree="$1" history="${2:-1}"
  mkdir -p "$tree/policies/shipped" || fail "cannot stage $tree"
  fixture_v1 > "$tree/policies/shipped/2026-01-01-fixture-v1.json"
  if [ "$history" = 1 ]; then
    git -C "$tree" init -q --initial-branch=main || fail "cannot init the fixture repository"
    git -C "$tree" config user.name "policy fixture"
    git -C "$tree" config user.email "policy@example.invalid"
    fixture_v1 > "$tree/policies/default.json"
    git -C "$tree" add -A >/dev/null 2>&1 && git -C "$tree" commit -qm "fixture release 1" || fail "cannot commit release 1"
    fixture_v2 > "$tree/policies/default.json"
    git -C "$tree" add -A >/dev/null 2>&1 && git -C "$tree" commit -qm "fixture release 2" || fail "cannot commit release 2"
    fixture_v3 > "$tree/policies/default.json"
    git -C "$tree" add -A >/dev/null 2>&1 && git -C "$tree" commit -qm "fixture release 3" || fail "cannot commit release 3"
  else
    fixture_v3 > "$tree/policies/default.json"
  fi
  return 0
}

# The base record a deploy leaves beside the file it installed (the code the deploy runs, not a fixture
# copy of it): `policy.base.json` + its sha256. A node that has one is the common case once this ships.
record_base() { # destination source [label]
  install_default_policy_record_base "$2" "$1" "${3:-installed-from:fixture}"     || fail "cannot record the fixture base for $1"
}

TREE="$WORK/tree"
make_tree "$TREE" 1 || fail "cannot build the fixture tree"
NOGIT="$WORK/no-git"
make_tree "$NOGIT" 0 || fail "cannot build the fixture tree without history"

# --- 1. a node with no policy file gets the default, and the base it came from --------------------
NODE="$WORK/fresh/.wasm-agent"
install_default_policy "$TREE/policies/default.json" "$NODE/policy.json" > "$WORK/fresh.out" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "installing into an empty state directory answered $status: $(cat "$WORK/fresh.out")"
cmp -s "$TREE/policies/default.json" "$NODE/policy.json" || fail "the installed policy is not byte-identical to the shipped default"
[ -f "$NODE/policy.base.json" ] || fail "the install recorded no base: the next release cannot merge per rule"
cmp -s "$TREE/policies/default.json" "$NODE/policy.base.json" || fail "the recorded base is not the default that was installed"
base_sha="$(policy_sha256 "$NODE/policy.base.json")"
recorded_sha="$(sed -n '1s/[[:space:]].*//p' "$NODE/policy.base.sha256" 2>/dev/null)"
[ "$base_sha" = "$recorded_sha" ] || fail "policy.base.sha256 does not name the sha of policy.base.json ($recorded_sha vs $base_sha)"
ok "a state directory with no policy file gets the default, byte for byte, and the base is recorded"

# Installing again is a no-op that says "kept", not a second write.
before="$(stamp "$NODE/policy.json")"
install_default_policy "$TREE/policies/default.json" "$NODE/policy.json" > "$WORK/again.out" 2>&1 || fail "the second install failed: $(cat "$WORK/again.out")"
grep -q 'kept' "$WORK/again.out" || fail "a second install did not say it kept the file: $(cat "$WORK/again.out")"
[ "$(stamp "$NODE/policy.json")" = "$before" ] || fail "a second install rewrote the policy file"
ok "a second deploy keeps the file it installed"

# --- the merge cases (they run the node merge tool) ---------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  for case in "a rule the release added arrives" "a rule the node edited is kept" "a conflict is reported" \
              "no base: additions-only" "the oldest shipped default in history is the base" "a shipped record is the base" \
              "the merge is idempotent"; do
    skip "$case" "node is not on PATH and the per-rule merge is scripts/lib/policy-merge.mjs"
  done
else
  # --- 2. a rule the release ADDED arrives ------------------------------------------------------
  # The 07/11 case, exactly: the node's file is release 1, unedited, and release 2 adds `ix/*` to a rule
  # plus a component. Everything lands, nothing is a conflict.
  ADD="$WORK/add/.wasm-agent"
  mkdir -p "$ADD"
  fixture_v1 > "$ADD/policy.json"
  record_base "$ADD/policy.json" "$TREE/policies/shipped/2026-01-01-fixture-v1.json"
  install_default_policy "$TREE/policies/default.json" "$ADD/policy.json" > "$WORK/add.out" 2>&1 \
    || fail "the add-only merge failed: $(cat "$WORK/add.out")"
  added="$(jget "$ADD/policy.json" components:wa-fixture:capabilities:kv.write:allow)"
  case "$added" in *'"ix/*"'*) ;; *) fail "the rule the release added did not arrive: kv.write allow is $added ($(cat "$WORK/add.out"))" ;; esac
  [ "$(jget "$ADD/policy.json" components:mcp-fixture:note)" = '"fixture component added in release 2"' ] \
    || fail "the component the release added did not arrive"
  grep -q 'conflict' "$WORK/add.out" && fail "an unedited node file produced a conflict: $(cat "$WORK/add.out")"
  grep -q 'rule:wa-fixture/kv.write (changed)' "$WORK/add.out" || fail "the report did not name the applied rule: $(cat "$WORK/add.out")"
  [ "$(policy_merge_warnings "$ADD/policy.json")" = "" ] || fail "an unedited node file produced a warning: $(policy_merge_warnings "$ADD/policy.json")"
  cmp -s "$TREE/policies/default.json" "$ADD/policy.base.json" || fail "the base was not advanced to the release just installed"
  ok "a rule the release added arrives (ix/*), and the base advances to the new default"

  # ...and the file the merge replaced is kept beside it, so a merge the operator disagrees with can be
  # undone by hand instead of by memory.
  cmp -s "$TREE/policies/shipped/2026-01-01-fixture-v1.json" "$ADD/policy.prev.json" \
    || fail "the pre-merge file was not kept at policy.prev.json"
  ok "the file the merge replaced is kept at policy.prev.json"

  # --- 3. a rule the node EDITED is kept, and the rest still lands ------------------------------
  # The node ranked its own dial cap (a rule release 2 does not touch) and never touched kv.write.
  KEPT="$WORK/kept/.wasm-agent"
  mkdir -p "$KEPT"
  fixture_v1_net_edited > "$KEPT/policy.json"
  record_base "$KEPT/policy.json" "$TREE/policies/shipped/2026-01-01-fixture-v1.json"
  install_default_policy "$TREE/policies/default.json" "$KEPT/policy.json" > "$WORK/kept.out" 2>&1 \
    || fail "the merge over an edited rule failed: $(cat "$WORK/kept.out")"
  [ "$(jget "$KEPT/policy.json" components:wa-fixture:capabilities:net.dial:rate:per_minute)" = "5" ] \
    || fail "the operator's own cap was overwritten: $(jget "$KEPT/policy.json" components:wa-fixture:capabilities:net.dial:rate:per_minute)"
  kept_allow="$(jget "$KEPT/policy.json" components:wa-fixture:capabilities:kv.write:allow)"
  case "$kept_allow" in *'"ix/*"'*) ;; *) fail "the release's rule change did not land beside the node's edit: $kept_allow" ;; esac
  grep -q 'conflict' "$WORK/kept.out" && fail "a rule only the node changed was reported as a conflict: $(cat "$WORK/kept.out")"
  ok "a rule the node edited is kept as written, and the release's other changes land"

  # --- 4. a rule BOTH sides changed is a conflict, and the node's version wins -------------------
  CONFLICT="$WORK/conflict/.wasm-agent"
  mkdir -p "$CONFLICT"
  fixture_v1_kv_narrowed > "$CONFLICT/policy.json"
  record_base "$CONFLICT/policy.json" "$TREE/policies/shipped/2026-01-01-fixture-v1.json"
  chmod 640 "$CONFLICT/policy.json" 2>/dev/null || true
  # The mode the operator's file had, whatever this filesystem reports for it: on a filesystem where chmod
  # is a no-op (an NTFS mount answers 644 for everything) this measures 644 -> 644, and the preservation
  # itself is proven only where mode bits are real. Measured, not assumed, either way.
  conflict_mode="$(stat -c %a "$CONFLICT/policy.json" 2>/dev/null || stat -f %Lp "$CONFLICT/policy.json" 2>/dev/null)"
  install_default_policy "$TREE/policies/default.json" "$CONFLICT/policy.json" > "$WORK/conflict.out" 2>&1
  status=$?
  [ "$status" -eq 0 ] || fail "a conflict made the install refuse ($status): $(cat "$WORK/conflict.out")"
  [ "$(jget "$CONFLICT/policy.json" components:wa-fixture:capabilities:kv.write:allow)" = '["dev"]' ] \
    || fail "the node's narrowed rule was replaced: $(jget "$CONFLICT/policy.json" components:wa-fixture:capabilities:kv.write:allow)"
  grep -q 'conflict rule:wa-fixture/kv.write' "$WORK/conflict.out" \
    || fail "the conflict was not printed: $(cat "$WORK/conflict.out")"
  case "$(policy_merge_warnings "$CONFLICT/policy.json")" in
    *rule:wa-fixture/kv.write*) ;;
    *) fail "policy_merge_warnings did not name the conflict: $(policy_merge_warnings "$CONFLICT/policy.json")" ;;
  esac
  # ...and the deploy still brought in what it could: the component release 2 added.
  [ "$(jget "$CONFLICT/policy.json" components:mcp-fixture:note)" = '"fixture component added in release 2"' ] \
    || fail "a conflict on one rule stopped the other additions"
  [ "$(stat -c %a "$CONFLICT/policy.json" 2>/dev/null || stat -f %Lp "$CONFLICT/policy.json" 2>/dev/null)" = "$conflict_mode" ] \
    || fail "the merged file did not keep the operator's mode ($conflict_mode -> $(stat -c %a "$CONFLICT/policy.json" 2>/dev/null || stat -f %Lp "$CONFLICT/policy.json" 2>/dev/null))"
  ok "a conflict keeps the node's version, is printed, is reported as a warning, and the deploy continues"

  # --- 5. no provable base: additions-only, an existing rule never modified ---------------------
  # A hand-written file matches no shipped default and no history. New rules and components are added;
  # the node's own rule is left exactly as it is, and the entries the release has and the node lacks are
  # named so the operator has the one-line edit instead of a refused write.
  NOBASE="$WORK/no-base/.wasm-agent"
  mkdir -p "$NOBASE"
  fixture_handwritten > "$NOBASE/policy.json"
  no_base_before="$(stamp "$NOBASE/policy.json")"
  install_default_policy "$TREE/policies/default.json" "$NOBASE/policy.json" > "$WORK/no-base.out" 2>&1 \
    || fail "the additions-only merge failed: $(cat "$WORK/no-base.out")"
  [ "$(jget "$NOBASE/policy.json" components:wa-fixture:capabilities:kv.write:allow)" = '["dev"]' ] \
    || fail "an additions-only merge modified an existing rule: $(jget "$NOBASE/policy.json" components:wa-fixture:capabilities:kv.write:allow)"
  [ "$(jget "$NOBASE/policy.json" components:wa-fixture:capabilities:kv.write:rate:per_minute)" = "60" ] \
    || fail "an additions-only merge modified an existing rule's rate"
  [ "$(jget "$NOBASE/policy.json" components:mcp-fixture:note)" = '"fixture component added in release 2"' ] \
    || fail "an additions-only merge did not add the release's new component"
  case "$(policy_merge_warnings "$NOBASE/policy.json")" in
    *ix/\**) ;;
    *) fail "the additions-only merge did not name the entries the node lacks: $(policy_merge_warnings "$NOBASE/policy.json")" ;;
  esac
  [ "$(stamp "$NOBASE/policy.json")" != "$no_base_before" ] || fail "the additions-only merge wrote nothing at all"
  ok "no base: new rules are added, an existing rule is never modified, and the missing entries are named"

  # --- 6a. a node installed before the base record existed: the oldest history match is the base ---
  OLD="$WORK/old/.wasm-agent"
  mkdir -p "$OLD"
  fixture_v1 > "$OLD/policy.json"
  install_default_policy "$TREE/policies/default.json" "$OLD/policy.json" > "$WORK/old.out" 2>&1 \
    || fail "the history-based merge failed: $(cat "$WORK/old.out")"
  case "$(sed -n 's/^base=//p' "$OLD/policy.merge.txt")" in
    history:*) ;;
    *) fail "the base was not taken from policies/default.json's history: $(cat "$OLD/policy.merge.txt")" ;;
  esac
  # The node never edited a rule, so the file it ends up with is the release's own bytes.
  cmp -s "$TREE/policies/default.json" "$OLD/policy.json" || fail "an unedited node file was not brought to the release's own bytes"
  ok "a node with no base is merged against the oldest default in history that is its own file"

  # --- 6b. ...and a shipped release record is a base when there is no history --------------------
  RECORD="$WORK/record/.wasm-agent"
  mkdir -p "$RECORD"
  fixture_v1 > "$RECORD/policy.json"
  install_default_policy "$NOGIT/policies/default.json" "$RECORD/policy.json" > "$WORK/record.out" 2>&1 \
    || fail "the shipped-record merge failed: $(cat "$WORK/record.out")"
  case "$(sed -n 's/^base=//p' "$RECORD/policy.merge.txt")" in
    shipped:*) ;;
    *) fail "a shipped release record was not used as the base: $(cat "$RECORD/policy.merge.txt")" ;;
  esac
  ok "a shipped release record (policies/shipped/*.json) is a base when there is no history"

  # --- 7. the merge is idempotent ---------------------------------------------------------------
  after="$(stamp "$ADD/policy.json")"
  install_default_policy "$TREE/policies/default.json" "$ADD/policy.json" > "$WORK/idem.out" 2>&1 \
    || fail "the second deploy over a merged file failed: $(cat "$WORK/idem.out")"
  grep -q 'kept' "$WORK/idem.out" || fail "a second deploy over a merged file did not say 'kept': $(cat "$WORK/idem.out")"
  [ "$(stamp "$ADD/policy.json")" = "$after" ] || fail "a second deploy rewrote a merged policy file"
  install_default_policy "$TREE/policies/default.json" "$ADD/policy.json" > "$WORK/idem2.out" 2>&1
  [ "$(stamp "$ADD/policy.json")" = "$after" ] || fail "a third deploy rewrote a merged policy file"
  ok "the merge happens once: a second and third deploy keep the merged file untouched"
fi

# --- the old contract: an operator's file is not something a deploy replaces ---------------------
# A file that is not JSON at all is still the operator's: the node refuses its sensitive capabilities and
# says why (`Mode::Policy`), and a deploy that replaced it with a default would hide that. It is the one
# case the merge cannot reason about, so it is kept, the deploy says so, and installed.txt warns.
BROKEN="$WORK/broken/.wasm-agent"
mkdir -p "$BROKEN"
printf '{"version":1,"components":{"x":{"capabilities":{"kv.write":{"per_minutes":1}}}' > "$BROKEN/policy.json"
broken_before="$(stamp "$BROKEN/policy.json")"
install_default_policy "$TREE/policies/default.json" "$BROKEN/policy.json" > "$WORK/broken.out" 2>&1 \
  || fail "a broken operator policy made the install fail: $(cat "$WORK/broken.out")"
[ "$(stamp "$BROKEN/policy.json")" = "$broken_before" ] || fail "a policy file that is not JSON was rewritten"
grep -q 'not valid JSON' "$WORK/broken.out" || fail "the deploy did not say the file is not JSON: $(cat "$WORK/broken.out")"
if command -v node >/dev/null 2>&1; then
  case "$(policy_merge_warnings "$BROKEN/policy.json")" in
    *"not valid JSON"*) ;;
    *) fail "a file that is not JSON produced no warning for installed.txt: $(policy_merge_warnings "$BROKEN/policy.json")" ;;
  esac
fi
ok "a policy file that is not JSON is still the operator's, and is not replaced"

# A file that parses but names a field the node's schema would reject is a different thing, and this merge
# does not pretend to be a schema: the operator's own rule stays exactly as written (nothing is dropped or
# rewritten) and the release's rules are added beside it. The node still refuses the file until the
# operator fixes it - the merge neither hides that nor makes it worse.
SCHEMA="$WORK/schema/.wasm-agent"
mkdir -p "$SCHEMA"
printf '{"version":1,"components":{"x":{"capabilities":{"kv.write":{"per_minutes":1}}}}}' > "$SCHEMA/policy.json"
install_default_policy "$TREE/policies/default.json" "$SCHEMA/policy.json" > "$WORK/schema.out" 2>&1 \
  || fail "a schema-invalid operator policy made the install fail: $(cat "$WORK/schema.out")"
grep -q 'per_minutes' "$SCHEMA/policy.json" || fail "a schema-invalid operator rule was dropped by the merge"
ok "a rule the node's schema would reject is still the operator's text, and the merge keeps it"

# A path that exists as something else (a directory) is not something to write through, and is not ours
# to remove.
mkdir -p "$WORK/dir/.wasm-agent/policy.json"
install_default_policy "$TREE/policies/default.json" "$WORK/dir/.wasm-agent/policy.json" > "$WORK/dir.out" 2>&1 \
  || fail "a directory at the policy path made the install fail: $(cat "$WORK/dir.out")"
[ -d "$WORK/dir/.wasm-agent/policy.json" ] || fail "a directory at the policy path was removed"
ok "a directory at the policy path is left alone"

# A component only the node names is the node's: the release never shipped it, so no side of the merge
# has an opinion about it and it survives every run.
if command -v node >/dev/null 2>&1; then
  OWN="$WORK/own/.wasm-agent"
  mkdir -p "$OWN"
  fixture_v1_kv_narrowed > "$OWN/policy.json"
  record_base "$OWN/policy.json" "$TREE/policies/shipped/2026-01-01-fixture-v1.json"
  node -e '
const fs = require("node:fs");
const doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
doc.components["operator-component"] = { note: "the operator added this", capabilities: { "kv.read": {} } };
fs.writeFileSync(process.argv[1], JSON.stringify(doc, null, 2) + "\n");
' "$OWN/policy.json"
  install_default_policy "$TREE/policies/default.json" "$OWN/policy.json" > "$WORK/own.out" 2>&1 \
    || fail "the merge over a node-only component failed: $(cat "$WORK/own.out")"
  [ "$(jget "$OWN/policy.json" components:operator-component:note)" = '"the operator added this"' ] \
    || fail "a component only the node names was dropped by the merge"
  ok "a component only the node names survives the merge"
fi

# --- no default in this tree is a note, not a silently empty install ---------------------------
NOTHING="$WORK/nothing/.wasm-agent"
install_default_policy "$WORK/there-is-no-such-default.json" "$NOTHING/policy.json" > "$WORK/none.out" 2>&1
[ $? -eq 2 ] || fail "a missing default did not answer 2 (nothing installed)"
[ ! -e "$NOTHING/policy.json" ] || fail "a missing default still created a policy file"
ok "a tree without policies/default.json installs nothing and says so"

# --- a file that is still an unmodified shipped default is refreshed when the merge cannot run ----
# Two ways the per-rule merge cannot run, both real: `node` is not on PATH (the deploy needs it, so this is
# the broken-host case), and the merge tool is not beside the installer (the installed copy of deploy.sh has
# no `scripts/lib/`). In both, a file whose bytes are a default this tree shipped is refreshed - nobody's
# choice is being overwritten - and anything else is kept with the reason.
#
# `node` is made absent with a `command` shim rather than a stripped PATH: a PATH without the platform's own
# DLL directories cannot run bash at all on Windows (measured: `error while loading shared libraries`), so a
# stripped PATH would test the harness, not the branch. The shim answers only the one question the branch
# asks (`command -v node`) and passes everything else through.
FALLBACK="$WORK/fallback/.wasm-agent"
mkdir -p "$FALLBACK"
cp -f "$TREE/policies/shipped/2026-01-01-fixture-v1.json" "$FALLBACK/policy.json"
bash -c '
  set -uo pipefail
  . "$1"
  command() {
    case "$1" in
      -v) case "$2" in node) return 1 ;; esac ;;
    esac
    builtin command "$@"
  }
  install_default_policy "$2" "$3"
' _ "$HELPER" "$TREE/policies/default.json" "$FALLBACK/policy.json" > "$WORK/fallback.out" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "the fallback refresh answered $status: $(cat "$WORK/fallback.out")"
grep -q 'node is not on PATH' "$WORK/fallback.out" || fail "the fallback did not say why it could not merge: $(cat "$WORK/fallback.out")"
cmp -s "$TREE/policies/default.json" "$FALLBACK/policy.json" || fail "the fallback did not refresh an unmodified shipped default"
ok "without node an unmodified shipped default is still refreshed, byte for byte"

# ...and a file the release cannot prove is its own is kept, with the reason.
EDITED="$WORK/edited/.wasm-agent"
mkdir -p "$EDITED"
fixture_v1_net_edited > "$EDITED/policy.json"
edited_before="$(stamp "$EDITED/policy.json")"
bash -c '
  set -uo pipefail
  . "$1"
  command() {
    case "$1" in
      -v) case "$2" in node) return 1 ;; esac ;;
    esac
    builtin command "$@"
  }
  install_default_policy "$2" "$3"
' _ "$HELPER" "$TREE/policies/default.json" "$EDITED/policy.json" > "$WORK/edited.out" 2>&1
grep -q 'kept' "$WORK/edited.out" || fail "an edited policy was not kept by the fallback: $(cat "$WORK/edited.out")"
[ "$(stamp "$EDITED/policy.json")" = "$edited_before" ] || fail "an edited policy file was rewritten by the fallback"
ok "without node an edited policy file is kept, byte for byte"

# The other half of the same branch: the installer without the merge tool beside it (the installed copy of
# deploy.sh). A shipped default is refreshed here too, and an edited file is kept.
LONE_LIB="$WORK/lone-lib"
mkdir -p "$LONE_LIB"
cp -f "$HELPER" "$LONE_LIB/install-default-policy.sh"
[ ! -e "$LONE_LIB/policy-merge.mjs" ] || fail "the lone installer copy still carries the merge tool"
LONE="$WORK/lone/.wasm-agent"
mkdir -p "$LONE"
cp -f "$TREE/policies/shipped/2026-01-01-fixture-v1.json" "$LONE/policy.json"
bash -c 'set -uo pipefail; . "$1"; install_default_policy "$2" "$3"' _ "$LONE_LIB/install-default-policy.sh" \
  "$TREE/policies/default.json" "$LONE/policy.json" > "$WORK/lone.out" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "the installer without its merge tool answered $status: $(cat "$WORK/lone.out")"
grep -q 'not beside the installer' "$WORK/lone.out" || fail "the installer did not say the merge tool is missing: $(cat "$WORK/lone.out")"
cmp -s "$TREE/policies/default.json" "$LONE/policy.json" || fail "an installer without the merge tool did not refresh a shipped default"
ok "an installer without the merge tool still refreshes a shipped default, and says why it cannot merge"

# --- nothing is left half-written --------------------------------------------------------------
# The staging names only: `policy.merge.txt` is state (the report installed.txt is fed from), and is not a
# leftover.
staged_files() { # -> every staging file under the scratch tree
  find "$WORK" \( -name 'policy.json.merge.*' -o -name 'policy.json.refresh.*' -o -name 'policy.json.install.*'     -o -name '.policy.base.json.[0-9]*' -o -name '.policy.base.sha256.[0-9]*' -o -name '.policy.prev.json.[0-9]*' \) 2>/dev/null
}
[ -z "$(staged_files)" ] || fail "the install left staging files behind: $(staged_files)"
ok "no staging file is left beside a policy file"

# The report the deploy reads its installed.txt warning from is state, and it is there after a merge.
if command -v node >/dev/null 2>&1; then
  [ -f "$CONFLICT/policy.merge.txt" ] || fail "a merge left no policy.merge.txt to warn from"
  grep -q '^mode=three-way' "$CONFLICT/policy.merge.txt" || fail "policy.merge.txt does not say how the merge ran"
  grep -q '^conflict=' "$CONFLICT/policy.merge.txt" || fail "policy.merge.txt does not record the conflict"
  ok "a merge leaves its report in policy.merge.txt, which is what installed.txt is warned from"
fi

# --- the deploy calls it, and records what the merge could not do ------------------------------
# Structural, and deliberately so: the deploy cannot be run here (it installs). What must not regress is
# that the call exists, that it is the helper, that the warning reaches installed.txt, and that the reason
# for "only if absent" is written beside it - the next person to "keep the default fresh" has to delete a
# paragraph, not a line.
grep -q 'install_default_policy' "$DEPLOY" || fail "deploy.sh no longer installs the default policy"
grep -q 'scripts/lib/install-default-policy.sh' "$DEPLOY" || fail "deploy.sh no longer uses the tested helper"
grep -q 'policy_merge_warnings' "$DEPLOY" || fail "deploy.sh no longer collects what the rule merge could not bring in"
grep -q 'policy_warnings=' "$DEPLOY" || fail "deploy.sh no longer records the policy warning in installed.txt"
grep -q 'manifest mode' "$DEPLOY" || fail "deploy.sh no longer says what a node without a policy file does"
grep -q 'policy_unlisted_components' "$DEPLOY" || fail "deploy.sh no longer names installed components the policy does not"
ok "deploy.sh installs the default through the helper, records the merge's warnings, and names the unruled components"

# --- a component the shipped default does not name is named ------------------------------------
# This is the sentence that turns "wa-whatsapp stopped writing kv after the upgrade" into a line
# read before the restart: the file exists, so an unlisted component loses its sensitive
# capabilities (no_policy) until a rule is added for it.
COMPONENTS="$WORK/components"
mkdir -p "$COMPONENTS"
: > "$COMPONENTS/wa-whatsapp.wasm"
: > "$COMPONENTS/some-new-component.wasm"
unlisted="$(policy_unlisted_components "$DEFAULT" "$COMPONENTS")"
[ "$unlisted" = "some-new-component" ] || fail "unlisted components answered '$unlisted'"
ok "an installed component the policy does not name is reported"

if [ "$skipped" -gt 0 ]; then
  echo "test-install-default-policy: $checks checks passed, $skipped SKIPPED (node is not on PATH: the per-rule merge is scripts/lib/policy-merge.mjs)"
else
  echo "test-install-default-policy: $checks checks passed"
fi
