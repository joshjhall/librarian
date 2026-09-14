#!/usr/bin/env bash
# Behaviour gate for bin/check-memory-baselines.sh (#1007).
#
# The guard's job is to fail a commit that would raise a frozen count in
# tests/okf-bundle.baseline — at authoring time, on the author's machine,
# rather than ~10 minutes later at pre-push where the breakage reds main for
# everyone. This suite pins that it fires on exactly the commits that would,
# and NOT on the ones that would not.
#
# WHY THE PASSING CASES ARE THE LOAD-BEARING ONES. The dangerous failure here
# is not a missed catch; it is a guard that fires on CORRECT work. Post-#991 a
# conformant memory needs no bump at all, so a guard that blocked every commit
# touching .claude/memory/ would be wrong on the common case — and a gate
# people learn to `--no-verify` past protects nothing. test_conformant_* and
# test_no_memory_* are the controls that keep the signal honest.
#
# EVERY CASE RUNS THE REAL SCRIPT IN A REAL THROWAWAY GIT REPO. The guard reads
# the INDEX (`git diff --cached`, `git checkout-index`), so a fixture that only
# writes files on disk would exercise none of its actual plumbing. Each sandbox
# gets its own bundle, its own baseline, and its own commit — nothing depends on
# what happens to be staged in the developer's checkout.
#
# bash-3.2 clean and BSD-safe per CLAUDE.md § Runtime policy.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

GUARD="$REPO_ROOT/bin/check-memory-baselines.sh"
REAL_BASH="$(command -v bash)"

# Git's hook-exported environment, scrubbed so a pre-push run stays hermetic:
# lefthook exports GIT_DIR and friends, which would point every sandbox's git
# at the REAL repo. Attached `-uVAR` form — BSD env has no long options and
# reads `--unset=VAR` as `-u nset=VAR` (#932).
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

test_suite "memory baseline pre-commit guard (#1007)"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# --- sandbox plumbing -------------------------------------------------------

# make_repo <varname> — a git repo holding a small conformant bundle and a
# baseline frozen at its observed counts. The starting state always PASSES, so
# any failure a case produces is the thing that case introduced.
make_repo() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/repo.XXXXXX")"

    command mkdir -p "$dir/.claude/memory" "$dir/tests" "$dir/bin"

    # Two pre-existing memories: one clean, one carrying a memory-missing-why
    # finding. The second is what gives the baseline a NON-ZERO entry to be
    # raised above — a baseline of all zeros could not distinguish "growth
    # above an allowance" from "any finding at all".
    conformant_memory "$dir/.claude/memory/alpha.md" alpha
    command cat >"$dir/.claude/memory/beta.md" <<'EOF'
---
name: beta
description: a pre-existing memory that lacks its why sections
type: feedback
---

Body with no why sections — this is the pre-existing debt.
EOF

    command cat >"$dir/.claude/memory/MEMORY.md" <<'EOF'
# Memory Index

- [Alpha](alpha.md) — a clean concept
- [Beta](beta.md) — pre-existing debt
EOF

    # The real gate and its scanner, referenced in place. Copying them would
    # let this suite pass against a stale duplicate while the real gate drifted.
    command cat >"$dir/tests/okf-bundle.baseline" <<'EOF'
# test baseline

memory-missing-why 1
EOF

    command git -C "$dir" init -q 2>/dev/null
    command git -C "$dir" config user.email test@example.com
    command git -C "$dir" config user.name Test
    command git -C "$dir" add -A 2>/dev/null
    command git -C "$dir" commit -qm initial 2>/dev/null

    printf -v "$__out" '%s' "$dir"
}

# conformant_memory <path> <name> — a memory the scanner has nothing to say
# about: top-level `type:` (OKF §4.1) and the body sections its type requires.
conformant_memory() {
    command cat >"$1" <<EOF
---
name: $2
description: a conformant concept for the guard fixture
type: feedback
---

Body text.

**Why:** it needs a why section to satisfy its type.

**How to apply:** as written.
EOF
}

# index_line <repo> <file> <title> — add the MEMORY.md pointer that keeps a
# memory reachable (absent => memory-orphan).
index_line() {
    command printf -- '- [%s](%s) — fixture\n' "$3" "$2" >>"$1/.claude/memory/MEMORY.md"
}

