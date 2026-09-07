---
name: grep-q-under-pipefail-inverts-a-match
description: "`x | grep -q` under pipefail reports FAILURE when the match SUCCEEDS — and only once the upstream write exceeds the pipe buffer"
metadata:
  type: feedback
---

`grep -q` exits **as soon as it matches**, closing the pipe while the upstream is
still writing. The writer takes SIGPIPE (141), and `set -o pipefail` promotes
that to a pipeline failure — so a membership test reports "not found" *because*
the item was found. The verdict is inverted, not merely lost.

**Why:** it is size-dependent, not logic-dependent. While the upstream write fits
the pipe buffer (~64KB) the writer finishes before `grep` exits and the site
passes forever. Measured: 0/10 false FAILs at 24KB upstream, 10/10 at 109KB,
400/400 at 1.3MB. So it lies dormant through every test run until the data grows,
then surfaces as a "flake" that re-runs green — which is how it survives.

The tell is a **self-contradicting message**: `category 'command-injection' is
claimed but no scanner emits it`, printed directly above an evidence line
*listing* `command-injection` as emitted. When an assertion's own evidence
refutes it, suspect the plumbing, not the subject (same shape in prose:
[[comment-asserts-intent-not-code]]).

**How to apply:** use a here-string — `grep -qx "$needle" <<<"$haystack"` — which
has no second process and no pipe status. Do NOT sweep this mechanically: some
pipelines have a genuine upstream whose failure *should* propagate (`git worktree
list | grep -q`, `find -print -quit | grep -q`), so each site needs a decision
and a stated reason. Found live in `validate-owasp-coverage.sh`, swept in #928;
`tests/lint-shell-portability.sh` check 5 now bans the shape, with
`# lint-allow-pipe-grep-q: <reason>` as the escape hatch (a reasonless marker
does not exempt).

Two lessons that sweep taught beyond the mechanism. **The negated form is the
dangerous half**: `! upstream | grep -q` turns a real match into failure, then
`!` flips it to *success* — so the assertion passes while the forbidden thing is
present. 28 of the sites were this shape. And **a per-line guard under-covers**:
6 sites split the upstream and the `grep -q` across lines, so the scanner must
carry pending-pipe state or it silently misses exactly the sites a one-time sweep
also misses. Note the conversion itself is not observably testable per-site —
the site passes before *and* after — so the guard's negative-case test, not the
diff, is what actually proves the work.

Generalize the instinct: any `cmd | consumer-that-exits-early` under pipefail is
suspect — `head` (72 sites here, unswept), `grep -m1`. Related family:
[[whole-repo-diff-bounded-by-repo-content]] (a check silently vacuous because of
its input).
