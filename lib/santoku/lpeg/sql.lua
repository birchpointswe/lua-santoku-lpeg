local lpeg = require("santoku.re.core")
local str = require("santoku.string")
local arr = require("santoku.array")

local P, S, R, C, Cp, V = lpeg.P, lpeg.S, lpeg.R, lpeg.C, lpeg.Cp, lpeg.V
local lmatch = lpeg.match
local sub = str.sub
local lower = str.lower
local upper = str.upper
local concat = arr.concat

local M = {}

M.IDENT_PAT = "^[%a_][%w_]*$"

M.PRAGMAS = {
  table_info = true,
  table_xinfo = true,
  index_list = true,
  index_info = true,
  integrity_check = true,
  quick_check = true,
}

local E_TXN = "transactions are not supported; statements run atomically one at a time"
local E_ATTACH = "ATTACH is not supported"
local E_TRIGGER = "triggers are not supported; they would fire during sync apply"
local E_FK = "foreign keys are not supported; REFERENCES conflicts with sync conflict resolution"
local E_STRICT = "STRICT tables are not supported"
local E_AUTOINC = "AUTOINCREMENT is not supported; INTEGER PRIMARY KEY already auto-assigns"
local E_RENAME = "RENAME is not supported; create a new table and INSERT ... SELECT"
local E_VACINTO = "VACUUM INTO is not supported"
local E_VIRTUAL = "virtual tables are not supported"
local E_TEMP = "TEMP objects are not supported; use CTEs"
local E_QUOTED = "quoted identifiers are not supported; names must match [A-Za-z_][A-Za-z0-9_]*"
local E_SCHEMA = "schema-qualified names are not supported"
local E_PK = "a PRIMARY KEY is required"
local E_STMT = "unrecognized or unsupported statement"
local E_TRAIL = "unexpected trailing content"
local E_CTAS = "CREATE TABLE AS is not supported; create the table, then INSERT ... SELECT"

local function check_with (fn, name)
  if not fn then return true end
  local ok, err = fn(name)
  if not ok then return nil, err or (name .. " is not allowed") end
  return true
end

local ident_ch = R("az", "AZ", "09") + P("_")
local ws1 = S(" \t\r\n")
local line_comment = P("--") * (1 - P("\n")) ^ 0
local block_comment = P("/*") * (1 - P("*/")) ^ 0 * P("*/")
local sp = (ws1 + line_comment + block_comment) ^ 0

local sqstr = P("'") * (P("''") + (1 - P("'"))) ^ 0 * P("'")
local dqtok = P("\"") * (P("\"\"") + (1 - P("\""))) ^ 0 * P("\"")
local brtok = P("[") * (1 - P("]")) ^ 0 * P("]")
local bttok = P("`") * (P("``") + (1 - P("`"))) ^ 0 * P("`")
local anystr = sqstr + dqtok + brtok + bttok

local balanced = P({ P("(") *
  (anystr + line_comment + block_comment + V(1) + (1 - S("()"))) ^ 0 * P(")") })

local digits = R("09") ^ 1
local number = S("+-") ^ -1 * (
  (P("0") * S("xX") * (R("09") + R("af") + R("AF")) ^ 1) +
  (digits * (P(".") * R("09") ^ 0) ^ -1 + P(".") * digits) *
  (S("eE") * S("+-") ^ -1 * digits) ^ -1)

local kw_cache = {}

local function K (w)
  local p = kw_cache[w]
  if p then return p end
  p = P(true)
  for i = 1, #w do
    local c = sub(w, i, i)
    p = p * S(lower(c) .. upper(c))
  end
  p = p * -ident_ch
  kw_cache[w] = p
  return p
end

local bare = C((R("az", "AZ") + P("_")) * ident_ch ^ 0)

local function skip (s, pos)
  return lmatch(sp * Cp(), s, pos) or pos
end

