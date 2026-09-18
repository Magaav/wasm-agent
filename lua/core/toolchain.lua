-- The toolchains this node needs to build and test *itself*, and how to get them on its own
-- machine.
--
-- A node that can only be built somewhere else is not independent. The cloud was the only machine
-- with a Rust toolchain and a cross-linker, so a host change waited for it, and a build was
-- impossible whenever that machine was unreachable - which is a bad property for something that is
-- supposed to reproduce itself. The toolchains are ordinary packages, so the node can install
-- them; this module is the list, the check, and the install.
--
-- Three verbs, deliberately separate: `check` reports, `plan` prints the exact commands, `ensure`
-- runs them. Looking never installs anything, and `ensure` prints what it is about to run as it
-- runs it, because an install is a visible act on somebody's machine and not a side effect of a
-- build. Every tool carries the reason it is wanted: a node missing a toolchain should be able to
-- say what it therefore cannot do.
local platform = dofile("lua/core/platform.lua")

local M = {}

local function os_name()
  local ok, value = pcall(platform.os)
  if ok and type(value) == "string" and value ~= "" then return value end
  return "unknown"
end

-- One entry per toolchain. `probe` is a command that exits 0 when the toolchain resolves - the
-- distinction that matters, because a systemd service does not inherit a login shell's PATH, so
-- `cargo` can be installed and still unreachable.
local function wanted()
  local here = os_name()
  local list = {
    {
      id = "git",
      why = "clone, sync and commit this node's work",
      probe = "git --version",
      install = {
        windows = "winget install --id Git.Git -e --accept-source-agreements",
        linux = "sudo apt-get install -y git",
        darwin = "brew install git",
      },
    },
    {
      id = "cargo",
      why = "build this node's host from source",
      probe = "cargo --version",
      install = {
        windows = "winget install --id Rustlang.Rustup -e --accept-source-agreements --accept-package-agreements",
        linux = "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y",
        darwin = "brew install rustup && rustup default stable",
      },
    },
    {
      id = "cc",
      why = "link the native dependencies (sqlite, ring)",
      probe = here == "windows" and "cc --version" or "cc --version",
      install = {
        -- The *workload* is the whole point on Windows: Build Tools without VCTools installs no
        -- compiler at all, so `cc` still fails and the node still cannot build - which is worse
        -- than installing nothing, because it looks done. VCTools is what provides cl.exe, and
        -- --includeRecommended brings the Windows SDK it needs to link against.
        windows = "winget install --id Microsoft.VisualStudio.2022.BuildTools -e " ..
          "--accept-source-agreements --accept-package-agreements " ..
          '--override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"',
        linux = "sudo apt-get install -y build-essential",
        darwin = "xcode-select --install",
      },
    },
    {
      id = "node",
      why = "run the UI and composer harnesses",
      probe = "node --version",
      install = {
        windows = "winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements",
        linux = "sudo apt-get install -y nodejs",
        darwin = "brew install node",
      },
    },
  }
  -- Only a machine that builds the Windows binary from a non-Windows one needs the cross linker.
  -- Asking a Linux node for it is the difference between "you cannot build" and "you cannot build
  -- the Windows target", and the second is a much smaller problem.
  if here ~= "windows" then
    list[#list + 1] = {
      id = "mingw",
      why = "build the Windows binary from this node (wa-window)",
      probe = "x86_64-w64-mingw32-gcc --version",
      install = { linux = "sudo apt-get install -y mingw-w64", darwin = "brew install mingw-w64" },
    }
  end
  return list
end

M.wanted = wanted

-- host.exec hands back a JSON string, not a table.
local function run(command)
  local ok, raw = pcall(host.exec, command)
  if not ok or type(raw) ~= "string" then
    return { code = -1, stdout = "", stderr = tostring(raw) }
  end
  local decoded_ok, decoded = pcall(dofile("lua/vendor/json.lua").decode, raw)
  if not decoded_ok or type(decoded) ~= "table" then
    return { code = -1, stdout = "", stderr = raw }
  end
  return decoded
end

