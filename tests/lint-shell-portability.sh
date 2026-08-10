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
# Check 2 — hardcoded core-utility paths (#443): a `/usr/bin/<tool>` or `/bin/<tool>`
# invocation is banned (it exits 127 where the tool lives elsewhere — macOS /bin,
# Homebrew git). Use the `command <tool>` builtin, which honors PATH while still
# bypassing shell functions/aliases. Allowed: the `#!/usr/bin/env bash` shebang
# and `/usr/bin/env` itself (env is the one tool with a stable path).
#
# Check 3 — GNU-only regex constructs (#679). BSD `grep`/`sed` (the macOS
# default) do not implement the GNU regex extensions, and the failure mode is
# what makes this worth a gate: they do NOT error, they silently MISMATCH.
#   - `\s` / `\S`   whitespace class  -> BSD reads a literal `s` / `S`
#   - `\w` / `\W`   word class        -> BSD reads a literal `w` / `W`
#   - `\|` in a BRE alternation       -> BSD reads a literal `|`
# A scanner pattern that silently stops matching emits zero findings and still
# exits 0, so the scan looks clean on macOS while seeing nothing — which is
# exactly how #679 went unnoticed (an indented `print(` was invisible, and a
# project's .claude/pre-review.yml parsed to empty).
# Portable replacements: `[[:space:]]`, `[[:alnum:]_]`, and `grep -E`/`sed -E`
# where alternation is native. See dev-core's shell-scripting skill.
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

# --- Hardcoded core-utility-path ban (#443) -------------------------------------
# A tool invoked by an absolute path (`/usr/bin/mv`, `/bin/cat`) is NOT portable:
# on macOS core utils live in /bin, /usr/bin/realpath is absent, and Homebrew git
# is at /opt/homebrew/bin/git — so under `set -euo pipefail` a wrong assumed path
# hard-crashes a script whose tool is present on PATH. The portable idiom is the
# `command` builtin (`command mv`), which honors PATH while still bypassing shell
# functions/aliases. This check bans a hardcoded `/usr/bin/<tool>` or `/bin/<tool>`
# invocation, allowing the two legitimate uses of those prefixes:
#   - the `#!/usr/bin/env bash` shebang (env is the ONE tool with a stable path),
#   - `/usr/bin/env` itself anywhere (used to run a command with a scrubbed env).
# Match a leading `/usr/bin/` or `/bin/` followed by ANY lowercase tool name.
# Guards on BOTH sides so only a real tool invocation matches:
#   - leading `[^A-Za-z0-9_./]` (or start) so /usr/local/bin/x, /opt/... and an
#     already-`command`'d name don't match;
#   - trailing `[^/A-Za-z0-9_.-]` (or end) so a deeper PROJECT PATH like
#     `$ROOT/bin/lib/release/x.sh` or `$sb/bin/release.sh` is NOT flagged — a tool
#     invocation is followed by whitespace / `)` / `|` / etc., never `/` or `.`.
# The one allowed tool, `env` (the `#!/usr/bin/env` shebang and `/usr/bin/env -i`
# exec-wrapper), is excluded PROCEDURALLY in scan_file_paths, not carved out of
# the regex — an in-regex `[a-df-z]` first-letter exclusion would silently also
# skip every other `e*` tool (echo, expr, eval, egrep …), a false-negative gap.
PATHLIT_RE='(^|[^A-Za-z0-9_./])/(usr/bin|bin)/([a-z][a-z0-9_-]*)([^/A-Za-z0-9_.-]|$)'