# run_guard <repo> [env assignments...] — run the REAL guard with its cwd and
# PROJECT_ROOT inside the sandbox, capturing output and status.
GUARD_OUT=""
GUARD_RC=0
run_guard() {
    local repo="$1"
    shift
    GUARD_RC=0
    # The guard resolves PROJECT_ROOT from its own location, so it is copied in
    # rather than run from the real bin/ — otherwise it would judge THIS repo.
    command cp "$GUARD" "$repo/bin/check-memory-baselines.sh"
    GUARD_OUT="$(/usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        -uBASH_ENV \
        MEMORY_BASELINE_GATE="$REPO_ROOT/tests/validate-okf-bundle.sh" \
        OKF_BUNDLE_BASELINE="$repo/tests/okf-bundle.baseline" \
        "$@" \
        "$REAL_BASH" "$repo/bin/check-memory-baselines.sh" 2>&1)" || GUARD_RC=$?
}

# run_guard_default_baseline <repo> — same, but WITHOUT OKF_BUNDLE_BASELINE, so
# the guard resolves the baseline itself. Required by the staged-baseline cases:
# the override is a literal path and would bypass the very resolution they test.
run_guard_default_baseline() {
    local repo="$1"
    shift
    GUARD_RC=0
    command cp "$GUARD" "$repo/bin/check-memory-baselines.sh"
    GUARD_OUT="$(/usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        -uBASH_ENV \
        MEMORY_BASELINE_GATE="$REPO_ROOT/tests/validate-okf-bundle.sh" \
        "$@" \
        "$REAL_BASH" "$repo/bin/check-memory-baselines.sh" 2>&1)" || GUARD_RC=$?
}

# --- AC4: the mutation, both directions -------------------------------------

# Stage a memory missing its required body sections; the guard must fire, and
# must say WHICH category and by how much (AC2). Then add the sections and the
# same commit must pass — the half that proves the guard is satisfiable.
test_missing_why_is_blocked_and_named() {
    local repo=""
    make_repo repo

    command cat >"$repo/.claude/memory/gamma.md" <<'EOF'
---
name: gamma
description: a new memory with no why sections
type: feedback
---

Body with no why sections.
EOF
    index_line "$repo" gamma.md Gamma
    command git -C "$repo" add -A 2>/dev/null

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -eq 1 ]" \
        "a staged memory that raises a baselined count is BLOCKED (exit $GUARD_RC)"
    assert_contains "$GUARD_OUT" "memory-missing-why" \
        "the diagnostic names WHICH category grew (AC2)"
    assert_contains "$GUARD_OUT" "2 > 1" \
        "the diagnostic names BY HOW MUCH — the observed count against the baseline (AC2)"
    assert_contains "$GUARD_OUT" "gamma.md" \
        "the diagnostic names the staged file, not just the corpus-wide rows"

    # THE NARROWING, pinned by its negative half. beta.md carries the same
    # memory-missing-why finding but is PRE-EXISTING debt the author did not
    # touch — on the real bundle there are 80 such rows, and printing them
    # buries the one actionable file under four screens. Asserting only that
    # gamma appears cannot catch that: a guard dumping every corpus row
    # contains gamma too, and passes. This is the assertion that fails it.
    assert_not_contains "$GUARD_OUT" "beta.md" \
        "and does NOT reprint pre-existing corpus-wide findings the author did not touch"
}

test_adding_the_why_sections_passes() {
    local repo=""
    make_repo repo

    # Byte-identical setup to the case above, except the body carries the
    # sections its type requires. That is the mutation's other direction.
    conformant_memory "$repo/.claude/memory/gamma.md" gamma
    index_line "$repo" gamma.md Gamma
    command git -C "$repo" add -A 2>/dev/null

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -eq 0 ]" \
        "the same commit passes once the file is conformant (exit $GUARD_RC) — the guard is satisfiable by FIXING, not only by bumping"
}

# --- AC3: a file that legitimately needs no bump ----------------------------

# The control. Post-#991 a conformant memory raises NOTHING, so a guard keyed on
# "did you touch .claude/memory/" would fire here — on correct work. Measured on
# the real bundle: a conformant indexed memory leaves the count at its baseline.
test_conformant_memory_needs_no_bump() {
    local repo=""
    make_repo repo

    conformant_memory "$repo/.claude/memory/delta.md" delta
    index_line "$repo" delta.md Delta
    command git -C "$repo" add -A 2>/dev/null

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -eq 0 ]" \
        "a conformant memory passes with NO baseline bump (exit $GUARD_RC) — the guard is not a blanket block on touching the bundle (AC3)"
    assert_not_contains "$GUARD_OUT" "BLOCKED" \
        "correct work produces no diagnostic at all"
}

