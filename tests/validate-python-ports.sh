#!/usr/bin/env bash
# Python-port contract + parity gate (issue #17).
#
# Skill pre-scan tools are migrating to a Python 3.11+ primary implementation
# (patterns.py) behind the same TSV contract as the bash fallback (patterns.sh),
# selected at dispatch by a shim in patterns.sh. This gate pins, for every
# patterns.py in the tree:
#
#   1. Edge-case contract under python3 — no arg -> exit 1 + `Usage` on stderr;
#      empty file list -> exit 0 with no output (the same contract
#      validate-prescans.sh pins for the bash entry points).
#   2. bash<->python PARITY — the bash fallback (forced via PATTERNS_FORCE_BASH=1)
#      and the python impl must emit byte-identical findings over a fixture tree.
#      This is what makes the port a safe drop-in: the language boundary is the
#      output, not the implementation.
#
# The whole suite SKIPS (does not fail) when a python3>=3.11 is unavailable,
# mirroring run-all.sh's node-absent skip — a host without the primary runtime
# still exercises the bash path via validate-prescans.sh; parity can only be
# asserted where both runtimes exist.
#
# WHAT PARITY DOES **NOT** PROVE (#684). The contract is same-OUTPUT-on-this-HOST,
# not same-INTENT. Two consequences, both load-bearing when reading a green run:
#
#   1. A defect present in BOTH impls passes. Parity compares them to each other,
#      never to what the pattern was meant to match, so an identical bug is
#      invisible by construction. This is not hypothetical: the Go no-assertions
#      pattern in loop-make-it-work carried a trailing `\b` in patterns.sh AND
#      patterns.py that rejected `t.Errorf`/`t.Fatalf`/`t.Logf` — Go's dominant
#      assertion idioms — so ordinary Go tests were reported as having NO
#      assertions at HIGH. This gate stayed green through the entire lifetime of
#      that bug and through #679. Only a fixture asserting the INTENDED match
#      catches that class; those live in the per-detector suites
#      (validate-loop-detectors.sh et al.), which is where such a case belongs.
#
#   2. Divergence that appears only under BSD semantics is out of reach here.
#      Python `re` implements `\s`/`\w`/`\b` natively, while the bash fallback
#      inherits the host's grep/sed dialect — so the two can agree perfectly on a
#      GNU host and disagree on macOS, and this gate cannot tell. Closing that
#      needs a BSD userland, which is what the `bsd-probe` job on macos-latest
#      (ci.yml) and tests/probe-bsd-regex.sh provide; this suite runs there too,
#      so a BSD-only parity break surfaces in that job rather than here.
#
# Pure bash + coreutils + python3; no network, no jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

test_suite "Python-port contract + bash parity (#17)"

# Gate the whole suite on a usable primary runtime (python3>=3.11).
if ! command -v python3 >/dev/null 2>&1 ||
    ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    skip_test "python3>=3.11 not available (bash path is covered by validate-prescans.sh)"
    generate_report
    return 0 2>/dev/null || exit 0
fi

# List every ported tool across all plugins (absolute paths, sorted).
#
# DISCOVERY IS BY PAIR NAME, NOT BY THE LITERAL `patterns.py` (#695). The
# original form globbed `-name 'patterns.py'`, which silently EXCLUDED any port
# whose pair is named anything else — and a tool this gate does not see is a tool
# whose bash and python halves can drift apart freely, which is the one thing
# this gate exists to prevent. ship-issue's sizing.{py,sh} is exactly that case:
# it lives beside a 1,572-line bash pre-review-gates.sh that is NOT ported, so
# naming its pair `patterns.*` would have been actively misleading.
#
# PORT_BASENAMES is the explicit list of pair stems. Add a stem here when a new
# <stem>.py / <stem>.sh port appears; the sibling-resolution below keys off the
# same list, so one edit covers discovery, the edge-case contract, and parity.
#
# SCOPE: this gate's contract is FILE-LIST shaped (argv[1] is a list of paths to
# scan; no args -> exit 1 + Usage; empty list -> exit 0 + no output). A port with
# a different CLI shape does not belong here and must be pinned by its own suite
# instead of being bent to fit. ship-issue's split-verify.{py,sh} is that case —
# its argv is `<original> <post-split-original> [results...]`, for which "empty
# file list exits 0" is meaningless — so its bash<->python parity is asserted
# per-case in tests/validate-split-verify.sh rather than over this corpus.
PORT_BASENAMES="patterns sizing"

