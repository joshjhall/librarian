# shellcheck shell=bash
# Security pre-scan delegation (#708)
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.
#
# The gate resolves check-security/patterns.sh at RUNTIME and hands it the same
# file list every other scanner reads. Unlike the sizing.sh arm -- which degrades
# gracefully -- this one FAILS LOUD when the scanner is unreachable, because a
# security scan that finds nothing because it did not run is byte-identical to a
# clean scan (#538/#571 inert-gate shape).
#
# THE CENTRAL PROPERTY these cases exist to pin is not "the refusal emits
# something". It is that ABSENT and CLEAN are DISTINGUISHABLE, in BOTH the exit
# code and the output. A test asserting only "no security rows" would pass with
# and without the whole arm ([[absence-assertion-needs-a-leak-fixture]]), so
# test_security_absent_differs_from_clean drives the same input down both paths
# and asserts the two outcomes DIVERGE.
#
# Absence is FORCED via SECURITY_SCANNER rather than skipped when the sibling
# plugin is missing ([[self-skipping-test-hides-the-risky-branch]]): a
# skip-if-absent arm only ever covers the present case, which is the one that
# already works.

# sec_run <file-list> [env-assignment] -- run the real gate capturing stdout,
# stderr and the exit code into SEC_OUT / SEC_ERR / SEC_RC. Single-consumer, so
# it lives here rather than in the shared library.
SEC_OUT=""
SEC_ERR=""
SEC_RC=0
sec_run() {
    local list="$1" override="${2:-}"
    local outfile errfile
    outfile="$(command mktemp)"
    errfile="$(command mktemp)"
    SEC_RC=0
    if [ -n "$override" ]; then
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "SECURITY_SCANNER=$override" \
            "$REAL_BASH" "$GATE" "$list" >"$outfile" 2>"$errfile" || SEC_RC=$?
    else
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" "$GATE" "$list" >"$outfile" 2>"$errfile" || SEC_RC=$?
    fi
    SEC_OUT="$(command cat "$outfile")"
    SEC_ERR="$(command cat "$errfile")"
    command rm -f "$outfile" "$errfile"
}

# A source carrying two detector-tripping patterns: an AWS key literal
# (hardcoded-secret) and an f-string SQL build (injection-risk). Both are
# check-security categories, so a row for either is attributable to the pre-scan
# and not to this gate's own four detectors.
write_vulnerable_source() {
    local dir="$1"
    command printf '%s\n' \
        'AWS_SECRET = "AKIA''IOSFODNN7EXAMPLE"' \
        'def q(uid, conn):' \
        '    return conn.execute(f"SELECT * FROM users WHERE id = {uid}")' \
        >"$dir/vuln.py"
}

# --- AC#1: the detector fires, deterministically -----------------------------

test_security_prescan_rows_reach_the_gate_output() {
    local d rows
    d="$(fresh_dir)"
    write_vulnerable_source "$d"
    sec_run "$(make_list "$d" vuln.py)"

    assert_equals "0" "$SEC_RC" "a resolvable scanner keeps the gate's exit-0 contract"
    rows="$(category_rows "$SEC_OUT" "hardcoded-secret")"
    assert_contains "$rows" "vuln.py" \
        "a hardcoded credential produces a deterministic hardcoded-secret row (#708 AC#1)"
    rows="$(category_rows "$SEC_OUT" "injection-risk")"
    assert_contains "$rows" "vuln.py" \
        "f-string SQL produces a deterministic injection-risk row (#708 AC#1)"
}

