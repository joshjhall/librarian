#!/usr/bin/env bash
# check-security + check-code-health detector behavioral gate (issue #348).
#
# These two review-audit source-scanning pre-scans —
#
#   check-security      (hardcoded-secret / injection-risk / xss-risk / insecure-crypto)
#   check-code-health   (tech-debt-marker / debug-statement / empty-handler)
#
# — were among the lowest-coverage Python ports (check-code-health 68%,
# check-security 84%) because, like the check-docs-* family before #243, NEITHER
# had a dedicated behavioral gate: only tests/validate-python-ports.sh covered
# them, and it asserts bash==python PARITY over one shared fixture tree, which —
# as its own header notes — "cannot catch a regression where both impls break the
# same way." Whole per-language and per-category arms (the private-key header, the
# Stripe/React/Blade branches, the Go/Ruby/Java debug + empty-handler arms, the
# insecure-crypto comment-skip boundary, the is-test-file segment anchoring) never
# executed and had zero output-asserting coverage.
#
# This gate is the behavioral half of the #204 two-surface convention for the
# source family: it drives PURPOSE-BUILT fixtures through each scanner and asserts
# the SPECIFIC finding category each fixture must emit — AND that a clean
# counter-fixture stays silent — with emphasis on BOUNDARIES and NEGATIVE paths
# (the credential denylist skip, the crypto comment-only skip, the
# print()-with-logger negative, the debug-in-test-file suppression, the
# segment-anchored is-test-file that must NOT match contest.py). The sibling
# tests/coverage-python.sh corpus is extended in lockstep so the same branches
# execute under measurement; coverage rises because behavior is asserted, never
# the reverse.
#
# Each category is asserted against BOTH the Python primary (patterns.py) and the
# bash fallback (PATTERNS_FORCE_BASH=1 patterns.sh) — free parity reinforcement on
# top of validate-python-ports.sh's whole-corpus diff.
#
# Fault-injection verified (the #221 precedent): each boundary below was proven
# to catch a regression by transiently mutating the port and confirming this gate
# goes red, then reverting. The mutations checked, one per port:
#   check-security      — the insecure-crypto `not is_comment` guard forced true
#                         (so a commented md5() would wrongly fire) → the
#                         comment-skip silent assertion goes red.
#   check-code-health   — the debug-statement `if not test_file:` guard dropped
#                         (so a print() inside a test file would wrongly fire) →
#                         the test-file-suppression silent assertion goes red.
# Both went red under mutation and green on revert.
#
# Both ports read only file CONTENT (no git-rooting), so their CWD is irrelevant
# and every fixture runs from $WORKDIR.
#
# SKIPS (does not fail) when a python3>=3.11 is unavailable — the same posture as
# validate-python-ports.sh; the bash path is still asserted where present.
#
#
# THIS FILE IS A THIN ENTRY POINT (issue #859, following the #564 convention).
# The cases live in per-area fragments under tests/validate-source-detectors/,
# and the shared drivers (emit_rows / assert_fires / assert_silent / fresh_dir /
# make_list, plus HAVE_PY / WORKDIR) live in
# tests/lib/source-detectors-sandbox.sh. The explicit FRAGMENTS list below fixes
# the source order and is guarded, so an unwired fragment cannot silently
# contribute zero tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "check-security + check-code-health detector fixtures (#348)"

# Read by the sourced sandbox and the area fragments below; shellcheck analyses
# one file at a time and so cannot see those uses.
# shellcheck disable=SC2034  # consumed by the sourced drivers/fragments
{
    SKILLS_DIR="$REPO_ROOT/plugins/review-audit/skills"
    REAL_BASH="$(command -v bash)"
    SK_SEC="$SKILLS_DIR/check-security"
    SK_HEALTH="$SKILLS_DIR/check-code-health"
}

# --- Shared drivers + area fragments ----------------------------------------

# shellcheck source=tests/lib/fragments.sh
source "$SCRIPT_DIR/lib/fragments.sh"
# shellcheck source=tests/lib/source-detectors-sandbox.sh
source "$SCRIPT_DIR/lib/source-detectors-sandbox.sh"

source_fragments "$SCRIPT_DIR/validate-source-detectors" \
    10-security.sh \
    20-code-health.sh

# --- Run all tests ----------------------------------------------------------
# Dispatch order is deliberate and is NOT definition order — preserved exactly
# as it stood before the split.
run_fragment_test test_security_secrets "check-security: AWS/GitHub/Stripe/PEM secrets + credential denylist + env.example skip"
run_fragment_test test_security_injection "check-security: py/js/rb SQL interpolation + concatenation + parameterized negative"
run_fragment_test test_security_xss "check-security: React/Vue/safe-filter/Blade XSS arms"
run_fragment_test test_security_crypto "check-security: md5/ECB fire, commented crypto skipped (comment boundary)"
run_fragment_test test_security_unreadable "check-security: an unreadable file is skipped, not crashed"
run_fragment_test test_health_debt "check-code-health: tech-debt marker"
run_fragment_test test_health_debug "check-code-health: py/js/rb/go/java/rs/swift debug arms + logger negative + test-file suppression"
run_fragment_test test_health_empty_handler "check-code-health: py/js/rb/go/rs/swift empty-handler arms + handled negative"
run_fragment_test test_health_test_file_and_skip "check-code-health: is_test_file segment anchoring + SKIP_GLOBS"
run_fragment_test test_health_dispatch_order_and_shape "check-code-health: bash dispatcher gates prints only, in print-then-debugger order (#686)"
run_fragment_test test_health_stdout_git_failure_fails_closed "check-code-health: a hanging git fails CLOSED and leaks nothing (#686)"
run_fragment_test test_health_stdout_is_output "check-code-health: stdout_is_output exempts prints only, keeps breakpoints (#686/#680 AC3)"
run_fragment_test test_health_stdout_repo_cleaned_up "check-code-health: the stdout match-repo is not leaked (#686)"

generate_report
