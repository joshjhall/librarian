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

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

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
    fi | command awk -F '\t' -v c="$cat" '$3 == c'
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
fresh_dir() { command mktemp -d "$WORKDIR/case.XXXXXX"; }

# make_list OUTFILE PATH... — write a newline file list, echo its path.
make_list() {
    local out="$1"
    shift
    : >"$out"
    local p
    for p in "$@"; do
        command printf '%s\n' "$p" >>"$out"
    done
    command printf '%s' "$out"
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
    command printf 'aws = "%s"\n' "$AKIA_TOK" >"$d/aws.py"
    list="$(make_list "$d/l" "$d/aws.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "AWS access key pattern" \
        "security: AWS AKIA key fires"

    # GitHub token pattern.
    d="$(fresh_dir)"
    command printf 'gh = "%s"\n' "$GHP_TOK" >"$d/gh.py"
    list="$(make_list "$d/l" "$d/gh.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "GitHub token pattern" \
        "security: GitHub ghp_ token fires"

    # Stripe live-key pattern.
    d="$(fresh_dir)"
    command printf 'stripe = "%s"\n' "$STRIPE_TOK" >"$d/stripe.py"
    list="$(make_list "$d/l" "$d/stripe.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Stripe live key pattern" \
        "security: Stripe sk_live_ key fires"

    # Private-key header (per-language-agnostic, all files).
    d="$(fresh_dir)"
    command printf '%s\n' "-----BEGIN RSA PRIVATE KEY-----" >"$d/id.pem"
    list="$(make_list "$d/l" "$d/id.pem")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Private key header" \
        "security: PEM private-key header fires"

    # Generic credential assignment with a literal value fires...
    d="$(fresh_dir)"
    command printf '%s\n' 'password = "hunter2hunter2"' >"$d/cred.py"
    list="$(make_list "$d/l" "$d/cred.py")"
    assert_fires "$SK_SEC" "$list" hardcoded-secret "Possible hardcoded credential" \
        "security: generic credential assignment fires"

    # ...but the DENYLIST boundary keeps placeholder / env-read / comment silent.
    d="$(fresh_dir)"
    command printf '%s\n' \
        'password = "changeme_placeholder"' \
        'api_key = os.environ["API_KEY"]' \
        '# secret = "realvalue_but_comment"' >"$d/clean.py"
    list="$(make_list "$d/l" "$d/clean.py")"
    assert_silent "$SK_SEC" "$list" hardcoded-secret \
        "security: placeholder/env/comment credentials stay silent (denylist boundary)"

    # SKIP_GLOBS: a *.env.example carrying a real-looking secret is skipped whole.
    d="$(fresh_dir)"
    command printf 'stripe = "%s"\n' "$STRIPE_TOK" >"$d/secrets.env.example"
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
    command printf '%s\n' 'q = f"SELECT * FROM t WHERE id={i}"' >"$d/q.py"
    list="$(make_list "$d/l" "$d/q.py")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL in f-string" \
        "security: Python SQL f-string fires"

    # JS/TS template-literal SQL.
    d="$(fresh_dir)"
    command printf '%s\n' 'const q = `SELECT * FROM t WHERE x=${v}`;' >"$d/q.ts"
    list="$(make_list "$d/l" "$d/q.ts")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL in template literal" \
        "security: JS/TS SQL template literal fires"

    # Ruby string-interpolation SQL.
    d="$(fresh_dir)"
    command printf '%s\n' 'sql = "SELECT * FROM t WHERE id=#{id}"' >"$d/q.rb"
    list="$(make_list "$d/l" "$d/q.rb")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL with string interpolation" \
        "security: Ruby SQL interpolation fires"

    # SQL string concatenation (all languages).
    d="$(fresh_dir)"
    command printf '%s\n' 'q = "SELECT a FROM t" + tail' >"$d/c.py"
    list="$(make_list "$d/l" "$d/c.py")"
    assert_fires "$SK_SEC" "$list" injection-risk "SQL string concatenation" \
        "security: SQL string concatenation fires"

    # A parameterized query is NOT an injection risk.
    d="$(fresh_dir)"
    command printf '%s\n' 'cur.execute("SELECT * FROM t WHERE id=%s", (i,))' >"$d/safe.py"
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
    command printf '%s\n' "el.$react = {__html: raw};" >"$d/r.jsx"
    list="$(make_list "$d/l" "$d/r.jsx")"
    assert_fires "$SK_SEC" "$list" xss-risk "React raw HTML rendering" \
        "security: React dangerouslySetInnerHTML fires"

    d="$(fresh_dir)"
    command printf '%s\n' "<div $vue=\"userInput\"></div>" >"$d/v.html"
    list="$(make_list "$d/l" "$d/v.html")"
    assert_fires "$SK_SEC" "$list" xss-risk "Vue raw HTML directive" \
        "security: Vue v-html fires"

    d="$(fresh_dir)"
    command printf '%s\n' "{{ value|safe }}" >"$d/t.html"
    list="$(make_list "$d/l" "$d/t.html")"
    assert_fires "$SK_SEC" "$list" xss-risk "Template safe filter" \
        "security: Django/Jinja safe filter fires"

    d="$(fresh_dir)"
    command printf '%s\n' "$blade \$unescaped !!}" >"$d/b.blade.php"
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
    command printf '%s\n' 'digest = md5(payload)' >"$d/h.py"
    list="$(make_list "$d/l" "$d/h.py")"
    assert_fires "$SK_SEC" "$list" insecure-crypto "Weak hash algorithm" \
        "security: md5() weak hash fires"

    d="$(fresh_dir)"
    command printf '%s\n' "cipher = OpenSSL::Cipher.new('AES-128-ECB')" >"$d/e.rb"
    list="$(make_list "$d/l" "$d/e.rb")"
    assert_fires "$SK_SEC" "$list" insecure-crypto "ECB mode encryption" \
        "security: ECB mode fires"

    # BOUNDARY: a comment-only line mentioning md5/ECB is skipped (is_comment).
    d="$(fresh_dir)"
    command printf '%s\n' \
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
    command printf 'gh = "%s"\n' "$GHP_TOK" >"$d/nope.py"
    command chmod 000 "$d/nope.py"
    list="$(make_list "$d/l" "$d/nope.py")"
    # An unreadable file yields no rows (the per-file open() OSError arm) rather
    # than crashing. Root can read 000 files, so only assert the non-root case.
    if [ "$(command id -u)" -ne 0 ]; then
        assert_silent "$SK_SEC" "$list" hardcoded-secret \
            "security: an unreadable file is skipped, not crashed"
    else
        skip_test "security unreadable-file arm (running as root can read 0000)"
    fi
    command chmod 644 "$d/nope.py" 2>/dev/null || true
}

