/*
** santoku.re: program build/validation, per-thread scratch, the C match entry,
** and the C->Lua bindings appended to santoku.re.core. Included by core.c after
** the vendored impls, so it can use their file-local helpers (getpatt,
** getpattern, prepcompile) and the include-twice matchers.
*/

static char *tk_re_strdup (const char *s) {
  size_t n = strlen(s) + 1;
  char *d = (char *) malloc(n);
  if (d) memcpy(d, s, n);
  return d;
}

/* Non-raising build + validate. Walks the compiled program: rejects match-time
** captures (ICloseRunTime) and value captures (anything other than position /
** group / close), and resolves named groups to dense tag ids (first-seen
** order). On success fills *out with an owned code copy and tag arrays and
** returns 0; on failure sets *err to a static message and returns -1.
** 'idx' must be a positive (absolute) stack index of an lpeg pattern udata. */
static int tk_re_build (lua_State *L, int idx, tk_re_prog_t *out,
                        const char **err) {
  Pattern *pat;
  Instruction *code, *p;
  unsigned short keys[MAXAUX + 1];
  char *names[MAXAUX + 1];
  int ntags = 0, n, i;
  *err = NULL;
  (void) getpatt(L, idx, NULL);          /* typecheck: arg is a pattern */
  pat = getpattern(L, idx);
  code = (pat->code != NULL) ? pat->code : prepcompile(L, pat, idx);
  /* Walk the whole program by its header codesize; do NOT stop at the first
  ** IEnd -- a compiled choice contains several IEnd markers, with capture
  ** instructions living between them (sizei steps over inline charsets). */
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
        if (key != 0) {  /* named group -> tag */
          int found = -1, t;
          for (t = 0; t < ntags; t++)
            if (keys[t] == (unsigned short) key) { found = t; break; }
          if (found < 0 && ntags <= MAXAUX) {
            const char *nm;
            lua_getuservalue(L, idx);      /* ktable */
            lua_rawgeti(L, -1, key);        /* ktable[key] = group name */
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
  out->code = (Instruction *) malloc((size_t) n * sizeof(Instruction));
  if (out->code == NULL) { *err = "out of memory"; goto invalid; }
  memcpy(out->code, code, (size_t) n * sizeof(Instruction));
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

static void tk_re_free_parts (tk_re_prog_t *prog) {
  int i;
  free(prog->code); prog->code = NULL;
  for (i = 0; i < prog->ntags; i++) free(prog->tagnames[i]);
  free(prog->tagnames); prog->tagnames = NULL;
  free(prog->tagkeys); prog->tagkeys = NULL;
  prog->ntags = 0;
}

tk_re_prog_t *tk_re_prog (lua_State *L, int idx) {
  tk_re_prog_t *prog = (tk_re_prog_t *) malloc(sizeof(*prog));
  const char *err = NULL;
  if (prog == NULL) { luaL_error(L, "santoku.re: out of memory"); return NULL; }
  if (tk_re_build(L, idx, prog, &err) != 0) {
    free(prog);
    luaL_error(L, "santoku.re: %s", err);
    return NULL;
  }
  return prog;
}

void tk_re_free (tk_re_prog_t *prog) {
  if (prog == NULL) return;
  tk_re_free_parts(prog);
  free(prog);
}

int tk_re_prog_ntags (const tk_re_prog_t *prog) { return prog->ntags; }

const char *tk_re_prog_tagname (const tk_re_prog_t *prog, int tag) {
  if (tag < 0 || tag >= prog->ntags) return NULL;
  return prog->tagnames[tag];
}

void tk_re_scratch_init (tk_re_scratch_t *sc) {
  sc->stack_cap = 100;
  sc->stack = malloc(sc->stack_cap * sizeof(Stack));
  sc->caps_cap = INITCAPSIZE;
  sc->caps = malloc(sc->caps_cap * sizeof(Capture));
  sc->ceiling = MAXBACK;
  sc->ncaps = 0;
  sc->status = TK_RE_OK;
}

void tk_re_scratch_free (tk_re_scratch_t *sc) {
  free(sc->stack); sc->stack = NULL;
  free(sc->caps); sc->caps = NULL;
}

int64_t tk_re_match (const tk_re_prog_t *prog, const char *subject,
                     size_t len, size_t init, tk_re_scratch_t *sc) {
  const char *o = subject;
  if (init > len) init = len;
  sc->status = TK_RE_OK;
  return tk_re_vmmatch(prog, o, o + init, o + len, sc);
}

int tk_re_ncaps (const tk_re_scratch_t *sc) { return sc->ncaps; }

void tk_re_cap (const tk_re_prog_t *prog, const tk_re_scratch_t *sc,
                int i, tk_re_cap_t *out) {
  Capture *c = (Capture *) sc->caps + i;
  int t;
  out->index = (int64_t) c->index;
  out->kind = c->kind;
  out->siz = c->siz;
  out->tag = -1;
  if (c->kind == Cgroup) {
    for (t = 0; t < prog->ntags; t++)
      if (prog->tagkeys[t] == c->idx) { out->tag = t; break; }
  }
}

/* ---- C->Lua bindings (santoku.re.core additions) ------------------------- */

static int l_re_check (lua_State *L) {
  tk_re_prog_t prog;
  const char *err = NULL;
  if (tk_re_build(L, 1, &prog, &err) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, err);
    return 2;
  }
  tk_re_free_parts(&prog);
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
  tk_re_free_parts(&prog);
  return 1;
}

/* Exercises the state-free tk_re_vmmatch from Lua (tests / debugging). Returns
** the 0-based end offset + capture count, or nil on no match. */
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
  else if (r < 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "match error %d", sc.status);
    ret = 2;
  } else {
    lua_pushinteger(L, (lua_Integer) r);
    lua_pushinteger(L, sc.ncaps);
    ret = 2;
  }
  tk_re_scratch_free(&sc);
  tk_re_free_parts(&prog);
  return ret;
}

static const luaL_Reg tk_re_extra[] = {
  { "_check", l_re_check },
  { "_tags", l_re_tags },
  { "_pmatch", l_re_pmatch },
  { NULL, NULL }
};

int luaopen_santoku_re_core (lua_State *L);
int luaopen_santoku_re_core (lua_State *L) {
  tk_re_open_core(L);              /* core lpeg table on top */
  luaL_setfuncs(L, tk_re_extra, 0);
  return 1;
}
