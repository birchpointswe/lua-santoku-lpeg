local lpeg = require("santoku.re.core")
local arr = require("santoku.array")
local str = require("santoku.string")
local co_factory = require("santoku.co")
local P, S, R, C, Cc, Cp, Ct, V = lpeg.P, lpeg.S, lpeg.R, lpeg.C, lpeg.Cc, lpeg.Cp, lpeg.Ct, lpeg.V
local match = lpeg.match

local ws = S(" \t\n\r") ^ 0
local esc = P("\\") * P(1)
local str_inner = (esc + (1 - S("\"\\")) ^ 1) ^ 0
local jstr = P("\"") * str_inner * P("\"")

local jnum = P("-") ^ -1 *
  (P("0") + R("19") * R("09") ^ 0) *
  (P(".") * R("09") ^ 1) ^ -1 *
  (S("eE") * S("+-") ^ -1 * R("09") ^ 1) ^ -1

local jval = P({
  "val",
  val = ws * (
    P("{") * ws * (V("pair") * (ws * P(",") * ws * V("pair")) ^ 0) ^ -1 * ws * P("}") +
    P("[") * ws * (V("val") * (ws * P(",") * ws * V("val")) ^ 0) ^ -1 * ws * P("]") +
    jstr + jnum + P("true") + P("false") + P("null")
  ) * ws
  ,
  pair = jstr * ws * P(":") * V("val")
})

local key_cap = P("\"") * C(str_inner) * P("\"") * Cp()
local str_pos = P("\"") * Cp() * str_inner * Cp() * P("\"") * Cp()
local val_end = jval * Cp()

local function json_fields(input, fields)
  local co = co_factory()
  local fset = {}
  for i = 1, #fields do
    fset[fields[i]] = true
  end
  return co.wrap(function ()
    local pos = match(ws * P("{") * Cp(), input)
    if not pos then return end
    while true do
      pos = match(ws * Cp(), input, pos)
      if not pos then return end
      local ch = str.sub(input, pos, pos)
      if ch == "}" then return end
      if ch == "," then
        pos = pos + 1
        pos = match(ws * Cp(), input, pos)
        if not pos then return end
      end
      local key, kend = match(key_cap, input, pos)
      if not key then return end
      pos = match(ws * P(":") * ws * Cp(), input, kend)
      if not pos then return end
      if fset[key] then
        local ch2 = str.sub(input, pos, pos)
        if ch2 == "\"" then
          local s, e, npos = match(str_pos, input, pos)
          if not s then return end
          if e > s then co.yield(s, e - 1) end
          pos = npos
        elseif ch2 == "[" then
          pos = pos + 1
          while true do
            pos = match(ws * Cp(), input, pos)
            if not pos then return end
            local ac = str.sub(input, pos, pos)
            if ac == "]" then pos = pos + 1; break end
            if ac == "," then
              pos = pos + 1
            elseif ac == "\"" then
              local s, e, npos = match(str_pos, input, pos)
              if not s then return end
              if e > s then co.yield(s, e - 1) end
              pos = npos
            else
              local npos = match(val_end, input, pos)
              if not npos then return end
              pos = npos
            end
          end
        else
          local npos = match(val_end, input, pos)
          if not npos then return end
          pos = npos
        end
      else
        local npos = match(val_end, input, pos)
        if not npos then return end
        pos = npos
      end
    end
  end)
end

local function ci(s)
  local p = P(true)
  for i = 1, #s do
    local c = str.sub(s, i, i)
    p = p * S(str.lower(c) .. str.upper(c))
  end
  return p
end

local squoted = P("'") * (1 - P("'")) ^ 0 * P("'")
local dquoted = P("\"") * (1 - P("\"")) ^ 0 * P("\"")
local tag_body = (squoted + dquoted + (1 - P(">"))) ^ 0 * P(">")
local comment = P("<!--") * (1 - P("-->")) ^ 0 * P("-->")

