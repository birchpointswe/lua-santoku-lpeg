/*
** santoku.re: state-free matching API over a vendored lpeg core.
** These types cross into consumers (e.g. lua-santoku-learn's extract driver)
** and into the OMP match loop, so they carry no lua_State and no lpeg types.
*/
#ifndef TK_RE_TYPES_H
#define TK_RE_TYPES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct lua_State;

/* status codes; also stored in scratch.status on the error return path */
enum {
  TK_RE_OK = 0,
  TK_RE_ESTACK,    /* backtrack stack hit the ceiling */
  TK_RE_ECAPS,     /* capture buffer allocation failed */
  TK_RE_ERUNTIME,  /* a match-time capture reached the parallel VM (unreachable
                      after prog validation; guarded) */
  TK_RE_EOOM       /* out of memory growing scratch */
};

/* A compiled, thread-portable program. Opaque to consumers. */
typedef struct tk_re_prog_s tk_re_prog_t;

/* Per-thread match scratch. Fields are engine-owned; treat as opaque and use
** the helpers. Sizes are in element units (Stack / Capture), not bytes. */
typedef struct {
  void  *stack;      size_t stack_cap;
  void  *caps;       size_t caps_cap;
  size_t ceiling;    /* max backtrack stack size (elements); default MAXBACK */
  int    ncaps;      /* captures produced by the last successful match */
  int    status;     /* TK_RE_* after an error return */
} tk_re_scratch_t;

/* Projected raw capture, mirroring the engine's Capture record. 'index' is the
** 0-based subject offset; 'siz' is full-capture size+1 (0 = open marker); 'tag'
** is the dense named-group id for Cgroup opens/closes (else -1); 'kind' is the
** engine CapKind. Consumers pair open/close by scanning [0, ncaps). */
typedef struct {
  int64_t index;
  int32_t tag;
  int32_t kind;
  int32_t siz;
} tk_re_cap_t;

/* Build + validate a program from the lpeg pattern userdata at stack index
** 'idx'. Forces compilation, rejects match-time and value captures (parallel
** tier reads structure only), and resolves named groups to dense tag ids.
** Raises a Lua error (main-thread/setup use) on an invalid pattern. */
tk_re_prog_t *tk_re_prog (struct lua_State *L, int idx);
void          tk_re_free (tk_re_prog_t *prog);

int           tk_re_prog_ntags (const tk_re_prog_t *prog);
const char   *tk_re_prog_tagname (const tk_re_prog_t *prog, int tag);

void          tk_re_scratch_init (tk_re_scratch_t *sc);
void          tk_re_scratch_free (tk_re_scratch_t *sc);

/* Match 'prog' against subject[init, len) (0-based init). Returns the end
** offset (>= 0), -1 on no match, or -2 on error (see sc->status). On success
** the raw capture list is in scratch; read it with tk_re_ncaps/tk_re_cap. */
int64_t       tk_re_match (const tk_re_prog_t *prog, const char *subject,
                           size_t len, size_t init, tk_re_scratch_t *sc);

int           tk_re_ncaps (const tk_re_scratch_t *sc);
void          tk_re_cap (const tk_re_prog_t *prog, const tk_re_scratch_t *sc,
                         int i, tk_re_cap_t *out);

#ifdef __cplusplus
}
#endif

#endif
