# shellcheck shell=bash
# Failure modes, the no-jq fallback, and registration — read-scope guard tests (issue #630).
#
# Covers AC#5 (fail open, LOUDLY, on malformed input or a missing runtime), the pure-bash fallback still enforcing when jq is absent, and AC#6 (the guard is actually registered in hooks.json).
#
# Sourced by tests/validate-read-scope-guard.sh, which defines GUARD / HOOKS_JSON
# and sources tests/lib/read-scope-guard-fixtures.sh BEFORE this file. This
# fragment only DEFINES test functions; the entry point dispatches them from its
# explicit ordered run_test list.

# --- AC#5: fail open, and LOUD ----------------------------------------------
# Fail-OPEN because a read guard that fails closed wedges every session: a golem
# that cannot read cannot work at all, and there is no alternate spelling that
# recovers. Fail-LOUD because a silent degraded-allow is indistinguishable from a
# guard that is working — which is how a control sits inert unnoticed. Both
# halves are asserted for each failure input; either alone is satisfiable by a
# broken guard.
test_parse_empty_allows() {
    local out
    out="$(printf '' | "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    assert_output_empty "$out" "empty stdin emits no deny (allow)"
}
test_parse_empty_is_loud() {
    local err
    err="$(printf '' | "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)" || true
    assert_contains "$err" "read-scope-guard" "empty stdin logs a loud diagnostic"
}
test_parse_nonjson_allows() {
    local out
    out="$(printf 'not json' | "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    assert_output_empty "$out" "non-JSON stdin allows"
}
test_no_cwd_allows_and_is_loud() {
    jq_required || return 0
    local payload out err
    payload="$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s/peer-file.txt"}}' "$PEER_DIR")"
    out="$(printf '%s' "$payload" | "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    err="$(printf '%s' "$payload" | "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)" || true
    assert_output_empty "$out" "a payload with no cwd allows (fail-open)"
    assert_contains "$err" "no cwd" "a payload with no cwd is loud"
}
test_cwd_outside_repo_allows() {
    jq_required || return 0
    run_guard "/tmp" "Read" "file_path" "$PEER_DIR/peer-file.txt"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "a cwd outside any git repo allows (fail-open)"
}

# --- The no-jq fallback still enforces --------------------------------------
# Base macOS ships no jq, so a guard that only worked with jq would be silently
# inert on a whole platform. The fallback must keep BOTH directions: still deny a
# peer read, and still allow the carve-outs. Asserting only the deny would let a
# fallback that denies everything pass.
#
# Decisions are read WITHOUT jq here — the deny envelope is checked by substring,
# since `decision()` needs jq and this whole case is about jq being gone.
test_nojq_denies_peer_read() {
    run_guard "$WT_DIR" "Read" "file_path" "$PEER_DIR/peer-file.txt" nojq
    assert_contains "$GUARD_OUT" '"permissionDecision":"deny"' \
        "no-jq path still denies a peer read"
    assert_contains "$GUARD_OUT" "$PEER_DIR" "no-jq deny reason still names the peer"
}
test_nojq_allows_own_worktree() {
    run_guard "$WT_DIR" "Read" "file_path" "$WT_DIR/seed.txt" nojq
    assert_output_empty "$GUARD_OUT" "no-jq path still allows my own worktree"
}
test_nojq_allows_status_dir() {
    run_guard "$WT_DIR" "Read" "file_path" "$STATUS_DIR/feed.jsonl" nojq
    assert_output_empty "$GUARD_OUT" "no-jq path still allows the shared .status feed"
}
test_nojq_allows_main_session() {
    run_guard "$MAIN_DIR" "Read" "file_path" "$PEER_DIR/peer-file.txt" nojq
    assert_output_empty "$GUARD_OUT" "no-jq path still allows the orchestrator"
}
test_nojq_grep_path_field_denies() {
    # The no-jq scraper reads `file_path` first and falls back to `path`; a
    # regression that dropped the second scrape would silently stop enforcing on
    # Grep/Glob — the two tools most likely to wander into a peer.
    run_guard "$WT_DIR" "Grep" "path" "$PEER_DIR" nojq
    assert_contains "$GUARD_OUT" '"permissionDecision":"deny"' \
        "no-jq path still denies a Grep whose target arrives in the path field"
}