# scan_file_paths <path> — populate CUR_PATH_VIOLATIONS with `line N: <code>` for
# each hardcoded core-utility-path invocation. Shebang (line 1) and comment lines are
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
        # `env` is the one allowed tool (the `#!/usr/bin/env` shebang handled by
        # the line-1 skip above, and the `/usr/bin/env -i` exec-wrapper). Blank out
        # every `/usr/bin/env` and `/bin/env` occurrence (with its following
        # separator so the boundary still matches) BEFORE the scan, so a line whose
        # only absolute-path token is `env` no longer matches — while a line that
        # ALSO invokes a real tool (`env … | /usr/bin/tr …`) still flags.
        scan_code="$(printf '%s\n' "$code" | command sed -E 's#(^|[^A-Za-z0-9_./])/(usr/bin|bin)/env([^/A-Za-z0-9_.-]|$)#\1 \3#g')"
        printf '%s\n' "$scan_code" | command grep -qE "$PATHLIT_RE" || continue
        CUR_PATH_VIOLATIONS+="line ${lineno}: ${code#"${code%%[![:space:]]*}"}"$'\n'
    done <"$file"
}

# --- GNU-only regex ban (#679) --------------------------------------------------
# `\s`/`\S`, `\w`/`\W`, and BRE `\|` are GNU regex extensions. BSD grep/sed read
# them as literals, so a pattern using them silently stops matching on macOS
# rather than erroring — a scanner then reports zero findings and exits 0.
#
# SCOPED TO REGEX-BEARING LINES, on purpose. A bare repo-wide grep for `\s` would
# also flag the two places where such a sequence is fixture DATA rather than a
# shell pattern — a Python `re.search(r"^\s*…")` inside a heredoc
# (validate-python-ports.sh) and a JS `console.log("…\\s…")` string
# (validate-pre-review-gates.sh). Those are payloads handed to another language,
# where `\s` is correct and must stay. They cannot carry a `lint-allow-` marker
# either: both sit inside quoted heredocs, where an added comment would corrupt
# the fixture the assertions depend on.
#
# So a line is only inspected when it actually invokes grep/sed/awk. That keeps
# the check aimed at shell regexes and lets the fixtures alone WITHOUT an
# exclusion list that would drift as tests move (and without carving the pattern
# itself, per the `PATHLIT_RE` precedent above).
GNURE_TOOL_RE='(^|[^A-Za-z0-9_-])(grep|egrep|fgrep|sed|awk)([^A-Za-z0-9_-]|$)'
GNURE_BAD_RE='\\[sSwW]|\\\|'
# `grep -P` (PCRE) is banned outright and needs no regex-bearing scoping: it is a
# GNU BUILD OPTION, absent from BSD grep entirely and from some Linux builds,
# where it exits 2 and the pipeline silently yields nothing. Matched separately
# because the flag is the violation — the pattern beside it may be perfectly
# portable. Written to catch `-P` both standalone and bundled (`-oP`).
GNUP_FLAG_RE='(^|[^A-Za-z0-9_-])(grep|egrep|zgrep)([[:space:]]+-[A-Za-z]*P([[:space:]]|$))'

# scan_file_gnu_regex <path> — populate CUR_GNURE_VIOLATIONS with `line N: <code>`
# for each GNU-only regex construct on a line that invokes grep/sed/awk.
CUR_GNURE_VIOLATIONS=""
scan_file_gnu_regex() {
    local file="$1"
    CUR_GNURE_VIOLATIONS=""
    local lineno=0 line code
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        code="$line"
        case "$code" in
            \#*) continue ;;
        esac
        # An explicit `# lint-allow-gnu-regex: <reason>` marker exempts a line
        # where a GNU construct is deliberate and the script is known GNU-only.
        # The reason is REQUIRED and enforced, not merely requested: a bare
        # `lint-allow-gnu-regex:` with nothing after the colon does NOT exempt,
        # so an exemption cannot be taken silently. `*[![:space:]]*` demands at
        # least one non-whitespace character in the tail.
        case "$line" in
            *"lint-allow-gnu-regex:"*[![:space:]]*) continue ;;
        esac
        code="${code%%[[:space:]]#*}"
        # Cheap bash prefilter before any subprocess. The overwhelming majority
        # of lines contain no backslash at all, and this scan runs over the whole
        # corpus on every pre-push — forking two greps per line made the gate
        # take minutes. `case` is a builtin, so the greps below now run only on
        # the handful of candidate lines.
        case "$code" in
            *'\'* | *-*P*) ;;
            *) continue ;;
        esac
        # `grep -P` is flagged on its own — the FLAG is the violation, so this
        # arm is deliberately not gated on the regex-bearing scoping below.
        if printf '%s\n' "$code" | command grep -qE "$GNUP_FLAG_RE"; then
            CUR_GNURE_VIOLATIONS+="line ${lineno}: ${code#"${code%%[![:space:]]*}"}"$'\n'
            continue
        fi
        # Only regex-bearing lines (see the scoping rationale above).
        printf '%s\n' "$code" | command grep -qE "$GNURE_TOOL_RE" || continue
        printf '%s\n' "$code" | command grep -qE "$GNURE_BAD_RE" || continue
        CUR_GNURE_VIOLATIONS+="line ${lineno}: ${code#"${code%%[![:space:]]*}"}"$'\n'
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

