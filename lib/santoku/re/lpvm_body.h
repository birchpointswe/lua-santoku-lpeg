/*
** The lpeg opcode interpreter, extracted verbatim from lpeg 1.1.0's match()
** and included twice from lpvm_impl.h: once with TK_RE_LUA (the stock serial
** matcher, name 'match', used by lp_match) and once without (the state-free
** parallel matcher 'tk_re_vmmatch', used under OMP by consumers).
**
** The two tiers share this body so the extensively-tested serial path exercises
** the exact opcode logic the parallel path runs. Divergences are exactly the
** four points where upstream touches the lua_State: backtrack-stack growth,
** capture-buffer growth, match-time captures (ICloseRunTime + dyncap
** bookkeeping), and the error/return convention. Each is an #ifdef here.
*/

#ifdef TK_RE_LUA
#  define STACKBASE getstackbase(L, ptop)
const char *match (lua_State *L, const char *o, const char *s, const char *e,
                   Instruction *op, Capture *capture, int ptop) {
  Stack stackbase[INITBACK];
  Stack *stacklimit = stackbase + INITBACK;
  Stack *stack = stackbase;  /* point to first empty slot in stack */
  int capsize = INITCAPSIZE;
#else
#  define STACKBASE ((Stack *)sc->stack)
int64_t tk_re_vmmatch (const tk_re_prog_t *prog, const char *o, const char *s,
                       const char *e, tk_re_scratch_t *sc) {
  Instruction *op = prog->code;
  Stack *stacklimit = ((Stack *)sc->stack) + sc->stack_cap;
  Stack *stack = (Stack *)sc->stack;  /* first empty slot in stack */
  Capture *capture = (Capture *)sc->caps;
  int capsize = (int)sc->caps_cap;
#endif
  int captop = 0;  /* point to first empty slot in captures */
  int ndyncap = 0;  /* number of dynamic captures (in Lua stack) */
  const Instruction *p = op;  /* current instruction */
  stack->p = &giveup; stack->s = s; stack->caplevel = 0; stack++;
#ifdef TK_RE_LUA
  lua_pushlightuserdata(L, stackbase);
#endif
  for (;;) {
#if defined(DEBUG) && defined(TK_RE_LUA)
      printf("-------------------------------------\n");
      printcaplist(capture, capture + captop);
      printf("s: |%s| stck:%d, dyncaps:%d, caps:%d  ",
             s, (int)(stack - getstackbase(L, ptop)), ndyncap, captop);
      printinst(op, p);
#endif
#ifdef TK_RE_LUA
    assert(stackidx(ptop) + ndyncap == lua_gettop(L) && ndyncap <= captop);
#endif
    switch ((Opcode)p->i.code) {
      case IEnd: {
        assert(stack == STACKBASE + 1);
        capture[captop].kind = Cclose;
        capture[captop].index = MAXINDT;
#ifdef TK_RE_LUA
        return s;
#else
        sc->ncaps = captop;
        return (int64_t)(s - o);
#endif
      }
      case IGiveup: {
        assert(stack == STACKBASE);
#ifdef TK_RE_LUA
        return NULL;
#else
        return -1;
#endif
      }
      case IRet: {
        assert(stack > STACKBASE && (stack - 1)->s == NULL);
        p = (--stack)->p;
        continue;
      }
      case IAny: {
        if (s < e) { p++; s++; }
        else goto fail;
        continue;
      }
      case IUTFR: {
        int codepoint;
        if (s >= e)
          goto fail;
        s = utf8_decode (s, &codepoint);
        if (s && p[1].offset <= codepoint && codepoint <= utf_to(p))
          p += 2;
        else
          goto fail;
        continue;
      }
      case ITestAny: {
        if (s < e) p += 2;
        else p += getoffset(p);
        continue;
      }
      case IChar: {
        if ((byte)*s == p->i.aux1 && s < e) { p++; s++; }
        else goto fail;
        continue;
      }
      case ITestChar: {
        if ((byte)*s == p->i.aux1 && s < e) p += 2;
        else p += getoffset(p);
        continue;
      }
      case ISet: {
        uint c = (byte)*s;
        if (charinset(p, (p+1)->buff, c) && s < e)
          { p += 1 + p->i.aux2.set.size; s++; }
        else goto fail;
        continue;
      }
      case ITestSet: {
        uint c = (byte)*s;
        if (charinset(p, (p + 2)->buff, c) && s < e)
          p += 2 + p->i.aux2.set.size;
        else p += getoffset(p);
        continue;
      }
      case IBehind: {
        int n = p->i.aux1;
        if (n > s - o) goto fail;
        s -= n; p++;
        continue;
      }
      case ISpan: {
        for (; s < e; s++) {
          uint c = (byte)*s;
          if (!charinset(p, (p+1)->buff, c)) break;
        }
        p += 1 + p->i.aux2.set.size;
        continue;
      }
      case IJmp: {
        p += getoffset(p);
        continue;
      }
      case IChoice: {
        if (stack == stacklimit)
#ifdef TK_RE_LUA
          stack = doublestack(L, &stacklimit, ptop);
#else
          { stack = tk_re_doublestack(sc, &stacklimit); if (!stack) return -2; }
#endif
        stack->p = p + getoffset(p);
        stack->s = s;
        stack->caplevel = captop;
        stack++;
        p += 2;
        continue;
      }
      case ICall: {
        if (stack == stacklimit)
#ifdef TK_RE_LUA
          stack = doublestack(L, &stacklimit, ptop);
#else
          { stack = tk_re_doublestack(sc, &stacklimit); if (!stack) return -2; }
#endif
        stack->s = NULL;
        stack->p = p + 2;  /* save return address */
        stack++;
        p += getoffset(p);
        continue;
      }
      case ICommit: {
        assert(stack > STACKBASE && (stack - 1)->s != NULL);
        stack--;
        p += getoffset(p);
        continue;
      }
      case IPartialCommit: {
        assert(stack > STACKBASE && (stack - 1)->s != NULL);
        (stack - 1)->s = s;
        (stack - 1)->caplevel = captop;
        p += getoffset(p);
        continue;
      }
      case IBackCommit: {
        assert(stack > STACKBASE && (stack - 1)->s != NULL);
        s = (--stack)->s;
#ifdef TK_RE_LUA
        if (ndyncap > 0)  /* are there matchtime captures? */
          ndyncap -= removedyncap(L, capture, stack->caplevel, captop);
#endif
        captop = stack->caplevel;
        p += getoffset(p);
        continue;
      }
      case IFailTwice:
        assert(stack > STACKBASE);
        stack--;
        /* FALLTHROUGH */
      case IFail:
      fail: { /* pattern failed: try to backtrack */
        do {  /* remove pending calls */
          assert(stack > STACKBASE);
          s = (--stack)->s;
        } while (s == NULL);
#ifdef TK_RE_LUA
        if (ndyncap > 0)  /* is there matchtime captures? */
          ndyncap -= removedyncap(L, capture, stack->caplevel, captop);
#endif
        captop = stack->caplevel;
        p = stack->p;
#if defined(DEBUG) && defined(TK_RE_LUA)
        printf("**FAIL**\n");
#endif
        continue;
      }
      case ICloseRunTime: {
#ifdef TK_RE_LUA
        CapState cs;
        int rem, res, n;
        int fr = lua_gettop(L) + 1;  /* stack index of first result */
        cs.reclevel = 0; cs.L = L;
        cs.s = o; cs.ocap = capture; cs.ptop = ptop;
        n = runtimecap(&cs, capture + captop, s, &rem);  /* call function */
        captop -= n;  /* remove nested captures */
        ndyncap -= rem;  /* update number of dynamic captures */
        fr -= rem;  /* 'rem' items were popped from Lua stack */
        res = resdyncaptures(L, fr, s - o, e - o);  /* get result */
        if (res == -1)  /* fail? */
          goto fail;
        s = o + res;  /* else update current position */
        n = lua_gettop(L) - fr + 1;  /* number of new captures */
        ndyncap += n;  /* update number of dynamic captures */
        if (n == 0)  /* no new captures? */
          captop--;  /* remove open group */
        else {  /* new captures; keep original open group */
          if (fr + n >= SHRT_MAX)
            luaL_error(L, "too many results in match-time capture");
          /* add new captures + close group to 'capture' list */
          capture = growcap(L, capture, &capsize, captop, n + 1, ptop);
          adddyncaptures(s - o, capture + captop, n, fr);
          captop += n + 1;  /* new captures + close group */
        }
        p++;
        continue;
#else
        /* prog validation rejects Cruntime, so this is unreachable */
        assert(0);
        sc->status = TK_RE_ERUNTIME;
        return -2;
#endif
      }
      case ICloseCapture: {
        Capture *open = vm_findopen(capture + captop, s - o);
        assert(captop > 0);
        if (open) {  /* if possible, turn capture into a full capture */
          open->siz = (s - o) - open->index + 1;
          p++;
          continue;
        }
        else {  /* must create a close capture */
          capture[captop].siz = 1;  /* mark entry as closed */
          capture[captop].index = s - o;
          goto pushcapture;
        }
      }
      case IOpenCapture:
        capture[captop].siz = 0;  /* mark entry as open */
        capture[captop].index = s - o;
        goto pushcapture;
      case IFullCapture:
        capture[captop].siz = getoff(p) + 1;  /* save capture size */
        capture[captop].index = s - o - getoff(p);
        /* goto pushcapture; */
      pushcapture: {
        capture[captop].idx = p->i.aux2.key;
        capture[captop].kind = getkind(p);
        captop++;
#ifdef TK_RE_LUA
        capture = growcap(L, capture, &capsize, captop, 0, ptop);
#else
        capture = tk_re_growcap(sc, capture, &capsize, captop, 0);
        if (!capture) return -2;
#endif
        p++;
        continue;
      }
      default: assert(0);
#ifdef TK_RE_LUA
        return NULL;
#else
        return -2;
#endif
    }
  }
}
#undef STACKBASE