function M.check()
  local tools, missing = {}, {}
  for _, tool in ipairs(wanted()) do
    local result = run(tool.probe)
    local ready = tonumber(result.code or -1) == 0
    local detail = tostring(result.stdout or ""):gsub("%s+$", "")
    if detail == "" then detail = tostring(result.stderr or ""):gsub("%s+$", "") end
    tools[#tools + 1] = {
      id = tool.id, why = tool.why, probe = tool.probe, ready = ready,
      detail = detail:sub(1, 120),
    }
    if not ready then missing[#missing + 1] = tool.id end
  end
  return { tools = tools, missing = missing, ready = #missing == 0, os = os_name() }
end

-- The exact commands this machine would need, for the toolchains that are actually missing. This
-- is what a person reads before deciding, and what `ensure` runs.
function M.plan()
  local here = os_name()
  local report = M.check()
  local ready = {}
  for _, row in ipairs(report.tools) do ready[row.id] = row.ready end
  local commands = {}
  for _, tool in ipairs(wanted()) do
    if not ready[tool.id] then
      local command = (tool.install or {})[here]
      if command then
        commands[#commands + 1] = { id = tool.id, why = tool.why, command = command }
      else
        commands[#commands + 1] = { id = tool.id, why = tool.why, command = nil,
          note = "no install command known for " .. here }
      end
    end
  end
  return { commands = commands, os = here, missing = report.missing, ready = report.ready }
end

-- Run the plan. Refuses without `confirmed`, so no code path can install software by accident; the
-- CLI passes it only when `--yes` was typed.
function M.ensure(opts)
  opts = opts or {}
  local plan = M.plan()
  if #plan.commands == 0 then
    return { ok = true, ran = {}, note = "every toolchain this node wants already resolves" }
  end
  if not opts.confirmed then
    return { ok = false, ran = {}, refused = true, commands = plan.commands,
      note = "not confirmed: nothing was installed" }
  end
  local ran = {}
  for _, item in ipairs(plan.commands) do
    if item.command then
      print("  installing " .. item.id .. " (" .. item.why .. ")")
      print("    " .. item.command)
      local result = run(item.command)
      local code = tonumber(result.code or -1)
      ran[#ran + 1] = { id = item.id, code = code, output = tostring(result.stderr or result.stdout or ""):sub(-500) }
      print("    -> exit " .. code)
    else
      ran[#ran + 1] = { id = item.id, code = -1, output = item.note or "no command" }
      print("  " .. item.id .. ": " .. (item.note or "no install command known"))
    end
  end
  local after = M.check()
  return {
    ok = after.ready, ran = ran, missing = after.missing,
    note = after.ready and "all toolchains resolve now" or ("still missing: " .. table.concat(after.missing, " ")),
  }
end

-- A one-line summary for `wa status`, which is where a person looks when a build fails.
function M.line()
  local report = M.check()
  local parts = {}
  for _, tool in ipairs(report.tools) do
    parts[#parts + 1] = tool.id .. "=" .. (tool.ready and "yes" or "no")
  end
  local line = table.concat(parts, " ")
  if not report.ready then
    line = line .. "  (missing: " .. table.concat(report.missing, " ") .. " - `wa toolchain plan` says how, `wa toolchain ensure --yes` does it)"
  end
  return line
end

-- A longer bracket than `[[`: the text itself contains `]]` (from `[--yes]`), which would close a
-- plain long string early and leave the rest of the file as code.
local TOOLCHAIN_HELP = [==[usage: wa toolchain [check | plan | ensure [--yes]]

  check    report which toolchains resolve on this machine (read-only)
  plan     print the exact install commands for the ones that do not (read-only)
  ensure   run those commands, with --yes. Nothing else installs anything, ever.

A node that can build itself can be reproduced without the machine it was written on.]==]

function M.cli(args)
  args = args or {}
  local verb = args[2] or "check"
  if verb == "--help" or verb == "-h" or verb == "help" then
    print(TOOLCHAIN_HELP)
    return 0
  end
  if verb == "check" then
    local report = M.check()
    print("  toolchains on this node (" .. report.os .. "):")
    for _, tool in ipairs(report.tools) do
      print(string.format("   %-6s %-4s %s%s", tool.id, tool.ready and "yes" or "no", tool.why,
        tool.ready and ("  (" .. tool.detail .. ")") or ""))
    end
    if report.ready then
      print("  every one resolves: this node can build itself")
    else
      print("  missing: " .. table.concat(report.missing, " ") .. " - `wa toolchain plan` to see how")
    end
    return report.ready and 0 or 1
  end
  if verb == "plan" then
    local plan = M.plan()
    if #plan.commands == 0 then
      print("  nothing to install: every toolchain this node wants already resolves")
      return 0
    end
    print("  to make this node able to build itself, on " .. plan.os .. ":")
    for _, item in ipairs(plan.commands) do
      print("   " .. item.id .. " (" .. item.why .. ")")
      print("     " .. (item.command or (item.note or "no command known")))
    end
    print("  run them: wa toolchain ensure --yes")
    return 0
  end
  if verb == "ensure" then
    local confirmed = false
    for _, arg in ipairs(args) do
      if arg == "--yes" or arg == "-y" then confirmed = true end
    end
    local result = M.ensure({ confirmed = confirmed })
    if result.refused then
      print("  nothing installed. This would run:")
      for _, item in ipairs(result.commands) do
        print("   " .. item.id .. ": " .. (item.command or item.note or ""))
      end
      print("  re-run with --yes to do it.")
      return 2
    end
    print("  " .. (result.note or ""))
    return result.ok and 0 or 1
  end
  print(TOOLCHAIN_HELP)
  return 2
end

return M
