#!/usr/bin/env bash
# Differential equivalence gate for the pre-scan tools (issue #17 follow-up).
#
# tests/validate-python-ports.sh pins bash<->python parity over ONE small shared
# fixture tree — enough to catch a gross regression, but a category or language
# branch with no example in that fixture goes untested. This gate widens the net:
# for every tool it diffs the bash fallback (PATTERNS_FORCE_BASH=1) against the
# python primary over
#
#   1. the WHOLE librarian-proper tree (plugins/ tests/ bin/ .github/ docs/) —
#      real files exercise the categories/languages actually present in the repo,
#   2. a per-category / per-language FIXTURE LIBRARY (fixtures/ below) — synthetic
#      files that exercise CONTENT branches the repo itself does not contain
#      (Rust, Kotlin, empty handlers, multibyte evidence, set -e edge cases, …),
#      and
#   3. a PATH-SHAPE corpus (shapes/ below) — synthetic files whose CONTENT is
#      deliberately identical and whose PATHS are the awkward ones: test_*
#      directories, __tests__ under a non-test parent, spec/ inside src/,
#      near-miss basenames (contest.py), uppercase extensions, spaces.
#
# Any byte difference between the two implementations is a divergence and fails
# the gate: the two must be equivalent, full stop. drift-detect (the two-arg
# outlier) is diffed with its own actual/planned fixture pair.
#
# WHAT EACH CORPUS DOES AND DOES NOT BOUND (#867).
#
# Corpus 1 is bounded by THE REPO'S OWN CONTENT. It can only ask the two
# runtimes about inputs this tree happens to contain today, so an absent input
# shape is not covered and the gate still reports green — and coverage SHRINKS
# SILENTLY when the last file of some shape is deleted. That is not
# hypothetical: it is exactly how #836 survived. check-lifecycle's bash
# is_test_file spelled its name arms as PATH globs (`*/test_*.*`), where a
# bash `case` glob's `*` crosses `/`, so a directory named test_helpers/
# silenced every finding for real source beneath it while its python twin
# scanned it. `git ls-files | grep -c "/test_[^/]*/"` returns 0, so this gate
# diffed the two impls over every tracked file and found no difference.
#
# Corpus 3 exists to close that: it asks the path questions regardless of what
# the tree looks like, and test_shape_corpus_is_non_vacuous below MUTATES a
# copy of a scanner back to the pre-#836 spelling to prove the corpus can still
# detect the regression that once shipped past here. The per-arm coverage
# report (report_path_shape_coverage) prints how many REAL files reach each
# classification arm, so an arm at zero is readable rather than invisible.
#
# None of the three is a substitute for the per-detector suites. Parity is
# same-OUTPUT, never same-INTENT: a defect present in BOTH impls passes here by
# construction (the #684 limit that validate-python-ports.sh documents at
# length). A fixture asserting the INTENDED match belongs in
# validate-lifecycle-detectors.sh et al., and the is_test_file ANCHORING
# invariant itself is pinned structurally by tests/lint-test-file-anchoring.sh
# (#866), not here.
#
# Skips (does not fail) when python3>=3.11 is unavailable, mirroring
# validate-python-ports.sh. Pure bash + coreutils + python3; no network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

test_suite "Pre-scan bash<->python differential equivalence (#17)"

if ! command -v python3 >/dev/null 2>&1 ||
    ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    skip_test "python3>=3.11 not available (bash path covered by validate-prescans.sh)"
    generate_report
    return 0 2>/dev/null || exit 0
fi

# PHYSICAL path: macOS $TMPDIR is under /var, a symlink to /private/var, so
# `mktemp -d` returns /var/... while git and realpath-based code resolve the
# same dir to /private/var/... Any prefix match between the two spellings
# fails, silently dropping rows or refusing valid paths (#932).
WORKDIR="$(command mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && command pwd -P)"
trap 'command rm -rf "$WORKDIR"' EXIT

# --- Corpus 1: the whole librarian-proper tree ------------------------------
# One path per line; excludes the containers/ submodule (separate repo), VCS
# metadata, and python bytecode caches. Only searches dirs that exist (a missing
# optional dir like docs/ must not fail the find under `set -e`).
REPO_CORPUS="$WORKDIR/repo-corpus.txt"
search_dirs=()
for d in plugins tests bin .github docs; do
    [ -d "$REPO_ROOT/$d" ] && search_dirs+=("$REPO_ROOT/$d")