local function at_kw (s, pos, w)
  return lmatch(K(w) * sp * Cp(), s, pos)
end

local function at_pat (s, pos, pat)
  return lmatch(pat * sp * Cp(), s, pos)
end

local function at_end (s, pos)
  pos = lmatch((sp * P(";")) ^ 0 * sp * Cp(), s, pos) or pos
  return pos > #s
end

local function take_ident (s, pos)
  if lmatch(dqtok + brtok + bttok, s, pos) then
    return nil, nil, E_QUOTED
  end
  local name, np = lmatch(bare * sp * Cp(), s, pos)
  if not name then
    return nil, nil, E_STMT
  end
  if sub(s, np, np) == "." then
    return nil, nil, E_SCHEMA
  end
  return name, np
end

local RESERVED_TYPE = {}
for _, w in ipairs({
  "primary", "not", "null", "unique", "check", "default", "collate",
  "references", "generated", "as", "constraint", "on",
}) do
  RESERVED_TYPE[w] = true
end

local function take_type (s, pos)
  local words = {}
  while true do
    local w, np = lmatch(bare * sp * Cp(), s, pos)
    if not w or RESERVED_TYPE[lower(w)] then break end
    words[#words + 1] = w
    pos = np
  end
  if #words == 0 then return nil, pos end
  local np = at_pat(s, pos, P("(") * sp * number * (sp * P(",") * sp * number) ^ -1 * sp * P(")"))
  if np then pos = np end
  return concat(words, " "), pos
end

local function skip_conflict (s, pos)
  local np = at_kw(s, pos, "on")
  if not np then return pos end
  np = at_kw(s, np, "conflict")
  if not np then return pos end
  for _, w in ipairs({ "rollback", "abort", "fail", "ignore", "replace" }) do
    local ep = at_kw(s, np, w)
    if ep then return ep end
  end
  return pos
end

local dtoken = S("+-") ^ -1 * ident_ch ^ 1 * (P(".") * ident_ch ^ 0) ^ -1

local function take_default (s, pos)
  local np = at_pat(s, pos, balanced)
  if np then return np end
  np = at_pat(s, pos, sqstr + number + dtoken)
  return np
end

local function parse_colconstraints (s, pos, col)
  while true do
    local np = at_kw(s, pos, "constraint")
    if np then
      local _, ip, ierr = take_ident(s, np)
      if not ip then return nil, ierr end
      pos = ip
    end
    np = at_kw(s, pos, "primary")
    if np then
      np = at_kw(s, np, "key")
      if not np then return nil, E_STMT end
      local dp = at_kw(s, np, "asc") or at_kw(s, np, "desc")
      if dp then np = dp end
      np = skip_conflict(s, np)
      if at_kw(s, np, "autoincrement") then return nil, E_AUTOINC end
      col.pk = true
      pos = np
    elseif at_kw(s, pos, "references") then
      return nil, E_FK
    elseif at_kw(s, pos, "not") then
      np = at_kw(s, pos, "not")
      np = at_kw(s, np, "null")
      if not np then return nil, E_STMT end
      col.notnull = true
      pos = skip_conflict(s, np)
    elseif at_kw(s, pos, "null") then
      pos = skip_conflict(s, at_kw(s, pos, "null"))
    elseif at_kw(s, pos, "unique") then
      col.unique = true
      pos = skip_conflict(s, at_kw(s, pos, "unique"))
    elseif at_kw(s, pos, "check") then
      np = at_pat(s, at_kw(s, pos, "check"), balanced)
      if not np then return nil, E_STMT end
      col.checked = true
      pos = np
    elseif at_kw(s, pos, "default") then
      np = take_default(s, at_kw(s, pos, "default"))
      if not np then return nil, E_STMT end
      col.defaulted = true
      pos = np
    elseif at_kw(s, pos, "collate") then
      local _, ip, ierr = take_ident(s, at_kw(s, pos, "collate"))
      if not ip then return nil, ierr end
      pos = ip
    elseif at_kw(s, pos, "generated") or at_kw(s, pos, "as") then
      np = at_kw(s, pos, "generated")
      if np then
        np = at_kw(s, np, "always")
        if not np then return nil, E_STMT end
        np = at_kw(s, np, "as")
        if not np then return nil, E_STMT end
      else
        np = at_kw(s, pos, "as")
      end
      np = at_pat(s, np, balanced)
      if not np then return nil, E_STMT end
      local mp = at_kw(s, np, "stored") or at_kw(s, np, "virtual")
      if mp then np = mp end
      col.generated = true
      pos = np
    else
      return pos
    end
  end
end

local function parse_idxcols (s, pos)
  local names = {}
  local np = at_pat(s, pos, P("("))
  if not np then return nil, nil, E_STMT end
  pos = np
  while true do
    local name, ip, ierr = take_ident(s, pos)
    if not name then return nil, nil, ierr end
    names[#names + 1] = name
    pos = ip
    np = at_kw(s, pos, "collate")
    if np then
      local _, cp, cerr = take_ident(s, np)
      if not cp then return nil, nil, cerr end
      pos = cp
    end
    np = at_kw(s, pos, "asc") or at_kw(s, pos, "desc")
    if np then pos = np end
    if at_kw(s, pos, "autoincrement") then return nil, nil, E_AUTOINC end
    np = at_pat(s, pos, P(","))
    if np then
      pos = np
    else
      np = at_pat(s, pos, P(")"))
      if not np then return nil, nil, E_STMT end
      return names, np
    end
  end
end

local function parse_create_table (s, pos, opts)
  local np = at_kw(s, pos, "if")
  local if_not_exists = false
  if np then
    np = at_kw(s, np, "not")
    np = np and at_kw(s, np, "exists")
    if not np then return nil, E_STMT end
    if_not_exists = true
    pos = np
  end
  local name, ip, ierr = take_ident(s, pos)
  if not name then return nil, ierr end
  pos = ip
  local cok, cerr0 = check_with(opts and opts.check_table, name)
  if not cok then return nil, cerr0 end
  if at_kw(s, pos, "as") then return nil, E_CTAS end
  np = at_pat(s, pos, P("("))
  if not np then return nil, E_STMT end
  pos = np
  local columns = {}
  local table_pk = nil
  while true do
    np = at_kw(s, pos, "constraint")
    if np then
      local _, cp, cerr = take_ident(s, np)
      if not cp then return nil, cerr end
      pos = cp
    end
    if at_kw(s, pos, "primary") then
      np = at_kw(s, at_kw(s, pos, "primary"), "key")
      if not np then return nil, E_STMT end
      local names, ep, perr = parse_idxcols(s, np)
      if not names then return nil, perr end
      table_pk = names
      pos = skip_conflict(s, ep)
    elseif at_kw(s, pos, "unique") then
      local names, ep, perr = parse_idxcols(s, at_kw(s, pos, "unique"))
      if not names then return nil, perr end
      pos = skip_conflict(s, ep)
    elseif at_kw(s, pos, "check") then
      np = at_pat(s, at_kw(s, pos, "check"), balanced)
      if not np then return nil, E_STMT end
      pos = np
    elseif at_kw(s, pos, "foreign") then
      return nil, E_FK
    else
      local cname, cp, cerr = take_ident(s, pos)
      if not cname then return nil, cerr end
      local colok, colerr = check_with(opts and opts.check_column, cname)
      if not colok then return nil, colerr end
      pos = cp
      local col = { name = cname }
      local ctype
      ctype, pos = take_type(s, pos)
      col.type = ctype
      local rp, rerr = parse_colconstraints(s, pos, col)
      if not rp then return nil, rerr end
      pos = rp
      columns[#columns + 1] = col
    end
    np = at_pat(s, pos, P(","))
    if np then
      pos = np
    else
      np = at_pat(s, pos, P(")"))
      if not np then return nil, E_STMT end
      pos = np
      break
    end
  end
  local without_rowid = false
  while true do
    np = at_kw(s, pos, "without")
    if np then
      np = at_kw(s, np, "rowid")
      if not np then return nil, E_STMT end
      without_rowid = true
      pos = np
    elseif at_kw(s, pos, "strict") then
      return nil, E_STRICT
    else
      break
    end
    np = at_pat(s, pos, P(","))
    if np then pos = np else break end
  end
  if not at_end(s, pos) then return nil, E_TRAIL end
  local pk = table_pk
  if not pk then
    pk = {}
    for i = 1, #columns do
      if columns[i].pk then pk[#pk + 1] = columns[i].name end
    end
  end
  if #pk == 0 then return nil, E_PK end
  local colnames = {}
  for i = 1, #columns do colnames[columns[i].name] = true end
  for i = 1, #pk do
    if not colnames[pk[i]] then return nil, E_STMT end
  end
  return {
    kind = "create_table",
    name = name,
    if_not_exists = if_not_exists,
    without_rowid = without_rowid,
    columns = columns,
    pk = pk,
  }
end

local function parse_create_view (s, pos, opts)
  local np = at_kw(s, pos, "if")
  local if_not_exists = false
  if np then
    np = at_kw(s, np, "not")
    np = np and at_kw(s, np, "exists")
    if not np then return nil, E_STMT end
    if_not_exists = true
    pos = np
  end
  local name, ip, ierr = take_ident(s, pos)
  if not name then return nil, ierr end
  pos = ip
  local vok, verr = check_with(opts and opts.check_table, name)
  if not vok then return nil, verr end
  local cols = nil
  if at_pat(s, pos, P("(")) then
    local names, ep, perr = parse_idxcols(s, pos)
    if not names then return nil, perr end
    cols = names
    pos = ep
    for i = 1, #cols do
      local colok, colerr = check_with(opts and opts.check_column, cols[i])
      if not colok then return nil, colerr end
    end
  end
  np = at_kw(s, pos, "as")
  if not np then return nil, E_STMT end
  pos = np
  if not (at_kw(s, pos, "select") or at_kw(s, pos, "with") or at_kw(s, pos, "values")) then
    return nil, E_STMT
  end
  return { kind = "create_view", name = name, if_not_exists = if_not_exists, columns = cols }
end

local function parse_create_index (s, pos, opts, unique)
  local np = at_kw(s, pos, "if")
  local if_not_exists = false
  if np then
    np = at_kw(s, np, "not")
    np = np and at_kw(s, np, "exists")
    if not np then return nil, E_STMT end
    if_not_exists = true
    pos = np
  end
  local name, ip, ierr = take_ident(s, pos)
  if not name then return nil, ierr end
  pos = ip
  local iok, ierr2 = check_with(opts and opts.check_table, name)
  if not iok then return nil, ierr2 end
  np = at_kw(s, pos, "on")
  if not np then return nil, E_STMT end
  local tname, tp, terr = take_ident(s, np)
  if not tname then return nil, terr end
  local tok, terr2 = check_with(opts and opts.check_table, tname)
  if not tok then return nil, terr2 end
  pos = tp
  np = at_pat(s, pos, balanced)
  if not np then return nil, E_STMT end
  pos = np
  np = at_kw(s, pos, "where")
  if not np and not at_end(s, pos) then return nil, E_TRAIL end
  return {
    kind = "create_index",
    name = name,
    table = tname,
    unique = unique or false,
    if_not_exists = if_not_exists,
  }
end

local function parse_drop (s, pos, opts)
  local kind
  local np = at_kw(s, pos, "table")
  if np then kind = "drop_table" pos = np
  else
    np = at_kw(s, pos, "view")
    if np then kind = "drop_view" pos = np
    else
      np = at_kw(s, pos, "index")
      if np then kind = "drop_index" pos = np
      else
        if at_kw(s, pos, "trigger") then return nil, E_TRIGGER end
        return nil, E_STMT
      end
    end
  end
  local if_exists = false
  np = at_kw(s, pos, "if")
  if np then
    np = at_kw(s, np, "exists")
    if not np then return nil, E_STMT end
    if_exists = true
    pos = np
  end
  local name, ip, ierr = take_ident(s, pos)
  if not name then return nil, ierr end
  local dok, derr = check_with(opts and opts.check_table, name)
  if not dok then return nil, derr end
  if not at_end(s, ip) then return nil, E_TRAIL end
  return { kind = kind, name = name, if_exists = if_exists }
end

local function parse_alter (s, pos, opts)
  local np = at_kw(s, pos, "table")
  if not np then return nil, E_STMT end
  local tname, tp, terr = take_ident(s, np)
  if not tname then return nil, terr end
  local aok, aerr = check_with(opts and opts.check_table, tname)
  if not aok then return nil, aerr end
  pos = tp
  if at_kw(s, pos, "rename") then return nil, E_RENAME end
  np = at_kw(s, pos, "add")
  if np then
    local cp = at_kw(s, np, "column")
    if cp then np = cp end
    local cname, ip, ierr = take_ident(s, np)
    if not cname then return nil, ierr end
    local colok, colerr = check_with(opts and opts.check_column, cname)
    if not colok then return nil, colerr end
    pos = ip
    local col = { name = cname }
    local ctype
    ctype, pos = take_type(s, pos)
    col.type = ctype
    local rp, rerr = parse_colconstraints(s, pos, col)
    if not rp then return nil, rerr end
    if not at_end(s, rp) then return nil, E_TRAIL end
    if col.pk then return nil, E_STMT end
    return { kind = "alter_add_column", table = tname, column = col }
  end
  np = at_kw(s, pos, "drop")
  if np then
    local cp = at_kw(s, np, "column")
    if cp then np = cp end
    local cname, ip, ierr = take_ident(s, np)
    if not cname then return nil, ierr end
    local colok, colerr = check_with(opts and opts.check_column, cname)
    if not colok then return nil, colerr end
    if not at_end(s, ip) then return nil, E_TRAIL end
    return { kind = "alter_drop_column", table = tname, column = cname }
  end
  return nil, E_STMT
end

local function parse_pragma (s, pos, opts)
  local name, ip, ierr = take_ident(s, pos)
  if not name then return nil, ierr end
  pos = ip
  local allowed = (opts and opts.pragmas) or M.PRAGMAS
  if not allowed[lower(name)] then
    return nil, "pragma " .. name .. " is not allowed"
  end
  local np = at_pat(s, pos, P("=") * sp * (sqstr + number + dtoken))
    or at_pat(s, pos, balanced)
  if np then pos = np end
  if not at_end(s, pos) then return nil, E_TRAIL end
  return { kind = "pragma", name = lower(name) }
end

local function skip_with (s, pos)
  local np = at_kw(s, pos, "recursive")
  if np then pos = np end
  while true do
    local qp = at_pat(s, pos, dqtok + brtok + bttok)
    if qp then
      pos = qp
    else
      local _, ip, ierr = take_ident(s, pos)
      if not ip then return nil, ierr end
      pos = ip
    end
    local cp = at_pat(s, pos, balanced)
    if cp then pos = cp end
    np = at_kw(s, pos, "as")
    if not np then return nil, E_STMT end
    pos = np
    local mp = at_kw(s, pos, "materialized")
    if not mp then
      local tp = at_kw(s, pos, "not")
      if tp then
        mp = at_kw(s, tp, "materialized")
        if not mp then return nil, E_STMT end
      end
    end
    if mp then pos = mp end
    np = at_pat(s, pos, balanced)
    if not np then return nil, E_STMT end
    pos = np
    np = at_pat(s, pos, P(","))
    if np then pos = np else return pos end
  end
end

local parse

local function parse_create (s, pos, opts)
  if at_kw(s, pos, "temp") or at_kw(s, pos, "temporary") then return nil, E_TEMP end
  if at_kw(s, pos, "trigger") then return nil, E_TRIGGER end
  if at_kw(s, pos, "virtual") then return nil, E_VIRTUAL end
  local np = at_kw(s, pos, "unique")
  if np then
    np = at_kw(s, np, "index")
    if not np then return nil, E_STMT end
    return parse_create_index(s, np, opts, true)
  end
  np = at_kw(s, pos, "index")
  if np then return parse_create_index(s, np, opts, false) end
  np = at_kw(s, pos, "table")
  if np then return parse_create_table(s, np, opts) end
  np = at_kw(s, pos, "view")
  if np then return parse_create_view(s, np, opts) end
  return nil, E_STMT
end

parse = function (s, opts)
  if type(s) ~= "string" then return nil, E_STMT end
  local pos = skip(s, 1)
  if pos > #s then return nil, E_STMT end
  local np = at_kw(s, pos, "explain")
  if np then
    local qp = at_kw(s, np, "query")
    if qp then
      qp = at_kw(s, qp, "plan")
      if not qp then return nil, E_STMT end
      np = qp
    end
    local inner, err = parse(sub(s, np), opts)
    if not inner then return nil, err end
    return { kind = "explain", inner = inner }
  end
  for _, w in ipairs({ "begin", "commit", "end", "rollback", "savepoint", "release" }) do
    if at_kw(s, pos, w) then return nil, E_TXN end
  end
  if at_kw(s, pos, "attach") or at_kw(s, pos, "detach") then return nil, E_ATTACH end
  if at_kw(s, pos, "select") or at_kw(s, pos, "values") then return { kind = "select" } end
  if at_kw(s, pos, "insert") or at_kw(s, pos, "replace") then return { kind = "insert" } end
  if at_kw(s, pos, "update") then return { kind = "update" } end
  if at_kw(s, pos, "delete") then return { kind = "delete" } end
  np = at_kw(s, pos, "with")
  if np then
    local ep, werr = skip_with(s, np)
    if not ep then return nil, werr end
    if at_kw(s, ep, "select") or at_kw(s, ep, "values") then return { kind = "select" } end
    if at_kw(s, ep, "insert") or at_kw(s, ep, "replace") then return { kind = "insert" } end
    if at_kw(s, ep, "update") then return { kind = "update" } end
    if at_kw(s, ep, "delete") then return { kind = "delete" } end
    return nil, E_STMT
  end
  np = at_kw(s, pos, "create")
  if np then return parse_create(s, np, opts) end
  np = at_kw(s, pos, "drop")
  if np then return parse_drop(s, np, opts) end
  np = at_kw(s, pos, "alter")
  if np then return parse_alter(s, np, opts) end
  np = at_kw(s, pos, "pragma")
  if np then return parse_pragma(s, np, opts) end
  np = at_kw(s, pos, "vacuum")
  if np then
    if at_kw(s, np, "into") then return nil, E_VACINTO end
    if not at_end(s, np) then
      local _, ip = take_ident(s, np)
      if ip and at_kw(s, ip, "into") then return nil, E_VACINTO end
      return nil, E_TRAIL
    end
    return { kind = "vacuum" }
  end
  np = at_kw(s, pos, "analyze")
  if np then
    if not at_end(s, np) then return nil, E_TRAIL end
    return { kind = "analyze" }
  end
  np = at_kw(s, pos, "reindex")
  if np then
    if not at_end(s, np) then return nil, E_TRAIL end
    return { kind = "reindex" }
  end
  return nil, E_STMT
end

M.parse = parse

return M
