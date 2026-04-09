local env = {
  name = "santoku-lpeg",
  version = "0.0.1-1",
  variable_prefix = "TK_LPEG",
  license = "MIT",
  public = true,
  dependencies = {
    "lua >= 5.1",
    "lpeg >= 1.1.0-2",
  },
  test = {
    dependencies = {
      "santoku >= 0.0.325-1"
    }
  }
}

env.homepage = "https://github.com/treadwelllane/lua-" .. env.name
env.tarball = env.name .. "-" .. env.version .. ".tar.gz"
env.download = env.homepage .. "/releases/download/" .. env.version .. "/" .. env.tarball

return { env = env }
