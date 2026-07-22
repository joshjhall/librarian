#!/usr/bin/env bash
# check-docs-* detector behavioral gate (issue #243).
#
# The five review-audit check-docs-* pre-scan ports —
#
#   check-docs-staleness    check-docs-deadlinks   check-docs-examples
#   check-docs-missing-api   check-docs-organization
#
# — were the lowest-coverage Python ports in the tree (60–72% line-rate) because,
# unlike check-ai-config (tests/validate-checker-detectors.sh), NONE of them had
# a behavioral gate: only tests/validate-python-ports.sh covered them, and it
# asserts bash==python PARITY over one shared fixture tree, which — as its own
# header notes — "cannot catch a regression where both impls break the same way."
# Whole branches (the edge / error / per-language arms) never executed and had
# zero output-asserting coverage.
#
# This gate is the behavioral half of the #204 two-surface convention for the
# docs family: it drives PURPOSE-BUILT fixtures through each scanner and asserts
# the SPECIFIC finding category each fixture must emit — AND that a clean
# counter-fixture stays silent — with emphasis on BOUNDARIES and NEGATIVE paths
# (the off-by-one at a staleness threshold, the URL-scheme skips, the min-files
# boundary, the per-language documented/undocumented split). The sibling
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
# goes red, then reverting. The mutations checked, one per port: staleness — the
# expired-date `<` threshold flipped to `<=`; deadlinks — the missing-target
# `os.path.exists` check forced true; examples — the KNOWN_MODULES skip emptied;
# missing-api — the preceding-docstring and Go doc-comment skips forced false;
# organization — the `count >= min_files` boundary narrowed to `>`. All five went
# red under mutation and green on revert.
#
# #348 boundary added: the missing-api private skip is anchored on the def/class
# NAME, not a whole-line substring, so a public def/function whose trailing
# comment merely mentions `def _x` / `function _x` is still flagged (the old
# `"def _" in content` / `*"function _"*` test silently swallowed it). Fault-
# injection: reverting the py skip to `if "def _" in content` (and the sh case to
# `*"def _"*`) turns the new comment-mention assertions red; the name-anchored
# form is green.
#
# check-docs-organization and check-docs-examples resolve a project root via
# `git rev-parse --show-toplevel`, so their fixtures run inside a fresh `git init`
# sandbox with git's hook-exported environment scrubbed (the GIT_SCRUB pattern
# from validate-pre-review-gates.sh / validate-golem-scripts.sh). The other three
# ports read only file content (or resolve relative to the document's own dir),
# so their CWD is irrelevant and they run under $WORKDIR.
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

# Git's hook-exported environment — scrub per invocation so each sandbox is
# hermetic even under a pre-push hook (mirrors validate-pre-review-gates.sh).
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "check-docs-* detector fixtures (#243)"

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# Per-skill directories.
SK_STALE="$SKILLS_DIR/check-docs-staleness"
SK_DEAD="$SKILLS_DIR/check-docs-deadlinks"
SK_EXAMPLES="$SKILLS_DIR/check-docs-examples"
SK_MISSAPI="$SKILLS_DIR/check-docs-missing-api"
SK_ORG="$SKILLS_DIR/check-docs-organization"

# --- Scanner drivers ---------------------------------------------------------
# emit_rows IMPL SKILLDIR LIST CWD CAT [ENV...] — the rows one impl emits for a
# single category. IMPL is "py" or "sh"; extra args are VAR=VALUE env overrides
# (threshold tuning). Run cd'd into CWD so the git-rooted ports resolve their
# project root to the sandbox; the content-only ports ignore CWD.
emit_rows() {
    local impl="$1" skill="$2" list="$3" cwd="$4" cat="$5"
    shift 5
    if [ "$impl" = py ]; then
        (
            cd "$cwd" && /usr/bin/env "$@" python3 "$skill/patterns.py" "$list" 2>/dev/null
        )
    else
        (
            cd "$cwd" &&
                /usr/bin/env PATTERNS_FORCE_BASH=1 "$@" "$REAL_BASH" "$skill/patterns.sh" "$list" 2>/dev/null
        )
    fi | command awk -F '\t' -v c="$cat" '$3 == c'
}