# The certainty column is load-bearing for the DISPOSITION criterion: a security
# finding reaches `R3-security-high` (blocking) only at HIGH. At MEDIUM or LOW it
# falls to R2-low-certainty / the deferrable bucket, which is the failure
# [[blocking-empty-is-not-nothing-to-fix]] names. Pin the column so a
# re-grading cannot quietly move these rows out of the blocking path.
test_security_rows_are_high_certainty() {
    local d row
    d="$(fresh_dir)"
    write_vulnerable_source "$d"
    sec_run "$(make_list "$d" vuln.py)"

    row="$(category_rows "$SEC_OUT" "hardcoded-secret" | command head -n 1)"
    assert_equals "HIGH" "$(field "$row" 5)" \
        "the row is HIGH — the certainty R3-security-high requires to block (#708)"
    assert_equals "5" "$(command printf '%s' "$row" | command awk -F'\t' '{print NF}')" \
        "the row keeps the 5-column TSV contract"
}

# --- AC#2: absence is loud, never a silent clean -----------------------------

test_security_scanner_absent_fails_loud() {
    local d
    d="$(fresh_dir)"
    write_vulnerable_source "$d"
    sec_run "$(make_list "$d" vuln.py)" "/nonexistent/check-security/patterns.sh"

    assert_exit 1 "$SEC_RC" \
        "an unresolvable scanner exits NON-ZERO, never 0-with-no-security-rows (#708 AC#2)"
    assert_contains "$SEC_ERR" "the security pre-scan did not run" \
        "the refusal says the scan did not run"
    assert_contains "$SEC_ERR" "review-audit" \
        "the refusal names the plugin that ships the scanner"
    assert_contains "$SEC_ERR" "claude plugin install review-audit@librarian" \
        "the refusal is ACTIONABLE — it names the install command"
    assert_contains "$SEC_ERR" "/nonexistent/check-security/patterns.sh" \
        "the refusal reports the path it actually resolved to"
    assert_contains "$SEC_OUT" "security-scan-unavailable" \
        "a caller reading only stdout still sees the absence as a marker row"
}

# A scanner that RESOLVES but fails is the same hazard by another route: it emits
# no rows and, without this arm, the gate would exit 0 on its silence.
test_security_scanner_failure_is_not_silence() {
    local d stub
    d="$(fresh_dir)"
    write_vulnerable_source "$d"
    stub="$d/exit2-scanner.sh"
    command printf '%s\n' '#!/usr/bin/env bash' 'exit 2' >"$stub"
    command chmod +x "$stub"
    sec_run "$(make_list "$d" vuln.py)" "$stub"

    assert_exit 1 "$SEC_RC" \
        "a scanner exiting non-zero also fails the gate loudly (#708 AC#2)"
    assert_contains "$SEC_ERR" "scanner exited non-zero" \
        "the refusal distinguishes a FAILING scanner from a MISSING one"
    assert_contains "$SEC_OUT" "security-scan-unavailable" \
        "the marker row is emitted for a failing scanner too"
}

# THE DISCRIMINATING CASE. Everything above could pass while `absent` and `clean`
# still looked alike to a caller. This drives the SAME clean input down both
# paths and asserts they diverge in both channels -- the property the whole
# runtime-resolution decision rests on.
test_security_absent_differs_from_clean() {
    local d list clean_rc clean_out absent_rc absent_out
    d="$(fresh_dir)"
    command mkdir -p "$d/tests"
    command printf '%s\n' 'VALUE = 1' >"$d/clean.py"
    command printf '%s\n' 'import clean' >"$d/tests/test_clean.py"
    list="$(make_list "$d" clean.py)"

    sec_run "$list"
    clean_rc="$SEC_RC"
    clean_out="$SEC_OUT"

    sec_run "$list" "/nonexistent/check-security/patterns.sh"
    absent_rc="$SEC_RC"
    absent_out="$SEC_OUT"

    # A genuinely clean scan: exit 0, and NO marker.
    assert_equals "0" "$clean_rc" "a clean diff with a working scanner exits 0"
    assert_not_contains "$clean_out" "security-scan-unavailable" \
        "a clean scan emits no unavailability marker"

    # The two outcomes must differ in BOTH channels. Asserting the exit codes are
    # unequal (rather than each value separately) is what makes this a
    # DIVERGENCE test: neutering the refusal to `return 0` makes it fail here
    # even if the marker string were still printed.
    assert_true "[ \"$clean_rc\" != \"$absent_rc\" ]" \
        "ABSENT and CLEAN differ in the EXIT CODE ($clean_rc vs $absent_rc) (#708 AC#2)"
    assert_true "[ \"$clean_out\" != \"$absent_out\" ]" \
        "ABSENT and CLEAN differ in the OUTPUT — silence is never mistaken for clean (#708 AC#2)"
}

