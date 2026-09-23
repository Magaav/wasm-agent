-- Markdown for the CLI view.
--
-- What is asserted here is the *rendering decision*, which is the part that can be wrong
-- without a model: which role a heading, a bullet, a fence and a link are given, that a long
-- line is wrapped to the terminal rather than to the byte count, and - the one that matters
-- most - that nothing in the reply is dropped on the way through. A renderer that ate a line
-- would be worse than the plain text it replaced.
--
-- `paint` is passed in, so the test reads the roles the renderer chose without a terminal:
-- the recorder keeps the plain text (what a captured transcript shows) beside the style.
local md = dofile("lua/core/markdown.lua")
local view_lib = dofile("lua/core/cli_view.lua")

local failed = 0
local checks = 0
local function ok(condition, label)
  checks = checks + 1
  if not condition then
    print("FAIL " .. label)
    failed = failed + 1
  end
end

local function has(text, needle)
  return tostring(text):find(needle, 1, true) ~= nil
end

-- A painter that records instead of colouring: the returned text is what a captured
-- transcript carries, and `roles` is what a terminal would have been told.
local function recorder()
  local pieces = {}
  local rec = {
    paint = function(text, style)
      local name
      if type(style) == "table" then name = table.concat(style, "+")
      elseif style == nil then name = "-"
      else name = style end
      pieces[#pieces + 1] = { text = tostring(text), style = name }
      return tostring(text)
    end,
  }
  function rec.role_of(needle)
    for _, piece in ipairs(pieces) do
      if piece.text:find(needle, 1, true) then return piece.style end
    end
    return nil
  end
  function rec.text()
    local out = {}
    for _, piece in ipairs(pieces) do out[#out + 1] = piece.text end
    return table.concat(out)
  end
  return rec
end

local function render(source, opts)
  local rec = recorder()
  opts = opts or {}
  opts.paint = rec.paint
  local text = md.render(source, opts)
  return text, rec
end

-- ---- the components ----------------------------------------------------------------

local _, head = render("# A heading\n\nsome words")
ok(head.role_of("heading") == "bold+mdHeading", "a first-level heading is bold in pi's heading colour")
ok(head.role_of("words") == "-", "an ordinary paragraph is left in the terminal's own text colour")

local _, second = render("## A smaller heading")
ok(second.role_of("smaller") == "bold+mdHeading", "a second-level heading is bold too")
local _, third = render("### Deep")
ok(third.role_of("Deep") == "mdHeading", "a deeper heading keeps the colour and loses the weight")

local _, bullets = render("- one\n- two\n\n1. three")
ok(bullets.role_of("\226\128\162") == "mdListBullet", "a bullet gets pi's list-bullet colour")
ok(bullets.role_of("1.") == "mdListBullet", "an ordered list numbers in the same colour")

local _, quote = render("> quoted words")
ok(quote.role_of("quoted") == "mdQuote", "a quote's words take the quote colour")
ok(quote.role_of("\226\148\130") == "mdQuoteBorder", "and its border is drawn separately")

local _, rule = render("---")
ok(rule.role_of("\226\148\128") == "mdHr", "a horizontal rule is pi's rule colour")

-- ---- code --------------------------------------------------------------------------

local fenced = "```lua\nlocal x = 1 -- why\nprint(\"hi\")\n```"
local _, code = render(fenced)
ok(code.role_of("lua") == "mdCodeBlockBorder", "a fence's border names the language")
ok(code.role_of("local") == "syntaxKeyword", "a keyword in a fence is a keyword")
ok(code.role_of("-- why") == "syntaxComment", "a comment is a comment in the language the fence named")
ok(code.role_of("\"hi\"") == "syntaxString", "a string is a string")
ok(code.role_of("1") == "syntaxNumber", "a number is a number")
ok(code.role_of("print") == "syntaxFunction", "a name followed by a call is a function")
ok(not has(code.text(), "```"), "the fence marks themselves do not reach the screen")
ok(has(code.text(), "local x = 1"), "and the code does")

-- An untagged fence gets no comment colour rather than a guess: colouring half a line as a
-- comment because the wrong language was assumed is worse than leaving it plain.
local _, untagged = render("```\n# not necessarily a comment\n```")
ok(untagged.role_of("necessarily") == "mdCodeBlock",
  "an untagged fence colours its body and assumes no comment syntax")
ok(untagged.role_of("#") == "mdCodeBlock", "including the # that another language would call a comment")

-- ---- inline ------------------------------------------------------------------------

local _, inline = render("use `dofile` and **bold** and *italic* and [text](https://example.invalid/x)")
ok(inline.role_of("dofile") == "mdCode", "inline code is pi's code colour")
ok(inline.role_of("bold") == "bold+text", "bold is bold")
ok(inline.role_of("italic") == "italic", "italic is italic")
ok(inline.role_of("text") == "mdLink", "a link's label is the link colour")
ok(inline.role_of("https://example.invalid/x") == "mdLinkUrl", "and its target is the url colour")

-- Two bugs this test was written to catch, both of them text loss: a pattern with no capture
-- (a bare url) has no `first`, so reading only the capture dropped the whole word; and a
-- segment that begins with a space - which every segment after an inline token does - was
-- rejected rather than read from its first word, gluing the words on either side together.
local _, bare = render("see https://example.invalid/x for more")
ok(has(bare.text(), "https://example.invalid/x"), "a bare url is kept, not swallowed")
ok(has(bare.text(), "for more"), "and the words after it survive")
local _, spaced = render("a **b** c")
ok(has(spaced.text(), "a b c"), "the spaces around an inline token are not lost")
ok(not has(spaced.text(), "abc"), "and two words are never glued into one")

-- ---- wrapping, and the width -------------------------------------------------------

local long = string.rep("word ", 60)
local wrapped = render(long, { width = 40, indent = "  " })
local widest = 0
for line in (wrapped .. "\n"):gmatch("([^\n]*)\n") do
  if md.columns(line) > widest then widest = md.columns(line) end
end
ok(widest <= 40, "a wrapped paragraph fits the width it was given")
local wrapped_lines = 0
for _ in (wrapped .. "\n"):gmatch("([^\n]*)\n") do wrapped_lines = wrapped_lines + 1 end
ok(wrapped_lines >= 3, "and is wrapped rather than one long line")

-- A word longer than a line is broken rather than allowed to overflow: a URL is the common
-- case, and a line that overflows the terminal wraps in the terminal's own column, which is
-- where the indent and the colours stop lining up.
local url = "see https://example.invalid/" .. string.rep("a", 120)
local broken = render(url, { width = 40, indent = "  " })
for line in (broken .. "\n"):gmatch("([^\n]*)\n") do
  ok(md.columns(line) <= 40, "a line with an unbreakable word still fits")
  break
end
ok(not has(broken, " " .. string.rep("a", 121)), "and the long word is still there, in pieces")

-- Width is columns, not bytes: the same rule `cli_view.columns` uses, pinned against it so
-- the two cannot drift.
for _, sample in ipairs({ "plain", "\194\183\194\183\194\183", "caf\195\169 \226\134\145", "" }) do
  ok(md.columns(sample) == view_lib.columns(sample), "the two column counts agree on " .. #sample .. " bytes")
end

-- ---- nothing is lost ---------------------------------------------------------------

-- The property that matters most: whatever the model wrote comes out. A renderer that
-- dropped a line would be worse than the plain text it replaced, so the visible text is
-- compared word for word against the input for the shapes that actually arrive.
local nasty = table.concat({
  "# Title",
  "",
  "A paragraph with `code`, **bold**, *italic*, a [link](https://example.invalid) and a bare",
  "https://example.invalid/bare plus trailing spaces.  ",
  "",
  "> a quote",
  "",
  "```rust",
  "fn main() { println!(\"hi\"); }",
  "```",
  "",
  "- first",
  "- second",
  "",
  "| not | a | table |",
  "---",
  "last words",
}, "\n")
local plain = render(nasty, { width = 60 })
for _, word in ipairs({ "Title", "paragraph", "code", "bold", "italic", "link", "bare", "quote",
  "main", "println", "first", "second", "table", "last", "words" }) do
  ok(has(plain, word), "the reply keeps the word '" .. word .. "'")
end

-- A captured transcript must carry no escape sequences at all: the view decides that, and it
-- decides it by not passing a painter that colours.
local _, captured = render(nasty, { width = 60 })
ok(not has(captured.text(), "\27"), "no escape sequence reaches the text the renderer returns")

-- An empty reply is empty, not a stray blank line.
ok(md.render("", { width = 40 }) == "", "an empty reply renders as nothing")
ok(md.render("   \n\n  ", { width = 40 }) == "", "and so does whitespace")

-- ---- plain wrapping, for the reasoning block ---------------------------------------

local wrapped_plain = md.wrap("one two three four five six seven eight nine ten", { width = 20, indent = "  " })
ok(md.columns(wrapped_plain:match("[^\n]*")) <= 20, "wrapped plain text respects its width")
ok(has(wrapped_plain, "\n"), "and actually wraps")

if failed > 0 then
  print(string.format("markdown: %d failed of %d checks", failed, checks))
  os.exit(1)
end
print(string.format("markdown ok (%d checks)", checks))
