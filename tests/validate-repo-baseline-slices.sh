#!/usr/bin/env bash
# Conformance gate for the repo-baseline language slices (#1211).
#
# dev-core's repo-baseline skill defines a slice contract: every
# languages/<lang>.md must carry a fixed list of `##` headings, in order, so the
# audit and scaffold tooling can read any slice generically. The list lives in
# ONE place — between the `slice-contract:required-headings` markers in
# slice-contract.md — and this gate parses it from there rather than keeping a
# copy, so editing the contract changes the gate and there is nothing to drift.
#
# Fails closed on a vacuous corpus: zero parsed headings (markers moved or
# renamed) or zero slices on disk is a FAILURE, not a clean pass — a gate that
# checks nothing must not report that it found nothing wrong.
#
# Pure bash + coreutils (bash-3.2 clean, no sed/grep regex), so it runs the same
# on macOS and Linux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

SKILL_DIR="$REPO_ROOT/plugins/dev-core/skills/repo-baseline"
CONTRACT="$SKILL_DIR/slice-contract.md"
SLICES_DIR="$SKILL_DIR/languages"

test_suite "repo-baseline slice contract conformance"

WORKDIR="$(command mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && command pwd -P)"
trap 'command rm -rf "$WORKDIR"' EXIT

# required_headings <contract-file>
# Prints each required heading (e.g. `## CI job`), one per line, from the list
# items between the start and end markers. An item is a line whose first
# backticked span starts with `## `; anything else in the region is ignored.
# Prints NOTHING unless the region is closed by its end marker: an unterminated
# region would otherwise run to EOF and absorb every later list item as a
# requirement, so it fails closed into the zero-heading case instead.
required_headings() {
    local line in_region=0 closed=0 span found=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *'<!-- slice-contract:required-headings -->'*)
                in_region=1
                continue
                ;;
            *'<!-- slice-contract:end-required-headings -->'*)
                [ "$in_region" -eq 1 ] && closed=1
                in_region=0
                continue
                ;;
        esac
        [ "$in_region" -eq 1 ] || continue
        case "$line" in
            *'`## '*'`'*)
                span="${line#*\`}"
                span="${span%%\`*}"
                found="$found$span
"
                ;;
        esac
    done <"$1"
    [ "$closed" -eq 1 ] || return 0
    command printf '%s' "$found"
}

# Fenced-code tracking, shared by every parser in this file so they cannot
# disagree on what a fence is. CommonMark's rules, the subset the slices use:
# a fence opens on a run of 3+ backticks or 3+ tildes; it closes only on a run
# of the SAME character at least as long, followed by nothing but whitespace.
# So inside a ``` fence, "```bash", "``` bash" and "~~~" are all content.

# fence_run <line>
# Sets FENCE_RUN to the line's leading run of 3+ backticks or tildes and
# FENCE_REST to what follows it; FENCE_RUN is empty when the line opens no
# fence. Pure parameter expansion: no subshell per line.
fence_run() {
    local line="$1" ch rest
    FENCE_RUN="" FENCE_REST=""
    case "$line" in
        '```'*) ch='`' ;;
        '~~~'*) ch='~' ;;
        *) return 0 ;;
    esac
    rest="$line"
    while [ "${rest#"$ch"}" != "$rest" ]; do
        FENCE_RUN="$FENCE_RUN$ch"
        rest="${rest#"$ch"}"
    done
    FENCE_REST="$rest"
}

# fence_closes <open-run> <line>
# Succeeds when <line> closes a fence opened by <open-run>.
fence_closes() {
    fence_run "$2"
    [ -n "$FENCE_RUN" ] || return 1
    [ "${FENCE_RUN%"${FENCE_RUN#?}"}" = "${1%"${1#?}"}" ] || return 1
    [ "${#FENCE_RUN}" -ge "${#1}" ] || return 1
    case "$FENCE_REST" in
        *[![:space:]]*) return 1 ;;
    esac
    return 0
}

# slice_headings <slice-file>
# Prints the slice's `## ` headings in document order, skipping fenced code
# blocks (a `## ` inside a fence is example content, not structure).
slice_headings() {
    local line fence=""
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "$fence" ]; then
            fence_closes "$fence" "$line" && fence=""
            continue
        fi
        fence_run "$line"
        if [ -n "$FENCE_RUN" ]; then
            fence="$FENCE_RUN"
            continue
        fi
        case "$line" in
            '## '*) command printf '%s\n' "${line%"${line##*[![:space:]]}"}" ;;
        esac
    done <"$1"
}

