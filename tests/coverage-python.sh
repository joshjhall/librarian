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

# --- check-security + check-code-health corpus (#348) ------------------------
# check-security (84%) and check-code-health (68%) were the lowest-coverage
# non-docs ports because the generic corpus above never exercised their
# per-language / per-framework / boundary arms. These fixtures drive those
# branches under measurement, in lockstep with the behavioral assertions in
# tests/validate-source-detectors.sh (the #204 two-surface convention). Both
# ports are content-only (no git-rooting), so they run over SRC_LIST from
# WORKDIR. Boundary/negative arms (the credential denylist, the crypto
# comment-skip, the debug-in-test-file suppression, the is_test_file segment
# anchoring, the SKIP_GLOBS whole-file skip, the per-file OSError arm) are all
# represented so their lines execute; correctness is pinned by the gate.
SRCDIR="$FIXDIR/src"
mkdir -p "$SRCDIR/tests"

# Fake secret tokens, fragment-assembled so this SCRIPT holds no contiguous
# secret; the fixture on disk carries the full token.
SEC_AKIA="AKIA""0123456789ABCDEF"
SEC_GHP="ghp_""ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
SEC_STRIPE="sk_""live_""ABCDEFGHIJKLMNOPQRSTUV"
SEC_REACT="dangerously""SetInnerHTML"
SEC_VUE="v-""html"
SEC_BLADE="{""!!"

# Python source: secrets (all 4 header arms + generic credential), denylist
# negatives, f-string SQL + concatenation, md5 real vs commented, print() vs
# logger negative, breakpoint, empty except (pass) vs handled.
{
    printf 'aws = "%s"\n' "$SEC_AKIA"
    printf 'gh = "%s"\n' "$SEC_GHP"
    printf 'stripe = "%s"\n' "$SEC_STRIPE"
    printf '%s\n' '-----BEGIN RSA PRIVATE KEY-----'
    printf '%s\n' 'password = "hunter2hunter2"'
    printf '%s\n' 'placeholder = "changeme_placeholder"'
    printf '%s\n' 'from_env = os.environ["API_KEY"]'
    printf '%s\n' 'q = f"SELECT * FROM t WHERE id={i}"'
    printf '%s\n' 'c = "SELECT a FROM t" + tail'
    printf '%s\n' 'digest = md5(payload)'
    printf '%s\n' '# md5(commented) is skipped by the comment guard'
    printf '%s\n' 'print("debug marker")'
    printf '%s\n' 'logger.print("structured")'
    printf '%s\n' 'breakpoint()'
    printf '%s\n' 'x = 1  # TODO: refactor'
    printf '%s\n' 'try:'
    printf '%s\n' '    risky()'
    printf '%s\n' 'except Exception:'
    printf '%s\n' '    pass'
} >"$SRCDIR/app.py"

# TS source: template-literal SQL, console/debugger, empty catch.
{
    printf '%s\n' 'const q = `SELECT * FROM t WHERE x=${v}`;'
    printf '%s\n' 'console.log("debug");'
    printf '%s\n' 'debugger;'
    printf '%s\n' 'try { risky(); } catch (e) {}'
} >"$SRCDIR/app.ts"

# Ruby source: interpolation SQL, ECB, binding.pry, empty rescue.
{
    printf '%s\n' 'sql = "SELECT * FROM t WHERE id=#{id}"'
    printf '%s\n' "cipher = OpenSSL::Cipher.new('AES-128-ECB')"
    printf '%s\n' 'binding.pry'
    printf '%s\n' 'begin'
    printf '%s\n' '  risky'
    printf '%s\n' 'rescue'
    printf '%s\n' 'end'
} >"$SRCDIR/app.rb"

# Go source: fmt.Println debug (own line so the ^\s* anchor matches), swallowed
# error.
{
    printf '%s\n' 'package main'
    printf '%s\n' 'func F() {'
    printf '%s\n' '    fmt.Println("x")'
    printf '%s\n' '}'
    printf '%s\n' 'func G() { if err != nil {} }'
} >"$SRCDIR/app.go"

# Java source: System.out.println debug (own line), empty catch.
{
    printf '%s\n' 'class C {'
    printf '%s\n' '  void f() {'
    printf '%s\n' '    System.out.println("x");'
    printf '%s\n' '  }'
    printf '%s\n' '  void g() { try { risky(); } catch (E e) {} }'
    printf '%s\n' '}'
} >"$SRCDIR/App.java"

