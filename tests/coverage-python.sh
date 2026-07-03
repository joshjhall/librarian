#!/usr/bin/env bash
# Python coverage for the patterns.py pre-scan ports (#186).
#
# Emits a Cobertura coverage.xml for the 14 plugins/**/patterns.py ports so CI
# can upload it to Codecov. Coverage is scoped to Python (and, separately, the
# .mjs validators via tests/coverage-mjs.sh) on purpose: the bash patterns.sh
# fallback is grep-pipeline code whose matching lives in `grep` subprocess regex
# alternations a line tracer cannot see, so a bash line-coverage number is
# instrument noise, not signal (see CLAUDE.md runtime policy; the bash path is
# guarded by tests/validate-python-ports.sh byte-parity instead).
#
# Each port is driven under `coverage run --parallel-mode` against a small
# synthetic corpus that exercises the detector categories (secrets, SQL, XSS,
# crypto, debug markers, empty bodies, ...), mirroring the fixture shape of
# tests/validate-python-ports.sh. drift-detect is the two-arg outlier (it diffs
# two path lists), handled below. The per-process .coverage.* data files are
# then combined into a single coverage.xml at the repo root.
#
# Skips gracefully (exit 0, no report) when python3>=3.11 or coverage.py is
# absent — the same skip-if-absent posture as the sibling gates. CI installs
# coverage so it actually runs there. This script is NOT wired into
# tests/run-all.sh: it is an additive reporting step, run by CI and `just
# coverage`, and must not perturb the no-python3 macOS test path.
#
# Pure bash-3.2 + coreutils + python3; no network, no jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGINS_DIR="$REPO_ROOT/plugins"

# --- Runtime gate: python3>=3.11 + coverage.py, else skip cleanly ------------
if ! command -v python3 >/dev/null 2>&1 ||
    ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    printf '[skip] python-coverage — python3>=3.11 not available\n'
    exit 0
fi
if ! python3 -c 'import coverage' 2>/dev/null; then
    printf '[skip] python-coverage — coverage.py not installed (pip install coverage)\n'
    exit 0
fi

OUT_XML="$REPO_ROOT/coverage.xml"

# --- Synthetic corpus that exercises the detector categories -----------------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
FIXDIR="$WORKDIR/fix"
mkdir -p "$FIXDIR"

# Fake secret tokens assembled from fragments so this file holds no contiguous
# secret for gitleaks to flag; the fixtures on disk carry the full token. All
# are obvious fakes (repeated/sequential filler, not real credentials).
GH_TOK="ghp_""ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
AWS_TOK="AKIA""0123456789ABCDEF"
STRIPE_TOK="sk_""live_""ABCDEFGHIJKLMNOPQRSTUV"

cat >"$FIXDIR/app.py" <<'EOF'
import hashlib
query = f"SELECT * FROM users WHERE id={user_id}"
single_q = f'SELECT * FROM t WHERE id={i}'
digest = md5(payload)
secret = "abcdefghijkl"
xor_secret = "value_x2_7_here"
# md5(commented) is skipped — crypto comment-skip is live
placeholder = "changeme_example_value"
concat = "SELECT a FROM t" + tail
api_key = 'sk2live7value_xx'
loaded = yaml.load(payload)
safe_loaded = yaml.load(payload, Loader=SafeLoader)
print("debug marker")  # TODO: remove
def empty_impl():
    pass
EOF
printf 'gh = "%s"\n' "$GH_TOK" >>"$FIXDIR/app.py"

cat >"$FIXDIR/app.ts" <<'EOF'
const sql = `SELECT * FROM t WHERE x=${val}`;
node.innerHTML = raw;
const spaced = () => { }
console.log("debug"); // FIXME
EOF
printf 'const awsKey = "%s";\n' "$AWS_TOK" >>"$FIXDIR/app.ts"

cat >"$FIXDIR/app.go" <<'EOF'
package main

func Undocumented() {}

func Spaced() { }
EOF

cat >"$FIXDIR/view.html" <<'EOF'
<div v-html="userInput"></div>
{{ value|safe }}
{!! $unescaped !!}
<a href="./missing-link.md">broken</a>
EOF

cat >"$FIXDIR/model.rb" <<'EOF'
sql = "SELECT * FROM t WHERE id=#{id}"
cipher = OpenSSL::Cipher.new('AES-128-ECB')
EOF

cat >"$FIXDIR/README.md" <<'EOF'
# Sample

See [broken](./does-not-exist.md) and http://example.com/probably-dead.

```python
import nonexistent_module
foo(
```
EOF

# .env.example carrying a secret must be ignored by the skip-glob path.
printf 'key = "%s"\n' "$STRIPE_TOK" >"$FIXDIR/secrets.env.example"

