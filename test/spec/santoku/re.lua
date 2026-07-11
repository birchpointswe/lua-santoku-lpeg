local test = require("santoku.test")
local re = require("santoku.re")

test("santoku.re", function ()

  test("serial: literal + classes", function ()
    assert(re.match("hello", "'hello'") == 6)      -- end position after match
    assert(re.match("hello world", "{%a+}") == "hello")
    assert(re.match("abc", "{}") == 1)             -- position capture
    assert(re.match("123abc", "%d+ {%a+}") == "abc")
  end)

  test("serial: literal transform survives", function ()
    assert(re.match("x", "'x' -> 'Y'") == "Y")     -- -> "str" value capture
  end)

  test("stripped syntax errors", function ()
    assert(not pcall(re.compile, "{%a+} => f"))    -- match-time capture gone
    assert(not pcall(re.compile, "{%a+} -> f"))    -- function transform gone
    assert(not pcall(re.compile, "%a+ ~> f"))      -- fold-with-fn gone
    assert(not pcall(re.compile, "%custom"))       -- user defs gone (%name only predef)
  end)

  test("check: parallel-tier acceptance", function ()
    assert(re.check("%a+") == true)                -- no captures
    assert(re.check("{}") == true)                 -- position
    assert(re.check("{: %a+ :}") == true)          -- anonymous group
    assert(re.check("{:word: %a+ :}") == true)     -- named group
  end)

  test("check: parallel-tier rejection", function ()
    local ok1, msg1 = re.check("{%a+}")            -- string (value) capture
    assert(ok1 == nil and type(msg1) == "string")
    local ok2, msg2 = re.check("'x' -> 'Y'")       -- value transform
    assert(ok2 == nil and type(msg2) == "string")
    local ok3, msg3 = re.check("{:g: %a :} =g")    -- back-ref = match-time
    assert(ok3 == nil and type(msg3) == "string")
  end)

  test("tags: dense ids by first appearance", function ()
    local t = re.tags("{:caps: %u+ :} / {:num: %d+ :}")
    assert(t.caps == 0 and t.num == 1)
    local none = re.tags("%a+")
    assert(next(none) == nil)
  end)

  test("pmatch: state-free NOLUA path", function ()
    local e = re.pmatch("%a+", "hello123")
    assert(e == 5)                                 -- matched [0,5)
    assert(re.pmatch("%d+", "hello") == nil)       -- no match
    assert(re.pmatch("%d+", "ab12", 3) == 4)       -- init=3 -> [2,4)
    local e2, nc = re.pmatch("{:w: %a+ :}", "abc")
    assert(e2 == 3 and nc and nc >= 1)             -- group produces captures
  end)

end)
