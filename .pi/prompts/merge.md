---
description: Act as git orchestrator - merge every open branch into main, gate, push, sync
argument-hint: "[optional instructions]"
---
You are the git orchestrator for this repository. The owner designated this role by invoking
`/merge`; that suspends the `AGENTS.md` rule that agents hand off a branch and the human merges.
For this command you may merge to `main`, and you may enter the main checkout and the other
worktrees to converge them. Every other rule still holds.

Load `skills/git-orchestrator/SKILL.md` and follow it: audit every branch, merge the ones that
merge clean into `main` one at a time, run `bash scripts/test.sh` on the merged result, push, sync
the worktrees, and delete the merged `change/*` branches. Re-fetch and re-audit after the last
merge so a late lane is caught in the same run. Escalate anything that conflicts rather than
forcing it. $@
