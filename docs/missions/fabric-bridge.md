# Mission change/fabric-bridge — wa exposes its fabric so any harness can drive it (MCP server)

Victor 18/11: orchestration must be reachable not only from wa's own sessions but from other harnesses (Claude
Code, others) - "so it could expose itself for other harness to control it". Today wa only CONSUMES MCP servers
("connectors": mail, WhatsApp, ...); it serves none. Naming: inbound = connectors (wa uses others), outbound =
the bridge (others use wa).
1. One fabric API, one implementation: the same operations wa's master uses internally (mastermind mission) -
   fleet.nodes, sessions.list/read(follow), session.send, fork, spawn worker (node, brief), cancel, resume,
   collect, mission.stage/start/status/report, land.status - are the ONLY backend; the in-CLI orchestration,
   Fleet View and the bridge all call it. No second copy for the bridge.
2. Decided (Claude, 18/11, Victor delegated): server name `wa-fabric`, command `wa bridge serve`; tool names
   prefixed by object. The tool set must enable FULL orchestration, nothing the in-CLI master can do is missing:
   fabric_nodes, fabric_status (one-line fabric summary), node_health; sessions_list, session_follow (live,
   read-only), session_send, session_fork, session_cancel, session_resume; worker_spawn (node, brief, base),
   worker_collect (answer, commits, files, failures as data), worker_cancel, worker_resume; mission_stage,
   mission_start, mission_status, mission_report, mission_verify, mission_clean; review_start (independent
   reviewer on a branch), review_result; land_plan (dry run), land_start, land_status, land_resume;
   deploy_status, node_update (canary/ring), node_rollback. Destructive/fleet-wide ones (land_start,
   node_update, node_rollback, mission_clean) need the control scope and are audited; reads need read scope.
   `wa bridge serve` - an MCP server (stdio for a local harness; Streamable HTTP on loopback for a remote one
   behind the mesh), tools mapped 1:1 to the fabric API, read tools and write tools separated in the manifest.
3. Security, because this is a control surface over every node: stdio is the local operator only; HTTP needs a
   bridge token held in the vault (operator-issued, scoped read|control, revocable), never in the URL; every
   write call audited (who, which tool, which session/node); the bridge can never read vault values or the
   secret paths (same secret_guard), and a remote node still applies its own admission.
4. A Claude Code recipe in docs (user-level, outside any company repo): `claude mcp add wa-fabric -- wa bridge
   serve` so a Claude session can list nodes, follow sessions and spawn/steer workers through the bridge.
Done when: an external MCP client (the repo's own MCP test client, then Claude Code) lists the fleet, follows a
live session, spawns a worker on another node and cancels it - all through the bridge, all audited; read-only
token refused on write tools. Prompt/envelope text verbatim to Victor before landing. Never push.
