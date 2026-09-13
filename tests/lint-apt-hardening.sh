#!/usr/bin/env bash
# Structural gate: every workflow apt-get goes through bin/apt-install.sh (#983).
#
# WHY THIS EXISTS AT ALL. The #983 fix is a behaviour change in one script, but
# its VALUE is that no workflow step bypasses it. A bare
# `sudo apt-get update && sudo apt-get install -y ...` added to a new job — or
# restored by a careless revert — is invisible: the step passes on every good
# day and only fails on the bad window the fix was written for, which is exactly
# the condition nobody is watching for. So the acceptance criterion is not "the
# script works" but "the fix is applied to EVERY workflow step running apt-get",
# and that is a property of the workflow files, checkable offline.
#
# Scope boundary: this gate checks ROUTING (does an apt-get invocation go
# through bin/apt-install.sh), not the script's behaviour — that is
# tests/validate-apt-install.sh. The two are deliberately separate: a gate that
# both constructs the behaviour and asserts the routing would pass on a tree
# where the script had been emptied.
#
# Exempt: a line that IS the bin/apt-install.sh call, and apt-get mentions
# inside a YAML comment (which are how the steps explain themselves).
#
# Pure bash + coreutils + grep; no network, no jq. bash-3.2 clean, BSD-clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
INSTALLER="bin/apt-install.sh"

test_suite "apt hardening (#983)"

# _apt_lines <file> — `<lineno>:<text>` for every line mentioning apt-get,
# EXCLUDING comment lines. A YAML comment is the only place the token may appear
# without being an invocation, and both hardened steps carry one explaining why
# they route through the script — flagging those would make the gate unfixable.
#
# Note the `|| true`: grep exits 1 on no match, which under `set -e` would abort
# the scan of a workflow that legitimately runs no apt-get at all.
_apt_lines() {
    command grep -nE 'apt-get' "$1" 2>/dev/null |
        command grep -vE '^[0-9]+:[[:space:]]*#' || true
}

# line_is_routed <line> — true when EVERY apt-get occurrence on the line is
# routed through the installer.
#
# Two bypasses make this a per-CLAUSE question rather than a per-line one, and
# both are the same shape: a line that contains the installer path somewhere,
# while still running a bare apt-get somewhere else.
#
#   run: sudo apt-get install -y jq  # deliberately not bin/apt-install.sh
#   run: bash bin/apt-install.sh jq && sudo apt-get install -y curl
#
# The first excuses itself in a comment, the second chains past the routed call.
# A naive `[[ "$line" == *"$INSTALLER"* ]]` accepts both — and they are the two
# lines most likely to BE a real bypass, since each is what someone writes when
# they know about the rule and are working around it.
#
# So: drop the comment, split the rest on the shell's own separators, and
# require each clause that mentions apt-get to also invoke the installer.
#
# The comment split is a plain `%%#*` and is NOT quote-aware — a routed line
# carrying a literal `#` in an earlier quoted argument would be truncated and
# flagged. That direction is deliberate and safe: truncation only ever REMOVES
# text before a containment test, so it can add a false positive (a loud CI
# failure on a line a human then rewrites) but can never hide a bare apt-get. A
# fail-closed misfire is the right side to err on for a gate whose whole job is
# to notice a bypass.
line_is_routed() {
    local code="${1%%#*}"
    local clause
    # IFS split on the separators a compound `run:` line can use. Word-splitting
    # here is intentional, hence the disable.
    local old_ifs="$IFS"
    IFS=';&|'
    # shellcheck disable=SC2086
    set -- $code
    IFS="$old_ifs"
    for clause in "$@"; do
        case "$clause" in
            *apt-get*)
                [[ "$clause" == *"$INSTALLER"* ]] || return 1
                ;;
        esac
    done
    return 0
}

# scan_file <path> — populate CUR_VIOLATIONS with one indented line per
# unrouted apt-get invocation (empty when the file is clean).
CUR_FILE=""
CUR_VIOLATIONS=""
scan_file() {
    local file="$1"
    CUR_VIOLATIONS=""
    local entry lineno line
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        lineno="${entry%%:*}"
        line="${entry#*:}"
        if line_is_routed "$line"; then
            continue
        fi
        CUR_VIOLATIONS="${CUR_VIOLATIONS}    ${lineno}: ${line}
"
    done <<EOF
$(_apt_lines "$file")
EOF
}