# The baseline is genuinely reachable in this fixture — otherwise the case above
# would pass because nothing could ever fail, not because the file is clean.
# Without this, a typo'd bundle path turns every passing assertion vacuous.
test_fixture_baseline_is_actually_reachable() {
    local repo=""
    make_repo repo

    command cat >"$repo/.claude/memory/epsilon.md" <<'EOF'
---
name: epsilon
description: deliberately defective, to prove the fixture can fail
type: project
---

No why sections here either.
EOF
    index_line "$repo" epsilon.md Epsilon
    command git -C "$repo" add -A 2>/dev/null

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -ne 0 ]" \
        "the fixture CAN fail (exit $GUARD_RC) — so the passing cases above mean something"
}

# --- the orphan route -------------------------------------------------------

# Not in the issue text, found by measurement: an unindexed memory trips
# memory-orphan, an UNLISTED category whose implicit baseline is 0, so a single
# one fails. This is the likelier miss of the two — the author writes a
# conformant file and simply forgets the MEMORY.md pointer.
test_unindexed_memory_is_blocked_as_an_orphan() {
    local repo=""
    make_repo repo

    conformant_memory "$repo/.claude/memory/zeta.md" zeta
    # Deliberately NO index_line.
    command git -C "$repo" add -A 2>/dev/null

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -eq 1 ]" \
        "a conformant but unindexed memory is BLOCKED (exit $GUARD_RC)"
    assert_contains "$GUARD_OUT" "memory-orphan" \
        "the diagnostic names memory-orphan — an unlisted category, implicit baseline 0"
    assert_contains "$GUARD_OUT" "1 > 0" \
        "the unlisted category's implicit-zero baseline is shown in the delta"
}

# --- scope: the guard is free on unrelated commits --------------------------

test_commit_without_memory_changes_is_untouched() {
    local repo=""
    make_repo repo

    command mkdir -p "$repo/src"
    command printf 'print("hello")\n' >"$repo/src/app.py"
    command git -C "$repo" add -A 2>/dev/null

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -eq 0 ]" \
        "a commit touching no memory file exits 0 (exit $GUARD_RC)"
    assert_output_empty "$GUARD_OUT" \
        "and says nothing at all — the guard is silent on the majority of commits"
}

# A commit that touches the bundle AND other files is still in scope: the
# `case` prefix match must not be defeated by an unrelated path sorting first.
test_mixed_commit_is_still_in_scope() {
    local repo=""
    make_repo repo

    command mkdir -p "$repo/src"
    command printf 'print("hello")\n' >"$repo/src/app.py"
    command cat >"$repo/.claude/memory/eta.md" <<'EOF'
---
name: eta
description: defective memory alongside unrelated changes
type: feedback
---

No why sections.
EOF
    index_line "$repo" eta.md Eta
    command git -C "$repo" add -A 2>/dev/null

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -eq 1 ]" \
        "a commit mixing source and memory changes is still checked (exit $GUARD_RC)"
}

# --- the deletion route -----------------------------------------------------

# THE CASE THAT KILLED --diff-filter=ACMR. The intuitive filter admits only
# additions/copies/modifications/renames, on the reasoning that removing a file
# cannot raise a count. It can: deleting a memory without also removing its
# MEMORY.md pointer leaves the line behind as memory-dangling-index, an unlisted
# category with an implicit baseline of 0. Measured in a sandbox — with ACMR the
# guard exited 0 on precisely that commit.
#
# It is also the easiest of the three routes to hit, because deleting a file
# feels self-contained: nothing prompts you to go look at the index.
test_deletion_leaving_a_dangling_index_is_blocked() {
    local repo=""
    make_repo repo

    # Remove alpha.md but leave its MEMORY.md pointer in place.
    command git -C "$repo" rm -q "$repo/.claude/memory/alpha.md" 2>/dev/null

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -eq 1 ]" \
        "deleting a memory without removing its index line is BLOCKED (exit $GUARD_RC) — a --diff-filter=ACMR guard exits 0 here"
    assert_contains "$GUARD_OUT" "memory-dangling-index" \
        "the diagnostic names the dangling index line"
}

# The converse, so the case above is not satisfied by blocking every deletion:
# removing the pointer alongside the file is correct work and must pass.
test_deletion_with_its_index_line_removed_passes() {
    local repo=""
    make_repo repo

    command git -C "$repo" rm -q "$repo/.claude/memory/alpha.md" 2>/dev/null
    command grep -v 'alpha.md' "$repo/.claude/memory/MEMORY.md" \
        >"$repo/.claude/memory/MEMORY.md.new"
    command mv "$repo/.claude/memory/MEMORY.md.new" "$repo/.claude/memory/MEMORY.md"
    command git -C "$repo" add -A 2>/dev/null

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -eq 0 ]" \
        "removing a memory AND its index line passes (exit $GUARD_RC) — the guard blocks the defect, not the deletion"
}

