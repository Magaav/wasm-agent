-- One source for every WIT package a component vendors in its own `wit/deps/`.
--
--   lua5.4 scripts/gen-wit-deps.lua --write    # rewrite every deps copy from its canonical file
--   lua5.4 scripts/gen-wit-deps.lua --check    # exit 1, naming each copy that differs
--   lua5.4 scripts/gen-wit-deps.lua --list     # the manifest as '<out>\t<sources>', one per line
--
-- WHY THIS FILE EXISTS (22/11). Measured on main 44479b7f: TEN `kernel.wit` files in SEVEN different
-- contents (161, 181, 206, 321, 390, 82 and 45 lines), seven `clocks.wit` in two, `bus.wit` and
-- `queue.wit` in one each, and the dates climbed with the line counts. Nothing copied them from one
-- place: each component vendored the interface as it stood the day it was built, and two seams carry
-- hand-trimmed subsets. Re-measured block by block against the canonical text, every shared block of
-- every copy was a verbatim slice with the same declarations - so no component is built against a
-- contract the host disagrees with today, and nothing in the tree said so. What had silently drifted
-- was the trimming: `svc-queue-echo`'s copy kept the first line of a doc comment and dropped the rest,
-- and `wit/memory` and `wit/selfloop` had lost the doc comments inside `interface types` altogether. A
-- hand edit of the kind that produced those is one line away from a copy that drops a function, which
-- is a component built against one contract and refused at run time by another.
-- WHAT A COPY IS, exactly one of two things, and nothing else:
--   * the canonical file BYTE FOR BYTE (`keep = '*'`), so a full copy costs nothing to verify;
--   * a NAMED LIST of blocks (interfaces and worlds) sliced out of the canonical file, in the canonical
--     file's own order, each with the doc comment or `@` attribute directly above it and copied verbatim.
--     The list is written out here rather than inferred: a seam that drops an interface says which one,
--     and a name that no longer exists in the canonical file is a FAILURE that names it, not a silent
--     omission (a trim that quietly lost `drain` would build against a contract that has no drain).
-- The canonical files are the ones the host is built against - `wit/kernel/kernel.wit` and
-- `wit/kernel/sql.wit` for `wa:kernel@0.1.0` (`rust/wa-kernel-runtime/src/service_components.rs`,
-- `sql_host.rs`), `wit/kernel-v2/kernel.wit` for `wa:kernel@0.2.0`
-- (`rust/wa-kernel-runtime/src/service_components_v2.rs`), `wit/bus/bus.wit`, `wit/queue/queue.wit`, and
-- the four `wasi:*` packages vendored once in `wit/kernel-v2/deps/`.
--
-- HOW IT IS KEPT HONEST: the same module is loaded by `scripts/test-wit-deps.lua` (a never-dropped fast
-- row), which recomputes every byte and fails BY NAME when a copy is not what this would write, when a
-- `.wit` under a `deps/` directory is not in this manifest at all, and when a block a copy declares
-- differs from the canonical block of the same name. The generator itself is registered in
-- `scripts/generators.txt`, so `bash scripts/regenerate.sh` runs it on every landing's merged tree.

