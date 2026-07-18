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
# Pure bash-3.2 + coreutils; full /usr/bin/* paths per project convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/plugins/review-audit/skills"

REAL_BASH="$(command -v bash)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "check-security + check-code-health detector fixtures (#348)"

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

WORKDIR="$(/usr/bin/mktemp -d)"
trap '/usr/bin/rm -rf "$WORKDIR"' EXIT

SK_SEC="$SKILLS_DIR/check-security"
SK_HEALTH="$SKILLS_DIR/check-code-health"

# --- Scanner drivers ---------------------------------------------------------
# emit_rows IMPL SKILLDIR LIST CAT [ENV...] — the rows one impl emits for a
# single category. IMPL is "py" or "sh"; extra args are VAR=VALUE env overrides.
emit_rows() {
    local impl="$1" skill="$2" list="$3" cat="$4"
    shift 4
    if [ "$impl" = py ]; then
        /usr/bin/env "$@" python3 "$skill/patterns.py" "$list" 2>/dev/null
    else
        /usr/bin/env PATTERNS_FORCE_BASH=1 "$@" "$REAL_BASH" "$skill/patterns.sh" "$list" 2>/dev/null
    fi | /usr/bin/awk -F '\t' -v c="$cat" '$3 == c'
}

# assert_fires SKILLDIR LIST CAT NEEDLE MSG [ENV...] — the category fires (rows
# contain NEEDLE) in BOTH impls. Python side skipped (not failed) when absent.
assert_fires() {
    local skill="$1" list="$2" cat="$3" needle="$4" msg="$5"
    shift 5
    assert_contains "$(emit_rows sh "$skill" "$list" "$cat" "$@")" \
        "$needle" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_contains "$(emit_rows py "$skill" "$list" "$cat" "$@")" \
            "$needle" "$msg (python)"
    fi
}

# assert_silent SKILLDIR LIST CAT MSG [ENV...] — the category emits NOTHING in
# both impls.
assert_silent() {
    local skill="$1" list="$2" cat="$3" msg="$4"
    shift 4
    assert_output_empty "$(emit_rows sh "$skill" "$list" "$cat" "$@")" \
        "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty "$(emit_rows py "$skill" "$list" "$cat" "$@")" \
            "$msg (python)"
    fi
}

# fresh_dir — unique scratch dir per fixture so path resolution is clean.
fresh_dir() { /usr/bin/mktemp -d "$WORKDIR/case.XXXXXX"; }

# make_list OUTFILE PATH... — write a newline file list, echo its path.
make_list() {
    local out="$1"
    shift
    : >"$out"
    local p
    for p in "$@"; do
        /usr/bin/printf '%s\n' "$p" >>"$out"
    done
    /usr/bin/printf '%s' "$out"
}

# Fake secret tokens assembled from fragments so THIS gate file holds no
# contiguous secret for a scanner/gitleaks to flag; the fixtures on disk carry
# the full token. All are obvious fakes (sequential/repeated filler).
AKIA_TOK="AKIA""0123456789ABCDEF"
GHP_TOK="ghp_""ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
STRIPE_TOK="sk_""live_""ABCDEFGHIJKLMNOPQRSTUV"

# ============================================================================
# check-security — hardcoded-secret
# ============================================================================
test_security_secrets() {
    local d list

    # AWS access-key pattern.
    d="$(fresh_dir)"
    /usr/bin/printf 'aws = "%s"\n' "$AKIA_TOK" >"$d/aws.py"
    list="$(make_list "$d/l" "$d/aws.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "AWS access key pattern" \
        "security: AWS AKIA key fires"

    # GitHub token pattern.
    d="$(fresh_dir)"
    /usr/bin/printf 'gh = "%s"\n' "$GHP_TOK" >"$d/gh.py"
    list="$(make_list "$d/l" "$d/gh.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "GitHub token pattern" \
        "security: GitHub ghp_ token fires"

    # Stripe live-key pattern.
    d="$(fresh_dir)"
    /usr/bin/printf 'stripe = "%s"\n' "$STRIPE_TOK" >"$d/stripe.py"
    list="$(make_list "$d/l" "$d/stripe.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Stripe live key pattern" \
        "security: Stripe sk_live_ key fires"

    # Private-key header (per-language-agnostic, all files).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' "-----BEGIN RSA PRIVATE KEY-----" >"$d/id.pem"
    list="$(make_list "$d/l" "$d/id.pem")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Private key header" \
        "security: PEM private-key header fires"

    # Generic credential assignment with a literal value fires...
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'password = "hunter2hunter2"' >"$d/cred.py"
    list="$(make_list "$d/l" "$d/cred.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: generic credential assignment fires"

    # ...but the DENYLIST boundary keeps placeholder / env-read / comment silent.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' \
        'password = "changeme_placeholder"' \
        'api_key = os.environ["API_KEY"]' \
        '# secret = "realvalue_but_comment"' >"$d/clean.py"
    list="$(make_list "$d/l" "$d/clean.py")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: placeholder/env/comment credentials stay silent (denylist boundary)"

    # SKIP_GLOBS: a *.env.example carrying a real-looking secret is skipped whole.
    d="$(fresh_dir)"
    /usr/bin/printf 'stripe = "%s"\n' "$STRIPE_TOK" >"$d/secrets.env.example"
    list="$(make_list "$d/l" "$d/secrets.env.example")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: a secret inside *.env.example is skipped (SKIP_GLOBS)"
}

# ============================================================================
# check-security — injection-risk (per-language SQL)
# ============================================================================
test_security_injection() {
    local d list

    # Python f-string SQL.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'q = f"SELECT * FROM t WHERE id={i}"' >"$d/q.py"
    list="$(make_list "$d/l" "$d/q.py")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL in f-string" \
        "security: Python SQL f-string fires"

    # JS/TS template-literal SQL.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'const q = `SELECT * FROM t WHERE x=${v}`;' >"$d/q.ts"
    list="$(make_list "$d/l" "$d/q.ts")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL in template literal" \
        "security: JS/TS SQL template literal fires"

    # Ruby string-interpolation SQL.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'sql = "SELECT * FROM t WHERE id=#{id}"' >"$d/q.rb"
    list="$(make_list "$d/l" "$d/q.rb")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL with string interpolation" \
        "security: Ruby SQL interpolation fires"

    # SQL string concatenation (all languages).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'q = "SELECT a FROM t" + tail' >"$d/c.py"
    list="$(make_list "$d/l" "$d/c.py")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL string concatenation" \
        "security: SQL string concatenation fires"

    # A parameterized query is NOT an injection risk.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'cur.execute("SELECT * FROM t WHERE id=%s", (i,))' >"$d/safe.py"
    list="$(make_list "$d/l" "$d/safe.py")"
    assert_silent "$SK_SEC" "$list" injection-risk \
        "security: a parameterized query stays silent"
}

# ============================================================================
# check-security — xss-risk (per-framework)
# ============================================================================
test_security_xss() {
    local d list
    # React dangerouslySetInnerHTML — fragmented so this gate is not self-flagged.
    local react="dangerously""SetInnerHTML"
    local vue="v-""html"
    local blade="{""!!"

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' "el.$react = {__html: raw};" >"$d/r.jsx"
    list="$(make_list "$d/l" "$d/r.jsx")"
    assert_fires "$SK_SEC" "$list" xss-risk "React raw HTML rendering" \
        "security: React dangerouslySetInnerHTML fires"

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' "<div $vue=\"userInput\"></div>" >"$d/v.html"
    list="$(make_list "$d/l" "$d/v.html")"
    assert_fires "$SK_SEC" "$list" xss-risk "Vue raw HTML directive" \
        "security: Vue v-html fires"

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' "{{ value|safe }}" >"$d/t.html"
    list="$(make_list "$d/l" "$d/t.html")"
    assert_fires "$SK_SEC" "$list" xss-risk "Template safe filter" \
        "security: Django/Jinja safe filter fires"

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' "$blade \$unescaped !!}" >"$d/b.blade.php"
    list="$(make_list "$d/l" "$d/b.blade.php")"
    assert_fires "$SK_SEC" "$list" xss-risk "Blade unescaped output" \
        "security: Blade {!! !!} fires"
}

# ============================================================================
# check-security — insecure-crypto (comment-skip boundary)
# ============================================================================
test_security_crypto() {
    local d list

    # md5()/sha1() and ECB fire on real code lines.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'digest = md5(payload)' >"$d/h.py"
    list="$(make_list "$d/l" "$d/h.py")"
    assert_fires "$SK_SEC" "$list" insecure-crypto "Weak hash algorithm" \
        "security: md5() weak hash fires"

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' "cipher = OpenSSL::Cipher.new('AES-128-ECB')" >"$d/e.rb"
    list="$(make_list "$d/l" "$d/e.rb")"
    assert_fires "$SK_SEC" "$list" insecure-crypto "ECB mode encryption" \
        "security: ECB mode fires"

    # BOUNDARY: a comment-only line mentioning md5/ECB is skipped (is_comment).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' \
        '# md5(commented) must be skipped' \
        '// ECB in a comment must be skipped' >"$d/c.py"
    list="$(make_list "$d/l" "$d/c.py")"
    assert_silent "$SK_SEC" "$list" insecure-crypto \
        "security: commented md5/ECB stay silent (comment-skip boundary)"
}

# ============================================================================
# check-security — unreadable file (scan_file OSError arm)
# ============================================================================
test_security_unreadable() {
    local d list
    d="$(fresh_dir)"
    /usr/bin/printf 'gh = "%s"\n' "$GHP_TOK" >"$d/nope.py"
    /usr/bin/chmod 000 "$d/nope.py"
    list="$(make_list "$d/l" "$d/nope.py")"
    # An unreadable file yields no rows (the per-file open() OSError arm) rather
    # than crashing. Root can read 000 files, so only assert the non-root case.
    if [ "$(/usr/bin/id -u)" -ne 0 ]; then
        assert_silent "$SK_SEC" "$list" hardcoded-secret \
            "security: an unreadable file is skipped, not crashed"
    else
        skip_test "security unreadable-file arm (running as root can read 0000)"
    fi
    /usr/bin/chmod 644 "$d/nope.py" 2>/dev/null || true
}

# ============================================================================
# check-code-health — tech-debt-marker + debug-statement + empty-handler
# ============================================================================
test_health_debt() {
    local d list
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'x = 1  # TODO: refactor this' >"$d/a.py"
    list="$(make_list "$d/l" "$d/a.py")"
    assert_fires "$SK_HEALTH" "$list" tech-debt-marker "Tech debt marker" \
        "health: a TODO marker fires"
}

test_health_debug() {
    local d list

    # Python print() fires...
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'print("hi")' >"$d/p.py"
    list="$(make_list "$d/l" "$d/p.py")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Python print() fires"

    # ...but print() that is a logging call is NOT a debug statement (negative).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'logger.print("structured")' >"$d/log.py"
    list="$(make_list "$d/l" "$d/log.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: a logger.print() line stays silent (logging negative)"

    # Python debugger statement.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'breakpoint()' >"$d/bp.py"
    list="$(make_list "$d/l" "$d/bp.py")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debugger statement" \
        "health: Python breakpoint() fires"

    # JS console + debugger.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'console.log("x");' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Console debug statement" \
        "health: JS console.log fires"

    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'debugger;' >"$d/d.js"
    list="$(make_list "$d/l" "$d/d.js")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debugger keyword" \
        "health: JS debugger keyword fires"

    # Ruby debugger.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'binding.pry' >"$d/r.rb"
    list="$(make_list "$d/l" "$d/r.rb")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Ruby debugger" \
        "health: Ruby binding.pry fires"

    # Go debug print.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'fmt.Println("x")' >"$d/g.go"
    list="$(make_list "$d/l" "$d/g.go")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Go fmt.Println fires"

    # Java debug print.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'System.out.println("x");' >"$d/J.java"
    list="$(make_list "$d/l" "$d/J.java")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Java System.out.println fires"

    # BOUNDARY: a debug print inside a TEST file is suppressed (not test_file only
    # applies debug scanning to non-test files).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'print("hi")' >"$d/test_mod.py"
    list="$(make_list "$d/l" "$d/test_mod.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: a print() inside a test file is suppressed (is_test_file boundary)"
}

test_health_empty_handler() {
    local d list

    # Python empty except (pass).
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'try:' '    risky()' 'except Exception:' '    pass' >"$d/e.py"
    list="$(make_list "$d/l" "$d/e.py")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty except block" \
        "health: Python empty except (pass) fires"

    # ...but an except with a real body stays silent.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'try:' '    risky()' 'except Exception:' '    log(e)' >"$d/ok.py"
    list="$(make_list "$d/l" "$d/ok.py")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: a handled except stays silent"

    # JS empty catch.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'try { risky(); } catch (e) {}' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: JS empty catch fires"

    # Ruby empty rescue.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'begin' '  risky' 'rescue' 'end' >"$d/r.rb"
    list="$(make_list "$d/l" "$d/r.rb")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty rescue block" \
        "health: Ruby empty rescue fires"

    # Go swallowed error.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'if err != nil {}' >"$d/g.go"
    list="$(make_list "$d/l" "$d/g.go")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Swallowed error" \
        "health: Go swallowed error fires"
}

test_health_test_file_and_skip() {
    local d list

    # is_test_file segment anchoring: tests/helper.py IS a test → debug suppressed.
    d="$(fresh_dir)"
    /usr/bin/mkdir -p "$d/tests"
    /usr/bin/printf '%s\n' 'print("dbg")' >"$d/tests/helper.py"
    list="$(make_list "$d/l" "$d/tests/helper.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: print() under a tests/ segment is suppressed"

    # ...but contest.py is NOT a test file (segment-anchored, not substring) → fires.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'print("dbg")' >"$d/contest.py"
    list="$(make_list "$d/l" "$d/contest.py")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: contest.py is NOT a test file (segment anchoring negative)"

    # test_*.py basename arm → test file.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' 'print("dbg")' >"$d/test_widget.py"
    list="$(make_list "$d/l" "$d/test_widget.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: test_widget.py basename is a test file"

    # SKIP_GLOBS: a *.md carrying a TODO is skipped wholesale.
    d="$(fresh_dir)"
    /usr/bin/printf '%s\n' '# TODO: doc marker' >"$d/notes.md"
    list="$(make_list "$d/l" "$d/notes.md")"
    assert_silent "$SK_HEALTH" "$list" tech-debt-marker \
        "health: a TODO inside a *.md is skipped (SKIP_GLOBS)"
}

run_test test_security_secrets "check-security: AWS/GitHub/Stripe/PEM secrets + credential denylist + env.example skip"
run_test test_security_injection "check-security: py/js/rb SQL interpolation + concatenation + parameterized negative"
run_test test_security_xss "check-security: React/Vue/safe-filter/Blade XSS arms"
run_test test_security_crypto "check-security: md5/ECB fire, commented crypto skipped (comment boundary)"
run_test test_security_unreadable "check-security: an unreadable file is skipped, not crashed"
run_test test_health_debt "check-code-health: tech-debt marker"
run_test test_health_debug "check-code-health: py/js/rb/go/java debug arms + logger negative + test-file suppression"
run_test test_health_empty_handler "check-code-health: py/js/rb/go empty-handler arms + handled negative"
run_test test_health_test_file_and_skip "check-code-health: is_test_file segment anchoring + SKIP_GLOBS"

generate_report
