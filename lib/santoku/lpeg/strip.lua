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

local function strip_conf (src)
  local out = {}
  local pos = 1
  local len = #src
  while pos <= len do
    local b = byte(src, pos)
    if b == 35 then
      while pos <= len and byte(src, pos) ~= 10 do
        pos = pos + 1
      end
      pos = after_comment(src, pos, out, false)
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

local ext_map = {
  lua = strip_lua,
  c = strip_c, h = strip_c, cpp = strip_c, cc = strip_c, hpp = strip_c, m = strip_c,
  js = strip_js,
  css = strip_css,
  html = strip_html, htm = strip_html,
  conf = strip_conf,
  json = false,
}

local function nlonly (s)
  return (s:gsub("[^\n]", ""))
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

local function step_conf (src, pos, stop, _st)
  local b = byte(src, pos)
  if b == 35 then
    local nl = find(src, "\n", pos, true)
    if nl and nl <= stop then return nl, pos - 1, true, nil end
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
  end
  local nxt = find(src, "[#\"']", pos + 1)
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
  js = step_js,
  css = step_css,
  conf = step_conf,
  html = step_html, htm = step_html,
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
          local np, emit_end, stripped, nst = step(src, pos, seg_stop, st)
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

local function split_ext (filename)
  local base = filename:match("[^/\\]+$") or filename
  local tk = base:match("%.tk%.([%w]+)$")
  if tk then
    return true, tk:lower()
  end
  local ext = base:match("%.([%w]+)$")
  return false, ext and ext:lower() or nil
end

local function strip (src, filename)
  local is_tk, ext = split_ext(filename)
  if is_tk then
    return strip_template(src, ext)
  end
  local fn = ext_map[ext]
  if fn == nil or fn == false then
    return src, false
  end
  return fn(src)
end

return {
  strip = strip,
  strip_lua = strip_lua,
  strip_c = strip_c,
  strip_js = strip_js,
  strip_css = strip_css,
  strip_conf = strip_conf,
  strip_html = strip_html,
  strip_template = strip_template,
}
