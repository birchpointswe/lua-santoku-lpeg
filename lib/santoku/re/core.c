/*
** santoku.re.core: the vendored lpeg 1.1.0 engine (renamed for coexistence
** with any external lpeg rock) plus santoku.re's state-free matching layer.
**
** toku compiles one module per .c, so the six lpeg translation units are
** amalgamated here as *_impl.h includes (one file-local static name collided,
** lpvm's findopen -> vm_findopen). The module exports the full lpeg combinator
** API (santoku.lpeg utilities depend on it) and the tk_re_* C API + _check /
** _tags / _pmatch bindings.
**
** lpeg is Copyright 2007-2023 Lua.org & PUC-Rio (MIT); see LICENSE.
*/

#include "lua.h"
#include "lauxlib.h"

#include "santoku/re_match.h"  /* header-only state-free matcher + prog type */

#include "lpcap_impl.h"    /* lpcap.c  */
#include "lpcset_impl.h"   /* lpcset.c */
#include "lpcode_impl.h"   /* lpcode.c */
#include "lpprint_impl.h"  /* lpprint.c */
#include "lpvm_impl.h"     /* lpvm.c: helpers + serial matcher */
#include "lptree_impl.h"   /* lptree.c: combinators, pattreg, tk_re_open_core */
#include "tk_re_impl.h"    /* prog build (udata) + _prog/_check/_tags/_pmatch */
