/*
** santoku.re: public C API for state-free (thread-portable) matching over a
** vendored, re-only lpeg core. Consumers (e.g. lua-santoku-learn's extract
** driver) build a program once on the main state with tk_re_prog, then match
** under OMP with per-thread tk_re_scratch_t and tk_re_match.
*/
#ifndef SANTOKU_RE_H
#define SANTOKU_RE_H

#include "santoku/re/tk_re_types.h"

#endif