# Per-file test body for the GNU-only regex ban (reads CUR_FILE).
test_file_no_gnu_regex() {
    scan_file_gnu_regex "$CUR_FILE"
    assert_equals "" "$CUR_GNURE_VIOLATIONS" \
        "$(command basename "$CUR_FILE") must use POSIX classes ([[:space:]], [[:alnum:]_]) and -E alternation, not GNU \\s/\\w/\\| (#679)"
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
echohit="$(/bin/echo hi)"
exprhit="$(/usr/bin/expr 1 + 1)"
okcommand="$(command mv a b)"
okenv="$(/usr/bin/env -i sh -c :)"
okenvthentool="$(/usr/bin/env -i sh)"
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
    # An `e*`-named tool must still be flagged (the exemption is `env` ALONE, not
    # every tool starting with `e` — regression guard for the #443-review gap).
    assert_contains "$CUR_PATH_VIOLATIONS" "echohit" "/bin/echo is flagged (not exempted as an e* tool)"
    assert_contains "$CUR_PATH_VIOLATIONS" "exprhit" "/usr/bin/expr is flagged (not exempted as an e* tool)"
    # Portable / allowed forms must NOT surface.
    assert_not_contains "$CUR_PATH_VIOLATIONS" "okcommand" "command <tool> is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "okenv" "/usr/bin/env is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "oklocal" "/usr/local/bin/<tool> is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "okprojpath" "a deeper /bin/lib/... project path is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "okprojscript" "a /bin/<name>.sh project script path is NOT flagged"
    assert_not_contains "$CUR_PATH_VIOLATIONS" "commentpath_ok" "A prose comment naming an absolute path is NOT flagged"
}