# --- AC#3: the pre-scan's file scope matches the dimension's diff scope -------

# The security dimension reads the manifest the harness builds over `deltaFiles`
# on a narrowed cycle (#492) and over the full scope otherwise; the caller re-runs
# this gate on that same current scope. So the property to pin here is that the
# security scanner sees EXACTLY the gate's own list -- no wider (rows for files
# the reviewer cannot see) and no narrower (files scanned by nobody).
test_security_scope_matches_the_gate_file_list() {
    local d rows
    d="$(fresh_dir)"
    write_vulnerable_source "$d"
    command cp "$d/vuln.py" "$d/other.py"

    # FULL list: both files are in scope, so both must produce rows.
    sec_run "$(make_list "$d" vuln.py other.py)"
    rows="$(category_rows "$SEC_OUT" "hardcoded-secret")"
    assert_contains "$rows" "vuln.py" "full scope: the first file is scanned"
    assert_contains "$rows" "other.py" "full scope: the second file is scanned"

    # NARROWED list: the subset shape a re-review cycle passes. The excluded file
    # must produce NO row, or the reviewer would receive findings about a file
    # outside the delta it was given.
    sec_run "$(make_list "$d" vuln.py)"
    rows="$(category_rows "$SEC_OUT" "hardcoded-secret")"
    assert_contains "$rows" "vuln.py" "narrowed scope: the in-scope file is still scanned"
    assert_not_contains "$rows" "other.py" \
        "narrowed scope: an out-of-scope file produces NO row (#708 AC#3, #492)"
}

# --- Non-interference --------------------------------------------------------

test_security_arm_does_not_perturb_other_scanners() {
    local d
    d="$(fresh_dir)"
    command printf '%s\n' 'def f():' '    print("debug")' >"$d/app.py"
    sec_run "$(make_list "$d" app.py)"

    assert_equals "0" "$SEC_RC" "the security arm leaves the exit-0-on-findings contract intact"
    assert_contains "$(category_rows "$SEC_OUT" "debug-statement")" "app.py" \
        "the debug-statement detector still fires alongside the security arm"
    assert_contains "$(category_rows "$SEC_OUT" "missing-test-file")" "app.py" \
        "the missing-test-file detector still fires alongside the security arm"
}

# Even when the security arm REFUSES, the rows the gate already computed must
# still reach stdout: the refusal is appended last precisely so an operator does
# not lose findings they had earned.
test_security_refusal_preserves_earlier_rows() {
    local d
    d="$(fresh_dir)"
    command printf '%s\n' 'def f():' '    print("debug")' >"$d/app.py"
    sec_run "$(make_list "$d" app.py)" "/nonexistent/check-security/patterns.sh"

    assert_exit 1 "$SEC_RC" "the run still fails loudly"
    assert_contains "$(category_rows "$SEC_OUT" "debug-statement")" "app.py" \
        "a refusal does not discard the rows the other scanners already produced"
}