# ============================================================================
# check-code-health — tech-debt-marker + debug-statement + empty-handler
# ============================================================================
test_health_debt() {
    local d list
    d="$(fresh_dir)"
    command printf '%s\n' 'x = 1  # TODO: refactor this' >"$d/a.py"
    list="$(make_list "$d/l" "$d/a.py")"
    assert_fires "$SK_HEALTH" "$list" tech-debt-marker "Tech debt marker" \
        "health: a TODO marker fires"
}

test_health_debug() {
    local d list

    # Python print() fires...
    d="$(fresh_dir)"
    command printf '%s\n' 'print("hi")' >"$d/p.py"
    list="$(make_list "$d/l" "$d/p.py")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Python print() fires"

    # ...but print() that is a logging call is NOT a debug statement (negative).
    d="$(fresh_dir)"
    command printf '%s\n' 'logger.print("structured")' >"$d/log.py"
    list="$(make_list "$d/l" "$d/log.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: a logger.print() line stays silent (logging negative)"

    # Python debugger statement.
    d="$(fresh_dir)"
    command printf '%s\n' 'breakpoint()' >"$d/bp.py"
    list="$(make_list "$d/l" "$d/bp.py")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debugger statement" \
        "health: Python breakpoint() fires"

    # JS console + debugger.
    d="$(fresh_dir)"
    command printf '%s\n' 'console.log("x");' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Console debug statement" \
        "health: JS console.log fires"

    d="$(fresh_dir)"
    command printf '%s\n' 'debugger;' >"$d/d.js"
    list="$(make_list "$d/l" "$d/d.js")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debugger keyword" \
        "health: JS debugger keyword fires"

    # Ruby debugger.
    d="$(fresh_dir)"
    command printf '%s\n' 'binding.pry' >"$d/r.rb"
    list="$(make_list "$d/l" "$d/r.rb")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Ruby debugger" \
        "health: Ruby binding.pry fires"

    # Go debug print.
    d="$(fresh_dir)"
    command printf '%s\n' 'fmt.Println("x")' >"$d/g.go"
    list="$(make_list "$d/l" "$d/g.go")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Go fmt.Println fires"

    # Java debug print.
    d="$(fresh_dir)"
    command printf '%s\n' 'System.out.println("x");' >"$d/J.java"
    list="$(make_list "$d/l" "$d/J.java")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: Java System.out.println fires"

    # BOUNDARY: a debug print inside a TEST file is suppressed (not test_file only
    # applies debug scanning to non-test files).
    d="$(fresh_dir)"
    command printf '%s\n' 'print("hi")' >"$d/test_mod.py"
    list="$(make_list "$d/l" "$d/test_mod.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: a print() inside a test file is suppressed (is_test_file boundary)"
}

