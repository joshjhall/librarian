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

WORKDIR="$(/usr/bin/mktemp -d)"
trap '/usr/bin/rm -rf "$WORKDIR"' EXIT

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

run_test test_corpora_non_empty "Differential corpora are non-empty (gate is not a no-op)"
run_test test_repo_corpus "Every tool: bash==python over the whole repo tree"
run_test test_fixture_corpus "Every tool: bash==python over the per-category fixtures"
run_test test_drift_detect "drift-detect: bash==python over actual/planned fixtures"

generate_report