done
command find "${search_dirs[@]}" -type f 2>/dev/null |
    command grep -vE '__pycache__|/\.git/' | command sort >"$REPO_CORPUS" || true

# --- Corpus 2: the synthetic per-category / per-language fixture library -----
# Written under $WORKDIR/fixtures so paths are stable and self-contained. Each
# file targets branches the repo tree may not exercise. Keep additions here as
# new categories/languages are added to any tool.
FIXDIR="$WORKDIR/fixtures"
command mkdir -p "$FIXDIR/src" "$FIXDIR/tests" "$FIXDIR/docs"

# Rust — pub-fn docs, cfg(test), pub struct.
command cat >"$FIXDIR/src/lib.rs" <<'EOF'
pub fn undocumented_rust() {}
/// documented
pub fn documented_rust() {}
pub struct Thing {}
pub enum Kind {}
#[cfg(test)]
mod tests {}
EOF

# Kotlin / Java — System.out debug, public method, exported fun.
command cat >"$FIXDIR/src/App.kt" <<'EOF'
fun main() {
    System.out.println("dbg")
    System.err.println("err")
}
public fun exported(): Int { return 0 }
public void thing() {}
EOF

# Ruby — empty rescue (multi-line lookahead), binding.pry debug, def.
command cat >"$FIXDIR/src/svc.rb" <<'EOF'
def risky
  begin
    x
  rescue
  end
end
binding.pry
def documented_rb
end
EOF

# Go — empty handler, swallowed err, exported func, fmt.Println debug.
command cat >"$FIXDIR/src/main.go" <<'EOF'
package main

// Exported does things.
func Exported() {}

func Undocumented() {}

func handle() {
    fmt.Println("dbg")
    if err != nil {}
}
EOF

# Shell (#598) — TODO marker, swallowed error (`|| true`), function def, and a
# nested tests/ sibling so the missing-test-file discovery arms are exercised in
# both directions (one source covered by convention, one orphan) rather than
# only the flagged one. The fixture library previously had no .sh at all.
command cat >"$FIXDIR/src/tool.sh" <<'EOF'
#!/usr/bin/env bash
# TODO: implement
run_thing() {
    do_work || true
}
run_thing
EOF
command cat >"$FIXDIR/src/orphan.sh" <<'EOF'
#!/usr/bin/env bash
echo orphaned
EOF
command cat >"$FIXDIR/tests/validate-tool.sh" <<'EOF'
#!/usr/bin/env bash
# exercises tool.sh
EOF

# jsx/tsx — arrow empty body, console debug, export const.
command cat >"$FIXDIR/src/comp.jsx" <<'EOF'
export const X = () => {}
console.log("dbg")
const spaced = () => { }
EOF

# Python — empty except with a blank line, logging exemption, breakpoint, def.
command cat >"$FIXDIR/src/health.py" <<'EOF'
try:
    x()
except Exception:

    pass
try:
    y()
except:
    log.info("handled")
def public_fn():
    print("debug")
    breakpoint()
EOF

# Markdown — deprecated links, anchors, dates, versions, code blocks with and
# without a .sh reference (the set -e abort regression), multibyte evidence.
command cat >"$FIXDIR/docs/guide.md" <<'EOF'
# A Heading — with an em-dash

