-- What a bash result carries to the caller (mission slim-tool-results, Victor 22/11).
--
-- Measured on the base of this branch, one real run block, command `echo hi`: 38 fields and 1,408 bytes
-- of JSON for 3 bytes of stdout. Over the last 200 recorded results the envelope was 2,111 bytes per
-- call median against 756 bytes of fields a caller acts on (docs/missions/reports/write-names-its-node.md),
-- and 179 of those bytes per call were the PEER's filesystem paths. pi and Claude Code both hand the model
-- the text and the exit code and keep the rest behind one pointer; this module is that pointer's local half.
--
-- The pointer already existed and this module only uses it: every field dropped here is on the
-- OPERATION RECORD, written by the operation manager before any of this runs, and
-- `operation {action="status", id=<operation_id>}` answers that record verbatim (published RPC
-- `status` -> `manager().status`, rust/wa-capabilities/src/operations.rs; the record's own fields are
-- written in rust/wa-operation/src/lib.rs). Nothing is lost - it stops being copied into the window.
--
-- AN ALLOW-LIST, because a block-list grows one measurement at a time and lets the next field through:
-- the caller receives the keys named in KEEP and nothing else. The rule behind the list:
--   * keep what a caller ACTS on - the two streams, the exit code, ok, the node, the operation id (the
--     handle), the timeout, the truncation facts and every hint or refusal sentence;
--   * drop what only describes the call - clocks (timing, *_elapsed_ms, elapsed_ms, last_output_elapsed_ms),
--     ownership (owner, owner_boot, owner_process_id, session), the launch directory (cwd, cwd_requested,
--     cwd_source, effective_cwd), containment and priority (containment, cpu_priority), cleanup
--     bookkeeping (cleanup, cleanup_budget_ms), duplicate state (state, status, process_exit_code,
--     process_exit_elapsed_ms, settled, promoted, adopted, overdue, output_streams_closed) and the
--     record's own file paths (stdout_path, stderr_path - the peer's layout, on a remote call).
-- A result that is not a command envelope (no stdout and no code - a transport refusal, an admission
-- refusal, a `{state:"pending"}` handle) is passed through UNTOUCHED: unknown is not empty, and a shape
-- this module does not recognise is not one it may rewrite.
local M = {}

M.KEEP = {
  stdout = true, stderr = true, code = true, ok = true, node = true,
  operation_id = true, timeout_ms = true,
  stdout_truncated = true, stderr_truncated = true, output_truncated = true, output_complete = true,
  stdout_elided_bytes = true, stderr_elided_bytes = true, stdout_bytes = true, stderr_bytes = true,
  -- Hints and refusals, which are what a caller acts on: the pointer to the omitted body, the Windows
  -- staged-script note ($0 is the file path), and the words every refusal carries.
  output_hint = true, staged_script_note = true,
  -- A refusal is what a caller acts on, and so is the name of what refused: the path guard's
  -- `blocked_by`/`blocked_reason` and a hook's `denied_by`/`permission` (scripts/test-path-guard-canary.lua
  -- asserts the first pair; a refusal that says only "no" is the round the model spends guessing).
  error = true, note = true, fix = true, normalized = true,
  blocked_by = true, blocked_reason = true, denied_by = true, permission = true,
}

-- One command's envelope: the streams or an exit code. Every other shape is somebody else's answer.
local function envelope(value)
  return type(value) == 'table'
    and (type(value.stdout) == 'string' or type(value.code) == 'number')
end

-- The caller's copy: the kept keys, in a fresh table, so nothing else in the process can be reached
-- through the answer it hands out.
function M.slim(value)
  if not envelope(value) then return value end
  local out = {}
  for key, item in pairs(value) do if M.KEEP[key] then out[key] = item end end
  return out
end

-- Which answer is a command's, decided by the call that asked for it, never by the answer's own text:
-- `bash` here, and a peer's `bash` through `remote` - one call or an entry of a read-only batch.
-- A peer that predates this shape answers fat; the caller slims it, so an old node costs the caller
-- nothing new and the shape a script reads is the same whoever ran the command.
function M.slim_for(name, args, value)
  if type(value) ~= 'table' then return value end
  if name == 'bash' then return M.slim(value) end
  if name ~= 'remote' or type(args) ~= 'table' then return value end
  if args.capability == 'bash' then return M.slim(value) end
  local calls, results = args.calls, value.results
  if args.capability == 'batch' and type(calls) == 'table' and type(results) == 'table' then
    local out, changed = nil, false
    for index, entry in ipairs(calls) do
      if type(entry) == 'table' and entry.capability == 'bash' then
        local slimmed = M.slim(results[index])
        if slimmed ~= results[index] then
          if not out then
            out = {}
            for key, item in pairs(value) do out[key] = item end
            out.results = {}
            for position, item in ipairs(results) do out.results[position] = item end
          end
          out.results[index] = slimmed
          changed = true
        end
      end
    end
    if changed then return out end
  end
  return value
end

return M
