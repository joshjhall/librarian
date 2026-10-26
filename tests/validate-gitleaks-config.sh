#!/usr/bin/env bash
# Behavior gate for the repo-root .gitleaks.toml (#872).
#
# The lefthook pre-commit step runs `gitleaks protect --staged` from the repo
# root with no --config, so the config takes effect only through gitleaks'
# auto-discovery of `.gitleaks.toml` in the scanned tree. Every case here runs
# exactly that: a sandbox git repo with the real config copied to its root, the
# file staged, and `gitleaks protect --staged` run from inside it. A test that
# passed --config would pin a path the hook never takes.
#
# The cases pin both directions of the allowlist, because either one alone is
# vacuous: the prose label must commit clean, a real credential in the SAME
# file must still be caught, and the label must still fire with the config
# removed — otherwise "clean" proves nothing about the config.
#
# gitleaks is a local hook tool that CI does not install, so an absent binary
# exits the reserved 77 sentinel (rendered [SKIP] … did not run), never 0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

CONFIG="$REPO_ROOT/.gitleaks.toml"
SKIP_EXIT_CODE=77

test_suite "gitleaks config (.gitleaks.toml)"

if ! command -v gitleaks >/dev/null 2>&1; then
    skip_test "GATE DID NOT RUN — gitleaks not available (install gitleaks to exercise .gitleaks.toml)"
    generate_report
    return "$SKIP_EXIT_CODE" 2>/dev/null || exit "$SKIP_EXIT_CODE"
fi

SANDBOX="$(command mktemp -d)"
trap 'command rm -rf "$SANDBOX"' EXIT

# The exact label from #872 that blocked a commit.
PROSE_LINE='        "missing-api swift: unmarked/internal/private declarations are not public API"'
# A credential-shaped assignment, split so this file does not trip the hook.
PLANTED_KEY="q8Zr2mVx""7LpT4wKc9NbJ"

# new_repo <name> [with-config] -> prints the sandbox repo path
# GITLEAKS_CONFIG* would outrank the auto-discovered file, and GIT_* would point
# git at the wrong repo; scrub both so the case measures only the sandbox.
new_repo() {
    local dir="$SANDBOX/$1"
    command mkdir -p "$dir"
    command env -uGIT_DIR -uGIT_WORK_TREE -uGIT_INDEX_FILE git -C "$dir" init -q
    if [ "${2:-}" = "with-config" ]; then
        command cp "$CONFIG" "$dir/.gitleaks.toml"
    fi
    printf '%s\n' "$dir"
}

# scan <repo> -> sets SCAN_RC and SCAN_REPORT (JSON findings)
scan() {
    local dir="$1"
    command env -uGIT_DIR -uGIT_WORK_TREE -uGIT_INDEX_FILE git -C "$dir" add -A
    SCAN_RC=0
    (cd "$dir" && command env -uGITLEAKS_CONFIG -uGITLEAKS_CONFIG_TOML \
        gitleaks protect --staged --no-banner --redact \
        --report-format json --report-path "$dir.report.json" >/dev/null 2>&1) || SCAN_RC=$?
    SCAN_REPORT="$(command cat "$dir.report.json" 2>/dev/null || true)"
}

test_config_present() {
    assert_file_exists "$CONFIG"
    assert_file_contains "$CONFIG" "useDefault = true" \
        "Config must extend the stock ruleset, not replace it"
    # assert_file_contains takes a BRE, so the brackets are escaped.
    assert_file_contains "$CONFIG" 'targetRules = \["generic-api-key"\]' \
        "Allowlist must stay scoped to the one rule it was measured against"
}

test_prose_fires_without_config() {
    local dir
    dir="$(new_repo vacuity)"
    printf '%s\n' "$PROSE_LINE" >"$dir/t.sh"
    scan "$dir"
    assert_exit 1 "$SCAN_RC" "Control: the #872 label must still fire with NO config, or the clean case below proves nothing"
    assert_contains "$SCAN_REPORT" "generic-api-key"
}

test_prose_commits_clean() {
    local dir
    dir="$(new_repo prose with-config)"
    printf '%s\n' "$PROSE_LINE" >"$dir/t.sh"
    scan "$dir"
    assert_exit 0 "$SCAN_RC" "The #872 prose label must commit clean under .gitleaks.toml"
}

test_planted_key_still_caught() {
    local dir
    dir="$(new_repo planted with-config)"
    printf 'api_key = "%s"\n%s\n' "$PLANTED_KEY" "$PROSE_LINE" >"$dir/t.sh"
    scan "$dir"
    assert_exit 1 "$SCAN_RC" "A real credential beside the prose must still block the commit"
    assert_contains "$SCAN_REPORT" "generic-api-key"
    # Assert the finding is the KEY's line, not the prose's: a regression that
    # re-fired on the prose alone would satisfy the two checks above.
    assert_contains "$SCAN_REPORT" '"StartLine": 1'
    assert_not_contains "$SCAN_REPORT" '"StartLine": 2'
}

test_fixture_tokens_commit_clean() {
    local dir f
    dir="$(new_repo fixtures with-config)"
    for f in tests/validate-source-detectors/10-security.sh \
        tests/validate-loop-detectors.sh \
        tests/validate-python-ports.sh; do
        command mkdir -p "$dir/$(command dirname "$f")"
        command cp "$REPO_ROOT/$f" "$dir/$f"
    done
    scan "$dir"
    assert_exit 0 "$SCAN_RC" "The AKIA_TOK/GHP_TOK/STRIPE_TOK fixture files must commit clean"
}

run_test test_config_present "config extends the defaults and scopes the allowlist to generic-api-key"
run_test test_prose_fires_without_config "control: #872 label fires with no config"
run_test test_prose_commits_clean "#872 label commits clean under the config"
run_test test_planted_key_still_caught "planted credential in the same file is still caught"
run_test test_fixture_tokens_commit_clean "fake-token fixture files commit clean"

generate_report