# --- the staged-vs-worktree split -------------------------------------------

# THE CASE THAT JUSTIFIES `git checkout-index`. The gate enumerates from the
# INDEX but reads CONTENT from the working tree, so a memory staged broken and
# then fixed on disk reports clean while the commit carries the defect.
# Measured on the real bundle: the plain gate exits 0 here, the guard exits 1.
#
# Reverting the guard to scan the worktree turns this case red — which is what
# makes it a test of the decision rather than a restatement of it.
test_staged_content_is_judged_not_the_worktree() {
    local repo=""
    make_repo repo

    command cat >"$repo/.claude/memory/theta.md" <<'EOF'
---
name: theta
description: staged in a broken state
type: feedback
---

No why sections.
EOF
    index_line "$repo" theta.md Theta
    command git -C "$repo" add -A 2>/dev/null

    # Now fix the WORKTREE copy only — the index still holds the broken one.
    conformant_memory "$repo/.claude/memory/theta.md" theta

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -eq 1 ]" \
        "the guard judges the STAGED content, not the worktree (exit $GUARD_RC) — a worktree-scanning guard passes this and lets the defect land"
}

# The converse, so the case above cannot be satisfied by a guard that simply
# always fails: staged-clean with a broken worktree copy must PASS, because the
# broken bytes are not what the commit carries.
test_broken_worktree_with_clean_index_passes() {
    local repo=""
    make_repo repo

    conformant_memory "$repo/.claude/memory/iota.md" iota
    index_line "$repo" iota.md Iota
    command git -C "$repo" add -A 2>/dev/null

    command cat >"$repo/.claude/memory/iota.md" <<'EOF'
---
name: iota
description: broken on disk but not staged
type: feedback
---

No why sections.
EOF

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -eq 0 ]" \
        "unstaged worktree breakage does not block the commit (exit $GUARD_RC) — the guard judges what is being committed, in both directions"
}

# --- path representability --------------------------------------------------

# Plain `git diff --cached --name-only` C-QUOTES any path holding a quote, a
# tab, or a non-ASCII byte: `café.md` comes back as the literal 16-character
# string "caf\303\251.md". That matches no prefix test, so the commit reads as
# touching nothing in the bundle and the guard exits 0 on the very file being
# added — the silent-skip shape again, arriving through path quoting. `-z` emits
# raw bytes; this pins that the guard uses it.
test_non_ascii_filename_is_still_in_scope() {
    local repo=""
    make_repo repo

    command cat >"$repo/.claude/memory/café.md" <<'EOF'
---
name: cafe
description: a memory whose filename is not ASCII
type: feedback
---

Body with no why sections.
EOF
    index_line "$repo" 'café.md' Cafe
    command git -C "$repo" add -A 2>/dev/null

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -eq 1 ]" \
        "a non-ASCII memory filename is still in scope (exit $GUARD_RC)"

    # THE ASSERTION THAT ACTUALLY PINS -z. The exit code alone does NOT: this
    # commit also stages an ASCII MEMORY.md, so the scope test is satisfied by
    # that file and the gate finds the row either way — a C-quoting guard exits
    # 1 here too, for the wrong reason. Measured: reverting to plain
    # `--name-only` left this case green on the status alone.
    #
    # What the quoting actually breaks is the NARROWING lookup: STAGED_LIST
    # holds the 16-character literal "caf\303\251.md", which matches no row, so
    # the guard falls through to its "no finding sits in your staged files"
    # branch and the author is told to go re-run the full gate. The file's real
    # name appearing under the staged heading is what proves the raw bytes
    # survived.
    assert_contains "$GUARD_OUT" "In the file(s) you staged:" \
        "the staged-file narrowing resolved (a C-quoted path matches no row and falls through)"
    assert_contains "$GUARD_OUT" "café.md" \
        "and names the file by its real name, not a C-quoted escape sequence"
}

# --- path rendering in the diagnostic ---------------------------------------