# Negative case for the GNU-only regex ban: scan_file_gnu_regex must fire on each
# construct when a regex tool is invoked, and must NOT fire on the POSIX
# equivalents, on prose, on an allow-marked line, or on a `\s` that is payload for
# ANOTHER language rather than a shell pattern (the fixture case the scoping
# exists for — see the rationale above scan_file_gnu_regex).
test_negative_case_gnu_regex_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/gnure.sh" <<'EOF'
#!/usr/bin/env bash
sgrep_hit="$(grep -nE '^\s*print\(' f)"
wgrep_hit="$(grep -nE '^\w+\(\)' f)"
altsed_hit="$(sed 's/^\(a\|b\)//' f)"
capS_hit="$(grep -E '\S+' f)"
capW_hit="$(grep -E '\W+' f)"
awk_hit="$(awk '/^\s*x/ {print}' f)"
pcre_hit="$(grep -P 'a+' f)"
pcrebundled_hit="$(grep -oP 'a+' f)"
okspace="$(grep -nE '^[[:space:]]*print\(' f)"
okword="$(grep -nE '^[[:alnum:]_]+\(\)' f)"
okalt="$(sed -E 's/^(a|b)//' f)"
okmarked="$(grep -E '^\s*x' f)"  # lint-allow-gnu-regex: GNU-only helper
bareMarker_hit="$(grep -E '^\s*y' f)"  # lint-allow-gnu-regex:
okpayload="a python string r\"^\s*console\." handed to another language"
# a prose comment naming \s and \w and \| is commentgnu_ok
EOF

    # The whitespace-only-reason fixture is appended with printf, NOT written in
    # the heredoc above: its trailing spaces are the whole point, and a heredoc
    # line ending in whitespace is silently stripped by formatters/editors —
    # leaving a fixture byte-identical to the bare-marker one, which would test
    # nothing while looking like it did.
    command printf '%s\n' \
        "wsMarker_hit=\"\$(grep -E '^\\s*z' f)\"  # lint-allow-gnu-regex:   " \
        >>"$tmp/gnure.sh"

    scan_file_gnu_regex "$tmp/gnure.sh"

    assert_not_empty "$CUR_GNURE_VIOLATIONS" "scan_file_gnu_regex flags GNU constructs (violation branch fires)"
    assert_contains "$CUR_GNURE_VIOLATIONS" "sgrep_hit" '\s in a grep pattern is flagged'
    assert_contains "$CUR_GNURE_VIOLATIONS" "wgrep_hit" '\w in a grep pattern is flagged'
    assert_contains "$CUR_GNURE_VIOLATIONS" "altsed_hit" '\| BRE alternation in sed is flagged'
    assert_contains "$CUR_GNURE_VIOLATIONS" "capS_hit" '\S is flagged'
    assert_contains "$CUR_GNURE_VIOLATIONS" "capW_hit" '\W is flagged'
    assert_contains "$CUR_GNURE_VIOLATIONS" "awk_hit" '\s in an awk pattern is flagged'
    # `grep -P` is flagged on the FLAG alone — note both patterns above are
    # portable EREs, so only the PCRE mode selection can be what fires here.
    assert_contains "$CUR_GNURE_VIOLATIONS" "pcre_hit" 'grep -P (PCRE mode) is flagged'
    assert_contains "$CUR_GNURE_VIOLATIONS" "pcrebundled_hit" 'grep -oP (bundled PCRE flag) is flagged'
    # POSIX / allowed forms must NOT surface.
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "okspace" '[[:space:]] is NOT flagged'
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "okword" '[[:alnum:]_] is NOT flagged'
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "okalt" 'sed -E (a|b) alternation is NOT flagged'
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "okmarked" 'a lint-allow-gnu-regex line is NOT flagged'
    # The reason is enforced, not just documented: a marker with an empty tail
    # must NOT buy an exemption, or the escape hatch becomes a silent one.
    assert_contains "$CUR_GNURE_VIOLATIONS" "bareMarker_hit" 'a REASONLESS lint-allow-gnu-regex marker does NOT exempt'
    assert_contains "$CUR_GNURE_VIOLATIONS" "wsMarker_hit" 'a whitespace-only reason does NOT exempt'
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "okpayload" 'a non-shell regex payload (no grep/sed/awk) is NOT flagged'
    assert_not_contains "$CUR_GNURE_VIOLATIONS" "commentgnu_ok" "A prose comment naming the constructs is NOT flagged"
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
run_test test_negative_case_gnu_regex_fires "scan_file_gnu_regex flags GNU-only regex constructs (#679)"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    CUR_FILE="$f"
    run_test test_file_portable "${f#"$REPO_ROOT"/}: bash-3.2 clean"
    run_test test_file_no_hardcoded_paths "${f#"$REPO_ROOT"/}: no hardcoded core-utility paths (#443)"
    run_test test_file_no_gnu_regex "${f#"$REPO_ROOT"/}: no GNU-only regex constructs (#679)"
done <<<"$scripts_list"

generate_report