test_file_routed() {
    scan_file "$CUR_FILE"
    assert_not_empty "$CUR_FILE" "Workflow path is set"
    if [ -n "$CUR_VIOLATIONS" ]; then
        _fail "apt-get invoked directly — route it through $INSTALLER (#983)" \
            "$CUR_VIOLATIONS"
    fi
    return 0
}

# --- Negative fixture: prove the detector fires -------------------------------
# Without this, an inert scan_file (a regex typo, a grep that stopped matching)
# would report every workflow clean and the gate would be a green no-op — the
# silence-reads-as-a-pass shape (#538/#571).
test_negative_case_fires() {
    local tmp
    tmp="$(command mktemp)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    command cat >"$tmp" <<'FIXTURE'
      - name: Bad direct install
        run: sudo apt-get update && sudo apt-get install -y jq
      # a comment mentioning apt-get is not an invocation
      - name: Excused direct install
        run: sudo apt-get install -y curl  # deliberately not bin/apt-install.sh
      - name: Chained past the installer
        run: bash bin/apt-install.sh jq && sudo apt-get install -y ripgrep
      - name: Chained with a semicolon
        run: bash bin/apt-install.sh jq; sudo apt-get install -y fd-find
      - name: Chained through a pipe
        run: bash bin/apt-install.sh jq | tee log; sudo apt-get install -y bat
      - name: Good routed install
        run: bash bin/apt-install.sh jq shellcheck
FIXTURE
    scan_file "$tmp"
    command rm -f "$tmp"

    assert_contains "$CUR_VIOLATIONS" "sudo apt-get update" \
        "A direct apt-get invocation IS flagged"
    # Anchored on the routed line's own arguments, not on the installer path:
    # the excused line below legitimately carries that path in its comment, so
    # matching the path alone would conflate "the routed line was flagged" with
    # "some flagged line mentions the script".
    assert_not_contains "$CUR_VIOLATIONS" "jq shellcheck" \
        "A routed install is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" "a comment mentioning" \
        "A YAML comment mentioning apt-get is NOT flagged"
    # The substring-match trap: a direct call whose trailing comment names the
    # installer must still be flagged, or the gate can be talked out of firing
    # by the very line it is meant to catch.
    assert_contains "$CUR_VIOLATIONS" "install -y curl" \
        "A direct apt-get is flagged even when a comment names the installer"
    # The other half of the same shape: a bare apt-get chained AFTER a routed
    # call. The installer path is genuinely on the line, so only a per-clause
    # check can see the second command at all.
    assert_contains "$CUR_VIOLATIONS" "install -y ripgrep" \
        "A bare apt-get chained after a routed call is still flagged"
    # All three separators the split covers, asserted individually: a typo that
    # dropped one character from IFS would still pass the `&&` case alone.
    assert_contains "$CUR_VIOLATIONS" "install -y fd-find" \
        "A semicolon-chained bare apt-get is flagged"
    assert_contains "$CUR_VIOLATIONS" "install -y bat" \
        "A pipe-chained bare apt-get is flagged"
}

# The installer must actually exist — otherwise every workflow "routes" to a
# missing file and the gate passes while CI cannot install anything.
test_installer_present() {
    assert_file_exists "$REPO_ROOT/$INSTALLER" \
        "$INSTALLER exists (the routing target)"
}

# Discover workflow files. nullglob so an empty dir yields an empty array rather
# than a literal glob pattern.
shopt -s nullglob
workflows=("$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml)
shopt -u nullglob

# Guard: the suite must actually inspect something. A gate that silently checks
# zero files (dir moved, glob regressed) is worse than no gate.
test_corpus_non_empty() {
    assert_not_empty "${workflows[*]:-}" "At least one workflow file is present to lint"
}

run_test test_corpus_non_empty "Workflow corpus is non-empty (gate is not a no-op)"
run_test test_installer_present "$INSTALLER is present"
run_test test_negative_case_fires "scan_file flags a direct apt-get (violation path)"

for f in "${workflows[@]}"; do
    CUR_FILE="$f"
    run_test test_file_routed "$(command basename "$f"): apt-get routed through $INSTALLER"
done

generate_report