# assert_fires SKILLDIR LIST CWD CAT NEEDLE MSG [ENV...] — the category fires
# (rows contain NEEDLE) in BOTH impls. Python side skipped (not failed) when
# python3 is absent.
assert_fires() {
    local skill="$1" list="$2" cwd="$3" cat="$4" needle="$5" msg="$6"
    shift 6
    assert_contains "$(emit_rows sh "$skill" "$list" "$cwd" "$cat" "$@")" \
        "$needle" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_contains "$(emit_rows py "$skill" "$list" "$cwd" "$cat" "$@")" \
            "$needle" "$msg (python)"
    fi
}

# assert_silent SKILLDIR LIST CWD CAT MSG [ENV...] — the category emits NOTHING
# in both impls.
assert_silent() {
    local skill="$1" list="$2" cwd="$3" cat="$4" msg="$5"
    shift 5
    assert_output_empty "$(emit_rows sh "$skill" "$list" "$cwd" "$cat" "$@")" \
        "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty "$(emit_rows py "$skill" "$list" "$cwd" "$cat" "$@")" \
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

# new_git_sandbox <varname> — a fresh `git init` sandbox with one seed commit so
# `git rev-parse --show-toplevel` resolves to the sandbox. Hook env scrubbed.
new_git_sandbox() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" config user.name "Test"
    printf -v "$__out" '%s' "$dir"
}

# ============================================================================
# check-docs-staleness — expired-date / outdated-reference / stale-comment
# ============================================================================
test_staleness() {
    local d list now_ym

    # --- expired-date: an off-by-one at `(year*12+month) < threshold_months`. ---
    # A date in the CURRENT year-month is the boundary. With STALENESS_MONTHS=0 the
    # threshold is exactly now (equal is NOT stale -> silent); with =-1 the
    # threshold is now+1 (now < now+1 -> stale -> fires). Same fixture, env flip:
    # a `<` -> `<=` regression flips the silent case to firing.
    now_ym="$(command date +%Y-%m)"
    d="$(fresh_dir)"
    command printf '%s\n' "Doc last updated ${now_ym}-15 in this release." >"$d/cur.md"
    list="$(make_list "$d/l" "$d/cur.md")"
    assert_silent "$SK_STALE" "$list" "$WORKDIR" expired-date \
        "staleness: a current-month date is NOT stale at the threshold (equal)" \
        CHECK_STALENESS_MONTHS=0
    assert_fires "$SK_STALE" "$list" "$WORKDIR" expired-date \
        "Date reference older than" \
        "staleness: the same date IS stale one month past the threshold" \
        CHECK_STALENESS_MONTHS=-1

    # A comfortably-old date fires under the default threshold (12 months).
    d="$(fresh_dir)"
    command printf '%s\n' "Originally written 2001-01-15 for v1." >"$d/old.md"
    list="$(make_list "$d/l" "$d/old.md")"
    assert_fires "$SK_STALE" "$list" "$WORKDIR" expired-date \
        "Date reference older than 12 months" \
        "staleness: a years-old date fires expired-date"

    # A far-future date is never stale (exercises the is_date_stale False arm).
    d="$(fresh_dir)"
    command printf '%s\n' "Planned for 2099-01-15 at the earliest." >"$d/future.md"
    list="$(make_list "$d/l" "$d/future.md")"
    assert_silent "$SK_STALE" "$list" "$WORKDIR" expired-date \
        "staleness: a future date is not stale"

    # --- outdated-reference: bare version fires; changelog/list forms excluded. ---
    d="$(fresh_dir)"
    command printf '%s\n' "Install release v1.2.3 from the archive." >"$d/ver.md"
    list="$(make_list "$d/l" "$d/ver.md")"
    assert_fires "$SK_STALE" "$list" "$WORKDIR" outdated-reference \
        "Version reference to verify" \
        "staleness: a bare version reference fires outdated-reference"

    d="$(fresh_dir)"
    {
        command printf '%s\n' "## [1.2.3] section header"
        command printf '%s\n' "- v1.2.3 bullet entry"
    } >"$d/changelog.md"
    list="$(make_list "$d/l" "$d/changelog.md")"
    assert_silent "$SK_STALE" "$list" "$WORKDIR" outdated-reference \
        "staleness: changelog '## [x]' and '- vX' forms are excluded"

    # --- outdated-reference: a URL carrying a deprecation indicator. ---
    d="$(fresh_dir)"
    command printf '%s\n' "Docs at http://example.com/legacy/api page." >"$d/depurl.md"
    list="$(make_list "$d/l" "$d/depurl.md")"
    assert_fires "$SK_STALE" "$list" "$WORKDIR" outdated-reference \
        "URL with deprecation indicators" \
        "staleness: a URL with a deprecation word fires outdated-reference"

    d="$(fresh_dir)"
    command printf '%s\n' "Docs at http://example.com/current/api page." >"$d/liveurl.md"
    list="$(make_list "$d/l" "$d/liveurl.md")"
    assert_silent "$SK_STALE" "$list" "$WORKDIR" outdated-reference \
        "staleness: a plain URL with no deprecation word is silent"

    # --- stale-comment: a staleness marker phrase. ---
    d="$(fresh_dir)"
    command printf '%s\n' "# TODO: this section is outdated and should change" >"$d/marker.md"
    list="$(make_list "$d/l" "$d/marker.md")"
    assert_fires "$SK_STALE" "$list" "$WORKDIR" stale-comment \
        "Staleness marker" \
        "staleness: TODO + 'outdated' fires stale-comment"

    d="$(fresh_dir)"
    command printf '%s\n' "# TODO: implement the new feature next sprint" >"$d/todo.md"
    list="$(make_list "$d/l" "$d/todo.md")"
    assert_silent "$SK_STALE" "$list" "$WORKDIR" stale-comment \
        "staleness: a plain TODO with no staleness word is silent"
}

