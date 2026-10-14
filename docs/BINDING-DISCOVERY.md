# Binding-aware capability discovery

The operator requested a fix for two avoidable `client` open/status attempts that both returned `workspace_execution_context_unsupported` in a required worktree. Permission and execution support are different facts; discovering a permitted tool must expose this distinction before invoking it.

## Contract

`capabilities` retains its permitted name list and adds a caller-scoped workspace snapshot plus per-tool `execution` metadata. `tool_search` returns the same exact native schema with separate execution metadata and a per-result `loaded` flag. A blocked or unknown tool is not loaded; rediscovery removes its stale load name. Its exact definition and original transcript remain evidence. Bootstrap schemas do not expand when discovery runs.

Metadata is explicitly `scope:workspace_policy_only`. `workspace_binding` says supported, unsupported, action-dependent or not-applicable. `status` says blocked, unknown, argument-dependent or not-blocked. Only blocked tools carry `available:false`; no metadata claims complete executability or grants authority. Permissions, profile, target identity, arguments, directory/path/cwd, stale definitions and effects are still checked at invocation.

One read-only workspace snapshot serves a discovery/capabilities call. No client/browser/peer/app/executor probe runs. Guest and approved-profile catalogue ceilings remain; the capabilities list now applies the same exact child catalogue as discovery. Workspace paths are not exposed in metadata. Conditional tools (operation start, MCP probe/non-read operations) are not falsely advertised as entirely executable or blocked.

Required allocated bindings still refuse client, shell, remote and spell_run. A failed required binding remains unavailable; reads can still inspect/recover evidence. Unknown metadata is not an executable claim. Native dispatcher conditions share the same fixed-tool classification and are not weakened. A later workspace change can invalidate prior discovery; actual preflight remains decisive.

For a blocked client, guidance says **do not invoke it or retry status**. Provide an existing artifact link or state the limitation. Do not clear a workspace, use another executor/identity, move work to an unbound session, or run a desktop action through node-local Bash to bypass the refusal. Runtime client failures still use the normal status-first diagnosis when that capability is executable. Static client/schema guidance and `client-controls` explain that exception for full/legacy sessions too.

## Verification and limits

`test-binding-discovery.lua` checks scoped discovery, exact schemas, stable declarations, blocked load persistence, role/profile fences, one-snapshot reads, conditional tools, missing/unknown bindings, binding drift and unchanged direct refusals. A deterministic artifact-view plan follows discovery and makes0 client attempts/refusals instead of2; separate negative guard tests still exercise the refusals. A private old-tools control must fail the same metadata oracle. Run source and embedded seed/restart in private processes; no real client, app, browser or provider is contacted.

The verified `binding-discovery-proof` spell records `node scripts/test-binding-discovery.cjs <built-wa> <fresh-evidence>` and its retained-hash `--post`; required workspaces use the same verified direct CLI. Source/embedded native proof and old-tools control passed. Native MCP (88checks), MCP restart/no-replay (58checks) and typed routing/cursor reconstruction (158checks) passed with their retained-hash postchecks. The graph audit supplied the MCP restart caller as a useful regression lead, not a correctness certificate.

Initial private native bootstrap bytes changed26874→26886 (+12 schema bytes); system17292 and11 tools are unchanged. AGENTS.md remains10389bytes. This is a measured description/inspectability tradeoff, not billed tokens or savings.

This removes a known refused choice from the measured deterministic plan. It does not prove autonomous planning quality, make bound client execution supported, or turn permission into readiness. Discovery adds on-demand metadata bytes and a small static schema-description delta; AGENTS.md is unchanged. Original refusals and uncertain effects remain. Installation requires the supported exact-source Sentinel path and fresh verification.
