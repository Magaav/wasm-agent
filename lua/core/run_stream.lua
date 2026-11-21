-- The run tool's `code` argument, decoded WHILE the model is still writing it.
--
-- A native tool call reaches this process as a stream of argument FRAGMENTS (a `tool_call_delta`
-- per provider chunk), and each one is a slice of the JSON object `{"code":"...","raw":{...}}`
-- taken at an arbitrary byte offset: a fragment ends inside an escape (`\n`, `\"`, `\u00e9`),
-- between the hex digits of a `\uXXXX`, or inside the key itself. `json.decode` cannot read that - a
-- half-written string is the NORMAL state of every fragment after the first, not an error to
-- repair - so this is an incremental scanner: it walks the object at its top level, finds `code`,
-- and decodes the string value as the bytes arrive, holding a partial escape until the rest comes.
--
-- It never guesses the tool name: the caller feeds fragments of one call, and `M.new()` is one call.
-- Pure: no host call, no global state. `feed` answers the text the fragment ADDED (""), which is
-- what a view writes; `text` answers everything decoded so far, which is what a redraw uses.
local M = {}

local ESCAPE = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r',
  t = '\t' }
local REPLACEMENT = '\239\191\189'   -- U+FFFD, what every reader of a broken escape shows

-- One code point as UTF-8.
local function utf8(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

function M.new()
  return { phase = 'start', depth = 0, key = '', esc = nil, hex = '', high = nil,
    parts = {}, bytes = 0 }
end

-- The code value has started (so the view may open its block), and has finished.
function M.active(state) return state.phase == 'value' or state.phase == 'done' end
function M.done(state) return state.phase == 'done' end
function M.text(state) return table.concat(state.parts) end

local function append(state, out, piece)
  if piece == nil or piece == '' then return end
  state.parts[#state.parts + 1] = piece
  state.bytes = state.bytes + #piece
  out[#out + 1] = piece
end

-- A `\uXXXX` code point, honoring a surrogate pair split across escapes (or across fragments).
local function unicode(state, cp)
  if cp >= 0xD800 and cp <= 0xDBFF then state.high = cp return nil end
  if cp >= 0xDC00 and cp <= 0xDFFF then
    local high = state.high
    state.high = nil
    if high then return utf8(0x10000 + (high - 0xD800) * 0x400 + (cp - 0xDC00)) end
    return REPLACEMENT
  end
  local high = state.high
  state.high = nil
  return (high and REPLACEMENT or '') .. utf8(cp)
end

-- One character inside the `code` STRING. Answers whether the string ENDED on it.
-- `state.esc` is nil (ordinary), '' (a backslash arrived, the next char names the escape) or 'u'
-- (collecting the four hex digits of a \uXXXX, which may itself be split across fragments).
local function code_char(state, ch, out)
  local esc = state.esc
  if esc == 'u' then
    if ch:match('^[%x]$') then
      state.hex = state.hex .. ch
      if #state.hex == 4 then
        local cp = tonumber(state.hex, 16)
        state.hex, state.esc = '', nil
        append(state, out, unicode(state, cp))
      end
    else
      -- A broken \u: say so, then read this character as ordinary content.
      state.hex, state.esc = '', nil
      local high = state.high
      state.high = nil
      append(state, out, (high and REPLACEMENT or '') .. REPLACEMENT)
      return code_char(state, ch, out)
    end
    return false
  end
  if esc then
    local high = state.high
    state.high = nil
    if high then append(state, out, REPLACEMENT) end
    if ch == 'u' then
      state.esc, state.hex = 'u', ''
    else
      state.esc = nil
      append(state, out, ESCAPE[ch] or ch)
    end
    return false
  end
  if ch == '\\' then state.esc = '' return false end
  if ch == '"' then return true end
  local high = state.high
  state.high = nil
  if high then append(state, out, REPLACEMENT) end
  append(state, out, ch)
  return false
end

-- Feed one argument fragment. Answers the text this fragment added to `code` ("" when nothing).
function M.feed(state, chunk)
  if type(chunk) ~= 'string' or chunk == '' or state.phase == 'done' then return '' end
  local out = {}
  local index = 1
  while index <= #chunk do
    local ch = chunk:sub(index, index)
    local phase = state.phase
    if phase == 'start' then
      if ch == '{' then state.phase = 'key_pre' end
    elseif phase == 'key_pre' then
      if ch == '"' then state.key, state.esc, state.phase = '', nil, 'key' end
    elseif phase == 'key' then
      if state.esc then
        local letter = state.esc
        state.esc = nil
        state.key = state.key .. (ESCAPE[letter] or letter)
      elseif ch == '\\' then
        state.esc = 'x'
      elseif ch == '"' then
        state.phase = 'colon'
      else
        state.key = state.key .. ch
      end
    elseif phase == 'colon' then
      if ch == ':' then state.phase = 'value_pre' end
    elseif phase == 'value_pre' then
      if ch == '"' then
        state.esc, state.hex, state.high = nil, '', nil
        state.phase = (state.key == 'code') and 'value' or 'other'
      elseif ch == '{' or ch == '[' then
        state.phase, state.depth, state.instr, state.esc = 'nested', 1, false, nil
      elseif ch == '}' then
        state.phase = 'done'
      elseif ch == ',' then
        state.phase = 'key_pre'
      end
    elseif phase == 'value' then
      if code_char(state, ch, out) then state.phase = 'comma' end
    elseif phase == 'other' then
      if state.esc then state.esc = nil
      elseif ch == '\\' then state.esc = 'x'
      elseif ch == '"' then state.phase = 'comma' end
    elseif phase == 'nested' then
      if state.instr then
        if state.esc then state.esc = nil
        elseif ch == '\\' then state.esc = 'x'
        elseif ch == '"' then state.instr = false end
      elseif ch == '"' then state.instr = true
      elseif ch == '{' or ch == '[' then state.depth = state.depth + 1
      elseif ch == '}' or ch == ']' then
        state.depth = state.depth - 1
        if state.depth <= 0 then state.phase = 'comma' end
      end
    elseif phase == 'comma' then
      if ch == ',' then state.phase = 'key_pre'
      elseif ch == '}' then state.phase = 'done' end
    end
    index = index + 1
  end
  return table.concat(out)
end

return M
