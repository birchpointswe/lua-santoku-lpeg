/*
** santoku.re: compile-side glue. Builds a thread-portable program from a
** compiled lpeg pattern (validating out match-time / value captures, resolving
** named groups to dense tag ids) and hands it to consumers as a
** "santoku_re_prog" userdata whose tk_re_prog_t (santoku/re_match.h) the
** header-only matcher reads. Also the _prog / _check / _tags / _pmatch
** bindings on santoku.re.core.
**
** The vendored compiler's 'Instruction' and the header's 'tk_re_inst_t' have
** identical layout; the program is memcpy'd across by byte count.
*/

static char *tk_re_strdup (const char *s) {
  size_t n = strlen(s) + 1;
  char *d = (char *) malloc(n);
  if (d) memcpy(d, s, n);
  return d;
}

/* Non-raising build + validate over the vendored compiled code. Fills *out
** (owned code copy + tag arrays) and returns 0; on failure sets *err and
** returns -1. 'idx' is a positive stack index of an lpeg pattern udata. */
static int tk_re_build (lua_State *L, int idx, tk_re_prog_t *out, const char **err) {
  Pattern *pat;
  Instruction *code, *p;
  unsigned short keys[MAXAUX + 1];
  char *names[MAXAUX + 1];
  int ntags = 0, n, i;
  *err = NULL;
  (void) getpatt(L, idx, NULL);
  pat = getpattern(L, idx);
  code = (pat->code != NULL) ? pat->code : prepcompile(L, pat, idx);
  n = (int) code[-1].codesize;
  for (p = code; (p - code) < n; p += sizei(p)) {
    Opcode op = (Opcode) p->i.code;
    if (op == ICloseRunTime) {
      *err = "pattern uses a match-time capture (=name or =>); serial tier only";
      goto invalid;
    }
    if (op == IOpenCapture || op == IFullCapture) {
      int k = getkind(p);
      if (k == Cgroup) {
        int key = p->i.aux2.key;
        if (key != 0) {
          int found = -1, t;
          for (t = 0; t < ntags; t++)
            if (keys[t] == (unsigned short) key) { found = t; break; }
          if (found < 0 && ntags <= MAXAUX) {
            const char *nm;
            lua_getuservalue(L, idx);
            lua_rawgeti(L, -1, key);
            nm = lua_tostring(L, -1);
            names[ntags] = tk_re_strdup(nm ? nm : "");
            keys[ntags] = (unsigned short) key;
            ntags++;
            lua_pop(L, 2);
          }
        }
      } else if (k != Cposition && k != Cclose) {
        *err = "pattern uses a value capture; the parallel tier reads structure only";
        goto invalid;
      }
    }
  }
  out->code = (tk_re_inst_t *) malloc((size_t) n * sizeof(tk_re_inst_t));
  if (!out->code) { *err = "out of memory"; goto invalid; }
  memcpy(out->code, code, (size_t) n * sizeof(Instruction));  /* layouts match */
  out->codesize = n;
  out->ntags = ntags;
  out->tagnames = ntags ? (char **) malloc((size_t) ntags * sizeof(char *)) : NULL;
  out->tagkeys = ntags ? (unsigned short *) malloc((size_t) ntags * sizeof(unsigned short)) : NULL;
  for (i = 0; i < ntags; i++) { out->tagnames[i] = names[i]; out->tagkeys[i] = keys[i]; }
  return 0;
invalid:
  for (i = 0; i < ntags; i++) free(names[i]);
  return -1;
}

static void tk_re_prog_freeparts (tk_re_prog_t *prog) {
  int i;
  free(prog->code); prog->code = NULL;
  for (i = 0; i < prog->ntags; i++) free(prog->tagnames[i]);
  free(prog->tagnames); prog->tagnames = NULL;
  free(prog->tagkeys); prog->tagkeys = NULL;
  prog->ntags = 0;
}

static int tk_re_prog_gc (lua_State *L) {
  tk_re_prog_t *prog = (tk_re_prog_t *) luaL_checkudata(L, 1, TK_RE_PROG_MT);
  tk_re_prog_freeparts(prog);
  return 0;
}

/* re.core._prog(pattern) -> program userdata (thread-portable, gc-managed). */
static int l_re_prog (lua_State *L) {
  tk_re_prog_t built;
  const char *err = NULL;
  tk_re_prog_t *pu;
  if (tk_re_build(L, 1, &built, &err) != 0)
    return luaL_error(L, "santoku.re: %s", err);
  pu = (tk_re_prog_t *) lua_newuserdata(L, sizeof(tk_re_prog_t));
  *pu = built;
  luaL_getmetatable(L, TK_RE_PROG_MT);
  lua_setmetatable(L, -2);
  return 1;
}

static int l_re_check (lua_State *L) {
  tk_re_prog_t prog;
  const char *err = NULL;
  if (tk_re_build(L, 1, &prog, &err) != 0) {
    lua_pushnil(L); lua_pushstring(L, err); return 2;
  }
  tk_re_prog_freeparts(&prog);
  lua_pushboolean(L, 1);
  return 1;
}

static int l_re_tags (lua_State *L) {
  tk_re_prog_t prog;
  const char *err = NULL;
  int i;
  if (tk_re_build(L, 1, &prog, &err) != 0)
    return luaL_error(L, "santoku.re: %s", err);
  lua_createtable(L, 0, prog.ntags);
  for (i = 0; i < prog.ntags; i++) {
    lua_pushinteger(L, i);
    lua_setfield(L, -2, prog.tagnames[i]);
  }
  tk_re_prog_freeparts(&prog);
  return 1;
}

/* re.core._pmatch(pattern, subject [, init]) -> end offset + ncaps, or nil.
** Builds a temporary program and exercises the header-only matcher. */
static int l_re_pmatch (lua_State *L) {
  size_t len;
  const char *s = luaL_checklstring(L, 2, &len);
  lua_Integer init = luaL_optinteger(L, 3, 1);
  tk_re_prog_t prog;
  tk_re_scratch_t sc;
  const char *err = NULL;
  int64_t r;
  int ret;
  if (init < 1) init = 1;
  if (tk_re_build(L, 1, &prog, &err) != 0)
    return luaL_error(L, "santoku.re: %s", err);
  tk_re_scratch_init(&sc);
  r = tk_re_match(&prog, s, len, (size_t)(init - 1), &sc);
  if (r == -1) { lua_pushnil(L); ret = 1; }
  else if (r < 0) { lua_pushnil(L); lua_pushfstring(L, "match error %d", sc.status); ret = 2; }
  else { lua_pushinteger(L, (lua_Integer) r); lua_pushinteger(L, sc.ncaps); ret = 2; }
  tk_re_scratch_free(&sc);
  tk_re_prog_freeparts(&prog);
  return ret;
}

static const luaL_Reg tk_re_extra[] = {
  { "_prog", l_re_prog },
  { "_check", l_re_check },
  { "_tags", l_re_tags },
  { "_pmatch", l_re_pmatch },
  { NULL, NULL }
};

int luaopen_santoku_re_core (lua_State *L);
int luaopen_santoku_re_core (lua_State *L) {
  luaL_newmetatable(L, TK_RE_PROG_MT);   /* program udata metatable */
  lua_pushcfunction(L, tk_re_prog_gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  tk_re_open_core(L);                    /* core lpeg table on top */
  luaL_setfuncs(L, tk_re_extra, 0);
  return 1;
}
