local skills = dofile("lua/core/skills.lua")
local tools = dofile("lua/core/tools.lua")
local b = skills.prompt_block() or ""
print("  skills block:   " .. #b .. " chars (~" .. math.floor(#b/4) .. " tokens)")
local n = 0
local ok, s = pcall(tools.schemas, "master")
if ok and type(s) == "table" then n = #s end
print("  tool schemas:   " .. n .. " tools for master")
