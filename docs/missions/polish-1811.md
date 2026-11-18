# Mission change/polish-1811 — friction measured in Victor's real session 378934d2 on work (18/11)

Session: 06:39-07:44, 189 messages, 90 tool calls, 13 failed, ~3.8M tokens; tasks: local installer search,
GitHub MCP candidates. Each item: failing-then-passing test, quoted in REPORT.md. Build here only; no push.

1. 30 s codemode default budget: 8 of 13 failures were TimeoutError (gh search, bash, operation). Make the
   budget follow the work (network/search/operation calls get a longer default) or continue the script as a
   managed operation automatically instead of killing it. The model must never redo finished calls.
2. Hyphenated tool names: `tools.mcp_colmeio-cloud_...` -> TypeError. Offer an identifier-safe alias
   (underscores) everywhere names are shown; the error quotes the call and gives the bracket form.
3. Schema guessing: `schema_required:arguments.action`, `schema_enum:wait_for`, `setTimeout is not
   defined`. Every schema error carries one valid example call; the sandbox error for setTimeout names the
   supported wait.
4. A bash `--help` hung with no timeout. Compare with Claude Code (default 120 s, per-call timeout up to
   10 min, background run option) and pi before choosing; Victor 18/11: take theirs or a better one.
   Proposed: every bash call has a default timeout stated in its result; at the timeout the process is
   moved to a managed background operation (output kept, pollable) instead of killed; non-interactive by
   construction - stdin=/dev/null, PAGER=cat, GIT_PAGER=cat, no TTY - since a pager waiting for input is the
   likely cause of the `--help` hang. Prove the cause before the fix.
5. Resume after deploy waited the full bound: paused 07:09:55 ("1786s left"), resumed 07:39:59. Resume on
   the deploy-finished event (or the node's next healthy start), not at the bound.
6. Language. The rule exists (agent.lua:229 `s.language`: "Reply in the language of the user's latest
   message ..."), so the envelope did not lose it. Answer 189 came in Portuguese right after an automated
   `[self-wake ...]` message, which arrives in the user role: "the user's latest message" was not the
   human's. Fix the mechanism, not with a law: automated user-role messages (self-wake, session update,
   deploy notices) are marked as automated and are never the referent; the human's latest own message is.
   The changed `s.language` text must be shown to Victor verbatim before landing (envelope rule).
(Item 7, user-facing self-report / pause wording: skipped by Victor 18/11, not in this mission.)