# ============================================================================
# check-docs-deadlinks — broken-relative-link / broken-anchor / suspicious-external-link
# ============================================================================
test_deadlinks() {
    local d list

    # --- broken-relative-link: missing target fires; existing target silent. ---
    d="$(fresh_dir)"
    command printf '%s\n' "See [the guide](./missing-guide.md) for details." >"$d/doc.md"
    list="$(make_list "$d/l" "$d/doc.md")"
    assert_fires "$SK_DEAD" "$list" "$WORKDIR" broken-relative-link \
        "Link target not found: ./missing-guide.md" \
        "deadlinks: a missing relative link target fires"

    d="$(fresh_dir)"
    : >"$d/present.md"
    command printf '%s\n' "See [the guide](./present.md) for details." >"$d/doc.md"
    list="$(make_list "$d/l" "$d/doc.md")"
    assert_silent "$SK_DEAD" "$list" "$WORKDIR" broken-relative-link \
        "deadlinks: an existing relative link target is silent"

    # Every non-relative scheme (http/https/mailto/#/ftp) and the empty target
    # are skipped — none may fire broken-relative-link.
    d="$(fresh_dir)"
    {
        command printf '%s\n' "A [x](http://example.com/a) link."
        command printf '%s\n' "A [x](https://example.com/b) link."
        command printf '%s\n' "A [x](mailto:dev@example.com) link."
        command printf '%s\n' "A [x](#local-anchor) link."
        command printf '%s\n' "A [x](ftp://example.com/c) link."
        command printf '%s\n' "An [x]() empty link."
    } >"$d/schemes.md"
    list="$(make_list "$d/l" "$d/schemes.md")"
    assert_silent "$SK_DEAD" "$list" "$WORKDIR" broken-relative-link \
        "deadlinks: http/https/mailto/#/ftp/empty targets are all skipped"

    # --- broken-anchor: no matching heading fires; matching heading silent. ---
    d="$(fresh_dir)"
    {
        command printf '%s\n' "Jump to [the section](#ghost-section)."
        command printf '%s\n' "## Some Other Heading"
    } >"$d/anchor.md"
    list="$(make_list "$d/l" "$d/anchor.md")"
    assert_fires "$SK_DEAD" "$list" "$WORKDIR" broken-anchor \
        "Anchor #ghost-section has no matching heading" \
        "deadlinks: an anchor with no matching heading fires"

    d="$(fresh_dir)"
    {
        command printf '%s\n' "Jump to [the section](#real-section)."
        command printf '%s\n' "## Real Section"
    } >"$d/anchor-ok.md"
    list="$(make_list "$d/l" "$d/anchor-ok.md")"
    assert_silent "$SK_DEAD" "$list" "$WORKDIR" broken-anchor \
        "deadlinks: an anchor matching a heading is silent"

    # --- suspicious-external-link: a deprecation indicator in the URL. ---
    d="$(fresh_dir)"
    command printf '%s\n' "Old docs: https://example.com/deprecated-api here." >"$d/susp.md"
    list="$(make_list "$d/l" "$d/susp.md")"
    assert_fires "$SK_DEAD" "$list" "$WORKDIR" suspicious-external-link \
        "Suspicious URL" \
        "deadlinks: a URL with a deprecation indicator fires"

    d="$(fresh_dir)"
    command printf '%s\n' "Current docs: https://example.com/stable-api here." >"$d/plain.md"
    list="$(make_list "$d/l" "$d/plain.md")"
    assert_silent "$SK_DEAD" "$list" "$WORKDIR" suspicious-external-link \
        "deadlinks: a plain external URL is silent"
}

