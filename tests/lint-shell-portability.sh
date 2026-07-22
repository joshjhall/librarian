#!/usr/bin/env bash
# Bash portability guardrail (issues #17, #443).
#
# The skill code tools and helper scripts must run on base macOS, whose stock
# /bin/bash is 3.2 (2007) and whose core utilities live in /bin, not /usr/bin. A
# script silently relying on a bash-4-only feature — or on a hardcoded tool path
# that is wrong on this host — malfunctions there rather than failing loudly. This
# gate greps librarian-proper `*.sh` for both traps and fails with `file:line` so
# a regression is caught before it ships.
#
# Check 1 — forbidden bash-4+ constructs (#17), all unavailable in 3.2:
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
# Check 2 — hardcoded coreutil paths (#443): a `/usr/bin/<tool>` or `/bin/<tool>`
# invocation is banned (it exits 127 where the tool lives elsewhere — macOS /bin,
# Homebrew git). Use the `command <tool>` builtin, which honors PATH while still
# bypassing shell functions/aliases. Allowed: the `#!/usr/bin/env bash` shebang
# and `/usr/bin/env` itself (env is the one tool with a stable path).
#
# Scope: `plugins/ tests/ bin/` only. The `containers/` submodule is a separate
# repo that deliberately requires bash 5 — out of scope here.
#
# Detection strips comments before matching (a `# ... declare -A ...` or
# `# ... /usr/bin/rm ...` mention in prose is not usage) and skips the fixture
# heredocs in this file itself. Pure bash + coreutils + grep; no network.

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

# --- Hardcoded coreutil-path ban (#443) -------------------------------------
# A tool invoked by an absolute path (`/usr/bin/mv`, `/bin/cat`) is NOT portable:
# on macOS core utils live in /bin, /usr/bin/realpath is absent, and Homebrew git
# is at /opt/homebrew/bin/git — so under `set -euo pipefail` a wrong assumed path
# hard-crashes a script whose tool is present on PATH. The portable idiom is the
# `command` builtin (`command mv`), which honors PATH while still bypassing shell
# functions/aliases. This check bans a hardcoded `/usr/bin/<tool>` or `/bin/<tool>`
# invocation, allowing the two legitimate uses of those prefixes:
#   - the `#!/usr/bin/env bash` shebang (env is the ONE tool with a stable path),
#   - `/usr/bin/env` itself anywhere (used to run a command with a scrubbed env).
# Match a leading `/usr/bin/` or `/bin/` followed by a lowercase tool name that is
# NOT `env`. Guards on BOTH sides so only a real tool invocation matches:
#   - leading `[^A-Za-z0-9_./]` (or start) so /usr/local/bin/x, /opt/... and an
#     already-`command`'d name don't match;
#   - trailing `[^/A-Za-z0-9_.-]` (or end) so a deeper PROJECT PATH like
#     `$ROOT/bin/lib/release/x.sh` or `$sb/bin/release.sh` is NOT flagged — a tool
#     invocation is followed by whitespace / `)` / `|` / etc., never `/` or `.`.
PATHLIT_RE='(^|[^A-Za-z0-9_./])/(usr/bin|bin)/(env[A-Za-z0-9_-]|[a-df-z][a-z0-9_-]*)([^/A-Za-z0-9_.-]|$)'

# scan_file_paths <path> — populate CUR_PATH_VIOLATIONS with `line N: <code>` for
# each hardcoded coreutil-path invocation. Shebang (line 1) and comment lines are
# skipped, matching scan_file's comment handling, so a doc mention of `/usr/bin/x`
# does not register.
CUR_PATH_VIOLATIONS=""
scan_file_paths() {
    local file="$1"
    CUR_PATH_VIOLATIONS=""
    local lineno=0 line code
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        [ "$lineno" -eq 1 ] && continue # shebang
        code="$line"
        case "$code" in
            \#*) continue ;;
        esac
        # An explicit `# lint-allow-path: <reason>` marker exempts a line where an
        # absolute tool path is deliberate — e.g. a generated stub that must run
        # under a stripped PATH (where `command <tool>` cannot resolve). The
        # marker must carry a reason so the exemption is justified, not silent.
        case "$line" in
            *"lint-allow-path:"*) continue ;;
        esac
        code="${code%%[[:space:]]#*}"
        printf '%s\n' "$code" | command grep -qE "$PATHLIT_RE" || continue
        CUR_PATH_VIOLATIONS+="line ${lineno}: ${code#"${code%%[![:space:]]*}"}"$'\n'
    done <"$file"
}

# Per-file test body (reads CUR_FILE).
CUR_FILE=""
test_file_portable() {
    scan_file "$CUR_FILE"
    assert_equals "" "$CUR_VIOLATIONS" \
        "$(command basename "$CUR_FILE") must be bash-3.2 clean (no declare -A/mapfile/nameref/case-conv/;;&)"
}

# Per-file test body for the hardcoded-path ban (reads CUR_FILE).
test_file_no_hardcoded_paths() {
    scan_file_paths "$CUR_FILE"
    assert_equals "" "$CUR_PATH_VIOLATIONS" \
        "$(command basename "$CUR_FILE") must invoke coreutils via \`command <tool>\`, not a hardcoded /usr/bin//bin path (#443)"
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

# Negative case for the hardcoded-path ban: scan_file_paths must fire on a
# hardcoded /usr/bin//bin invocation and must NOT fire on the portable
# `command <tool>` form, the env shebang, /usr/bin/env, /usr/local/bin, or a
# prose comment mentioning an absolute path.
test_negative_case_paths_fire() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/paths.sh" <<'EOF'
#!/usr/bin/env bash
usrbin_hit="$(/usr/bin/mv a b)"
binhit="$(/bin/cat f)"
githit="$(/usr/bin/git status)"
okcommand="$(command mv a b)"
okenv="$(/usr/bin/env -i sh -c :)"
oklocal="$(/usr/local/bin/rm x)"
okprojpath="$(source "$ROOT"/bin/lib/release/util.sh)"
okprojscript="$(bash "$sb"/bin/release.sh patch)"
# a prose comment naming /usr/bin/rm is commentpath_ok
EOF

    scan_file_paths "$tmp/paths.sh"

    assert_not_empty "$CUR_PATH_VIOLATIONS" "scan_file_paths flags hardcoded paths (violation branch fires)"
    assert_contains "$CUR_PATH_VIOLATIONS" "usrbin_hit" "/usr/bin/mv is flagged"
    assert_contains "$CUR_PATH_VIOLATIONS" "binhit" "/bin/cat is flagged"
    assert_contains "$CUR_PATH_VIOLATIONS" "githit" "/usr/bin/git is flagged"
    # Portable / allowed forms must NOT surface.
    assert_not_contains "$CUR_PATH_VIOLATIONS" "okcommand" "command <tool> is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "okenv" "/usr/bin/env is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "oklocal" "/usr/local/bin/<tool> is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "okprojpath" "a deeper /bin/lib/... project path is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "okprojscript" "a /bin/<name>.sh project script path is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "commentpath_ok" "A prose comment naming an absolute path is NOT flagged"
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
run_test test_negative_case_paths_fire "scan_file_paths flags hardcoded /usr/bin//bin paths (#443)"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    CUR_FILE="$f"
    run_test test_file_portable "${f#"$REPO_ROOT"/}: bash-3.2 clean"
    run_test test_file_no_hardcoded_paths "${f#"$REPO_ROOT"/}: no hardcoded coreutil paths (#443)"
done <<<"$scripts_list"

generate_report
