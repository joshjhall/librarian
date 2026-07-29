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
#      and
#   2. a per-category / per-language FIXTURE LIBRARY (fixtures/ below) — synthetic
#      files that exercise branches the repo itself does not contain (Rust, Kotlin,
#      empty handlers, multibyte evidence, set -e edge cases, …).
#
# Any byte difference between the two implementations is a divergence and fails
# the gate: the two must be equivalent, full stop. drift-detect (the two-arg
# outlier) is diffed with its own actual/planned fixture pair.
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

WORKDIR="$(command mktemp -d)"
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
    assert_true "[ $WS_TOOLS -ge 1 ]" \
        "trailing-whitespace fixture still triggers a tool (got $WS_TOOLS)"
}

run_test test_corpora_non_empty "Differential corpora are non-empty (gate is not a no-op)"
run_test test_repo_corpus "Every tool: bash==python over the whole repo tree"
run_test test_fixture_corpus "Every tool: bash==python over the per-category fixtures"
run_test test_drift_detect "drift-detect: bash==python over actual/planned fixtures"
run_test test_trailing_colon_preserved "Trailing colons survive into evidence in both impls (#549)"
run_test test_trailing_ws_preserved "Trailing whitespace survives into evidence in both impls (#549)"

generate_report
