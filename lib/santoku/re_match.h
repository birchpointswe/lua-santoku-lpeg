/*
** santoku.re: self-contained, header-only state-free matcher.
**
** This header carries its own copy of the (frozen) lpeg 1.1.0 instruction and
** capture layout plus a Lua-free opcode interpreter, all static-inline, so a
** consumer TU (e.g. lua-santoku-learn's extract driver) can match under OMP
** without linking against re/core.so -- the ecosystem convention (matrix's C
** API is likewise header-only inline).
**
** The compiler stays in re/core.so; it builds a program from a re pattern and
** hands it over as a "santoku_re_prog" userdata whose tk_re_prog_t this header
** reads. core.so's vendored 'Instruction' and this header's 'tk_re_inst_t' are
** distinct type names with identical layout; the prog builder memcpys between
** them by byte count.
**
** lpeg is Copyright 2007-2023 Lua.org & PUC-Rio (MIT); see LICENSE.
*/
#ifndef SANTOKU_RE_MATCH_H
#define SANTOKU_RE_MATCH_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>

#define TK_RE_PROG_MT "santoku_re_prog"

typedef unsigned char tk_re_byte;
typedef unsigned int  tk_re_uint;

/* one compiled instruction (lpeg Instruction layout, verbatim) */
typedef union tk_re_inst_s {
  struct {
    tk_re_byte code;
    tk_re_byte aux1;
    union {
      short key;
      struct { tk_re_byte offset; tk_re_byte size; } set;
    } aux2;
  } i;
  int offset;
  tk_re_uint codesize;
  tk_re_byte buff[1];
} tk_re_inst_t;

/* opcodes (order matches lpeg's Opcode enum) */
enum {
  TK_RE_IAny, TK_RE_IChar, TK_RE_ISet, TK_RE_ITestAny, TK_RE_ITestChar,
  TK_RE_ITestSet, TK_RE_ISpan, TK_RE_IUTFR, TK_RE_IBehind, TK_RE_IRet,
  TK_RE_IEnd, TK_RE_IChoice, TK_RE_IJmp, TK_RE_ICall, TK_RE_IOpenCall,
  TK_RE_ICommit, TK_RE_IPartialCommit, TK_RE_IBackCommit, TK_RE_IFailTwice,
  TK_RE_IFail, TK_RE_IGiveup, TK_RE_IFullCapture, TK_RE_IOpenCapture,
  TK_RE_ICloseCapture, TK_RE_ICloseRunTime, TK_RE_IEmpty
};

/* capture kinds (subset we care about; values match lpeg's CapKind) */
enum {
  TK_RE_Cclose = 0, TK_RE_Cposition = 1, TK_RE_Cgroup = 15
};

typedef uint32_t tk_re_index_t;
#define TK_RE_MAXINDT (~(tk_re_index_t)0)

typedef struct {
  tk_re_index_t index;      /* subject position */
  unsigned short idx;       /* group name key / arg */
  tk_re_byte kind;
  tk_re_byte siz;           /* full-capture size + 1 (0 = open) */
} tk_re_capture_t;

typedef struct {
  const char *s;
  const tk_re_inst_t *p;
  int caplevel;
} tk_re_stack_t;

/* a compiled, thread-portable program (owned copy of the instructions) */
typedef struct {
  tk_re_inst_t *code;
  int codesize;
  int ntags;
  char **tagnames;          /* dense tag id -> named-group name */
  unsigned short *tagkeys;  /* dense tag id -> ktable key */
} tk_re_prog_t;

/* per-thread match scratch (backtrack stack + capture list) */
typedef struct {
  tk_re_stack_t *stack;   size_t stack_cap;
  tk_re_capture_t *caps;  size_t caps_cap;
  size_t ceiling;         /* max backtrack stack (elements) */
  int ncaps;              /* captures from the last successful match */
  int status;             /* 0 ok, else error */
} tk_re_scratch_t;

enum { TK_RE_OK = 0, TK_RE_ESTACK, TK_RE_ECAPS, TK_RE_ERUNTIME, TK_RE_EOOM };

#define TK_RE_INITBACK   400
#define TK_RE_INITCAP    32
#define tk_re_getoffset(p)   (((p) + 1)->offset)
#define tk_re_getkind(op)    ((op)->i.aux1 & 0xF)
#define tk_re_getoff(op)     (((op)->i.aux1 >> 4) & 0xF)
#define tk_re_testchar(st,c) ((((tk_re_uint)(st)[((c) >> 3)]) >> ((c) & 7)) & 1)
#define tk_re_utf_to(inst)   (((inst)->i.aux2.key << 8) | (inst)->i.aux1)

static const tk_re_inst_t tk_re_giveup = {{ TK_RE_IGiveup, 0, {0} }};

static inline int tk_re_charinset (const tk_re_inst_t *i, const tk_re_byte *buff, tk_re_uint c) {
  c -= i->i.aux2.set.offset;
  if (c >= ((tk_re_uint) i->i.aux2.set.size * (tk_re_uint) sizeof(tk_re_inst_t) * 8u))
    return i->i.aux1;
  return tk_re_testchar(buff, c);
}

