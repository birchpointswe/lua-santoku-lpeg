local lpeg = require("santoku.re.core")

local P, S, Cc, Cp, Ct = lpeg.P, lpeg.S, lpeg.Cc, lpeg.Cp, lpeg.Ct
local Cmt, B, C, Cg, Cb, R = lpeg.Cmt, lpeg.B, lpeg.C, lpeg.Cg, lpeg.Cb, lpeg.R
local lmatch = lpeg.match

local byte = string.byte
local sub = string.sub
local find = string.find
local concat = table.concat

local function is_subseq (out, src)
  local oi = 1
  local si = 1
  local olen = #out
  local slen = #src
  while oi <= olen do
    if si > slen then return false end
    if byte(out, oi) == byte(src, si) then
      oi = oi + 1
    end
    si = si + 1
  end
  return true
end

local function guard (out, src, bailed)
  if bailed then return src, true end
  if out == src then return src, false end
  if not is_subseq(out, src) then return src, true end
  return out, false
end

local function is_ident_ch (b)
  return b and (
    (b >= 48 and b <= 57) or
    (b >= 65 and b <= 90) or
    (b >= 97 and b <= 122) or
    b == 95 or b == 36)
end

local function ws_after (src, pos)
  local len = #src
  while pos <= len do
    local b = byte(src, pos)
    if b == 32 or b == 9 then
      pos = pos + 1
    else
      break
    end
  end
  return pos
end

local function trim_trailing (out)
  local i = #out
  while i > 0 do
    local s = out[i]
    local j = #s
    while j > 0 do
      local b = byte(s, j)
      if b == 32 or b == 9 then
        j = j - 1
      else
        break
      end
    end
    if j == #s and j > 0 then return end
    if j > 0 then
      out[i] = sub(s, 1, j)
      return
    end
    out[i] = nil
    i = i - 1
  end
end

local function lead_blank (src, cstart)
  local p = cstart - 1
  while p >= 1 do
    local b = byte(src, p)
    if b == 32 or b == 9 then
      p = p - 1
    elseif b == 10 then
      return true
    else
      return false
    end
  end
  return true
end

local function after_comment (src, cstart, pos, out)
  local p = ws_after(src, pos)
  local b = byte(src, p)
  if not (b == nil or b == 10 or b == 13) then
    return pos
  end
  trim_trailing(out)
  if not lead_blank(src, cstart) then
    return p
  end
  if b == 13 then
    p = p + 1
    b = byte(src, p)
  end
  if b == 10 then
    p = p + 1
  end
  return p
end

local drive_grammar
local lua_grammar
local html_grammar
local js_grammar
local gpend, gbail, glast
local hd_delim, hd_end

local function strip_lua (src)
  return drive_grammar(lua_grammar, src)
end

local c_directives = { "tk:", "NOLINT", "clang-format", "@ts-", "IWYU pragma:", "NOSONAR" }

local tmpl_open = P("<%")
local tmpl_block = tmpl_open * (P(1) - P("%>")) ^ 0 * (P("%>") + P(true))

local function tokenizer (rules, interesting, t)
  local alt = P(false)
  for i = 1, #rules do
    alt = alt + Ct(Cc(rules[i][2]) * Cp() * rules[i][1] * Cp())
  end
  local one = t and (P(1) - tmpl_open) or P(1)
  alt = alt + Ct(Cc("code") * Cp() * ((one - S(interesting)) ^ 1) * Cp())
  alt = alt + Ct(Cc("code") * Cp() * P(1) * Cp())
  return Ct(alt ^ 0)
end

