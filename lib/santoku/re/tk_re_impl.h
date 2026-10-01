// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Birch Point SWE

static char *tk_re_strdup (const char *s) {
  size_t n = strlen(s) + 1;
  char *d = (char *) malloc(n);
  if (d) memcpy(d, s, n);
  return d;
}

static int tk_re_build (lua_State *L, int idx, tk_re_prog_t *out, const char **err) {
  Pattern *pat;
  Instruction *code, *p;
  tk_re_inst_t *copy;
  char **tn;
  unsigned short *tk;
  unsigned short keys[MAXAUX + 1];
  char *names[MAXAUX + 1];
  int ntags = 0, n, i;
  *err = NULL;
  (void) getpatt(L, idx, NULL);
  pat = getpattern(L, idx);
  code = (pat->code != NULL) ? pat->code : prepcompile(L, pat, idx);
  n = (int) code[-1].codesize - 1;
  for (p = code; (p - code) < n; p += sizei(p)) {
    Opcode op = (Opcode) p->i.code;
    if (op == ICloseRunTime) {
      *err = "pattern uses a match-time capture (=name or =>); serial tier only";
      goto invalid;
    }
    if (op == IOpenCapture || op == IFullCapture) {
      int k = getkind(p);
      if (k == Cgroup) {
        unsigned short key = (unsigned short) p->i.aux2.key;
        if (key != 0) {
          int found = -1, t;
          for (t = 0; t < ntags; t++)
            if (keys[t] == key) { found = t; break; }
          if (found < 0) {
            const char *nm;
            if (ntags > MAXAUX) {
              *err = "pattern has more named groups than the parallel tier supports";
              goto invalid;
            }
            lua_getuservalue(L, idx);
            lua_rawgeti(L, -1, (int) key);
            nm = lua_tostring(L, -1);
            if (!nm) nm = "";
            for (t = 0; t < ntags; t++)
              if (strcmp(names[t], nm) == 0) break;
            if (t < ntags) {
              lua_pop(L, 2);
              *err = "pattern reuses a group name; each named group needs a unique name";
              goto invalid;
            }
            names[ntags] = tk_re_strdup(nm);
            lua_pop(L, 2);
            if (!names[ntags]) { *err = "out of memory"; goto invalid; }
            keys[ntags] = key;
            ntags++;
          }
        }
      } else if (k != Cposition && k != Cclose) {
        *err = "pattern uses a value capture; the parallel tier reads structure only";
        goto invalid;
      }
    }
  }
  copy = (tk_re_inst_t *) malloc((size_t) n * sizeof(tk_re_inst_t));
  tn = ntags ? (char **) malloc((size_t) ntags * sizeof(char *)) : NULL;
  tk = ntags ? (unsigned short *) malloc((size_t) ntags * sizeof(unsigned short)) : NULL;
  if (!copy || (ntags && (!tn || !tk))) {
    free(copy);
    free(tn);
    free(tk);
    *err = "out of memory";
    goto invalid;
  }
  memcpy(copy, code, (size_t) n * sizeof(Instruction));
  for (i = 0; i < ntags; i++) { tn[i] = names[i]; tk[i] = keys[i]; }
  out->code = copy;
  out->codesize = n;
  out->ntags = ntags;
  out->tagnames = tn;
  out->tagkeys = tk;
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

static tk_re_prog_t *tk_re_prog_push (lua_State *L, int idx) {
  const char *err = NULL;
  tk_re_prog_t *pu = (tk_re_prog_t *) lua_newuserdata(L, sizeof(tk_re_prog_t));
  memset(pu, 0, sizeof(tk_re_prog_t));
  luaL_getmetatable(L, TK_RE_PROG_MT);
  lua_setmetatable(L, -2);
  if (tk_re_build(L, idx, pu, &err) != 0)
    luaL_error(L, "santoku.re: %s", err);
  return pu;
}

static int l_re_prog (lua_State *L) {
  tk_re_prog_push(L, 1);
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
  tk_re_prog_t *prog = tk_re_prog_push(L, 1);
  int i;
  lua_createtable(L, 0, prog->ntags);
  for (i = 0; i < prog->ntags; i++) {
    lua_pushinteger(L, i);
    lua_setfield(L, -2, prog->tagnames[i]);
  }
  return 1;
}

static int l_re_pmatch (lua_State *L) {
  size_t len;
  const char *s = luaL_checklstring(L, 2, &len);
  lua_Integer init = luaL_optinteger(L, 3, 1);
  tk_re_prog_t *prog;
  tk_re_scratch_t sc;
  int64_t r;
  int status, ncaps;
  if (init < 1) init = 1;
  prog = tk_re_prog_push(L, 1);
  tk_re_scratch_init(&sc);
  r = tk_re_match(prog, s, len, (size_t)(init - 1), &sc);
  status = sc.status;
  ncaps = sc.ncaps;
  tk_re_scratch_free(&sc);
  if (r == -1) { lua_pushnil(L); return 1; }
  if (r < 0) { lua_pushnil(L); lua_pushfstring(L, "match error %d", status); return 2; }
  lua_pushinteger(L, (lua_Integer) r);
  lua_pushinteger(L, ncaps);
  return 2;
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
  luaL_newmetatable(L, TK_RE_PROG_MT);
  lua_pushcfunction(L, tk_re_prog_gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  tk_re_open_core(L);
  luaL_setfuncs(L, tk_re_extra, 0);
  return 1;
}
