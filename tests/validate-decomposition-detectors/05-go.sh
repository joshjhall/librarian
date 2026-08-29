# shellcheck shell=bash
# Go segmenter — check-decomposition detector tests (issue #760 split).
#
# The func-family seam and `func Test` exclusion, plus the #727 arms: methods
# clustering by receiver, visible grouped declarations, and a testify Test
# method staying test-classified.
#
# Sourced by tests/validate-decomposition-detectors.sh, which defines PY / SH /
# REAL_BASH and sources tests/lib/decomposition-sandbox.sh (the emit_rows /
# assert_fires / assert_silent / fresh_dir / list_of drivers) BEFORE this file.
# This fragment only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_fragment_test list.

# ============================================================================
# Go segmenter
# ============================================================================
test_seam_go() {
    local d f list
    d="$(fresh_dir)"
    f="$d/app.go"
    command cat >"$f" <<'EOF'
package main

func MainEntry(s string) string {
	return handleRequest(s)
}

func handleRequest(s string) string {
	return s + "a"
}

func handleResponse(s string) string {
	return s + "b"
}

func handleError(s string) string {
	return s + "c"
}

func TestMainEntry(t *testing.T) {
	MainEntry("x")
}
EOF
    list="$(list_of "$f")"

    assert_fires "$list" decomposition-seam "seam 7-18: func handle_* family (3 units," \
        "go: handle* seam span and family"
    assert_fires "$list" decomposition-seam "fan-in 1 <- MainEntry" \
        "go: seam fan-in names its caller"
    # func Test... excluded — the other rule that was duplicated prose.
    assert_fires "$list" file-length "3 test-excluded" \
        "go: func Test excluded from production LOC"
}

# ============================================================================
# Go segmenter — methods, receivers, grouped declarations (#727)
# ============================================================================
# Before #727 a method header did not merely get a poor NAME: `func (r *Repo)`
# failed the identifier class outright, so the match failed and the method was
# absorbed into the preceding unit's span. A 25-method file segmented to ~2
# units and was declined as "single cohesive unit". The assertions below key on
# the unit COUNT and on receiver-keyed family names, both of which are
# unreachable without the fix.
test_go_method_receivers() {
    local d f list
    d="$(fresh_dir)"
    f="$d/repo.go"
    command cat >"$f" <<'EOF'
package repo

func (r *Repo) GetOne(id string) string {
	return r.db[id]
}

func (r *Repo) GetTwo(id string) string {
	return r.db[id]
}

func (r *Repo) GetThree(id string) string {
	return r.db[id]
}

func (r *Repo[T]) GetFour(id string) string {
	return r.db[id]
}

func (s Store) PutOne(v string) error {
	s.n++
	return nil
}

func NewRepo() *Repo {
	return &Repo{}
}
EOF
    list="$(list_of "$f")"

    # Methods on one receiver cluster into one family, which is what makes the
    # seam proposable at all — Go's split shape is "more files in the package".
    # GetFour has a GENERIC receiver (`*Repo[T]`); it joins the same family only
    # if the type-parameter suffix is stripped, so a family of 4 also pins that
    # the name is `Repo_GetFour`, not `Repo[T]_GetFour`.
    assert_fires "$list" decomposition-seam "func repo_* family (4 units," \
        "go: methods cluster by receiver, generic receiver stripped to its type" \
        DECOMP_SEAM_MIN_UNITS=4
    # The unit count proves the methods are VISIBLE. Pre-fix this file measured
    # 1 unit (only NewRepo); 6 is reachable only once each method segments.
    assert_fires "$list" file-length "6 top-level units" \
        "go: every method is its own unit, not absorbed into the previous one"

    # A pointer receiver, a value receiver, and a generic receiver all name the
    # TYPE, never the binder — `Store_PutOne`, not `s_PutOne`.
    assert_fires "$list" decomposition-seam "> $d/repo/repo.go" \
        "go: the receiver family proposes a receiver-named module"

    # Grouped declarations were invisible for the same reason (`(` is not an
    # identifier char). One visible unit per block is the honest count.
    f="$d/decls.go"
    command cat >"$f" <<'EOF'
package decls

var (
	ErrOne = 1
	ErrTwo = 2
)

const (
	Alpha = "a"
	Beta  = "b"
)

type (
	Handle = string
	Token  = string
)

func Solo() int {
	return 1
}
EOF
    list="$(list_of "$f")"
    # All THREE grouped forms are exercised: `type (` is named in the arm's own
    # comment but had no fixture, so a divergence confined to that branch would
    # have gone unseen.
    assert_fires "$list" file-length "4 top-level units" \
        "go: grouped var/const/type blocks are one visible unit each, not zero"

    # The ACCEPTED LIMITATION, pinned as live behavior rather than only as a
    # comment: two adjacent blocks of the same kind share the keyword as their
    # name, so they cluster as one family. That is the documented trade-off —
    # a future change to position-dependent naming (explicitly rejected in
    # UNIT_RE["go"], because it would churn the TSV on an unrelated insert)
    # would break this assertion, which is the point.
    f="$d/adjacent.go"
    command cat >"$f" <<'EOF'
package adjacent

var (
	GroupOneA = 1
	GroupOneB = 2
)

var (
	GroupTwoA = 3
	GroupTwoB = 4
)

var (
	GroupThreeA = 5
	GroupThreeB = 6
)
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "func var_* family (3 units," \
        "go: adjacent same-kind grouped blocks share the keyword family (accepted, #727)"
}

