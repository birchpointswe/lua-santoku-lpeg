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
    assert(out == "local x = 1\nreturn x\n")
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

  test("leaves no trailing whitespace where comment was", function ()
    local src = "local x = 1  \t -- foo\n"
    local out = strip.strip_lua(src)
    assert(out == "local x = 1\n")
    assert(is_subseq(out, src))
  end)

  test("full line comment is deleted, not blanked", function ()
    local out = strip.strip_lua("a = 1\n  \t-- foo\nb = 2\n")
    assert(out == "a = 1\nb = 2\n")
  end)

  test("comment at end of file without newline", function ()
    assert(strip.strip_lua("a = 1 -- foo") == "a = 1")
  end)

  test("pre-existing trailing whitespace untouched", function ()
    local src = "x = 1  \ny = 2\t\n"
    assert(strip.strip_lua(src) == src)
  end)

  test("trailing whitespace inside long string preserved", function ()
    local src = "local s = [[a  \nb  ]] -- c\n"
    assert(strip.strip_lua(src) == "local s = [[a  \nb  ]]\n")
  end)

  test("trailing whitespace inside short string preserved", function ()
    local src = "local s = \"a  \" -- c\n"
    assert(strip.strip_lua(src) == "local s = \"a  \"\n")
  end)

  test("inline long comment keeps token separation", function ()
    assert(strip.strip_lua("local a --[[ c ]] b\n") == "local a  b\n")
  end)

  test("long comment ending a line trims both sides", function ()
    assert(strip.strip_lua("local a = 1 --[[ c ]]  \nb\n") == "local a = 1\nb\n")
  end)

  test("multiline long comment trims what precedes it", function ()
    assert(strip.strip_lua("a = 1  --[[x\ny]]\n") == "a = 1\n")
  end)

  test("directive comment keeps its leading whitespace", function ()
    local src = "local x = 1  -- luacheck: ignore\n"
    assert(strip.strip_lua(src) == src)
  end)

end)

