-- WHAT THE PAUSE AND RELEASE LINES NAME, read from the request a REAL sentinel just wrote into the node's
-- own box (scripts/test-deploy-target.sh runs both processes against one scratch home).
--
-- Nothing here re-implements a file shape or a sentence: the box is read by lua/core/deploy_wait.lua and the two
-- sentences are composed by lua/core/deploy_pause.lua. That is the point - the row proves the readers a paused and
-- a released session actually meet, over the file the sentinel actually wrote.
local function refuse(why) print("REFUSED deploy-target: " .. why); os.exit(2) end
local why_home = dofile("scripts/lib/scratch-home.lua").guard("deploy-target")
if why_home then refuse(why_home) end

local wait = dofile("lua/core/deploy_wait.lua")
local pause = dofile("lua/core/deploy_pause.lua")

local now = os.time()
local recorded, why = wait.read(now)
if not recorded then refuse("no waiting request in the box: " .. tostring(why)) end
print("to " .. tostring(recorded.to))
print("pause " .. pause.say(recorded))
print("not-happened " .. pause.not_happened_text(recorded, now))
-- The release line names what the install record holds, read by the product's own reader
-- (lua/core/update.lua `installed_record`, through pause.installed_identity).
local installed = pause.installed_identity()
if not installed then refuse("no installed.txt to read in " .. tostring(os.getenv("WA_INSTALL_DIR"))) end
local was = { tree = "", commit = tostring(os.getenv("DW_WAS") or "") }
print("resume " .. pause.installed_text(was, installed))