list_python_ports() {
    local stem
    for stem in $PORT_BASENAMES; do
        command find "$PLUGINS_DIR" -type f -name "${stem}.py" 2>/dev/null
    done | command sort
}

# sibling_sh PY — the bash fallback paired with PY, by stem substitution.
# Derived rather than hardcoded so a new stem in PORT_BASENAMES needs no edit here.
sibling_sh() {
    command printf '%s' "${1%.py}.sh"
}

# A shared fixture tree exercising the categories/dispatch a security-style
# scanner cares about. It is deliberately generic (secrets, SQL, XSS, crypto,
# debug markers) so the same tree meaningfully exercises any ported tool; a tool
# that finds nothing in it still asserts parity (both impls emit nothing).
WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT
FIXDIR="$WORKDIR/fix"
command mkdir -p "$FIXDIR"

# The fake secret tokens (GitHub PAT, AWS key, Stripe key) are assembled at
# runtime from fragments so this TEST FILE contains no contiguous secret for the
# gitleaks pre-commit hook to flag — while the fixture files written to disk hold
# the full contiguous token the scanner must match. (The tokens are obvious fakes:
# repeated/sequential filler, not real credentials.)
GH_TOK="ghp_""ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
AWS_TOK="AKIA""0123456789ABCDEF"
STRIPE_TOK="sk_""live_""ABCDEFGHIJKLMNOPQRSTUV"

# app.py also carries #183 regression lines: an x/2/7-bearing single-quoted
# secret (loop-make-it-secure's fixed \x27 class), a yaml.load with and without a
# Loader= (its fixed deserialization filter), and a def whose body is only `pass`
# (loop-make-it-work's fixed empty-body arm). A divergence between the bash and
# python impls on any of these fails the parity assertion below.
#
# The trailing print() lines carry the #604 case: two debug prints whose
# ARGUMENT contains regex-shaped text (an `re.search(r"..."` literal and a
# `grep -niE -- '...'` literal). Before #604 both impls suppressed them, and
# parity was green on the shared false negative — the exact relative-property
# failure mode #605 describes. Both now emit debug-statement rows, and parity
# holds on the corrected behavior. Keep them: they are the fixture's only
# coverage of that branch.
command cat >"$FIXDIR/app.py" <<'EOF'
import hashlib
query = f"SELECT * FROM users WHERE id={user_id}"
single_q = f'SELECT * FROM t WHERE id={i}'
digest = md5(payload)
secret = "abcdefghijkl"
xor_secret = "value_x2_7_here"
# md5(commented) is skipped — the crypto comment-skip is live (#168)
placeholder = "changeme_example_value"
concat = "SELECT a FROM t" + tail
api_key = 'sk2live7value_xx'
loaded = yaml.load(payload)
safe_loaded = yaml.load(payload, Loader=SafeLoader)
def empty_impl():
    pass
print(re.search(r"^\s*console\.(log|debug)\(", line))
print("command grep -niE -- 'it.s worth noting that'")
print("a genuine debug print")
print("grep -vE no end-of-options marker here")
EOF
command printf 'gh = "%s"\n' "$GH_TOK" >>"$FIXDIR/app.py"

command cat >"$FIXDIR/app.ts" <<'EOF'
const sql = `SELECT * FROM t WHERE x=${val}`;
node.innerHTML = raw;
const spaced = () => { }
EOF
command printf 'const awsKey = "%s";\n' "$AWS_TOK" >>"$FIXDIR/app.ts"

# app.go exercises loop-make-it-documented's fixed Go GoDoc arm and
# loop-make-it-work's fixed empty-brace whitespace class (#183).
command cat >"$FIXDIR/app.go" <<'EOF'
package main

func Undocumented() {}

func Spaced() { }
EOF

command cat >"$FIXDIR/view.html" <<'EOF'
<div v-html="userInput"></div>
{{ value|safe }}
{!! $unescaped !!}
EOF

command cat >"$FIXDIR/model.rb" <<'EOF'
sql = "SELECT * FROM t WHERE id=#{id}"
cipher = OpenSSL::Cipher.new('AES-128-ECB')
EOF

