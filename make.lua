local env = {
  name = "santoku-lpeg",
  version = "0.0.7-1",
  variable_prefix = "TK_LPEG",
  license = "MIT",
  public = true,
  dependencies = {
    "lua == 5.1",
    -- lpeg 1.1.0 is vendored under lib/santoku/re (see LICENSE); no external dep.
  },
  test = {
    dependencies = {
      "santoku >= 0.0.328-1",
      "santoku-matrix >= 0.0.313-1",
    }
  }
}

env.homepage = "https://github.com/birchpointswe/lua-" .. env.name
env.tarball = env.name .. "-" .. env.version .. ".tar.gz"
env.download = env.homepage .. "/releases/download/" .. env.version .. "/" .. env.tarball

return { env = env }