# A testify-style method (`func (s *Suite) TestFoo`) must stay TEST-classified
# even though the receiver arm now rewrites its name. Kept separate from the
# clustering case: this is the ordering between TEST_UNIT_RE and UNIT_RE, and a
# regression here silently counts test code as production.
test_go_method_test_classification() {
    local d f list
    d="$(fresh_dir)"
    f="$d/suite.go"
    command cat >"$f" <<'EOF'
package suite

func Production(s string) string {
	a := s + "!"
	b := a + "?"
	c := b + "."
	return c
}

func TestPlain(t *testing.T) {
	Production("x")
}

func (s *Suite) TestMethod() {
	Production("y")
}

func (s *Suite) BenchmarkMethod() {
	Production("z")
}
EOF
    list="$(list_of "$f")"
    # The plain Test func AND both testify METHODS are excluded. A regression
    # that let the receiver arm win would leave the two methods counted as
    # production, raising units to 3 and dropping test-excluded to 4.
    assert_fires "$list" file-length "11 test-excluded" \
        "go: a testify Test/Benchmark method stays test-classified under the receiver arm"
    assert_fires "$list" file-length "1 top-level units" \
        "go: only the production func counts toward the unit total"

    # --- #851: the SAME content at an idiomatic `_test.go` path inverts ------
    # A separate-file test's test code IS its production content, so the units
    # that were subtracted above are now counted. Classification is unchanged —
    # `11 test-excluded` still reports, because test_excluded stays a truthful
    # diagnostic — and only the SUBTRACTION differs. That pairing is the whole
    # point: the two cases share a byte-identical body and differ only in the
    # PATH, so a regression that collapses the distinction cannot keep both
    # green.
    f="$d/suite_test.go"
    command cp "$d/suite.go" "$f"
    list="$(list_of "$f")"
    assert_fires "$list" file-length "11 test-excluded" \
        "go: a _test.go file still CLASSIFIES its test units (#851)"
    assert_fires "$list" file-length "16 production LOC" \
        "go: a _test.go file counts its test lines as production (#851)"
    assert_fires "$list" file-length "4 top-level units" \
        "go: a _test.go file counts its test units toward the unit total (#851)"

    # The prefix needs a BOUNDARY. Go's rule is `func TestXxx` where Xxx does
    # not start lowercase, so a bare prefix match classifies `Testify`,
    # `Benchmarking` and `Exampler` as test code and silently drops their
    # lines from production LOC — a wrong number feeding every downstream
    # verdict, with no visible error. Every unit below is PRODUCTION.
    f="$d/prefixy.go"
    command cat >"$f" <<'EOF'
package api

func (s *Suite) Testify(v string) string {
	return v
}

func (r *Repo) Exampler(v string) string {
	return v
}

func (a *API) Benchmarking(v string) string {
	return v
}

func Fuzzy(v string) string {
	return v
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "0 test-excluded" \
        "go: a name merely STARTING with Test/Benchmark/Example is not a test"
    assert_fires "$list" file-length "4 top-level units" \
        "go: those four production units all survive the test classifier"
}