# conformance_problems <contract-file> <slice-file>
# Prints one line per problem: a required heading that is absent, or present
# but out of the contract's order. Empty output means the slice conforms.
# Order is checked as a subsequence, so extra headings a slice adds AFTER (or
# between) the required ones are allowed, per the contract.
conformance_problems() {
    local contract="$1" slice="$2"
    local req_file="$WORKDIR/req.$$" have_file="$WORKDIR/have.$$"
    required_headings "$contract" >"$req_file"
    slice_headings "$slice" >"$have_file"

    # Greedy subsequence match: each required heading is searched for only
    # AFTER the previous match, so a duplicate earlier in the slice cannot be
    # mistaken for the in-order occurrence. A heading present only before that
    # point is out of order; one present nowhere is missing.
    local req have pos seen n last_pos=0
    while IFS= read -r req; do
        pos=0 seen=0 n=0
        while IFS= read -r have; do
            n=$((n + 1))
            [ "$have" = "$req" ] || continue
            seen=1
            if [ "$n" -gt "$last_pos" ]; then
                pos=$n
                break
            fi
        done <"$have_file"
        if [ "$pos" -gt 0 ]; then
            last_pos=$pos
        elif [ "$seen" -eq 1 ]; then
            command printf 'out of order: %s\n' "$req"
        else
            command printf 'missing heading: %s\n' "$req"
        fi
    done <"$req_file"
    command rm -f "$req_file" "$have_file"
}

# rc_settings <file>
# Prints the settings lines of an rc-style file: every line that is neither
# blank nor a `#` comment, with surrounding whitespace trimmed.
rc_settings() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in
            '' | '#'*) continue ;;
        esac
        command printf '%s\n' "$line"
    done <"$1"
}

# slice_fence_block <lang> <slice-file>
# Prints, verbatim, the FIRST ```<lang> fence under the slice's
# `## Config files` heading — the slice's literal copy of a file it ships.
# Prints nothing when the heading or the fence is absent or the fence is
# unterminated, which the caller treats as a failure, never as a match.
slice_fence_block() {
    # Fences go through fence_run/fence_closes, so a `## ` line inside any
    # fence is example content, never a heading. `capture` is set only on a
    # <lang> opener inside the section, and its close is the only successful
    # return.
    local lang="$1" line in_section=0 fence="" capture=0 block="$WORKDIR/fence.$$"
    shift
    : >"$block"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "$fence" ]; then
            if fence_closes "$fence" "$line"; then
                if [ "$capture" -eq 1 ]; then
                    command cat "$block"
                    command rm -f "$block"
                    return 0
                fi
                fence=""
            elif [ "$capture" -eq 1 ]; then
                command printf '%s\n' "$line" >>"$block"
            fi
            continue
        fi
        fence_run "$line"
        if [ -n "$FENCE_RUN" ]; then
            fence="$FENCE_RUN"
            case "$FENCE_REST" in
                "$lang" | "$lang "*) [ "$in_section" -eq 1 ] && capture=1 ;;
            esac
            continue
        fi
        case "$line" in
            '## Config files' | '## Config files '*) in_section=1 ;;
            '## '*) in_section=0 ;;
        esac
    done <"$1"
    command rm -f "$block"
}

# slice_fence_settings <lang> <slice-file>
# The settings lines (as rc_settings) of slice_fence_block's block — the form a
# config copy is compared in (`ini` for shell's .shellcheckrc, `toml` for
# python's ruff.toml). TOML table headers like `[lint]` are kept, so a setting
# moved between tables is drift. Empty whenever slice_fence_block is.
slice_fence_settings() {
    local raw="$WORKDIR/settings.$$"
    slice_fence_block "$@" >"$raw"
    rc_settings "$raw"
    command rm -f "$raw"
}

# A minimal fixture contract with three required headings.
FIXTURE_CONTRACT="$WORKDIR/contract.md"
command cat >"$FIXTURE_CONTRACT" <<'EOF'
# Contract

<!-- slice-contract:required-headings -->

1. `## Alpha`
1. `## Beta`
1. `## Gamma`

<!-- slice-contract:end-required-headings -->

1. `## Not required` (outside the markers)
EOF

# --- The real contract and slices -------------------------------------------

test_contract_parses() {
    local count
    count="$(required_headings "$CONTRACT" | command wc -l)"
    count=$((count + 0))
    assert_true "[ $count -gt 0 ]" \
        "slice-contract.md yields at least one required heading (got $count — markers moved?)"
    assert_contains "$(required_headings "$CONTRACT")" "## Open decisions" \
        "The parsed list carries the last contract heading (whole region read)"
}