test_health_empty_handler() {
    local d list

    # Python empty except (pass).
    d="$(fresh_dir)"
    command printf '%s\n' 'try:' '    risky()' 'except Exception:' '    pass' >"$d/e.py"
    list="$(make_list "$d/l" "$d/e.py")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty except block" \
        "health: Python empty except (pass) fires"

    # ...but an except with a real body stays silent.
    d="$(fresh_dir)"
    command printf '%s\n' 'try:' '    risky()' 'except Exception:' '    log(e)' >"$d/ok.py"
    list="$(make_list "$d/l" "$d/ok.py")"
    assert_silent "$SK_HEALTH" "$list" empty-handler \
        "health: a handled except stays silent"

    # JS empty catch.
    d="$(fresh_dir)"
    command printf '%s\n' 'try { risky(); } catch (e) {}' >"$d/c.js"
    list="$(make_list "$d/l" "$d/c.js")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty catch block" \
        "health: JS empty catch fires"

    # Ruby empty rescue.
    d="$(fresh_dir)"
    command printf '%s\n' 'begin' '  risky' 'rescue' 'end' >"$d/r.rb"
    list="$(make_list "$d/l" "$d/r.rb")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Empty rescue block" \
        "health: Ruby empty rescue fires"

    # Go swallowed error.
    d="$(fresh_dir)"
    command printf '%s\n' 'if err != nil {}' >"$d/g.go"
    list="$(make_list "$d/l" "$d/g.go")"
    assert_fires "$SK_HEALTH" "$list" empty-handler "Swallowed error" \
        "health: Go swallowed error fires"
}

test_health_test_file_and_skip() {
    local d list

    # is_test_file segment anchoring: tests/helper.py IS a test → debug suppressed.
    d="$(fresh_dir)"
    command mkdir -p "$d/tests"
    command printf '%s\n' 'print("dbg")' >"$d/tests/helper.py"
    list="$(make_list "$d/l" "$d/tests/helper.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: print() under a tests/ segment is suppressed"

    # ...but contest.py is NOT a test file (segment-anchored, not substring) → fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'print("dbg")' >"$d/contest.py"
    list="$(make_list "$d/l" "$d/contest.py")"
    assert_fires "$SK_HEALTH" "$list" debug-statement "Debug print statement" \
        "health: contest.py is NOT a test file (segment anchoring negative)"

    # test_*.py basename arm → test file.
    d="$(fresh_dir)"
    command printf '%s\n' 'print("dbg")' >"$d/test_widget.py"
    list="$(make_list "$d/l" "$d/test_widget.py")"
    assert_silent "$SK_HEALTH" "$list" debug-statement \
        "health: test_widget.py basename is a test file"

    # SKIP_GLOBS: a *.md carrying a TODO is skipped wholesale.
    d="$(fresh_dir)"
    command printf '%s\n' '# TODO: doc marker' >"$d/notes.md"
    list="$(make_list "$d/l" "$d/notes.md")"
    assert_silent "$SK_HEALTH" "$list" tech-debt-marker \
        "health: a TODO inside a *.md is skipped (SKIP_GLOBS)"
}