See [one](missing1.md) and [two](missing2.md) here.
[anchor](#a-heading-with-an-em-dash) and [bad](#nope)
Link [dead](https://old.example.com/deprecated/path).

```bash
echo no script on this line
./real-script.sh arg
```

```python
import os
from madeup.module import thing
```

Date 2020-01-15 is stale. Version v9.9.9 to verify.
A very long line with unicode — dashes ————————————————————————————————— and more text past eighty bytes to exercise evidence truncation on multibyte input aaaaaaa.
EOF

# check-ai-config — an agent md with a bad model + wildcard tools; a workflow.js.
command mkdir -p "$FIXDIR/plugins/x/agents/foo" "$FIXDIR/plugins/x/skills/bar"
command cat >"$FIXDIR/plugins/x/agents/foo/foo.md" <<'EOF'
---
name: foo
description: an agent
tools: "*"
model: not_a_real_model
---
body
EOF
command cat >"$FIXDIR/plugins/x/skills/bar/workflow.js" <<'EOF'
const ref = `${f}:${l}:${c}`;
agentType: 'bare'
npm install
EOF

# Secrets fixture — single-quoted x/2/7 secret, yaml.load with/without Loader.
command cat >"$FIXDIR/src/sec.py" <<'EOF'
api_key = 'sk2live7value_xx'
loaded = yaml.load(payload)
safe = yaml.load(payload, Loader=SafeLoader)
digest = hashlib.md5(x)
# md5( in a comment
EOF

# Trailing-colon fixtures (#549) — the regression corpus for the `IFS=:` defect.
#
# `grep -n | while IFS=: read -r line_num content` strips ONE trailing IFS
# delimiter, so evidence for a line ending in a bare colon lost that colon.
# Seven ports papered over it with a `_bash_read_content` shim that reproduced
# the strip in Python, which is why this gate stayed green through two live
# occurrences (#397, PR #547) — both "fixed" by rewording the offending doc line.
#
# Two properties make these fixtures actually bite, and both are easy to lose:
#
#   1. EXACTLY ONE COLON, AT THE END. `read` strips one trailing delimiter, not
#      all of them: `x:` loses it, but `x::` and `a:b:c:` come back intact. A
#      probe line with an interior colon makes the defect look nonexistent.
#   2. THE LINE MUST MATCH THE TOOL'S OWN REGEX. Fixtures are shared across all
#      tools, but a tool only reads lines its grep selects — a generic markdown
#      line exercises exactly one of the twelve. Each line below is shaped to a
#      specific detector; keep them that way when editing.
#
# Verified non-vacuous against a pre-fix plugins tree: the differential fails for
# check-docs-staleness and check-security (`…v1.2.3` vs `…v1.2.3:`), and
# test_trailing_colon_preserved below fails for six more — check-code-health,
# check-docs-missing-api, loop-make-it-work and loop-make-it-tested on BOTH the
# bash and python side, which is the shimmed class the differential is
# structurally blind to.
command cat >"$FIXDIR/docs/trailing-colon.md" <<'EOF'
Install release v1.2.3:
EOF
# The AWS-key fixture is assembled from two halves rather than written as a
# literal. `AKIA[0-9A-Z]{16}` is exactly what check-security and
# loop-make-it-secure detect — and also what the gitleaks pre-commit hook
# detects, which would block every commit touching this file. Splitting the
# literal keeps the source clean while the file ON DISK is byte-identical, so
# the detectors still fire. Do not re-inline it.
AKIA_FIXTURE="AKIA""ABCDEFGHIJKLMNOP"
# The third line carries TRAILING SPACES on purpose — see test_trailing_ws_
# preserved below. It is written via printf rather than a heredoc so the
# whitespace survives editors and lint that would strip it from a repo file.
{
    printf 'AWS_KEY = %s:\n' "$AKIA_FIXTURE"
    printf '%s\n' 'x = 1  # TODO refactor:'
    printf '%s\n' 'def undocumented_trailing():'
    printf '%s\n' 'y = 2  # TODO keep-my-spaces   '
} >"$FIXDIR/src/trailing_colon.py"

FIX_CORPUS="$WORKDIR/fixture-corpus.txt"
command find "$FIXDIR" -type f 2>/dev/null | command sort >"$FIX_CORPUS"

# --- Corpus 3: the PATH-SHAPE corpus ----------------------------------------
# Corpus 2 above varies CONTENT across ordinary, well-behaved paths. This one
# does the opposite: every file gets BYTE-IDENTICAL content, and only the PATH
# varies. That is what makes a divergence here attributable — if the two impls
# disagree on two files holding the same bytes, the disagreement is in path
# classification (is_test_file and its neighbours), not in a detector regex.
#
# The shapes are chosen from is_test_file's own arms plus the awkward spellings
# #867 named. Adding one is a one-line `shape_file` call; keep the near-miss
# entries, which pin the OPPOSITE direction (#568) — contest.py must NOT be
# treated as a test just because "test" appears in the basename.
SHAPEDIR="$WORKDIR/shapes"

# shape_file RELPATH — create RELPATH under $SHAPEDIR with the shared probe
# content. Content is chosen to trip several categories at once (lifecycle's
# unreaped-subprocess and terminate-without-kill, code-health's TODO marker and
# debug-statement) so a path-classification divergence shows up in more than one
# tool. Parent dirs are created as needed; RELPATH may contain spaces.
shape_file() {
    command mkdir -p "$SHAPEDIR/$(command dirname "$1")"
    command cat >"$SHAPEDIR/$1" <<'EOF'
# TODO: shared probe content — identical in every path-shape fixture
import subprocess
proc = subprocess.Popen(["true"])
proc.terminate()
print("debug")
EOF
}

# Directory arms — a `tests`/`test`/`__tests__`/`spec` SEGMENT anywhere.
shape_file "src/tests/helper.py"
shape_file "lib/test/util.py"
shape_file "src/vendor/__tests__/helper.py"
shape_file "src/spec/runner.py"
# __pycache__ is an is_test_file directory arm too. The REPO corpus filters it
# out by construction (`grep -vE '__pycache__'` above), so this corpus is the
# only place the arm is reachable at all.
shape_file "src/__pycache__/mod.py"

# The #836 shape: a directory whose NAME begins test_ but which is NOT a test
# segment. A name arm spelled as a path glob (`*/test_*.*`) wrongly matches it
# and silences real source beneath. Zero such directories exist in the tree
# (`git ls-files | grep -c "/test_[^/]*/"` == 0), which is why the repo corpus
# could never ask this question.
shape_file "src/test_helpers/production.py"
# The same near-miss one segment over: `__tests___helpers` STARTS WITH the
# `__tests__` arm's text but is a different segment, so it must NOT classify as
# a test. Covered by the `near:__tests__-dir` arm in SHAPE_ARMS below, which is
# what keeps this fixture from becoming an unasserted decoration.
shape_file "src/__tests___helpers/production.py"

# Basename arms — these SHOULD classify as tests, wherever they sit.
shape_file "src/test_util.py"
shape_file "src/util_test.py"
shape_file "src/util_spec.py"
shape_file "src/a.test.py"
shape_file "src/a.spec.py"

# NEAR MISSES — these must NOT classify as tests. A bare *test* glob wrongly
# matches all three; segment/basename anchoring is what keeps them scanned.
shape_file "src/contest.py"
shape_file "src/latest.py"
shape_file "src/attestation.py"
shape_file "src/protester.py"

# Basename tokenizer edges — hyphens and interior dots.
shape_file "src/my-mod.v2.py"
shape_file "src/.hidden.py"

# UPPERCASE extension. Zero files in the tracked tree have one
# (`git ls-files | grep -cE '\.[A-Z]+$'` == 0), so case-dispatch divergence on
# the extension is unreachable from the repo corpus.
shape_file "src/Legacy.PY"

# A path containing a SPACE. Zero in the tracked tree. Representable here
# because the corpus file is NEWLINE-delimited — a path containing a NEWLINE is
# NOT representable, so never add one.
shape_file "src/my dir/a.py"

SHAPE_CORPUS="$WORKDIR/shape-corpus.txt"
command find "$SHAPEDIR" -type f 2>/dev/null | command sort >"$SHAPE_CORPUS"

# --- Two-arg drift-detect fixtures ------------------------------------------
DRIFT_ACTUAL="$WORKDIR/drift-actual.txt"
DRIFT_PLANNED="$WORKDIR/drift-planned.txt"
command cat >"$DRIFT_PLANNED" <<'EOF'
src/a.py
src/b.py
lib/
dir/nested/deep.py
EOF
command cat >"$DRIFT_ACTUAL" <<'EOF'
src/a.py
lib/x.py
package-lock.json
Cargo.lock
tests/test_a.py
src/a_spec.py
dir/other.py
.gitignore
go.sum
EOF

# diff_tool SH_PATH CORPUS [CORPUS2] — assert bash and python emit byte-identical
# output over the given corpus/corpora. Sorts both (finding order is not part of
# the contract; set membership is).
CUR_LABEL=""
diff_one_arg() {
    local sh="$1" corpus="$2"
    local py="${sh%patterns.sh}patterns.py"
    local b p
    b="$(PATTERNS_FORCE_BASH=1 bash "$sh" "$corpus" 2>/dev/null | command sort)" || true
    p="$(python3 "$py" "$corpus" 2>/dev/null | command sort)" || true
    assert_equals "$b" "$p" \
        "$CUR_LABEL: bash and python emit identical findings
$(command diff <(printf '%s\n' "$b") <(printf '%s\n' "$p") | command head -40)"
}

# --- Drive: every single-arg tool over both corpora, drift-detect separately --

single_arg_tools() {
    command find "$PLUGINS_DIR" -type f -name 'patterns.sh' 2>/dev/null |
        command grep -v '/drift-detect/' | command sort
}

test_repo_corpus() {
    local sh
    while IFS= read -r sh; do
        [ -n "$sh" ] || continue
        CUR_LABEL="$(command basename "$(command dirname "$sh")") [repo tree]"
        diff_one_arg "$sh" "$REPO_CORPUS"
    done < <(single_arg_tools)
}

test_fixture_corpus() {
    local sh
    while IFS= read -r sh; do
        [ -n "$sh" ] || continue
        CUR_LABEL="$(command basename "$(command dirname "$sh")") [fixtures]"
        diff_one_arg "$sh" "$FIX_CORPUS"
    done < <(single_arg_tools)
}

test_shape_corpus() {
    local sh
    while IFS= read -r sh; do
        [ -n "$sh" ] || continue
        CUR_LABEL="$(command basename "$(command dirname "$sh")") [path shapes]"
        diff_one_arg "$sh" "$SHAPE_CORPUS"
    done < <(single_arg_tools)
}

test_drift_detect() {
    local sh="$PLUGINS_DIR/dev-core/skills/drift-detect/patterns.sh"
    local py="${sh%patterns.sh}patterns.py"
    [ -f "$sh" ] && [ -f "$py" ] || {
        skip_test "drift-detect not present"
        return 0
    }
    local b p
    b="$(PATTERNS_FORCE_BASH=1 bash "$sh" "$DRIFT_ACTUAL" "$DRIFT_PLANNED" 2>/dev/null | command sort)" || true
    p="$(python3 "$py" "$DRIFT_ACTUAL" "$DRIFT_PLANNED" 2>/dev/null | command sort)" || true
    assert_equals "$b" "$p" "drift-detect: bash and python emit identical findings
$(command diff <(printf '%s\n' "$b") <(printf '%s\n' "$p") | command head -40)"
}

# Corpus guards — a differential that silently diffs zero files is a false green.
test_corpora_non_empty() {
    assert_true "[ -s '$REPO_CORPUS' ]" "repo corpus is non-empty"
    assert_true "[ -s '$FIX_CORPUS' ]" "fixture corpus is non-empty"
    assert_true "[ -s '$SHAPE_CORPUS' ]" "path-shape corpus is non-empty"
}

# --- Path-shape coverage (#867) ---------------------------------------------
#
# The differential's first corpus can only ask about shapes the tree contains,
# and nothing in its output distinguishes "the runtimes agree everywhere" from
# "the runtimes were never asked the interesting question". These two functions
# split that concern by WHERE the zero occurs, and they fail differently on
# purpose:
#
#   * ZERO IN THE REPO TREE IS REPORTED, NEVER FAILED. Several arms are legitimately
#     at zero here today (that is the whole finding of #867), so failing on it
#     would make the gate unlandable and would assert a falsehood — the shape's
#     absence is a fact about this repo, not a defect. Printing it turns an
#     invisible gap into a readable one.
#   * ZERO IN THE SHAPE CORPUS IS A FAILURE. That corpus is purpose-built, so an
#     arm reaching zero there means a fixture stopped exercising the arm it was
#     written for — the same vacuity guard test_trailing_colon_preserved uses.
#
# SHAPE_ARMS: one "label<TAB>ERE" row per classification arm. Bash 3.2 has no
# associative arrays (CLAUDE.md), so this is a newline-delimited string. The
# regexes are POSIX ERE against a full path — no \s, \w or GNU-only spellings,
# since BSD grep reads those as literals (#679).
SHAPE_ARMS='seg:tests/	(^|/)tests/
seg:test/	(^|/)test/
seg:__tests__/	(^|/)__tests__/
seg:spec/	(^|/)spec/
seg:__pycache__/	(^|/)__pycache__/
dir:test_*/	/test_[^/]*/
base:test_*.*	/test_[^/]*\.[^/]*$
base:*_test.*	/[^/]*_test\.[^/]*$
base:*_spec.*	/[^/]*_spec\.[^/]*$
base:*.test.*	/[^/]*\.test\.[^/]*$
base:*.spec.*	/[^/]*\.spec\.[^/]*$
path:uppercase-ext	/[^/]*\.[A-Z][A-Z]*$
path:with-space	[/][^/]*[ ]
path:dotted-base	/[^/]*\.[^/.]*\.[^/.]*$
near:__tests__-dir	/__tests___[^/]*/
near:test-in-basename	/(contest|latest|attestation|protester)\.'

# count_arm CORPUS ERE — how many paths in CORPUS match ERE. `grep -c` on a
# FILE, never `grep -q` in a pipeline: under `pipefail`, `-q` exits on the first
# match, the writer takes SIGPIPE and the pipeline reports 141, inverting a
# successful match into a failure (#928/#932).
count_arm() {
    command grep -cE -- "$2" "$1" 2>/dev/null || true
}

# Prints the per-arm table AND asserts the table is not empty.
#
# The print is the point (it is what makes an absent shape readable), but a
# function dispatched through run_test that cannot fail always shows PASS, which
# is indistinguishable from a real check to anyone scanning the tally — the
# inert-gate shape this repo keeps filing issues about (#538/#571). So it also
# asserts that SHAPE_ARMS actually parsed: a mangled table (a tab lost to an
# editor, the quoting broken) would otherwise print a header and nothing else
# and still read as PASS.
report_path_shape_coverage() {
    local label ere n_repo n_shape note rows=0
    printf '    path-shape coverage (repo tree / shape corpus):\n'
    while IFS="$(printf '\t')" read -r label ere; do
        [ -n "$label" ] || continue
        # A row whose ERE is empty means the tab separator was lost; counting it
        # as a row would let a mangled table satisfy the assertion below.
        [ -n "$ere" ] || continue
        n_repo="$(count_arm "$REPO_CORPUS" "$ere")"
        n_shape="$(count_arm "$SHAPE_CORPUS" "$ere")"
        note=""
        [ "${n_repo:-0}" -eq 0 ] && note="   [absent from tree — synthetic only]"
        printf '      %-22s %6s / %-4s%s\n' "$label" "${n_repo:-0}" "${n_shape:-0}" "$note"
        rows=$((rows + 1))
    done <<EOF
$SHAPE_ARMS
EOF
    # Pinned at the current arm count, not at >0: a table that silently shrinks
    # is the failure mode worth catching, and >0 would tolerate losing all but
    # one row.
    assert_true "[ $rows -ge 16 ]" \
        "coverage table parsed every arm row (got $rows)"
}

# Every arm must be reached by the shape corpus, or that corpus is asserting
# less than it looks like it does.
test_shape_corpus_covers_every_arm() {
    local label ere n
    while IFS="$(printf '\t')" read -r label ere; do
        [ -n "$label" ] || continue
        n="$(count_arm "$SHAPE_CORPUS" "$ere")"
        assert_true "[ ${n:-0} -gt 0 ]" \
            "shape corpus exercises arm $label (matched ${n:-0} fixture paths)"
    done <<EOF
$SHAPE_ARMS
EOF
}

# NON-VACUITY: the shape corpus must be able to detect the very regression that
# shipped past this gate (#836/#867 acceptance criterion 3).
#
# Mutating a COPY under $WORKDIR, never the tracked scanner: rewrite
# check-lifecycle's basename arms back to the pre-#836 path-glob spelling, where
# a `case` glob's `*` crosses `/` and so `*/test_*.*` also matches the DIRECTORY
# src/test_helpers/. The mutant must then DISAGREE with the unmodified python
# primary over the shape corpus. If it agrees, the corpus lost the fixture that
# made it bite and test_shape_corpus above would be reporting a false green.
test_shape_corpus_is_non_vacuous() {
    local orig="$PLUGINS_DIR/review-audit/skills/check-lifecycle/patterns.sh"
    local py="$PLUGINS_DIR/review-audit/skills/check-lifecycle/patterns.py"
    [ -f "$orig" ] && [ -f "$py" ] || {
        skip_test "check-lifecycle not present"
        return 0
    }
    local mutant="$WORKDIR/mutant-patterns.sh"
    # The pre-#836 spelling: name arms matched against the whole path.
    command sed \
        -e 's|^    case "\${1##\*/}" in$|    case "$1" in|' \
        -e 's|^        test_\*\.\*) return 0 ;;$|        test_*.* \| */test_*.*) return 0 ;;|' \
        "$orig" >"$mutant"

    # Guard: if the sed stopped matching (the scanner was reformatted), the
    # "mutant" is a verbatim copy and the assertion below would pass vacuously
    # by comparing the FIXED impl against itself.
    assert_true "! command cmp -s '$orig' '$mutant'" \
        "mutation actually rewrote check-lifecycle's is_test_file"

    local m p m_shape p_shape
    m="$(PATTERNS_FORCE_BASH=1 bash "$mutant" "$SHAPE_CORPUS" 2>/dev/null | command sort)" || true
    p="$(python3 "$py" "$SHAPE_CORPUS" 2>/dev/null | command sort)" || true

    # The detection itself: the two must NOT agree. assert_equals asserts
    # sameness, so express the difference as a computed yes/no rather than
    # inverting it — a bare `[ "$m" != "$p" ]` inside an assert_true string
    # would hide both operands from the failure message.
    if [ "$m" != "$p" ]; then
        assert_equals "differ" "differ" \
            "shape corpus DETECTS the pre-#836 is_test_file regression (mutant != python)"
    else
        assert_equals "differ" "identical" \
            "shape corpus DETECTS the pre-#836 is_test_file regression (mutant != python)"
    fi

    # And name the specific shape that does the detecting, so a future edit that
    # drops src/test_helpers/ fails here with a readable reason rather than
    # quietly weakening the corpus. `grep -c` on a here-string, never `grep -q`
    # in a pipeline (#928).
    m_shape="$(printf '%s\n' "$m" | command grep -cF 'test_helpers/production.py')" || true
    p_shape="$(printf '%s\n' "$p" | command grep -cF 'test_helpers/production.py')" || true
    assert_equals "0" "${m_shape:-0}" \
        "mutant skips src/test_helpers/production.py (the #836 shape)"
    assert_true "[ ${p_shape:-0} -gt 0 ]" \
        "python still scans src/test_helpers/production.py (got ${p_shape:-0} rows)"
}

# Trailing colons survive into evidence, in BOTH impls (#549).
#
# The differential above cannot see this class of defect for the seven tools
# whose patterns.py carried `_bash_read_content`: that shim reproduced the bash
# strip in Python, so both sides agreed on mangled evidence and the diff was
# empty. Parity is necessary, not sufficient — this asserts the evidence is also
# CORRECT, which is the property #397 and PR #547 were each worked around
# instead of fixed.
# Evidence field (TSV column 4) that ends in one of these lost its colon. Only
# findings that QUOTE a fixture line are checked — `loop-make-it-tested` also
# emits "No test file found for trailing_colon.py", which correctly has no
# colon, so a blanket "every evidence ends in ':'" would be wrong.
truncated_evidence() {
    command awk -F'\t' -v akia="$AKIA_FIXTURE" '
        $4 ~ /v1\.2\.3$/ ||
        (index($4, akia) > 0 && index($4, akia) == length($4) - length(akia) + 1) ||
        $4 ~ /# TODO refactor$/ ||
        $4 ~ /undocumented_trailing\(\)$/ { print }
    '
}

TRAILING_TOOLS=0
test_trailing_colon_preserved() {
    local sh py n b p
    while IFS= read -r sh; do
        [ -n "$sh" ] || continue
        py="${sh%patterns.sh}patterns.py"
        n="$(command basename "$(command dirname "$sh")")"
        b="$(PATTERNS_FORCE_BASH=1 bash "$sh" "$FIX_CORPUS" 2>/dev/null |
            command grep 'trailing.colon' || true)"
        p="$(python3 "$py" "$FIX_CORPUS" 2>/dev/null |
            command grep 'trailing.colon' || true)"
        # Only tools whose detectors actually select a fixture line can speak to
        # this; the rest emit nothing and are covered by the differential alone.
        [ -n "$b" ] || continue
        TRAILING_TOOLS=$((TRAILING_TOOLS + 1))
        assert_equals "" "$(printf '%s\n' "$b" | truncated_evidence)" \
            "$n [bash]: evidence keeps the trailing colon"
        assert_equals "" "$(printf '%s\n' "$p" | truncated_evidence)" \
            "$n [python]: evidence keeps the trailing colon"
    done < <(single_arg_tools)
    # Guard: if the fixtures stop matching any detector's regex (an easy thing to
    # break while editing them) this test would pass by asserting nothing.
    assert_true "[ $TRAILING_TOOLS -ge 6 ]" \
        "fixtures still trigger at least 6 tools (got $TRAILING_TOOLS)"
}

