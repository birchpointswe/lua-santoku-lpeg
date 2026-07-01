# santoku-lpeg

Helpers built on top of the external [lpeg](http://www.inf.puc-rio.br/~roberto/lpeg/)
library: streaming field extraction from JSON lines, and a set of HTML scanners,
extractors, rewriters, and a minifier. This library does not wrap or re-expose lpeg's
own primitives (`P`/`S`/`R`/`C`/`V`/...); for those, see the
[lpeg documentation](http://www.inf.puc-rio.br/~roberto/lpeg/). The functions here are
the layer that uses lpeg grammars to do specific scanning jobs.

This README is a usage guide, not an API reference. The tests are the spec:
`test/spec/santoku/lpeg.lua` exercises the full surface. Read that for the exhaustive
behavior; read this for how the functions are used and the conventions.

## Conventions

- **Single flat module.** `require("santoku.lpeg")` returns a table of plain functions;
  there are no objects or methods.
- **1-based, inclusive positions.** Functions that report offsets (`json_fields`,
  `html_extract`, `html_tags`) return `s, e` such that `str:sub(s, e)` is the match,
  matching Lua string conventions.
- **Iterators yield, they do not collect.** `json_fields` and `html_text` return
  coroutine-backed iterators for `for` loops; they hold no result table.
- **Scanners, not validators.** The HTML functions tolerate malformed markup (unmatched
  tags, bare attributes, missing quotes); they scan rather than enforce a grammar. The
  JSON scanner assumes well-formed input on the scanned fields.
- **External lpeg only.** The runtime dependency is the `lpeg` rock. Base `santoku` and
  `santoku-matrix` are test dependencies, not runtime ones. `html_spans` needs
  `santoku.pvec` (from lua-santoku-matrix) at call time, so a caller using it must provide
  matrix itself.

## Function map

| Function | Role | Anchor test |
|----------|------|-------------|
| `json_fields(str, fields)` | iterate `s, e` byte ranges of named top-level JSON fields (string or array values), skipping nested objects | `lpeg.lua` |
| `html_text(str)` | iterate visible text runs, dropping tags, comments, `script`, `style` | `lpeg.lua` |
| `html_extract(str)` | strip tags to plain text; return `text, tags` with positions into the stripped text | `lpeg.lua` |
| `html_tags(str)` | iterate `name, attrs, open_s, open_e, close_s, close_e` for each element | `lpeg.lua` |
| `html_inject(text, tags[, attr_order])` | rebuild HTML from stripped text plus tag records (inverse of `html_extract`) | `lpeg.lua` |
| `html_spans(tags)` | convert tag records to a `santoku.pvec` of `(s-1, e)` spans | `lpeg.lua` (seed) |
| `html_match_tags(ids, starts, ends[, names][, prefix])` | build `span` tag records from parallel id/start/end vectors | `lpeg.lua` (seed) |
| `component_parts(html)` | split a component fragment into `deps`, `style`, `init`, `destroy`, `body` | `lpeg.lua` |
| `minify_html(html)` | collapse whitespace and drop comments, preserving `pre`/`textarea`/`script`/`style` | `lpeg.lua` |
| `transform_inline(html, transforms)` | rewrite inline `<script>`/`<style>` bodies through `transforms.js`/`transforms.css` | `lpeg.lua` |

Worked, per-scenario examples live in [`doc/usage.md`](doc/usage.md).

## Snippets

### Stream named fields out of JSON lines

```lua
local lp = require("santoku.lpeg")
local line = '{"title":"hello","tags":["a","b"],"x":1}'
for s, e in lp.json_fields(line, { "title", "tags" }) do
  print(line:sub(s, e))   -- hello / a / b
end
```

### Strip HTML to text, then put the tags back

```lua
local text, tags = lp.html_extract('hello <span class="author">John</span> world')
-- text == "hello John world"; tags[1].s..tags[1].e covers "John"
local rebuilt = lp.html_inject(text, tags)   -- inverse: re-wraps "John" in its span
```

## Building / testing

This repo uses the `toku` build harness. Tests live in `test/spec/santoku/`; run the
suite through `toku` so the `lpeg` rock and the `santoku`/`santoku-matrix` test
dependencies are on the path (the latter supplies the `ivec`/`pvec` types the
`html_match_tags` and `html_spans` tests use).

## License

MIT License

Copyright 2025 Birch Point SWE

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