# HTML: Vue v-html + Django safe filter + Blade unescaped (xss arms).
{
    printf '%s\n' "<div $SEC_VUE=\"userInput\"></div>"
    printf '%s\n' "{{ value|safe }}"
    printf '%s\n' "$SEC_BLADE \$raw !!}"
} >"$SRCDIR/view.html"

# JSX: React dangerouslySetInnerHTML (xss arm).
printf '%s\n' "el.$SEC_REACT = {__html: raw};" >"$SRCDIR/comp.jsx"

# A test file: check-code-health must SUPPRESS debug statements here (is_test_file
# boundary) — the print() below must NOT be flagged as a debug statement, driving
# the `if not test_file:` false arm and the is_test_file segment/basename arms.
printf '%s\n' 'print("in a test file")' >"$SRCDIR/tests/test_helper.py"

# contest.py: NOT a test file (segment anchoring negative) — print() DOES fire,
# driving the is_test_file segment arms' non-matching path.
printf '%s\n' 'print("not a test")' >"$SRCDIR/contest.py"

# Top-level basename test-file arms (no tests/ segment): test_*.py drives the
# `fnmatch(base, "test_*.*")` arm; widget_test.py drives the `*_test.*` arm.
printf '%s\n' 'print("dbg")' >"$SRCDIR/test_widget.py"
printf '%s\n' 'print("dbg")' >"$SRCDIR/widget_test.py"

# An except block with NO following non-blank line drives the
# _first_nonblank_after empty-string return (the except is the last content).
{
    printf '%s\n' 'try:'
    printf '%s\n' '    risky()'
    printf '%s\n' 'except Exception:'
} >"$SRCDIR/trailing_except.py"

# SKIP_GLOBS: a *.env.example carrying a secret (check-security skip) and a *.md
# carrying a TODO (check-code-health skip) drive the whole-file skip arms.
printf 'stripe = "%s"\n' "$SEC_STRIPE" >"$SRCDIR/secrets.env.example"
printf '%s\n' '# TODO: doc marker' >"$SRCDIR/notes.md"

# An unreadable source file drives the per-file open() OSError arm in both ports.
SRC_UNREAD="$SRCDIR/unreadable.py"
printf 'gh = "%s"\n' "$SEC_GHP" >"$SRC_UNREAD"
chmod 000 "$SRC_UNREAD" 2>/dev/null || true

SRC_LIST="$WORKDIR/src-list.txt"
: >"$SRC_LIST"
for f in "$SRCDIR"/app.py "$SRCDIR"/app.ts "$SRCDIR"/app.rb "$SRCDIR"/app.go \
    "$SRCDIR"/App.java "$SRCDIR"/view.html "$SRCDIR"/comp.jsx \
    "$SRCDIR"/tests/test_helper.py "$SRCDIR"/contest.py \
    "$SRCDIR"/test_widget.py "$SRCDIR"/widget_test.py \
    "$SRCDIR"/trailing_except.py \
    "$SRCDIR"/secrets.env.example "$SRCDIR"/notes.md "$SRC_UNREAD"; do
    printf '%s\n' "$f" >>"$SRC_LIST"
done
# A blank line drives the main() empty-path `if not path: continue` arm.
printf '\n' >>"$SRC_LIST"

# A file-list PATH that itself does not exist drives the main()
# file-list-not-found (OSError) arm — the list file is absent, not its contents.
SRC_NOFILE_LIST="$WORKDIR/src-nonexistent-list-XYZ.txt"

# --- check-docs-* corpus (#243) ---------------------------------------------
# The five check-docs-* ports were the lowest-coverage in the tree because the
# generic corpus above never exercised their edge/per-language/error arms. These
# fixtures drive those branches under measurement, in lockstep with the
# behavioral assertions in tests/validate-docs-detectors.sh (the #204 two-surface
# convention). Content-only ports (staleness, deadlinks, missing-api) run over
# DOCS_LIST from WORKDIR; the git-rooted ports (examples, organization) run cd'd
# into DOCS_SB so their `git rev-parse --show-toplevel` resolves to the sandbox.
DOCSDIR="$FIXDIR/docs"
mkdir -p "$DOCSDIR"

# staleness: stale date, future date, bare version, changelog-excluded forms,
# deprecated + plain URLs, stale marker vs plain TODO.
cat >"$DOCSDIR/staleness.md" <<'EOF'
Originally written 2001-01-15 for v1.
Planned for 2099-01-15 at the earliest.
Install release v1.2.3 from the archive.
## [1.2.3] section header
- v1.2.3 bullet entry
Docs at http://example.com/legacy/api page.
Docs at http://example.com/current/api page.
# TODO: this section is outdated and should change
# TODO: implement the new feature next sprint
EOF