# Trailing WHITESPACE survives into evidence too (#549 review catch).
#
# The colon fix replaced `while IFS=: read -r n content` with a bare
# `while read -r raw` + prefix strip. A bare `read` splits on the DEFAULT IFS,
# so it eats trailing spaces/tabs the old `IFS=:` form kept — a second,
# narrower evidence-mangling bug introduced by the fix for the first. The
# correct idiom is `IFS= read -r raw`, which suppresses all field splitting.
#
# Leading whitespace is NOT at risk and is deliberately not asserted: every line
# is `grep -n` output, so it begins with a line number, and `${raw#*:}` keeps
# everything after the first colon verbatim.
#
# The repo-tree corpus cannot catch this — real repo files are trailing-space
# stripped by lint, so only a purpose-built fixture exercises it.
#
# The fixture uses trailing SPACES only, and that is sufficient: the default IFS
# is space/tab/newline, and `read` trims any run of them identically, so a
# trailing tab is not a separate code path. The matcher below accepts `[ \t]+`
# so a future fixture may add tabs without needing to change it.
trailing_ws_evidence() {
    command awk -F'\t' '$4 ~ /keep-my-spaces[ \t]+$/ { print }'
}

WS_TOOLS=0
test_trailing_ws_preserved() {
    local sh py n b p
    while IFS= read -r sh; do
        [ -n "$sh" ] || continue
        py="${sh%patterns.sh}patterns.py"
        n="$(command basename "$(command dirname "$sh")")"
        b="$(PATTERNS_FORCE_BASH=1 bash "$sh" "$FIX_CORPUS" 2>/dev/null |
            command grep 'keep-my-spaces' || true)"
        p="$(python3 "$py" "$FIX_CORPUS" 2>/dev/null |
            command grep 'keep-my-spaces' || true)"
        [ -n "$p" ] || continue
        WS_TOOLS=$((WS_TOOLS + 1))
        # Python is the reference impl: it slices the line verbatim, so its
        # evidence keeps the spaces. Bash must match it.
        assert_true "[ -n \"\$(printf '%s\n' \"\$p\" | trailing_ws_evidence)\" ]" \
            "$n [python]: evidence keeps trailing whitespace"
        assert_true "[ -n \"\$(printf '%s\n' \"\$b\" | trailing_ws_evidence)\" ]" \
            "$n [bash]: evidence keeps trailing whitespace"
    done < <(single_arg_tools)
    # Same guard as test_trailing_colon_preserved: pinned just at the observed
    # count so an edit that narrows fixture matching fails rather than silently
    # shrinking coverage to a single tool.
    assert_true "[ $WS_TOOLS -ge 2 ]" \
        "trailing-whitespace fixture still triggers 2+ tools (got $WS_TOOLS)"
}

run_test test_corpora_non_empty "Differential corpora are non-empty (gate is not a no-op)"
run_test test_repo_corpus "Every tool: bash==python over the whole repo tree"
run_test test_fixture_corpus "Every tool: bash==python over the per-category fixtures"
run_test test_shape_corpus "Every tool: bash==python over the path-shape corpus (#867)"
run_test test_shape_corpus_covers_every_arm "Path-shape corpus reaches every classification arm (#867)"
run_test test_shape_corpus_is_non_vacuous "Path-shape corpus detects the pre-#836 is_test_file regression (#867)"
run_test report_path_shape_coverage "Path-shape coverage report — arms at zero in the real tree are visible (#867)"
run_test test_drift_detect "drift-detect: bash==python over actual/planned fixtures"
run_test test_trailing_colon_preserved "Trailing colons survive into evidence in both impls (#549)"
run_test test_trailing_ws_preserved "Trailing whitespace survives into evidence in both impls (#549)"

generate_report
