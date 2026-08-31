local env = {
  name = "santoku-lpeg",
  version = "2.0.1-1",
  variable_prefix = "TK_LPEG",
  license = "MIT",
  public = true,
  dependencies = {
    "lua == 5.1",

  },
  test = {
    dependencies = {
      "santoku >= 2.0.0, < 3.0.0",
      "santoku-matrix >= 2.0.0, < 3.0.0",
    }
  }
}

env.homepage = "https://github.com/birchpointswe/lua-" .. env.name
env.tarball = env.name .. "-" .. env.version .. ".tar.gz"
env.download = env.homepage .. "/releases/download/" .. env.version .. "/" .. env.tarball

return { env = env }