# deadlinks: broken + existing relative links, every skip scheme, broken +
# matching anchor, suspicious + plain external URL.
: >"$DOCSDIR/present.md"
cat >"$DOCSDIR/deadlinks.md" <<'EOF'
See [the guide](./missing-guide.md) for details.
See [present](./present.md) for details.
A [x](http://example.com/a) link.
A [x](https://example.com/b) link.
A [x](mailto:dev@example.com) link.
A [x](#real-section) link.
A [x](ftp://example.com/c) link.
An [x]() empty link.
Jump to [the section](#ghost-section).
Jump to [the section](#real-section).
## Real Section
Old docs: https://example.com/deprecated-api here.
Current docs: https://example.com/stable-api here.
EOF

# missing-api: one documented + one undocumented public symbol per language, a
# private symbol (own-line `def _`), a _test.go skip, a body-docstring def (the
# next-two-lines docstring arm), and a public def whose trailing comment MENTIONS
# `def _foo`. That last line is the #348 boundary: the private skip is anchored on
# the def NAME (not a whole-line substring), so `public_alias` must be flagged
# (comment mention ≠ private) while own-line `def _private_helper` is skipped. The
# private def now enters the `defs()` loop (regex admits a leading `_`) and drives
# the name-anchored skip arm under measurement.
printf '%s\n' 'CONST = 1' 'def compute_total():' '    return 0' \
    '"""d."""' 'def documented_fn():' '    return 0' \
    'def public_alias():  # def _legacy_name kept for back-compat' '    return 0' \
    'def _private_helper():' '    return 0' >"$DOCSDIR/api.py"
# body-docstring arm in isolation: no `"""` in the 3 lines BEFORE the def, so the
# preceding-docstring arm does not fire and the next-two-lines body-docstring
# arm is the one that documents it.
printf '%s\n' 'x = 1' 'y = 2' 'z = 3' 'def body_doc_fn():' \
    '    """Body docstring documents this."""' '    return 0' >"$DOCSDIR/api_body.py"
printf '%s\n' 'const A = 1;' 'export function doThing() {}' \
    '/** d */' 'export function documented() {}' >"$DOCSDIR/api.ts"
printf '%s\n' 'package main' '' 'func DoThing() {}' \
    '// Documented does.' 'func Documented() {}' >"$DOCSDIR/api.go"
printf '%s\n' 'package main' '' 'func InTest() {}' >"$DOCSDIR/api_test.go"
printf '%s\n' 'const A: u8 = 1;' 'pub fn do_thing() {}' \
    '/// d' 'pub fn documented() {}' >"$DOCSDIR/api.rs"
printf '%s\n' 'set -e' 'deploy() {' '  true' '}' \
    '# Documented.' 'release() {' '  true' '}' \
    '_helper() {' '  true' '}' >"$DOCSDIR/api.sh"
printf '%s\n' 'class C' '  def process' '  end' \
    '  # Documented.' '  def documented' '  end' 'end' >"$DOCSDIR/api.rb"
printf '%s\n' 'class C {' '  public void doThing() {}' \
    '  /** Documented. */' '  public void documented() {}' '}' >"$DOCSDIR/api.java"

DOCS_LIST="$WORKDIR/docs-list.txt"
: >"$DOCS_LIST"
for f in "$DOCSDIR"/staleness.md "$DOCSDIR"/deadlinks.md "$DOCSDIR"/present.md \
    "$DOCSDIR"/api.py "$DOCSDIR"/api_body.py "$DOCSDIR"/api.ts "$DOCSDIR"/api.go \
    "$DOCSDIR"/api_test.go "$DOCSDIR"/api.rs "$DOCSDIR"/api.sh "$DOCSDIR"/api.rb \
    "$DOCSDIR"/api.java; do
    printf '%s\n' "$f" >>"$DOCS_LIST"
done

# Git sandbox for the two git-rooted ports (examples, organization). A bare
# `git init` is enough for `git rev-parse --show-toplevel`; no commit needed.
DOCS_SB="$WORKDIR/docs-sb"
mkdir -p "$DOCS_SB"
git -C "$DOCS_SB" init -q >/dev/null 2>&1 || true

# examples: python fence (broken/known/in-project import), shell fence
# (missing/present script), js + unknown fences, and a non-md skip.
: >"$DOCS_SB/localmod.py"
: >"$DOCS_SB/present-tool.sh"
cat >"$DOCS_SB/examples.md" <<'EOF'
```python
import nonexistent_pkg_xyz
import os
import localmod
```
```bash
./missing-tool.sh
bash present-tool.sh
```
```js
import { z } from "./nope";
```
```
plain block content
```
EOF
printf '%s\n' '```python' 'import nonexistent_pkg_xyz' '```' >"$DOCS_SB/not-a-doc.txt"

# organization: a LICENCE.md variant present (exercises the LICENSE-variant
# found/break arm) while README.md/CHANGELOG.md stay absent (their missing-root
# arms still fire); a pkg dir at the min-files boundary with no README; a dir
# with its own README; a deep dir (past the depth cap); a root-level file (its
# dir == project_root skip); and an excluded node_modules/<pkg> tree.
: >"$DOCS_SB/LICENCE.md"
: >"$DOCS_SB/root-file.py"
mkdir -p "$DOCS_SB/pkg" "$DOCS_SB/withreadme" "$DOCS_SB/a/b/c" "$DOCS_SB/node_modules/dep"
: >"$DOCS_SB/a/b/c/deep.py"
# Hidden + .pyc siblings in pkg exercise the listdir skip arms (name startswith
# '.', and the *.pyc/*.o glob) — they must NOT count toward the min-files total.
: >"$DOCS_SB/pkg/.hidden"
: >"$DOCS_SB/pkg/cached.pyc"
: >"$DOCS_SB/pkg/f1.py"
: >"$DOCS_SB/pkg/f2.py"
: >"$DOCS_SB/pkg/f3.py"
: >"$DOCS_SB/withreadme/README.md"
: >"$DOCS_SB/withreadme/g1.py"
: >"$DOCS_SB/withreadme/g2.py"
: >"$DOCS_SB/a/b/h1.py"
: >"$DOCS_SB/a/b/h2.py"
: >"$DOCS_SB/node_modules/dep/n1.js"
: >"$DOCS_SB/node_modules/dep/n2.js"

DOCS_SB_LIST="$WORKDIR/docs-sb-list.txt"
: >"$DOCS_SB_LIST"
for f in "$DOCS_SB"/examples.md "$DOCS_SB"/not-a-doc.txt "$DOCS_SB"/root-file.py \
    "$DOCS_SB"/pkg/f1.py "$DOCS_SB"/pkg/f2.py "$DOCS_SB"/pkg/f3.py \
    "$DOCS_SB"/withreadme/g1.py "$DOCS_SB"/withreadme/g2.py \
    "$DOCS_SB"/a/b/h1.py "$DOCS_SB"/a/b/h2.py "$DOCS_SB"/a/b/c/deep.py \
    "$DOCS_SB"/node_modules/dep/n1.js "$DOCS_SB"/node_modules/dep/n2.js; do
    printf '%s\n' "$f" >>"$DOCS_SB_LIST"
done

# A file list pointing at a non-existent file drives the per-path skip arm
# (`os.path.isfile(...)` False -> continue) in every content-reading port; a
# missing list PATH itself drives the file-not-found (OSError) arm; and a
# no-argument invocation drives the usage-error arm. These are the negative-path
# branches (issue #243 priority 2) the positive corpus never reaches.
DOCS_GHOST_LIST="$WORKDIR/docs-ghost-list.txt"
printf '%s\n' "$WORKDIR/does-not-exist-xyz.md" "$WORKDIR/also-missing.py" >"$DOCS_GHOST_LIST"
DOCS_NOFILE_LIST="$WORKDIR/no-such-list-file.txt" # intentionally never created

# An empty list PATH (exists, no lines) drives the empty-list early-return arm
# (organization returns 0 before touching the project root — issue #64).
DOCS_EMPTY_LIST="$WORKDIR/docs-empty-list.txt"
: >"$DOCS_EMPTY_LIST"

# An unreadable file that PASSES os.path.isfile() but fails open() drives the
# per-file OSError read arm (`except OSError: continue`). chmod 000 only denies a
# NON-root reader — CI/dev run as runner/vscode (uid != 0). If this ever runs as
# root, chmod 000 is a no-op and these OSError arms silently go uncovered; emit a
# visible note in that case rather than losing the coverage without a trace. A
# blank line in the list also exercises the empty-token skip.
if [ "$(id -u)" -eq 0 ]; then
    printf '[note] python-coverage — running as root: chmod-000 unreadable-file OSError arms are not exercised (root bypasses file perms)\n'
fi
DOCS_UNREADABLE="$DOCSDIR/unreadable.md"
printf '%s\n' 'stale 2001-01-01 [x](./nope.md)' >"$DOCS_UNREADABLE"
chmod 000 "$DOCS_UNREADABLE" 2>/dev/null || true
DOCS_UNREAD_LIST="$WORKDIR/docs-unread-list.txt"
printf '%s\n' "$DOCS_UNREADABLE" "" >"$DOCS_UNREAD_LIST"

# missing-api reads a file it cannot open (its own `except OSError: return` in
# scan_file) — the unreadable .py drives it. A leading BLANK line drives the
# empty-token skip (`if not path: continue`).
DOCS_UNREADABLE_PY="$DOCSDIR/unreadable.py"
printf '%s\n' 'def public_fn():' '    return 0' >"$DOCS_UNREADABLE_PY"
chmod 000 "$DOCS_UNREADABLE_PY" 2>/dev/null || true
DOCS_UNREAD_PY_LIST="$WORKDIR/docs-unread-py-list.txt"
printf '%s\n' "" "$DOCS_UNREADABLE_PY" >"$DOCS_UNREAD_PY_LIST"

# organization edge list: an absolute root-level path (dirname "" -> the
# `if not d` skip), a ghost subdir (not os.path.isdir -> skip), and a real
# 000-perm dir whose os.listdir() raises OSError (the listdir except arm). All
# under the sandbox so the project-root prefix checks pass where relevant.
mkdir -p "$DOCS_SB/locked"
: >"$DOCS_SB/locked/f1.py"
: >"$DOCS_SB/locked/f2.py"
: >"$DOCS_SB/locked/f3.py"
chmod 000 "$DOCS_SB/locked" 2>/dev/null || true
DOCS_ORG_EDGE_LIST="$WORKDIR/docs-org-edge-list.txt"
printf '%s\n' \
    "/zzz-root-level-file.py" \
    "$DOCS_SB/ghostdir/absent.py" \
    "$DOCS_SB/locked/f1.py" >"$DOCS_ORG_EDGE_LIST"

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
        */check-security/patterns.py | */check-code-health/patterns.py)
            # Drive the per-language / per-framework / boundary arms over the
            # source-shaped corpus (#348); the generic FILE_LIST keeps the
            # no-match early paths covered. The negative-path arms (usage error,
            # file-list-not-found) run below.
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$SRC_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            # Usage-error arm (no argument -> exit 1).
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            # File-list-not-found arm (a list PATH that does not exist -> OSError).
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$SRC_NOFILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-ai-config/patterns.py)
            # Drive this port over the config-shaped corpus (agent/skill/MCP/hook/
            # workflow.js) instead of the generic one, with bloat thresholds tuned
            # down so the tiny CLAUDE.md trips the HIGH arm and the SKILL.md trips
            # the WARNING-only arm (SKILL_WARN<lines<SKILL_HIGH), driving both
            # bloat branches under measurement (#348). Also run the generic list
            # so the no-match early-return globs stay covered.
            CLAUDE_MD_WARN=1 CLAUDE_MD_HIGH=2 DOC_WARN=1 DOC_HIGH=3 \
                SKILL_WARN=3 SKILL_HIGH=99 \
                python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$AICFG_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            # Negative-path arms (#348): usage error (no arg) and file-list-not-
            # found (OSError). The empty-path + unreadable-file skip arms are
            # driven by the shared negative-path loop below.
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$WORKDIR/ai-nonexistent-list-XYZ.txt" >/dev/null 2>&1 || true
            # Relative `plugins/`-prefixed path -> _plugins_dir_for's relative arm
            # (run cd'd into $FIXDIR so the path stays relative). (#348)
            (cd "$FIXDIR" && python3 -m coverage run --parallel-mode \
                --source="$PLUGINS_DIR" "$py" "$AICFG_REL_LIST" >/dev/null 2>&1) || true
            ;;
        */check-docs-staleness/patterns.py)
            # STALENESS_MONTHS=-1 makes the current-month date in staleness.md
            # cross the threshold deterministically (year*12+month boundary).
            CHECK_STALENESS_MONTHS=-1 \
                python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DOCS_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-docs-deadlinks/patterns.py | */check-docs-missing-api/patterns.py)
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DOCS_LIST" >/dev/null 2>&1 || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-docs-examples/patterns.py)
            # Git-rooted: cd into the sandbox so `git rev-parse` resolves there.
            (cd "$DOCS_SB" && python3 -m coverage run --parallel-mode \
                --source="$PLUGINS_DIR" "$py" "$DOCS_SB_LIST" >/dev/null 2>&1) || true
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$FILE_LIST" >/dev/null 2>&1 || true
            ;;
        */check-docs-organization/patterns.py)
            # Git-rooted + min-files/depth boundaries driven via env.
            (cd "$DOCS_SB" && CHECK_ORG_MIN_FILES=3 CHECK_ORG_README_DEPTH=2 \
                python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$py" "$DOCS_SB_LIST" >/dev/null 2>&1) || true
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

# --- Negative-path drivers for the check-docs-* ports (#243) -----------------
# Drive the usage-error, file-not-found, and per-path-skip arms of each docs
# port. These branches (issue priority 2) return non-zero / emit nothing, so the
# positive corpus above never reaches them; the behavioral contract is pinned by
# validate-python-ports.sh, this only makes the lines execute under measurement.
for docs_port in check-docs-staleness check-docs-deadlinks check-docs-examples \
    check-docs-missing-api check-docs-organization; do
    dp="$PLUGINS_DIR/review-audit/skills/$docs_port/patterns.py"
    [ -f "$dp" ] || continue
    # No argument -> usage-error arm (exit 1).
    python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$dp" >/dev/null 2>&1 || true
    # A list PATH that does not exist -> file-not-found (OSError) arm.
    python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$dp" "$DOCS_NOFILE_LIST" >/dev/null 2>&1 || true
    # A list of non-existent files -> per-path isfile()==False skip arm.
    python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$dp" "$DOCS_GHOST_LIST" >/dev/null 2>&1 || true
    # An empty (0-line) list -> empty-list early-return arm.
    python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$dp" "$DOCS_EMPTY_LIST" >/dev/null 2>&1 || true
    # An unreadable file that passes isfile() -> per-file OSError read arm.
    # missing-api reads .py (opens in scan_file); the others read .md content.
    case "$docs_port" in
        check-docs-missing-api)
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$dp" "$DOCS_UNREAD_PY_LIST" >/dev/null 2>&1 || true
            ;;
        check-docs-examples | check-docs-organization) ;; # OSError arm handled below
        *)
            python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
                "$dp" "$DOCS_UNREAD_LIST" >/dev/null 2>&1 || true
            ;;
    esac
