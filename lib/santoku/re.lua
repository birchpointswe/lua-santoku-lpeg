-- santoku.re: the public re-string interface over the vendored, stripped lpeg
-- core. compile/match/find/gsub are the serial tier (full pure-data captures);
-- check/tags/pmatch reach the state-free parallel tier used by native drivers.
--
-- The lpeg combinator API is intentionally not exported here; santoku.lpeg
-- keeps it for utility code. Only the re grammar (no function/match-time
-- captures, no user definitions table) is public.

local core = require("santoku.re.core")
local grammar = require("santoku.re.grammar")

local M = {}

M.compile = grammar.compile
M.match = grammar.match
M.find = grammar.find
M.gsub = grammar.gsub

-- Validate a pattern for the parallel tier: ok, or (nil, message). Rejects
-- match-time and value captures.
function M.check (p)
  return core._check(grammar.compile(p))
end

-- Named-group -> dense tag id map for the parallel tier.
function M.tags (p)
  return core._tags(grammar.compile(p))
end

-- Run the state-free matcher from Lua (mirrors the native tk_re_match path):
-- returns the 0-based end offset and capture count, or nil on no match.
function M.pmatch (p, s, i)
  return core._pmatch(grammar.compile(p), s, i)
end

return M
