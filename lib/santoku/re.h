/*
** santoku.re: public C API. Consumers include this to run the state-free
** matcher (santoku/re_match.h) in their own TU under OMP. Compile a re pattern
** in Lua (santoku.re / santoku.re.core._prog) into a "santoku_re_prog" userdata,
** peek it with tk_re_prog_peek, then match with per-thread tk_re_scratch_t.
*/
#ifndef SANTOKU_RE_H
#define SANTOKU_RE_H

#include "santoku/re_match.h"

#endif
