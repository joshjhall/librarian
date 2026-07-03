#!/usr/bin/env bash
# Bash portability guardrail (issue #17).
#
# The skill code tools and helper scripts must run on base macOS, whose stock
# /bin/bash is 3.2 (2007). A single script silently relying on a bash-4-only
# feature malfunctions there rather than failing loudly — exactly the trap #17
# closes. This gate greps librarian-proper `*.sh` for the bash-4+ constructs we
# forbid and fails with `file:line` so a regression is caught before it ships.
#
# Forbidden constructs (all bash-4+, unavailable in 3.2):
#   - `declare -A` / `local -A`      associative arrays
#   - `mapfile` / `readarray`        read-into-array builtins
#   - `declare -n` / `local -n`      namerefs
#   - `${v,,}` `${v^^}` `${v,}` `${v^}`  case-conversion expansions
#   - `;;&`                          case fallthrough
#
# Portable replacements: space-delimited string sets + `case` membership, and
# flat "<key>\ttab<value>" maps (see plugins/workflow/scripts/golem-gate-watch.sh
# for a worked example), `while IFS= read` loops instead of mapfile, and
# `tr '[:upper:]' '[:lower:]'` for case folding.
#
# Scope: `plugins/ tests/ bin/` only. The `containers/` submodule is a separate
# repo that deliberately requires bash 5 — out of scope here.
#
# Detection strips comments before matching (a `# ... declare -A ...` mention in
# prose or documentation is not usage) and skips the fixture heredoc in this file
# itself. Pure bash + coreutils + grep; no network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Shell portability (bash 3.2 clean) (#17)"

# Extended-regex alternation of the forbidden constructs. Written as fragments to
# keep each construct legible; note `local -A`/`declare -A` cover both scopes, and
# the parameter-expansion arm matches `${name,,}` / `${name^^}` / single-char too.
FORBIDDEN_RE='(declare|local)[[:space:]]+(-[A-Za-z]*A[A-Za-z]*)[[:space:]]'
FORBIDDEN_RE+='|(declare|local)[[:space:]]+(-[A-Za-z]*n[A-Za-z]*)[[:space:]]'
FORBIDDEN_RE+='|(^|[[:space:];|&])(mapfile|readarray)([[:space:]]|$)'
FORBIDDEN_RE+='|[$][{][A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^|,|\^)[}]'
FORBIDDEN_RE+='|;;&'

# List librarian-proper shell scripts (absolute paths, sorted). Excludes the
# containers/ submodule and this lint file itself (it carries the patterns as
# fixture/regex text, which are stripped/handled but need not self-scan).
list_shell_scripts() {
    command find "$REPO_ROOT/plugins" "$REPO_ROOT/tests" "$REPO_ROOT/bin" \
        -type f -name '*.sh' 2>/dev/null |
        command grep -vF "$SCRIPT_DIR/lint-shell-portability.sh" |
        command sort
}

# scan_file <path> — populate CUR_VIOLATIONS with `line N: <code>` per forbidden
# construct found (empty when clean). Comments are stripped first: everything
# from the first unquoted `#` is crude-removed by dropping ` #...` and `^#...`,
# which is sufficient because the forbidden tokens never legitimately share a
# line with a trailing comment that reintroduces them.
CUR_VIOLATIONS=""
scan_file() {
    local file="$1"
    CUR_VIOLATIONS=""
    local lineno=0 line code
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        # Strip a whole-line comment and any trailing ` # ...` comment. This is
        # deliberately conservative: it removes the common comment shapes so a
        # documentation mention of `declare -A` does not register as usage.
        code="$line"
        case "$code" in
            \#*) continue ;;
        esac
        code="${code%%[[:space:]]#*}"
        printf '%s\n' "$code" | command grep -qE "$FORBIDDEN_RE" || continue
        CUR_VIOLATIONS+="line ${lineno}: ${code#"${code%%[![:space:]]*}"}"$'\n'
    done <"$file"
}

# Per-file test body (reads CUR_FILE).
CUR_FILE=""
test_file_portable() {
    scan_file "$CUR_FILE"
    assert_equals "" "$CUR_VIOLATIONS" \
        "$(command basename "$CUR_FILE") must be bash-3.2 clean (no declare -A/mapfile/nameref/case-conv/;;&)"
}

# Negative case: scan_file's violation branch must actually fire on each
# forbidden construct, and must NOT fire on portable equivalents or on a comment
# that merely mentions a construct. Mirrors the two-branch coverage of
# tests/lint-action-pins.sh.
test_negative_case_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    # A quoted heredoc keeps every construct literal (no expansion). This lint
    # excludes itself from the corpus (see list_shell_scripts), so the forbidden
    # tokens appearing here in the fixture never self-flag. scan_file strips
    # trailing comments, so assertions match the CODE token (not a comment marker)
    # — a unique variable name per bad line makes each assertion unambiguous. The
    # trailing portable lines (prose comment, set-membership, tr-fold) must NOT
    # surface in the violations.
    command cat >"$tmp/bad.sh" <<'EOF'
#!/usr/bin/env bash
declare -A assoc_hit
local -A localassoc_hit
mapfile -t mapfile_hit <f
readarray -t readarray_hit <f
declare -n nameref_hit=x
lower_hit="${x,,}"
upper_hit="${x^^}"
case $x in a) : ;;& b) : ;; esac  # fallthru_hit_marker
# this comment mentions declare -A but is prose: commentprose_ok
okset=" "; case " $okset " in *" 1 "*) : ;; esac
okfold="$(printf %s "$x" | tr '[:upper:]' '[:lower:]')"
EOF

    scan_file "$tmp/bad.sh"

    assert_not_empty "$CUR_VIOLATIONS" "scan_file flags forbidden constructs (violation branch fires)"
    assert_contains "$CUR_VIOLATIONS" "assoc_hit" "declare -A is flagged"
    assert_contains "$CUR_VIOLATIONS" "localassoc_hit" "local -A is flagged"
    assert_contains "$CUR_VIOLATIONS" "mapfile_hit" "mapfile is flagged"
    assert_contains "$CUR_VIOLATIONS" "readarray_hit" "readarray is flagged"
    assert_contains "$CUR_VIOLATIONS" "nameref_hit" "declare -n nameref is flagged"
    assert_contains "$CUR_VIOLATIONS" "lower_hit" 'lowercase ${v,,} is flagged'
    assert_contains "$CUR_VIOLATIONS" "upper_hit" 'uppercase ${v^^} is flagged'
    assert_contains "$CUR_VIOLATIONS" ";;&" ';;& fallthrough is flagged'
    # Portable lines must NOT surface.
    assert_not_contains "$CUR_VIOLATIONS" "commentprose_ok" "A prose comment mentioning a construct is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" "okset" "A space-delimited set + case membership is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" "okfold" "tr-based case folding is NOT flagged"
}

# Discover the corpus.
scripts_list="$(list_shell_scripts)"

# Guard: the suite must actually inspect something. A gate that silently checks
# zero files (dir moved, find regressed) is worse than no gate.
test_corpus_non_empty() {
    assert_not_empty "$scripts_list" "At least one shell script must be found to lint"
}

run_test test_corpus_non_empty "Shell-script corpus is non-empty (gate is not a no-op)"
run_test test_negative_case_fires "scan_file flags every forbidden construct (violation path)"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    CUR_FILE="$f"
    run_test test_file_portable "${f#"$REPO_ROOT"/}: bash-3.2 clean"
done <<<"$scripts_list"

generate_report