# --- Resolution arms ---------------------------------------------------------
#
# The dev-checkout probe is exercised by every other case here (they run the gate
# from the source tree). The INSTALLED-CACHE probe is not: it needs a
# <plugin>/<version>/skills/ layout, which the repo does not have. So synthesize
# one -- and give the two plugins DIFFERENT versions, because that is the whole
# reason the version segment is globbed rather than assumed to match workflow's.
#
# Both walks were originally derived on paper and both were off by one level,
# resolving nothing while the arm still "worked" (it refused, loudly, for the
# wrong reason). This case is what stops that returning.
test_security_scanner_resolves_from_installed_layout() {
    local root d rows
    root="$(fresh_dir)"
    command mkdir -p "$root/workflow/9.9.9/skills/ship-issue" \
        "$root/review-audit/8.8.8/skills/check-security"
    command cp "$GATE" "${GATE%/*}/test-discovery.sh" \
        "$root/workflow/9.9.9/skills/ship-issue/"
    command cp "${SECURITY_SCANNER_REAL%/*}/patterns.sh" \
        "${SECURITY_SCANNER_REAL%/*}/patterns.py" \
        "$root/review-audit/8.8.8/skills/check-security/"

    d="$(fresh_dir)"
    write_vulnerable_source "$d"

    SEC_RC=0
    SEC_OUT="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$root/workflow/9.9.9/skills/ship-issue/pre-review-gates.sh" \
        "$(make_list "$d" vuln.py)" 2>/dev/null)" || SEC_RC=$?

    assert_equals "0" "$SEC_RC" \
        "the installed-cache probe resolves — no refusal from a real plugin layout (#708)"
    rows="$(category_rows "$SEC_OUT" "hardcoded-secret")"
    assert_contains "$rows" "vuln.py" \
        "a MISMATCHED plugin version (9.9.9 vs 8.8.8) still resolves — the version segment is globbed, not assumed (#708)"
}

# make_versioned_cache <root> <workflow-version> <review-audit-version>...
# Build an installed-plugin layout where each review-audit version ships a STUB
# scanner that announces which version ran. Single-consumer, so it stays here.
make_versioned_cache() {
    local root="$1" wf_ver="$2"
    shift 2
    local v
    command mkdir -p "$root/workflow/$wf_ver/skills/ship-issue"
    command cp "$GATE" "${GATE%/*}/test-discovery.sh" "$root/workflow/$wf_ver/skills/ship-issue/"
    for v in "$@"; do
        command mkdir -p "$root/review-audit/$v/skills/check-security"
        command printf '%s\n' '#!/usr/bin/env bash' \
            "command echo \"RESOLVED-VERSION-$v\" >&2" 'exit 0' \
            >"$root/review-audit/$v/skills/check-security/patterns.sh"
    done
}

# Which version actually ran, from the stub's stderr marker.
resolved_version_of() {
    command printf '%s' "$1" | command sed -n 's/.*RESOLVED-VERSION-\([0-9.]*\).*/\1/p' | command head -n 1
}

# THE VERSION-SELECTION CONTRACT (#708 review cycle 1).
#
# An earlier revision selected with `sort | tail -n 1` and CALLED it
# "newest-last". Plain sort is lexicographic, so "10.0.0" < "9.9.9" and the first
# major rollover would have silently picked the STALE copy — a comment asserting
# what the code did not do ([[comment-asserts-intent-not-code]]). `sort -V` is
# the obvious fix and is banned repo-wide (GNU-only; see lint-agnix-clean.sh).
#
# The resolver therefore prefers the LOCKSTEP version (equal to this plugin's
# own — bin/release.sh stamps all plugins together), and falls back to a
# field-by-field numeric compare. Both arms are pinned, and the fallback fixture
# straddles the digit boundary because that is the only input where numeric and
# lexicographic ordering DISAGREE ([[fixture-must-express-the-divergent-case]]).
test_security_scanner_prefers_the_lockstep_version() {
    local root d
    root="$(fresh_dir)"
    make_versioned_cache "$root" "9.9.9" "8.8.8" "9.9.9" "10.0.0"
    d="$(fresh_dir)"
    write_vulnerable_source "$d"

    SEC_RC=0
    SEC_ERR="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$root/workflow/9.9.9/skills/ship-issue/pre-review-gates.sh" \
        "$(make_list "$d" vuln.py)" 2>&1 >/dev/null)" || SEC_RC=$?

    assert_equals "9.9.9" "$(resolved_version_of "$SEC_ERR")" \
        "the sibling matching THIS plugin's version wins, even with a numerically higher one present (#708)"
}