test_slices_exist() {
    local count=0 f
    for f in "$SLICES_DIR"/*.md; do
        [ -f "$f" ] && count=$((count + 1))
    done
    assert_true "[ $count -gt 0 ]" \
        "At least one languages/*.md slice exists (got $count)"
}

test_every_slice_conforms() {
    local f problems
    for f in "$SLICES_DIR"/*.md; do
        [ -f "$f" ] || continue
        problems="$(conformance_problems "$CONTRACT" "$f")"
        assert_output_empty "$problems" \
            "Slice ${f#"$REPO_ROOT"/} conforms to slice-contract.md"
    done
}

test_shell_slice_rc_matches_repo() {
    local slice_set rc_set
    slice_set="$(slice_fence_settings ini "$SLICES_DIR/shell.md")"
    rc_set="$(rc_settings "$REPO_ROOT/.shellcheckrc")"
    assert_not_empty "$slice_set" \
        "shell.md's Config files section carries a non-empty \`\`\`ini block"
    assert_not_empty "$rc_set" \
        "The repo's .shellcheckrc has at least one settings line"
    assert_equals "$rc_set" "$slice_set" \
        "shell.md's .shellcheckrc block has the same settings lines as the repo's .shellcheckrc"
}

test_python_slice_ruff_matches_repo() {
    local slice_set rc_set
    slice_set="$(slice_fence_settings toml "$SLICES_DIR/python.md")"
    rc_set="$(rc_settings "$REPO_ROOT/ruff.toml")"
    assert_not_empty "$slice_set" \
        "python.md's Config files section carries a non-empty \`\`\`toml block"
    assert_contains "$rc_set" "required-version" \
        "The repo's ruff.toml carries its required-version pin"
    assert_equals "$rc_set" "$slice_set" \
        "python.md's ruff.toml block has the same settings lines as the repo's ruff.toml"
}

test_python_slice_run_sh_template() {
    local f="$WORKDIR/run.sh"
    slice_fence_block bash "$SLICES_DIR/python.md" >"$f"
    assert_true "[ -s \"$f\" ]" \
        "python.md's Config files section carries a non-empty \`\`\`bash block (tests/run.sh)"
    assert_true "bash -n \"$f\"" \
        "The tests/run.sh template parses as bash"
    assert_true "command grep -E '^[[:space:]]+exit 77\$' \"$f\" >/dev/null" \
        "The tests/run.sh template reports a missing runner with the 77 skip sentinel (as code, not a comment)"
    assert_contains "$(command cat "$f")" "uv run --no-project --with-requirements tests/requirements.txt" \
        "The tests/run.sh template runs pytest through the pinned requirements file"
}

test_python_slice_conftest_template() {
    local f="$WORKDIR/conftest.py"
    slice_fence_block python "$SLICES_DIR/python.md" >"$f"
    assert_true "[ -s \"$f\" ]" \
        "python.md's Config files section carries a non-empty \`\`\`python block (tests/conftest.py)"
    assert_contains "$(command cat "$f")" "spec_from_file_location" \
        "The conftest template loads scripts by path"
    if ! command -v python3 >/dev/null 2>&1; then
        skip_test "python3 unavailable — conftest syntax not checked"
        return 0
    fi
    assert_true "python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' \"$f\"" \
        "The conftest template parses as Python"
}

# required_pin <file>
# Prints the bare version from a top-level `required-version = "==X.Y.Z"` line
# (ruff.toml, uv.toml), or nothing when there is none.
required_pin() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            'required-version = "=='*'"')
                line="${line#*==}"
                command printf '%s\n' "${line%\"}"
                return 0
                ;;
        esac
    done <"$1"
}

# slice_ci_images <slice-file>
# Prints `<job> <image>` for each GitLab job in the slice: a column-0 `name:`
# line names the job, and its `  image:` line (comment stripped) names the image.
slice_ci_images() {
    local line job="" img
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            [a-z]*:) job="${line%:}" ;;
            '  image: '*)
                img="${line#  image: }"
                img="${img%% *}"
                command printf '%s %s\n' "$job" "$img"
                ;;
        esac
    done <"$1"
}

# fence_after_label <label> <slice-file>
# Prints, verbatim, the first fence that follows the line naming <label> as a
# backticked path (e.g. `uv.toml` — required.) — the block the slice says IS
# that file. Empty when the label or its fence is absent or unterminated.
fence_after_label() {
    local label="$1" line armed=0 fence="" block="$WORKDIR/label.$$"
    : >"$block"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "$fence" ]; then
            if fence_closes "$fence" "$line"; then
                command cat "$block"
                command rm -f "$block"
                return 0
            fi
            command printf '%s\n' "$line" >>"$block"
            continue
        fi
        fence_run "$line"
        if [ -n "$FENCE_RUN" ]; then
            [ "$armed" -eq 1 ] && fence="$FENCE_RUN"
            continue
        fi
        case "$line" in
            '`'"$label"'` '*) armed=1 ;;
        esac
    done <"$2"
    command rm -f "$block"
}

# table_pin <tool> <slice-file>
# Prints the `Pinned version` cell of <tool>'s row in the Tools & versions table
# (the third column), trimmed.
table_pin() {
    local line cell
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "| $1 "*)
                cell="${line#|*|*|}"
                cell="${cell%%|*}"
                cell="${cell#"${cell%%[![:space:]]*}"}"
                command printf '%s\n' "${cell%"${cell##*[![:space:]]}"}"
                return 0
                ;;
        esac
    done <"$2"
}

# ci_image_problems <slice-file> <ruff-pin> <uv-pin>
# Prints one line per GitLab image that cannot run its job's script:. Empty
# output means both jobs use a shell-bearing variant at the given pins.
ci_image_problems() {
    local images
    images="$(slice_ci_images "$1")"
    # The bare ruff tag is the /ruff binary with ENTRYPOINT ["/ruff"] and no
    # shell, so GitLab cannot run script: in it; -alpine has /bin/sh.
    case "$images" in
        *"python-lint ghcr.io/astral-sh/ruff:$2-alpine"*) ;;
        *) command printf 'python-lint is not ruff:%s-alpine\n' "$2" ;;
    esac
    # tests/run.sh is bash: uv's bare tag is distroless and -alpine has no bash.
    case "$images" in
        *"python-test ghcr.io/astral-sh/uv:$3-trixie-slim"* | \
            *"python-test ghcr.io/astral-sh/uv:$3-debian-slim"*) ;;
        *) command printf 'python-test is not a Debian uv:%s image\n' "$3" ;;
    esac
}

test_python_slice_ci_images() {
    local slice="$SLICES_DIR/python.md" uv_block="$WORKDIR/uv.toml" ruff_pin uv_pin
    ruff_pin="$(required_pin "$REPO_ROOT/ruff.toml")"
    fence_after_label uv.toml "$slice" >"$uv_block"
    uv_pin="$(required_pin "$uv_block")"
    assert_not_empty "$ruff_pin" "The repo's ruff.toml yields a ruff pin"
    assert_not_empty "$uv_pin" "python.md's uv.toml block yields a uv pin"
    assert_output_empty "$(ci_image_problems "$slice" "$ruff_pin" "$uv_pin")" \
        "GitLab jobs use shell-bearing images at the ruff.toml / uv.toml pins"
}

test_python_slice_table_pins() {
    local slice="$SLICES_DIR/python.md" uv_block="$WORKDIR/uv.toml"
    local req="$WORKDIR/req.txt" pytest_pin
    fence_after_label uv.toml "$slice" >"$uv_block"
    fence_after_label tests/requirements.txt "$slice" >"$req"
    pytest_pin="$(command cat "$req")"
    pytest_pin="${pytest_pin#pytest==}"
    # Non-empty first: two vanished values compare equal, which is not agreement.
    assert_not_empty "$pytest_pin" "python.md's tests/requirements.txt block yields a pytest pin"
    assert_not_empty "$(required_pin "$uv_block")" "python.md's uv.toml block yields a uv pin"
    assert_not_empty "$(table_pin ruff "$slice")" "The Tools & versions table has a ruff pin"
    assert_not_empty "$(table_pin uv "$slice")" "The Tools & versions table has a uv pin"
    assert_not_empty "$(table_pin pytest "$slice")" "The Tools & versions table has a pytest pin"
    assert_equals "$(required_pin "$REPO_ROOT/ruff.toml")" "$(table_pin ruff "$slice")" \
        "The Tools & versions ruff row equals the ruff.toml pin"
    assert_equals "$(required_pin "$uv_block")" "$(table_pin uv "$slice")" \
        "The Tools & versions uv row equals the uv.toml block's pin"
    assert_equals "$pytest_pin" "$(table_pin pytest "$slice")" \
        "The Tools & versions pytest row equals the requirements.txt pin"
}

test_python_slice_prepush_glob() {
    local slice="$SLICES_DIR/python.md"
    # Measured on lefthook 2.2.1: `dir/**/*.py` does not match a flat
    # `dir/x.py`, so that glob silently skips this layout's tests.
    # Only YAML glob lines count — the slice's prose quotes the bad pattern as
    # a warning, and that must not trip the check.
    assert_true "! command grep -E '^[[:space:]]+(glob: |- )\"[^\"]*/\*\*/\*\.py\"' \"$slice\" >/dev/null" \
        "No hook glob in python.md uses dir/**/*.py (misses flat bin/x.py, tests/test_x.py)"
    assert_true "command grep -Fx '        - \"tests/**\"' \"$slice\" >/dev/null" \
        "The pre-push tests glob covers the whole tests/ directory"
}

# --- Negative fixtures: the checker must fire --------------------------------

test_fixture_ci_image_parsing() {
    local slice="$WORKDIR/images.md" pin="$WORKDIR/pin.toml"
    command printf 'python-lint:\n  stage: lint\n  image: ghcr.io/astral-sh/ruff:1.2.3 # c\npython-test:\n  image: ghcr.io/astral-sh/uv:4.5.6-alpine\n' >"$slice"
    assert_equals 'python-lint ghcr.io/astral-sh/ruff:1.2.3
python-test ghcr.io/astral-sh/uv:4.5.6-alpine' "$(slice_ci_images "$slice")" \
        "Each job is paired with its own image, comment stripped"
    command printf '# c\nrequired-version = "==0.9.1"\nx = 1\n' >"$pin"
    assert_equals "0.9.1" "$(required_pin "$pin")" "required_pin reads the bare version"
    command printf 'required-version = ">=0.9"\n' >"$pin"
    assert_output_empty "$(required_pin "$pin")" "A non-exact pin yields nothing"
}

test_fixture_ci_image_problems_fire() {
    local slice="$WORKDIR/images2.md" got
    command printf 'python-lint:\n  image: ghcr.io/astral-sh/ruff:1.2.3-alpine\npython-test:\n  image: ghcr.io/astral-sh/uv:4.5.6-trixie-slim\n' >"$slice"
    assert_output_empty "$(ci_image_problems "$slice" 1.2.3 4.5.6)" \
        "Shell-bearing images at the given pins report no problem"
    command printf 'python-lint:\n  image: ghcr.io/astral-sh/ruff:1.2.3\npython-test:\n  image: ghcr.io/astral-sh/uv:4.5.6-alpine\n' >"$slice"
    got="$(ci_image_problems "$slice" 1.2.3 4.5.6)"
    assert_contains "$got" "python-lint is not ruff:1.2.3-alpine" "A bare ruff tag is reported"
    assert_contains "$got" "python-test is not a Debian uv:4.5.6 image" "A uv -alpine tag is reported"
    command printf 'python-lint:\n  image: ghcr.io/astral-sh/ruff:1.2.3-alpine\npython-test:\n  image: ghcr.io/astral-sh/uv:4.5.6-trixie-slim\n' >"$slice"
    assert_contains "$(ci_image_problems "$slice" 1.2.4 4.5.6)" "python-lint is not ruff:1.2.4-alpine" \
        "An image tag left behind by a pin bump is reported"
}

test_fixture_prepush_glob_regex() {
    local f="$WORKDIR/glob.md"
    command printf '      glob: "{bin,tests}/**/*.py"\n' >"$f"
    assert_true "command grep -E '^[[:space:]]+(glob: |- )\"[^\"]*/\*\*/\*\.py\"' \"$f\" >/dev/null" \
        "A scalar dir/**/*.py glob line is caught"
    command printf '      glob:\n        - "bin/**/*.py"\n' >"$f"
    assert_true "command grep -E '^[[:space:]]+(glob: |- )\"[^\"]*/\*\*/\*\.py\"' \"$f\" >/dev/null" \
        "A list-item dir/**/*.py glob is caught"
    command printf 'Never use `"{bin,tests}/**/*.py"` here.\n      glob: "*.py"\n' >"$f"
    assert_true "! command grep -E '^[[:space:]]+(glob: |- )\"[^\"]*/\*\*/\*\.py\"' \"$f\" >/dev/null" \
        "Prose quoting the pattern, and a plain *.py glob, are not caught"
}

test_fixture_label_and_table_parsing() {
    local slice="$WORKDIR/labels.md"
    command printf '| Tool | P | Pinned version | S |\n| uv   | x | 9.9.9          | y |\n\n`ruff.toml` — required.\n\n```toml\nrequired-version = "==1.0.0"\n```\n\n`uv.toml` — required.\n\n```toml\nrequired-version = "==9.9.9"\n```\n' >"$slice"
    assert_equals 'required-version = "==9.9.9"' "$(fence_after_label uv.toml "$slice")" \
        "fence_after_label reads the fence after its own label, not an earlier toml fence"
    assert_equals "9.9.9" "$(table_pin uv "$slice")" "table_pin reads the Pinned version cell"
    assert_output_empty "$(fence_after_label missing.toml "$slice")" \
        "An absent label yields nothing"
}

test_fixture_sentinel_in_comment_only() {
    local f="$WORKDIR/comment-sentinel.sh"
    command printf '#!/usr/bin/env bash\n# would exit 77 here\necho "exit 77"\nexit 0\n' >"$f"
    assert_true "! command grep -E '^[[:space:]]+exit 77\$' \"$f\" >/dev/null" \
        "An 'exit 77' that appears only in a comment or a string is not the sentinel"
}

test_fixture_template_syntax_fires() {
    local slice="$WORKDIR/broken-templates.md" f="$WORKDIR/broken.out"
    command printf '# S\n\n## Config files\n\n```bash\nif true; then\n```\n\n```python\ndef f(:\n```\n' >"$slice"
    slice_fence_block bash "$slice" >"$f"
    assert_contains "$(command cat "$f")" "if true; then" \
        "The broken bash template is the one read back"
    assert_true "! bash -n \"$f\" 2>/dev/null" \
        "A bash template with a syntax error fails bash -n"
    if ! command -v python3 >/dev/null 2>&1; then
        skip_test "python3 unavailable"
        return 0
    fi
    slice_fence_block python "$slice" >"$f"
    assert_true "! python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' \"$f\" 2>/dev/null" \
        "A python template with a syntax error fails to parse"
}

test_fixture_fence_lang_selects() {
    local slice="$WORKDIR/lang.md"
    command printf '# S\n\n## Config files\n\n```ini\nshell=bash\n```\n\n```toml\n[lint]\nselect = ["F"]\n```\n' >"$slice"
    assert_equals '[lint]
select = ["F"]' "$(slice_fence_settings toml "$slice")" \
        "The toml reader skips an earlier ini fence and keeps TOML table headers"
    assert_equals "shell=bash" "$(slice_fence_settings ini "$slice")" \
        "The ini reader is unaffected by a later toml fence"
    command printf '# S\n\n## Config files\n\n```tomlx\nx=1\n```\n' >"$slice"
    assert_output_empty "$(slice_fence_settings toml "$slice")" \
        "A fence whose info string merely starts with the language is not captured"
}

test_fixture_ini_drift() {
    local slice="$WORKDIR/drift.md" rc="$WORKDIR/rc"
    command printf 'shell=bash\ndisable=SC1090\n' >"$rc"
    command printf '# S\n\n## Config files\n\n```ini\n# c\nseverity=info\nshell=bash\ndisable=SC1090\n```\n' >"$slice"
    local got
    got="$(slice_fence_settings ini "$slice")"
    assert_contains "$got" "severity=info" \
        "The drifted line is read out of the slice block"
    assert_true "[ \"\$got\" != \"\$(rc_settings \"\$rc\")\" ]" \
        "A slice block carrying severity=info differs from an rc without it"
    command printf '# S\n\n## Config files\n\n```ini\n  # c\n\n shell=bash \ndisable=SC1090\n```\n' >"$slice"
    assert_equals "$(rc_settings "$rc")" "$(slice_fence_settings ini "$slice")" \
        "Comments, blank lines and surrounding whitespace do not count as drift"
}

test_fixture_ini_block_outside_section() {
    local slice="$WORKDIR/elsewhere.md"
    command printf '# S\n\n## Tools\n\n```ini\nshell=bash\n```\n\n## Config files\n\nnone\n' >"$slice"
    assert_output_empty "$(slice_fence_settings ini "$slice")" \
        "An ini block under another heading is not read as the Config files block"
    command printf '# S\n\n## Config files\n\nnone\n\n## Hook entries\n\n```ini\nshell=bash\n```\n' >"$slice"
    assert_output_empty "$(slice_fence_settings ini "$slice")" \
        "The Config files section ends at the next heading; a later section's ini block is not read"
    command printf '# S\n\n## Config files\n\n```ini\nshell=bash\n```\n\n```ini\nshell=sh\n```\n' >"$slice"
    assert_equals "shell=bash" "$(slice_fence_settings ini "$slice")" \
        "Only the FIRST ini fence under Config files is read"
    command printf '# S\n\n## Config files\n\n```bash\n## not a heading\n```\n\n```ini\nshell=bash\n```\n' >"$slice"
    assert_equals "shell=bash" "$(slice_fence_settings ini "$slice")" \
        "A '## ' line inside an earlier non-ini fence does not end the Config files section"
    command printf '# S\n\n## Config filesystem\n\n```ini\nshell=bash\n```\n' >"$slice"
    assert_output_empty "$(slice_fence_settings ini "$slice")" \
        "A heading that merely starts with 'Config files' is not the Config files section"
    command printf '# S\n\n## Tools\n\n```ini\n## not a heading\nx=1\n```\n\n## Config files\n\n```ini\nshell=bash\n```\n' >"$slice"
    assert_equals "shell=bash" "$(slice_fence_settings ini "$slice")" \
        "An ini fence in an earlier section is skipped as a fence, not read or inverted"
    command printf '# S\n\n## Config files\n\n~~~md\n## not a heading\n```\n~~~\n\n```ini title\nshell=bash\n```\n' >"$slice"
    assert_equals "shell=bash" "$(slice_fence_settings ini "$slice")" \
        "A ~~~ fence closes only on ~~~, and an ini opener may carry an info string"
    command printf '# S\n\n## Config files (copy me)\n\n```ini\nshell=bash\n```\n' >"$slice"
    assert_equals "shell=bash" "$(slice_fence_settings ini "$slice")" \
        "The Config files heading may carry trailing text after a space"
    command printf '# S\n\n## Config files\n\n```md\n```ini\nx=1\n```\n\n```ini\nshell=bash\n```\n' >"$slice"
    assert_equals "shell=bash" "$(slice_fence_settings ini "$slice")" \
        "A fence opener with an info string inside an open fence is content, not a close"
}

# Table-driven: <open-run>|<line>|<closes: 1 or 0>. One row per fence rule, so
# both parsers' shared definition of "closes" is pinned in one place.
test_fixture_fence_closes_table() {
    local row open line want got
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        open="${row%%|*}"
        row="${row#*|}"
        line="${row%|*}"
        want="${row##*|}"
        got=0
        fence_closes "$open" "$line" && got=1
        assert_equals "$want" "$got" "fence_closes '$open' '$line'"
    done <<'EOF'
```|```	|1
```|```|1
```|```   |1
```|````|1
````|```|0
```|~~~|0
~~~|~~~|1
~~~|~~~~|1
~~~~|~~~|0
~~~|```|0
```|```bash|0
```|``` bash|0
```|```ini|0
```|  text|0
EOF
}

test_fixture_ini_fence_variants() {
    local slice="$WORKDIR/variants.md"
    command printf '# S\n\n## Config files\n\n```md\n``` bash\n## Hook entries\n```\n\n```ini\nshell=bash\n```\n' >"$slice"
    assert_equals "shell=bash" "$(slice_fence_settings ini "$slice")" \
        "'\`\`\` bash' inside an open fence is content, so the fenced '## ' stays fenced"
    command printf '# S\n\n## Config files\n\n````md\n```\n## x\n````\n\n~~~ini\nshell=bash\n~~~\n' >"$slice"
    assert_equals "shell=bash" "$(slice_fence_settings ini "$slice")" \
        "A 4-backtick fence is not closed by 3, and a ~~~ini fence is captured"
}

test_fixture_headings_nested_fence() {
    local slice="$WORKDIR/headings-nested.md"
    command printf '# S\n\n## Alpha\n\n~~~md\n```\n## Beta\n~~~\n\n## Gamma\n' >"$slice"
    assert_contains "$(conformance_problems "$FIXTURE_CONTRACT" "$slice")" \
        "missing heading: ## Beta" \
        "slice_headings: a backtick line inside a ~~~ fence does not close it"
}

test_fixture_ini_block_unterminated() {
    local slice="$WORKDIR/unterminated-ini.md"
    command printf '# S\n\n## Config files\n\n```ini\nshell=bash\n\n## Later\n' >"$slice"
    assert_output_empty "$(slice_fence_settings ini "$slice")" \
        "An ini fence with no closing fence parses empty, not to everything after it"
    command printf '# S\n\n## Tools\n\ntext\n' >"$slice"
    assert_output_empty "$(slice_fence_settings ini "$slice")" \
        "A slice with no Config files heading parses empty"
}

test_fixture_conforming() {
    local slice="$WORKDIR/ok.md"
    command printf '# S\n\n## Alpha\n\n## Beta\n\n## Extra\n\n## Gamma\n' >"$slice"
    assert_output_empty "$(conformance_problems "$FIXTURE_CONTRACT" "$slice")" \
        "A slice with all headings in order (plus an extra) conforms"
    assert_equals "3" "$(required_headings "$FIXTURE_CONTRACT" | command wc -l | command tr -d ' ')" \
        "Only the items between the markers are required"
}

test_fixture_missing_heading() {
    local slice="$WORKDIR/missing.md"
    command printf '# S\n\n## Alpha\n\n## Gamma\n' >"$slice"
    assert_contains "$(conformance_problems "$FIXTURE_CONTRACT" "$slice")" \
        "missing heading: ## Beta" \
        "A slice missing a required heading is reported, naming the heading"
}

test_fixture_out_of_order() {
    local slice="$WORKDIR/order.md"
    command printf '# S\n\n## Beta\n\n## Alpha\n\n## Gamma\n' >"$slice"
    assert_contains "$(conformance_problems "$FIXTURE_CONTRACT" "$slice")" \
        "out of order: ## Beta" \
        "A slice with required headings out of order is reported"
}

test_fixture_heading_only_in_fence() {
    local slice="$WORKDIR/fence.md"
    command printf '# S\n\n## Alpha\n\n```md\n## Beta\n```\n\n## Gamma\n' >"$slice"
    assert_contains "$(conformance_problems "$FIXTURE_CONTRACT" "$slice")" \
        "missing heading: ## Beta" \
        "A heading that appears only inside a code fence does not count"
}

test_fixture_vacuous_contract() {
    local contract="$WORKDIR/no-markers.md"
    command printf '# Contract\n\n1. `## Alpha`\n' >"$contract"
    assert_output_empty "$(required_headings "$contract")" \
        "A contract without markers parses to zero headings (which test_contract_parses rejects)"
}

test_fixture_duplicate_heading() {
    local slice="$WORKDIR/dup.md"
    # An early stray `## Gamma` must not be taken as the required one: the
    # in-order sequence Alpha, Beta, Gamma still exists, so this conforms.
    command printf '# S\n\n## Gamma\n\n## Alpha\n\n## Beta\n\n## Gamma\n' >"$slice"
    assert_output_empty "$(conformance_problems "$FIXTURE_CONTRACT" "$slice")" \
        "A duplicated required heading is matched in order, not at its first occurrence"
}

test_fixture_unterminated_contract() {
    local contract="$WORKDIR/unterminated.md"
    command printf '# C\n\n<!-- slice-contract:required-headings -->\n\n1. `## Alpha`\n\n1. `## Later`\n' >"$contract"
    assert_output_empty "$(required_headings "$contract")" \
        "A contract whose end marker is missing parses to zero headings, not to everything after the start"
}

# --- Run All Tests ----------------------------------------------------------

run_test test_contract_parses "slice-contract.md's required-heading list parses non-empty"
run_test test_slices_exist "At least one language slice exists"
run_test test_every_slice_conforms "Every language slice carries the required headings in order"
run_test test_shell_slice_rc_matches_repo "The shell slice's .shellcheckrc block matches the repo's .shellcheckrc"
run_test test_python_slice_ruff_matches_repo "The python slice's ruff.toml block matches the repo's ruff.toml"
run_test test_python_slice_run_sh_template "The python slice's tests/run.sh template parses and keeps the 77 sentinel"
run_test test_python_slice_conftest_template "The python slice's conftest.py template parses"
run_test test_python_slice_ci_images "The python slice's GitLab images are shelled variants at the ruff/uv pins"
run_test test_python_slice_table_pins "The python slice's Tools & versions pins equal its config blocks"
run_test test_python_slice_prepush_glob "The python slice's pre-push glob matches flat bin/ and tests/ files"
run_test test_fixture_ci_image_parsing "Fixture: CI image and pin parsing"
run_test test_fixture_ci_image_problems_fire "Fixture: a shell-less or stale CI image is reported"
run_test test_fixture_prepush_glob_regex "Fixture: the pre-push glob check catches glob lines, not prose"
run_test test_fixture_label_and_table_parsing "Fixture: label-anchored fence and table-pin parsing"
run_test test_fixture_sentinel_in_comment_only "Fixture: a commented-out 77 sentinel is not the sentinel"
run_test test_fixture_template_syntax_fires "Fixture: a template with a syntax error is caught"
run_test test_fixture_fence_lang_selects "Fixture: the fence reader captures only the requested language"
run_test test_fixture_conforming "Fixture: a conforming slice passes"
run_test test_fixture_missing_heading "Fixture: a missing heading is reported"
run_test test_fixture_out_of_order "Fixture: an out-of-order heading is reported"
run_test test_fixture_heading_only_in_fence "Fixture: a fenced-only heading is reported missing"
run_test test_fixture_vacuous_contract "Fixture: a marker-less contract parses empty"
run_test test_fixture_duplicate_heading "Fixture: a duplicated heading is matched as a subsequence"
run_test test_fixture_unterminated_contract "Fixture: an unterminated contract region parses empty"
run_test test_fixture_ini_drift "Fixture: a drifted ini block is reported; comments and whitespace are not drift"
run_test test_fixture_ini_block_outside_section "Fixture: an ini block outside Config files is ignored"
run_test test_fixture_fence_closes_table "Fixture: fence close rules (same char, run >= opener, no info string)"
run_test test_fixture_ini_fence_variants "Fixture: info-string lines and longer runs stay inside an open fence"
run_test test_fixture_headings_nested_fence "Fixture: slice_headings shares the fence rules"
run_test test_fixture_ini_block_unterminated "Fixture: an unterminated ini fence or absent heading parses empty"

generate_report