# ============================================================================
# check-docs-examples — broken-example (git-rooted; runs inside a sandbox)
# ============================================================================
test_examples() {
    local sb list

    new_git_sandbox sb

    # --- python fence: unresolvable import fires; known + in-project silent. ---
    command printf '%s\n' \
        '```python' 'import nonexistent_pkg_xyz' '```' >"$sb/broken-import.md"
    list="$(make_list "$WORKDIR/ex1" "$sb/broken-import.md")"
    assert_fires "$SK_EXAMPLES" "$list" "$sb" broken-example \
        "Import not found in project: import nonexistent_pkg_xyz" \
        "examples: a python import absent from the project fires"

    command printf '%s\n' '```python' 'import os' '```' >"$sb/known-import.md"
    list="$(make_list "$WORKDIR/ex2" "$sb/known-import.md")"
    assert_silent "$SK_EXAMPLES" "$list" "$sb" broken-example \
        "examples: a stdlib import (os) is silent"

    : >"$sb/localmod.py"
    command printf '%s\n' '```python' 'import localmod' '```' >"$sb/proj-import.md"
    list="$(make_list "$WORKDIR/ex3" "$sb/proj-import.md")"
    assert_silent "$SK_EXAMPLES" "$list" "$sb" broken-example \
        "examples: an import resolving to a project file is silent"

    # --- shell fence: missing script fires; present script silent. ---
    command printf '%s\n' '```bash' './missing-tool.sh' '```' >"$sb/broken-sh.md"
    list="$(make_list "$WORKDIR/ex4" "$sb/broken-sh.md")"
    assert_fires "$SK_EXAMPLES" "$list" "$sb" broken-example \
        "Script not found: ./missing-tool.sh" \
        "examples: a shell fence referencing a missing script fires"

    : >"$sb/present-tool.sh"
    command printf '%s\n' '```bash' 'bash present-tool.sh' '```' >"$sb/present-sh.md"
    list="$(make_list "$WORKDIR/ex5" "$sb/present-sh.md")"
    assert_silent "$SK_EXAMPLES" "$list" "$sb" broken-example \
        "examples: a shell fence referencing a present script is silent"

    # --- js/ts and unknown fences set state but emit nothing (branch coverage). ---
    command printf '%s\n' \
        '```js' 'import { z } from "./nope";' '```' \
        '```' 'plain block content' '```' >"$sb/other-fences.md"
    list="$(make_list "$WORKDIR/ex6" "$sb/other-fences.md")"
    assert_silent "$SK_EXAMPLES" "$list" "$sb" broken-example \
        "examples: js and unknown fences emit nothing"

    # --- non-markdown files are skipped wholesale. ---
    command printf '%s\n' '```python' 'import nonexistent_pkg_xyz' '```' >"$sb/not-a-doc.txt"
    list="$(make_list "$WORKDIR/ex7" "$sb/not-a-doc.txt")"
    assert_silent "$SK_EXAMPLES" "$list" "$sb" broken-example \
        "examples: a non-.md/.rst file is skipped"
}

