# tools/differential

An equivalence gate for `lib/santoku/lpeg/strip.lua`.

`strip.lua` rewrites source files in place across every repo on this machine. A
silent behaviour change corrupts code rather than failing loudly, so unit tests
alone are not sufficient assurance. This compares the working tree against any
earlier revision over the whole local corpus.

## Usage

```
./tools/differential [revision]
```

Defaults to `593d9fa`, the last revision before the LPeg rewrite. That is an
independent byte-loop implementation and therefore the strongest available
oracle. Any revision works.

It extracts `lib/santoku/lpeg/strip.lua` at that revision, builds a corpus from
every tracked file in `~/dotfiles` and `~/git/*` excluding vendored and build
trees, then compares the two implementations on each file's full contents and
on truncations at 13, 37, 50, 71 and 93 percent.

Truncation matters. Two real bugs were found only that way, both in heredoc
handling: `<<<` here-strings must consume two bytes when delimiter parsing
fails, and a heredoc whose newline is the final byte must not bail.

Exit status is zero only on `IDENTICAL`. Divergences print the file, whether it
was truncated, and how the bail flag differed.

## Interpreting a divergence

A divergence is not automatically a failure. When behaviour is changed on
purpose this becomes a change-scope gate rather than an equivalence gate: it
should report exactly the intended class of divergence and nothing else.
Anything unexpected means the change is wider than intended.

If a divergence suggests the older revision was right, investigate rather than
re-baseline. Re-baseline only once the new behaviour is deliberate and covered
by a spec case.

## Relationship to the test suite

`test/spec/santoku/lpeg/strip.lua` pins intended behaviour by example under
`toku test`. This tool proves the absence of unintended behaviour across real
inputs. Both are needed; neither substitutes for the other.
