local test = require("santoku.test")
local lp = require("santoku.lpeg")

test("json_fields", function ()

  test("simple string fields", function ()
    local line = '{"title":"hello","body":"world","other":123}'
    local results = {}
    for s, e in lp.json_fields(line, {"title", "body"}) do
      results[#results + 1] = line:sub(s, e)
    end
    assert(#results == 2)
    assert(results[1] == "hello")
    assert(results[2] == "world")
  end)

  test("array values", function ()
    local line = '{"tags":["a","b","c"],"x":1}'
    local results = {}
    for s, e in lp.json_fields(line, {"tags"}) do
      results[#results + 1] = line:sub(s, e)
    end
    assert(#results == 3)
    assert(results[1] == "a")
    assert(results[2] == "b")
    assert(results[3] == "c")
  end)

  test("nested objects skipped", function ()
    local line = '{"a":"yes","nested":{"a":"no"},"b":"also"}'
    local results = {}
    for s, e in lp.json_fields(line, {"a", "b"}) do
      results[#results + 1] = line:sub(s, e)
    end
    assert(#results == 2)
    assert(results[1] == "yes")
    assert(results[2] == "also")
  end)

  test("escaped strings", function ()
    local line = '{"val":"hello\\"world"}'
    local results = {}
    for s, e in lp.json_fields(line, {"val"}) do
      results[#results + 1] = line:sub(s, e)
    end
    assert(#results == 1)
    assert(results[1] == 'hello\\"world')
  end)

  test("empty string skipped", function ()
    local line = '{"a":"","b":"ok"}'
    local results = {}
    for s, e in lp.json_fields(line, {"a", "b"}) do
      results[#results + 1] = line:sub(s, e)
    end
    assert(#results == 1)
    assert(results[1] == "ok")
  end)

  test("missing fields", function ()
    local line = '{"x":1}'
    local results = {}
    for s, e in lp.json_fields(line, {"title"}) do
      results[#results + 1] = line:sub(s, e)
    end
    assert(#results == 0)
  end)

end)

test("html_text", function ()

  test("simple tags", function ()
    local html = "<p>hello</p> <b>world</b>"
    local results = {}
    for text in lp.html_text(html) do
      results[#results + 1] = text
    end
    assert(#results == 2)
    assert(results[1] == "hello")
    assert(results[2] == " world")
  end)

  test("script and style stripped", function ()
    local html = "before<script>var x=1;</script>after<style>.a{}</style>end"
    local results = {}
    for text in lp.html_text(html) do
      results[#results + 1] = text
    end
    assert(#results == 3)
    assert(results[1] == "before")
    assert(results[2] == "after")
    assert(results[3] == "end")
  end)

  test("comments stripped", function ()
    local html = "a<!-- comment -->b"
    local results = {}
    for text in lp.html_text(html) do
      results[#results + 1] = text
    end
    assert(#results == 2)
    assert(results[1] == "a")
    assert(results[2] == "b")
  end)

end)

test("html_extract", function ()

  test("strips tags and tracks positions", function ()
    local html = 'hello <span class="author">John</span> world'
    local text, tags = lp.html_extract(html)
    assert(text == "hello John world")
    assert(#tags == 1)
    assert(tags[1].name == "span")
    assert(tags[1].attrs["class"] == "author")
    assert(text:sub(tags[1].s, tags[1].e) == "John")
  end)

  test("multiple tags", function ()
    local html = '<span class="title">BOOK</span> by <span class="author">Smith</span>'
    local text, tags = lp.html_extract(html)
    assert(text == "BOOK by Smith")
    assert(#tags == 2)
    assert(tags[1].attrs["class"] == "title")
    assert(tags[2].attrs["class"] == "author")
    assert(text:sub(tags[1].s, tags[1].e) == "BOOK")
    assert(text:sub(tags[2].s, tags[2].e) == "Smith")
  end)

end)

test("html_tags", function ()

  test("iterates tags", function ()
    local html = '<b>bold</b> and <i x="1">italic</i>'
    local results = {}
    for name, attrs in lp.html_tags(html) do
      results[#results + 1] = { name = name, attrs = attrs }
    end
    assert(#results == 2)
    assert(results[1].name == "b")
    assert(results[2].name == "i")
    assert(results[2].attrs.x == "1")
  end)

end)

test("html_inject", function ()

  test("round-trip extract then inject", function ()
    local html = 'hello <span class="author">John</span> world'
    local text, tags = lp.html_extract(html)
    local rebuilt = lp.html_inject(text, tags)
    assert(rebuilt:find("John"))
    assert(rebuilt:find("hello"))
    assert(rebuilt:find("world"))
    assert(rebuilt:find("span"))
  end)

  test("attr_order", function ()
    local text = "hello Germany world"
    local tags = {{
      name = "span", s = 7, e = 13,
      attrs = { class = "country", id = "276", ["data-country-iso"] = "276" }
    }}
    local result = lp.html_inject(text, tags, { "class", "id" })
    local s = result:find('class=')
    local i = result:find('id=')
    local d = result:find('data%-country%-iso=')
    assert(s and i and d)
    assert(s < i, "class before id")
    assert(i < d, "id before data-country-iso")
  end)

  test("canonicalization via text override", function ()
    local html = '<span class="author">J. Smith</span>'
    local text, tags = lp.html_extract(html)
    assert(text == "J. Smith")
    tags[1].text = "John Smith"
    local rebuilt = lp.html_inject(text, tags)
    assert(rebuilt:find("John Smith"))
    assert(not rebuilt:find("J%. Smith"))
  end)

end)

test("minify_html", function ()

  test("strips comments and collapses whitespace", function ()
    local html = "<!-- comment --><div>  hello   world  </div>"
    local result = lp.minify_html(html)
    assert(not result:find("comment"))
    assert(result:find("hello"))
  end)

  test("preserves pre content", function ()
    local html = "<pre>  keep   spaces  </pre>"
    local result = lp.minify_html(html)
    assert(result:find("keep   spaces"))
  end)

end)

test("component_parts", function ()

  test("extracts script, style, and body", function ()
    local html = '<style>.a{color:red}</style><div>body</div><script>init()</script>'
    local parts = lp.component_parts(html)
    assert(parts.style == ".a{color:red}")
    assert(parts.init == "init()")
    assert(parts.body == "<div>body</div>")
  end)

  test("script src as dep", function ()
    local html = '<script src="lib.js"></script><p>hi</p>'
    local parts = lp.component_parts(html)
    assert(#parts.deps == 1)
    assert(parts.deps[1] == "lib.js")
  end)

  test("destroy script", function ()
    local html = '<script type="destroy">cleanup()</script><p>hi</p>'
    local parts = lp.component_parts(html)
    assert(parts.destroy == "cleanup()")
  end)

end)

test("transform_inline", function ()

  test("transforms inline js", function ()
    local html = '<script>var x = 1;</script>'
    local result = lp.transform_inline(html, { js = string.upper })
    assert(result:find("VAR X = 1;"))
  end)

  test("transforms inline css", function ()
    local html = '<style>.a { color: red }</style>'
    local result = lp.transform_inline(html, { css = string.upper })
    assert(result:find("%.A { COLOR: RED }"))
  end)

  test("skips script with src", function ()
    local html = '<script src="x.js">keep</script>'
    local result = lp.transform_inline(html, { js = string.upper })
    assert(result:find("keep"))
    assert(not result:find("KEEP"))
  end)

end)

local ivec = require("santoku.ivec")

test("html_match_tags", function ()

  test("builds span tags with class names", function ()
    local ids = ivec.create({ 1, 2 })
    local starts = ivec.create({ 0, 5 })
    local ends = ivec.create({ 3, 8 })
    local tags = lp.html_match_tags(ids, starts, ends, { [1] = "PER", [2] = "LOC" }, "ner-")
    assert(#tags == 2)
    assert(tags[1].name == "span")
    assert(tags[1].s == 1 and tags[1].e == 3)
    assert(tags[1].attrs.class == "ner-PER")
    assert(tags[2].attrs.class == "ner-LOC")
  end)

  test("falls back to stringified id when no names", function ()
    local tags = lp.html_match_tags(ivec.create({ 7 }), ivec.create({ 2 }), ivec.create({ 4 }))
    assert(tags[1].attrs.class == "7")
    assert(tags[1].s == 3 and tags[1].e == 4)
  end)

end)

test("html_spans", function ()

  test("converts extracted tags to a pvec of spans", function ()
    local _, tags = lp.html_extract('hello <b>John</b> world')
    local spans = lp.html_spans(tags)
    assert(spans:size() == 1)
  end)

end)