test_security_scanner_fallback_is_numeric_not_lexicographic() {
    local root d
    root="$(fresh_dir)"
    # workflow 7.7.7 has NO review-audit twin, so the lockstep arm cannot fire and
    # the numeric fallback is what is under test.
    make_versioned_cache "$root" "7.7.7" "8.8.8" "9.9.9" "10.0.0"
    d="$(fresh_dir)"
    write_vulnerable_source "$d"

    SEC_RC=0
    SEC_ERR="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$root/workflow/7.7.7/skills/ship-issue/pre-review-gates.sh" \
        "$(make_list "$d" vuln.py)" 2>&1 >/dev/null)" || SEC_RC=$?

    # 10.0.0 is the correct answer and the one a lexicographic sort gets WRONG
    # (it ranks "10.0.0" below "9.9.9"), so this assertion fails against the old
    # `sort | tail -n 1` spelling and passes against the numeric compare.
    assert_equals "10.0.0" "$(resolved_version_of "$SEC_ERR")" \
        "the fallback picks the numerically greatest version across the digit boundary — NOT the lexicographic max (#708)"
}

# The "nothing resolved at all" refusal branch, distinct from the
# SECURITY_SCANNER-points-at-a-missing-file branch every other absence case here
# drives. Its message differs ("Searched the dev checkout…" vs "Resolved to: …"),
# so without this the branch never runs and its wording could rot unnoticed
# ([[test-defined-but-never-registered]] in spirit: reachable code, no test).
test_security_scanner_unresolvable_branch_names_the_search() {
    local iso d
    iso="$(fresh_dir)"
    # A gate with NO resolvable sibling in any probe: copied to a bare directory
    # whose parents contain no review-audit tree at all, and SECURITY_SCANNER unset.
    command mkdir -p "$iso/lonely"
    command cp "$GATE" "${GATE%/*}/test-discovery.sh" "$iso/lonely/"
    d="$(fresh_dir)"
    write_vulnerable_source "$d"

    SEC_RC=0
    SEC_ERR="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$iso/lonely/pre-review-gates.sh" \
        "$(make_list "$d" vuln.py)" 2>&1 >/dev/null)" || SEC_RC=$?

    assert_exit 1 "$SEC_RC" \
        "an entirely unresolvable scanner still fails loud (#708 AC#2)"
    assert_contains "$SEC_ERR" "Searched the dev checkout and the installed plugin cache" \
        "the not-found branch names WHERE it looked — distinct from the resolved-but-missing branch"
    assert_contains "$SEC_ERR" "claude plugin install review-audit@librarian" \
        "the not-found branch is actionable too"
}

# A malformed version directory must never outrank a real one (#919 AC#3). The
# fixture puts it LAST in glob order (lexically after "8.8.8"), so it is the
# entry a `tail -n 1` — or any compare that treats a non-integer field as
# greater — would wrongly select. _prescan_ver_gt reads a non-integer field as
# 0, so it loses every comparison it takes part in.
test_security_scanner_malformed_version_cannot_outrank_a_real_one() {
    local root d
    root="$(fresh_dir)"
    # workflow 7.7.7 has no twin, so the lockstep arm cannot answer and the
    # numeric fallback is what decides.
    make_versioned_cache "$root" "7.7.7" "8.8.8" "not-a-version"
    d="$(fresh_dir)"
    write_vulnerable_source "$d"

    SEC_RC=0
    SEC_ERR="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$root/workflow/7.7.7/skills/ship-issue/pre-review-gates.sh" \
        "$(make_list "$d" vuln.py)" 2>&1 >/dev/null)" || SEC_RC=$?

    assert_equals "8.8.8" "$(resolved_version_of "$SEC_ERR")" \
        "a malformed version directory sorting LAST still loses to a real version (#919 AC#3)"
}
