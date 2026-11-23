-- THE PRODUCT VERSION ON THE SURFACES (Victor, 22/11: "make v0.1.0 be reflected into the entrance; v1.0 is
-- wrong. each release we add v0.1.0 then v0.1.1 and so on" + "wa --version prints the product version and the
-- sha, from the same source, with a test").
--
-- ONE OWNER (the tree's `VERSION` file), read back through the binary by every surface:
--
--   lua/core/build_identity.lua   M.product_version()  - the reader the welcome box uses
--   lua/core/cli_view.lua         M.banner()           - the header line itself
--   rust/wa-host/src/main.rs      `wa --version`       - the same two facts, same order (its own row:
--                                                        scripts/test-build-info.sh, against a real binary)
--
-- WHAT THIS ROW CAN AND CANNOT SAY. It drives the READER and the HEADER with the fixture host's answers, so it
-- holds the text to its shape whatever binary is running. It also compares the running binary's version with the
-- tree's VERSION file - but only when that binary was built from THIS commit: a release binary from another
-- commit answering another number is the truth (that is what the sha beside it is for), and the row says which
-- case it is in instead of pretending one.

local cli_view = dofile("lua/core/cli_view.lua")
local identity = dofile("lua/core/build_identity.lua")

local checks, failed = 0, 0
local function ok(condition, message)
  checks = checks + 1
  if not condition then failed = failed + 1; print("FAIL " .. message) else print("ok   " .. message) end
end
local function eq(got, want, message)
  ok(tostring(got) == tostring(want), message .. " (got " .. tostring(got) .. ", want " .. tostring(want) .. ")")
end
local function contains(haystack, needle, message)
  ok(tostring(haystack or ""):find(needle, 1, true) ~= nil, message .. " (looked for " .. tostring(needle) .. ")")
end
local function hides(haystack, needle, message)
  ok(tostring(haystack or ""):find(needle, 1, true) == nil, message .. " (found " .. tostring(needle) .. ")")
end

local middle_dot = "\194\183"

-- ---------------------------------------------------------------- the reader
-- The binary's answer is a JSON string (`host.build_identity()`); `opts.native` is the seam every case below
-- uses, so the shapes are asserted without depending on which binary runs this row.
eq(identity.product_version({ native = { product_version = "0.1.0" } }), "0.1.0", "the version is read from the binary's own answer")
eq(identity.product_version({ native = { product_version = "0.2.12" } }), "0.2.12", "a two-digit patch number too")
eq(identity.product_version({ native = { label = "abc12345", known = true } }), "unknown",
  "a binary older than the field answers unknown, never a made-up number")
eq(identity.product_version({ native = { product_version = "  0.1.3  " } }), "0.1.3", "and the field is trimmed")

-- ---------------------------------------------------------------- the header line
local function header(opts) return (cli_view.banner(opts):gsub("\n", " | ")) end
contains(header({ product = "0.1.0", version = "6a7f613d", workspace = "~/work" }),
  "Welcome to wasm-agent! v0.1.0 " .. middle_dot .. " v6a7f613d",
  "the welcome line is 'Welcome to wasm-agent! v<version> <dot> v<sha>'")
contains(header({ product = "0.1.11", version = "node-abc12345" }),
  "Welcome to wasm-agent! v0.1.11 " .. middle_dot .. " node-abc12345",
  "a release install shows the version and the release tag it was installed from")
contains(header({ product = "0.1.2", version = "abc12345+dirty" }),
  "Welcome to wasm-agent! v0.1.2 " .. middle_dot .. " vabc12345+dirty",
  "a dev build shows the last released version and its own (dirty) sha")
contains(header({ product = "unknown", version = "abc12345" }), "Welcome to wasm-agent! vabc12345",
  "a binary with no version shows the sha alone")
hides(header({ product = "unknown", version = "abc12345" }), "vunknown", "...and never an invented 'vunknown'")
hides(header({ product = "0.1.0", version = "unknown build" }), "vunknown", "nor 'vunknown build'")
contains(header({ product = "0.1.0", version = "node-abc12345" }), "v0.1.0", "the version is the first half")

-- ---------------------------------------------------------------- the ONE source
-- The tree's VERSION file is what the binary embeds. When this row runs against a binary of THIS commit the two
-- must agree; when it does not, the row says which case it is in and claims nothing - a release binary from
-- another commit answering another number is the truth, and the sha printed beside it is how a reader sees it.
local root = (host.getenv and host.getenv("WASM_AGENT_LUA_ROOT")) or "."
local function read(path)
  local ok, text = pcall(host.read_file, path)
  return (ok and type(text) == "string") and text or nil
end
local text = read(root .. "/VERSION")
ok(text ~= nil, "the tree has a VERSION file (" .. root .. "/VERSION)")
text = (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
ok(text:match("^%d+%.%d+%.%d+$") ~= nil, "VERSION holds d.d.d ('" .. text .. "')")
local native = identity.native() or {}
local binary_product = tostring(native.product_version or "")
ok(binary_product ~= "", "the running binary carries a product version (the build embeds the file)")
ok(binary_product:match("^%d+%.%d+%.%d+$") ~= nil or binary_product == "unknown",
  "and it is a version or 'unknown', never something invented ('" .. binary_product .. "')")
-- The tree's commit, so the two numbers are compared only when they can be: `host.exec` answers a JSON string.
local json = dofile("lua/vendor/json.lua")
local tree_commit = ""
if host.exec then
  local ran, raw = pcall(host.exec, "git rev-parse HEAD 2>/dev/null")
  if ran and type(raw) == "string" then
    local decoded_ok, decoded = pcall(json.decode, raw)
    if decoded_ok and type(decoded) == "table" then tree_commit = tostring(decoded.stdout or "") end
  end
  tree_commit = (tree_commit:gsub("%s+$", ""))
end
local binary_commit = tostring(native.commit or "")
if tree_commit ~= "" and binary_commit ~= "" and binary_commit ~= "unknown" and binary_commit:sub(1, 40) == tree_commit:sub(1, 40) then
  eq(binary_product, text, "a binary built from this commit reports this tree's VERSION")
else
  print(string.format("note: the running binary is commit %s and the tree is %s; the two are held equal only on a build of the same commit",
    binary_commit ~= "" and binary_commit:sub(1, 8) or "unknown", tree_commit ~= "" and tree_commit:sub(1, 8) or "unknown"))
  ok(text:match("^%d+%.%d+%.%d+$") ~= nil, "the tree's number stands on its own as the release's")
end

print(string.format("product-version: %d checks, %d failed", checks, failed))
if failed > 0 then os.exit(1) end
os.exit(0)