# ============================================================================
# check-code-health — declared `stdout_is_output` (#686)
# ============================================================================
#
# The declaration is read from `<repo-root>/.claude/pre-review.yml`, and the
# scanner finds that root with `git rev-parse --show-toplevel` at runtime. So
# these fixtures need a real git sandbox AND the scanner has to run FROM INSIDE
# it — the shared emit_rows driver does not cd, which would make every case here
# resolve THIS repo's config instead of the fixture's. Hence the local drivers.

# health_rows_in DIR IMPL LIST CAT — like emit_rows, but cd'd into DIR first.
# `command env`, not a hardcoded /usr/bin/env: CLAUDE.md bans absolute paths to
# core utilities (#443). The sibling emit_rows above predates that rule and still
# hardcodes one; new code should not add instances.
health_rows_in() {
    local dir="$1" impl="$2" list="$3" cat="$4"
    if [ "$impl" = py ]; then
        (cd "$dir" && command env python3 "$SK_HEALTH/patterns.py" "$list" 2>/dev/null)
    else
        (cd "$dir" && command env PATTERNS_FORCE_BASH=1 "$REAL_BASH" \
            "$SK_HEALTH/patterns.sh" "$list" 2>/dev/null)
    fi | command awk -F '\t' -v c="$cat" '$3 == c'
}

# assert_health_in DIR LIST CAT MODE NEEDLE MSG — assert in BOTH impls, from
# inside DIR. MODE is "fires" (rows contain NEEDLE) or "absent" (they do not).
# Both impls are checked because python is the PRIMARY runtime and bash the
# fallback: a fix landing in only one is the exact defect this pair invites.
assert_health_in() {
    local dir="$1" list="$2" cat="$3" mode="$4" needle="$5" msg="$6"
    local out
    out="$(health_rows_in "$dir" sh "$list" "$cat")"
    if [ "$mode" = fires ]; then
        assert_contains "$out" "$needle" "$msg (bash)"
    else
        assert_not_contains "$out" "$needle" "$msg (bash)"
    fi
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(health_rows_in "$dir" py "$list" "$cat")"
        if [ "$mode" = fires ]; then
            assert_contains "$out" "$needle" "$msg (python)"
        else
            assert_not_contains "$out" "$needle" "$msg (python)"
        fi
    fi
}

# stdout_sandbox VARNAME [CONFIG_LINE...] — a git sandbox holding a declared CLI
# file (cli.py: a print AND a breakpoint) plus an undeclared control
# (other.py: a print). Writes .claude/pre-review.yml only when CONFIG_LINEs are
# given, so the no-config case is the same fixture minus the declaration.
STDOUT_LIST=""
stdout_sandbox() {
    local __out="$1" dir=""
    shift
    dir="$(fresh_dir)"
    command git init -q "$dir" 2>/dev/null
    command mkdir -p "$dir/src"
    # cli.py carries BOTH families on purpose: the exemption must reach the
    # print and NOT the breakpoint, and one file proves both halves at once.
    command printf '%s\n' 'print("real output")' 'breakpoint()' >"$dir/src/cli.py"
    command printf '%s\n' 'print("debug leftover")' >"$dir/src/other.py"
    if [ "$#" -gt 0 ]; then
        command mkdir -p "$dir/.claude"
        command printf '%s\n' "$@" >"$dir/.claude/pre-review.yml"
    fi
    STDOUT_LIST="$(make_list "$dir/l" "$dir/src/cli.py" "$dir/src/other.py")"
    printf -v "$__out" '%s' "$dir"
}