# Skip-glob coverage: an .env.example holding a secret must be ignored.
command printf 'key = "%s"\n' "$STRIPE_TOK" >"$FIXDIR/secrets.env.example"

# ESM/CJS extension coverage (#568). Both impls route .mjs/.cjs through their
# js/ts arms; without a fixture carrying these extensions the parity assertion
# passes VACUOUSLY with respect to that branch — it never runs. A top-level
# console.log is the cheapest input that reaches the arm in every ported tool.
command cat >"$FIXDIR/tool.mjs" <<'EOF'
console.log('left in by accident');
export function undocumented() {}
EOF

command cat >"$FIXDIR/tool.cjs" <<'EOF'
console.log('left in by accident');
module.exports.thing = function () {};
EOF

# Shell coverage (#598). The fixture tree carried NO .sh at all, so every
# shell-handling branch in every port was asserted vacuously — the same trap the
# .mjs/.cjs comment above records, and the reason #568's lesson was "a fixture
# lacking the extension asserts nothing". This is the language most of this
# repo's own tooling is written in.
#
# Content is chosen to reach several arms at once: a TODO marker, a swallowed
# error (`|| true`), and a function definition.
command cat >"$FIXDIR/tool.sh" <<'EOF'
#!/usr/bin/env bash
# TODO: implement
run_thing() {
    do_work || true
}
run_thing
EOF

FILE_LIST="$WORKDIR/list.txt"
: >"$FILE_LIST"
for f in "$FIXDIR/app.py" "$FIXDIR/app.ts" "$FIXDIR/app.go" "$FIXDIR/view.html" \
    "$FIXDIR/model.rb" "$FIXDIR/secrets.env.example" \
    "$FIXDIR/tool.mjs" "$FIXDIR/tool.cjs" "$FIXDIR/tool.sh"; do
    command printf '%s\n' "$f" >>"$FILE_LIST"
done

EMPTY="$WORKDIR/empty.txt"
: >"$EMPTY"

# drift-detect is the two-arg outlier (actual-files + planned-files). It reads no
# file CONTENT — only compares the two path lists — so its parity fixture is a
# pair of path lists rather than the shared source tree. A planned file absent
# from "actual" and an unplanned actual file exercise both categories.
DRIFT_ACTUAL="$WORKDIR/drift-actual.txt"
DRIFT_PLANNED="$WORKDIR/drift-planned.txt"
command printf '%s\n' "src/foo.py" "src/unplanned.py" "package-lock.json" >"$DRIFT_ACTUAL"
command printf '%s\n' "src/foo.py" "src/never_touched.py" >"$DRIFT_PLANNED"

# port_is_two_arg PY — 0 (true) if this port takes two file-list args. Mirrors
# the same special-case in tests/validate-prescans.sh (keyed on the skill dir).
port_is_two_arg() {
    case "$1" in
        */drift-detect/patterns.py) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Edge-case contract (python entry point) --------------------------------

CUR_PY=""
test_python_edgecases() {
    local py="$CUR_PY" rc out err

    # No argument -> exit 1 with a Usage message on stderr.
    rc=0
    err="$(python3 "$py" </dev/null 2>&1 >/dev/null)" || rc=$?
    assert_exit 1 "$rc" "patterns.py: missing argument should exit 1"
    assert_contains "$err" "Usage" "patterns.py: missing argument should print a usage error"

    # Empty file list -> exit 0, no output. drift-detect needs the right arity
    # (two empty lists) so it does not exit 1 on a legitimately empty diff.
    rc=0
    if port_is_two_arg "$py"; then
        out="$(python3 "$py" "$EMPTY" "$EMPTY" 2>/dev/null)" || rc=$?
    else
        out="$(python3 "$py" "$EMPTY" 2>/dev/null)" || rc=$?
    fi
    assert_exit 0 "$rc" "patterns.py: empty file list should exit 0"
    assert_output_empty "$out" "patterns.py: empty file list should emit no findings"
}

# --- bash<->python parity ----------------------------------------------------

