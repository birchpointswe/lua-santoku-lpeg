local test = require("santoku.test")

local err = require("santoku.error")
local assert = err.assert

local validate = require("santoku.validate")
local eq = validate.isequal

local lp = require("santoku.lpeg")

test("pull named fields out of a json line without parsing it", function ()
  local line = '{"title":"hello","body":"world","other":123}'
  local found = {}
  for s, e in lp.json_fields(line, { "title", "body" }) do
    found[#found + 1] = line:sub(s, e)
  end
  assert(eq(2, #found))
  assert(eq("hello", found[1]))
  assert(eq("world", found[2]))
end)

test("nested objects are skipped, so only top-level keys match", function ()
  local line = '{"a":"yes","nested":{"a":"no"},"b":"also"}'
  local found = {}
  for s, e in lp.json_fields(line, { "a" }) do
    found[#found + 1] = line:sub(s, e)
  end
  assert(eq(1, #found))
  assert(eq("yes", found[1]))
end)

test("read the visible text out of html, dropping script and style", function ()
  local html = "before<script>var x=1;</script>after<style>.a{}</style>end"
  local found = {}
  for text in lp.html_text(html) do
    found[#found + 1] = text
  end
  assert(eq(3, #found))
  assert(eq("before", found[1]))
  assert(eq("end", found[3]))
end)

test("extract text while tracking where each tag covered it", function ()
  local html = 'hello <span class="author">John</span> world'
  local text, tags = lp.html_extract(html)
  assert(eq("hello John world", text))
  assert(eq(1, #tags))
  assert(eq("span", tags[1].name))
  assert(eq("author", tags[1].attrs["class"]))
  assert(eq("John", text:sub(tags[1].s, tags[1].e)))
end)
