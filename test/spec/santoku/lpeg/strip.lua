local test = require("santoku.test")
local strip = require("santoku.lpeg.strip")

local function is_subseq (out, src)
  local oi, si = 1, 1
  while oi <= #out do
    if si > #src then return false end
    if out:sub(oi, oi) == src:sub(si, si) then oi = oi + 1 end
    si = si + 1
  end
  return true
end

test("strip_lua", function ()

  test("removes decorative line comment", function ()
    local out, bailed = strip.strip_lua("local x = 1 -- foo\nreturn x\n")
    assert(not bailed)
    assert(out == "local x = 1 \nreturn x\n")
    assert(is_subseq(out, "local x = 1 -- foo\nreturn x\n"))
  end)

  test("preserves luacheck directive", function ()
    local src = "local unpack = unpack -- luacheck: ignore\n"
    local out = strip.strip_lua(src)
    assert(out == src)
  end)

  test("preserves luacov directive", function ()
    local src = "x = 1 -- luacov: disable\n"
    assert(strip.strip_lua(src) == src)
  end)

  test("comment markers inside short strings preserved", function ()
    local src = "local s = \"-- not a comment\"\n"
    assert(strip.strip_lua(src) == src)
  end)

  test("single-quote string with escapes preserved", function ()
    local src = "local s = 'a \\' -- b'\n"
    assert(strip.strip_lua(src) == src)
  end)

  test("comment markers inside long strings preserved", function ()
    local src = "local s = [[ -- not a comment ]]\n"
    assert(strip.strip_lua(src) == src)
  end)

  test("leveled long string preserved with nested brackets", function ()
    local src = "local s = [==[ ]] -- inside ]==]\n"
    assert(strip.strip_lua(src) == src)
  end)

  test("removes leveled long comment", function ()
    local out = strip.strip_lua("a --[==[ x ]] y ]==] b\n")
    assert(out == "a  b\n")
  end)

  test("removes basic long comment", function ()
    local out = strip.strip_lua("a --[[ x ]] b\n")
    assert(out == "a  b\n")
  end)

  test("empty if stays intact", function ()
    local src = "if x then end\n"
    assert(strip.strip_lua(src) == src)
  end)

end)

test("strip_c", function ()

  test("removes line and block comments", function ()
    local out = strip.strip_c("int x; // hi\nint y; /* z */\n")
    assert(out == "int x; \nint y; \n")
  end)

  test("markers inside strings preserved", function ()
    local src = "char *s = \"// not /* a */ comment\";\n"
    assert(strip.strip_c(src) == src)
  end)

  test("markers inside char literals preserved", function ()
    local src = "char c = '/';\n"
    assert(strip.strip_c(src) == src)
  end)

  test("backslash-newline continues line comment", function ()
    local out = strip.strip_c("a // one \\\ntwo\nb\n")
    assert(out == "a \nb\n")
  end)

  test("block comment spanning lines keeps newlines", function ()
    local out = strip.strip_c("a /* one\ntwo */ b\n")
    assert(out == "a \n b\n")
  end)

  test("NOLINT preserved", function ()
    local src = "int x; // NOLINT(foo)\n"
    assert(strip.strip_c(src) == src)
  end)

  test("clang-format preserved", function ()
    local src = "x; /* clang-format off */\n"
    assert(strip.strip_c(src) == src)
  end)

end)

test("strip_js", function ()

  test("regex literal not a comment", function ()
    local src = "var r = /ab\\/c/g;\n"
    assert(strip.strip_js(src) == src)
  end)

  test("regex starting with star not a block comment", function ()
    local src = "var r = /*/;\n"
    assert(strip.strip_js(src) == src)
  end)

  test("division then line comment", function ()
    local out = strip.strip_js("var x = a / b // c\n")
    assert(out == "var x = a / b \n")
  end)

  test("backtick template preserved", function ()
    local src = "var t = `x ${ a/b } // still string`;\n"
    assert(strip.strip_js(src) == src)
  end)

  test("block comment removed", function ()
    local out = strip.strip_js("a /* z */ b\n")
    assert(out == "a  b\n")
  end)

  test("comment markers inside string preserved", function ()
    local src = "var s = \"// not a comment\";\n"
    assert(strip.strip_js(src) == src)
  end)

  test("regex after return", function ()
    local src = "return /x/.test(y);\n"
    assert(strip.strip_js(src) == src)
  end)

  test("ts directive comment preserved", function ()
    local src = "x; // @ts-ignore\n"
    assert(strip.strip_js(src) == src)
  end)

end)

test("strip_css", function ()

  test("removes block comment", function ()
    local out = strip.strip_css(".a { color: red } /* c */\n")
    assert(out == ".a { color: red } \n")
  end)

  test("comment in string preserved", function ()
    local src = ".a { content: \"/* not a comment */\" }\n"
    assert(strip.strip_css(src) == src)
  end)

end)

test("strip_conf", function ()

  test("removes hash comment", function ()
    local out = strip.strip_conf("listen 80; # comment\nserver_name x;\n")
    assert(out == "listen 80; \nserver_name x;\n")
  end)

  test("hash in string preserved", function ()
    local src = "add_header X \"# not a comment\";\n"
    assert(strip.strip_conf(src) == src)
  end)

end)