local function render (src, toks)
  local out = {}
  local pos = 1
  for i = 1, #toks do
    local t = toks[i]
    local kind, s, e = t[1], t[2], t[3]
    if e > pos then
      if kind == "comment" and s >= pos then
        pos = after_comment(src, s, e, out)
      else
        out[#out + 1] = sub(src, s < pos and pos or s, e - 1)
        pos = e
      end
    end
  end
  return concat(out)
end

local function grammar_toks (patt, src)
  gpend = {}
  gbail = false
  glast = nil
  local toks = lmatch(patt, src)
  if not toks or gbail then return nil end
  return toks
end

drive_grammar = function (patt, src)
  local toks = grammar_toks(patt, src)
  if not toks then return src, true end
  return guard(render(src, toks), src, false)
end

local function dir_ahead (list)
  local alt = P(false)
  for i = 1, #list do
    alt = alt + P(list[i])
  end
  return S(" \t") ^ 0 * alt
end

local esc_any = P("\\") * P(1)

local function quoted (q)
  return P(q) * (esc_any + (P(1) - S(q .. "\n"))) ^ 0 * (P(q) + P(true))
end

local tline_body = (P(1) - P("\n") - tmpl_open) ^ 0

local function tquoted (q, esc, nl)
  local body = P(1) - (nl and S(q .. "\n") or P(q))
  if esc then body = esc_any + body end
  return P(q) * (tmpl_block + body) ^ 0 * (P(q) + P(true))
end

local function tbody (close, cut)
  local body = P(1) - P(close)
  if cut then body = body - tmpl_open end
  return body ^ 0 * (P(close) + P(true))
end

local function skip_blk (s, q, len)
  local e = find(s, "%>", q + 2, true)
  return e and (e + 2) or (len + 1)
end

local c_cont = P("\\") * (P("\r\n") + P("\n"))
local c_line_body = (c_cont + (P(1) - P("\n"))) ^ 0
local c_dir = dir_ahead(c_directives)

local c_grammar = tokenizer({
  { P("//") * #c_dir * c_line_body, "code" },
  { P("//") * c_line_body, "comment" },
  { P("/*") * #c_dir * (P(1) - P("*/")) ^ 0 * P("*/"), "code" },
  { P("/*") * (P(1) - P("*/")) ^ 0 * P("*/"), "comment" },
  { P("/*") * #c_dir * P(1) ^ 0, "code" },
  { P("/*") * P(1) ^ 0, "opaque" },
  { quoted("\""), "code" },
  { quoted("'"), "code" },
}, "/\"'")

local c_tline = (c_cont + (P(1) - P("\n") - tmpl_open)) ^ 0

local c_tgrammar = tokenizer({
  { tmpl_block, "code" },
  { P("//") * #c_dir * c_tline, "code" },
  { P("//") * c_tline, "comment" },
  { P("/*") * #c_dir * tbody("*/", true), "code" },
  { P("/*") * tbody("*/"), "comment" },
  { tquoted("\"", true, false), "code" },
  { tquoted("'", true, false), "code" },
}, "/\"'", true)

local function strip_c (src)
  return drive_grammar(c_grammar, src)
end

local js_keywords = {
  ["return"] = true, ["typeof"] = true, ["instanceof"] = true,
  ["in"] = true, ["of"] = true, ["new"] = true, ["delete"] = true,
  ["void"] = true, ["do"] = true, ["else"] = true, ["yield"] = true,
  ["await"] = true, ["case"] = true, ["throw"] = true,
}

local function js_regex_allowed (last)
  if last == nil then return true end
  local b = byte(last, #last)
  if b == 41 or b == 93 then return false end
  if is_ident_ch(b) then
    if js_keywords[last] then return true end
    return false
  end
  return true
end

local js_directives = { "tk:", "@ts-", "NOLINT", "clang-format", "eslint", "istanbul", "prettier", "c8", "webpack" }

local function strip_js (src)
  return drive_grammar(js_grammar, src)
end

local css_grammar = tokenizer({
  { P("/*") * (P(1) - P("*/")) ^ 0 * P("*/"), "comment" },
  { P("/*") * P(1) ^ 0, "opaque" },
  { quoted("\""), "code" },
  { quoted("'"), "code" },
}, "/\"'")

local css_tgrammar = tokenizer({
  { tmpl_block, "code" },
  { P("/*") * tbody("*/"), "comment" },
  { tquoted("\"", true, true), "code" },
  { tquoted("'", true, true), "code" },
}, "/\"'", true)

local function strip_css (src)
  return drive_grammar(css_grammar, src)
end

local function strip_html (src)
  return drive_grammar(html_grammar, src)
end

local function is_alpha_us (b)
  return b and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95)
end

local function line_indent (src, pos)
  local ls = pos
  while ls > 1 and byte(src, ls - 1) ~= 10 do ls = ls - 1 end
  local n = 0
  while byte(src, ls) == 32 do
    n = n + 1
    ls = ls + 1
  end
  return n
end

hd_delim = function (src, pos, len)
  if byte(src, pos + 2) == 60 then return nil end
  local p = pos + 2
  local dash = false
  if byte(src, p) == 45 then
    dash = true
    p = p + 1
  end
  while byte(src, p) == 32 or byte(src, p) == 9 do p = p + 1 end
  if byte(src, p) == 92 then p = p + 1 end
  local q = byte(src, p)
  if q == 34 or q == 39 then
    local e = p + 1
    while e <= len and byte(src, e) ~= q do e = e + 1 end
    if e > len or e == p + 1 then return nil end
    return { delim = sub(src, p + 1, e - 1), dash = dash }, e + 1
  end
  if not is_alpha_us(q) then return nil end
  local s = p
  while p <= len and is_ident_ch(byte(src, p)) do p = p + 1 end
  return { delim = sub(src, s, p - 1), dash = dash }, p
end

hd_end = function (src, ls, le, hd, anyws)
  local p = ls
  if hd.dash then
    while p <= le do
      local b = byte(src, p)
      if b == 9 or (anyws and b == 32) then p = p + 1 else break end
    end
  end
  local d = hd.delim
  if sub(src, p, p + #d - 1) ~= d then return false end
  p = p + #d
  while p <= le do
    local b = byte(src, p)
    if b ~= 32 and b ~= 9 and b ~= 13 then return false end
    p = p + 1
  end
  return true
end

local sh_directives = { "tk:", "shellcheck", "noqa", "type:", "pylint", "mypy", "fmt:", "pragma:" }

local py_directives = {
  "tk:", "noqa", "type:", "pylint", "mypy", "fmt:", "pragma:", "-*-", "coding=", "coding:",
}

local yaml_directives = {
  "tk:", "cloud-config", "yaml-language-server:", "noqa", "type:", "fmt:", "pragma:", "shellcheck",
}

local docker_directives = { "tk:", "syntax=", "escape=", "check=" }

local conf_directives = { "tk:", "shellcheck", "noqa", "fmt:", "pragma:" }

local line_body = (P(1) - P("\n")) ^ 0
local word_start = -B(P(1)) + B(S(" \t\n\r"))

local line_start = Cmt(Cp(), function (s, i, p)
  local q = p - 1
  while q >= 1 do
    local b = byte(s, q)
    if b == 32 or b == 9 then
      q = q - 1
    elseif b == 10 then
      return i
    else
      return false
    end
  end
  return i
end)

local shebang_at = Cmt(Cp(), function (s, i, p)
  if p == 1 then return i end
  local nl = find(s, "\n", 1, true)
  return (nl and p == nl + 1) and i or false
end)

local shebang_tok = shebang_at * P("#!") * line_body
local shebang_tok_t = shebang_at * P("#!") * tline_body

local function triple (q)
  local t = P(q .. q .. q)
  return t * (esc_any + (P(1) - t)) ^ 0 * (t + P(true))
end

local function ttriple (q)
  local t = P(q .. q .. q)
  return t * (tmpl_block + esc_any + (P(1) - t)) ^ 0 * (t + P(true))
end

local conf_grammar = tokenizer({
  { shebang_tok, "code" },
  { word_start * P("#") * #dir_ahead(conf_directives), "code" },
  { word_start * P("#") * line_body, "comment" },
  { quoted("\""), "code" },
  { quoted("'"), "code" },
}, "#\"'")

local conf_tgrammar = tokenizer({
  { tmpl_block, "code" },
  { shebang_tok_t, "code" },
  { word_start * P("#") * #dir_ahead(conf_directives) * tline_body, "code" },
  { word_start * P("#") * tline_body, "comment" },
  { tquoted("\"", true, true), "code" },
  { tquoted("'", true, true), "code" },
}, "#\"'", true)

local unit_grammar = tokenizer({
  { line_start * S("#;") * line_body, "comment" },
}, "#;")

local unit_tgrammar = tokenizer({
  { tmpl_block, "code" },
  { line_start * S("#;") * tline_body, "comment" },
}, "#;", true)

local py_grammar = tokenizer({
  { shebang_tok, "code" },
  { P("#") * #dir_ahead(py_directives) * line_body, "code" },
  { P("#") * line_body, "comment" },
  { triple("\""), "opaque" },
  { triple("'"), "opaque" },
  { quoted("\""), "code" },
  { quoted("'"), "code" },
}, "#\"'")

local py_tgrammar = tokenizer({
  { tmpl_block, "code" },
  { shebang_tok_t, "code" },
  { P("#") * #dir_ahead(py_directives) * tline_body, "code" },
  { P("#") * tline_body, "comment" },
  { ttriple("\""), "opaque" },
  { ttriple("'"), "opaque" },
  { tquoted("\"", true, true), "code" },
  { tquoted("'", true, true), "code" },
}, "#\"'", true)

local lua_eq = P("=") ^ 0
local lua_open = P("[") * Cg(C(lua_eq), "lvl") * P("[")
local lua_close = Cmt(P("]") * C(lua_eq) * P("]") * Cb("lvl"), function (_, i, a, b)
  return a == b and i or false
end)
local lua_long = lua_open * (P(1) - lua_close) ^ 0 * lua_close
local lua_long_open = lua_open * P(1) ^ 0
local lua_dir = S(" \t") ^ 0 * (P("luacheck:") + P("luacov:") + P("tk:"))

lua_grammar = tokenizer({
  { P("--") * lua_long, "comment" },
  { P("--") * lua_long_open, "opaque" },
  { P("--") * #lua_dir * line_body, "code" },
  { P("--") * line_body, "comment" },
  { quoted("\""), "code" },
  { quoted("'"), "code" },
  { lua_long, "opaque" },
  { lua_long_open, "opaque" },
}, "-\"'[")

local lua_tlong = lua_open * (tmpl_block + (P(1) - lua_close)) ^ 0 * lua_close

local lua_tgrammar = tokenizer({
  { tmpl_block, "code" },
  { P("--") * lua_long, "comment" },
  { P("--") * lua_long_open, "comment" },
  { P("--") * #lua_dir * tline_body, "code" },
  { P("--") * tline_body, "comment" },
  { tquoted("\"", true, true), "code" },
  { tquoted("'", true, true), "code" },
  { lua_tlong, "opaque" },
  { lua_long_open, "opaque" },
}, "-\"'[", true)

html_grammar = tokenizer({
  { P("<!--") * (P(1) - P("-->")) ^ 0 * P("-->"), "comment" },
  { P("<!--") * P(1) ^ 0, "opaque" },
}, "<")

local html_tgrammar = tokenizer({
  { tmpl_block, "code" },
  { P("<!--") * tbody("-->"), "comment" },
}, "<", true)

local function hd_scan (s, p, hd, anyws)
  local len = #s
  while p <= len do
    local nl = find(s, "\n", p, true)
    if not nl then break end
    if hd_end(s, p, nl - 1, hd, anyws) then return nl + 1 end
    p = nl + 1
  end
  if p <= len and hd_end(s, p, len, hd, anyws) then return len + 1 end
  return nil
end

local hd_start = Cmt(Cp() * P("<<"), function (s, _, p)
  local hd, np = hd_delim(s, p, #s)
  if not hd then return false end
  gpend[#gpend + 1] = hd
  return np
end)

local function hd_run (anyws)
  return Cmt(P("\n"), function (s, i)
    if #gpend == 0 then return false end
    local p = i
    local len = #s
    while #gpend > 0 and p <= len do
      local hd = table.remove(gpend, 1)
      local np = hd_scan(s, p, hd, anyws)
      if not np then gbail = true return false end
      p = np
    end
    return p
  end)
end

local function arith (opener, t)
  return Cmt(opener, function (s, i)
    local d, q, len = 2, i, #s
    while q <= len do
      local c = byte(s, q)
      if t and c == 60 and byte(s, q + 1) == 37 then
        q = skip_blk(s, q, len)
      else
        if c == 40 then d = d + 1
        elseif c == 41 then
          d = d - 1
          if d == 0 then return q + 1 end
        end
        q = q + 1
      end
    end
    return len + 1
  end)
end

local function quoted_ml (q, esc)
  if esc then
    return P(q) * (esc_any + (P(1) - P(q))) ^ 0 * (P(q) + P(true))
  end
  return P(q) * (P(1) - P(q)) ^ 0 * (P(q) + P(true))
end

local sh_grammar = tokenizer({
  { shebang_tok, "code" },
  { word_start * P("#") * #dir_ahead(sh_directives) * line_body, "code" },
  { word_start * P("#") * line_body, "comment" },
  { quoted_ml("'", false), "opaque" },
  { quoted_ml("\"", true), "opaque" },
  { quoted_ml("`", true), "opaque" },
  { P("\\") * P(1) ^ -1, "code" },
  { arith(P("$((")), "code" },
  { arith(word_start * P("((")), "code" },
  { hd_start, "code" },
  { P("<<"), "code" },
  { hd_run(false), "opaque" },
}, "#'\"`$<\\\n(")

local sh_tgrammar = tokenizer({
  { tmpl_block, "code" },
  { shebang_tok_t, "code" },
  { word_start * P("#") * #dir_ahead(sh_directives) * tline_body, "code" },
  { word_start * P("#") * tline_body, "comment" },
  { tquoted("'", false, false), "opaque" },
  { tquoted("\"", true, false), "opaque" },
  { tquoted("`", true, false), "opaque" },
  { P("\\") * (P(1) - tmpl_open) ^ -1, "code" },
  { arith(P("$(("), true), "code" },
  { arith(word_start * P("(("), true), "code" },
  { hd_start, "code" },
  { P("<<"), "code" },
  { hd_run(false), "opaque" },
}, "#'\"`$<\\\n(", true)

local hcl_grammar = tokenizer({
  { P("#") * line_body, "comment" },
  { P("//") * line_body, "comment" },
  { P("/*") * (P(1) - P("*/")) ^ 0 * P("*/"), "comment" },
  { P("/*") * P(1) ^ 0, "opaque" },
  { quoted("\""), "code" },
  { hd_start, "code" },
  { P("<<"), "code" },
  { hd_run(true), "opaque" },
}, "#/\"<\n")

local hcl_tgrammar = tokenizer({
  { tmpl_block, "code" },
  { P("#") * tline_body, "comment" },
  { P("//") * tline_body, "comment" },
  { P("/*") * tbody("*/"), "comment" },
  { tquoted("\"", true, true), "code" },
  { hd_start, "code" },
  { P("<<"), "code" },
  { hd_run(true), "opaque" },
}, "#/\"<\n", true)

local docker_grammar = tokenizer({
  { line_start * P("#") * #dir_ahead(docker_directives) * line_body, "code" },
  { line_start * P("#") * line_body, "comment" },
  { quoted("\""), "code" },
  { quoted("'"), "code" },
  { hd_start, "code" },
  { P("<<"), "code" },
  { hd_run(true), "opaque" },
}, "#\"'<\n")

local docker_tgrammar = tokenizer({
  { tmpl_block, "code" },
  { line_start * P("#") * #dir_ahead(docker_directives) * tline_body, "code" },
  { line_start * P("#") * tline_body, "comment" },
  { tquoted("\"", true, true), "code" },
  { tquoted("'", false, true), "code" },
  { hd_start, "code" },
  { P("<<"), "code" },
  { hd_run(true), "opaque" },
}, "#\"'<\n", true)

local yaml_dq = P("\"") * (esc_any + (P(1) - P("\""))) ^ 0 * (P("\"") + P(true))
local yaml_sq = P("'") * (P("''") + (P(1) - P("'"))) ^ 0 * (P("'") + P(true))
local yaml_tdq = tquoted("\"", true, false)
local yaml_tsq = P("'") * (tmpl_block + P("''") + (P(1) - P("'"))) ^ 0 * (P("'") + P(true))

local function yaml_blk (t)
  return Cmt(Cp() * S("|>") * (S("+-") + R("09")) ^ 0 * S(" \t\r") ^ 0 *
    #(P("\n") + P(-1) + (t and tmpl_open or P(false))), function (s, i, p)
    if t and byte(s, i) == 60 then return i end
    local indent = line_indent(s, p)
    local len = #s
    local nl = find(s, "\n", i, true)
    if not nl then return len + 1 end
    local q = nl + 1
    while q <= len do
      local e = find(s, "\n", q, true)
      local le = e and (e - 1) or len
      local r, n = q, 0
      while r <= le and byte(s, r) == 32 do n = n + 1 r = r + 1 end
      local blank = r > le or byte(s, r) == 13
      if not blank and n <= indent then return q end
      if not e then break end
      q = e + 1
    end
    return len + 1
  end)
end

local yaml_grammar = tokenizer({
  { shebang_tok, "code" },
  { word_start * P("#") * #dir_ahead(yaml_directives) * line_body, "code" },
  { word_start * P("#") * line_body, "comment" },
  { yaml_dq, "code" },
  { yaml_sq, "code" },
  { word_start * yaml_blk(false), "opaque" },
}, "#\"'|>")

local yaml_tgrammar = tokenizer({
  { tmpl_block, "code" },
  { shebang_tok_t, "code" },
  { word_start * P("#") * #dir_ahead(yaml_directives) * tline_body, "code" },
  { word_start * P("#") * tline_body, "comment" },
  { yaml_tdq, "code" },
  { yaml_tsq, "code" },
  { word_start * yaml_blk(true), "opaque" },
}, "#\"'|>", true)

local function setlast (v)
  return Cmt(P(true), function (_, i) glast = v return i end)
end

local js_id = R("az", "AZ", "09") + S("_$")
local js_line_b = (P(1) - P("\n")) ^ 0
local js_blk = P("/*") * (P(1) - P("*/")) ^ 0 * P("*/")
local js_dir = dir_ahead(js_directives)
local js_class = P("[") * (esc_any + (P(1) - S("]\n"))) ^ 0 * (P("]") + P(true))
local js_regex = P("/") * (esc_any + js_class + (P(1) - S("/\n"))) ^ 0 *
  (P("/") + P(true)) * js_id ^ 0
local regex_ok = Cmt(P(true), function (_, i)
  return js_regex_allowed(glast) and i or false
end)
local function js_tmpl (t)
  return Cmt(P("`"), function (s, i)
    local d, q, len = 0, i, #s
    while q <= len do
      local c = byte(s, q)
      if c == 92 then q = q + 2
      elseif t and c == 60 and byte(s, q + 1) == 37 then q = skip_blk(s, q, len)
      elseif c == 96 and d == 0 then return q + 1
      elseif c == 36 and byte(s, q + 1) == 123 then d = d + 1 q = q + 2
      elseif c == 125 and d > 0 then d = d - 1 q = q + 1
      else q = q + 1 end
    end
    return len + 1
  end)
end
local js_str = function (q)
  return P(q) * (esc_any + (P(1) - P(q))) ^ 0 * (P(q) + P(true))
end
local js_tclass = P("[") * (esc_any + (P(1) - S("]\n") - tmpl_open)) ^ 0 * (P("]") + P(true))
local js_tregex = P("/") * (esc_any + js_tclass + (P(1) - S("/\n") - tmpl_open)) ^ 0 *
  (P("/") + P(true)) * js_id ^ 0

js_grammar = tokenizer({
  { P("//") * #js_dir * js_line_b * setlast(nil), "code" },
  { P("//") * js_line_b * setlast(nil), "comment" },
  { P("/*") * #js_dir * js_blk * setlast(nil), "code" },
  { js_blk * setlast(nil), "comment" },
  { P("/*") * #js_dir * P(1) ^ 0 * setlast(nil), "code" },
  { P("/*") * P(1) ^ 0 * setlast(nil), "opaque" },
  { regex_ok * js_regex * setlast("\1"), "code" },
  { P("/") * setlast("/"), "code" },
  { js_str("\"") * setlast("\1"), "code" },
  { js_str("'") * setlast("\1"), "code" },
  { js_tmpl(false) * setlast("\1"), "opaque" },
  { Cmt(C(js_id ^ 1), function (_, i, w) glast = w return i end), "code" },
  { S(" \t\n\r") ^ 1, "code" },
  { Cmt(C(P(1)), function (_, i, c) glast = c return i end), "code" },
}, "/\"'`")

local js_tgrammar = tokenizer({
  { tmpl_block, "code" },
  { P("//") * #js_dir * tline_body * setlast(nil), "code" },
  { P("//") * tline_body * setlast(nil), "comment" },
  { P("/*") * #js_dir * tbody("*/", true) * setlast("\1"), "code" },
  { P("/*") * tbody("*/") * setlast("\1"), "comment" },
  { regex_ok * js_tregex * setlast("\1"), "code" },
  { P("/") * setlast("/"), "code" },
  { tquoted("\"", true, false) * setlast("\1"), "code" },
  { tquoted("'", true, false) * setlast("\1"), "code" },
  { js_tmpl(true) * setlast("\1"), "opaque" },
  { Cmt(C(js_id ^ 1), function (_, i, w) glast = w return i end), "code" },
  { S(" \t\n\r") ^ 1, "code" },
  { Cmt(C(P(1)), function (_, i, c) glast = c return i end), "code" },
}, "/\"'`", true)

local function strip_sh (src) return drive_grammar(sh_grammar, src) end
local function strip_hcl (src) return drive_grammar(hcl_grammar, src) end
local function strip_python (src) return drive_grammar(py_grammar, src) end
local function strip_yaml (src) return drive_grammar(yaml_grammar, src) end
local function strip_dockerfile (src) return drive_grammar(docker_grammar, src) end
local function strip_unit (src) return drive_grammar(unit_grammar, src) end
local function strip_conf (src) return drive_grammar(conf_grammar, src) end

local ext_map = {
  lua = strip_lua,
  c = strip_c, h = strip_c, cpp = strip_c, cc = strip_c, hpp = strip_c, m = strip_c,
  java = strip_c,
  js = strip_js,
  css = strip_css,
  html = strip_html, htm = strip_html,
  conf = strip_conf, env = strip_conf,
  sh = strip_sh, bash = strip_sh,
  tf = strip_hcl, tfvars = strip_hcl, hcl = strip_hcl,
  py = strip_python,
  yml = strip_yaml, yaml = strip_yaml,
  dockerfile = strip_dockerfile,
  service = strip_unit, timer = strip_unit, socket = strip_unit,
  json = false, md = false, txt = false, gitignore = false,
  svg = false, png = false, jpg = false, jpeg = false, gif = false,
  webp = false, ico = false, woff = false, woff2 = false, ttf = false,
  eot = false, pdf = false, gz = false, zip = false, tar = false,
}

local name_map = {
  Dockerfile = "dockerfile",
  dockerfile = "dockerfile",
  Containerfile = "dockerfile",
}

local shebang_map = {
  sh = "sh", bash = "sh", dash = "sh", ksh = "sh", zsh = "sh", ash = "sh",
  lua = "lua", luajit = "lua",
  python = "py",
}

local function shebang_lang (src)
  if byte(src, 1) ~= 35 or byte(src, 2) ~= 33 then return nil end
  local stop = (find(src, "\n", 1, true) or (#src + 1)) - 1
  local words = {}
  for w in sub(src, 3, stop):gmatch("%S+") do words[#words + 1] = w end
  local first = words[1]
  if not first then return nil end
  first = first:match("[^/\\]+$")
  if first == "env" then
    first = nil
    for i = 2, #words do
      local w = words[i]
      if not find(w, "=", 1, true) and sub(w, 1, 1) ~= "-" then
        first = w:match("[^/\\]+$")
        break
      end
    end
    if not first then return nil end
  end
  return shebang_map[first] or shebang_map[first:match("^%a+") or ""]
end

local grammars = {
  lua = lua_grammar,
  c = c_grammar, h = c_grammar, cpp = c_grammar, cc = c_grammar,
  hpp = c_grammar, m = c_grammar, java = c_grammar,
  js = js_grammar,
  css = css_grammar,
  conf = conf_grammar, env = conf_grammar,
  html = html_grammar, htm = html_grammar,
  sh = sh_grammar, bash = sh_grammar,
  tf = hcl_grammar, tfvars = hcl_grammar, hcl = hcl_grammar,
  py = py_grammar,
  yml = yaml_grammar, yaml = yaml_grammar,
  dockerfile = docker_grammar,
  service = unit_grammar, timer = unit_grammar, socket = unit_grammar,
}

local tmpl_none = tokenizer({ { tmpl_block, "code" } }, "", true)

local tmpl_grammars = {
  lua = lua_tgrammar,
  c = c_tgrammar, h = c_tgrammar, cpp = c_tgrammar, cc = c_tgrammar,
  hpp = c_tgrammar, m = c_tgrammar, java = c_tgrammar,
  js = js_tgrammar,
  css = css_tgrammar,
  conf = conf_tgrammar, env = conf_tgrammar,
  html = html_tgrammar, htm = html_tgrammar,
  sh = sh_tgrammar, bash = sh_tgrammar,
  tf = hcl_tgrammar, tfvars = hcl_tgrammar, hcl = hcl_tgrammar,
  py = py_tgrammar,
  yml = yaml_tgrammar, yaml = yaml_tgrammar,
  dockerfile = docker_tgrammar,
  service = unit_tgrammar, timer = unit_tgrammar, socket = unit_tgrammar,
}

local function emit_block (src, out, f)
  local close = find(src, "%>", f + 2, true)
  if not close then
    out[#out + 1] = sub(src, f)
    return #src + 1
  end
  local code = (strip_lua(sub(src, f + 2, close - 1)))
  if find(code, "^%s*$") then
    return after_comment(src, f, close + 2, out)
  end
  out[#out + 1] = "<%"
  out[#out + 1] = code
  out[#out + 1] = "%>"
  return close + 2
end

local function emit_code (src, out, a, b)
  local pos = a
  while pos < b do
    local f = find(src, "<%", pos, true)
    if not f or f >= b then
      out[#out + 1] = sub(src, pos, b - 1)
      return b
    end
    if f > pos then out[#out + 1] = sub(src, pos, f - 1) end
    pos = emit_block(src, out, f)
  end
  return pos
end

local function render_tmpl (src, toks)
  local out = {}
  local pos = 1
  for i = 1, #toks do
    local t = toks[i]
    local kind, s, e = t[1], t[2], t[3]
    if e > pos then
      if kind == "comment" and s >= pos then
        local f = find(src, "<%", s, true)
        if f and f < e then return nil end
        pos = after_comment(src, s, e, out)
      else
        pos = emit_code(src, out, s < pos and pos or s, e)
      end
    end
  end
  return concat(out)
end

local function strip_template (src, output_lang)
  local toks = grammar_toks(tmpl_grammars[output_lang] or tmpl_none, src)
  if not toks then return src, true end
  local out = render_tmpl(src, toks)
  if not out then return src, true end
  return guard(out, src, false)
end

local license_markers = {
  "Copyright", "copyright", "SPDX-License-Identifier",
  "Permission is hereby granted", "(C) 20", "(c) 20",
}

local function license_count (s)
  local n = 0
  for i = 1, #license_markers do
    local m = license_markers[i]
    local p = 1
    while true do
      local f = find(s, m, p, true)
      if not f then break end
      n = n + 1
      p = f + 1
    end
  end
  return n
end

local license_blocks = {
  { "/*", "*/" },
  { "<!--", "-->" },
  { "--[[", "]]" },
}

local license_lines = { "//", "--", "#", ";" }

local function eol_at (src, pos)
  return find(src, "\n", pos, true) or (#src + 1)
end

local function license_head (src)
  local len = #src
  local pos = 1
  if byte(src, 1) == 35 and byte(src, 2) == 33 then
    pos = eol_at(src, 1) + 1
  end
  while pos <= len do
    local b = byte(src, pos)
    if b == 32 or b == 9 or b == 10 or b == 13 then pos = pos + 1 else break end
  end
  if pos > len then return nil end
  for i = 1, #license_blocks do
    local o, c = license_blocks[i][1], license_blocks[i][2]
    if sub(src, pos, pos + #o - 1) == o then
      local e = find(src, c, pos + #o, true)
      if not e then return nil end
      local stop = e + #c - 1
      if license_count(sub(src, pos, stop)) == 0 then return nil end
      return eol_at(src, stop)
    end
  end
  for i = 1, #license_lines do
    local m = license_lines[i]
    if sub(src, pos, pos + #m - 1) == m then
      local last
      local p = pos
      while true do
        local e = eol_at(src, p)
        last = e
        local ns = e + 1
        if ns > len then break end
        local q = ns
        while q <= len and (byte(src, q) == 32 or byte(src, q) == 9) do q = q + 1 end
        if sub(src, q, q + #m - 1) ~= m then break end
        p = q
      end
      if license_count(sub(src, pos, last)) == 0 then return nil end
      return last
    end
  end
  return nil
end

local function mark_protected (src, patt, prot)
  local toks = grammar_toks(patt, src)
  if not toks then return false end
  for i = 1, #toks do
    local t = toks[i]
    if t[1] ~= "code" then
      local j = find(src, "\n", t[2], true)
      while j and j < t[3] do
        prot[j] = true
        j = find(src, "\n", j + 1, true)
      end
    end
  end
  return true
end

local function collapse_marked (src, prot)
  local out = {}
  local len = #src
  local pos = 1
  local blanks = 0
  while pos <= len do
    local nl = find(src, "\n", pos, true)
    local last = nl or len
    local text = sub(src, pos, nl and (nl - 1) or len)
    if nl and not prot[nl] and text:match("^[ \t\r]*$") then
      blanks = blanks + 1
      if blanks <= 1 then
        out[#out + 1] = sub(src, pos, last)
      end
    else
      blanks = 0
      out[#out + 1] = sub(src, pos, last)
    end
    pos = last + 1
  end
  return concat(out)
end

local function mark_blocks (src, prot)
  local len = #src
  local pos = 1
  while pos <= len do
    local f = find(src, "<%", pos, true)
    if not f then return end
    local close = find(src, "%>", f + 2, true)
    local stop = close and (close + 1) or len
    local i = find(src, "\n", f, true)
    while i and i <= stop do
      prot[i] = true
      i = find(src, "\n", i + 1, true)
    end
    pos = stop + 1
  end
end

local function collapse_blanks (src, lang, templated)
  local prot = {}
  local patt
  if templated then
    mark_blocks(src, prot)
    patt = tmpl_grammars[lang]
  else
    patt = grammars[lang]
    if not patt then return src end
  end
  if patt and not mark_protected(src, patt, prot) then return src end
  return collapse_marked(src, prot)
end

local function split_ext (filename)
  local base = filename:match("[^/\\]+$") or filename
  local tk = base:match("%.tk%.([%w]+)$")
  if tk then
    return true, tk:lower()
  end
  tk = base:match("%.([%w]+)%.tk$")
  if tk then
    return true, tk:lower()
  end
  if base:match("%.tk$") then
    return true, nil
  end
  return false, base
end

local function tk_directive (src)
  local len = #src
  local pos = 1
  for _ = 1, 2 do
    if pos > len then break end
    local e = (find(src, "\n", pos, true) or (len + 1)) - 1
    local line = sub(src, pos, e)
    local lang =
      line:match("^%s*#+%s*tk:%s*([%w]+)") or
      line:match("^%s*%-%-%s*tk:%s*([%w]+)") or
      line:match("^%s*//%s*tk:%s*([%w]+)") or
      line:match("^%s*;+%s*tk:%s*([%w]+)")
    if lang then return lang:lower() end
    pos = e + 2
  end
  return nil
end

local function lang_for (src, base)
  local nm = name_map[base]
  if nm then return nm end
  local ext = base:match("%.([%w]+)$")
  if ext then return ext:lower() end
  return shebang_lang(src)
end

local function coverage (src, filename)
  if tk_directive(src) then return "checked" end
  local is_tk, rest = split_ext(filename)
  if is_tk then return "checked" end
  local fn = ext_map[lang_for(src, rest)]
  if fn == false then return "ignored" end
  if fn == nil then return "unknown" end
  return "checked"
end

local function strip (src, filename)
  local is_tk, rest = split_ext(filename)
  local tk = tk_directive(src)
  if tk then
    is_tk, rest = true, tk
  end
  local fn
  local lang = rest
  if is_tk then
    fn = function (s) return strip_template(s, rest) end
  else
    lang = lang_for(src, rest)
    fn = ext_map[lang]
    if fn == nil or fn == false then
      return src, false
    end
  end
  local out, bailed
  local head = license_head(src)
  if head then
    local body
    body, bailed = fn(sub(src, head + 1))
    out = sub(src, 1, head) .. body
  else
    out, bailed = fn(src)
  end
  if bailed then return src, true end
  out = collapse_blanks(out, lang, is_tk)
  if not is_subseq(out, src) then return src, true end
  if license_count(out) < license_count(src) then return src, true end
  return out, false
end

return {
  strip = strip,
  coverage = coverage,
  license_head = license_head,
  strip_lua = strip_lua,
  strip_c = strip_c,
  strip_js = strip_js,
  strip_css = strip_css,
  strip_conf = strip_conf,
  strip_html = strip_html,
  strip_sh = strip_sh,
  strip_hcl = strip_hcl,
  strip_python = strip_python,
  strip_yaml = strip_yaml,
  strip_dockerfile = strip_dockerfile,
  strip_unit = strip_unit,
  strip_template = strip_template,
}
