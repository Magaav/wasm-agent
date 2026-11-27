# The canonical runtime binding: asked before the build, and asked AGAIN at install.
#
# Sourced by `deploy.sh`. Both answers are the same question - "which checkout does this node run from, and is
# it clean and equal to main?" - and the reason to ask twice is the ~4 minutes of build and prove in between: a
# second worktree on branch main can appear, and main can move under a checkout, while nobody is looking.
#
# Measured 18/11 (review, item 9). The preflight answer was exported as `WA_RUNTIME_WORKTREE`, so the
# install-time block saw the value already set and skipped its own run entirely: the re-check after the long
# build was gone. The preflight answer is kept in its OWN variable now, and the two answers are compared.
#
# wa_runtime_binding_path ANSWER: the directory an answer names, resolved when it exists (so two spellings of
# one path, or a relative and an absolute one, compare equal).
#
# wa_runtime_binding_recheck PREFLIGHT INSTALL
#   prints nothing, returns 0: the install answer is the preflight answer (or there was no preflight answer
#     because the operator set the binding explicitly);
#   prints the refusal naming BOTH answers and returns 1: they disagree.
wa_runtime_binding_path() {
  if [ -n "${1:-}" ] && [ -d "${1:-}" ]; then
    (cd "$1" 2>/dev/null && pwd) || printf '%s' "$1"
  else
    printf '%s' "${1:-}"
  fi
}

wa_runtime_binding_recheck() {
  local preflight install
  [ -n "${1:-}" ] || return 0
  preflight="$(wa_runtime_binding_path "$1")"
  install="$(wa_runtime_binding_path "${2:-}")"
  [ "$preflight" = "$install" ] && return 0
  printf 'canonical runtime binding changed during the build: the preflight chose %s, the install re-check chose %s; nothing was installed - re-run the deploy\n' "$preflight" "$install"
  return 1
}

# WHAT MOVED SINCE THE PREFLIGHT (Victor on work, 27/11). The install-time binding question is the same question
# the preflight asked, so when it fails late the useful sentence is the DIFFERENCE, not the rule again: the ref, the
# sha the build started from, and the sha the tree has now. Prints '' when nothing can be said, so it never invents.
wa_runtime_binding_moved_note() { # <repo> <preflight-head> <preflight-main>
  local repo="${1:-}" head="${2:-}" main="${3:-}" now_head now_main ref
  [ -n "$repo" ] && [ -d "$repo" ] || return 0
  ref="${WA_DEPLOY_MAIN_REF:-origin/main}"
  now_head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
  now_main="$(git -C "$repo" rev-parse "$ref" 2>/dev/null || true)"
  [ -n "$now_head" ] || return 0
  if [ -n "$head" ] && [ "$head" = "$now_head" ] && [ -n "$now_main" ] && [ "$main" != "$now_main" ]; then
    printf ' (%s moved during the build: it was %s when the preflight read it, it is %s now; the tree is still on %s - the bytes that were built)' \
      "$ref" "${main:0:12}" "${now_main:0:12}" "${now_head:0:12}"
  elif [ -n "$head" ] && [ "$head" != "$now_head" ]; then
    printf ' (the tree moved during the build: the preflight read HEAD %s, the tree is on %s now)' "${head:0:12}" "${now_head:0:12}"
  fi
}