# The rows must come back REPO-RELATIVE. They arrive from the gate prefixed with
# the throwaway materialization dir and INDENTED, so the prefix does not sit at
# position 0 — a bare `${row#$WORKDIR/}` strips nothing, every row stays
# absolute, and the `grep -F` lookup against staged paths then matches none of
# them. The guard silently loses its narrowing and tells the author no finding
# is in their files. Found by running the real guard under a hostile TMPDIR;
# the 16 cases before this one all ran with a clean one and stayed green.
#
# $TMPDIR carries sed metacharacters here on purpose: it is operator-controlled,
# and the strip this replaced spliced it into an `s|…|…|` delimiter, where a `|`
# breaks the command and an `&` expands to the match. Both spellings are checked
# in one case because they are one property — "the prefix is removed literally".
test_rows_render_repo_relative_under_a_hostile_tmpdir() {
    local repo="" hostile="$WORKDIR/pipe|amp&dir"
    make_repo repo
    command mkdir -p "$hostile"

    command cat >"$repo/.claude/memory/mu.md" <<'EOF'
---
name: mu
description: a memory with no why sections
type: feedback
---

Body with no why sections.
EOF
    index_line "$repo" mu.md Mu
    command git -C "$repo" add -A 2>/dev/null

    run_guard "$repo" TMPDIR="$hostile"

    assert_true "[ '$GUARD_RC' -eq 1 ]" \
        "the guard still fires under a TMPDIR holding sed metacharacters (exit $GUARD_RC)"
    assert_contains "$GUARD_OUT" ".claude/memory/mu.md" \
        "rows render repo-relative"
    assert_not_contains "$GUARD_OUT" "$hostile" \
        "the materialization prefix is stripped — not left absolute, which would defeat the staged-file lookup"
}

# --- the baseline is part of the staged tree too -----------------------------

# THE GUARD'S OWN BUG, ONE FILE OVER (found by the pre-PR review, reproduced
# before fixing). The remedy this script prints for a block is "raise the entry
# in tests/okf-bundle.baseline" — so the author edits it and re-runs `git
# commit`. If the baseline were read from DISK, a forgotten `git add` would let
# the guard see the bumped copy, exit 0, and land a commit carrying the OLD
# baseline against the new finding. Main reds at pre-push: #1007 exactly,
# arriving through the guard built to prevent it.
#
# These two cases run WITHOUT the OKF_BUNDLE_BASELINE override, because that
# override is a literal path and would bypass the resolution under test.
test_unstaged_baseline_bump_does_not_pass_the_guard() {
    local repo=""
    make_repo repo

    command cat >"$repo/.claude/memory/nu.md" <<'EOF'
---
name: nu
description: a memory with no why sections
type: feedback
---

Body with no why sections.
EOF
    index_line "$repo" nu.md Nu
    command git -C "$repo" add -A 2>/dev/null

    # Raise the allowance on DISK only — never staged.
    command printf '# test baseline\n\nmemory-missing-why 2\n' \
        >"$repo/tests/okf-bundle.baseline"

    run_guard_default_baseline "$repo"

    assert_true "[ '$GUARD_RC' -eq 1 ]" \
        "an UNSTAGED baseline bump does not satisfy the guard (exit $GUARD_RC) — the commit would carry the old baseline and red main"
}

test_staged_baseline_bump_passes() {
    local repo=""
    make_repo repo

    command cat >"$repo/.claude/memory/xi.md" <<'EOF'
---
name: xi
description: a memory with no why sections
type: feedback
---

Body with no why sections.
EOF
    index_line "$repo" xi.md Xi
    command printf '# test baseline\n\nmemory-missing-why 2\n' \
        >"$repo/tests/okf-bundle.baseline"
    command git -C "$repo" add -A 2>/dev/null

    run_guard_default_baseline "$repo"

    assert_true "[ '$GUARD_RC' -eq 0 ]" \
        "a STAGED baseline bump does satisfy it (exit $GUARD_RC) — the guard blocks the omission, not the deliberate raise"
}

# --- fail loud, never silently ----------------------------------------------

# A failing `git diff --cached` must not read as "nothing staged". A process
# substitution cannot carry the status, so the loop would see an empty stream,
# leave STAGED_MEMORY at 0, and exit 0 announcing a clean run — the silent skip
# this script's own header forbids, in the one git call that had no die().
test_a_failing_git_diff_fails_loud() {
    local repo="" out="" rc=0
    make_repo repo
    command cp "$GUARD" "$repo/bin/check-memory-baselines.sh"

    # A corrupt index makes `git diff --cached` exit non-zero for a real reason.
    command printf 'garbage' >"$repo/.git/index"

    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
        MEMORY_BASELINE_GATE="$REPO_ROOT/tests/validate-okf-bundle.sh" \
        "$REAL_BASH" "$repo/bin/check-memory-baselines.sh" 2>&1)" || rc=$?

    assert_true "[ '$rc' -eq 2 ]" \
        "a failing git diff exits 2, never 0 (exit $rc) — an unreadable index must not read as an empty one"
    assert_contains "$out" "git diff --cached failed" \
        "and names the failure rather than reporting a clean scan"
}

