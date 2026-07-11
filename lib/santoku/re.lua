







local core = require("santoku.re.core")
local grammar = require("santoku.re.grammar")

local M = {}

M.compile = grammar.compile
M.match = grammar.match
M.find = grammar.find
M.gsub = grammar.gsub



function M.check (p)
  return core._check(grammar.compile(p))
end


function M.tags (p)
  return core._tags(grammar.compile(p))
end



function M.pmatch (p, s, i)
  return core._pmatch(grammar.compile(p), s, i)
end

return M