test_python_bash_parity() {
    local py="$CUR_PY" sh
    sh="$(sibling_sh "$py")"

    if [ ! -f "$sh" ]; then
        skip_test "no sibling .sh for $(command basename "$py") — parity needs both impls"
        return 0
    fi

    # EVERY force-bash variable is exported, not just PATTERNS_FORCE_BASH. Each
    # shim reads its OWN var (sizing.sh reads SIZING_FORCE_BASH), so setting only
    # the patterns one would let a non-patterns shim exec its python primary —
    # and the "parity" assertion would compare python against python and pass
    # unconditionally. Setting all of them is safe: a shim ignores the vars it
    # does not read. The self-check below proves the bash body actually ran.
    local py_out sh_out
    if port_is_two_arg "$py"; then
        py_out="$(python3 "$py" "$DRIFT_ACTUAL" "$DRIFT_PLANNED" 2>/dev/null | command sort)"
        sh_out="$(PATTERNS_FORCE_BASH=1 SIZING_FORCE_BASH=1 bash "$sh" "$DRIFT_ACTUAL" "$DRIFT_PLANNED" 2>/dev/null | command sort)"
    else
        py_out="$(python3 "$py" "$FILE_LIST" 2>/dev/null | command sort)"
        sh_out="$(PATTERNS_FORCE_BASH=1 SIZING_FORCE_BASH=1 bash "$sh" "$FILE_LIST" 2>/dev/null | command sort)"
    fi

    assert_equals "$sh_out" "$py_out" \
        "$(command basename "$(command dirname "$py")"): python and bash impls emit identical findings"
}

# --- Corpus guard + drive ----------------------------------------------------

# --- Direct unit coverage of a port's predicates (#605) ----------------------
#
# Parity is a strong property but a RELATIVE one: it asserts the two impls
# agree, not that either is correct. If both share a misconception parity stays
# green and both are wrong — which is exactly how #599 shipped a suppression
# that suppressed nothing (fixed in #604).
#
# So this calls check-code-health/patterns.py's is_test_file DIRECTLY, in
# Python, with both branches. The sibling cases in
# tests/validate-pre-review-gates.sh cover the same predicate through the BASH
# gate; neither substitutes for the other — they are different functions in
# different languages that happen to agree.
#
# Zero new dependency, consistent with the repo's testing posture: the module
# is stdlib-only and main-guarded, so importlib loads it without executing
# main(). No pytest, no test framework.
HEALTH_PY="$PLUGINS_DIR/review-audit/skills/check-code-health/patterns.py"