# check-ai-config scans Claude Code CONFIG files (agent/skill frontmatter,
# CLAUDE.md bloat, MCP config, hook safety, workflow.js harness logic), gated on
# path globs the generic corpus above never matches. Build a small config-shaped
# tree so its detectors execute for the coverage run. The BEHAVIORAL assertions
# on these detectors live in tests/validate-checker-detectors.sh (#204) — this
# corpus only drives line coverage; the gate is what pins correctness. Fixtures
# use only PRESENT frontmatter fields so the bash fallback's missing-field crash
# (#205) does not apply and both impls stay well-behaved.
AICFG="$FIXDIR/ai/agents/rev"
mkdir -p "$AICFG"
cat >"$AICFG/rev.md" <<'EOF'
---
name: rev
description: A reviewer agent.
tools: '*'
model: nope
---
# Reviewer
EOF
SKILLDIR="$FIXDIR/ai/skills/demo"
mkdir -p "$SKILLDIR"
cat >"$SKILLDIR/SKILL.md" <<'EOF'
---
name: demo
---
Prose with no structural section heading.
EOF
cat >"$FIXDIR/ai/mcp.json" <<'EOF'
{ "a": "http://evil.example.com", "b": "http://localhost:1" }
EOF
cat >"$FIXDIR/ai/hook.sh" <<'EOF'
#!/usr/bin/env bash
rm -rf /tmp/x
git reset --hard
EOF
printf 'echo %s\n' '$GITHUB_TOKEN' >>"$FIXDIR/ai/hook.sh"
cat >"$FIXDIR/ai/demo.workflow.js" <<'EOF'
const ref = `${a}:${b}:${c}`
run(`x agentType: 'bare'`)
sh(`claude --dangerously-skip-permissions ${task}`)
sh("npm install")
EOF
cat >"$FIXDIR/ai/CLAUDE.md" <<'EOF'
line one
line two
line three
EOF
# Wrong-basename agent (dir 'rev' but file 'other.md') -> naming arm.
cat >"$AICFG/other.md" <<'EOF'
---
name: other
description: d
tools: Read
model: opus
---
EOF
# Agent with no opening frontmatter fence -> missing-frontmatter early return.
NOFMDIR="$FIXDIR/ai/agents/nofm"
mkdir -p "$NOFMDIR"
printf '%s\n' "# no frontmatter" "body" >"$NOFMDIR/nofm.md"
# Agent missing required fields (present-fence). Safe here: the coverage run uses
# patterns.py directly, which handles a missing field correctly (the bash-only
# #205 crash does not apply to the python primary).
BAREDIR="$FIXDIR/ai/agents/bare"
mkdir -p "$BAREDIR"
printf '%s\n' "---" "unrelated: v" "---" "body" >"$BAREDIR/bare.md"
# A docs/*.md over its (tuned) threshold -> DOC bloat arm.
mkdir -p "$FIXDIR/ai/docs"
printf '%s\n' "d1" "d2" "d3" "d4" >"$FIXDIR/ai/docs/guide.md"

AICFG_LIST="$WORKDIR/ai-list.txt"
printf '%s\n' \
    "$AICFG/rev.md" "$AICFG/other.md" "$NOFMDIR/nofm.md" "$BAREDIR/bare.md" \
    "$SKILLDIR/SKILL.md" "$FIXDIR/ai/mcp.json" "$FIXDIR/ai/hook.sh" \
    "$FIXDIR/ai/demo.workflow.js" "$FIXDIR/ai/CLAUDE.md" "$FIXDIR/ai/docs/guide.md" \
    >"$AICFG_LIST"

# Single-arg corpus: a file list of every fixture above.
FILE_LIST="$WORKDIR/list.txt"
: >"$FILE_LIST"
for f in "$FIXDIR"/app.py "$FIXDIR"/app.ts "$FIXDIR"/app.go \
    "$FIXDIR"/view.html "$FIXDIR"/model.rb "$FIXDIR"/README.md \
    "$FIXDIR"/secrets.env.example; do
    printf '%s\n' "$f" >>"$FILE_LIST"
done

# drift-detect is two-arg: actual vs planned path lists.
DRIFT_ACTUAL="$WORKDIR/drift-actual.txt"
DRIFT_PLANNED="$WORKDIR/drift-planned.txt"
printf '%s\n' "src/foo.py" "src/unplanned.py" "package-lock.json" >"$DRIFT_ACTUAL"
printf '%s\n' "src/foo.py" "src/never_touched.py" >"$DRIFT_PLANNED"

# --- Run every port under coverage (parallel-mode accumulates per process) ---
# COVERAGE_FILE lives in WORKDIR so combine sees only this run's data files and
# nothing pollutes the repo tree until the final xml is written.
export COVERAGE_FILE="$WORKDIR/.coverage"

run_count=0
while IFS= read -r py; do
    [ -n "$py" ] || continue
    case "$py" in
        */drift-detect/patterns.py)
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DRIFT_ACTUAL" "$DRIFT_PLANNED" >/dev/null 2>&1 || true
            ;;
        */check-ai-config/patterns.py)
            # Drive this port over the config-shaped corpus (agent/skill/MCP/hook/
            # workflow.js) instead of the generic one, with bloat thresholds tuned
            # down so the tiny CLAUDE.md trips the warn/high arms. Also run the
            # generic list so the no-match early-return globs stay covered.
            CLAUDE_MD_WARN=1 CLAUDE_MD_HIGH=2 DOC_WARN=1 DOC_HIGH=3 \
                python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$AICFG_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
        *)
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
    esac
    run_count=$((run_count + 1))
done <<EOF
$(find "$PLUGINS_DIR" -type f -name 'patterns.py' 2>/dev/null | sort)
EOF

if [ "$run_count" -eq 0 ]; then
    printf '[FAIL] python-coverage — no patterns.py found under %s\n' "$PLUGINS_DIR" >&2
    exit 1
fi

# --- Combine + emit Cobertura XML at the repo root ---------------------------
python3 -m coverage combine >/dev/null 2>&1 || true
python3 -m coverage xml -o "$OUT_XML" >/dev/null 2>&1 || {
    printf '[FAIL] python-coverage — coverage xml failed\n' >&2
    exit 1
}

if [ ! -s "$OUT_XML" ]; then
    printf '[FAIL] python-coverage — coverage.xml is empty\n' >&2
    exit 1
fi

pct="$(python3 -m coverage report 2>/dev/null | awk '/^TOTAL/ {print $NF}')"
printf '[ok] python-coverage — %s ports run, coverage.xml written (TOTAL %s)\n' \
    "$run_count" "${pct:-n/a}"
