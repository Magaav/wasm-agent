# Mission change/fleet-view — see and enter every session in the fabric from the CLI

Victor 18/11: one chat point to control the whole fabric; from the wa text area, `<` opens a panel of all nodes
and the agents working on each; enter any session to watch it; `>` goes back to the selected session.
UI/command layer only (Lua + UI, hot-reloadable); no prompt/envelope change in this mission.
Built ON the fabric API defined by change/mastermind (nodes, sessions, follow, parent->child): the view calls
the API and never reads nodes/sessions on its own - one implementation, three faces (CLI, Fleet View, bridge).
1. Key binding, without breaking editing: Left arrow / `<` opens Fleet View only when the text area is empty or
   the cursor is at column 0 (otherwise it moves the cursor as today); Esc or `>` returns.
2. Fleet View panel: every node of the roster with online state, role, load; under each node the sessions
   running there (master, subagents, missions/operations) with title, state (running/waiting/failed/done),
   round count, tokens, age. Remote nodes are read through the mesh (one bounded call per node, cached a few
   seconds, never blocking the master chat); an unreachable node says so instead of hiding.
3. Enter a session: Enter or `>` on a row opens a live, read-only view of that session's transcript (local or
   remote, streamed or polled); `<` goes back to the panel; `>` from the panel returns to the previously
   selected session; one key returns to the master chat. Sending a message into another session is a later step.
4. A one-line fabric status in the master chat's status bar (nodes online, sessions running, failures).
Done when: a scripted TUI test (replay-events / the repo's UI test path) drives `<`, selection, Enter, `<`, `>`,
Esc with fixture nodes and sessions; screenshots via the repo's UI check; no regression in text editing (Left
arrow mid-text still moves the cursor). Build/test on this node only; never push.