local TARGETS = {
  -- wa-email and wa-whatsapp import `wa:kernel/types`, `drain` (whatsapp) and `vision` (whatsapp), so
  -- they carry the whole 0.2 package: a full copy, byte for byte.
  { out = 'rust/components/wa-email/wit/deps/kernel.wit', from = 'wit/kernel-v2/kernel.wit', keep = '*' },
  { out = 'rust/components/wa-whatsapp/wit/deps/kernel.wit', from = 'wit/kernel-v2/kernel.wit', keep = '*' },

  -- svc-drain imports `wa:kernel/drain` and nothing else of the kernel's.
  { out = 'rust/components/svc-drain/wit/deps/kernel.wit', from = 'wit/kernel-v2/kernel.wit',
    keep = { 'types', 'websocket', 'http', 'speech', 'kv', 'lifecycle', 'drain', 'log', 'credentials',
             'service', 'service-component' } },

  -- model-gateway imports `credentials`, `http`, `kv` and `log`; it does not read images, hold a key or
  -- speak the wasi:keyvalue shape, so `vision`, `keystore` and `service-vision` are not vendored.
  { out = 'rust/components/model-gateway/wit/deps/kernel.wit', from = 'wit/kernel-v2/kernel.wit',
    keep = { 'types', 'websocket', 'http', 'speech', 'kv', 'lifecycle', 'drain', 'log', 'credentials',
             'service', 'keyvalue', 'config', 'service-component', 'service-drain', 'wasi-probe-env',
             'wasi-probe-stdin', 'wasi-probe-fs', 'wasi-probe-net', 'keyvalue-config', 'wasi-probe-kv' } },

  -- svc-queue-echo and telemetry-sink import `wa:bus` and `wa:queue` and no `wa:kernel` interface at
  -- all; their deps copies stay because the package resolves them from `deps/`, and they stay
  -- generated in case one of them grows a kernel import.
  { out = 'rust/components/svc-queue-echo/wit/deps/kernel.wit', from = 'wit/kernel-v2/kernel.wit',
    keep = { 'types', 'websocket', 'http', 'speech', 'kv', 'lifecycle', 'log', 'credentials', 'service',
             'service-component' } },
  { out = 'rust/components/telemetry-sink/wit/deps/kernel.wit', from = 'wit/kernel-v2/kernel.wit',
    keep = { 'types', 'websocket', 'http', 'speech', 'kv', 'lifecycle', 'log', 'credentials', 'service',
             'service-component' } },

  -- The two seams that stand on `wa:kernel/sql` keep `types` and `sql`, out of the 0.1 package, and no
  -- world: their own `.wit` declares the world they are built as.
  { out = 'wit/memory/deps/kernel/kernel.wit',
    parts = { { from = 'wit/kernel/kernel.wit', keep = { 'types' } },
              { from = 'wit/kernel/sql.wit', keep = { 'sql' } } } },
  { out = 'wit/selfloop/deps/kernel/kernel.wit',
    parts = { { from = 'wit/kernel/kernel.wit', keep = { 'types' } },
              { from = 'wit/kernel/sql.wit', keep = { 'sql' } } } },

  -- wasi:clocks, as version 0.3.0: a full copy where the component imports `wall-clock` and
  -- `monotonic-clock`, and a trim where it only needs the two clocks, not `timezone` or a world.
  { out = 'rust/components/wa-email/wit/deps/clocks.wit', from = 'wit/kernel-v2/deps/clocks.wit', keep = '*' },
  { out = 'rust/components/wa-whatsapp/wit/deps/clocks.wit', from = 'wit/kernel-v2/deps/clocks.wit', keep = '*' },
  { out = 'rust/components/model-gateway/wit/deps/clocks.wit', from = 'wit/kernel-v2/deps/clocks.wit', keep = '*' },
  { out = 'rust/components/svc-drain/wit/deps/clocks.wit', from = 'wit/kernel-v2/deps/clocks.wit',
    keep = { 'types', 'monotonic-clock', 'system-clock' } },
  { out = 'rust/components/svc-queue-echo/wit/deps/clocks.wit', from = 'wit/kernel-v2/deps/clocks.wit',
    keep = { 'types', 'monotonic-clock', 'system-clock' } },
  { out = 'rust/components/telemetry-sink/wit/deps/clocks.wit', from = 'wit/kernel-v2/deps/clocks.wit',
    keep = { 'types', 'monotonic-clock', 'system-clock' } },

  -- The three `wasi:*` packages a wasip2 build always resolves beside the kernel, plus `wa:bus` and
  -- `wa:queue`: full copies, one source each.
  { out = 'rust/components/model-gateway/wit/deps/cli.wit', from = 'wit/kernel-v2/deps/cli.wit', keep = '*' },
  { out = 'rust/components/model-gateway/wit/deps/filesystem.wit', from = 'wit/kernel-v2/deps/filesystem.wit', keep = '*' },
  { out = 'rust/components/model-gateway/wit/deps/random.wit', from = 'wit/kernel-v2/deps/random.wit', keep = '*' },
  { out = 'rust/components/model-gateway/wit/deps/sockets.wit', from = 'wit/kernel-v2/deps/sockets.wit', keep = '*' },
  { out = 'rust/components/wa-email/wit/deps/cli.wit', from = 'wit/kernel-v2/deps/cli.wit', keep = '*' },
  { out = 'rust/components/wa-email/wit/deps/filesystem.wit', from = 'wit/kernel-v2/deps/filesystem.wit', keep = '*' },
  { out = 'rust/components/wa-email/wit/deps/random.wit', from = 'wit/kernel-v2/deps/random.wit', keep = '*' },
  { out = 'rust/components/wa-email/wit/deps/sockets.wit', from = 'wit/kernel-v2/deps/sockets.wit', keep = '*' },
  { out = 'rust/components/wa-whatsapp/wit/deps/cli.wit', from = 'wit/kernel-v2/deps/cli.wit', keep = '*' },
  { out = 'rust/components/wa-whatsapp/wit/deps/filesystem.wit', from = 'wit/kernel-v2/deps/filesystem.wit', keep = '*' },
  { out = 'rust/components/wa-whatsapp/wit/deps/random.wit', from = 'wit/kernel-v2/deps/random.wit', keep = '*' },
  { out = 'rust/components/wa-whatsapp/wit/deps/sockets.wit', from = 'wit/kernel-v2/deps/sockets.wit', keep = '*' },
  { out = 'rust/components/telemetry-sink/wit/deps/telemetry.wit', from = 'wit/telemetry/telemetry.wit', keep = '*' },
  { out = 'rust/components/svc-queue-echo/wit/deps/bus.wit', from = 'wit/bus/bus.wit', keep = '*' },
  { out = 'rust/components/telemetry-sink/wit/deps/bus.wit', from = 'wit/bus/bus.wit', keep = '*' },
  { out = 'rust/components/wa-email/wit/deps/bus/bus.wit', from = 'wit/bus/bus.wit', keep = '*' },
  { out = 'rust/components/svc-drain/wit/deps/queue/queue.wit', from = 'wit/queue/queue.wit', keep = '*' },
  { out = 'rust/components/svc-queue-echo/wit/deps/queue/queue.wit', from = 'wit/queue/queue.wit', keep = '*' },
  { out = 'rust/components/wa-email/wit/deps/queue/queue.wit', from = 'wit/queue/queue.wit', keep = '*' },
  { out = 'rust/components/wa-whatsapp/wit/deps/queue/queue.wit', from = 'wit/queue/queue.wit', keep = '*' },
}