static inline const char *tk_re_utf8_decode (const char *o, int *val) {
  static const tk_re_uint limits[] = {0xFF, 0x7F, 0x7FF, 0xFFFFu};
  const unsigned char *s = (const unsigned char *) o;
  tk_re_uint c = s[0], res = 0;
  if (c < 0x80) res = c;
  else {
    int count = 0;
    while (c & 0x40) {
      int cc = s[++count];
      if ((cc & 0xC0) != 0x80) return NULL;
      res = (res << 6) | (cc & 0x3F);
      c <<= 1;
    }
    res |= (c & 0x7F) << (count * 5);
    if (count > 3 || res > 0x10FFFFu || res <= limits[count]) return NULL;
    s += count;
  }
  *val = (int) res;
  return (const char *) s + 1;
}

static inline void tk_re_scratch_init (tk_re_scratch_t *sc) {
  sc->stack_cap = 100;
  sc->stack = (tk_re_stack_t *) malloc(sc->stack_cap * sizeof(tk_re_stack_t));
  sc->caps_cap = TK_RE_INITCAP;
  sc->caps = (tk_re_capture_t *) malloc(sc->caps_cap * sizeof(tk_re_capture_t));
  sc->ceiling = TK_RE_INITBACK;
  sc->ncaps = 0;
  sc->status = TK_RE_OK;
}

static inline void tk_re_scratch_free (tk_re_scratch_t *sc) {
  free(sc->stack); sc->stack = NULL;
  free(sc->caps); sc->caps = NULL;
}

static inline tk_re_stack_t *tk_re_doublestack (tk_re_scratch_t *sc, tk_re_stack_t **limit) {
  tk_re_stack_t *base = sc->stack, *ns;
  size_t n = sc->stack_cap, newn = n * 2;
  if (n >= sc->ceiling) { sc->status = TK_RE_ESTACK; return NULL; }
  if (newn > sc->ceiling) newn = sc->ceiling;
  ns = (tk_re_stack_t *) realloc(base, newn * sizeof(tk_re_stack_t));
  if (!ns) { sc->status = TK_RE_EOOM; return NULL; }
  sc->stack = ns; sc->stack_cap = newn;
  *limit = ns + newn;
  return ns + n;
}

static inline tk_re_capture_t *tk_re_growcap (tk_re_scratch_t *sc, int *capsize, int captop, int n) {
  tk_re_capture_t *nc;
  size_t newsize;
  if (*capsize - captop > n) return sc->caps;
  newsize = (size_t) captop + (size_t) n + 1;
  newsize += newsize / 2;
  nc = (tk_re_capture_t *) realloc(sc->caps, newsize * sizeof(tk_re_capture_t));
  if (!nc) { sc->status = TK_RE_ECAPS; return NULL; }
  sc->caps = nc; sc->caps_cap = newsize; *capsize = (int) newsize;
  return nc;
}

/* find the open capture a close can attach to (lpeg findopen, no-Lua) */
static inline tk_re_capture_t *tk_re_findopen (tk_re_capture_t *cap, tk_re_index_t currindex) {
  int i;
  cap--;
  if (!((cap)->siz == 0) && cap->index == currindex) return NULL;
  for (i = 0; i < 20; i++, cap--) {
    if (currindex - cap->index >= 0xFF) return NULL;
    else if (cap->siz == 0) return cap;
    else if (cap->kind == TK_RE_Cclose) return NULL;
  }
  return NULL;
}

