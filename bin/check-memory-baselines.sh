#!/usr/bin/env bash
# Pre-commit guard: a memory addition must not red the OKF bundle gate (#1007).
#
# Adding a file under .claude/memory/ can raise a frozen per-category count in
# tests/okf-bundle.baseline. When the author does not also fix the file (or, as
# a last resort, raise the entry), MAIN GOES RED AND STAYS RED — the pre-push
# hook then blocks EVERY branch in the repo, not just the offender's.
#
# This happened TWICE on 2026-09-10, from two different authors four hours
# apart (6c2ad75, then 907395b / PR #1001). The second is the instructive one:
# 36556d9, one commit earlier on that very branch, is the memory documenting
# that the bump is required. Prose in the repo did not prevent the repo's own
# author from missing it one commit later, which is the argument for a gate.
#
# ---------------------------------------------------------------------------
# WHY THIS RUNS THE GATE INSTEAD OF DIFFING THE BASELINE FILES
# ---------------------------------------------------------------------------
#
# The obvious guard — "you staged a memory, did you also stage a baseline?" —
# is WRONG, and measurably so. #991 migrated the bundle to top-level `type:`,
# which cleared okf-missing-type out of the baseline entirely. Measured on this
# tree: a conformant, indexed memory added to the bundle yields 80 findings
# against an 80 baseline and exits 0 — it needs NO bump at all. A staged-pair
# check would therefore fire on CORRECT work, and a guard that cries wolf on
# the common case is a guard people learn to bypass.
#
# Running the real gate against the staged tree has three properties the
# file-diff heuristic cannot get:
#
#   1. it fires on exactly the commits that WOULD red main, and no others;
#   2. it names the category and the N > M delta for free, because that is the
#      gate's own diagnostic — no second copy of the rule to drift;
#   3. a conformant file genuinely passes, so the signal stays trustworthy.
#
# ---------------------------------------------------------------------------
# WHY THE STAGED TREE IS MATERIALIZED RATHER THAN SCANNED IN PLACE
# ---------------------------------------------------------------------------
#
# The gate enumerates with `git ls-files` — which reads the INDEX — but the
# scanner then reads each file's CONTENT from the working tree. Those are not
# the same tree, and the gap is reachable: measured, a memory staged in a
# broken state and then FIXED in the worktree reports clean, while the commit
# that lands carries the defect. That is the silence-reads-as-a-pass shape
# (#538/#571) arriving through the plumbing of the check meant to prevent it.
#
# `git checkout-index` materializes exactly what is about to be committed, so
# the guard judges the commit rather than the desk it was written on.
#
# ---------------------------------------------------------------------------
# FAIL LOUD, NEVER SKIP
# ---------------------------------------------------------------------------
#
# There is no 77 sentinel here. Per CLAUDE.md, 77 means "this gate's optional
# LINTER is absent" (ruff, shellcheck). This guard's runtime is git + bash +
# the in-repo gate; their absence is a broken checkout, not an unavailable
# optional tool. A guard that exited 0 when it could not run would be
# indistinguishable from a pass — which is the entire failure class above.
#
# The guard never prints memory CONTENT: it forwards the gate's
# file/line/category rows, whose evidence column is already dropped upstream.
#
# bash-3.2 clean and BSD-safe (no declare -A / mapfile / namerefs / ${v,,},
# no \s \w, no grep -P, no GNU-only env/realpath/mktemp flags) — macOS ships
# bash 3.2 and BSD userland. See CLAUDE.md § Runtime policy.
#
# Usage:
#   bash bin/check-memory-baselines.sh        check the staged tree
#
#   Exit 0  nothing staged under the bundle, or the staged bundle is clean.
#   Exit 1  the staged tree would raise a baselined count (with a diagnostic).
#   Exit 2  the guard could not run (missing git, gate, or a failed scan).

set -uo pipefail

BIN_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(command dirname "$BIN_DIR")"