# ============================================================================
# check-docs-missing-api — undocumented-public-api, one arm per language
# ============================================================================
test_missing_api() {
    local d list

    # --- Python: undocumented fires; docstring-before, body-docstring, private silent. ---
    d="$(fresh_dir)"
    command printf '%s\n' "CONST = 1" "def compute_total():" "    return 0" >"$d/u.py"
    list="$(make_list "$d/l" "$d/u.py")"
    assert_fires "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "Python: def compute_total" \
        "missing-api py: an undocumented public def fires"

    d="$(fresh_dir)"
    command printf '%s\n' '"""Module docstring."""' "def compute_total():" "    return 0" >"$d/doc.py"
    list="$(make_list "$d/l" "$d/doc.py")"
    assert_silent "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "missing-api py: a preceding docstring documents the def"

    d="$(fresh_dir)"
    command printf '%s\n' "def compute_total():" '    """Body docstring."""' "    return 0" >"$d/body.py"
    list="$(make_list "$d/l" "$d/body.py")"
    assert_silent "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "missing-api py: a body-opening docstring documents the def"

    d="$(fresh_dir)"
    command printf '%s\n' "def _private_helper():" "    return 0" >"$d/priv.py"
    list="$(make_list "$d/l" "$d/priv.py")"
    assert_silent "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "missing-api py: a private (_-prefixed) def is skipped"

    # #348 boundary: the private skip is anchored on the def NAME, not a
    # whole-line substring. A genuinely-public def whose trailing comment merely
    # MENTIONS `def _x` must still fire (the old `"def _" in content` test
    # silently swallowed it). Assert both the def and the class arm.
    d="$(fresh_dir)"
    command printf '%s\n' "def public_alias():  # def _legacy_name kept" "    return 0" >"$d/mention.py"
    list="$(make_list "$d/l" "$d/mention.py")"
    assert_fires "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "Python: def public_alias" \
        "missing-api py: a public def whose comment mentions 'def _' still fires (#348)"

    d="$(fresh_dir)"
    command printf '%s\n' "class Public:  # class _Old alias" "    pass" >"$d/mention_cls.py"
    list="$(make_list "$d/l" "$d/mention_cls.py")"
    assert_fires "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "Python: class Public" \
        "missing-api py: a public class whose comment mentions 'class _' still fires (#348)"

    # --- JS/TS: undocumented export fires; /** */ block silent. ---
    d="$(fresh_dir)"
    command printf '%s\n' "const A = 1;" "export function doThing() {}" >"$d/u.ts"
    list="$(make_list "$d/l" "$d/u.ts")"
    assert_fires "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "JS/TS: export function doThing" \
        "missing-api ts: an undocumented export fires"

    d="$(fresh_dir)"
    command printf '%s\n' "/** Does the thing. */" "export function doThing() {}" >"$d/doc.ts"
    list="$(make_list "$d/l" "$d/doc.ts")"
    assert_silent "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "missing-api ts: a preceding /** */ documents the export"

    # --- Go: undocumented exported func fires; doc-comment + _test.go silent. ---
    d="$(fresh_dir)"
    command printf '%s\n' "package main" "" "func DoThing() {}" >"$d/u.go"
    list="$(make_list "$d/l" "$d/u.go")"
    assert_fires "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "Go: func DoThing" \
        "missing-api go: an undocumented exported func fires"

    d="$(fresh_dir)"
    command printf '%s\n' "package main" "// DoThing does the thing." "func DoThing() {}" >"$d/doc.go"
    list="$(make_list "$d/l" "$d/doc.go")"
    assert_silent "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "missing-api go: a '// DoThing' doc comment documents the func"

    d="$(fresh_dir)"
    command printf '%s\n' "package main" "" "func DoThing() {}" >"$d/x_test.go"
    list="$(make_list "$d/l" "$d/x_test.go")"
    assert_silent "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "missing-api go: a _test.go file is skipped wholesale"

    # --- Rust: undocumented pub fires; /// doc silent. ---
    d="$(fresh_dir)"
    command printf '%s\n' "const A: u8 = 1;" "pub fn do_thing() {}" >"$d/u.rs"
    list="$(make_list "$d/l" "$d/u.rs")"
    assert_fires "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "Rust: pub fn do_thing" \
        "missing-api rs: an undocumented pub fn fires"

    d="$(fresh_dir)"
    command printf '%s\n' "/// Does the thing." "pub fn do_thing() {}" >"$d/doc.rs"
    list="$(make_list "$d/l" "$d/doc.rs")"
    assert_silent "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "missing-api rs: a preceding /// documents the pub fn"

    # --- Shell: undocumented func fires; # comment + private silent. ---
    d="$(fresh_dir)"
    command printf '%s\n' "set -e" "deploy() {" "  true" "}" >"$d/u.sh"
    list="$(make_list "$d/l" "$d/u.sh")"
    assert_fires "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "Shell: deploy()" \
        "missing-api sh: an undocumented function fires"

    d="$(fresh_dir)"
    command printf '%s\n' "# Deploy the app." "deploy() {" "  true" "}" >"$d/doc.sh"
    list="$(make_list "$d/l" "$d/doc.sh")"
    assert_silent "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "missing-api sh: a preceding # comment documents the function"

    d="$(fresh_dir)"
    command printf '%s\n' "_helper() {" "  true" "}" >"$d/priv.sh"
    list="$(make_list "$d/l" "$d/priv.sh")"
    assert_silent "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "missing-api sh: a private (_-prefixed) function is skipped"

    d="$(fresh_dir)"
    command printf '%s\n' "function _priv() {" "  true" "}" >"$d/privfn.sh"
    list="$(make_list "$d/l" "$d/privfn.sh")"
    assert_silent "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "missing-api sh: a private 'function _'-prefixed function is skipped"

    # #348 boundary: a public function whose trailing comment MENTIONS
    # `function _x` must still fire (the old `*"function _"*` whole-line glob
    # swallowed it). Name-anchored skip fixes it.
    d="$(fresh_dir)"
    command printf '%s\n' "deploy() {  # function _old_deploy renamed" "  true" "}" >"$d/mention.sh"
    list="$(make_list "$d/l" "$d/mention.sh")"
    assert_fires "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "Shell: deploy()" \
        "missing-api sh: a public function whose comment mentions 'function _' still fires (#348)"

    # --- Ruby: undocumented def fires; # comment silent. ---
    d="$(fresh_dir)"
    command printf '%s\n' "class C" "  def process" "  end" "end" >"$d/u.rb"
    list="$(make_list "$d/l" "$d/u.rb")"
    assert_fires "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "Ruby: " \
        "missing-api rb: an undocumented def fires"

    d="$(fresh_dir)"
    command printf '%s\n' "class C" "  # Process it." "  def process" "  end" "end" >"$d/doc.rb"
    list="$(make_list "$d/l" "$d/doc.rb")"
    assert_silent "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "missing-api rb: a preceding # comment documents the def"

    # --- Java/Kotlin: undocumented public method fires; /** */ silent. ---
    d="$(fresh_dir)"
    command printf '%s\n' "class C {" "  public void doThing() {}" "}" >"$d/u.java"
    list="$(make_list "$d/l" "$d/u.java")"
    assert_fires "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "Java/Kotlin: " \
        "missing-api java: an undocumented public method fires"

    d="$(fresh_dir)"
    command printf '%s\n' "class C {" "  /** Does the thing. */" "  public void doThing() {}" "}" >"$d/doc.java"
    list="$(make_list "$d/l" "$d/doc.java")"
    assert_silent "$SK_MISSAPI" "$list" "$WORKDIR" undocumented-public-api \
        "missing-api java: a preceding /** */ documents the public method"
}

# ============================================================================
# check-docs-organization — missing-root-doc / missing-dir-readme (git-rooted)
# ============================================================================
test_organization() {
    local sb list

    # --- missing-root-doc: absent README/LICENSE/CHANGELOG fire. ---
    new_git_sandbox sb
    command mkdir -p "$sb/src"
    : >"$sb/src/a.py"
    list="$(make_list "$WORKDIR/org1" "$sb/src/a.py")"
    assert_fires "$SK_ORG" "$list" "$sb" missing-root-doc \
        "Missing standard file: README.md" \
        "organization: a missing README.md fires missing-root-doc"

    # A LICENCE.md (British variant) satisfies the LICENSE check; with README.md
    # and CHANGELOG.md also present, missing-root-doc is fully silent.
    new_git_sandbox sb
    : >"$sb/README.md"
    : >"$sb/CHANGELOG.md"
    : >"$sb/LICENCE.md"
    command mkdir -p "$sb/src"
    : >"$sb/src/a.py"
    list="$(make_list "$WORKDIR/org2" "$sb/src/a.py")"
    assert_silent "$SK_ORG" "$list" "$sb" missing-root-doc \
        "organization: a LICENCE.md variant + README + CHANGELOG is silent"

    # --- missing-dir-readme: min-files boundary via CHECK_ORG_MIN_FILES. ---
    # A dir with exactly MIN files and no README fires; one file fewer is silent.
    new_git_sandbox sb
    : >"$sb/README.md"
    : >"$sb/LICENSE"
    : >"$sb/CHANGELOG.md"
    command mkdir -p "$sb/pkg"
    : >"$sb/pkg/f1.py"
    : >"$sb/pkg/f2.py"
    : >"$sb/pkg/f3.py"
    list="$(make_list "$WORKDIR/org3" "$sb/pkg/f1.py" "$sb/pkg/f2.py" "$sb/pkg/f3.py")"
    assert_fires "$SK_ORG" "$list" "$sb" missing-dir-readme \
        "no README" \
        "organization: a dir at the min-files boundary with no README fires" \
        CHECK_ORG_MIN_FILES=3
    assert_silent "$SK_ORG" "$list" "$sb" missing-dir-readme \
        "organization: the same dir one under the min-files boundary is silent" \
        CHECK_ORG_MIN_FILES=4

    # A dir with a README present is silent even over the threshold.
    new_git_sandbox sb
    : >"$sb/README.md"
    : >"$sb/LICENSE"
    : >"$sb/CHANGELOG.md"
    command mkdir -p "$sb/pkg"
    : >"$sb/pkg/README.md"
    : >"$sb/pkg/f1.py"
    : >"$sb/pkg/f2.py"
    list="$(make_list "$WORKDIR/org4" "$sb/pkg/f1.py" "$sb/pkg/f2.py")"
    assert_silent "$SK_ORG" "$list" "$sb" missing-dir-readme \
        "organization: a dir with its own README is silent" \
        CHECK_ORG_MIN_FILES=2

    # A dir deeper than CHECK_ORG_README_DEPTH is skipped.
    new_git_sandbox sb
    : >"$sb/README.md"
    : >"$sb/LICENSE"
    : >"$sb/CHANGELOG.md"
    command mkdir -p "$sb/a/b"
    : >"$sb/a/b/f1.py"
    : >"$sb/a/b/f2.py"
    list="$(make_list "$WORKDIR/org5" "$sb/a/b/f1.py" "$sb/a/b/f2.py")"
    assert_silent "$SK_ORG" "$list" "$sb" missing-dir-readme \
        "organization: a dir past the depth cap is skipped" \
        CHECK_ORG_MIN_FILES=2 CHECK_ORG_README_DEPTH=1

    # An excluded/generated tree is skipped. The exclusion glob is
    # `*/node_modules/*`, so it matches a dir NESTED under node_modules (a real
    # package dir), not the top-level node_modules dir itself — put the files a
    # level down so the excluded dir is the one being size-checked.
    new_git_sandbox sb
    : >"$sb/README.md"
    : >"$sb/LICENSE"
    : >"$sb/CHANGELOG.md"
    command mkdir -p "$sb/node_modules/pkg"
    : >"$sb/node_modules/pkg/f1.js"
    : >"$sb/node_modules/pkg/f2.js"
    list="$(make_list "$WORKDIR/org6" "$sb/node_modules/pkg/f1.js" "$sb/node_modules/pkg/f2.js")"
    assert_silent "$SK_ORG" "$list" "$sb" missing-dir-readme \
        "organization: an excluded node_modules/<pkg> tree is skipped" \
        CHECK_ORG_MIN_FILES=2
}

# --- Drive -------------------------------------------------------------------
if [ "$HAVE_PY" -eq 0 ]; then
    # With no python3>=3.11 the bash fallback is still asserted (patterns.sh
    # exists for every docs port), so the suite still runs meaningfully.
    :
fi

run_test test_staleness "check-docs-staleness: expired-date boundary, version/URL, stale-comment"
run_test test_deadlinks "check-docs-deadlinks: relative-link schemes, anchors, suspicious URL"
run_test test_examples "check-docs-examples: python/shell fences, known/in-project skips, non-md"
run_test test_missing_api "check-docs-missing-api: py/ts/go/rs/sh/rb/java documented vs not"
run_test test_organization "check-docs-organization: root docs, min-files boundary, depth/excludes"

generate_report