-- Files that live under a `deps/` directory and are NOT a copy of another file in this tree: the
-- package's own interface, put where its component's build resolves it. Named here, with the reason, so
-- the allow-list in scripts/test-wit-deps.lua names them instead of passing over every deps file it does
-- not recognise (an allow-list that skipped the unknown would pass when a copy appeared by hand).
local PACKAGE_LOCAL = {
  { path = 'wit/codemode/deps/kernel/quickjs.wit',
    why = 'the ONLY `wa:kernel/quickjs` definition in this tree: `rg -l "interface quickjs" wit/ '
      .. 'rust/components/` finds this file and no other, so there is no canonical text to slice it from. '
      .. 'The sandbox it declares is served by the Rust host (rust/wa-capabilities/src/quickjs.rs), and '
      .. 'the file says so in its own header.' },
}

local M = { targets = TARGETS, package_local = PACKAGE_LOCAL }


local function read_file(path)
  local handle = io.open(path, 'rb')
  if not handle then return nil end
  local text = handle:read('a')
  handle:close()
  return text
end

-- Lines without their newline; a final newline is not an extra empty line.
local function split_lines(text)
  local lines = {}
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = line end
  if lines[#lines] == '' then lines[#lines] = nil end
  return lines
end

-- The comment directly above a declaration, and its `@since(...)`-style attributes: walking up over
-- `///` and `@` lines and stopping at the first line that is neither. A blank line ends the block, so a
-- doc comment that belongs to the file's header is never pulled into a slice.
local function doc_start(lines, keyword_line)
  local start = keyword_line
  local n = keyword_line - 1
  while n >= 1 do
    local trimmed = lines[n]:gsub('^%s+', ''):gsub('%s+$', '')
    if trimmed:sub(1, 3) == '///' or trimmed:sub(1, 1) == '@' then
      start = n
      n = n - 1
    else
      break
    end
  end
  return start
end

-- The top-level blocks of one WIT file: every `interface NAME {` and `world NAME {`, with the line it
-- starts on (its doc comment included), the line its closing brace is on, and the package line. Braces
-- inside a `//` comment do not open anything: the comment is cut before they are counted. The bytes are
-- never rewritten - a slice is copied out of `lines` as they are.
local function scan(path, text)
  local lines = split_lines(text)
  local blocks, by_name, package_line = {}, {}, nil
  local depth, open = 0, nil
  for n, line in ipairs(lines) do
    local code = line
    local cut = code:find('//', 1, true)
    if cut then code = code:sub(1, cut - 1) end
    if depth == 0 then
      if not package_line and code:match('^package%s') then package_line = n end
      local kind, name = code:match('^%s*(interface)%s+([%w_%-]+)')
      if not kind then kind, name = code:match('^%s*(world)%s+([%w_%-]+)') end
      if kind then open = { kind = kind, name = name, start = n, opened = false } end
    end
    for brace in code:gmatch('[{}]') do
      if brace == '{' then
        depth = depth + 1
        if open then open.opened = true end
      else
        depth = depth - 1
      end
    end
    if open and open.opened and depth == 0 then
      open.stop = n
      open.doc_start = doc_start(lines, open.start)
      if by_name[open.name] then
        error(string.format('wit-deps: %s declares %s twice', path, open.name), 0)
      end
      by_name[open.name] = open
      blocks[#blocks + 1] = open
      open = nil
    end
  end
  if open then
    error(string.format('wit-deps: %s opens %s %s on line %d and never closes it', path, open.kind,
      open.name, open.start), 0)
  end
  if not package_line then error(string.format('wit-deps: %s has no `package ...;` line', path), 0) end
  return { path = path, text = text, lines = lines, blocks = blocks, by_name = by_name,
           package_line = package_line }
end

local contexts = {}
local function context(path)
  if contexts[path] then return contexts[path] end
  local text = read_file(path)
  if not text then
    error(string.format('wit-deps: canonical file %s is missing or unreadable', path), 0)
  end
  contexts[path] = scan(path, text)
  return contexts[path]
end

-- A target as a list of parts, so a copy that takes blocks from two canonical files (the memory and
-- selfloop seams take `types` from the kernel and `sql` from its own file) is still one slice per file.
local function parts_of(target)
  if target.parts then return target.parts end
  return { { from = target.from, keep = target.keep } }
end

local function header_lines(target, parts)
  local out = {
    '// GENERATED by scripts/gen-wit-deps.lua - do not edit by hand.',
    '//',
    '// A hand edit here fails scripts/test-wit-deps.lua, and `bash scripts/regenerate.sh` puts the',
    '// canonical text back. What is kept, and from where:',
  }
  for _, part in ipairs(parts) do
    out[#out + 1] = string.format('//   %s: %s', part.from, table.concat(part.keep, ', '))
  end
  out[#out + 1] = '//'
  out[#out + 1] = '// Every block below is a verbatim slice of its file, in that file' .. "'" .. 's order, with the doc'
  out[#out + 1] = '// comment above it. The canonical file is the source; this one only says what is kept.'
  return out
end

local function render_target(target)
  local parts = parts_of(target)
  if #parts == 0 then error(string.format('wit-deps: %s declares no source', target.out), 0) end
  -- keep = '*' is a full copy: the canonical bytes, unchanged, so the file cannot drift by a byte.
  if #parts == 1 and parts[1].keep == '*' then
    return context(parts[1].from).text, { parts[1].from }
  end
  local out, sources = {}, {}
  for _, part in ipairs(header_lines(target, parts)) do out[#out + 1] = part end
  out[#out + 1] = ''
  out[#out + 1] = context(parts[1].from).lines[context(parts[1].from).package_line]
  local sliced = 0
  for _, part in ipairs(parts) do
    if type(part.keep) ~= 'table' or #part.keep == 0 then
      error(string.format('wit-deps: %s keeps nothing from %s - say \'*\' for a full copy', target.out,
        part.from), 0)
    end
    local ctx = context(part.from)
    sources[#sources + 1] = part.from
    local keeping = {}
    for _, name in ipairs(part.keep) do
      if keeping[name] then
        error(string.format('wit-deps: %s keeps %s from %s twice', target.out, name, part.from), 0)
      end
      keeping[name] = true
      if not ctx.by_name[name] then
        error(string.format('wit-deps: %s keeps %s, which %s does not declare', target.out, name,
          part.from), 0)
      end
    end
    -- Canonical order, not the order of the keep list: the copy reads like the file it came from.
    for _, block in ipairs(ctx.blocks) do
      if keeping[block.name] then
        out[#out + 1] = ''
        for n = block.doc_start, block.stop do out[#out + 1] = ctx.lines[n] end
        sliced = sliced + 1
      end
    end
  end
  local wanted = 0
  for _, part in ipairs(parts) do wanted = wanted + #part.keep end
  if sliced ~= wanted then
    error(string.format('wit-deps: %s sliced %d block(s) for %d kept name(s)', target.out, sliced,
      wanted), 0)
  end
  out[#out + 1] = ''
  return table.concat(out, '\n'), sources
end

-- Every copy this script owns: what to write where, and the canonical files it came from.
function M.plan()
  local plan, by_out, sources = {}, {}, {}
  for _, target in ipairs(TARGETS) do
    if by_out[target.out] then
      error(string.format('wit-deps: %s is declared twice in this script', target.out), 0)
    end
    by_out[target.out] = true
    local text, from = render_target(target)
    plan[#plan + 1] = { out = target.out, text = text, sources = from }
    for _, path in ipairs(from) do sources[#sources + 1] = path end
  end
  for _, entry in ipairs(plan) do
    for _, path in ipairs(entry.sources) do
      if by_out[path] then
        error(string.format('wit-deps: %s is both a canonical file and a copy of %s', path, entry.out), 0)
      end
    end
  end
  table.sort(sources)
  local unique = {}
  for _, path in ipairs(sources) do
    if unique[#unique] ~= path then unique[#unique + 1] = path end
  end
  M.source_list = unique
  return plan
end

function M.sources()
  if not M.source_list then M.plan() end
  return M.source_list
end

function M.package_local_paths()
  local out = {}
  for _, entry in ipairs(PACKAGE_LOCAL) do out[#out + 1] = entry.path end
  return out
end

function M.outputs()
  local out = {}
  for _, target in ipairs(TARGETS) do out[#out + 1] = target.out end
  return out
end

-- An empty line and a missing line are different facts and must not read the same: a copy that gained a
-- blank line is not a copy that lost a block.
function M.show(line)
  if line == nil then return '<end of file>' end
  if line == '' then return '<blank line>' end
  return string.format('%q', line)
end

-- The first line on which `expected` and `actual` differ, as { line = n, expected = .., actual = .. }, or
-- nil when they are the same bytes. Named, because "stale" without a line is a search.
function M.difference(expected, actual)
  if expected == actual then return nil end
  local want = split_lines(expected)
  local have = split_lines(actual or '')
  local n = 1
  while n <= #want or n <= #have do
    if want[n] ~= have[n] then
      return { line = n, expected = want[n], actual = have[n] }
    end
    n = n + 1
  end
  -- Same lines, different trailing bytes (a missing or doubled final newline).
  return { line = #have, expected = want[#want], actual = have[#have] }
end

-- The blocks a file declares, by name, with their declaration text: what the "no copy may disagree on a
-- block it shares" rule is checked against (scripts/test-wit-deps.lua).
function M.blocks_of(path)
  return context(path)
end

local function main()
  local mode = arg and arg[1] or ''
  if mode == '--list' then
    for _, target in ipairs(TARGETS) do
      local parts, names = parts_of(target), {}
      for _, part in ipairs(parts) do names[#names + 1] = part.from end
      print(target.out .. '\t' .. table.concat(names, ','))
    end
    return 0
  end
  local plan = M.plan()
  if mode == '--check' then
    local stale = 0
    for _, entry in ipairs(plan) do
      local current = read_file(entry.out)
      if current == nil then
        stale = stale + 1
        print(string.format('wit-deps: MISSING %s (the manifest names it; run bash scripts/regenerate.sh)',
          entry.out))
      else
        local diff = M.difference(entry.text, current)
        if diff then
          stale = stale + 1
          print(string.format('wit-deps: STALE %s (line %d: want %s, have %s)', entry.out, diff.line,
            M.show(diff.expected), M.show(diff.actual)))
        end
      end
    end
    if stale == 0 then
      print(string.format('wit-deps: %d deps copies are exactly what their canonical files say', #plan))
      return 0
    end
    print(string.format('wit-deps: %d of %d deps copies differ from their canonical files - run bash scripts/regenerate.sh',
      stale, #plan))
    return 1
  end
  local written, same = 0, 0
  for _, entry in ipairs(plan) do
    local current = read_file(entry.out)
    if current == entry.text then
      same = same + 1
    else
      local handle = assert(io.open(entry.out, 'wb'))
      handle:write(entry.text)
      handle:close()
      written = written + 1
      print(string.format('wit-deps: wrote %s from %s', entry.out, table.concat(entry.sources, ', ')))
    end
  end
  print(string.format('wit-deps: %d deps copies from %d canonical file(s): %d written, %d already exact',
    #plan, #M.sources(), written, same))
  return 0
end

M.main = main
if arg and arg[1] and (arg[1] == '--write' or arg[1] == '--check' or arg[1] == '--list') then
  os.exit(main())
end
return M
