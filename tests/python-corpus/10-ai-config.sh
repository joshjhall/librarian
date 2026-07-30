# shellcheck shell=bash
# check-ai-config corpus — python coverage fixtures (issue #564 split).
#
# Builds the skill/agent/CLAUDE.md/MCP/hook fixtures plus the drift-detect path lists.
#
# Sourced by tests/coverage-python.sh, which creates WORKDIR and its EXIT trap
# BEFORE this file. This fragment only BUILDS FIXTURES and exports the path-list
# variables the driver section then feeds to each port under `coverage run`.
#
# NOTE: unlike the tests/ fragments, nothing here asserts — coverage-python.sh is
# a Codecov driver, not a test suite (it has zero run_test calls and is not wired
# into tests/run-all.sh). The behavioural gates for these same detectors live in
# tests/validate-{source,docs,loop,lifecycle,checker}-detectors.sh, and this
# corpus is kept in lockstep with them.

# The path-list / fixture-path variables below are the corpus's EXPORT surface:
# they are read by the driver loop in tests/coverage-python.sh, which sources
# this file. shellcheck analyses one file at a time and so cannot see those
# uses.
# shellcheck disable=SC2034  # consumed by the driver in tests/coverage-python.sh

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
# Multi-line so the insecure-http arm (non-localhost) fires on its own line and
# the localhost-allowlist skip fires on a SEPARATE line — a single-line form lets
# the localhost match swallow the whole line and neither branch emits (#348).
cat >"$FIXDIR/ai/mcp.json" <<'EOF'
{
  "a": "http://evil.example.com",
  "b": "http://localhost:1"
}
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
# CLAUDE.md carries a broken backtick path (claude-md-drift fires) and a real one
# (the exists-branch stays silent). `dir/ghost.sh` resolves under $FIXDIR/ai and
# is absent; real.sh is created below.
mkdir -p "$FIXDIR/ai/dir"
: >"$FIXDIR/ai/dir/real.sh"
cat >"$FIXDIR/ai/CLAUDE.md" <<'EOF'
line one with a bad `dir/ghost.sh` reference
line two with a good `dir/real.sh` reference
line three
EOF
# A plugins-shaped tree so config-inconsistency's plugins-root walk resolves: a
# real agent under plugin 'demo', and a host SKILL.md citing a real + ghost ref.
mkdir -p "$FIXDIR/plugins/demo/agents"
: >"$FIXDIR/plugins/demo/agents/checker.md"
mkdir -p "$FIXDIR/plugins/demo/skills/host"
cat >"$FIXDIR/plugins/demo/skills/host/SKILL.md" <<'EOF'
---
description: A host skill referencing agents.
---
## Workflow
Uses `demo:checker` (real) and `demo:ghost` (missing) and `go:generate` (skip).
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

# A skill SKILL.md whose first line is NOT `---` -> skill-frontmatter's
# missing-opening-fence arm (#348 coverage: the behavioral assertion exists in
# validate-checker-detectors.sh; this drives the same branch under measurement).
NOFMSKILL="$FIXDIR/ai/skills/nofm"
mkdir -p "$NOFMSKILL"
printf '%s\n' "# no frontmatter here" "just prose" >"$NOFMSKILL/SKILL.md"

# A SKILL.md over its WARNING threshold but UNDER high -> the ai-file-bloat
# `elif n > warn` (MEDIUM) arm, distinct from the CLAUDE.md high arm above.
WARNSKILL="$FIXDIR/ai/skills/warn"
mkdir -p "$WARNSKILL"
printf '%s\n' "line" "line" "line" "line" "line" >"$WARNSKILL/SKILL.md"

# An unreadable config file -> main()'s per-file open() OSError skip arm.
AI_UNREAD="$FIXDIR/ai/unreadable.json"
printf '%s\n' '{ "x": "http://evil.example.com" }' >"$AI_UNREAD"
chmod 000 "$AI_UNREAD" 2>/dev/null || true

# config-inconsistency's _plugins_dir_for has a RELATIVE `plugins/`-prefixed arm
# (path.startswith("plugins/")) distinct from the absolute `/plugins/` arm the
# host/SKILL.md above drives. Build a relative-path skill under $FIXDIR and drive
# it with a relative list while cd'd into $FIXDIR so the path literally begins
# with `plugins/` (#348). It cites a ghost `demo:missing` -> the arm resolves the
# real plugins/demo dir but finds no agent/skill -> config-inconsistency fires.
mkdir -p "$FIXDIR/plugins/demo/skills/rel"
cat >"$FIXDIR/plugins/demo/skills/rel/SKILL.md" <<'EOF'
---
description: A relative-path host skill.
---
## Workflow
Uses `demo:missing` (ghost) via a relative path.
EOF
AICFG_REL_LIST="$WORKDIR/ai-rel-list.txt"
printf '%s\n' "plugins/demo/skills/rel/SKILL.md" >"$AICFG_REL_LIST"

AICFG_LIST="$WORKDIR/ai-list.txt"
printf '%s\n' \
    "$AICFG/rev.md" "$AICFG/other.md" "$NOFMDIR/nofm.md" "$BAREDIR/bare.md" \
    "$SKILLDIR/SKILL.md" "$FIXDIR/ai/mcp.json" "$FIXDIR/ai/hook.sh" \
    "$FIXDIR/ai/demo.workflow.js" "$FIXDIR/ai/CLAUDE.md" "$FIXDIR/ai/docs/guide.md" \
    "$FIXDIR/plugins/demo/skills/host/SKILL.md" \
    "$NOFMSKILL/SKILL.md" "$WARNSKILL/SKILL.md" "$AI_UNREAD" \
    >"$AICFG_LIST"
# A blank line drives main()'s empty-path `if not path: continue` arm.
printf '\n' >>"$AICFG_LIST"

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