local function block_elem(name)
  local open = P("<") * ci(name) * #S(" \t\n\r/>") * tag_body
  local close = P("</") * ci(name) * ws * P(">")
  return open * (1 - close) ^ 0 * close
end

local script = block_elem("script")
local style = block_elem("style")

local comment_cp, script_cp, style_cp, any_tag_cp, tag_name_only, block_elems

local function html_text(input)
  local co = co_factory()
  return co.wrap(function ()
    local buf = {}
    local pos = 1
    local len = #input
    while pos <= len do
      if str.byte(input, pos) == 60 then
        local npos = match(comment_cp, input, pos)
          or match(script_cp, input, pos)
          or match(style_cp, input, pos)
        if npos then
          if #buf > 0 then
            local text = arr.concat(buf)
            buf = {}
            if #text > 0 then co.yield(text) end
          end
          pos = npos
        else
          local tname = match(tag_name_only, input, pos)
          if tname and block_elems[str.lower(tname)] then
            if #buf > 0 then
              local text = arr.concat(buf)
              buf = {}
              if #text > 0 then co.yield(text) end
            end
          end
          npos = match(any_tag_cp, input, pos)
          if npos then
            pos = npos
          else
            buf[#buf + 1] = "<"
            pos = pos + 1
          end
        end
      else
        local next_lt = str.find(input, "<", pos, true)
        local text_end = next_lt and (next_lt - 1) or len
        buf[#buf + 1] = str.sub(input, pos, text_end)
        pos = text_end + 1
      end
    end
    if #buf > 0 then
      local text = arr.concat(buf)
      if #text > 0 then co.yield(text) end
    end
  end)
end

local tag_name_ch = R("az", "AZ") + R("09") + S("-_:")
local tag_name_cap = C(tag_name_ch ^ 1)
local attr_key_patt = (1 - S(" \t\n\r=/>")) ^ 1
local attr_dqv = P("\"") * C((1 - P("\"")) ^ 0) * P("\"")
local attr_sqv = P("'") * C((1 - P("'")) ^ 0) * P("'")
local attr_uqv = C((1 - S(" \t\n\r>\"'")) ^ 1)
local attr_kv = C(attr_key_patt) * ws * P("=") * ws * (attr_dqv + attr_sqv + attr_uqv)
local attr_bare = C((1 - S(" \t\n\r=/>\"'")) ^ 1) * Cc(true)
local attrs_raw = Ct((ws * (attr_kv + attr_bare)) ^ 0)

local close_tag_cap = P("</") * ws * tag_name_cap * ws * P(">") * Cp()
local open_tag_cap = P("<") * tag_name_cap * attrs_raw * ws * (
  P("/") * ws * P(">") * Cp() * Cc(true) +
  P(">") * Cp() * Cc(false)
)

comment_cp = comment * Cp()
script_cp = script * Cp()
style_cp = style * Cp()
any_tag_cp = P("<") * tag_body * Cp()

local void_elems = {
  area = true, base = true, br = true, col = true, embed = true,
  hr = true, img = true, input = true, link = true, meta = true,
  source = true, track = true, wbr = true,
}

block_elems = {
  address = true, article = true, aside = true, blockquote = true,
  br = true, dd = true, details = true, div = true,
  dl = true, dt = true, fieldset = true, figcaption = true,
  figure = true, footer = true, form = true,
  h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
  header = true, hr = true, li = true, main = true,
  nav = true, ol = true, p = true, pre = true,
  section = true, summary = true, table = true,
  tbody = true, td = true, tfoot = true, th = true, thead = true, tr = true,
  ul = true,
}

tag_name_only = P("<") * P("/") ^ -1 * C(tag_name_ch ^ 1)

local function html_extract(input)
  local parts = {}
  local tags = {}
  local stack = {}
  local spos = 0
  local pos = 1
  local len = #input
  while pos <= len do
    if str.byte(input, pos) == 60 then
      local npos = match(comment_cp, input, pos)
        or match(script_cp, input, pos)
        or match(style_cp, input, pos)
      if npos then
        pos = npos
      else
        local cname, cend = match(close_tag_cap, input, pos)
        if cname then
          local lname = str.lower(cname)
          for i = #stack, 1, -1 do
            if stack[i].lname == lname then
              stack[i].e = spos
              stack[i].close_s = pos
              stack[i].close_e = cend - 1
              stack[i].lname = nil
              tags[#tags + 1] = stack[i]
              arr.remove(stack, i, i)
              break
            end
          end
          pos = cend
        else
          local tname, raw, oend, is_self = match(open_tag_cap, input, pos)
          if tname then
            if not is_self and not void_elems[str.lower(tname)] then
              local attrs = {}
              for j = 1, #raw, 2 do
                attrs[raw[j]] = raw[j + 1]
              end
              stack[#stack + 1] = {
                name = tname,
                lname = str.lower(tname),
                attrs = attrs,
                s = spos + 1,
                open_s = pos,
                open_e = oend - 1,
              }
            end
            pos = oend
          else
            npos = match(any_tag_cp, input, pos)
            if npos then
              pos = npos
            else
              parts[#parts + 1] = "<"
              spos = spos + 1
              pos = pos + 1
            end
          end
        end
      end
    else
      local next_lt = str.find(input, "<", pos, true)
      local text_end = next_lt and (next_lt - 1) or len
      parts[#parts + 1] = str.sub(input, pos, text_end)
      spos = spos + (text_end - pos + 1)
      pos = text_end + 1
    end
  end
  arr.sort(tags, function(a, b) return a.open_s < b.open_s end)
  return arr.concat(parts), tags
end

local function html_tags(input)
  local _, tags = html_extract(input)
  local i = 0
  return function ()
    i = i + 1
    local t = tags[i]
    if t then
      return t.name, t.attrs, t.open_s, t.open_e, t.close_s, t.close_e
    end
  end
end

local function html_inject(text, tags, attr_order)
  local sorted = {}
  for i = 1, #tags do sorted[i] = tags[i] end
  arr.sort(sorted, function(a, b) return a.s < b.s end)
  local parts = {}
  local pos = 1
  for i = 1, #sorted do
    local t = sorted[i]
    if t.s > pos then
      parts[#parts + 1] = str.sub(text, pos, t.s - 1)
    end
    parts[#parts + 1] = "<" .. t.name
    if t.attrs then
      local function emit(k)
        local v = t.attrs[k]
        if v == nil then return end
        if v == true then
          parts[#parts + 1] = " " .. k
        else
          parts[#parts + 1] = " " .. k .. "=\"" .. (str.gsub(v, "\"", "&quot;")) .. "\""
        end
      end
      if attr_order then
        local seen = {}
        for _, k in ipairs(attr_order) do
          emit(k)
          seen[k] = true
        end
        for k in pairs(t.attrs) do
          if not seen[k] then emit(k) end
        end
      else
        for k in pairs(t.attrs) do emit(k) end
      end
    end
    parts[#parts + 1] = ">"
    parts[#parts + 1] = t.text or str.sub(text, t.s, t.e)
    parts[#parts + 1] = "</" .. t.name .. ">"
    pos = t.e + 1
  end
  if pos <= #text then
    parts[#parts + 1] = str.sub(text, pos)
  end
  return arr.concat(parts)
end

local function html_spans(tags)
  local pvec = require("santoku.pvec")
  local spans = pvec.create()
  for i = 1, #tags do
    spans:push(tags[i].s - 1, tags[i].e)
  end
  return spans
end

local function html_match_tags(ids, starts, ends, names, prefix)
  local tags = {}
  for i = 0, ids:size() - 1 do
    local cls = names and names[ids:get(i)] or tostring(ids:get(i))
    if prefix then cls = prefix .. cls end
    tags[#tags + 1] = {
      name = "span",
      s = starts:get(i) + 1,
      e = ends:get(i),
      attrs = { class = cls },
    }
  end
  return tags
end

local style_open_cap = Cp() * P("<") * ci("style") * tag_body * Cp()
local style_close_cap = Cp() * P("</") * ci("style") * ws * P(">") * Cp()
local script_open_cap = Cp() * P("<") * ci("script") * attrs_raw * ws * P(">") * Cp()
local script_close_cap = Cp() * P("</") * ci("script") * ws * P(">") * Cp()
local script_self_cap = Cp() * P("<") * ci("script") * attrs_raw * ws * P("/") * ws * P(">") * Cp()

local function scan_close(patt, html, from)
  local s = from
  while s do
    local a, b = match(patt, html, s)
    if a then return a, b end
    s = str.find(html, "<", s + 1, true)
  end
end

local function component_parts(html)
  local deps = {}
  local style_content = ""
  local init = ""
  local destroy = ""
  local ranges = {}
  local pos = 1
  local len = #html
  while pos <= len do
    local lt = str.find(html, "<", pos, true)
    if not lt then break end
    local sc_start, sc_raw, sc_inner = match(script_open_cap, html, lt)
    local sc_self_start, sc_self_raw, sc_self_end = match(script_self_cap, html, lt)
    local st_start, st_inner = match(style_open_cap, html, lt)
    local picks = {}
    if sc_start then picks[#picks + 1] = { sc_start, "script" } end
    if sc_self_start then picks[#picks + 1] = { sc_self_start, "script_self" } end
    if st_start then picks[#picks + 1] = { st_start, "style" } end
    if #picks == 0 then pos = lt + 1 else
    arr.sort(picks, function (a, b) return a[1] < b[1] end)
    local pick = picks[1]
    if pick[2] == "script_self" then
      local attrs = {}
      for j = 1, #sc_self_raw, 2 do
        attrs[sc_self_raw[j]] = sc_self_raw[j + 1]
      end
      if attrs.src then
        deps[#deps + 1] = attrs.src
      end
      ranges[#ranges + 1] = { sc_self_start, sc_self_end - 1 }
      pos = sc_self_end
    elseif pick[2] == "script" then
      local attrs = {}
      for j = 1, #sc_raw, 2 do
        attrs[sc_raw[j]] = sc_raw[j + 1]
      end
      local close_start, close_end = scan_close(script_close_cap, html, sc_inner)
      if not close_start then break end
      if attrs.src then
        deps[#deps + 1] = attrs.src
      elseif attrs.type == "destroy" then
        destroy = str.sub(html, sc_inner, close_start - 1)
      else
        init = str.sub(html, sc_inner, close_start - 1)
      end
      ranges[#ranges + 1] = { sc_start, close_end - 1 }
      pos = close_end
    elseif pick[2] == "style" then
      local close_start, close_end = scan_close(style_close_cap, html, st_inner)
      if not close_start then break end
      style_content = str.sub(html, st_inner, close_start - 1)
      ranges[#ranges + 1] = { st_start, close_end - 1 }
      pos = close_end
    end end
  end
  arr.sort(ranges, function (a, b) return a[1] < b[1] end)
  local body_parts = {}
  local bp = 1
  for i = 1, #ranges do
    if ranges[i][1] > bp then
      body_parts[#body_parts + 1] = str.sub(html, bp, ranges[i][1] - 1)
    end
    bp = ranges[i][2] + 1
  end
  if bp <= len then
    body_parts[#body_parts + 1] = str.sub(html, bp)
  end
  local body = str.match(arr.concat(body_parts), "^%s*(.-)%s*$") or ""
  return {
    deps = deps,
    style = style_content,
    init = init,
    destroy = destroy,
    body = body,
  }
end

local function minify_html(html)
  local pre_cp = block_elem("pre") * Cp()
  local textarea_cp = block_elem("textarea") * Cp()
  local parts = {}
  local pos = 1
  local len = #html
  while pos <= len do
    if str.byte(html, pos) == 60 then
      local npos = match(comment_cp, html, pos)
      if npos then
        pos = npos
      else
        npos = match(pre_cp, html, pos)
          or match(textarea_cp, html, pos)
          or match(script_cp, html, pos)
          or match(style_cp, html, pos)
        if npos then
          parts[#parts + 1] = str.sub(html, pos, npos - 1)
          pos = npos
        else
          local tag_end = match(any_tag_cp, html, pos)
          if tag_end then
            parts[#parts + 1] = str.sub(html, pos, tag_end - 1)
            pos = tag_end
          else
            parts[#parts + 1] = "<"
            pos = pos + 1
          end
        end
      end
    else
      local next_lt = str.find(html, "<", pos, true)
      local text_end = next_lt and (next_lt - 1) or len
      local text = str.gsub(str.sub(html, pos, text_end), "%s+", " ")
      if text ~= " " then
        parts[#parts + 1] = text
      end
      pos = text_end + 1
    end
  end
  local result = arr.concat(parts)
  return str.match(result, "^%s*(.-)%s*$") or ""
end

local function transform_inline(html, transforms)
  if not transforms then return html end
  local js_fn = transforms.js
  local css_fn = transforms.css
  if not js_fn and not css_fn then return html end
  local replacements = {}
  local pos = 1
  local len = #html
  while pos <= len do
    local lt = str.find(html, "<", pos, true)
    if not lt then break end
    local handled = false
    if js_fn then
      local sc_start, sc_raw, sc_inner = match(script_open_cap, html, lt)
      if sc_start then
        local attrs = {}
        for j = 1, #sc_raw, 2 do
          attrs[sc_raw[j]] = sc_raw[j + 1]
        end
        if not attrs.src then
          local close_start, close_end = scan_close(script_close_cap, html, sc_inner)
          if close_start then
            replacements[#replacements + 1] = { sc_inner, close_start - 1, js_fn(str.sub(html, sc_inner, close_start - 1)) }
            pos = close_end
            handled = true
          end
        end
      end
    end
    if not handled and css_fn then
      local st_start, st_inner = match(style_open_cap, html, lt)
      if st_start then
        local close_start, close_end = scan_close(style_close_cap, html, st_inner)
        if close_start then
          replacements[#replacements + 1] = { st_inner, close_start - 1, css_fn(str.sub(html, st_inner, close_start - 1)) }
          pos = close_end
          handled = true
        end
      end
    end
    if not handled then
      pos = lt + 1
    end
  end
  if #replacements == 0 then return html end
  local parts = {}
  local bp = 1
  for i = 1, #replacements do
    local r = replacements[i]
    parts[#parts + 1] = str.sub(html, bp, r[1] - 1)
    parts[#parts + 1] = r[3]
    bp = r[2] + 1
  end
  parts[#parts + 1] = str.sub(html, bp)
  return arr.concat(parts)
end

local csv_dq = P("\"")
local csv_field_q = csv_dq * C(((1 - csv_dq) + (csv_dq * csv_dq)) ^ 0) * csv_dq
  / function (s) return (str.gsub(s, "\"\"", "\"")) end
local csv_field_u = C((1 - S(",\r\n")) ^ 0)
local csv_field = csv_field_q + csv_field_u
local csv_record = Ct(csv_field * (P(",") * csv_field) ^ 0)
local csv_nl = P("\r\n") + P("\n") + P("\r")
local csv_doc = Ct(csv_record * (csv_nl * csv_record) ^ 0) * csv_nl ^ -1

local function csv (input)
  if str.sub(input, 1, 3) == "\239\187\191" then input = str.sub(input, 4) end
  local rows = match(csv_doc, input)
  if not rows then return {} end
  local out = {}
  for i = 1, #rows do
    local r = rows[i]
    if not (#r == 1 and r[1] == "") then
      out[#out + 1] = r
    end
  end
  return out
end

return {
  json_fields = json_fields,
  html_text = html_text,
  html_extract = html_extract,
  html_tags = html_tags,
  html_inject = html_inject,
  html_spans = html_spans,
  html_match_tags = html_match_tags,
  component_parts = component_parts,
  minify_html = minify_html,
  transform_inline = transform_inline,
  csv = csv,
}
