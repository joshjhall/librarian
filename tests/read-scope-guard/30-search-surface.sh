# shellcheck shell=bash
# Search-surface exclusion — read-scope guard tests (issue #630, AC#4).
#
# The guard catches DELIBERATE peer reads. This fragment covers the ACCIDENTAL ones: a repo-rooted search issued from a golem worktree must return no matches from peer worktrees, because the worktree root is excluded from the search surface by `.gitignore`.
#
# Sourced by tests/validate-read-scope-guard.sh, which defines GUARD / HOOKS_JSON
# and sources tests/lib/read-scope-guard-fixtures.sh BEFORE this file. This
# fragment only DEFINES test functions; the entry point dispatches them from its
# explicit ordered run_test list.
#
# WHY THIS IS A TEST AND NOT A NEW MECHANISM. Measured before implementing: the
# repo already carries `.worktrees/` and `.claude/worktrees/` in `.gitignore`,
# and the gitignore-honoring searchers used here (the Grep tool's ugrep, and
# ripgrep) already skip peers — a planted peer file did NOT match while a
# same-term file outside the worktree dir DID. So the accidental vector is
# already closed; what it lacked was anything pinning it. An exclusion nobody
# tests is one `.gitignore` edit away from silently reopening, and the reopening
# is invisible: searches keep working, they just quietly return peer hits again.
#
# THE FIXTURE MUST DISTINGUISH "EXCLUDED" FROM "NO MATCH ANYWHERE" — AC#4 says so
# explicitly, and it is the tautology this suite would otherwise ship: a test
# that only asserts "no peer hit" passes just as well when the search is broken,
# the term is misspelled, or the searcher is absent. So the same term is planted
# BOTH inside a peer worktree AND outside the worktree dir, and both halves are
# asserted: the outside hit must be PRESENT (the search works and the term
# matches) and the peer hit ABSENT (the exclusion is what removed it).

# --- Helper: the gitignore-honoring searcher, or "" if none is available ----
# ripgrep is the searcher used here because it honors `.gitignore` the same way
# the Grep tool's ugrep does. `--hidden` is REQUIRED and is the subtle half: the
# default worktree dir `.worktrees` is a DOT directory, which rg skips by default
# for being hidden. Without `--hidden` the peer would be absent for the wrong
# reason and the test would pass with the `.gitignore` entry deleted — a green
# assertion proving nothing. Forcing `--hidden` makes the gitignore entry the
# ONLY thing excluding the peer, which is exactly the property under test.
_ss_rg() {
    command -v rg >/dev/null 2>&1 || return 1
    command rg -l --hidden "$@" 2>/dev/null
    return 0
}

# --- Build the fixture: same term inside a peer AND outside the worktree dir -
# Built here rather than in the shared fixtures file because it is the only area
# that needs it (the shared library must not accrete single-use code).
# _ss_fixture <tag> — build under a per-caller root. The tag is REQUIRED, not
# defaulted: two cases need this fixture and one of them MUTATES it (deleting the
# .gitignore entry), so a shared root would make the second build land on an
# already-initialized repo, fail at `git init`/`commit`, and SKIP — silently
# retiring the very leak fixture that stops the pair above being vacuous.
_ss_fixture() {
    SS_ROOT="$FIXTURE/searchsurface-$1"
    command mkdir -p "$SS_ROOT" || return 1
    git_clean -C "$SS_ROOT" init -q 2>/dev/null || return 1
    git_clean -C "$SS_ROOT" config user.email "test@example.com"
    git_clean -C "$SS_ROOT" config user.name "Test"
    printf '.worktrees/\n' >"$SS_ROOT/.gitignore" || return 1
    # The "term exists outside the worktree dir" anchor.
    printf 'READSCOPE_PLANTED_TERM\n' >"$SS_ROOT/tracked.txt" || return 1
    git_clean -C "$SS_ROOT" add -A 2>/dev/null || return 1
    git_clean -C "$SS_ROOT" -c commit.gpgsign=false commit -qm seed 2>/dev/null || return 1
    git_clean -C "$SS_ROOT" worktree add -q -b feature/issue-91 \
        "$SS_ROOT/.worktrees/issue-91" >/dev/null 2>&1 || return 1
    git_clean -C "$SS_ROOT" worktree add -q -b feature/issue-92 \
        "$SS_ROOT/.worktrees/issue-92" >/dev/null 2>&1 || return 1
    # The planted PEER hit — the same term, inside a peer worktree.
    printf 'READSCOPE_PLANTED_TERM\n' >"$SS_ROOT/.worktrees/issue-92/peer-only.txt" || return 1
    SS_ROOT="$(cd "$SS_ROOT" && pwd)"
    SS_WT="$SS_ROOT/.worktrees/issue-91"
    SS_PEER="$SS_ROOT/.worktrees/issue-92"
    return 0
}

# --- AC#4: a repo-rooted search from a golem returns no peer matches --------
test_search_surface_excludes_peer() {
    if ! command -v rg >/dev/null 2>&1; then
        skip_test "rg unavailable"
        return 0
    fi
    if ! _ss_fixture excludes; then
        skip_test "search-surface fixture unavailable"
        return 0
    fi
    local hits
    hits="$(cd "$SS_WT" && _ss_rg READSCOPE_PLANTED_TERM "$SS_ROOT")"
    # BOTH halves, or this proves nothing (see the header).
    assert_contains "$hits" "$SS_ROOT/tracked.txt" \
        "the planted term IS findable outside the worktree dir (search works; not a vacuous pass)"
    assert_not_contains "$hits" "$SS_PEER/peer-only.txt" \
        "a repo-rooted search from a golem worktree returns NO peer-worktree matches (#630 AC#4)"
}

# --- The `.gitignore` entry is what does the excluding -----------------------
# The assertion above is only meaningful if the exclusion has teeth. Delete the
# ignore entry and re-run: the peer hit must REAPPEAR. Without this arm the pair
# above would stay green if the peer file vanished, the term were misspelled, or
# rg silently stopped descending — the "absence assertion needs a leak fixture"
# failure this repo has shipped before. This is the leak fixture.
test_search_surface_exclusion_has_teeth() {
    if ! command -v rg >/dev/null 2>&1; then
        skip_test "rg unavailable"
        return 0
    fi
    if ! _ss_fixture teeth; then
        skip_test "search-surface fixture unavailable"
        return 0
    fi
    : >"$SS_ROOT/.gitignore" # remove the worktree-root exclusion
    local hits
    hits="$(cd "$SS_WT" && _ss_rg READSCOPE_PLANTED_TERM "$SS_ROOT")"
    assert_contains "$hits" "$SS_PEER/peer-only.txt" \
        "with the .gitignore entry removed the peer hit REAPPEARS — the exclusion, not luck, is what removes it"
}

# --- The real repo carries the entries the exclusion depends on -------------
# The fixture proves the MECHANISM works; this proves THIS repo is wired to it.
# Both spellings are required: `.worktrees/` is today's default and
# `.claude/worktrees/` is where #626 moves it, so the exclusion survives that
# migration in whichever order the two land.
test_repo_gitignore_excludes_worktree_roots() {
    local gi="$REPO_ROOT/.gitignore"
    if [ ! -f "$gi" ]; then
        skip_test ".gitignore not found"
        return 0
    fi
    local content
    content="$(command cat "$gi")"
    assert_contains "$content" ".worktrees/" \
        ".gitignore excludes the default worktree root from the search surface"
    assert_contains "$content" ".claude/worktrees/" \
        ".gitignore excludes the #626 worktree root too (survives the migration)"
}
