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