# The bash dispatcher's SHAPE, mirroring the Python source-order assertion in
# validate-python-ports.sh (#687). Both are source-level for the same reason:
# every pattern in both families is `^\s*`-anchored, so no single line can match
# both, and no input exists for which the call order changes the emitted bytes.
# Behaviour cannot witness the order — only the source can.
#
# It also pins the exemption's SHAPE, which behaviour alone leaves ambiguous:
# the two calls must be SEPARATE statements. Written as one `if`, a declaration
# would suppress the debugger row too; written this way, no such control path
# exists. That is #680 AC3 enforced structurally rather than asserted in prose.
test_health_dispatch_order_and_shape() {
    local block
    # The dispatch block: from the debug-statement marker to the end of its `if`.
    block="$(command awk '/--- Category: debug-statement ---/,/^    fi$/' \
        "$SK_HEALTH/patterns.sh")"

    assert_not_empty "$block" "the bash debug-statement dispatch block was found"

    local print_ln dbg_ln
    print_ln="$(command printf '%s\n' "$block" | command grep -n 'scan_debug_prints "\$file"' | command head -1 | command cut -d: -f1)"
    dbg_ln="$(command printf '%s\n' "$block" | command grep -n 'scan_debugger_statements "\$file"' | command head -1 | command cut -d: -f1)"

    assert_not_empty "$print_ln" "the dispatcher calls scan_debug_prints"
    assert_not_empty "$dbg_ln" "the dispatcher calls scan_debugger_statements"
    assert_true "[ \"${print_ln:-0}\" -lt \"${dbg_ln:-0}\" ]" \
        "bash dispatch order is print-then-debugger, matching patterns.py (#686)"

    # The print call is guarded by the predicate; the debugger call is NOT.
    assert_contains "$block" 'matches_declared_stdout_pattern "$file" || scan_debug_prints "$file"' \
        "the print call is gated by the stdout declaration (#686)"
    assert_not_contains "$block" 'matches_declared_stdout_pattern "$file" || scan_debugger_statements' \
        "the debugger call is NOT gated by the declaration (#680 AC3)"
}

