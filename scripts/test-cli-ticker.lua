-- The CLI's status line keeps moving while the interpreter is blocked.
--
-- Why this is observed through a captured child process rather than asserted in-process: the
-- host's ticker draws on the process's own stdout, from its own thread, so the only honest
-- evidence is that stdout. This script sleeps - it cannot repaint anything by itself - and
-- `scripts/test.sh` checks that the file it produced holds many frames whose clock advanced.
-- That is the property that used to be missing: a run that is thinking looked exactly like a
-- run that is hung, because nothing could move the line.
--
-- Two parts: the view's own path through the real host (what `wa chat` does), and then the
-- capability's contract on its own, including the answers it gives.
local json = dofile("lua/vendor/json.lua")
local view_lib = dofile("lua/core/cli_view.lua")

-- The view, live, owning this process's stdout - the arrangement the gate can observe.
local view = view_lib.new({ live = true, limit = 100, title = "wa - ticker" })
view:run_started()
-- Nothing on the Lua side runs during a sleep: every frame below is the host drawing the line
-- the view handed it, with the marks the view prints and the clock the view would print.
host.sleep(1000)
view:answered("view ran")

-- The capability on its own: a spec starts it, no argument stops it, and stopping twice stays
-- stopped. `marks` comes from the view so the frames cannot drift between the two paths.
local running = host.ticker(json.encode({
  line = "  {m}blocked \194\183 {t}",
  marks = view_lib.marks(),
  started = host.now(),
}))
if running ~= true then
  print("a spec should start a ticker")
  os.exit(1)
end
host.sleep(300)
if host.ticker(nil) ~= nil then
  print("stopping the ticker should answer nil")
  os.exit(1)
end
if host.ticker(nil) ~= nil then
  print("stopping an already-stopped ticker should answer nil")
  os.exit(1)
end
-- Stopping leaves the line to the caller: the ticker is not the one that decides the line is
-- finished. This is what the view's `clear` does before it prints anything else, and doing it
-- here is what keeps the rest of this capture readable.
io.write("\r\27[2K")
print("ticker ran")