/* Match prog against subject[init, len). Returns end offset (>=0), -1 no match,
** -2 error (see sc->status). On success the raw capture list is in sc->caps
** with sc->ncaps entries (terminated conceptually by the IEnd Cclose). */
static inline int64_t tk_re_match (const tk_re_prog_t *prog, const char *subject,
                                   size_t len, size_t init, tk_re_scratch_t *sc) {
  const char *o = subject, *s, *e = subject + len;
  const tk_re_inst_t *op = prog->code, *p;
  tk_re_stack_t *stack, *stacklimit;
  tk_re_capture_t *capture;
  int capsize, captop = 0;
  if (init > len) init = len;
  s = subject + init;
  sc->status = TK_RE_OK;
  stack = sc->stack; stacklimit = sc->stack + sc->stack_cap;
  capture = sc->caps; capsize = (int) sc->caps_cap;
  p = op;
  stack->p = &tk_re_giveup; stack->s = s; stack->caplevel = 0; stack++;
  for (;;) {
    switch (p->i.code) {
      case TK_RE_IEnd:
        capture[captop].kind = TK_RE_Cclose;
        capture[captop].index = TK_RE_MAXINDT;
        sc->ncaps = captop;
        return (int64_t)(s - o);
      case TK_RE_IGiveup:
        return -1;
      case TK_RE_IRet:
        p = (--stack)->p; continue;
      case TK_RE_IAny:
        if (s < e) { p++; s++; } else goto fail;
        continue;
      case TK_RE_IUTFR: {
        int cp;
        if (s >= e) goto fail;
        s = tk_re_utf8_decode(s, &cp);
        if (s && p[1].offset <= cp && cp <= tk_re_utf_to(p)) p += 2;
        else goto fail;
        continue;
      }
      case TK_RE_ITestAny:
        if (s < e) p += 2; else p += tk_re_getoffset(p);
        continue;
      case TK_RE_IChar:
        if ((tk_re_byte) *s == p->i.aux1 && s < e) { p++; s++; } else goto fail;
        continue;
      case TK_RE_ITestChar:
        if ((tk_re_byte) *s == p->i.aux1 && s < e) p += 2; else p += tk_re_getoffset(p);
        continue;
      case TK_RE_ISet: {
        tk_re_uint c = (tk_re_byte) *s;
        if (tk_re_charinset(p, (p + 1)->buff, c) && s < e) { p += 1 + p->i.aux2.set.size; s++; }
        else goto fail;
        continue;
      }
      case TK_RE_ITestSet: {
        tk_re_uint c = (tk_re_byte) *s;
        if (tk_re_charinset(p, (p + 2)->buff, c) && s < e) p += 2 + p->i.aux2.set.size;
        else p += tk_re_getoffset(p);
        continue;
      }
      case TK_RE_IBehind: {
        int n = p->i.aux1;
        if (n > s - o) goto fail;
        s -= n; p++;
        continue;
      }
      case TK_RE_ISpan:
        for (; s < e; s++) {
          tk_re_uint c = (tk_re_byte) *s;
          if (!tk_re_charinset(p, (p + 1)->buff, c)) break;
        }
        p += 1 + p->i.aux2.set.size;
        continue;
      case TK_RE_IJmp:
        p += tk_re_getoffset(p); continue;
      case TK_RE_IChoice:
        if (stack == stacklimit) {
          stack = tk_re_doublestack(sc, &stacklimit);
          if (!stack) return -2;
        }
        stack->p = p + tk_re_getoffset(p); stack->s = s; stack->caplevel = captop;
        stack++; p += 2;
        continue;
      case TK_RE_ICall:
        if (stack == stacklimit) {
          stack = tk_re_doublestack(sc, &stacklimit);
          if (!stack) return -2;
        }
        stack->s = NULL; stack->p = p + 2; stack++;
        p += tk_re_getoffset(p);
        continue;
      case TK_RE_ICommit:
        stack--; p += tk_re_getoffset(p); continue;
      case TK_RE_IPartialCommit:
        (stack - 1)->s = s; (stack - 1)->caplevel = captop; p += tk_re_getoffset(p);
        continue;
      case TK_RE_IBackCommit:
        s = (--stack)->s; captop = stack->caplevel; p += tk_re_getoffset(p);
        continue;
      case TK_RE_IFailTwice:
        stack--;
        /* FALLTHROUGH */
      case TK_RE_IFail:
      fail:
        do { s = (--stack)->s; } while (s == NULL);
        captop = stack->caplevel; p = stack->p;
        continue;
      case TK_RE_ICloseRunTime:
        /* rejected by prog validation; unreachable */
        sc->status = TK_RE_ERUNTIME; return -2;
      case TK_RE_ICloseCapture: {
        tk_re_capture_t *open = tk_re_findopen(capture + captop, (tk_re_index_t)(s - o));
        if (open) { open->siz = (tk_re_byte)((s - o) - open->index + 1); p++; continue; }
        capture[captop].siz = 1; capture[captop].index = (tk_re_index_t)(s - o);
        goto pushcapture;
      }
      case TK_RE_IOpenCapture:
        capture[captop].siz = 0; capture[captop].index = (tk_re_index_t)(s - o);
        goto pushcapture;
      case TK_RE_IFullCapture:
        capture[captop].siz = (tk_re_byte)(tk_re_getoff(p) + 1);
        capture[captop].index = (tk_re_index_t)(s - o - tk_re_getoff(p));
      pushcapture:
        capture[captop].idx = (unsigned short) p->i.aux2.key;
        capture[captop].kind = (tk_re_byte) tk_re_getkind(p);
        captop++;
        capture = tk_re_growcap(sc, &capsize, captop, 0);
        if (!capture) return -2;
        p++;
        continue;
      default:
        sc->status = TK_RE_ERUNTIME; return -2;
    }
  }
}

static inline tk_re_prog_t *tk_re_prog_peek (lua_State *L, int i) {
  return (tk_re_prog_t *) luaL_checkudata(L, i, TK_RE_PROG_MT);
}

static inline int tk_re_ncaps (const tk_re_scratch_t *sc) { return sc->ncaps; }

/* dense tag id for a Cgroup capture (-1 otherwise) */
static inline int tk_re_cap_tag (const tk_re_prog_t *prog, const tk_re_capture_t *c) {
  int t;
  if (c->kind != TK_RE_Cgroup) return -1;
  for (t = 0; t < prog->ntags; t++)
    if (prog->tagkeys[t] == c->idx) return t;
  return -1;
}

#endif
