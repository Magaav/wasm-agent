-- The detector finds markup; the ORIGINAL message is what gets cut (18/11 round 2, finding 1).
--
-- Round 1 found the markup in a code-stripped copy and then cut from THAT copy, so the text the
-- answer kept was the stripped one: every fenced block, inline span and indented block in the model's
-- own message was deleted along with the fabrication, and a false positive (markup inside code) took
-- the model's code and the rest of the message with it. The rule now: detect on the masked copy, cut
-- from the ORIGINAL by span, and markup inside code is never fake.
--
-- Hermetic: the detector is a pure module; nothing here starts a node, a provider or a process.
local fake_answer = dofile('lua/core/fake_answer.lua')
local FENCE3 = string.rep(string.char(96), 3)
local FENCE4 = string.rep(string.char(96), 4)
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

local SHAPE = "<result>\n<name>bash</name>\n<output>\n$ ls\nREADME.md\n</output>\n</result>"

-- ---------------------------------------------------------------- markup inside code is never fake
local fenced = "Here is the protocol, quoted from the docs:\n" ..
  FENCE4 .. "\n" .. SHAPE .. "\n" .. FENCE4 .. "\n" .. "That is what a result looks like."
check(fake_answer.scan(fenced) == nil, "markup inside a fenced block is documentation, not an imitation")
local tildes = "~~~text\n" .. SHAPE .. "\n~~~\n"
check(fake_answer.scan(tildes) == nil, "and the same inside a tilde fence")
-- An unterminated fence: the rest of the message is code, so nothing after it is the model imitating
-- a result. (Before: the closed-fence pattern never matched, the markup was found, and the rest of the
-- message was cut from the stripped copy.)
local open_fence = "A fixture, unterminated:\n" .. FENCE3 .. "xml\n" .. SHAPE .. "\n"
check(fake_answer.scan(open_fence) == nil, "an unterminated fence is still code: " ..
  tostring(fake_answer.scan(open_fence) and fake_answer.scan(open_fence).stripped))
-- Markdown's indented code: four spaces.
local indented = "Example:\n\n    " .. SHAPE:gsub("\n", "\n    ") .. "\n\nEnd of the example."
check(fake_answer.scan(indented) == nil, "markup inside an indented code block is code: " ..
  tostring(fake_answer.scan(indented) and fake_answer.scan(indented).stripped))
-- The same block indented with ONE TAB, and a block that is the FIRST line of the message
-- (18/11 round 3, item 4): the mask this started as wanted a newline in front of the line and four
-- SPACES, so a tab-indented fixture and a message that opened with an indented block were both read as
-- the model imitating a tool result - and the model's own code was cut for it.
local tabbed = "Example:\n\n\t" .. SHAPE:gsub("\n", "\n\t") .. "\n\nEnd of the example."
check(fake_answer.scan(tabbed) == nil, "one tab is an indented code block too: " ..
  tostring(fake_answer.scan(tabbed) and fake_answer.scan(tabbed).stripped))
local first_line = "    " .. SHAPE:gsub("\n", "\n    ")
check(fake_answer.scan(first_line) == nil, "and so is a block that opens the message: " ..
  tostring(fake_answer.scan(first_line) and fake_answer.scan(first_line).stripped))
local first_line_tab = "\t" .. SHAPE:gsub("\n", "\n\t")
check(fake_answer.scan(first_line_tab) == nil, "in its tab spelling: " ..
  tostring(fake_answer.scan(first_line_tab) and fake_answer.scan(first_line_tab).stripped))
-- A message that merely STARTS with spaces is prose, and a bare imitation is still found.
check(fake_answer.scan("  " .. SHAPE) ~= nil, "two spaces are not an indent: a bare imitation is still fake")
check(fake_answer.scan(SHAPE) ~= nil, "and so is one at byte 0 with no indent at all")

-- ---------------------------------------------------------------- the cut is made in the original
local code = FENCE3 .. "lua\nlocal x = 1\nprint(x)\n" .. FENCE3
local mixed = "The tool answered, so I will show it:\n\n" .. code .. "\n\nAnd here it is as markup:\n"
  .. SHAPE .. "\n\nThat is all."
local scan = fake_answer.scan(mixed)
check(scan ~= nil, "the real imitation in that message is still found")
check(scan and scan.stripped:find(code, 1, true) ~= nil,
  "the model's own code block survives the cut, byte for byte: [" .. tostring(scan and scan.stripped) .. "]")
check(scan and scan.stripped:find("That is all.", 1, true) ~= nil,
  "and so does the sentence after it: [" .. tostring(scan and scan.stripped) .. "]")
check(scan and scan.stripped:find("And here it is as markup:", 1, true) ~= nil,
  "the prose that introduced the markup is left where it was")
check(scan and scan.stripped:find("<output>", 1, true) == nil, "and the fabricated markup itself is gone")
check(scan and scan.stripped == "The tool answered, so I will show it:\n\n" .. code
  .. "\n\nAnd here it is as markup:\n\n\nThat is all.",
  "the stripped text is the original minus exactly that span: [" .. tostring(scan and scan.stripped) .. "]")

-- ---------------------------------------------------------------- the evidence is verbatim
check(scan and scan.removed == SHAPE, "what was removed is kept verbatim, not as a bounded quote: ["
  .. tostring(scan and scan.removed) .. "]")
check(scan and scan.removed_blocks and #scan.removed_blocks == 1, "one removed block, in its own entry")
check(scan and scan.tool == "bash", "the markup names the tool it was describing: " .. tostring(scan and scan.tool))

-- Several elements in one message: each span is cut from the original once, in order.
local twice = "First:\n" .. SHAPE .. "\nSecond:\n" .. SHAPE
local both = fake_answer.scan(twice)
check(both ~= nil and both.blocks == 2, "two fabricated blocks are two blocks: " .. tostring(both and both.blocks))
check(both and both.removed == SHAPE .. "\n" .. SHAPE, "and both are kept verbatim")
check(both and both.stripped == "First:\n\nSecond:", "leaving the prose that held them: ["
  .. tostring(both and both.stripped) .. "]")

-- ---------------------------------------------------------------- unchanged shapes still pass
check(fake_answer.scan("The build passed and the tests are green.") == nil, "an ordinary answer is not markup")
check(fake_answer.scan("The <output> element carries stdout.") == nil, "a tag mentioned in prose is prose")
local prose_end = "Done: the command printed\n<result>\n</result>\nand exited 0."
check(fake_answer.scan(prose_end) ~= nil, "a result element alone on its line is still an imitation")

print(string.format("ok fake-answer-original-span: %d checks", checks))