done

# The two git-rooted ports' _project_root() has an OSError fallback (git binary
# absent). Drive it with PATH emptied so `git` is not found -> subprocess raises
# FileNotFoundError (OSError) -> return ".". python3 is launched by ABSOLUTE path
# (an empty PATH cannot resolve `python3` itself); the emptied PATH only reaches
# the port's internal `git` subprocess lookup.
PYBIN="$(command -v python3)"
for docs_port in check-docs-examples check-docs-organization; do
    dp="$PLUGINS_DIR/review-audit/skills/$docs_port/patterns.py"
    [ -f "$dp" ] || continue
    (cd "$DOCS_SB" && PATH="" "$PYBIN" -m coverage run --parallel-mode \
        --source="$PLUGINS_DIR" "$dp" "$DOCS_SB_LIST" >/dev/null 2>&1) || true
done

# check-docs-examples reads .md content in scan_file — an unreadable .md that
# passes isfile() drives its per-file OSError arm (run inside the sandbox).
(cd "$DOCS_SB" &&
    python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLUGINS_DIR/review-audit/skills/check-docs-examples/patterns.py" \
        "$DOCS_UNREAD_LIST" >/dev/null 2>&1) || true

# organization: root-level path skip, ghost-subdir skip, and listdir-OSError arm.
(cd "$DOCS_SB" && CHECK_ORG_MIN_FILES=3 \
    python3 -m coverage run --parallel-mode --source="$PLUGINS_DIR" \
    "$PLUGINS_DIR/review-audit/skills/check-docs-organization/patterns.py" \
    "$DOCS_ORG_EDGE_LIST" >/dev/null 2>&1) || true

# Restore perms so the trap `rm -rf` can clean WORKDIR without warnings.
chmod 644 "$DOCS_UNREADABLE" "$DOCS_UNREADABLE_PY" 2>/dev/null || true
chmod 755 "$DOCS_SB/locked" 2>/dev/null || true
chmod 644 "$SRC_UNREAD" 2>/dev/null || true
chmod 644 "$AI_UNREAD" 2>/dev/null || true

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