test("strip_html", function ()

  test("removes comment keeps text and tags", function ()
    local out = strip.strip_html("<div>a<!-- c -->b</div>")
    assert(out == "<div>ab</div>")
  end)

  test("multiline comment keeps newlines", function ()
    local out = strip.strip_html("<p>x<!-- one\ntwo -->y</p>")
    assert(out == "<p>x\ny</p>")
  end)

end)

test("strip_template", function ()

  test("lua long string spanning code block", function ()
    local src = "local s = [[ <% return readfile(\"x.js\"), false %> ]]\n"
    local out, bailed = strip.strip_template(src, "lua")
    assert(not bailed)
    assert(out == src)
    assert(is_subseq(out, src))
  end)

  test("lua comment in code stripped but percent-gt survives", function ()
    local out = strip.strip_template("<% foo() -- done %>", "lua")
    assert(out == "<% foo() %>")
  end)

  test("multiline long string across code keeps inner dashes", function ()
    local src = "x = [[\nline -- keep\n<% y() %>\nmore -- keep\n]]\n"
    local out = strip.strip_template(src, "lua")
    assert(out == src)
    assert(is_subseq(out, src))
  end)

  test("literal lua comment outside code stripped", function ()
    local out = strip.strip_template("a -- gone\n<% z() %>\n", "lua")
    assert(out == "a \n<% z() %>\n")
  end)

  test("c template strips literal and code comments", function ()
    local src = "int x; // gone\n<% foo() -- also gone %>\nchar *s = \"//keep\";\n"
    local out, bailed = strip.strip_template(src, "c")
    assert(not bailed)
    assert(out == "int x; \n<% foo() %>\nchar *s = \"//keep\";\n")
    assert(is_subseq(out, src))
  end)

  test("html template strips html and lua comments", function ()
    local src = "<div><!-- gone --><% bar() -- gone %></div>"
    local out, bailed = strip.strip_template(src, "html")
    assert(not bailed)
    assert(out == "<div><% bar() %></div>")
    assert(is_subseq(out, src))
  end)

  test("conf template mostly one code block", function ()
    local src = "<%\n  local x = 1 -- gone\n  return y\n%>\n"
    local out = strip.strip_template(src, "conf")
    assert(out == "<%\n  local x = 1 \n  return y\n%>\n")
    assert(is_subseq(out, src))
  end)

  test("code block containing double quote and comment", function ()
    local out = strip.strip_template("<% x(\"a %> b\") %>", "lua")
    assert(is_subseq(out, "<% x(\"a %> b\") %>"))
  end)

  test("percent-gt inside output string is fine", function ()
    local src = "<% a() %> text <% b() %>"
    local out = strip.strip_template(src, "lua")
    assert(out == src)
  end)

end)

test("strip dispatcher", function ()

  test("routes lua", function ()
    assert(strip.strip("x = 1 -- c\n", "foo.lua") == "x = 1 \n")
  end)

  test("routes c and h", function ()
    assert(strip.strip("a; // c\n", "foo.c") == "a; \n")
    assert(strip.strip("a; // c\n", "foo.h") == "a; \n")
  end)

  test("routes js", function ()
    assert(strip.strip("a; // c\n", "foo.js") == "a; \n")
  end)

  test("routes css", function ()
    assert(strip.strip("a{} /* c */\n", "foo.css") == "a{} \n")
  end)

  test("routes html", function ()
    assert(strip.strip("<b>x</b><!-- c -->", "foo.html") == "<b>x</b>")
  end)

  test("routes conf", function ()
    assert(strip.strip("a; # c\n", "foo.conf") == "a; \n")
  end)

  test("json is no-op", function ()
    local src = "{\"a\": 1}\n"
    assert(strip.strip(src, "foo.json") == src)
  end)

  test("unknown is no-op", function ()
    local src = "whatever -- c\n"
    assert(strip.strip(src, "foo.xyz") == src)
  end)

  test("tk lua routes to template", function ()
    local src = "local s = [[ <% x() -- c %> ]]\n"
    assert(strip.strip(src, "foo.tk.lua") == "local s = [[ <% x() %> ]]\n")
  end)

  test("tk c routes to template with c output", function ()
    local src = "int x; // c\n<% y() %>\n"
    assert(strip.strip(src, "foo.tk.c") == "int x; \n<% y() %>\n")
  end)

  test("tk html routes to template with html output", function ()
    local src = "<!-- c --><% z() %>"
    assert(strip.strip(src, "foo.tk.html") == "<% z() %>")
  end)

  test("tk json strips only lua code", function ()
    local src = "{ <% k() -- c %> }"
    assert(strip.strip(src, "foo.tk.json") == "{ <% k() %> }")
  end)

  test("path with directories", function ()
    assert(strip.strip("x -- c\n", "a/b/foo.lua") == "x \n")
  end)

end)

test("subsequence safety on corpus shapes", function ()

  test("component.tk.lua shape is subsequence", function ()
    local src = "local skeleton = [[ <% return readfile(\"res/web/component.js\"), false %> ]]\n"
    local out = strip.strip(src, "component.tk.lua")
    assert(is_subseq(out, src))
  end)

end)
