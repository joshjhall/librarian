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

# List every patterns.py across all plugins (absolute paths, sorted).
list_python_ports() {
    command find "$PLUGINS_DIR" -type f -name 'patterns.py' 2>/dev/null | command sort
}

# A shared fixture tree exercising the categories/dispatch a security-style
# scanner cares about. It is deliberately generic (secrets, SQL, XSS, crypto,
# debug markers) so the same tree meaningfully exercises any ported tool; a tool
# that finds nothing in it still asserts parity (both impls emit nothing).
WORKDIR="$(/usr/bin/mktemp -d)"
trap '/usr/bin/rm -rf "$WORKDIR"' EXIT
FIXDIR="$WORKDIR/fix"
/usr/bin/mkdir -p "$FIXDIR"

# The fake secret tokens (GitHub PAT, AWS key, Stripe key) are assembled at
# runtime from fragments so this TEST FILE contains no contiguous secret for the
# gitleaks pre-commit hook to flag — while the fixture files written to disk hold
# the full contiguous token the scanner must match. (The tokens are obvious fakes:
# repeated/sequential filler, not real credentials.)
GH_TOK="ghp_""ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
AWS_TOK="AKIA""0123456789ABCDEF"
STRIPE_TOK="sk_""live_""ABCDEFGHIJKLMNOPQRSTUV"

/usr/bin/cat >"$FIXDIR/app.py" <<'EOF'
import hashlib
query = f"SELECT * FROM users WHERE id={user_id}"
single_q = f'SELECT * FROM t WHERE id={i}'
digest = md5(payload)
secret = "abcdefghijkl"
xor_secret = "value_x2_7_here"
# md5(commented) is skipped — the crypto comment-skip is live (#168)
placeholder = "changeme_example_value"
concat = "SELECT a FROM t" + tail
EOF
/usr/bin/printf 'gh = "%s"\n' "$GH_TOK" >>"$FIXDIR/app.py"

/usr/bin/cat >"$FIXDIR/app.ts" <<'EOF'
const sql = `SELECT * FROM t WHERE x=${val}`;
node.innerHTML = raw;
EOF
/usr/bin/printf 'const awsKey = "%s";\n' "$AWS_TOK" >>"$FIXDIR/app.ts"

/usr/bin/cat >"$FIXDIR/view.html" <<'EOF'
<div v-html="userInput"></div>
{{ value|safe }}
{!! $unescaped !!}
EOF

/usr/bin/cat >"$FIXDIR/model.rb" <<'EOF'
sql = "SELECT * FROM t WHERE id=#{id}"
cipher = OpenSSL::Cipher.new('AES-128-ECB')
EOF

# Skip-glob coverage: an .env.example holding a secret must be ignored.
/usr/bin/printf 'key = "%s"\n' "$STRIPE_TOK" >"$FIXDIR/secrets.env.example"

FILE_LIST="$WORKDIR/list.txt"
: >"$FILE_LIST"
for f in "$FIXDIR/app.py" "$FIXDIR/app.ts" "$FIXDIR/view.html" \
    "$FIXDIR/model.rb" "$FIXDIR/secrets.env.example"; do
    /usr/bin/printf '%s\n' "$f" >>"$FILE_LIST"
done

EMPTY="$WORKDIR/empty.txt"
: >"$EMPTY"

# drift-detect is the two-arg outlier (actual-files + planned-files). It reads no
# file CONTENT — only compares the two path lists — so its parity fixture is a
# pair of path lists rather than the shared source tree. A planned file absent
# from "actual" and an unplanned actual file exercise both categories.
DRIFT_ACTUAL="$WORKDIR/drift-actual.txt"
DRIFT_PLANNED="$WORKDIR/drift-planned.txt"
/usr/bin/printf '%s\n' "src/foo.py" "src/unplanned.py" "package-lock.json" >"$DRIFT_ACTUAL"
/usr/bin/printf '%s\n' "src/foo.py" "src/never_touched.py" >"$DRIFT_PLANNED"

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
    local py="$CUR_PY"
    local sh="${py%patterns.py}patterns.sh"

    if [ ! -f "$sh" ]; then
        skip_test "no sibling patterns.sh for $(command basename "$(command dirname "$py")") — parity needs both impls"
        return 0
    fi

    local py_out sh_out
    if port_is_two_arg "$py"; then
        py_out="$(python3 "$py" "$DRIFT_ACTUAL" "$DRIFT_PLANNED" 2>/dev/null | command sort)"
        sh_out="$(PATTERNS_FORCE_BASH=1 bash "$sh" "$DRIFT_ACTUAL" "$DRIFT_PLANNED" 2>/dev/null | command sort)"
    else
        py_out="$(python3 "$py" "$FILE_LIST" 2>/dev/null | command sort)"
        sh_out="$(PATTERNS_FORCE_BASH=1 bash "$sh" "$FILE_LIST" 2>/dev/null | command sort)"
    fi

    assert_equals "$sh_out" "$py_out" \
        "$(command basename "$(command dirname "$py")"): python and bash impls emit identical findings"
}

# --- Corpus guard + drive ----------------------------------------------------

ports_list="$(list_python_ports)"

test_corpus_non_empty() {
    assert_not_empty "$ports_list" "At least one patterns.py must be present to validate"
}

run_test test_corpus_non_empty "Python-port corpus is non-empty (gate is not a no-op)"

while IFS= read -r py; do
    [ -n "$py" ] || continue
    CUR_PY="$py"
    rel="${py#"$PLUGINS_DIR"/}"
    run_test test_python_edgecases "$rel: edge-case contract (no-arg exit 1, empty-list exit 0)"
    run_test test_python_bash_parity "$rel: bash<->python TSV parity"
done <<<"$ports_list"

generate_report