# --- AC#6: registration + executability -------------------------------------
# Per CLAUDE.md a hook script dropped in hooks/ is NOT registered on its own —
# `claude plugin details` reports Hooks (0) and installing wires up nothing. The
# script existing is not the deliverable; the registration is.
test_hooks_registered() {
    local content
    content="$(command cat "$HOOKS_JSON")"
    assert_contains "$content" "read-scope-guard.sh" \
        "hooks.json registers the read-scope guard"
    assert_contains "$content" "Read|Grep|Glob" \
        "hooks.json matches the three read tools"
}
test_hooks_json_valid() {
    jq_required || return 0
    local out
    out="$(command cat "$HOOKS_JSON" | jq -e '.hooks.PreToolUse | length' 2>/dev/null)" || true
    assert_equals "3" "$out" "hooks.json has three PreToolUse matchers (bash, write-scope, read-scope)"
}
test_guard_executable() {
    if [ -x "$GUARD" ]; then
        assert_equals "yes" "yes" "read-scope-guard.sh is executable"
    else
        assert_equals "yes" "no" "read-scope-guard.sh must be executable"
    fi
}

# --- A redirected worktree root degrades LOUDLY, never silently -------------
# The gitdir-pointer derivation is the primary, non-poisonable source for the
# session's own root (pinned by 10-peer-deny.sh's core.worktree case). When that
# pointer is ABSENT the guard falls back to `--show-toplevel`, which a poisoned
# `core.worktree` CAN redirect — so the fallback is cross-checked against `cwd`,
# which comes from the PreToolUse payload rather than from git config: a root
# that does not contain cwd was redirected and must not be trusted.
#
# Both arms of that outcome matter, and only one is obvious. The guard ALLOWS
# either way — this is the fail-open contract, and a wedged golem is worse than a
# missed read. What the cross-check buys is the DIAGNOSTIC: without it the same
# poison yields a silent allow, indistinguishable from a guard that is working
# correctly, which is precisely how a control sits inert unnoticed. So this case
# asserts the stderr line, not the decision. Verified by mutation: removing the
# cross-check leaves every decision in this suite unchanged and fails only here.
test_redirected_root_fails_open_loudly() {
    local poisoned="$FIXTURE/redirect"
    command mkdir -p "$poisoned/elsewhere" || {
        skip_test "redirect fixture unavailable"
        return 0
    }
    git_clean -C "$poisoned" init -q 2>/dev/null || {
        skip_test "redirect fixture unavailable"
        return 0
    }
    git_clean -C "$poisoned" config user.email "test@example.com"
    git_clean -C "$poisoned" config user.name "Test"
    printf 'x\n' >"$poisoned/f"
    git_clean -C "$poisoned" add f 2>/dev/null
    git_clean -C "$poisoned" -c commit.gpgsign=false commit -qm s 2>/dev/null
    git_clean -C "$poisoned" worktree add -q -b feature/issue-61 \
        "$poisoned/.worktrees/issue-61" >/dev/null 2>&1 || {
        skip_test "redirect fixture unavailable"
        return 0
    }
    git_clean -C "$poisoned" worktree add -q -b feature/issue-62 \
        "$poisoned/.worktrees/issue-62" >/dev/null 2>&1 || {
        skip_test "redirect fixture unavailable"
        return 0
    }
    local pmain pwt ppeer gd
    pmain="$(cd "$poisoned" && pwd)"
    pwt="$pmain/.worktrees/issue-61"
    ppeer="$pmain/.worktrees/issue-62"

    # Remove the trustworthy pointer so the poisonable fallback is what runs...
    gd="$(git_clean -C "$pwt" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
    [ -n "$gd" ] && [ -f "$gd/gitdir" ] || {
        skip_test "no gitdir pointer to remove in this git"
        return 0
    }
    command rm -f "$gd/gitdir"
    # ...then redirect it somewhere that does NOT contain cwd.
    git_clean -C "$pwt" config extensions.worktreeConfig true 2>/dev/null || {
        skip_test "worktreeConfig unsupported in this git"
        return 0
    }
    git_clean -C "$pwt" config --worktree core.worktree "$pmain/elsewhere" 2>/dev/null || {
        skip_test "per-worktree config unsupported in this git"
        return 0
    }

    # ARM CHECK — without a real redirect the guard would deny for the ordinary
    # reason and this case would assert nothing.
    local top
    top="$(git_clean -C "$pwt" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ "$top" != "$pmain/elsewhere" ]; then
        skip_test "core.worktree redirect did not take here"
        return 0
    fi

    local payload err
    payload="$(printf '{"cwd":"%s","tool_name":"Read","tool_input":{"file_path":"%s/f"}}' "$pwt" "$ppeer")"
    err="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)" || true
    assert_contains "$err" "does not contain cwd" \
        "a redirected worktree root degrades LOUDLY (a silent allow here is indistinguishable from a working guard)"
}

