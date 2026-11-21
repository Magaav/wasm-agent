# Two spellings of one commit id. `git rev-parse --short` picks its own length (8 hex in this repository
# on 21/11, more as it grows) while a binary reports 12, so comparing the strings refused a correct install
# as build_commit_mismatch (deploy of bcacbf38, 21/11). Two ids are the same commit when they agree on
# their common prefix - and that prefix must be at least 7 hex, or it says nothing.
wa_same_commit() { # <id> <id> -> 0 same, 1 different or too short to tell
  local a="${1:-}" b="${2:-}" n
  n=${#a}; [ ${#b} -lt "$n" ] && n=${#b}
  [ "$n" -ge 7 ] || return 1
  case "$a$b" in *[!0-9a-f]*) return 1 ;; esac
  [ "${a:0:$n}" = "${b:0:$n}" ]
}
