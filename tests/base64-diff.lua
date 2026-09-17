-- Isolate which direction is broken. Compare against the container's own
-- base64 command, which is authoritative.
local memory = dofile("lua/core/memory.lua")

local function run(cmd, input)
  local p = io.popen(cmd, "w")
  p:write(input)
  p:close()
  return nil
end

-- 1. Decoder: does it reproduce bytes that `base64 -d` also produces?
local probe_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
local mine = memory.base64_decode(probe_b64)
print("decoded length:", #mine)

-- Write my decode out, and the reference decode out, then diff them.
local f1 = io.open("/tmp/mine.bin", "wb"); f1:write(mine); f1:close()
os.execute("printf '%s' '" .. probe_b64 .. "' | base64 -d > /tmp/ref.bin")
print("--- cmp (0 == identical) ---")
os.execute("cmp /tmp/mine.bin /tmp/ref.bin && echo IDENTICAL || echo DIFFERENT")

-- 2. Encoder: feed it the reference bytes, compare to the reference base64.
local ref = io.open("/tmp/ref.bin", "rb"):read("a")
local reencoded = memory.base64_encode(ref)
print("--- encoder output ---")
print(reencoded)
print("--- reference ---")
print(probe_b64)
print("--- equal? ---")
print(reencoded == probe_b64)

-- 3. Where exactly do they diverge?
for i = 1, math.max(#reencoded, #probe_b64) do
  local a, b = reencoded:sub(i, i), probe_b64:sub(i, i)
  if a ~= b then
    print(string.format("first difference at %d: mine=%q ref=%q", i, a, b))
    break
  end
end