# The two earliest die() paths, which nothing else pins: a regression that
# guarded either with `|| true` would otherwise pass this suite.
test_absent_git_fails_loud() {
    local repo="" out="" rc=0
    make_repo repo
    command cp "$GUARD" "$repo/bin/check-memory-baselines.sh"

    # An empty PATH: `command -v git` finds nothing.
    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV PATH="/nonexistent" \
        "$REAL_BASH" "$repo/bin/check-memory-baselines.sh" 2>&1)" || rc=$?

    assert_true "[ '$rc' -eq 2 ]" \
        "an absent git exits 2 (exit $rc)"
    assert_contains "$out" "git not found" \
        "and says so"
}

test_non_git_directory_fails_loud() {
    local plain="" out="" rc=0
    plain="$(command mktemp -d "$WORKDIR/plain.XXXXXX")"
    command mkdir -p "$plain/bin"
    command cp "$GUARD" "$plain/bin/check-memory-baselines.sh"

    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
        "$REAL_BASH" "$plain/bin/check-memory-baselines.sh" 2>&1)" || rc=$?

    assert_true "[ '$rc' -eq 2 ]" \
        "a non-git directory exits 2 (exit $rc) — never a silent pass"
    assert_contains "$out" "not a git checkout" \
        "and names the reason"
}

# --- exit 1 is not one cause ------------------------------------------------

# validate-okf-bundle.sh exits 1 from THREE places: findings above the
# allowance, an unrepresentable file list (a filename containing a newline), and
# a scanner CRASH — the last two documented there as tool failures where
# "nothing was actually checked". Both reach the guard with no `exceed the
# allowance` line and no category rows, so the per-category diagnostic used to
# fall through to "the count rose elsewhere in the bundle" and then list memory
# remedies: guidance that points at prose when nothing was scanned.
#
# Still blocked (the commit must not land on an unverified bundle) — what is
# pinned here is that the REASON is named correctly.
test_a_tool_failure_is_not_reported_as_memory_findings() {
    local repo=""
    make_repo repo

    conformant_memory "$repo/.claude/memory/omicron.md" omicron
    index_line "$repo" omicron.md Omicron
    command git -C "$repo" add -A 2>/dev/null

    # A gate that fails the way the real one does when its scanner crashes.
    command cat >"$repo/tests/crash-gate.sh" <<'EOF'
#!/usr/bin/env bash
command printf 'validate-okf-bundle: scanner failed (exit 3):\n'
command printf '  patterns.sh: unresolvable version pin\n'
command printf 'The scanner reports a TOOL failure, not a dirty bundle.\n'
exit 1
EOF

    run_guard "$repo" MEMORY_BASELINE_GATE="$repo/tests/crash-gate.sh"

    assert_true "[ '$GUARD_RC' -eq 1 ]" \
        "a scanner crash still blocks the commit (exit $GUARD_RC) — an unverified bundle must not land"
    assert_contains "$GUARD_OUT" "FAILED for a tool reason" \
        "and names the cause as a tool failure"
    assert_not_contains "$GUARD_OUT" "count rose" \
        "never claiming a count rose when nothing was counted"
    assert_not_contains "$GUARD_OUT" "FIX THE FILE FIRST" \
        "and never offering memory-content remedies for a broken scanner"
}

# --- the baseline staged for deletion ---------------------------------------

