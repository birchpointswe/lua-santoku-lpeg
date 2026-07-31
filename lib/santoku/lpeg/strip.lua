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

local function after_comment (src, pos, out, multiline)
  local p = ws_after(src, pos)
  local b = byte(src, p)
  if b == nil or b == 10 or b == 13 then
    trim_trailing(out)
    return p
  end
  if multiline then
    trim_trailing(out)
  end
  return pos
end

local function long_bracket_open (src, pos)
  if byte(src, pos) ~= 91 then return nil end
  local p = pos + 1
  local level = 0
  while byte(src, p) == 61 do
    level = level + 1
    p = p + 1
  end
  if byte(src, p) == 91 then
    return level, p + 1
  end
  return nil
end

local function long_bracket_close (src, pos, level)
  if byte(src, pos) ~= 93 then return nil end
  local p = pos + 1
  local n = 0
  while byte(src, p) == 61 do
    n = n + 1
    p = p + 1
  end
  if n == level and byte(src, p) == 93 then
    return p + 1
  end
  return nil
end

local function strip_lua (src)
  local out = {}
  local pos = 1
  local len = #src
  local bailed = false
  while pos <= len do
    local b = byte(src, pos)
    if b == 45 and byte(src, pos + 1) == 45 then
      local cs = pos + 2
      local level, after = long_bracket_open(src, cs)
      if level then
        local p = after
        local closed = nil
        while p <= len do
          local e = long_bracket_close(src, p, level)
          if e then closed = e; break end
          p = p + 1
        end
        if closed then
          local ml = find(src, "\n", pos, true)
          pos = after_comment(src, closed, out, ml ~= nil and ml < closed)
        else
          out[#out + 1] = sub(src, pos)
          pos = len + 1
        end
      else
        local txt_start = ws_after(src, cs)
        local rest = sub(src, txt_start)
        if find(rest, "^luacheck:") or find(rest, "^luacov:") then
          local nl = find(src, "\n", pos, true)
          if nl then
            out[#out + 1] = sub(src, pos, nl - 1)
            pos = nl
          else
            out[#out + 1] = sub(src, pos)
            pos = len + 1
          end
        else
          local nl = find(src, "\n", cs, true)
          pos = after_comment(src, nl or (len + 1), out, false)
        end
      end
    elseif b == 34 or b == 39 then
      local q = b
      local start = pos
      pos = pos + 1
      while pos <= len do
        local c = byte(src, pos)
        if c == 92 then
          pos = pos + 2
        elseif c == q then
          pos = pos + 1
          break
        elseif c == 10 then
          break
        else
          pos = pos + 1
        end
      end
      out[#out + 1] = sub(src, start, pos - 1)
    elseif b == 91 then
      local level, after = long_bracket_open(src, pos)
      if level then
        local start = pos
        local p = after
        local closed = nil
        while p <= len do
          local e = long_bracket_close(src, p, level)
          if e then closed = e; break end
          p = p + 1
        end
        if closed then
          out[#out + 1] = sub(src, start, closed - 1)
          pos = closed
        else
          out[#out + 1] = sub(src, start)
          pos = len + 1
        end
      else
        out[#out + 1] = sub(src, pos, pos)
        pos = pos + 1
      end
    else
      out[#out + 1] = sub(src, pos, pos)
      pos = pos + 1
    end
  end
  return guard(concat(out), src, bailed)
end

local c_directives = { "NOLINT", "clang-format", "@ts-", "IWYU pragma:", "NOSONAR" }

local function has_directive (src, pos, list)
  local p = ws_after(src, pos)
  local rest = sub(src, p)
  for i = 1, #list do
    if find(rest, list[i], 1, true) == 1 then
      return true
    end
  end
  return false
end

local function strip_c_line (src, pos, len, out)
  local start = pos
  pos = pos + 2
  while pos <= len do
    local c = byte(src, pos)
    if c == 10 then
      break
    elseif c == 92 then
      if byte(src, pos + 1) == 10 then
        pos = pos + 2
      elseif byte(src, pos + 1) == 13 and byte(src, pos + 2) == 10 then
        pos = pos + 3
      else
        pos = pos + 1
      end
    else
      pos = pos + 1
    end
  end
  if has_directive(src, start + 2, c_directives) then
    out[#out + 1] = sub(src, start, pos - 1)
    return pos
  end
  return after_comment(src, pos, out, false)
end

local function strip_c_block (src, pos, len, out)
  local start = pos
  local p = pos + 2
  local closed = nil
  while p <= len do
    if byte(src, p) == 42 and byte(src, p + 1) == 47 then
      closed = p + 2
      break
    end
    p = p + 1
  end
  if not closed then
    out[#out + 1] = sub(src, start)
    return len + 1
  end
  if has_directive(src, start + 2, c_directives) then
    out[#out + 1] = sub(src, start, closed - 1)
    return closed
  end
  local inner = sub(src, start, closed - 1)
  local nl = inner:gsub("[^\n]", "")
  local np = after_comment(src, closed, out, #nl > 0)
  out[#out + 1] = nl
  return np
end

local function copy_c_string (src, pos, len, out, q)
  local start = pos
  pos = pos + 1
  while pos <= len do
    local c = byte(src, pos)
    if c == 92 then
      pos = pos + 2
    elseif c == q then
      pos = pos + 1
      break
    elseif c == 10 then
      break
    else
      pos = pos + 1
    end
  end
  out[#out + 1] = sub(src, start, pos - 1)
  return pos
end

local function strip_c (src)
  local out = {}
  local pos = 1
  local len = #src
  while pos <= len do
    local b = byte(src, pos)
    if b == 47 and byte(src, pos + 1) == 47 then
      pos = strip_c_line(src, pos, len, out)
    elseif b == 47 and byte(src, pos + 1) == 42 then
      pos = strip_c_block(src, pos, len, out)
    elseif b == 34 or b == 39 then
      pos = copy_c_string(src, pos, len, out, b)
    else
      out[#out + 1] = sub(src, pos, pos)
      pos = pos + 1
    end
  end
  return guard(concat(out), src, false)
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

local function copy_js_string (src, pos, len, out, q)
  local start = pos
  pos = pos + 1
  while pos <= len do
    local c = byte(src, pos)
    if c == 92 then
      pos = pos + 2
    elseif c == q then
      pos = pos + 1
      break
    else
      pos = pos + 1
    end
  end
  out[#out + 1] = sub(src, start, pos - 1)
  return pos
end

local function copy_js_template (src, pos, len, out)
  local start = pos
  pos = pos + 1
  local depth = 0
  while pos <= len do
    local c = byte(src, pos)
    if c == 92 then
      pos = pos + 2
    elseif c == 96 and depth == 0 then
      pos = pos + 1
      break
    elseif c == 36 and byte(src, pos + 1) == 123 then
      depth = depth + 1
      pos = pos + 2
    elseif c == 125 and depth > 0 then
      depth = depth - 1
      pos = pos + 1
    else
      pos = pos + 1
    end
  end
  out[#out + 1] = sub(src, start, pos - 1)
  return pos
end

local function copy_js_regex (src, pos, len, out)
  local start = pos
  pos = pos + 1
  local in_class = false
  while pos <= len do
    local c = byte(src, pos)
    if c == 92 then
      pos = pos + 2
    elseif c == 91 then
      in_class = true
      pos = pos + 1
    elseif c == 93 then
      in_class = false
      pos = pos + 1
    elseif c == 47 and not in_class then
      pos = pos + 1
      break
    elseif c == 10 then
      break
    else
      pos = pos + 1
    end
  end
  while pos <= len and is_ident_ch(byte(src, pos)) do
    pos = pos + 1
  end
  out[#out + 1] = sub(src, start, pos - 1)
  return pos
end

local js_directives = { "@ts-", "NOLINT", "clang-format", "eslint", "istanbul", "prettier", "c8", "webpack" }

local function strip_js_line (src, pos, len, out)
  local start = pos
  pos = pos + 2
  while pos <= len and byte(src, pos) ~= 10 do
    pos = pos + 1
  end
  if has_directive(src, start + 2, js_directives) then
    out[#out + 1] = sub(src, start, pos - 1)
    return pos
  end
  return after_comment(src, pos, out, false)
end

local function strip_js_block (src, pos, len, out)
  local start = pos
  local p = pos + 2
  local closed = nil
  while p <= len do
    if byte(src, p) == 42 and byte(src, p + 1) == 47 then
      closed = p + 2
      break
    end
    p = p + 1
  end
  if not closed then
    out[#out + 1] = sub(src, start)
    return len + 1
  end
  if has_directive(src, start + 2, js_directives) then
    out[#out + 1] = sub(src, start, closed - 1)
    return closed
  end
  local nl = (sub(src, start, closed - 1):gsub("[^\n]", ""))
  local np = after_comment(src, closed, out, #nl > 0)
  out[#out + 1] = nl
  return np
end

local function strip_js (src)
  local out = {}
  local pos = 1
  local len = #src
  local last = nil
  while pos <= len do
    local b = byte(src, pos)
    if b == 47 and byte(src, pos + 1) == 47 then
      pos = strip_js_line(src, pos, len, out)
      last = nil
    elseif b == 47 and byte(src, pos + 1) == 42 then
      pos = strip_js_block(src, pos, len, out)
      last = nil
    elseif b == 47 then
      if js_regex_allowed(last) then
        pos = copy_js_regex(src, pos, len, out)
        last = "\1"
      else
        out[#out + 1] = "/"
        pos = pos + 1
        last = "/"
      end
    elseif b == 34 or b == 39 then
      pos = copy_js_string(src, pos, len, out, b)
      last = "\1"
    elseif b == 96 then
      pos = copy_js_template(src, pos, len, out)
      last = "\1"
    elseif is_ident_ch(b) then
      local start = pos
      while pos <= len and is_ident_ch(byte(src, pos)) do
        pos = pos + 1
      end
      last = sub(src, start, pos - 1)
      out[#out + 1] = last
    elseif b == 32 or b == 9 or b == 10 or b == 13 then
      out[#out + 1] = sub(src, pos, pos)
      pos = pos + 1
    else
      out[#out + 1] = sub(src, pos, pos)
      last = sub(src, pos, pos)
      pos = pos + 1
    end
  end
  return guard(concat(out), src, false)
end

local function strip_css (src)
  local out = {}
  local pos = 1
  local len = #src
  while pos <= len do
    local b = byte(src, pos)
    if b == 47 and byte(src, pos + 1) == 42 then
      local p = pos + 2
      local closed = nil
      while p <= len do
        if byte(src, p) == 42 and byte(src, p + 1) == 47 then
          closed = p + 2
          break
        end
        p = p + 1
      end
      if not closed then
        out[#out + 1] = sub(src, pos)
        pos = len + 1
      else
        local nl = (sub(src, pos, closed - 1):gsub("[^\n]", ""))
        pos = after_comment(src, closed, out, #nl > 0)
        out[#out + 1] = nl
      end
    elseif b == 34 or b == 39 then
      pos = copy_c_string(src, pos, len, out, b)
    else
      out[#out + 1] = sub(src, pos, pos)
      pos = pos + 1
    end
  end
  return guard(concat(out), src, false)
end

local function strip_html (src)
  local out = {}
  local pos = 1
  local len = #src
  while pos <= len do
    if byte(src, pos) == 60 and byte(src, pos + 1) == 33 and
       byte(src, pos + 2) == 45 and byte(src, pos + 3) == 45 then
      local p = pos + 4
      local closed = nil
      while p <= len do
        if byte(src, p) == 45 and byte(src, p + 1) == 45 and byte(src, p + 2) == 62 then
          closed = p + 3
          break
        end
        p = p + 1
      end
      if not closed then
        out[#out + 1] = sub(src, pos)
        pos = len + 1
      else
        local nl = (sub(src, pos, closed - 1):gsub("[^\n]", ""))
        pos = after_comment(src, closed, out, #nl > 0)
        out[#out + 1] = nl
      end
    else
      local next_lt = find(src, "<", pos, true)
      local text_end = next_lt and (next_lt - 1) or len
      if text_end < pos then
        out[#out + 1] = sub(src, pos, pos)
        pos = pos + 1
      else
        out[#out + 1] = sub(src, pos, text_end)
        pos = text_end + 1
      end
    end
  end
  return guard(concat(out), src, false)
end

local function nlonly (s)
  return (s:gsub("[^\n]", ""))
end

local function drive (step, src)
  local out = {}
  local pos = 1
  local len = #src
  local st = nil
  while pos <= len do
    local np, emit_end, stripped, nst, bail = step(src, pos, len, st)
    if bail then return src, true end
    if stripped then
      local nl = nlonly(sub(src, pos, np - 1))
      np = after_comment(src, np, out, #nl > 0)
      out[#out + 1] = nl
    elseif emit_end >= pos then
      out[#out + 1] = sub(src, pos, emit_end)
    end
    pos = np
    st = nst
  end
  return guard(concat(out), src, false)
end

local function is_alpha_us (b)
  return b and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95)
end

local function at_word_start (src, pos)
  if pos <= 1 then return true end
  local b = byte(src, pos - 1)
  return b == 32 or b == 9 or b == 10 or b == 13
end

local function at_line_start (src, pos)
  local p = pos - 1
  while p >= 1 do
    local b = byte(src, p)
    if b == 32 or b == 9 then p = p - 1
    elseif b == 10 or b == 13 then return true
    else return false end
  end
  return true
end

local function is_shebang (src, pos)
  return pos == 1 and byte(src, 1) == 35 and byte(src, 2) == 33
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

local function hd_delim (src, pos, len)
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

local function hd_end (src, ls, le, hd, anyws)
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

local function hd_pop (st)
  local nst = { pend = {} }
  if st.pend then
    nst.hd = st.pend[1]
    for i = 2, #st.pend do nst.pend[i - 1] = st.pend[i] end
  end
  return nst
end

local function hd_push (st, hd)
  local pend = {}
  if st.pend then
    for i = 1, #st.pend do pend[i] = st.pend[i] end
  end
  pend[#pend + 1] = hd
  return { pend = pend }
end

local function hd_body (src, pos, stop, st, anyws)
  local p = pos
  while p <= stop do
    local nl = find(src, "\n", p, true)
    if not nl or nl > stop then break end
    if hd_end(src, p, nl - 1, st.hd, anyws) then
      return nl + 1, nl, false, hd_pop(st)
    end
    p = nl + 1
  end
  if stop >= #src then
    if p <= stop and hd_end(src, p, stop, st.hd, anyws) then
      return stop + 1, stop, false, hd_pop(st)
    end
    return stop + 1, stop, false, st, true
  end
  return stop + 1, stop, false, st
end

local function hd_newline (pos, st)
  if st.pend and #st.pend > 0 then
    return pos + 1, pos, false, hd_pop(st)
  end
  return pos + 1, pos, false, st
end

local function line_end (src, pos, stop)
  local nl = find(src, "\n", pos, true)
  if nl and nl <= stop then return nl - 1 end
  return stop
end

local sh_directives = { "shellcheck", "noqa", "type:", "pylint", "mypy", "fmt:", "pragma:" }

local function step_sh (src, pos, stop, st)
  st = st or {}
  if st.hd then return hd_body(src, pos, stop, st, false) end
  if st.q then
    local q, esc = st.q, st.esc
    local p = pos
    while p <= stop do
      local c = byte(src, p)
      if esc and c == 92 then p = p + 2
      elseif c == q then return p + 1, p, false, { pend = st.pend }
      else p = p + 1 end
    end
    return stop + 1, stop, false, st
  end
  if st.arith then
    local d = st.arith
    local p = pos
    while p <= stop do
      local c = byte(src, p)
      if c == 40 then d = d + 1
      elseif c == 41 then
        d = d - 1
        if d == 0 then return p + 1, p, false, { pend = st.pend } end
      end
      p = p + 1
    end
    return stop + 1, stop, false, { pend = st.pend, arith = d }
  end
  local b = byte(src, pos)
  if b == 35 and at_word_start(src, pos) then
    local last = line_end(src, pos, stop)
    if is_shebang(src, pos) or has_directive(src, pos + 1, sh_directives) then
      return last + 1, last, false, st
    end
    return last + 1, pos - 1, true, st
  elseif b == 39 or b == 34 or b == 96 then
    local esc = b ~= 39
    local p = pos + 1
    while p <= stop do
      local c = byte(src, p)
      if esc and c == 92 then p = p + 2
      elseif c == b then return p + 1, p, false, { pend = st.pend }
      else p = p + 1 end
    end
    return stop + 1, stop, false, { pend = st.pend, q = b, esc = esc }
  elseif b == 92 then
    local last = pos + 1 <= stop and pos + 1 or stop
    return last + 1, last, false, st
  elseif b == 36 and byte(src, pos + 1) == 40 and byte(src, pos + 2) == 40 then
    return pos + 3, pos + 2, false, { pend = st.pend, arith = 2 }
  elseif b == 40 and byte(src, pos + 1) == 40 and at_word_start(src, pos) then
    return pos + 2, pos + 1, false, { pend = st.pend, arith = 2 }
  elseif b == 60 and byte(src, pos + 1) == 60 then
    local hd, np = hd_delim(src, pos, #src)
    if hd then
      if np > stop + 1 then np = stop + 1 end
      return np, np - 1, false, hd_push(st, hd)
    end
    local last = pos + 1 <= stop and pos + 1 or stop
    return last + 1, last, false, st
  elseif b == 10 then
    return hd_newline(pos, st)
  end
  local nxt = find(src, "[#'\"`$<\\\n(]", pos + 1)
  local last = (nxt and nxt <= stop) and (nxt - 1) or stop
  return last + 1, last, false, st
end

local function step_hcl (src, pos, stop, st)
  st = st or {}
  if st.hd then return hd_body(src, pos, stop, st, true) end
  if st.q then
    local p = pos
    while p <= stop do
      local c = byte(src, p)
      if c == 92 then p = p + 2
      elseif c == 34 then return p + 1, p, false, { pend = st.pend }
      elseif c == 10 then return p, p - 1, false, { pend = st.pend }
      else p = p + 1 end
    end
    return stop + 1, stop, false, st
  end
  if st.cmt then
    local p = pos
    while p <= stop do
      if byte(src, p) == 42 and byte(src, p + 1) == 47 then
        return p + 2, pos - 1, true, { pend = st.pend }
      end
      p = p + 1
    end
    return stop + 1, pos - 1, true, st
  end
  local b = byte(src, pos)
  if b == 35 or (b == 47 and byte(src, pos + 1) == 47) then
    local last = line_end(src, pos, stop)
    return last + 1, pos - 1, true, st
  elseif b == 47 and byte(src, pos + 1) == 42 then
    local p = pos + 2
    while p <= stop do
      if byte(src, p) == 42 and byte(src, p + 1) == 47 then
        return p + 2, pos - 1, true, st
      end
      p = p + 1
    end
    return stop + 1, pos - 1, true, { pend = st.pend, cmt = true }
  elseif b == 34 then
    local p = pos + 1
    while p <= stop do
      local c = byte(src, p)
      if c == 92 then p = p + 2
      elseif c == 34 then return p + 1, p, false, { pend = st.pend }
      elseif c == 10 then return p, p - 1, false, { pend = st.pend }
      else p = p + 1 end
    end
    return stop + 1, stop, false, { pend = st.pend, q = 34 }
  elseif b == 60 and byte(src, pos + 1) == 60 then
    local hd, np = hd_delim(src, pos, #src)
    if hd then
      if np > stop + 1 then np = stop + 1 end
      return np, np - 1, false, hd_push(st, hd)
    end
    local last = pos + 1 <= stop and pos + 1 or stop
    return last + 1, last, false, st
  elseif b == 10 then
    return hd_newline(pos, st)
  end
  local nxt = find(src, "[#/\"<\n]", pos + 1)
  local last = (nxt and nxt <= stop) and (nxt - 1) or stop
  return last + 1, last, false, st
end

local py_directives = {
  "noqa", "type:", "pylint", "mypy", "fmt:", "pragma:", "-*-", "coding=", "coding:",
}

local function py_string (src, stop, q, n, from)
  local p = from
  while p <= stop do
    local c = byte(src, p)
    if c == 92 then p = p + 2
    elseif c == q then
      if n == 1 then return p + 1, p, false, nil end
      if byte(src, p + 1) == q and byte(src, p + 2) == q then
        return p + 3, p + 2, false, nil
      end
      p = p + 1
    elseif c == 10 and n == 1 then
      return p, p - 1, false, nil
    else p = p + 1 end
  end
  return stop + 1, stop, false, { q = q, n = n }
end

local function step_python (src, pos, stop, st)
  if st and st.q then
    return py_string(src, stop, st.q, st.n, pos)
  end
  local b = byte(src, pos)
  if b == 35 then
    local last = line_end(src, pos, stop)
    if is_shebang(src, pos) or has_directive(src, pos + 1, py_directives) then
      return last + 1, last, false, nil
    end
    return last + 1, pos - 1, true, nil
  elseif b == 34 or b == 39 then
    if byte(src, pos + 1) == b and byte(src, pos + 2) == b then
      return py_string(src, stop, b, 3, pos + 3)
    end
    return py_string(src, stop, b, 1, pos + 1)
  end
  local nxt = find(src, "[#'\"]", pos + 1)
  local last = (nxt and nxt <= stop) and (nxt - 1) or stop
  return last + 1, last, false, nil
end

local yaml_directives = {
  "cloud-config", "yaml-language-server:", "noqa", "type:", "fmt:", "pragma:", "shellcheck",
}

local function yaml_block (src, pos, stop, st)
  local p = pos
  while p <= stop do
    local nl = find(src, "\n", p, true)
    local le = nl and (nl - 1) or stop
    local q = p
    local n = 0
    while q <= le and byte(src, q) == 32 do
      n = n + 1
      q = q + 1
    end
    local blank = q > le or byte(src, q) == 13
    if not blank and n <= st.blk then
      return p, p - 1, false, nil
    end
    if not nl or nl > stop then break end
    p = nl + 1
  end
  return stop + 1, stop, false, st
end

local function yaml_indicator (src, pos, stop)
  local p = pos + 1
  while p <= stop do
    local c = byte(src, p)
    if c == 43 or c == 45 or (c >= 48 and c <= 57) then p = p + 1 else break end
  end
  while p <= stop do
    local c = byte(src, p)
    if c == 32 or c == 9 or c == 13 then p = p + 1 else break end
  end
  return p > stop or byte(src, p) == 10
end

local function step_yaml (src, pos, stop, st)
  if st and st.blk then return yaml_block(src, pos, stop, st) end
  if st and st.q then
    local q = st.q
    local p = pos
    while p <= stop do
      local c = byte(src, p)
      if q == 34 and c == 92 then p = p + 2
      elseif c == q then
        if q == 39 and byte(src, p + 1) == 39 then p = p + 2
        else return p + 1, p, false, nil end
      else p = p + 1 end
    end
    return stop + 1, stop, false, st
  end
  local b = byte(src, pos)
  if b == 35 and at_word_start(src, pos) then
    local last = line_end(src, pos, stop)
    if is_shebang(src, pos) or has_directive(src, pos + 1, yaml_directives) then
      return last + 1, last, false, nil
    end
    return last + 1, pos - 1, true, nil
  elseif b == 34 or b == 39 then
    local p = pos + 1
    while p <= stop do
      local c = byte(src, p)
      if b == 34 and c == 92 then p = p + 2
      elseif c == b then
        if b == 39 and byte(src, p + 1) == 39 then p = p + 2
        else return p + 1, p, false, nil end
      else p = p + 1 end
    end
    return stop + 1, stop, false, { q = b }
  elseif (b == 124 or b == 62) and at_word_start(src, pos) and
         yaml_indicator(src, pos, stop) then
    local indent = line_indent(src, pos)
    local nl = find(src, "\n", pos, true)
    if not nl or nl > stop then
      return stop + 1, stop, false, nil
    end
    return nl + 1, nl, false, { blk = indent }
  end
  local nxt = find(src, "[#\"'|>]", pos + 1)
  local last = (nxt and nxt <= stop) and (nxt - 1) or stop
  return last + 1, last, false, nil
end

local docker_directives = { "syntax=", "escape=", "check=" }

local function step_dockerfile (src, pos, stop, st)
  st = st or {}
  if st.hd then return hd_body(src, pos, stop, st, true) end
  local b = byte(src, pos)
  if b == 35 and at_line_start(src, pos) then
    local last = line_end(src, pos, stop)
    if has_directive(src, pos + 1, docker_directives) then
      return last + 1, last, false, st
    end
    return last + 1, pos - 1, true, st
  elseif b == 34 or b == 39 then
    local p = pos + 1
    while p <= stop do
      local c = byte(src, p)
      if b == 34 and c == 92 then p = p + 2
      elseif c == b then return p + 1, p, false, st
      elseif c == 10 then return p, p - 1, false, st
      else p = p + 1 end
    end
    return stop + 1, stop, false, st
  elseif b == 60 and byte(src, pos + 1) == 60 then
    local hd, np = hd_delim(src, pos, #src)
    if hd then
      if np > stop + 1 then np = stop + 1 end
      return np, np - 1, false, hd_push(st, hd)
    end
    local last = pos + 1 <= stop and pos + 1 or stop
    return last + 1, last, false, st
  elseif b == 10 then
    return hd_newline(pos, st)
  end
  local nxt = find(src, "[#\"'<\n]", pos + 1)
  local last = (nxt and nxt <= stop) and (nxt - 1) or stop
  return last + 1, last, false, st
end

local function step_unit (src, pos, stop, _st)
  local b = byte(src, pos)
  if (b == 35 or b == 59) and at_line_start(src, pos) then
    local last = line_end(src, pos, stop)
    return last + 1, pos - 1, true, nil
  end
  local nxt = find(src, "[#;]", pos + 1)
  local last = (nxt and nxt <= stop) and (nxt - 1) or stop
  return last + 1, last, false, nil
end

local conf_directives = { "shellcheck", "noqa", "fmt:", "pragma:" }

local function step_conf (src, pos, stop, st)
  if st and st.q then
    local q = st.q
    local p = pos
    while p <= stop do
      local c = byte(src, p)
      if c == 92 then p = p + 2
      elseif c == q then return p + 1, p, false, nil
      elseif c == 10 then return p, p - 1, false, nil
      else p = p + 1 end
    end
    return stop + 1, stop, false, st
  end
  local b = byte(src, pos)
  if b == 35 and at_word_start(src, pos) then
    local last = line_end(src, pos, stop)
    if is_shebang(src, pos) or has_directive(src, pos + 1, conf_directives) then
      return last + 1, last, false, nil
    end
    return last + 1, pos - 1, true, nil
  elseif b == 34 or b == 39 then
    local p = pos + 1
    while p <= stop do
      local c = byte(src, p)
      if c == 92 then p = p + 2
      elseif c == b then return p + 1, p, false, nil
      elseif c == 10 then return p, p - 1, false, nil
      else p = p + 1 end
    end
    return stop + 1, stop, false, { q = b }
  end
  local nxt = find(src, "[#\"']", pos + 1)
  local last = (nxt and nxt <= stop) and (nxt - 1) or stop
  return last + 1, last, false, nil
end

local function strip_sh (src) return drive(step_sh, src) end
local function strip_hcl (src) return drive(step_hcl, src) end
local function strip_python (src) return drive(step_python, src) end
local function strip_yaml (src) return drive(step_yaml, src) end
local function strip_dockerfile (src) return drive(step_dockerfile, src) end
local function strip_unit (src) return drive(step_unit, src) end
local function strip_conf (src) return drive(step_conf, src) end

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

local function step_lua (src, pos, stop, st)
  if st then
    if st.kind == "str" then
      local q = st.q
      while pos <= stop do
        local c = byte(src, pos)
        if c == 92 then pos = pos + 2
        elseif c == q then return pos + 1, pos, false, nil
        elseif c == 10 then return pos + 1, pos, false, nil
        else pos = pos + 1 end
      end
      return stop + 1, stop, false, st
    else
      local level = st.level
      while pos <= stop do
        local e = long_bracket_close(src, pos, level)
        if e then return e, e - 1, false, nil end
        pos = pos + 1
      end
      return stop + 1, stop, false, st
    end
  end
  local b = byte(src, pos)
  if b == 45 and byte(src, pos + 1) == 45 then
    local cs = pos + 2
    local lvl, after = long_bracket_open(src, cs)
    if lvl then
      local p = after
      while p <= stop do
        local e = long_bracket_close(src, p, lvl)
        if e then return e, pos - 1, true, nil end
        p = p + 1
      end
      return stop + 1, pos - 1, true, { kind = "cmt" }
    end
    local txt = ws_after(src, cs)
    local rest = sub(src, txt)
    if find(rest, "^luacheck:") or find(rest, "^luacov:") then
      local nl = find(src, "\n", pos, true)
      local last = nl and (nl - 1) or stop
      if last > stop then last = stop end
      return last + 1, last, false, nil
    end
    local nl = find(src, "\n", cs, true)
    if nl and nl <= stop then
      return nl, pos - 1, true, nil
    end
    return stop + 1, pos - 1, true, nil
  elseif b == 34 or b == 39 then
    local np = pos + 1
    while np <= stop do
      local c = byte(src, np)
      if c == 92 then np = np + 2
      elseif c == b then return np + 1, np, false, nil
      elseif c == 10 then return np + 1, np, false, nil
      else np = np + 1 end
    end
    return stop + 1, stop, false, { kind = "str", q = b }
  elseif b == 91 then
    local lvl, after = long_bracket_open(src, pos)
    if lvl then
      local p = after
      while p <= stop do
        local e = long_bracket_close(src, p, lvl)
        if e then return e, e - 1, false, nil end
        p = p + 1
      end
      return stop + 1, stop, false, { kind = "long", level = lvl }
    end
    return pos + 1, pos, false, nil
  end
  local nxt = find(src, "[-\"'%[]", pos + 1)
  local last = (nxt and nxt <= stop) and (nxt - 1) or stop
  return last + 1, last, false, nil
end

local function step_c (src, pos, stop, st)
  if st then
    if st.kind == "str" then
      local q = st.q
      while pos <= stop do
        local c = byte(src, pos)
        if c == 92 then pos = pos + 2
        elseif c == q then return pos + 1, pos, false, nil
        else pos = pos + 1 end
      end
      return stop + 1, stop, false, st
    else
      while pos <= stop do
        if byte(src, pos) == 42 and byte(src, pos + 1) == 47 then
          return pos + 2, pos - 1, true, nil
        end
        pos = pos + 1
      end
      return stop + 1, pos - 1, true, st
    end
  end
  local b = byte(src, pos)
  if b == 47 and byte(src, pos + 1) == 47 then
    local start = pos
    local p = pos + 2
    while p <= stop do
      local c = byte(src, p)
      if c == 10 then break
      elseif c == 92 then
        if byte(src, p + 1) == 10 then p = p + 2
        elseif byte(src, p + 1) == 13 and byte(src, p + 2) == 10 then p = p + 3
        else p = p + 1 end
      else p = p + 1 end
    end
    if has_directive(src, start + 2, c_directives) then
      return p, p - 1, false, nil
    end
    return p, start - 1, true, nil
  elseif b == 47 and byte(src, pos + 1) == 42 then
    local start = pos
    local p = pos + 2
    while p <= stop do
      if byte(src, p) == 42 and byte(src, p + 1) == 47 then
        if has_directive(src, start + 2, c_directives) then
          return p + 2, p + 1, false, nil
        end
        return p + 2, start - 1, true, nil
      end
      p = p + 1
    end
    if has_directive(src, start + 2, c_directives) then
      return stop + 1, stop, false, nil
    end
    return stop + 1, start - 1, true, { kind = "cmt" }
  elseif b == 34 or b == 39 then
    local np = pos + 1
    while np <= stop do
      local c = byte(src, np)
      if c == 92 then np = np + 2
      elseif c == b then return np + 1, np, false, nil
      else np = np + 1 end
    end
    return stop + 1, stop, false, { kind = "str", q = b }
  end
  local nxt = find(src, "[/\"']", pos + 1)
  local last = (nxt and nxt <= stop) and (nxt - 1) or stop
  return last + 1, last, false, nil
end

local function step_js (src, pos, stop, st)
  local last = st and st.last or nil
  if st and st.kind == "str" then
    local q = st.q
    while pos <= stop do
      local c = byte(src, pos)
      if c == 92 then pos = pos + 2
      elseif c == q then return pos + 1, pos, false, { kind = "js", last = "\1" }
      else pos = pos + 1 end
    end
    return stop + 1, stop, false, st
  elseif st and st.kind == "tmpl" then
    local depth = st.depth or 0
    while pos <= stop do
      local c = byte(src, pos)
      if c == 92 then pos = pos + 2
      elseif c == 96 and depth == 0 then
        return pos + 1, pos, false, { kind = "js", last = "\1" }
      elseif c == 36 and byte(src, pos + 1) == 123 then depth = depth + 1; pos = pos + 2
      elseif c == 125 and depth > 0 then depth = depth - 1; pos = pos + 1
      else pos = pos + 1 end
    end
    return stop + 1, stop, false, { kind = "tmpl", depth = depth }
  elseif st and st.kind == "cmt" then
    while pos <= stop do
      if byte(src, pos) == 42 and byte(src, pos + 1) == 47 then
        return pos + 2, pos - 1, true, { kind = "js", last = "\1" }
      end
      pos = pos + 1
    end
    return stop + 1, pos - 1, true, st
  end
  local b = byte(src, pos)
  if b == 47 and byte(src, pos + 1) == 47 then
    local start = pos
    local p = pos + 2
    while p <= stop and byte(src, p) ~= 10 do p = p + 1 end
    if has_directive(src, start + 2, js_directives) then
      return p, p - 1, false, { kind = "js", last = nil }
    end
    return p, start - 1, true, { kind = "js", last = nil }
  elseif b == 47 and byte(src, pos + 1) == 42 then
    local start = pos
    local p = pos + 2
    while p <= stop do
      if byte(src, p) == 42 and byte(src, p + 1) == 47 then
        if has_directive(src, start + 2, js_directives) then
          return p + 2, p + 1, false, { kind = "js", last = "\1" }
        end
        return p + 2, start - 1, true, { kind = "js", last = "\1" }
      end
      p = p + 1
    end
    if has_directive(src, start + 2, js_directives) then
      return stop + 1, stop, false, { kind = "js", last = "\1" }
    end
    return stop + 1, start - 1, true, { kind = "cmt" }
  elseif b == 47 then
    if js_regex_allowed(last) then
      local p = pos + 1
      local in_class = false
      while p <= stop do
        local c = byte(src, p)
        if c == 92 then p = p + 2
        elseif c == 91 then in_class = true; p = p + 1
        elseif c == 93 then in_class = false; p = p + 1
        elseif c == 47 and not in_class then p = p + 1; break
        elseif c == 10 then break
        else p = p + 1 end
      end
      while p <= stop and is_ident_ch(byte(src, p)) do p = p + 1 end
      return p, p - 1, false, { kind = "js", last = "\1" }
    end
    return pos + 1, pos, false, { kind = "js", last = "/" }
  elseif b == 34 or b == 39 then
    local np = pos + 1
    while np <= stop do
      local c = byte(src, np)
      if c == 92 then np = np + 2
      elseif c == b then return np + 1, np, false, { kind = "js", last = "\1" }
      else np = np + 1 end
    end
    return stop + 1, stop, false, { kind = "str", q = b }
  elseif b == 96 then
    local np = pos + 1
    local depth = 0
    while np <= stop do
      local c = byte(src, np)
      if c == 92 then np = np + 2
      elseif c == 96 and depth == 0 then
        return np + 1, np, false, { kind = "js", last = "\1" }
      elseif c == 36 and byte(src, np + 1) == 123 then depth = depth + 1; np = np + 2
      elseif c == 125 and depth > 0 then depth = depth - 1; np = np + 1
      else np = np + 1 end
    end
    return stop + 1, stop, false, { kind = "tmpl", depth = depth }
  elseif is_ident_ch(b) then
    local np = pos
    while np <= stop and is_ident_ch(byte(src, np)) do np = np + 1 end
    return np, np - 1, false, { kind = "js", last = sub(src, pos, np - 1) }
  elseif b == 32 or b == 9 or b == 10 or b == 13 then
    local np = pos
    while np <= stop do
      local c = byte(src, np)
      if c == 32 or c == 9 or c == 10 or c == 13 then np = np + 1 else break end
    end
    return np, np - 1, false, { kind = "js", last = last }
  end
  return pos + 1, pos, false, { kind = "js", last = sub(src, pos, pos) }
end

local function step_css (src, pos, stop, st)
  if st then
    if st.kind == "str" then
      local q = st.q
      while pos <= stop do
        local c = byte(src, pos)
        if c == 92 then pos = pos + 2
        elseif c == q then return pos + 1, pos, false, nil
        elseif c == 10 then return pos + 1, pos, false, nil
        else pos = pos + 1 end
      end
      return stop + 1, stop, false, st
    end
    while pos <= stop do
      if byte(src, pos) == 42 and byte(src, pos + 1) == 47 then
        return pos + 2, pos - 1, true, nil
      end
      pos = pos + 1
    end
    return stop + 1, pos - 1, true, st
  end
  local b = byte(src, pos)
  if b == 47 and byte(src, pos + 1) == 42 then
    local p = pos + 2
    while p <= stop do
      if byte(src, p) == 42 and byte(src, p + 1) == 47 then
        return p + 2, pos - 1, true, nil
      end
      p = p + 1
    end
    return stop + 1, pos - 1, true, { kind = "cmt" }
  elseif b == 34 or b == 39 then
    local np = pos + 1
    while np <= stop do
      local c = byte(src, np)
      if c == 92 then np = np + 2
      elseif c == b then return np + 1, np, false, nil
      elseif c == 10 then return np + 1, np, false, nil
      else np = np + 1 end
    end
    return stop + 1, stop, false, { kind = "str", q = b }
  end
  local nxt = find(src, "[/\"']", pos + 1)
  local last = (nxt and nxt <= stop) and (nxt - 1) or stop
  return last + 1, last, false, nil
end

local function step_html (src, pos, stop, st)
  if byte(src, pos) == 60 and byte(src, pos + 1) == 33 and
     byte(src, pos + 2) == 45 and byte(src, pos + 3) == 45 then
    local p = pos + 4
    while p <= stop do
      if byte(src, p) == 45 and byte(src, p + 1) == 45 and byte(src, p + 2) == 62 then
        return p + 3, pos - 1, true, nil
      end
      p = p + 1
    end
    return stop + 1, pos - 1, true, { kind = "cmt" }
  end
  local nxt = find(src, "<", pos + 1, true)
  local last = (nxt and nxt <= stop) and (nxt - 1) or stop
  return last + 1, last, false, st
end

local steppers = {
  lua = step_lua,
  c = step_c, h = step_c, cpp = step_c, cc = step_c, hpp = step_c, m = step_c,
  java = step_c,
  js = step_js,
  css = step_css,
  conf = step_conf, env = step_conf,
  html = step_html, htm = step_html,
  sh = step_sh, bash = step_sh,
  tf = step_hcl, tfvars = step_hcl, hcl = step_hcl,
  py = step_python,
  yml = step_yaml, yaml = step_yaml,
  dockerfile = step_dockerfile,
  service = step_unit, timer = step_unit, socket = step_unit,
}

local function strip_template (src, output_lang)
  local out = {}
  local pos = 1
  local len = #src
  local step = steppers[output_lang]
  local st = nil
  while pos <= len do
    if byte(src, pos) == 60 and byte(src, pos + 1) == 37 then
      if st and st.kind == "cmt" then
        return src, true
      end
      local p = pos + 2
      local close = find(src, "%>", p, true)
      if not close then
        out[#out + 1] = sub(src, pos)
        pos = len + 1
      else
        local code = sub(src, p, close - 1)
        out[#out + 1] = "<%"
        out[#out + 1] = (strip_lua(code))
        out[#out + 1] = "%>"
        pos = close + 2
      end
    else
      local seg_end = find(src, "<%", pos, true)
      local seg_stop = seg_end and (seg_end - 1) or len
      if not step then
        out[#out + 1] = sub(src, pos, seg_stop)
        pos = seg_stop + 1
      else
        while pos <= seg_stop do
          local np, emit_end, stripped, nst, bail = step(src, pos, seg_stop, st)
          if bail then return src, true end
          if stripped then
            local nl = nlonly(sub(src, pos, np - 1))
            np = after_comment(src, np, out, #nl > 0)
            out[#out + 1] = nl
          elseif emit_end >= pos then
            out[#out + 1] = sub(src, pos, emit_end)
          end
          pos = np
          st = nst
        end
      end
    end
  end
  return guard(concat(out), src, false)
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

local function split_ext (filename)
  local base = filename:match("[^/\\]+$") or filename
  local tk = base:match("%.tk%.([%w]+)$")
  if tk then
    return true, tk:lower()
  end
  return false, base
end

local function lang_for (src, base)
  local nm = name_map[base]
  if nm then return nm end
  local ext = base:match("%.([%w]+)$")
  if ext then return ext:lower() end
  return shebang_lang(src)
end

local function coverage (src, filename)
  local is_tk, rest = split_ext(filename)
  if is_tk then return "checked" end
  local fn = ext_map[lang_for(src, rest)]
  if fn == false then return "ignored" end
  if fn == nil then return "unknown" end
  return "checked"
end

local function strip (src, filename)
  local is_tk, rest = split_ext(filename)
  local fn
  if is_tk then
    fn = function (s) return strip_template(s, rest) end
  else
    fn = ext_map[lang_for(src, rest)]
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