# Overridable so the meta-test can exercise the missing-gate branch without
# uninstalling anything.
GATE="${MEMORY_BASELINE_GATE:-$PROJECT_ROOT/tests/validate-okf-bundle.sh}"

# The bundle path RELATIVE TO THE REPO ROOT. The guard resolves it inside the
# materialized staged tree, so this is a path fragment, not a location on disk.
BUNDLE_REL="${MEMORY_BUNDLE_REL:-.claude/memory}"

# The baseline path, RELATIVE TO THE REPO ROOT — resolved inside the
# materialized staged tree below, for the same reason the bundle is.
#
# THE BASELINE IS PART OF THE STAGED TREE TOO, and reading it from disk is this
# guard's own bug reintroduced one file over. The documented remedy for a block
# is "raise the entry in tests/okf-bundle.baseline" — so the author edits it,
# re-runs `git commit`, and if they forgot to `git add` it the guard reads the
# bumped DISK copy, exits 0, and the commit lands carrying the OLD baseline
# against the new finding. Main then reds at pre-push: precisely #1007, arriving
# through the guard built to prevent it. Measured both directions before the fix
# (unstaged bump => false pass; staged bump reverted on disk => false block).
#
# $OKF_BUNDLE_BASELINE still overrides with a LITERAL path — the meta-test points
# it at a sandbox file that is not in any index, so the override cannot be
# re-rooted without breaking every case that uses it.
BASELINE_REL="${MEMORY_BASELINE_REL:-tests/okf-bundle.baseline}"

die() {
    command printf 'check-memory-baselines: %s\n' "$1" >&2
    shift
    while [ "$#" -gt 0 ]; do
        command printf '  %s\n' "$1" >&2
        shift
    done
    exit 2
}

command -v git >/dev/null 2>&1 ||
    die 'git not found — cannot inspect the staged tree.' \
        'This guard protects the OKF bundle baseline; it must not pass silently.'

command git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1 ||
    die "not a git checkout: $PROJECT_ROOT" \
        'The guard reads the index; without one there is nothing to judge.'

# --- is any memory file staged? ---------------------------------------------
#
# -z because a path holding a quote, a tab, or a non-ASCII byte comes back
# C-QUOTED otherwise (`café.md` as the literal 20-char `"caf\303\251.md"`),
# which matches no prefix test and would silently drop the very file being
# added. Same reasoning, and the same measured failure, as the gate's own
# ls-files handling.
#
# NO --diff-filter AT ALL, and the omission is deliberate. The obvious spelling
# is ACMR — additions, copies, modifications, renames — on the reasoning that a
# DELETION cannot raise a count. Measured in a sandbox: it can. Removing a
# memory without also removing its MEMORY.md pointer leaves the index line
# behind, which is memory-dangling-index — an unlisted category, implicit
# baseline 0, so one is enough to red main. With ACMR the guard exits 0 on
# exactly that commit.
#
# It is also the EASIEST of the three to hit, because deleting a file feels
# self-contained in a way that adding one does not: nothing prompts you to go
# look at the index. So the filter is dropped and every staged bundle path puts
# the commit in scope; the gate then decides, which is the whole design here.
#
# The paths are KEPT, not just counted. The gate reports every finding in the
# corpus, and this bundle carries 80 pre-existing memory-missing-why rows that
# are someone else's debt (#631 is driving them down). Printing all of them
# buries the one file the author actually touched under four screens of noise
# — which is "something is wrong" again, the thing AC2 asks this guard not to
# be. The staged set is what makes the diagnostic actionable.
#
# THE DIFF'S EXIT STATUS IS CHECKED, and a process substitution cannot carry it:
# `done < <(git …)` leaves the loop reading an empty stream when git fails, so a
# corrupt index or a resource failure would set STAGED_MEMORY=0 and the guard
# would exit 0 announcing "nothing to check". That is the silent skip this
# script's own header forbids, in the one git call that had no die() around it.
# Run it to a file first so the status is git's own, and keep stderr for the
# diagnostic rather than discarding it.
# ONE trap for both temporaries. A second `trap … EXIT` later in the file would
# REPLACE this handler rather than add to it (bash keeps one per signal), so the
# earlier temp would leak on every run — the reason both paths are cleaned here.
STAGED_RAW="$(command mktemp)" ||
    die 'mktemp failed — cannot read the staged file list.'
