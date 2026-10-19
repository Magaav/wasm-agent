-- What a shell result is, and what a caller may conclude from it.
--
-- `host.exec` hands back a BOUNDED view of each stream: the first 8 KiB and the last 16 KiB with
-- an elision marker line between them once the middle is dropped (the total stays the 24 KiB it
-- always was; see docs/HOST.md). So:
--   * the beginning of a long output is present - the view is no longer a pure tail - and the
--     first line survives clipping, which is what a first-line parse needs;
--   * the MIDDLE is not present, so "absent from the view" never proves "absent from the output".
--     A guard that decides absence from a clipped view is exactly the bug this module exists to
--     prevent (`wave_canonical_main_missing` was raised against a healthy repository because a
--     26 KB `git worktree list` lost its first line);
--   * when all of an output is needed, it is read from the retained original at `stdout_path`,
--     which is what `complete()` does below.
--
-- A refusal never blames the repository for this: when the input a guard needed was clipped and
-- the whole output cannot be read, the error is named `output_truncated_requires_bounded_command`.
local json=dofile('lua/vendor/json.lua')
local M={}
M.TRUNCATED='output_truncated_requires_bounded_command'
-- Caller-side ceiling for reading a retained original. Above it the answer is a bounded command
-- or an explicit refusal, never a silent partial read.
M.MAX_COMPLETE_BYTES=16*1024*1024

-- The elision marker a bounded view inserts when the middle of a stream was dropped.
-- A line-oriented counter must skip it: it is a note from the host, not a line of command output.
M.ELISION_PATTERN='%[%d+ bytes elided by the host[^%]]*%]'
function M.is_elision(line)
  return type(line)=='string' and line:find(M.ELISION_PATTERN)~=nil
end

-- Did the host drop bytes from this result's view? The old host sets only `output_truncated`;
-- a host that predates both fields says nothing, and an absent flag is read as "not clipped"
-- so an existing caller keeps working.
function M.truncated(result)
  if type(result)~='table' then return false end
  return result.output_truncated==true or result.stdout_truncated==true
end

-- One command, decoded. A non-zero exit is returned, not raised: git's exit 1 is an answer.
function M.run(command,cwd,seconds)
  local ok,raw=pcall(host.exec,command,cwd or '',seconds or 120)
  if not ok then return nil,'command_exec_failed: '..tostring(raw) end
  local decoded,result=pcall(json.decode,raw or '')
  if not decoded or type(result)~='table' then return nil,'command_result_invalid' end
  return result
end

-- The view exactly as the host rendered it. Correct for "did it print anything?", the first
-- line, the last line, and a containment check in a trailer. Never for a count or for absence.
function M.preview(result)
  if type(result)~='table' then return '' end
  return tostring(result.stdout or '')
end

-- All of stdout. When the view was clipped this reads the retained original instead of letting a
-- caller mistake the view for the whole answer. Raises the named error when that is unavailable.
function M.complete(result,what)
  what=what or 'command stdout'
  if type(result)~='table' then error(M.TRUNCATED..': '..what..' has no result to read',0) end
  if not M.truncated(result) then return M.preview(result) end
  local path=result.stdout_path
  if type(path)=='string' and path~='' and host.read_file then
    local ok,text=pcall(host.read_file,path)
    if ok and type(text)=='string' and #text<=M.MAX_COMPLETE_BYTES then return text end
  end
  error(string.format('%s: %s was clipped by the bounded exec view and its retained original is unreadable; ask a bounded command for the fact instead of reading a listing that cannot fit',M.TRUNCATED,what),0)
end

return M