# --- git-unavailable and root-escape: the two remaining fail-open branches ---
# Both were verified by hand during implementation and neither was pinned, which
# is the same thing as untested: a hand check does not fail CI when the branch
# regresses. They matter more here than in the sibling write guard, because
# fail-open is this guard's ENTIRE safety story — a read guard that failed closed
# would wedge every session, so every degraded path must allow, and must say so
# on stderr where an operator can see it.
#
# `nogit` strips git from PATH the same way `nojq` strips jq — see the shared
# builder in tests/lib/read-scope-guard-fixtures.sh, which gives each mode its
# OWN stub dir so a leftover symlink cannot make this test silently exercise the
# git-PRESENT path.
test_no_git_allows_and_is_loud() {
    # Arm check FIRST: prove git really is hidden. Without this the case passes
    # whenever the stub accidentally resolves git — asserting nothing while
    # looking green ("shimmed PATH didn't hide the tool").
    local stub="$FIXTURE/armcheck-nogit"
    command mkdir -p "$stub"
    command ln -sf "$REAL_BASH" "$stub/bash"
    if /usr/bin/env -i PATH="$stub" "$REAL_BASH" -c 'command -v git' >/dev/null 2>&1; then
        skip_test "git still resolves under a stripped PATH here — cannot test its absence"
        return 0
    fi

    # A payload that WOULD be denied with git present (cwd in a worktree, target
    # in a peer), so an allow here is attributable to git's absence and not to
    # the target being innocuous.
    run_guard "$WT_DIR" "Read" "file_path" "$PEER_DIR/peer-file.txt" nogit
    assert_output_empty "$GUARD_OUT" \
        "with git unavailable the guard ALLOWS (fail-open) — a read guard that failed closed would wedge every session"

    local payload err
    payload="$(printf '{"cwd":"%s","tool_name":"Read","tool_input":{"file_path":"%s/peer-file.txt"}}' \
        "$WT_DIR" "$PEER_DIR")"
    err="$(printf '%s' "$payload" |
        /usr/bin/env -i PATH="$stub" "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)" || true
    assert_contains "$err" "git unavailable" \
        "...and says so LOUDLY, so a degraded guard is distinguishable from a working one"
}

# A `..` chain that would pop past `/` is a malformed absolute path the guard
# cannot scope, so it fails open loudly rather than guessing. Pinned because the
# normalization loop's `_bad` arm is otherwise unreachable from every other case
# in this suite.
test_root_escaping_target_allows_and_is_loud() {
    jq_required || return 0
    run_guard "$WT_DIR" "Read" "file_path" "/../../../etc/passwd"
    assert_equals "allow" "$(decision "$GUARD_OUT")" \
        "a target escaping the filesystem root allows (fail-open)"

    local payload err
    payload="$(printf '{"cwd":"%s","tool_name":"Read","tool_input":{"file_path":"/../../../etc/passwd"}}' "$WT_DIR")"
    err="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)" || true
    assert_contains "$err" "escapes the filesystem root" \
        "...and is loud about why it could not scope the path"
}