WORKDIR=""
cleanup() {
    command rm -f "$STAGED_RAW" "$STAGED_RAW.err"
    [ -n "$WORKDIR" ] && command rm -rf "$WORKDIR"
    return 0
}
trap cleanup EXIT

command git -C "$PROJECT_ROOT" diff --cached --name-only -z \
    >"$STAGED_RAW" 2>"$STAGED_RAW.err" ||
    die "git diff --cached failed (exit $?):" \
        "$(command sed 's/^/  /' <"$STAGED_RAW.err" 2>/dev/null)" \
        'Refusing to read a failed diff as "nothing staged".'

STAGED_MEMORY=0
STAGED_LIST=""
while IFS= read -r -d '' path; do
    [ -n "$path" ] || continue
    case "$path" in
        "$BUNDLE_REL"/*)
            STAGED_MEMORY=1
            STAGED_LIST="$STAGED_LIST$path
"
            ;;
    esac
done <"$STAGED_RAW"

# Nothing in the bundle — the overwhelming majority of commits. Cost so far is
# one `git diff --cached`, so the guard is effectively free on them.
if [ "$STAGED_MEMORY" -eq 0 ]; then
    exit 0
fi

[ -f "$GATE" ] ||
    die "OKF bundle gate not found at $GATE" \
        'Without it nothing verified the staged bundle. Refusing to pass.'

# --- materialize the staged tree --------------------------------------------

WORKDIR="$(command mktemp -d)" ||
    die 'mktemp failed — cannot materialize the staged tree.'

# `-a` writes every tracked path, not just the staged ones: the bundle's graph
# health is a WHOLE-CORPUS property. memory-orphan asks whether a file is
# reachable from MEMORY.md, and memory-dangling-index asks the converse — both
# unanswerable from the changed files alone. A partial materialization would
# report every untouched memory as an orphan and bury the real row.
command git -C "$PROJECT_ROOT" checkout-index -a --prefix="$WORKDIR/" \
    >/dev/null 2>&1 ||
    die 'git checkout-index failed — cannot materialize the staged tree.' \
        'Refusing to report on a tree that was never built.'

STAGED_BUNDLE="$WORKDIR/$BUNDLE_REL"

# Resolve the baseline against the SAME materialized tree, so the bundle and the
# allowance it is judged against come from one consistent snapshot — the commit.
# An explicit $OKF_BUNDLE_BASELINE wins as a literal path (see BASELINE_REL).
if [ -n "${OKF_BUNDLE_BASELINE:-}" ]; then
    BASELINE="$OKF_BUNDLE_BASELINE"
else
    # NO DISK FALLBACK. An earlier draft fell back to $PROJECT_ROOT when the
    # staged tree held no baseline, with a comment claiming the absent case was
    # read as all-zeros — the comment described the intent and the code did the
    # opposite, which is B1's own defect surviving in the one branch B1's fix did
    # not cover. Staging the baseline's DELETION would have been judged against
    # the copy still on disk.
    #
    # The path is passed through unconditionally instead: the gate treats a
    # missing baseline as all-zeros, and that is the TIGHTER reading — removing
    # the ratchet must fail loudly, never silently widen the allowance to
    # whatever the desk happens to hold.
    BASELINE="$WORKDIR/$BASELINE_REL"
fi

# The bundle is staged-for-DELETION down to nothing, or was never tracked.
# Either way there is no corpus to judge and no way to raise a count.
if [ ! -d "$STAGED_BUNDLE" ]; then
    exit 0
fi

# --- run the real gate against it -------------------------------------------
#
# The materialized tree is NOT a git checkout, so the gate takes its `find`
# fallback and scans exactly what was planted — which is the point: `ls-files`
# there would consult the enclosing repo's index and re-introduce the
# index-vs-worktree split this materialization exists to close.
GATE_OUT=""
GATE_RC=0
GATE_OUT="$(OKF_BUNDLE_ROOT="$STAGED_BUNDLE" \
    OKF_BUNDLE_BASELINE="$BASELINE" \
    command bash "$GATE" 2>&1)" || GATE_RC=$?

if [ "$GATE_RC" -eq 0 ]; then
    exit 0
fi

# Anything but 0 or 1 (2, or the 77 sentinel for an absent scanner) means the
# gate never ran. Conflating that with findings would report a dirty bundle when
# the real problem is a broken tool, sending the author to edit a file that is
# fine.
#
# BUT EXIT 1 IS NOT ONE CAUSE, and an earlier draft of this comment asserted it
# was. tests/validate-okf-bundle.sh exits 1 from THREE places: findings above the
# allowance (the case below), a bundle filename containing a newline (an
# unrepresentable file list), and a scanner CRASH — and it documents the last two
# as tool failures where "nothing was actually checked". Both of those arrive
# here with no `exceed the allowance` line and no category rows, so the
# per-category diagnostic below fell through to "the count rose elsewhere in the
# bundle" and then listed memory-content remedies. Measured against a crashing
# gate: actively wrong guidance, pointing at memory prose when nothing was
# scanned. The commit was still blocked, so this misdirects rather than
# mis-permits — but a diagnostic that names the wrong cause is how an author
# spends an hour on the wrong file, which is most of what #1007 cost.
#
# Keyed off the gate's OWN tool-failure phrases rather than re-deriving the
# conditions, for the same reason the rows below are forwarded rather than
# recomputed.
if [ "$GATE_RC" -ne 1 ]; then
    command printf 'check-memory-baselines: the OKF bundle gate did not run (exit %s).\n' \
        "$GATE_RC" >&2
    command printf '%s\n' "$GATE_OUT" >&2
    command printf '\nNothing was verified — this is a broken gate, not a clean bundle.\n' >&2
    exit 2
fi

case "$GATE_OUT" in
    *'scanner failed (exit'* | *'file-list line(s)'*)
        command printf '\n' >&2
        command printf 'check-memory-baselines: the OKF bundle gate FAILED for a tool reason,\n' >&2
        command printf 'not because of your memory content. Nothing was actually checked:\n\n' >&2
        command printf '%s\n' "$GATE_OUT" >&2
        command printf '\nFix the tool (or the unrepresentable filename) — editing a memory\n' >&2
        command printf 'file will not clear this.\n\n' >&2
        exit 1
        ;;
esac

# --- the diagnostic ---------------------------------------------------------
#
# Forward the gate's OWN violation lines and location rows rather than
# re-deriving them: a second copy of the rule is a second thing to drift, and
# the gate already formats both. Its rows are file/line/category with the
# evidence column dropped upstream, so no memory content reaches this output.
command printf '\n' >&2
command printf 'BLOCKED: this commit adds or changes a memory file that would red the\n' >&2
command printf 'OKF bundle gate — and that reds MAIN for everyone, not just you (#1007).\n' >&2
command printf '\n' >&2

command printf '%s\n' "$GATE_OUT" |
    command awk '/exceed the allowance/, /^$/' |
    command grep -v 'exceed the allowance' |
    command grep -v '^[[:space:]]*$' >&2

command printf '\n' >&2

# Rows for the files THIS commit stages, which is what the author can act on.
# The corpus-wide rows stay in the gate's own output (`tests/validate-okf-bundle.sh`)
# rather than being reprinted here.
# THE PREFIX STRIP IS PURE BASH, NOT sed, for the reason validate-okf-bundle.sh
# records at length about its own path handling: `sed "s|$WORKDIR/||"` splices a
# value into the DELIMITER position, and $WORKDIR comes from `mktemp -d` under
# an operator-controlled $TMPDIR. A `|` there breaks the s-command outright; `&`
# and `\` have their own meanings on the replacement side. `${line#"$WORKDIR"/}`
# is a literal prefix strip with no metacharacters at all, so the class cannot
# recur — and the quotes inside the expansion keep it literal rather than a glob.
# The gate INDENTS its location rows, so the absolute prefix does not sit at
# position 0 — a bare `${row#"$WORKDIR"/}` matches nothing and every row stays
# absolute, which then defeats the `grep -F` lookup below against repo-relative
# staged paths. (The sed this replaced hid that by substituting anywhere in the
# line.) Strip the leading whitespace first, then the prefix.
ALL_ROWS=""
while IFS= read -r row; do
    [ -n "$row" ] || continue
    while :; do
        case "$row" in
            ' '* | '	'*) row="${row#?}" ;;
            *) break ;;
        esac
    done
    ALL_ROWS="$ALL_ROWS${row#"$WORKDIR"/}
"
done <<EOF
$(command printf '%s\n' "$GATE_OUT" | command grep -E '	(memory|okf)-')
EOF

YOURS=""
while IFS= read -r staged; do
    [ -n "$staged" ] || continue
    match="$(command printf '%s\n' "$ALL_ROWS" | command grep -F "$staged	")" || true
    [ -n "$match" ] || continue
    YOURS="$YOURS$match
"
done <<EOF
$STAGED_LIST
EOF

if [ -n "$YOURS" ]; then
    command printf 'In the file(s) you staged:\n' >&2
    command printf '%s' "$YOURS" | command sed 's|^|  |' >&2
else
    # The raised count came from elsewhere in the bundle — most often a staged
    # MEMORY.md edit that orphaned or dangled a file it no longer points at.
    # Say so rather than printing nothing, which would read as "no reason".
    command printf 'No finding sits in the file(s) you staged — the count rose\n' >&2
    command printf 'elsewhere in the bundle. A staged MEMORY.md edit can do this by\n' >&2
    command printf 'orphaning a memory it no longer points at. Full rows:\n' >&2
    command printf '\n' >&2
    command printf '  bash tests/validate-okf-bundle.sh\n' >&2
fi

command printf '\n' >&2
command printf 'FIX THE FILE FIRST — raising a baseline entry is the last resort:\n' >&2
command printf '\n' >&2
command printf '  memory-missing-why    the body of a `feedback` or `project` memory must\n' >&2
command printf '                        carry **Why:** and **How to apply:** lines. Two\n' >&2
command printf '                        lines of prose, and the count stays where it is.\n' >&2
command printf '  memory-orphan         the file is not reachable from MEMORY.md. Add its\n' >&2
command printf '                        one-line pointer: - [Title](file.md) — hook\n' >&2
command printf '  memory-dangling-index an index line points at a file that is not there\n' >&2
command printf '                        (a rename or delete that left its pointer behind).\n' >&2
command printf '  okf-*                 a frontmatter defect. `type:` goes at the TOP\n' >&2
command printf '                        LEVEL, never nested under `metadata:`.\n' >&2
command printf '\n' >&2
command printf 'Re-run after fixing (the guard reads the INDEX, so stage first):\n' >&2
command printf '\n' >&2
command printf '  git add -A %s && bash bin/check-memory-baselines.sh\n' "$BUNDLE_REL" >&2
command printf '\n' >&2
command printf 'If the growth is genuinely deliberate, raise the entry in\n' >&2
command printf '%s\n' "$BASELINE" >&2
command printf 'and say why in the commit message — it is a reviewable diff on purpose.\n' >&2
command printf '\n' >&2

exit 1