test("strip_c", function ()

  test("removes line and block comments", function ()
    local out = strip.strip_c("int x; // hi\nint y; /* z */\n")
    assert(out == "int x;\nint y;\n")
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
    assert(out == "a\nb\n")
  end)

  test("inline block comment spanning lines joins them", function ()
    local out = strip.strip_c("a /* one\ntwo */ b\n")
    assert(out == "a  b\n")
  end)

  test("NOLINT preserved", function ()
    local src = "int x; // NOLINT(foo)\n"
    assert(strip.strip_c(src) == src)
  end)

  test("clang-format preserved", function ()
    local src = "x; /* clang-format off */\n"
    assert(strip.strip_c(src) == src)
  end)

  test("leaves no trailing whitespace where comment was", function ()
    local src = "int x;  \t // hi\n"
    local out = strip.strip_c(src)
    assert(out == "int x;\n")
    assert(is_subseq(out, src))
  end)

  test("indented line comment is deleted", function ()
    assert(strip.strip_c("a;\n  // c\nb;\n") == "a;\nb;\n")
  end)

  test("indented block comment is deleted", function ()
    assert(strip.strip_c("a;\n  /* c */  \nb;\n") == "a;\nb;\n")
  end)

  test("inline block comment keeps token separation", function ()
    assert(strip.strip_c("int a; /* c */ int b;\n") == "int a;  int b;\n")
  end)

  test("trailing whitespace inside string preserved", function ()
    local src = "char *s = \"a  \"; // c\n"
    assert(strip.strip_c(src) == "char *s = \"a  \";\n")
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
    assert(out == "var x = a / b\n")
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

  test("leaves no trailing whitespace where comment was", function ()
    assert(strip.strip_js("var x = 1;  \t // c\n") == "var x = 1;\n")
  end)

  test("indented comment is deleted", function ()
    assert(strip.strip_js("a;\n  // c\nb;\n") == "a;\nb;\n")
  end)

  test("trailing whitespace inside template literal preserved", function ()
    local src = "var t = `a  \nb  `; // c\n"
    assert(strip.strip_js(src) == "var t = `a  \nb  `;\n")
  end)

  test("trailing whitespace inside regex preserved", function ()
    local src = "var r = /a  /; // c\n"
    assert(strip.strip_js(src) == "var r = /a  /;\n")
  end)

end)

test("strip_css", function ()

  test("removes block comment", function ()
    local out = strip.strip_css(".a { color: red } /* c */\n")
    assert(out == ".a { color: red }\n")
  end)

  test("comment in string preserved", function ()
    local src = ".a { content: \"/* not a comment */\" }\n"
    assert(strip.strip_css(src) == src)
  end)

  test("indented comment is deleted", function ()
    assert(strip.strip_css(".a{}\n  /* c */\n.b{}\n") == ".a{}\n.b{}\n")
  end)

  test("inline comment keeps token separation", function ()
    assert(strip.strip_css(".a /* c */ .b {}\n") == ".a  .b {}\n")
  end)

  test("trailing whitespace inside string preserved", function ()
    local src = ".a { content: \"x  \" } /* c */\n"
    assert(strip.strip_css(src) == ".a { content: \"x  \" }\n")
  end)

end)

test("strip_conf", function ()

  test("removes hash comment", function ()
    local out = strip.strip_conf("listen 80; # comment\nserver_name x;\n")
    assert(out == "listen 80;\nserver_name x;\n")
  end)

  test("hash in string preserved", function ()
    local src = "add_header X \"# not a comment\";\n"
    assert(strip.strip_conf(src) == src)
  end)

  test("indented comment is deleted", function ()
    assert(strip.strip_conf("a;\n  # c\nb;\n") == "a;\nb;\n")
  end)

  test("trailing whitespace inside string preserved", function ()
    local src = "add_header X \"a  \"; # c\n"
    assert(strip.strip_conf(src) == "add_header X \"a  \";\n")
  end)

end)

test("strip_html", function ()

  test("removes comment keeps text and tags", function ()
    local out = strip.strip_html("<div>a<!-- c -->b</div>")
    assert(out == "<div>ab</div>")
  end)

  test("inline multiline comment joins the lines", function ()
    local out = strip.strip_html("<p>x<!-- one\ntwo -->y</p>")
    assert(out == "<p>xy</p>")
  end)

  test("indented comment is deleted", function ()
    assert(strip.strip_html("<p>x</p>\n  <!-- c -->  \n<p>y</p>") == "<p>x</p>\n<p>y</p>")
  end)

  test("inline comment keeps surrounding text spacing", function ()
    assert(strip.strip_html("<p>a <!-- c --> b</p>") == "<p>a  b</p>")
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
    assert(out == "<% foo()%>")
  end)

  test("multiline long string across code keeps inner dashes", function ()
    local src = "x = [[\nline -- keep\n<% y() %>\nmore -- keep\n]]\n"
    local out = strip.strip_template(src, "lua")
    assert(out == src)
    assert(is_subseq(out, src))
  end)

  test("literal lua comment outside code stripped", function ()
    local out = strip.strip_template("a -- gone\n<% z() %>\n", "lua")
    assert(out == "a\n<% z() %>\n")
  end)

  test("c template strips literal and code comments", function ()
    local src = "int x; // gone\n<% foo() -- also gone %>\nchar *s = \"//keep\";\n"
    local out, bailed = strip.strip_template(src, "c")
    assert(not bailed)
    assert(out == "int x;\n<% foo()%>\nchar *s = \"//keep\";\n")
    assert(is_subseq(out, src))
  end)

  test("html template strips html and lua comments", function ()
    local src = "<div><!-- gone --><% bar() -- gone %></div>"
    local out, bailed = strip.strip_template(src, "html")
    assert(not bailed)
    assert(out == "<div><% bar()%></div>")
    assert(is_subseq(out, src))
  end)

  test("conf template mostly one code block", function ()
    local src = "<%\n  local x = 1 -- gone\n  return y\n%>\n"
    local out = strip.strip_template(src, "conf")
    assert(out == "<%\n  local x = 1\n  return y\n%>\n")
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

  test("literal comment leaves no trailing whitespace", function ()
    local src = "int x;  // gone\n<% y() %>\n"
    local out = strip.strip_template(src, "c")
    assert(out == "int x;\n<% y() %>\n")
    assert(is_subseq(out, src))
  end)

  test("indented literal comment is deleted", function ()
    local out = strip.strip_template("a;\n  // gone\n<% y() %>\n", "c")
    assert(out == "a;\n<% y() %>\n")
  end)

  test("output long string trailing whitespace preserved across code", function ()
    local src = "x = [[  \n<% y() %>  \n]] -- gone\n"
    local out = strip.strip_template(src, "lua")
    assert(out == "x = [[  \n<% y() %>  \n]]\n")
    assert(is_subseq(out, src))
  end)

  test("multiline literal block comment trims what precedes it", function ()
    local src = "a;  /* one\ntwo */\nb;\n"
    local out = strip.strip_template(src, "c")
    assert(out == "a;\nb;\n")
    assert(is_subseq(out, src))
  end)

end)

test("strip_sh", function ()

  test("shebang preserved", function ()
    local src = "#!/bin/bash\necho hi\n"
    assert(strip.strip_sh(src) == src)
  end)

  test("removes decorative comment", function ()
    local out = strip.strip_sh("#!/bin/sh\n# gone\necho a # also gone\n")
    assert(out == "#!/bin/sh\necho a\n")
  end)

  test("shellcheck directive preserved", function ()
    local src = "# shellcheck disable=SC2086\nfoo $bar\n"
    assert(strip.strip_sh(src) == src)
  end)

  test("hash in parameter expansion not a comment", function ()
    local src = "code=\"${status#* }\"\nn=$#\n"
    assert(strip.strip_sh(src) == src)
  end)

  test("hash mid-word not a comment", function ()
    local src = "[[ \"$key\" =~ ^# ]] && continue\n"
    assert(strip.strip_sh(src) == src)
  end)

  test("shebang inside a string preserved", function ()
    local src = "printf '%s' \"#!/bin/bash\"\n"
    assert(strip.strip_sh(src) == src)
  end)

  test("hash inside single quotes preserved", function ()
    local src = "grep '# keep me' f\n"
    assert(strip.strip_sh(src) == src)
  end)

  test("heredoc body is opaque", function ()
    local src = "cat <<EOF\n# not a comment\n#!/bin/sh\nEOF\n# gone\n"
    assert(strip.strip_sh(src) == "cat <<EOF\n# not a comment\n#!/bin/sh\nEOF\n")
  end)

  test("dash heredoc allows tab-indented terminator", function ()
    local src = "cat <<-EOF\n\t# keep\n\tEOF\n"
    assert(strip.strip_sh(src) == src)
  end)

  test("quoted heredoc delimiter", function ()
    local src = "cat > f << 'CONF'\n# keep\nCONF\n"
    assert(strip.strip_sh(src) == src)
  end)

  test("two heredocs queued on one line", function ()
    local src = "cmd <<A <<B\n# a\nA\n# b\nB\n"
    assert(strip.strip_sh(src) == src)
  end)

  test("herestring is not a heredoc", function ()
    local out = strip.strip_sh("cmd <<< \"$x\"\n# gone\n")
    assert(out == "cmd <<< \"$x\"\n")
  end)

  test("arithmetic left shift is not a heredoc", function ()
    local out = strip.strip_sh("x=$(( a << b ))\n# gone\n")
    assert(out == "x=$(( a << b ))\n")
  end)

  test("unterminated heredoc bails", function ()
    local out, bailed = strip.strip_sh("cat <<EOF\n# keep\n")
    assert(bailed)
    assert(out == "cat <<EOF\n# keep\n")
  end)

  test("comment after semicolon is left alone", function ()
    local src = "a;#b\n"
    assert(strip.strip_sh(src) == src)
  end)

end)

test("strip_hcl", function ()

  test("removes hash slash and block comments", function ()
    local out = strip.strip_hcl("a = 1 # x\nb = 2 // y\nc = 3 /* z */\n")
    assert(out == "a = 1\nb = 2\nc = 3\n")
  end)

  test("hash inside string preserved", function ()
    local src = "default = \"ami#0f5\"\n"
    assert(strip.strip_hcl(src) == src)
  end)

  test("trailing comment after string removed", function ()
    local out = strip.strip_hcl("default = \"ami-0f5\" # Debian 12 ARM\n")
    assert(out == "default = \"ami-0f5\"\n")
  end)

  test("cloud-init heredoc is opaque", function ()
    local src = "user_data = <<-EOF\n#cloud-config\n      #!/bin/bash\n      # keep\nEOF\n"
    assert(strip.strip_hcl(src) == src)
  end)

  test("comment before heredoc still removed", function ()
    local out = strip.strip_hcl("# gone\nx = <<EOF\n# keep\nEOF\n")
    assert(out == "x = <<EOF\n# keep\nEOF\n")
  end)

  test("multiline block comment on its own lines is deleted", function ()
    assert(strip.strip_hcl("a\n/* one\ntwo */\nb\n") == "a\nb\n")
  end)

  test("single quote is not a string delimiter", function ()
    local src = "x = \"it's\" # gone\n"
    assert(strip.strip_hcl(src) == "x = \"it's\"\n")
  end)

end)

test("strip_python", function ()

  test("shebang and coding line preserved", function ()
    local src = "#!/usr/bin/env python3\n# -*- coding: utf-8 -*-\nx = 1\n"
    assert(strip.strip_python(src) == src)
  end)

  test("removes comment", function ()
    assert(strip.strip_python("x = 1  # gone\n") == "x = 1\n")
  end)

  test("noqa and type directives preserved", function ()
    local src = "import os  # noqa: F401\nx = []  # type: list\n"
    assert(strip.strip_python(src) == src)
  end)

  test("hash inside string preserved", function ()
    local src = "s = \"# not a comment\"\nt = '#either'\n"
    assert(strip.strip_python(src) == src)
  end)

  test("docstring is not a comment", function ()
    local src = "def f():\n    \"\"\"Doc # with hash.\"\"\"\n    return 1\n"
    assert(strip.strip_python(src) == src)
  end)

  test("triple quoted string spanning lines preserved", function ()
    local src = "s = '''\n# keep\n'''  # gone\n"
    assert(strip.strip_python(src) == "s = '''\n# keep\n'''\n")
  end)

  test("f-string brace content preserved", function ()
    local src = "s = f\"{a}#{b}\"\n"
    assert(strip.strip_python(src) == src)
  end)

end)

test("strip_yaml", function ()

  test("removes comment", function ()
    local out = strip.strip_yaml("dbs:\n  # gone\n  retention: 720h  # also gone\n")
    assert(out == "dbs:\n  retention: 720h\n")
  end)

  test("cloud-config directive preserved", function ()
    local src = "#cloud-config\nusers:\n  - default\n"
    assert(strip.strip_yaml(src) == src)
  end)

  test("yaml-language-server directive preserved", function ()
    local src = "# yaml-language-server: $schema=x.json\na: 1\n"
    assert(strip.strip_yaml(src) == src)
  end)

  test("hash without leading space is not a comment", function ()
    local src = "url: http://example.com/x#frag\n"
    assert(strip.strip_yaml(src) == src)
  end)

  test("hash inside quotes preserved", function ()
    local src = "a: \"# no\"\nb: '# no'\n"
    assert(strip.strip_yaml(src) == src)
  end)

  test("single quote doubling is an escape", function ()
    local src = "permissions: '0755'\nb: 2  # gone\n"
    assert(strip.strip_yaml(src) == "permissions: '0755'\nb: 2\n")
  end)

  test("literal block scalar is opaque", function ()
    local src = "    content: |\n      #!/bin/bash\n      # keep\n      exit 0\nruncmd:\n  # gone\n"
    assert(strip.strip_yaml(src) ==
      "    content: |\n      #!/bin/bash\n      # keep\n      exit 0\nruncmd:\n")
  end)

  test("folded block scalar with chomping indicator is opaque", function ()
    local src = "a: >-\n  # keep\nb: 1\n"
    assert(strip.strip_yaml(src) == src)
  end)

  test("blank line inside block scalar does not end it", function ()
    local src = "a: |\n  x\n\n  # keep\nb: 1\n"
    assert(strip.strip_yaml(src) == src)
  end)

  test("greater-than inside a plain scalar is not an indicator", function ()
    local out = strip.strip_yaml("cmd: echo a > b  # gone\n")
    assert(out == "cmd: echo a > b\n")
  end)

end)

test("strip_dockerfile", function ()

  test("syntax and escape parser directives preserved", function ()
    local src = "# syntax=docker/dockerfile:1\n# escape=`\nFROM alpine\n"
    assert(strip.strip_dockerfile(src) == src)
  end)

  test("removes comment lines", function ()
    local out = strip.strip_dockerfile("FROM alpine\n# gone\nRUN true\n")
    assert(out == "FROM alpine\nRUN true\n")
  end)

  test("inline hash is not a comment", function ()
    local src = "RUN echo a#b\n"
    assert(strip.strip_dockerfile(src) == src)
  end)

  test("comment inside a line continuation removed", function ()
    local out = strip.strip_dockerfile("RUN foo \\\n  # gone\n  bar\n")
    assert(out == "RUN foo \\\n  bar\n")
  end)

  test("heredoc body is opaque", function ()
    local src = "RUN <<EOF\n#!/bin/sh\n# keep\nEOF\n"
    assert(strip.strip_dockerfile(src) == src)
  end)

  test("shift operator inside quotes is not a heredoc", function ()
    local out = strip.strip_dockerfile("RUN echo \"a << b\"\n# gone\n")
    assert(out == "RUN echo \"a << b\"\n")
  end)

end)

test("strip_unit", function ()

  test("removes hash and semicolon comment lines", function ()
    local out = strip.strip_unit("[Unit]\n# gone\n; also gone\nDescription=x\n")
    assert(out == "[Unit]\nDescription=x\n")
  end)

  test("inline hash and semicolon preserved", function ()
    local src = "Environment=\"A=b#c;d\"\nExecStart=/bin/sh -c 'a; b'\n"
    assert(strip.strip_unit(src) == src)
  end)

end)

test("strip_conf hash boundary", function ()

  test("mustache section tag preserved", function ()
    local src = "  {{#nginx.dev_auth_secret}}\n  auth_basic off;\n  {{/nginx.dev_auth_secret}}\n"
    assert(strip.strip_conf(src) == src)
  end)

  test("hash mid-token preserved", function ()
    local src = "return 302 https://$host$request_uri#top;\n"
    assert(strip.strip_conf(src) == src)
  end)

  test("comment beside a mustache tag still removed", function ()
    local out = strip.strip_conf("  {{#a}} # gone\n")
    assert(out == "  {{#a}}\n")
  end)

end)

test("css has no line comments", function ()

  test("double slash is not a comment", function ()
    local src = "a { background: url(//cdn/x.png) }\n"
    assert(strip.strip_css(src) == src)
  end)

end)

test("html inside lua strings", function ()

  test("html comment in a lua long string preserved", function ()
    local src = "local page = [[<div><!-- keep --></div>]] -- gone\n"
    assert(strip.strip_lua(src) == "local page = [[<div><!-- keep --></div>]]\n")
  end)

end)

test("comment lines are deleted, not blanked", function ()

  test("consecutive full-line comments all disappear", function ()
    local out = strip.strip_lua("a = 1\n-- one\n-- two\n-- three\nb = 2\n")
    assert(out == "a = 1\nb = 2\n")
  end)

  test("comment as the only content leaves nothing", function ()
    assert(strip.strip_lua("-- gone\n") == "")
  end)

  test("comment on the first line is deleted", function ()
    assert(strip.strip_lua("-- gone\na = 1\n") == "a = 1\n")
  end)

  test("full-line comment with no trailing newline", function ()
    assert(strip.strip_lua("a = 1\n-- gone") == "a = 1\n")
  end)

  test("crlf full-line comment consumes both bytes", function ()
    assert(strip.strip_lua("a = 1\r\n-- gone\r\nb = 2\r\n") == "a = 1\r\nb = 2\r\n")
  end)

  test("trailing comment keeps its line", function ()
    assert(strip.strip_lua("a = 1 -- gone\nb = 2\n") == "a = 1\nb = 2\n")
  end)

  test("shell block of comments disappears entirely", function ()
    local out = strip.strip_sh("#!/bin/sh\n# one\n# two\necho a\n")
    assert(out == "#!/bin/sh\necho a\n")
  end)

  test("output is still a subsequence after deletion", function ()
    local src = "a = 1\n  -- gone\n  -- also\nb = 2 -- and\n"
    local out = strip.strip_lua(src)
    assert(out == "a = 1\nb = 2\n")
    assert(is_subseq(out, src))
  end)

end)

test("blank line collapsing", function ()

  test("blank lines either side of a deletion collapse to one", function ()
    assert(strip.strip("a = 1\n\n-- gone\n\nb = 2\n", "a.lua") == "a = 1\n\nb = 2\n")
  end)

  test("a single blank line is preserved", function ()
    assert(strip.strip("a = 1\n\nb = 2\n", "a.lua") == "a = 1\n\nb = 2\n")
  end)

  test("pre-existing runs collapse even with no comment present", function ()
    assert(strip.strip("a = 1\n\n\n\nb = 2\n", "a.lua") == "a = 1\n\nb = 2\n")
  end)

  test("many blank lines after a deletion collapse to one", function ()
    assert(strip.strip("a = 1\n-- gone\n\n\n\nb = 2\n", "a.lua") == "a = 1\n\nb = 2\n")
  end)

  test("no blank lines stays no blank lines", function ()
    assert(strip.strip("a = 1\n-- gone\nb = 2\n", "a.lua") == "a = 1\nb = 2\n")
  end)

  test("whitespace-only lines count as blank", function ()
    assert(strip.strip("a = 1\n   \n\t\n\nb = 2\n", "a.lua") == "a = 1\n   \nb = 2\n")
  end)

  test("blank runs inside a lua long string are untouched", function ()
    local src = "local s = [[\n\n\n\nkeep\n]]\n\n\nb = 2\n"
    assert(strip.strip(src, "a.lua") == "local s = [[\n\n\n\nkeep\n]]\n\nb = 2\n")
  end)

  test("blank runs inside a heredoc are untouched", function ()
    local src = "cat <<EOF\n\n\n\nkeep\nEOF\n\n\necho a\n"
    assert(strip.strip(src, "a.sh") == "cat <<EOF\n\n\n\nkeep\nEOF\n\necho a\n")
  end)

  test("blank runs inside a js template literal are untouched", function ()
    local src = "var t = `\n\n\nx`;\n\n\nvar u = 1;\n"
    assert(strip.strip(src, "a.js") == "var t = `\n\n\nx`;\n\nvar u = 1;\n")
  end)

  test("blank runs inside a python triple quote are untouched", function ()
    local src = "s = \'\'\'\n\n\nx\'\'\'\n\n\ny = 1\n"
    assert(strip.strip(src, "a.py") == "s = \'\'\'\n\n\nx\'\'\'\n\ny = 1\n")
  end)

  test("blank runs inside a yaml block scalar are untouched", function ()
    local src = "a: |\n  x\n\n\n  y\nb: 1\n\n\nc: 2\n"
    assert(strip.strip(src, "a.yml") == "a: |\n  x\n\n\n  y\nb: 1\n\nc: 2\n")
  end)

  test("collapsing keeps the subsequence guarantee", function ()
    local src = "a = 1\n\n\n\n-- gone\n\n\nb = 2\n"
    local out, bailed = strip.strip(src, "a.lua")
    assert(not bailed)
    assert(out == "a = 1\n\nb = 2\n")
    assert(is_subseq(out, src))
  end)

  test("templates collapse literal regions but not code blocks", function ()
    local src = "a = 1\n\n\n<% x()\n\n\ny() %>\n\n\nb = 2\n"
    assert(strip.strip(src, "f.tk.lua") == "a = 1\n\n<% x()\n\n\ny() %>\n\nb = 2\n")
  end)

  test("unknown types are left alone entirely", function ()
    local src = "x\n\n\n\ny\n"
    assert(strip.strip(src, "a.sql") == src)
  end)

end)

test("empty template blocks", function ()

  test("comment-only block on its own line disappears entirely", function ()
    local out = strip.strip_template("a = 1\n<% -- gone %>\nb = 2\n", "lua")
    assert(out == "a = 1\nb = 2\n")
  end)

  test("indented comment-only block disappears entirely", function ()
    local out = strip.strip_template("a;\n  <% -- gone %>  \nb;\n", "c")
    assert(out == "a;\nb;\n")
  end)

  test("a block that was already empty is dropped too", function ()
    assert(strip.strip_template("a = 1\n<%%>\nb = 2\n", "lua") == "a = 1\nb = 2\n")
  end)

  test("multiline comment-only block disappears", function ()
    local src = "a = 1\n<%\n  -- one\n  -- two\n%>\nb = 2\n"
    assert(strip.strip_template(src, "lua") == "a = 1\nb = 2\n")
  end)

  test("block with real code is kept", function ()
    local src = "a = 1\n<% return v %>\nb = 2\n"
    assert(strip.strip_template(src, "lua") == src)
  end)

  test("block keeping code but losing a comment stays", function ()
    local out = strip.strip_template("<% return v -- gone %>\n", "lua")
    assert(out == "<% return v%>\n")
  end)

  test("inline comment-only block leaves surrounding text", function ()
    local out = strip.strip_template("x = <% -- gone %> y\n", "lua")
    assert(out == "x =  y\n")
  end)

  test("no empty block residue is ever emitted", function ()
    local out = strip.strip_template("a\n<% -- x %>\n<% -- y %>\nb\n", "lua")
    assert(not out:find("<%%s*%%>"))
    assert(out == "a\nb\n")
  end)

end)

test("tk directive and suffix form", function ()

  test("dot-tk suffix routes to template with the prior extension", function ()
    local src = "#include <x.h>\n<% return readfile(\"res/k.h\") %>\nint a; // gone\n"
    assert(strip.strip(src, "klib.h.tk") ==
      "#include <x.h>\n<% return readfile(\"res/k.h\") %>\nint a;\n")
  end)

  test("bare dot-tk strips only the code blocks", function ()
    local src = "anything <% x() -- gone %> here\n"
    assert(strip.strip(src, "thing.tk") == "anything <% x()%> here\n")
  end)

  test("hash directive declares a shell template", function ()
    local src = "# tk: sh\n#!/bin/sh\n<% return v %>\necho a # gone\n"
    assert(strip.strip(src, "res/lib/test-run.sh") ==
      "# tk: sh\n#!/bin/sh\n<% return v %>\necho a\n")
  end)

  test("directive is honoured on line two, after a shebang", function ()
    local src = "#!/bin/sh\n# tk: sh\n<% return v %>\necho a # gone\n"
    assert(strip.strip(src, "run.sh") == "#!/bin/sh\n# tk: sh\n<% return v %>\necho a\n")
  end)

  test("dash directive declares a lua template", function ()
    local src = "-- tk: lua\nlocal x = <% return v %> -- luacheck: ignore\nlocal y = 1 -- gone\n"
    assert(strip.strip(src, "template.rockspec") ==
      "-- tk: lua\nlocal x = <% return v %> -- luacheck: ignore\nlocal y = 1\n")
  end)

  test("directive beats the filename", function ()
    local src = "# tk: sh\nfoo # gone\n"
    assert(strip.strip(src, "lib.mk") == "# tk: sh\nfoo\n")
  end)

  test("directive makes an otherwise unknown type covered", function ()
    assert(strip.coverage("# tk: sh\nfoo\n", "lib.mk") == "checked")
    assert(strip.coverage("foo\n", "lib.mk") == "unknown")
  end)

  test("unrelated tk-looking text is not a directive", function ()
    local src = "local tk = 1 -- gone\n"
    assert(strip.strip(src, "a.lua") == "local tk = 1\n")
  end)

end)

test("license headers", function ()

  test("c block notice survives, code comments do not", function ()
    local src = "/*\n** LPeg - PEG pattern matching for Lua\n" ..
      "** Copyright 2007-2023, Lua.org & PUC-Rio  (see 'lpeg.html' for license)\n" ..
      "** written by Roberto Ierusalimschy\n*/\n\nint x; // gone\n"
    local out, bailed = strip.strip(src, "lptypes.h")
    assert(not bailed)
    assert(out == "/*\n** LPeg - PEG pattern matching for Lua\n" ..
      "** Copyright 2007-2023, Lua.org & PUC-Rio  (see 'lpeg.html' for license)\n" ..
      "** written by Roberto Ierusalimschy\n*/\n\nint x;\n")
  end)

  test("lua line-comment run survives whole, not just the marked line", function ()
    local src = "--\n-- Copyright 2007-2023, Lua.org & PUC-Rio  (see 'lpeg.html' for license)\n" ..
      "-- written by Roberto Ierusalimschy\n--\n\nlocal x = 1 -- gone\n"
    local out, bailed = strip.strip(src, "grammar.lua")
    assert(not bailed)
    assert(out == "--\n-- Copyright 2007-2023, Lua.org & PUC-Rio  (see 'lpeg.html' for license)\n" ..
      "-- written by Roberto Ierusalimschy\n--\n\nlocal x = 1\n")
  end)

  test("hash notice survives in shell after the shebang", function ()
    local src = "#!/bin/sh\n# Copyright 2025 Someone\n# All rights reserved\n\necho a # gone\n"
    local out = strip.strip(src, "x.sh")
    assert(out == "#!/bin/sh\n# Copyright 2025 Someone\n# All rights reserved\n\necho a\n")
  end)

  test("permission notice without the word copyright survives", function ()
    local src = "/* Permission is hereby granted, free of charge */\nint x; // gone\n"
    assert(strip.strip(src, "a.c") == "/* Permission is hereby granted, free of charge */\nint x;\n")
  end)

  test("spdx identifier survives", function ()
    local src = "// SPDX-License-Identifier: MIT\nint x; // gone\n"
    assert(strip.strip(src, "a.c") == "// SPDX-License-Identifier: MIT\nint x;\n")
  end)

  test("ordinary head comment is still stripped", function ()
    local src = "/* just a description */\nint x;\n"
    assert(strip.strip(src, "a.c") == "int x;\n")
  end)

  test("head rule does not fire on a directive-only head", function ()
    local src = "-- luacheck: push\nlocal x = 1 -- gone\n"
    assert(strip.strip(src, "a.lua") == "-- luacheck: push\nlocal x = 1\n")
  end)

  test("losing a notice anywhere else bails instead of deleting it", function ()
    local src = "int a;\n\n/* mid-file\n * Copyright 2010 Someone\n */\nint b;\n"
    local out, bailed = strip.strip(src, "a.c")
    assert(bailed)
    assert(out == src)
  end)

  test("blank lines before the notice are tolerated and collapsed", function ()
    local src = "\n\n/* Copyright 2020 X */\nint y; // gone\n"
    assert(strip.strip(src, "a.c") == "\n/* Copyright 2020 X */\nint y;\n")
  end)

end)

test("coverage", function ()

  test("known source is checked", function ()
    assert(strip.coverage("x = 1\n", "a.lua") == "checked")
    assert(strip.coverage("a # c\n", "a.sh") == "checked")
    assert(strip.coverage("FROM a\n", "Dockerfile") == "checked")
  end)

  test("deliberately ignored types report ignored", function ()
    assert(strip.coverage("{}\n", "a.json") == "ignored")
    assert(strip.coverage("# Title\n", "a.md") == "ignored")
    assert(strip.coverage("<svg/>\n", "a.svg") == "ignored")
  end)

  test("source we have no rule for reports unknown", function ()
    assert(strip.coverage("select 1; -- c\n", "a.sql") == "unknown")
    assert(strip.coverage("fn main() {}\n", "a.rs") == "unknown")
    assert(strip.coverage("all:\n", "a.mk") == "unknown")
  end)

  test("templates are always checked", function ()
    assert(strip.coverage("x <% y() %>\n", "a.tk.sql") == "checked")
  end)

  test("extensionless shebang is checked, without is unknown", function ()
    assert(strip.coverage("#!/bin/bash\na\n", "bin/x") == "checked")
    assert(strip.coverage("plain text\n", "bin/x") == "unknown")
  end)

end)

test("strip dispatcher", function ()

  test("routes lua", function ()
    assert(strip.strip("x = 1 -- c\n", "foo.lua") == "x = 1\n")
  end)

  test("routes c and h", function ()
    assert(strip.strip("a; // c\n", "foo.c") == "a;\n")
    assert(strip.strip("a; // c\n", "foo.h") == "a;\n")
  end)

  test("routes js", function ()
    assert(strip.strip("a; // c\n", "foo.js") == "a;\n")
  end)

  test("routes css", function ()
    assert(strip.strip("a{} /* c */\n", "foo.css") == "a{}\n")
  end)

  test("routes html", function ()
    assert(strip.strip("<b>x</b><!-- c -->", "foo.html") == "<b>x</b>")
  end)

  test("routes conf", function ()
    assert(strip.strip("a; # c\n", "foo.conf") == "a;\n")
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
    assert(strip.strip(src, "foo.tk.lua") == "local s = [[ <% x()%> ]]\n")
  end)

  test("tk c routes to template with c output", function ()
    local src = "int x; // c\n<% y() %>\n"
    assert(strip.strip(src, "foo.tk.c") == "int x;\n<% y() %>\n")
  end)

  test("tk html routes to template with html output", function ()
    local src = "<!-- c --><% z() %>"
    assert(strip.strip(src, "foo.tk.html") == "<% z() %>")
  end)

  test("tk json strips only lua code", function ()
    local src = "{ <% k() -- c %> }"
    assert(strip.strip(src, "foo.tk.json") == "{ <% k()%> }")
  end)

  test("path with directories", function ()
    assert(strip.strip("x -- c\n", "a/b/foo.lua") == "x\n")
  end)

  test("routes sh and bash", function ()
    assert(strip.strip("a # c\n", "foo.sh") == "a\n")
    assert(strip.strip("a # c\n", "foo.bash") == "a\n")
  end)

  test("routes tf and tfvars", function ()
    assert(strip.strip("a = 1 # c\n", "main.tf") == "a = 1\n")
    assert(strip.strip("a = 1 // c\n", "x.tfvars") == "a = 1\n")
  end)

  test("routes py", function ()
    assert(strip.strip("x = 1 # c\n", "foo.py") == "x = 1\n")
  end)

  test("routes yml and yaml", function ()
    assert(strip.strip("a: 1 # c\n", "foo.yml") == "a: 1\n")
    assert(strip.strip("a: 1 # c\n", "foo.yaml") == "a: 1\n")
  end)

  test("routes dockerfile by extension and by basename", function ()
    assert(strip.strip("FROM a\n# c\n", "deployment.dockerfile") == "FROM a\n")
    assert(strip.strip("FROM a\n# c\n", "Dockerfile") == "FROM a\n")
    assert(strip.strip("FROM a\n# c\n", "x/y/Dockerfile") == "FROM a\n")
  end)

  test("routes service and env", function ()
    assert(strip.strip("[Unit]\n# c\n", "a.service") == "[Unit]\n")
    assert(strip.strip("A=1 # c\n", "build.env") == "A=1\n")
  end)

  test("extensionless shell shebang routes to sh", function ()
    assert(strip.strip("#!/bin/bash\na # c\n", "bin/deploy") == "#!/bin/bash\na\n")
    assert(strip.strip("#!/usr/bin/env bash\na # c\n", "bin/deploy") ==
      "#!/usr/bin/env bash\na\n")
    assert(strip.strip("#!/data/data/com.termux/files/usr/bin/bash\na # c\n", "bin/x") ==
      "#!/data/data/com.termux/files/usr/bin/bash\na\n")
  end)

  test("extensionless lua shebang routes to lua", function ()
    local src = "#!/usr/bin/lua\nx = 1 -- c\n"
    assert(strip.strip(src, "bin/git-subject") == "#!/usr/bin/lua\nx = 1\n")
  end)

  test("extensionless python shebang routes to py", function ()
    local src = "#!/usr/bin/env python3\nx = 1 # c\n"
    assert(strip.strip(src, "bin/yt-dlp") == "#!/usr/bin/env python3\nx = 1\n")
  end)

  test("extensionless without a shebang is a no-op", function ()
    local src = "just # text\n"
    assert(strip.strip(src, "bin/notes") == src)
  end)

  test("extensionless with an unknown shebang is a no-op", function ()
    local src = "#!/usr/bin/perl\nx # c\n"
    assert(strip.strip(src, "bin/thing") == src)
  end)

  test("tk sh routes to template with sh output", function ()
    local src = "a # gone\n<% y() %>\n"
    assert(strip.strip(src, "foo.tk.sh") == "a\n<% y() %>\n")
  end)

  test("tk conf keeps mustache tags", function ()
    local src = "{{#a}} # gone\n<% y() %>\n"
    assert(strip.strip(src, "nginx.tk.conf") == "{{#a}}\n<% y() %>\n")
  end)

end)

test("subsequence safety on corpus shapes", function ()

  test("component.tk.lua shape is subsequence", function ()
    local src = "local skeleton = [[ <% return readfile(\"res/web/component.js\"), false %> ]]\n"
    local out = strip.strip(src, "component.tk.lua")
    assert(is_subseq(out, src))
  end)

  test("db.tk.lua directive sharing a line with an expression", function ()
    local src = "local sub_migrations = <% return t_sub_migrations %> -- luacheck: ignore\n"
    local out, bailed = strip.strip(src, "db.tk.lua")
    assert(not bailed)
    assert(out == src)
  end)

  test("db.tk.lua directive after a call expression", function ()
    local src = "  migrate(db, <% return t_index_migrations %>) -- luacheck: ignore\n"
    assert(strip.strip(src, "db.tk.lua") == src)
  end)

  test("index.tk.css import string spans a code block", function ()
    local src = "@import \"<% return root_dir %>/res/tailwind/theme.css\";\n"
    local out, bailed = strip.strip(src, "index.tk.css")
    assert(not bailed)
    assert(out == src)
  end)

  test("index.tk.css url in single quotes spans a code block", function ()
    local src = "  src: url('/<% return hashed(\"roboto.woff2\") %>') format('woff2');\n"
    local out, bailed = strip.strip(src, "index.tk.css")
    assert(not bailed)
    assert(out == src)
  end)

  test("serviceworker.tk.js shape keeps regex and template literals", function ()
    local src = "const v = \"<% return api_version %>\";\nconst r = /a\\/b/g; // gone\n"
    assert(strip.strip(src, "serviceworker.tk.js") ==
      "const v = \"<% return api_version %>\";\nconst r = /a\\/b/g;\n")
  end)

end)
