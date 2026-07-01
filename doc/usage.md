# santoku-lpeg usage

These helpers sit on top of the external [lpeg](http://www.inf.puc-rio.br/~roberto/lpeg/)
library. Each section below is a single scenario with a real snippet and its anchor test.
All examples assume:

```lua
local lp = require("santoku.lpeg")
```

## Canonical flow: extract, edit, reinject

The HTML pair `html_extract` / `html_inject` is the central round trip. `html_extract`
returns the visible text with tags removed, plus a `tags` array where each record carries
its element name, attribute table, and the `s, e` position (1-based, inclusive) that the
element covered in the stripped text. Edit the records, then `html_inject` rebuilds the
markup.

```lua
local text, tags = lp.html_extract('hello <span class="author">John</span> world')
-- text == "hello John world"
-- tags[1] = { name = "span", attrs = { class = "author" }, s = 7, e = 10, ... }

tags[1].text = "John Smith"             -- override the rendered text for this tag
local rebuilt = lp.html_inject(text, tags)
-- rebuilt wraps "John Smith" in <span class="author">...</span>
```

Anchor: `test/spec/santoku/lpeg.lua` (`html_extract`, `html_inject`).

## Scenario: scan JSON fields without parsing the document

`json_fields` walks a single JSON object and yields the byte range of each requested
top-level field's value. String values yield their inner range (quotes excluded); array
values yield each string element; nested objects are skipped. Empty strings are not
yielded.

```lua
local line = '{"title":"hello","tags":["a","b"],"nested":{"title":"skip"}}'
for s, e in lp.json_fields(line, { "title", "tags" }) do
  print(line:sub(s, e))   -- hello, then a, then b
end
```

Anchor: `test/spec/santoku/lpeg.lua` (`json_fields`).

## Scenario: pull readable text out of HTML

`html_text` iterates the visible text runs, dropping tags, comments, and the contents of
`script` and `style`.

```lua
for run in lp.html_text("before<script>var x=1;</script>after<!-- c -->end") do
  print(run)   -- before, after, end
end
```

Anchor: `test/spec/santoku/lpeg.lua` (`html_text`).

## Scenario: iterate elements with attributes and positions

`html_tags` yields `name, attrs, open_s, open_e, close_s, close_e` per element, where the
positions index into the original HTML.

```lua
for name, attrs in lp.html_tags('<b>bold</b> and <i x="1">italic</i>') do
  print(name, attrs.x)   -- b nil / i 1
end
```

Anchor: `test/spec/santoku/lpeg.lua` (`html_tags`).

## Scenario: turn match results into highlight spans

`html_match_tags` builds `span` tag records (ready for `html_inject`) from parallel
id/start/end vectors. `names` maps an id to a class name; `prefix` is prepended to every
class. The vector arguments need `:size()` and `:get(i)` (0-based), which `santoku.ivec`
satisfies. `html_spans` converts existing tag records to a `santoku.pvec` of `(s-1, e)`
spans.

```lua
local tags = lp.html_match_tags(ids, starts, ends, { [1] = "PER" }, "ner-")
-- tags[i] = { name = "span", s = starts:get(i-1)+1, e = ends:get(i-1), attrs = { class = "ner-PER" } }
local html = lp.html_inject(text, tags)
```

Anchors: `test/spec/santoku/lpeg.lua` (`html_match_tags`, `html_spans`; seeded).
`html_spans` requires `santoku.pvec` from lua-santoku-matrix; matrix is a test dependency
of this repo, so the test exercises it directly.

## Scenario: split a component fragment

`component_parts` separates a fragment into `style`, inline `init` script, `destroy`
script (a `<script type="destroy">`), external `deps` (`src` attributes), and the
remaining `body`.

```lua
local parts = lp.component_parts(
  '<style>.a{color:red}</style><div>body</div><script>init()</script>')
-- parts.style == ".a{color:red}", parts.init == "init()", parts.body == "<div>body</div>"
```

Anchor: `test/spec/santoku/lpeg.lua` (`component_parts`).

## Scenario: minify and rewrite inline assets

`minify_html` collapses runs of whitespace and removes comments while leaving
`pre`, `textarea`, `script`, and `style` contents untouched. `transform_inline` runs
`transforms.js` over inline `<script>` bodies and `transforms.css` over `<style>` bodies;
scripts with a `src` attribute are left alone.

```lua
lp.minify_html("<!-- c --><div>  hi   there  </div>")          -- "<div> hi there </div>"
lp.transform_inline("<script>var x=1;</script>", { js = string.upper })
```

Anchors: `test/spec/santoku/lpeg.lua` (`minify_html`, `transform_inline`).

## Gotchas

- `html_extract` positions index the stripped text; `html_tags` positions index the
  original HTML. Do not mix them.
- `json_fields` scans, it does not validate; malformed JSON on a scanned field can end the
  iteration early.
- `html_spans` needs `santoku.pvec` (lua-santoku-matrix), a test dependency here and not a
  runtime one; a caller that uses it must depend on matrix.
- `html_match_tags` expects 0-based `:get(i)` vectors and emits 1-based inclusive `s, e`.
