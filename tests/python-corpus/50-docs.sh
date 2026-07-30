# shellcheck shell=bash
# check-docs-* corpus — python coverage fixtures (issue #564 split).
#
# Builds staleness, dead links, examples, missing-api and organization fixtures, including the unreadable-file and empty-list edges (#243).
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