# --- A RELATIVE target with no cwd must fail open LOUDLY, not join onto `/` --
# The relative-join fix anchors a relative target on `cwd` only when `cwd` is
# non-empty, deliberately leaving it unjoined so the later `[ -z "$cwd" ]` check
# catches it and fails open loudly. `test_no_cwd_allows_and_is_loud` above uses
# an ABSOLUTE target, so it never enters the join branch at all.
#
# What this pins is the OBSERVABLE CONTRACT (allow + the loud `no cwd` line) for
# a shape no other case covers, not the `[ -n "$cwd" ]` guard itself. Measured
# honestly: removing that guard is a NO-OP — the join happens before the
# `[ -z "$cwd" ]` check, so an unconditional join and a skipped one both reach
# the same fail-open+loud path with byte-identical output. The `[ -n ]` test is
# defensive, not load-bearing, and this comment says so rather than claiming a
# mutation it cannot catch. (Recorded because the first draft of this comment
# DID claim that, and the mutation round showed otherwise.)
test_relative_target_no_cwd_allows_and_is_loud() {
    jq_required || return 0
    local payload out err
    payload='{"tool_name":"Read","tool_input":{"file_path":"peer-file.txt"}}'
    out="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    err="$(printf '%s' "$payload" |
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)" || true
    assert_output_empty "$out" \
        "a RELATIVE target with no cwd allows (fail-open), rather than being joined onto nothing"
    assert_contains "$err" "no cwd" \
        "...and reaches the loud no-cwd diagnostic, not a silent scope against the filesystem root"
}

# --- The no-jq deny reason sanitizer is UNREACHABLE, and that is the finding --
# Review asked for a case driving a quote/backslash path through `_emit_deny`'s
# hand-rolled JSON escaping, since every fixture path here is `mktemp`-clean and
# that sanitizer has therefore never run. Attempted, then measured — and the
# result is more useful than the test would have been:
#
# The no-jq path CANNOT deliver such a reason. Its `sed` scraper takes the
# shortest span to the first unescaped quote, so a target containing `"` is
# TRUNCATED before the quote ever reaches the reason string (verified: a
# `.../we"ird/f.txt` target scrapes to `.../we\`). The jq path, which handles the
# exact bytes, never calls the hand-roll. So the two sanitizing expansions are
# dead code on every reachable input: removing them entirely leaves the whole
# suite green, and a test asserting valid JSON for a quoted path passes with AND
# without the sanitizer — a tautology.
#
# Recorded rather than tested, because writing the test would have added a green
# assertion that cannot fail and implied coverage that does not exist. The
# sanitizer stays as defense in depth for a future caller that reaches
# `_emit_deny` with unsanitized bytes; it is deliberately unpinned, and this note
# is why. (Measured 2026-09-05 against the no-jq scraper's truncation behavior.)

# --- No-jq truncation at an escaped quote must fail LOUD, not allow silently --
# The no-jq scrapes take the shortest span to the first `"`, so a path holding an
# escaped quote is cut short. An earlier draft called this an accepted gap,
# reasoning that "truncation only shortens, and a peer path cannot shorten into
# an own-tree prefix match". True for a quote AFTER the peer prefix — and FALSE
# for one before it, which was never measured.
#
# Reproduced: a target `…/issue-6\"36/CLAUDE.md` scrapes to `…/issue-6`, a
# sibling that is not a real worktree, so the structural peer check ALLOWED it
# with no diagnostic at all. A silent allow is the single outcome this guard must
# never produce — it is indistinguishable from a working guard.
#
# The raw payload still carries the evidence, so the no-jq path now refuses a
# payload containing an escaped quote and fails open LOUDLY instead of scoping a
# value it knows may be wrong. jq (present in every normal deployment) decodes
# such a value exactly and never reaches this branch.
test_nojq_escaped_quote_fails_open_loudly() {
    local payload out err
    # cwd is CLEAN and resolvable; only the TARGET carries the escaped quote, so
    # any allow here is attributable to the truncation rather than to an
    # unresolvable cwd (which has its own, already-tested loud path).
    payload="$(printf '{"cwd":"%s","tool_name":"Read","tool_input":{"file_path":"%s/issue-6\\\\"36/x.txt"}}' \
        "$WT_DIR" "$WT_PARENT")"
    local stub="$FIXTURE/stub-bin-nojq"
    command mkdir -p "$stub"
    command ln -sf "$REAL_BASH" "$stub/bash"
    command ln -sf "$REAL_GIT" "$stub/git"
    out="$(printf '%s' "$payload" | /usr/bin/env -i PATH="$stub" "$REAL_BASH" "$GUARD" 2>/dev/null)" || true
    err="$(printf '%s' "$payload" | /usr/bin/env -i PATH="$stub" "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)" || true
    assert_output_empty "$out" \
        "a no-jq payload with an escaped quote emits no deny (fail-open, per the read-guard contract)"
    assert_contains "$err" "escaped quote" \
        "...and is LOUD about it — the truncated target must not be scoped silently"
}