test_health_stdout_is_output() {
    local d=""

    # --- declared: the print is exempt ---
    # The needle is the print's EVIDENCE TEXT, not the filename: cli.py still
    # appears in this run via its breakpoint row (the next assertion), so
    # "cli.py is absent" could never hold and would fail whatever the code did.
    stdout_sandbox d "stdout_is_output:" "  - src/cli.py"
    assert_health_in "$d" "$STDOUT_LIST" debug-statement absent 'print("real output")' \
        "health: a declared file's print() is exempt (#686)"

    # --- AC3: the SAME declared file's breakpoint still fires ---
    # This is the boundary #680 AC3 asks for, and the reason the dispatcher uses
    # two statements rather than an if/else. Without this case, widening the
    # exemption to cover the debugger family would pass every other assertion.
    assert_health_in "$d" "$STDOUT_LIST" debug-statement fires "Debugger statement" \
        "health: a declared file's breakpoint() STILL fires (#680 AC3)"

    # --- control: an undeclared sibling in the same run is untouched ---
    # Proves the exemption is per-file, not a global off-switch. Keyed on the
    # control's own print evidence for the same reason as above.
    assert_health_in "$d" "$STDOUT_LIST" debug-statement fires 'print("debug leftover")' \
        "health: an UNDECLARED file's print() still fires (#686)"

    # --- no config at all: pre-#686 behaviour, exactly ---
    # The common path. If the predicate ever defaulted true, every repo without
    # a config would silently lose its print findings — so this is the case that
    # would catch it.
    local noconf=""
    stdout_sandbox noconf
    assert_health_in "$noconf" "$STDOUT_LIST" debug-statement fires 'print("real output")' \
        "health: with NO .claude/pre-review.yml, print() fires as before (#686)"

    # --- config present but key absent ---
    # A repo declaring some OTHER key must not accidentally enable the
    # exemption: the loader reads the file but finds no patterns.
    local otherkey=""
    stdout_sandbox otherkey "test_skip_patterns:" "  - vendor/**"
    assert_health_in "$otherkey" "$STDOUT_LIST" debug-statement fires 'print("real output")' \
        "health: a config without stdout_is_output leaves print() firing (#686)"

    # --- a GLOB, not just a literal path ---
    # SKILL.md documents these values as gitignore-style patterns and gives
    # `bin/*.js` as the worked example, but every case above declares an exact
    # path. Matching is delegated to `git check-ignore`, so a glob should work —
    # "should" being the point: a documented example nothing exercises is how
    # docs drift from behaviour.
    #
    # `src/*.py` matches BOTH fixture files, so this also shows the exemption
    # applying to a file never named literally.
    local globbed=""
    stdout_sandbox globbed "stdout_is_output:" "  - src/*.py"
    assert_health_in "$globbed" "$STDOUT_LIST" debug-statement absent 'print("real output")' \
        "health: a glob pattern exempts the file it matches (#686)"
    assert_health_in "$globbed" "$STDOUT_LIST" debug-statement absent 'print("debug leftover")' \
        "health: a glob exempts a file never named literally (#686)"
    # ...and the AC3 boundary holds under a glob too, not just a literal.
    assert_health_in "$globbed" "$STDOUT_LIST" debug-statement fires "Debugger statement" \
        "health: a glob-declared file's breakpoint() STILL fires (#680 AC3)"
}

# The temp match-repo must not leak. #680 added a repo to the reference impl
# without a cleanup branch and leaked one per run; the failure is silent (a
# stray /tmp dir, no error, no wrong output), so it needs a behavioural check
# rather than a code read.
#
# Each impl runs with TMPDIR pointed at a PRIVATE, EMPTY scratch dir, and the
# assertion is that the dir is empty afterwards. Two reasons that beats counting
# /tmp:
#
#   1. It is naming-agnostic. `mktemp -d` produces `tmp.XXXX` but Python's
#      `tempfile.mkdtemp()` produces `tmpXXXX` with NO dot, so a `tmp.*` glob
#      silently misses every Python leak — and Python is the PRIMARY runtime, so
#      the check would have covered only the fallback while claiming both.
#   2. Nothing else writes there, so a busy /tmp on the host cannot make it flap.
#
# Asserted per-impl rather than once at the end: a shared counter cannot say
# WHICH runtime leaked, and "one of the two leaked" is the report you least want
# at 2am.
test_health_stdout_repo_cleaned_up() {
    local d="" scratch=""

    stdout_sandbox d "stdout_is_output:" "  - src/cli.py"

    scratch="$(fresh_dir)"
    TMPDIR="$scratch" health_rows_in "$d" sh "$STDOUT_LIST" debug-statement >/dev/null
    assert_equals "" "$(command ls -A "$scratch" 2>/dev/null)" \
        "health: the bash impl leaves no temp match-repo behind (#686)"

    if [ "$HAVE_PY" -eq 1 ]; then
        scratch="$(fresh_dir)"
        TMPDIR="$scratch" health_rows_in "$d" py "$STDOUT_LIST" debug-statement >/dev/null
        assert_equals "" "$(command ls -A "$scratch" 2>/dev/null)" \
            "health: the python impl leaves no temp match-repo behind (#686)"
    fi
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
run_test test_health_dispatch_order_and_shape "check-code-health: bash dispatcher gates prints only, in print-then-debugger order (#686)"
run_test test_health_stdout_is_output "check-code-health: stdout_is_output exempts prints only, keeps breakpoints (#686/#680 AC3)"
run_test test_health_stdout_repo_cleaned_up "check-code-health: the stdout match-repo is not leaked (#686)"

generate_report