# The one branch B1's fix did not initially cover: with no baseline in the
# staged tree, an earlier draft fell back to the copy on DISK while its comment
# claimed the absent case read as all-zeros — the comment stated the intent and
# the code did the opposite. Staging the ratchet's deletion would then have been
# judged against the file still sitting on the author's desk.
test_deleting_the_baseline_does_not_fall_back_to_disk() {
    local repo=""
    make_repo repo

    # beta.md already trips memory-missing-why, and the committed baseline
    # allows 1. Remove the baseline: absent reads as all-zeros, so 1 > 0 fails.
    #
    # `--cached`, NOT a plain `git rm`, and that is what makes this a test.
    # A plain `git rm` deletes the DISK copy too, so a disk-fallback has nothing
    # to find and behaves identically to no fallback — the case passes either way
    # and pins nothing (measured: the mutant survived it). Staged-for-deletion
    # while the file remains on disk is both the real-world shape and the only
    # one where the two implementations diverge.
    # ORDER MATTERS: the memory is staged FIRST, because a later `git add -A`
    # would re-add the baseline straight back from disk and silently undo the
    # staged deletion this case is about. (It did, on the first draft — the
    # assertion then failed for both implementations, which is a broken fixture
    # rather than a caught bug.) Stage the deletion last, and never with -A.
    conformant_memory "$repo/.claude/memory/pi.md" pi
    index_line "$repo" pi.md Pi
    command git -C "$repo" add -A 2>/dev/null
    command git -C "$repo" rm -q --cached "$repo/tests/okf-bundle.baseline" 2>/dev/null

    run_guard_default_baseline "$repo"

    assert_true "[ '$GUARD_RC' -eq 1 ]" \
        "deleting the baseline is judged as all-zeros, not against the disk copy (exit $GUARD_RC) — removing the ratchet must not silently widen the allowance"
}

# --- several categories at once ---------------------------------------------

# Every other blocking case stages exactly ONE defect, so the diagnostic's
# `awk '/exceed the allowance/, /^$/'` range and the per-file narrowing are only
# ever exercised against a single row. A commit tripping two categories is a
# plausible shape and exactly where a range pattern goes subtly wrong (stopping
# at the first blank line between blocks).
test_two_categories_are_both_reported() {
    local repo=""
    make_repo repo

    # One memory missing its why sections; another conformant but unindexed.
    command cat >"$repo/.claude/memory/rho.md" <<'EOF'
---
name: rho
description: a memory with no why sections
type: feedback
---

Body with no why sections.
EOF
    index_line "$repo" rho.md Rho
    conformant_memory "$repo/.claude/memory/sigma.md" sigma
    # sigma deliberately gets NO index line.
    command git -C "$repo" add -A 2>/dev/null

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -eq 1 ]" \
        "a commit tripping two categories is blocked (exit $GUARD_RC)"
    assert_contains "$GUARD_OUT" "memory-missing-why" \
        "the first category is reported"
    assert_contains "$GUARD_OUT" "memory-orphan" \
        "the second category is reported too — not truncated at the first block"
    assert_contains "$GUARD_OUT" "rho.md" \
        "and the first offending staged file is named"
    assert_contains "$GUARD_OUT" "sigma.md" \
        "as is the second"
}

# --- the whole-bundle-gone branch -------------------------------------------

# A separately-coded early exit: if the staged tree has no bundle directory at
# all, there is no corpus to judge. The single-file deletion cases above do not
# reach it — only removing every file under .claude/memory/ in one commit does.
test_deleting_the_whole_bundle_passes() {
    local repo=""
    make_repo repo

    command git -C "$repo" rm -q -r "$repo/.claude/memory" 2>/dev/null

    run_guard "$repo"

    assert_true "[ '$GUARD_RC' -eq 0 ]" \
        "removing the entire bundle in one commit exits 0 (exit $GUARD_RC) — no corpus to judge, and no way to raise a count"
}

# --- fail loud, never silently (gate paths) ---------------------------------

# A missing gate must NOT be a pass. There is no 77 here: the guard's runtime is
# git plus the in-repo gate, so absence is a broken checkout rather than an
# unavailable optional tool. Exit 0 would be indistinguishable from "clean",
# which is the #538/#571 shape this guard exists to prevent.
test_missing_gate_fails_loud() {
    local repo=""
    make_repo repo

    conformant_memory "$repo/.claude/memory/kappa.md" kappa
    index_line "$repo" kappa.md Kappa
    command git -C "$repo" add -A 2>/dev/null

    run_guard "$repo" MEMORY_BASELINE_GATE="$repo/tests/does-not-exist.sh"

    assert_true "[ '$GUARD_RC' -eq 2 ]" \
        "an absent gate exits 2, never 0 (exit $GUARD_RC) — a guard that cannot run must not report clean"
    assert_contains "$GUARD_OUT" "not found" \
        "the diagnostic says the gate is missing"
    assert_true "[ '$GUARD_RC' -ne 77 ]" \
        "and does NOT use the 77 skip sentinel — 77 is for an absent optional linter"
}