test_py_is_test_file_direct() {
    local out rc=0
    if [ ! -f "$HEALTH_PY" ]; then
        skip_test "check-code-health/patterns.py not present"
        return 0
    fi
    # Each line: "<expected> <path>". Printed as "FAIL ..." on mismatch so the
    # assertion below names the specific arm that broke, not just a count.
    out="$(python3 - "$HEALTH_PY" <<'PY' 2>&1)" || rc=$?
import importlib.util, sys

spec = importlib.util.spec_from_file_location("health_patterns", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

cases = [
    # TRUE branch — directory-segment arms, then basename arms.
    (True, "tests/helper.py"),
    (True, "src/tests/helper.py"),
    (True, "spec/a.js"),
    (True, "__tests__/b.js"),
    (True, "pkg/test/c.js"),
    (True, "__pycache__/d.py"),
    (True, "test_util.py"),
    (True, "thing_test.js"),
    (True, "thing_spec.rb"),
    (True, "thing.test.ts"),
    (True, "thing.spec.js"),
    # FALSE branch — the near-misses a loose *test* glob wrongly swallows
    # (#568), plus a test_-prefixed DIRECTORY holding real source.
    (False, "contest.py"),
    (False, "latest.js"),
    (False, "attestation.go"),
    (False, "src/protest/manifest.js"),
    (False, "src/test_helpers/production.py"),
    (False, "app.py"),
]

bad = 0
for expected, path in cases:
    got = mod.is_test_file(path)
    if got is not expected:
        bad += 1
        print("FAIL is_test_file(%r) -> %r, expected %r" % (path, got, expected))
if bad == 0:
    print("OK")
PY
    assert_equals "0" "$rc" "the direct is_test_file probe ran without error"
    assert_equals "OK" "$out" "patterns.py is_test_file: every arm matches its expected branch (#605)"
}

# --- the debug-family split, called DIRECTLY (#687) --------------------------
#
# #680 split patterns.py's inline debug logic into _scan_debug_print and
# _scan_debugger. Until now they were exercised only INDIRECTLY, through this
# file's bash<->python parity fixture, which has two blind spots:
#
#   1. Parity proves the two impls AGREE, not that either is CORRECT. A
#      symmetrical mistake passes green — not hypothetical: a wrong trailing
#      `\b` sat in both copies of the Go assertion pattern through the whole of
#      #679, and this gate never noticed (#684).
#   2. The parity suite skip_tests itself when no python3>=3.11 exists. On such
#      a host the split had NO coverage — the #543 self-skipping shape, where
#      the arm that does not run is the risky one.
#
# So this calls both functions directly, in Python, the same importlib shape as
# test_py_is_test_file_direct above. Zero new dependencies; the module is
# stdlib-only and main-guarded, so importing it does not run main().
#
# The ORDER assertion is the point of the adjacent-lines fixture. scan_file's
# comment promises print-then-debugger emission, and the shared-region contract
# is an ORDERED multiset — validate-shared-scanner-sync.sh treats a reordered
# line as drift — but nothing pinned the order the two functions actually emit
# in. Swapping the two calls in scan_file would have been invisible.
test_py_debug_family_direct() {
    local out rc=0
    if [ ! -f "$HEALTH_PY" ]; then
        skip_test "check-code-health/patterns.py not present"
        return 0
    fi
    out="$(python3 - "$HEALTH_PY" <<'PY' 2>&1)" || rc=$?
import importlib.util, io, sys
from contextlib import redirect_stdout

spec = importlib.util.spec_from_file_location("health_patterns", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

problems = []


def rows(fn, path, idx, line, ext):
    """The TSV rows one family function emits for a single line."""
    buf = io.StringIO()
    with redirect_stdout(buf):
        fn(path, idx, line, ext)
    return [r for r in buf.getvalue().splitlines() if r]


# --- each family fires on its OWN input ---
pr = rows(mod._scan_debug_print, "a.py", 1, 'print("x")', "py")
if len(pr) != 1 or "Debug print statement" not in pr[0]:
    problems.append("_scan_debug_print on print() -> %r" % (pr,))

db = rows(mod._scan_debugger, "a.py", 1, "breakpoint()", "py")
if len(db) != 1 or "Debugger statement" not in db[0]:
    problems.append("_scan_debugger on breakpoint() -> %r" % (db,))

# --- and NOT on the other's input: the families must not overlap ---
# This is what makes the split meaningful. If either function widened to cover
# both, the exemption in scan_file (#686) would silently reach the debugger.
cross = rows(mod._scan_debug_print, "a.py", 1, "breakpoint()", "py")
if cross:
    problems.append("_scan_debug_print wrongly fired on breakpoint(): %r" % (cross,))

cross = rows(mod._scan_debugger, "a.py", 1, 'print("x")', "py")
if cross:
    problems.append("_scan_debugger wrongly fired on print(): %r" % (cross,))

# --- ADJACENT LINES, whole-file: both rows emit ---
buf = io.StringIO()
with redirect_stdout(buf):
    mod.scan_file("cli.py", ['print("out")', "breakpoint()"])
emitted = [r for r in buf.getvalue().splitlines() if "debug-statement" in r]

if len(emitted) != 2:
    problems.append("adjacent print+breakpoint emitted %d rows, want 2: %r" % (len(emitted), emitted))
else:
    if "Debug print statement" not in emitted[0]:
        problems.append("row 1 is not the print row: %r" % (emitted[0],))
    if "Debugger statement" not in emitted[1]:
        problems.append("row 2 is not the debugger row: %r" % (emitted[1],))

# --- ORDER: pinned at the SOURCE, because output cannot show it ---
#
# Worth stating plainly, because the obvious test does not work. The adjacent-
# lines case above cannot observe call order: the two families sit on different
# LINES, so scan_file's per-line loop emits them in line order whichever way it
# calls them — that case passes with the calls swapped (verified by mutation).
#
# Nor can a single line carry both: every pattern in both families is
# `^\s*`-anchored, so `print("x"); breakpoint()` matches the print family only.
# There is NO input for which the call order changes the emitted bytes.
#
# That is not a gap in the test, it is a fact about the code — and it is exactly
# why #687 asked for the order to be pinned: scan_file's comment promises
# print-then-debugger, and the shared-region contract is an ORDERED multiset, so
# the promise should not rest on a comment alone. Since behaviour cannot witness
# it, assert on the SOURCE: the two calls appear in the documented order.
import inspect

src = inspect.getsource(mod.scan_file)
i_print = src.find("_scan_debug_print(")
i_dbg = src.find("_scan_debugger(")
if i_print < 0 or i_dbg < 0:
    problems.append("scan_file no longer calls both family functions by name")
elif i_print > i_dbg:
    problems.append(
        "scan_file calls _scan_debugger BEFORE _scan_debug_print; "
        "the documented emission order is print-then-debugger"
    )

for p in problems:
    print("FAIL " + p)
if not problems:
    print("OK")
PY
    assert_equals "0" "$rc" "the direct debug-family probe ran without error"
    assert_equals "OK" "$out" \
        "patterns.py debug split: each family fires only on its own input, and scan_file emits print-then-debugger (#687)"
}

# --- _read_yaml_list, called directly (#686) ---------------------------------
#
# The bash twin has direct unit tests in validate-pre-review-gates.sh
# (test_read_yaml_list_*). The Python one had none: it is reached only through
# the end-to-end flow in validate-source-detectors.sh, whose values become
# GITIGNORE PATTERNS — and git strips trailing whitespace from those itself, so
# the #684 rule (strip unconditionally, preserve INSIDE quotes) is invisible
# through that path. A regression in the quote/whitespace handling would not
# show up anywhere.
#
# The last case is the ASCII section terminator. Python's str.isalpha() is
# Unicode-aware and the bash glob `[a-zA-Z_]*` is not, so an accented key in
# column 0 would end the section in one impl and not the other — the two
# runtimes reading one config differently. Caught in review before merge; this
# pins it, since no parity fixture uses a non-ASCII first character.
test_py_read_yaml_list_direct() {
    local out rc=0
    if [ ! -f "$HEALTH_PY" ]; then
        skip_test "check-code-health/patterns.py not present"
        return 0
    fi
    out="$(python3 - "$HEALTH_PY" <<'PY' 2>&1)" || rc=$?
import importlib.util, os, sys, tempfile

spec = importlib.util.spec_from_file_location("health_patterns", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

problems = []


def parse(key, text):
    d = tempfile.mkdtemp()
    p = os.path.join(d, "cfg.yml")
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(text)
    try:
        return mod._read_yaml_list(key, p)
    finally:
        os.remove(p)
        os.rmdir(d)


def check(label, got, want):
    if got != want:
        problems.append("%s -> %r, want %r" % (label, got, want))


# Trailing whitespace comes off with OR without a closing quote (#684).
check(
    "unquoted trailing ws",
    parse("k", 'k:\n  - a.py   \n  - "b.py"   \n'),
    ["a.py", "b.py"],
)

# ...but whitespace INSIDE the quotes is deliberate and survives.
check("quoted inner ws", parse("k", 'k:\n  - "a.py  "\n'), ["a.py  "])

# Both quote styles, and a bare value.
check(
    "quote styles",
    parse("k", "k:\n  - \"a.py\"\n  - 'b.py'\n  - c.py\n"),
    ["a.py", "b.py", "c.py"],
)

# A later top-level key ends the section; a different key is reachable.
two = "k:\n  - a.py\nother:\n  - b.py\n"
check("section ends at next key", parse("k", two), ["a.py"])
check("later key reachable", parse("other", two), ["b.py"])

# Absent key and blank entries.
check("absent key", parse("nope", "k:\n  - a.py\n"), [])
check("blank lines dropped", parse("k", "k:\n  - a.py\n\n  - b.py\n"), ["a.py", "b.py"])

# ASCII-ONLY terminator. A non-ASCII letter in column 0 does NOT end the
# section, matching the bash glob `[a-zA-Z_]*` — and since it is neither a
# terminator nor indented, bash then keeps it as an ITEM. Expected values here
# were taken from running the bash twin, not from intuition: it is the reference
# impl, so whatever it does IS the contract.
#
# With the original str.isalpha() this returned ["a.py"] — the section ended
# early and b.py was lost. That is the divergence this case pins.
check(
    "non-ASCII column-0 line does not terminate the section",
    parse("k", "k:\n  - a.py\n\u00e9key\n  - b.py\n"),
    ["a.py", "\u00e9key", "b.py"],
)

for p in problems:
    print("FAIL " + p)
if not problems:
    print("OK")
PY
    assert_equals "0" "$rc" "the direct _read_yaml_list probe ran without error"
    assert_equals "OK" "$out" \
        "patterns.py _read_yaml_list: quotes, #684 whitespace rule, and ASCII-only section terminator (#686)"
}

ports_list="$(list_python_ports)"

test_corpus_non_empty() {
    assert_not_empty "$ports_list" "At least one ported tool must be present to validate"
}

# Every discovered port's force-bash variable is actually SET by the parity test.
#
# WHY THIS EXISTS. The parity assertion runs the `.sh` half expecting the bash
# BODY; each shim decides that by reading its own `*_FORCE_BASH` variable. If a
# port's variable is not in the parity call, its shim exec's the PYTHON primary
# and the assertion compares python against python — passing unconditionally,
# forever, while the bash fallback rots untested. That failure is invisible: the
# gate stays green and reports the port as covered.
#
# So this greps each shim for the variable it reads and asserts that EVERY line
# of the parity test which invokes the `.sh` sets that exact name. A future port
# that introduces a third variable fails HERE with an actionable message, instead
# of silently opting out of parity.
#
# PER-INVOCATION, NOT PER-BODY. Checking that the variable appears ANYWHERE in
# the test body is too weak: the parity test has TWO invocation arms (one-arg and
# two-arg), and a variable present in only one of them leaves the other arm
# comparing python to python. Verified by mutation — dropping SIZING_FORCE_BASH
# from just the one-arg arm passed a body-scoped check and fails this one.
test_every_force_bash_var_is_set() {
    local py sh var parity_body invocations line n_inv=0
    parity_body="$(command sed -n '/^test_python_bash_parity()/,/^}/p' "$SCRIPT_DIR/validate-python-ports.sh")"
    assert_not_empty "$parity_body" "the parity test body was located (self-inspection works)"

    # Every line that actually runs the bash sibling.
    invocations="$(command printf '%s\n' "$parity_body" | command grep -F 'bash "$sh"' || true)"
    assert_not_empty "$invocations" "the parity test's bash invocations were located"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        n_inv=$((n_inv + 1))
    done <<EOF
$invocations
EOF
    # Both arms must be present, or the loop below could vacuously pass by
    # finding a single compliant invocation.
    assert_equals "2" "$n_inv" "the parity test has both invocation arms (one-arg and two-arg)"

    while IFS= read -r py; do
        [ -n "$py" ] || continue
        sh="$(sibling_sh "$py")"
        [ -f "$sh" ] || continue
        # The shim line looks like: [ "${SOMETHING_FORCE_BASH:-0}" != "1" ]
        var="$(command grep -oE '[A-Z_]+_FORCE_BASH' "$sh" | command head -1 || true)"
        assert_not_empty "$var" "$(command basename "$sh"): declares a *_FORCE_BASH shim variable"
        [ -n "$var" ] || continue
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            assert_contains "$line" "$var" \
                "$(command basename "$sh"): every parity invocation sets ${var} (else that arm compares python to python)"
        done <<EOF
$invocations
EOF
    done <<<"$ports_list"
}

run_test test_corpus_non_empty "Python-port corpus is non-empty (gate is not a no-op)"
run_test test_every_force_bash_var_is_set "Every port's *_FORCE_BASH var is set by the parity test (#695)"
run_test test_py_is_test_file_direct "check-code-health/patterns.py: is_test_file called directly, both branches (#605)"
run_test test_py_debug_family_direct "check-code-health/patterns.py: debug families called directly + emission order (#687)"
run_test test_py_read_yaml_list_direct "check-code-health/patterns.py: _read_yaml_list quote/whitespace/section rules match the bash twin (#686)"

while IFS= read -r py; do
    [ -n "$py" ] || continue
    CUR_PY="$py"
    rel="${py#"$PLUGINS_DIR"/}"
    run_test test_python_edgecases "$rel: edge-case contract (no-arg exit 1, empty-list exit 0)"
    run_test test_python_bash_parity "$rel: bash<->python TSV parity"
done <<<"$ports_list"

generate_report
