-- SPDX-License-Identifier: MIT
-- SPDX-FileCopyrightText: 2026 Birch Point SWE
local env = {
  name = "santoku-lpeg",
  version = "2.3.1-1",
  variable_prefix = "TK_LPEG",
  copyright = "Birch Point SWE",
  license = "MIT",
  vendored = {{
    name = "LPeg",
    version = "1.1.0",
    path = { "lib/santoku/re/lp*", "lib/santoku/re/grammar.lua" },
    copyright = "(C) 2007-2023 Lua.org, PUC-Rio.",
    license = "MIT",
    note = "The LPeg sources have been modified: renamed for coexistence, split for a state-free (thread-portable) match path, and the re grammar restricted to exclude function/match-time captures and user definition tables.",
  }},
  public = true,
  dependencies = {
    "lua == 5.1",
    "santoku >= 2.5.0, < 3.0.0",
    "santoku-matrix >= 3.0.2, < 4.0.0",
  },
}

env.homepage = "https://github.com/birchpointswe/lua-" .. env.name
env.tarball = env.name .. "-" .. env.version .. ".tar.gz"
env.download = env.homepage .. "/releases/download/" .. env.version .. "/" .. env.tarball

return { env = env }