# A gate that RUNS but fails for a tool reason (not a dirty bundle) must be
# distinguished from findings, or the author is sent to edit a file that is fine.
test_broken_gate_is_distinguished_from_findings() {
    local repo=""
    make_repo repo

    conformant_memory "$repo/.claude/memory/lambda.md" lambda
    index_line "$repo" lambda.md Lambda
    command git -C "$repo" add -A 2>/dev/null

    # A gate that exits 2 the way the real one does on a bad argument.
    command printf '#!/usr/bin/env bash\nexit 2\n' >"$repo/tests/broken-gate.sh"

    run_guard "$repo" MEMORY_BASELINE_GATE="$repo/tests/broken-gate.sh"

    assert_true "[ '$GUARD_RC' -eq 2 ]" \
        "a gate that fails for a TOOL reason exits 2, not 1 (exit $GUARD_RC)"
    assert_contains "$GUARD_OUT" "did not run" \
        "and says nothing was verified, rather than blaming the bundle"
}

# --- wiring -----------------------------------------------------------------

# The guard is only a guard if a hook actually invokes it. Without this, the
# script could sit in bin/ fully tested and never run on a single commit — the
# inert-gate shape (#538/#571/#906) in its purest form.
test_lefthook_registers_the_guard() {
    local hook="$REPO_ROOT/lefthook.yml"
    assert_file_exists "$hook" "lefthook.yml exists"
    assert_file_contains "$hook" "check-memory-baselines.sh" \
        "lefthook invokes the guard — otherwise it never runs on a commit"
    assert_file_contains "$hook" ".claude/memory/\*\*" \
        "and scopes it to the memory bundle"
}

# The guard must be reachable at the path lefthook names, from the repo root.
test_guard_script_exists_and_is_runnable() {
    assert_file_exists "$GUARD" "bin/check-memory-baselines.sh exists"
    assert_true "[ -r '$GUARD' ]" "and is readable"
}

# --- dispatch ---------------------------------------------------------------

run_test test_missing_why_is_blocked_and_named \
    "a staged memory missing its why sections is blocked, with the category and delta named"
run_test test_adding_the_why_sections_passes \
    "adding the why sections makes the same commit pass"
run_test test_conformant_memory_needs_no_bump \
    "a conformant memory needs no baseline bump and is not blocked"
run_test test_fixture_baseline_is_actually_reachable \
    "the fixture can fail, so its passing cases are not vacuous"
run_test test_unindexed_memory_is_blocked_as_an_orphan \
    "an unindexed memory is blocked as an orphan (implicit baseline 0)"
run_test test_commit_without_memory_changes_is_untouched \
    "a commit touching no memory file is silently untouched"
run_test test_mixed_commit_is_still_in_scope \
    "a commit mixing source and memory changes is still checked"
run_test test_deletion_leaving_a_dangling_index_is_blocked \
    "deleting a memory without removing its index line is blocked"
run_test test_deletion_with_its_index_line_removed_passes \
    "removing a memory and its index line together passes"
run_test test_staged_content_is_judged_not_the_worktree \
    "the staged content is judged, not the worktree"
run_test test_broken_worktree_with_clean_index_passes \
    "unstaged worktree breakage does not block the commit"
run_test test_non_ascii_filename_is_still_in_scope \
    "a non-ASCII memory filename is still in scope"
run_test test_rows_render_repo_relative_under_a_hostile_tmpdir \
    "rows render repo-relative under a hostile TMPDIR"
run_test test_unstaged_baseline_bump_does_not_pass_the_guard \
    "an unstaged baseline bump does not satisfy the guard"
run_test test_staged_baseline_bump_passes \
    "a staged baseline bump does satisfy it"
run_test test_a_failing_git_diff_fails_loud \
    "a failing git diff fails loud, never reads as nothing staged"
run_test test_absent_git_fails_loud \
    "an absent git fails loud"
run_test test_non_git_directory_fails_loud \
    "a non-git directory fails loud"
run_test test_a_tool_failure_is_not_reported_as_memory_findings \
    "a tool failure is not reported as memory findings"
run_test test_deleting_the_baseline_does_not_fall_back_to_disk \
    "deleting the baseline does not fall back to the disk copy"
run_test test_two_categories_are_both_reported \
    "two simultaneously-exceeded categories are both reported"
run_test test_deleting_the_whole_bundle_passes \
    "removing the entire bundle in one commit exits 0"
run_test test_missing_gate_fails_loud \
    "an absent gate fails loud (exit 2), never passes and never skips"
run_test test_broken_gate_is_distinguished_from_findings \
    "a broken gate is distinguished from a dirty bundle"
run_test test_lefthook_registers_the_guard \
    "lefthook actually invokes the guard"
run_test test_guard_script_exists_and_is_runnable \
    "the guard script exists at the path lefthook names"

generate_report
