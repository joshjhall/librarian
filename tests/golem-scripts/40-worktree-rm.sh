# shellcheck shell=bash
# worktree-rm.sh — golem helper-script tests (issue #564 split).
#
# Covers teardown, dirty-tree refusal, core.worktree repair, and the tmux kill-session outcome classifier (#486/#533).
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / WT_NEW / STATUS / ...) and sources tests/lib/golem-sandbox.sh for the
# shared sandbox plumbing (new_sandbox / run_in / ...) BEFORE this file. This
# fragment therefore only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_test list.

# --- worktree-rm.sh ---------------------------------------------------------

# Non-integer argument → exit 2.
test_worktree_rm_non_integer_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_RM" notanumber
    assert_exit 2 "$RUN_RC" "worktree-rm with a non-integer arg exits 2"
    assert_contains "$RUN_OUT" "issue number" "explains an issue number is required"
}

# Absent issue → clean no-op (exit 0) with a "nothing to remove" message.
test_worktree_rm_absent_is_noop() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_RM" 404
    assert_exit 0 "$RUN_RC" "worktree-rm for an absent issue is a clean no-op (exit 0)"
    assert_contains "$RUN_OUT" "nothing to remove" "reports nothing to remove"
}

# Round-trip: worktree-new then worktree-rm removes the worktree AND the branch.
test_worktree_rm_round_trip() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 34
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    run_in "$sb" "$WT_RM" 34
    assert_exit 0 "$RUN_RC" "worktree-rm succeeds"
    assert_contains "$RUN_OUT" "removed worktree" "reports the worktree removal"
    assert_contains "$RUN_OUT" "deleted branch" "reports the branch deletion"
    local branches
    branches="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" branch --list "feature/issue-34")"
    assert_equals "" "$branches" "the feature/issue-34 branch is gone after rm"
}

# Regression (#486): the tmux-kill block must kill the session UNCONDITIONALLY,
# not gate the kill on `tmux has-session`. That guard raced the golem's own
# `claude … ; claude …` self-teardown and intermittently reported the session
# absent while it lingered a beat longer, so the kill was skipped and golem-N
# leaked into `tmux ls` / golem-status.sh. A stub `tmux` that returns NON-ZERO
# for `has-session` (the racy false reading) but ZERO for `kill-session` (the
# session really is there) distinguishes the two behaviors: the old guarded code
# would skip the kill (no "killed" line), the new code kills anyway. Pins that
# `kill-session` is invoked with the exact-name `=golem-N` target and the
# "killed tmux session" line still prints. --unset=BASH_ENV keeps the
# devcontainer's /etc/bash_env from resetting $PATH and shadowing the stub (see
# run_launch_auth and the devcontainer-bash-env-path-reset note).
test_worktree_rm_kills_session_despite_has_session_false() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 62
    assert_exit 0 "$RUN_RC" "worktree-new seeds the worktree to reap"

    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Test stub: log argv; report has-session FALSE (racy guard) but kill-session OK.
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
case "$1" in
    has-session) exit 1 ;;
    kill-session) exit 0 ;;
    *) exit 0 ;;
esac
EOF
    command chmod +x "$sb/bin/tmux"

    local log="$sb/tmux-stub.log"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            TMUX_STUB_LOG="$log" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 62 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" "worktree-rm exits 0 with the tmux stub"
    assert_contains "$RUN_OUT" "killed tmux session golem-62" \
        "kills the session even though has-session would report it absent"
    local killlog
    killlog="$(command cat "$log" 2>/dev/null || true)"
    assert_contains "$killlog" "kill-session -t =golem-62" \
        "invokes kill-session with the exact-name =golem-N target"
}

# Regression companion (#486): the OTHER branch of the unconditional kill — tmux
# present but `kill-session` genuinely fails (no such session) — must stay a quiet
# exit-0 no-op: NO "killed tmux session" line and removed stays 0 (so a torn-down
# golem with nothing else to remove reports "nothing to remove", not a phantom
# kill). Without the old `has-session` guard, kill-session's own non-zero exit is
# the sole gate on the echo/removed=1, so pin it deterministically with a stub
# (kill-session -> non-zero) rather than relying on the host's real tmux. Run
# against an ABSENT issue so no worktree/branch removal masks removed=0.
#
# The stub emits tmux's REAL absent-session message (#533). A bare non-zero with
# empty stderr now classifies as `failed`, not `absent` — deliberately, since an
# unexplained failure is the case an operator must see — so this case has to
# speak tmux's actual language to keep exercising the quiet path. The added
# no-WARNING assertion is what fails if the classifier ever over-warns on an
# ORDINARY teardown, which would make the warning noise operators tune out.
test_worktree_rm_kill_session_failure_is_quiet_noop() {
    local sb
    new_sandbox sb

    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Test stub: log argv; report every subcommand as FAILED (session truly absent),
# using tmux's real wording so worktree-rm classifies it as `absent` (#533).
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
printf "can't find session: %s\n" "${3:-}" >&2
exit 1
EOF
    command chmod +x "$sb/bin/tmux"

    local log="$sb/tmux-stub.log"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            TMUX_STUB_LOG="$log" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 63 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" "worktree-rm exits 0 when kill-session fails (absent session)"
    assert_not_contains "$RUN_OUT" "killed tmux session" \
        "does not claim a kill when kill-session returned non-zero"
    # removed stays 0: nothing else to remove for an absent issue -> "nothing to remove".
    assert_contains "$RUN_OUT" "nothing to remove" \
        "a failed kill does not set removed=1 (phantom removal)"
    assert_not_contains "$RUN_OUT" "WARNING" \
        "an ordinary absent-session teardown warns about nothing (#533)"
    local killlog
    killlog="$(command cat "$log" 2>/dev/null || true)"
    assert_contains "$killlog" "kill-session -t =golem-63" \
        "still attempts the exact-name kill-session before treating it as a no-op"
}

# The other benign shape, end to end (#533): NO TMUX SERVER AT ALL.
#
# This is the common teardown case on a host that never started tmux, and its
# stderr never mentions a session — so a matcher written only against the
# issue's suggested "can't find session" wording would warn here, on the most
# routine teardown there is. The classifier case covers the verdict; this covers
# the whole script, because the two can disagree (the dispatch, not the helper,
# decides what gets printed). Same absent contract as the case above: silent,
# exit 0, no phantom removal.
test_worktree_rm_no_tmux_server_is_quiet_noop() {
    local sb
    new_sandbox sb

    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Test stub: log argv; emit tmux's real "no server" wording (#533).
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
printf 'no server running on /tmp/tmux-501/default\n' >&2
exit 1
EOF
    command chmod +x "$sb/bin/tmux"

    local log="$sb/tmux-stub.log"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            TMUX_STUB_LOG="$log" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 65 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" "a server-less host is a clean exit-0 teardown"
    assert_not_contains "$RUN_OUT" "WARNING" \
        "no server running is NOT a failure — warning here would be noise on every teardown"
    assert_not_contains "$RUN_OUT" "killed tmux session" \
        "does not claim a kill when there was no server"
    assert_contains "$RUN_OUT" "nothing to remove" \
        "removed stays 0 when there was nothing to kill"
}

# --- #533: a real kill-session failure is not a session-absent no-op ----------

# The pure classifier, driven directly.
#
# `tmux kill-session` returns the same non-zero exit for "no such session" (an
# expected no-op) and for a real fault leaving the session ALIVE; only stderr
# separates them. That decision is a pure function, so slice it out and drive
# every branch — the same idiom validate-lint-gates.sh uses for
# `ruff_install_action`, and for the same reason: a hand-reimplemented matcher
# here would drift from the script and keep passing while the real one broke.
#
# run_kill_outcome <rc> <stderr>
run_kill_outcome() {
    /usr/bin/env --unset=BASH_ENV "$REAL_BASH" -c '
        eval "$(command sed -n "/^tmux_kill_outcome() {/,/^}/p" "$1")"
        tmux_kill_outcome "$2" "$3"
    ' _ "$WT_RM" "$1" "$2" 2>&1
}

test_worktree_rm_kill_session_classifier() {
    assert_equals "killed" "$(run_kill_outcome 0 "")" \
        "exit 0 is a real kill"

    # All three shapes tmux 3.5a actually emits for "nothing to kill". Two never
    # mention a session, so a matcher keyed only on the issue's suggested
    # "can't find session" text would warn on every teardown on a server-less host.
    assert_equals "absent" "$(run_kill_outcome 1 "can't find session: golem-9")" \
        "server up but session gone is absent"
    assert_equals "absent" \
        "$(run_kill_outcome 1 "error connecting to /tmp/tmux-501/default (No such file or directory)")" \
        "no server ever started is absent"
    assert_equals "absent" "$(run_kill_outcome 1 "no server running on /tmp/tmux-501/default")" \
        "a server that started then exited is absent"
    assert_equals "absent" "$(run_kill_outcome 1 "SESSION NOT FOUND")" \
        "the benign match is case-insensitive"

    # `error connecting to` is only benign for ENOENT. tmux formats the message as
    # `error connecting to <sock> (<strerror>)`, and the SAME prefix carries
    # Permission denied for a LOCKED socket whose session is still running —
    # verified against tmux 3.5a by chmod 000 on a live socket, which yields
    # exactly this message and leaves the session alive. Treating that as absent
    # would re-create the swallowed-failure bug #533 closes.
    assert_equals "failed" "$(run_kill_outcome 1 "error connecting to /tmp/s (Permission denied)")" \
        "a locked socket is a real failure, not an absent server"
    # Any OTHER strerror on the same prefix is unrecognized, so it warns rather
    # than being assumed benign. (ECONNREFUSED is NOT the stale-socket case: a
    # bound, non-listening socket reports `no server running`, matched above.
    # Verified against tmux 3.5a.)
    assert_equals "failed" "$(run_kill_outcome 1 "error connecting to /tmp/s (Connection refused)")" \
        "an unrecognized connect strerror warns rather than passing as absent"

    # The ENOENT parenthetical is libc's strerror, which IS translated via
    # LC_MESSAGES (glibc: "Aucun fichier ou dossier de ce nom"), unlike the three
    # tmux-authored literals. The classifier matches only the English text, so the
    # dispatch pins LC_ALL=C; this asserts the untranslated form is what reaches
    # the benign arm, and the translated form does not silently pass.
    assert_equals "absent" \
        "$(run_kill_outcome 1 "error connecting to /tmp/s (No such file or directory)")" \
        "the C-locale ENOENT wording is the benign no-server case"
    assert_equals "failed" \
        "$(run_kill_outcome 1 "error connecting to /tmp/s (Aucun fichier ou dossier de ce nom)")" \
        "a TRANSLATED ENOENT is not silently benign — the caller must pin LC_ALL=C"

    # The non-numeric rc fail-safe the helper's comment claims. `[ "$rc" = "0" ]`
    # compares as a STRING on purpose; a future refactor to arithmetic
    # `(( rc == 0 ))` would abort under set -e on a non-numeric rc instead of
    # degrading to `failed`. Pin the documented property so the claim is not just
    # a comment.
    assert_equals "failed" "$(run_kill_outcome "abc" "")" \
        "a non-numeric rc degrades to failed, never an arithmetic abort"

    # The whole point of the issue: anything unrecognized means the session may
    # still be alive.
    assert_equals "failed" "$(run_kill_outcome 1 "server exited unexpectedly")" \
        "an unrecognized tmux error is a real failure"

    # An EMPTY stderr is `failed`, not `absent`. Defaulting the unknown to benign
    # is precisely the swallowed-error bug #533 exists to close, so pin it.
    assert_equals "failed" "$(run_kill_outcome 1 "")" \
        "a non-zero exit with no explanation is a real failure, not a no-op"
}

# End to end: the case the issue actually asks for. A stub `tmux` fails with an
# unexpected error, so the operator must SEE it — but teardown still exits 0 and
# must not claim a kill that did not happen.
#
# The removed=0 half is the load-bearing assertion: setting removed=1 here would
# fire the terminal `reaped` feed event (#446) for a golem whose session is still
# running, telling golem-status.sh the opposite of the truth. Run against an
# ABSENT issue so no worktree/branch removal masks it.
test_worktree_rm_warns_on_unexpected_kill_failure() {
    local sb
    new_sandbox sb

    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Test stub: log argv; fail with an error that is NOT a missing session.
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
printf 'server exited unexpectedly\n' >&2
exit 1
EOF
    command chmod +x "$sb/bin/tmux"

    local log="$sb/tmux-stub.log"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            TMUX_STUB_LOG="$log" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 64 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" \
        "teardown still exits 0 after a failed kill (worktree removal already happened)"
    assert_contains "$RUN_OUT" "WARNING: tmux kill-session failed for golem-64" \
        "the operator is told the session was NOT killed"
    assert_contains "$RUN_OUT" "server exited unexpectedly" \
        "tmux's own error text is carried through, not swallowed"
    assert_not_contains "$RUN_OUT" "killed tmux session" \
        "does not claim a kill that did not happen"
    # removed stays 0 -> no phantom reaped event for a still-live session.
    assert_contains "$RUN_OUT" "nothing to remove" \
        "a failed kill does not set removed=1 (would fire a false reaped event, #446)"
}

# The locked-socket case, end to end (#533). Its stderr shares the `error
# connecting to` prefix with the benign no-server shape, so an over-wide socket
# matcher swallows it — silently, on a session that is STILL RUNNING. That is
# this script's original bug wearing a different message, so it gets whole-script
# coverage and not just a classifier verdict: the dispatch, not the helper,
# decides whether the operator is told.
test_worktree_rm_warns_on_locked_socket() {
    local sb
    new_sandbox sb

    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Test stub: log argv; emit tmux's real EACCES wording — same `error connecting
# to` prefix as the benign no-server case, different parenthetical (#533).
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
printf 'error connecting to /tmp/tmux-501/default (Permission denied)\n' >&2
exit 1
EOF
    command chmod +x "$sb/bin/tmux"

    local log="$sb/tmux-stub.log"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            TMUX_STUB_LOG="$log" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 66 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" "a locked socket still exits 0 (teardown already happened)"
    assert_contains "$RUN_OUT" "WARNING: tmux kill-session failed for golem-66" \
        "a locked socket warns — the session may still be running"
    assert_contains "$RUN_OUT" "Permission denied" \
        "tmux's own EACCES text reaches the operator"
    assert_not_contains "$RUN_OUT" "killed tmux session" \
        "does not claim a kill against an unreachable socket"
}

# The two remaining `failed` shapes, end to end (#533).
#
# EMPTY stderr is deliberately a `failed` case — an unexplained non-zero is the
# one an operator most needs to see — but it was the only classifier-covered case
# with no end-to-end coverage, and interpolating it raw ended the warning at a
# dangling `): `. CONTROL CHARACTERS matter because this stderr is now echoed to
# a terminal rather than discarded, and it embeds the socket path: a crafted path
# or a spoofed tmux earlier on PATH could otherwise smuggle ANSI escapes into the
# operator's session. Both are asserted through the real dispatch, since the
# message is built there and not in the classifier.
test_worktree_rm_failed_warning_is_well_formed() {
    local sb
    new_sandbox sb

    command mkdir -p "$sb/bin"
    # Case 1: non-zero with NO stderr at all.
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    command chmod +x "$sb/bin/tmux"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 68 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" "an unexplained kill failure still exits 0"
    assert_contains "$RUN_OUT" "WARNING: tmux kill-session failed for golem-68" \
        "an empty-stderr failure still warns"
    # Assert the CONCRETE expected suffix. An earlier version of this used
    # assert_not_contains with a needle ending in `$`, intending an end-of-string
    # anchor — but assert_not_contains does a plain glob substring test, so the
    # `$` was a literal character present in neither the buggy nor the fixed
    # output, and the assertion could never fail. Pin the text that must be
    # there instead of the shape that must not.
    assert_contains "$RUN_OUT" "may still be running): (no stderr from tmux)" \
        "the empty case names itself instead of trailing a bare colon"

    # Case 2: stderr carrying terminal escape sequences. Includes a literal `%s`
    # and a backslash to prove the text is passed as printf DATA, not format, and
    # a DEL byte (\177) — a control character outside the C0 range that an
    # incomplete strip class would leave behind.
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf 'boom%%s\\x\033[31mRED\033[0m\007\177\rOVERWRITE\n' >&2
exit 1
EOF
    command chmod +x "$sb/bin/tmux"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 69 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" "a control-character-bearing failure still exits 0"
    assert_contains "$RUN_OUT" "boom" \
        "the readable part of tmux's error survives sanitizing"
    # The ESC and BEL bytes must be gone. Compared via a literal control byte so
    # the assertion tests the actual output, not an escaped rendering of it.
    assert_not_contains "$RUN_OUT" "$(command printf '\033')" \
        "ESC is stripped — tmux stderr cannot inject ANSI into the operator's terminal"
    assert_not_contains "$RUN_OUT" "$(command printf '\007')" \
        "BEL is stripped"
    assert_not_contains "$RUN_OUT" "$(command printf '\177')" \
        "DEL is stripped too — it is a control character outside the C0 range"
    # CR is its own spoofing primitive: a terminal returns the cursor to column 0,
    # so an embedded \r lets crafted stderr overwrite the WARNING text and make the
    # line read as something else. An enumerated strip class skipped it once
    # already (\013\014 then \016-\037, jumping \015), so pin it.
    assert_not_contains "$RUN_OUT" "$(command printf '\r')" \
        "CR is stripped — crafted stderr cannot overwrite the warning line"
    # The format string is fixed, so a literal %s in tmux's stderr must survive
    # verbatim rather than being consumed as a conversion.
    assert_contains "$RUN_OUT" "%s" \
        "a literal %s in tmux stderr is data, never a printf conversion"

    # Case 2b: an ALL-control payload sanitizes to nothing. That must NOT read as
    # "tmux said nothing" — it is the more suspicious, more actionable state
    # (a crafted payload, or tooling that cannot render it), so the operator has
    # to be able to tell the two apart.
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '\033\007\001\n' >&2
exit 1
EOF
    command chmod +x "$sb/bin/tmux"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 71 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" "an all-control payload still exits 0"
    assert_contains "$RUN_OUT" "(stderr present but unprintable)" \
        "an all-control payload is reported distinctly, not as 'no stderr'"
    assert_not_contains "$RUN_OUT" "(no stderr from tmux)" \
        "…and is NOT conflated with tmux having said nothing"

    # Case 3: `tr` itself is unavailable — the script's ONLY external dependency
    # in this path, used both by the classifier (lowercasing) and the sanitizer.
    #
    # Two distinct hazards, and the message below is chosen to separate them.
    # (a) set -e: a bare assignment from a command substitution aborts the script,
    #     so an unavailable `tr` would exit 127 AFTER the destructive git
    #     mutations, stranding a removed worktree.
    # (b) misclassification: if the lowercase step yields nothing, EVERY message
    #     — including the benign ones — falls to the `failed` arm and warns on an
    #     ordinary teardown.
    #
    # The stub tmux emits a BENIGN message on purpose. A test using an
    # already-failing message would reach the warning either way and so could not
    # tell (b) from correct behaviour — it would pass while the classifier was
    # broken. Here, ANY warning means the fallback failed.
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf "can't find session: golem-70\n" >&2
exit 1
EOF
    command chmod +x "$sb/bin/tmux"
    command cat >"$sb/bin/tr" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
    command chmod +x "$sb/bin/tr"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 70 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" \
        "a missing tr does NOT abort teardown (set -e on the substitution)"
    assert_not_contains "$RUN_OUT" "WARNING" \
        "a benign message still classifies absent when tr is gone — no spurious warning"
    assert_not_contains "$RUN_OUT" "killed tmux session" \
        "…and still does not claim a kill"
    command rm -f "$sb/bin/tr"
}

# The dispatch must invoke tmux under LC_ALL=C (#533).
#
# The benign ENOENT match keys off libc's strerror text, which is TRANSLATED via
# LC_MESSAGES — glibc really does ship "Aucun fichier ou dossier de ce nom" for
# ENOENT. On a host with such a locale generated, an unpinned call would miss the
# match and warn on every ordinary server-less teardown: the exact noise the
# narrowing exists to prevent. Asserted BEHAVIOURALLY — the stub reports the
# LC_ALL it was actually run with — because a grep for the string would pass even
# if the assignment were on the wrong command.
test_worktree_rm_pins_c_locale_for_tmux() {
    local sb
    new_sandbox sb

    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Test stub: record the locale tmux was invoked under, then act as absent.
printf 'LC_ALL=%s\n' "${LC_ALL-unset}" >>"$TMUX_STUB_LOG"
printf 'error connecting to /tmp/tmux-501/default (No such file or directory)\n' >&2
exit 1
EOF
    command chmod +x "$sb/bin/tmux"

    local log="$sb/tmux-stub.log"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            LC_ALL=fr_FR.UTF-8 \
            LANGUAGE=fr \
            LC_MESSAGES=fr_FR.UTF-8 \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            TMUX_STUB_LOG="$log" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 67 2>&1)" || RUN_RC=$?

    assert_exit 0 "$RUN_RC" "teardown exits 0 under a non-English ambient locale"
    local loclog
    loclog="$(command cat "$log" 2>/dev/null || true)"
    # The ambient fr_FR must NOT reach tmux — the call overrides it.
    assert_contains "$loclog" "LC_ALL=C" \
        "tmux is invoked under LC_ALL=C so strerror text stays English"
    # LANGUAGE is set too, because glibc's gettext consults it with its own
    # precedence and it is exported independently of LC_ALL on Debian-derived
    # hosts. glibc documents that LANGUAGE is IGNORED when the locale is C/POSIX
    # (verified directly against this box's libc: LANGUAGE=fr LC_ALL=C still
    # yields the English strerror), so LC_ALL=C alone closes the hole — this pins
    # that conclusion rather than leaving it as prose in the source comment.
    assert_not_contains "$RUN_OUT" "WARNING" \
        "a server-less teardown stays silent even with ambient LC_ALL, LC_MESSAGES and LANGUAGE all set to French"
}

# Every outcome the classifier can echo must have its own `case` label in the
# dispatch, with the wildcard reserved for an internal-contract violation.
#
# A `*)` doubling as a real arm looks harmless while the helper echoes only three
# strings, but it turns a future typo in an outcome name into silently taking the
# wrong branch — the #542 lesson, applied here. The names are read OUT OF THE
# HELPER rather than hardcoded, so a fourth outcome is picked up automatically
# instead of falling through.
test_worktree_rm_kill_dispatch_handles_every_outcome() {
    local outcome outcomes
    # Unquoted in the loop on purpose: the awk output is a newline-separated list
    # of `[a-z-]+` tokens (the regex admits nothing else) and word-splitting it
    # into the loop is the intent.
    outcomes="$(command awk '
        /^tmux_kill_outcome\(\) \{/ { grab = 1; next }
        grab && /^\}/ { exit }
        grab && match($0, /echo "[a-z-]+"/) {
            print substr($0, RSTART + 6, RLENGTH - 7)
        }
    ' "$WT_RM")"

    # NON-VACUITY FLOOR. If the helper is renamed or reshaped so the awk anchor
    # stops matching, the extraction yields NOTHING — and a for-loop over nothing
    # asserts nothing while still reporting PASS. That failure mode is the reason
    # this case exists, so pin the count: 3 outcomes today, a 4th arrives with a
    # deliberate bump here.
    assert_equals "3" "$(command printf '%s\n' "$outcomes" | command grep -c '[a-z]')" \
        "all 3 classifier outcomes were extracted (a broken anchor would assert nothing)"

    # shellcheck disable=SC2086 # deliberate word-split, see comment above
    for outcome in $outcomes; do
        assert_file_contains "$WT_RM" "        $outcome)" \
            "the dispatch handles '$outcome' explicitly, not via the wildcard"
    done
    assert_file_contains "$WT_RM" "ERROR: internal — tmux_kill_outcome returned" \
        "the wildcard reports an internal-contract violation"
}

# Teardown emits a terminal `reaped` feed line (#446, Bug #2). worktree-rm.sh pipes
# a REAPED:-prefixed Notification to golem-notify.sh after a successful teardown so
# the torn-down golem's stale `gate` line is superseded and it does not ghost on
# golem-status.sh's BLOCKED list. Two things are pinned: the line lands in the feed
# with event=reaped, AND it carries the correct `golem-N` id (not `golem-?`) — the
# script runs in the MAIN checkout, so worktree-rm.sh must force GOLEM_ID or the
# hook's basename fallback would stamp `golem-?` and never correlate.
test_worktree_rm_emits_reaped_feed_line() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed-line assertion needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 51
    assert_exit 0 "$RUN_RC" "worktree-new seeds the worktree to reap"
    run_in "$sb" "$WT_RM" 51
    assert_exit 0 "$RUN_RC" "worktree-rm succeeds"

    local feed
    feed="$sb/.worktrees/.status/feed.jsonl"
    assert_file_exists "$feed" "worktree-rm wrote a feed line on teardown"
    # The most-recent line for golem-51 must be a reaped event with the right id.
    local reaped
    reaped="$(command grep '"golem":"golem-51"' "$feed" 2>/dev/null | command tail -n1)"
    assert_not_empty "$reaped" "a feed line for golem-51 was written"
    local ev
    ev="$(command printf '%s' "$reaped" | jq -r '.event' 2>/dev/null)"
    assert_equals "reaped" "$ev" "the teardown line classifies as event=reaped (#446)"
    # No golem-? ghost id: the forced GOLEM_ID must have resolved to golem-51.
    assert_not_contains "$reaped" "golem-?" "the reaped line carries golem-51, not the golem-? sentinel"
}

# Regression (#328): worktree-rm.sh runs its OWN destructive git mutations
# (worktree remove / branch -D / config --unset core.worktree / worktree prune)
# after repo_root(). Like worktree-new, a tainted GIT_DIR/GIT_COMMON_DIR
# forwarded from a git hook would redirect those to an OUTER repo — force-
# deleting the wrong repo's branch or corrupting its core.worktree. The
# process-wide scrub added after `. config.sh` re-anchors them to cwd. Seed the
# sandbox with a worktree+branch via WT_NEW under run_in (safe — scrubbed), then
# invoke WT_RM directly UNDER taint (bypassing run_in's scrub) with
# GIT_DIR/GIT_COMMON_DIR pointed at a separate outer repo that carries an
# identically-named branch, and assert the SANDBOX's worktree+branch are removed
# while the outer repo's same-named branch is untouched (no cross-repo deletion).
test_worktree_rm_scrubs_tainted_git_env_for_mutations() {
    local sb outer
    new_sandbox sb
    # Create the sandbox worktree+branch to remove (scrubbed path — safe).
    run_in "$sb" "$WT_NEW" 79
    assert_exit 0 "$RUN_RC" "worktree-new seeds the sandbox worktree+branch"

    # A separate outer repo carrying an identically-named branch. If worktree-rm
    # ran its `git branch -D` in the tainted env, it would delete THIS branch.
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" -c commit.gpgsign=false commit -q --allow-empty -m outerseed 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch "feature/issue-79" 2>/dev/null || return 1

    # Run worktree-rm from the sandbox with the git env TAINTED toward outer.
    # No GIT_SCRUB on this invocation — the taint is the point; the script's own
    # #328 scrub must clear it. Pin GOLEM_* / HOME like run_in does otherwise.
    local out rc=0
    out="$(cd "$sb" &&
        GIT_DIR="$outer/.git" GIT_COMMON_DIR="$outer/.git" \
            HOME="$sb" \
            TMUX='' TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 79 2>&1)" || rc=$?
    assert_exit 0 "$rc" "worktree-rm exits 0 despite a tainted git environment"

    local sb_branch outer_branch
    sb_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" branch --list "feature/issue-79")"
    outer_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch --list "feature/issue-79")"
    assert_output_empty "$sb_branch" \
        "the SANDBOX branch was deleted (the mutation targeted the right repo)"
    assert_not_empty "$outer_branch" \
        "the outer/tainted repo's same-named branch is untouched (no cross-repo delete)"
}

# Security regression (#376, deferred from the #355/PR #375 pre-PR review): the
# mutation-level companion to test_worktree_rm_scrubs_tainted_git_env_for_mutations
# (#328), swapping the GIT_DIR taint for a GIT_CONFIG_COUNT/KEY_0/VALUE_0 config
# injection so the DESTRUCTIVE teardown (worktree remove / branch -D) is exercised
# under the dynamic GIT_CONFIG_* family end-to-end, not just at the repo_root()
# unit level. The injected core.hooksPath points at a hooks dir whose
# reference-transaction hook ALWAYS fails: if the scrub is dropped, worktree-rm's
# own `git branch -D` fires the hook and aborts the ref deletion (script exits
# non-zero, branch survives); with the scrub the injection is gone and the teardown
# runs clean, removing the sandbox worktree+branch. No GIT_SCRUB on the invocation
# — the taint is the point; the script's own #328 scrub must clear it. Pin GOLEM_*
# / HOME like run_in does otherwise.
test_worktree_rm_scrubs_git_config_injection_for_mutations() {
    local sb hooks
    new_sandbox sb
    # Seed the sandbox worktree+branch to remove (scrubbed path — safe).
    run_in "$sb" "$WT_NEW" 77
    assert_exit 0 "$RUN_RC" "worktree-new seeds the sandbox worktree+branch"
    _seed_failing_ref_hook "$sb" hooks

    local out rc=0
    out="$(cd "$sb" &&
        GIT_CONFIG_COUNT=1 \
            GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
            HOME="$sb" \
            TMUX='' TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 77 2>&1)" || rc=$?
    assert_exit 0 "$rc" "worktree-rm exits 0 despite a GIT_CONFIG_* injection taint"

    assert_true "[ ! -e '$sb/.worktrees/issue-77' ]" \
        "the worktree directory is gone after rm despite the config injection"
    local sb_branch
    sb_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" branch --list "feature/issue-77")"
    assert_output_empty "$sb_branch" \
        "the sandbox branch was deleted despite the GIT_CONFIG_* injection (scrub clears the dynamic pairs)"
}

# Regression (#368, deferred from PR #367's pre-PR review): worktree-rm.sh's
# top-level `unset $(_git_env_scrub_names)` carries the same FAIL-LOUD contract as
# worktree-new's — "NO `|| true`: a readonly GIT_DIR makes `unset` fail, which
# under `set -e` aborts LOUDLY before any mutation." Without this test a future
# edit adding `|| true` would silently let worktree-rm's DESTRUCTIVE mutations
# (worktree remove / branch -D / config --unset core.worktree) run in a tainted
# env. Pins it: a readonly-exported GIT_DIR/GIT_COMMON_DIR must make worktree-rm
# EXIT NON-ZERO and delete NOTHING — the pre-seeded sandbox worktree+branch stay
# intact and the outer repo is untouched.
#
# Same SOURCING requirement as the worktree-new case above: `declare -rx`'s
# readonly attribute is dropped across `exec`, so the taint must be applied by
# sourcing the script inside a bash that first declared the readonly vars (the
# plain `bash script` form run_in uses would inherit only the value, not the
# readonly-ness, and the unset would succeed). No GIT_SCRUB on the invocation —
# the taint is the point; the script's own guard must abort on it.
test_worktree_rm_readonly_tainted_git_env_fails_loud() {
    local sb outer
    new_sandbox sb
    # Seed the sandbox worktree+branch to (attempt to) remove — scrubbed, safe.
    run_in "$sb" "$WT_NEW" 79
    assert_exit 0 "$RUN_RC" "worktree-new seeds the sandbox worktree+branch"

    # A separate outer repo carrying an identically-named branch: if worktree-rm
    # ran its `git branch -D` in the tainted env it would delete THIS branch.
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" -c commit.gpgsign=false commit -q --allow-empty -m outerseed 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch "feature/issue-79" 2>/dev/null || return 1

    # Source worktree-rm inside a child bash that makes GIT_DIR/GIT_COMMON_DIR
    # `declare -rx` BEFORE the script's `unset` runs, so the unset fails and
    # `set -e` aborts before any destructive mutation.
    local out rc=0
    out="$(cd "$sb" &&
        HOME="$sb" \
            TMUX='' TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" -c \
            'declare -rx GIT_DIR="$2/.git"; declare -rx GIT_COMMON_DIR="$2/.git"; . "$1" 79' \
            _ "$WT_RM" "$outer" 2>&1)" || rc=$?
    assert_true "[ \"$rc\" -ne 0 ]" \
        "worktree-rm aborts NON-ZERO under a readonly-tainted git environment (fail-loud)"
    # The LOUD half of fail-loud (#368) — see the twin assertion in
    # 20-worktree-new.sh. A silent non-zero abort would satisfy the exit-code
    # check alone while telling an operator nothing about the cause.
    assert_contains "$out" "readonly variable" \
        "worktree-rm names the readonly GIT_* variable it could not unset (the LOUD half of fail-loud, #368)"

    # No mutation: the sandbox's worktree+branch survive, and the outer repo's
    # same-named branch is untouched (no cross-repo delete).
    local sb_branch outer_branch
    sb_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" branch --list "feature/issue-79")"
    outer_branch="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" branch --list "feature/issue-79")"
    assert_not_empty "$sb_branch" \
        "the sandbox branch survives (aborted before the destructive branch -D)"
    assert_true "[ -e \"$sb/.worktrees/issue-79\" ]" \
        "the sandbox worktree dir survives (aborted before git worktree remove)"
    assert_not_empty "$outer_branch" \
        "the outer/tainted repo's same-named branch is untouched (no cross-repo delete)"
}

# Regression (#325): worktree-new.sh now populates submodules, and
# `git worktree remove` (without --force) REFUSES any worktree containing a
# populated submodule ("working trees containing submodules cannot be moved or
# removed", exit 128) even when the submodule is clean. worktree-rm.sh must
# detect that the worktree is otherwise-clean and force past it, so ordinary
# teardown still succeeds. Round-trip a submodule-bearing worktree and assert rm
# removes it (exit 0) and reports forcing past clean submodules.
test_worktree_rm_forces_past_clean_submodule() {
    local super st=0
    _make_super_with_submodule super || st=$?
    if [ "$st" -eq 2 ]; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    [ "$st" -eq 0 ] || return 1
    run_in "$super" "$WT_NEW" 40
    assert_exit 0 "$RUN_RC" "worktree-new succeeds with a submodule present"
    assert_file_exists "$super/.worktrees/issue-40/mod/bin/fix.sh" \
        "the submodule is populated in the fresh worktree"
    run_in "$super" "$WT_RM" 40
    assert_exit 0 "$RUN_RC" "worktree-rm removes a clean submodule-bearing worktree"
    assert_contains "$RUN_OUT" "removed worktree" "reports the worktree removal"
    assert_true "[ ! -e '$super/.worktrees/issue-40' ]" \
        "the worktree directory is gone after rm"
}

# Regression (#325): the force-past-submodule path must NOT clobber real
# uncommitted work. When a worktree has BOTH a populated submodule AND a dirty
# REGULAR file, git still prints the submodule message, so a naive `--force`
# would silently discard the user's changes. worktree-rm.sh gates the force on
# `status --ignore-submodules=all` being empty, so a dirty regular file makes it
# REFUSE (exit 1) instead of forcing. Dirty a tracked file in the worktree and
# assert rm refuses and preserves the file.
test_worktree_rm_refuses_dirty_regular_file_with_submodule() {
    local super st=0
    _make_super_with_submodule super || st=$?
    if [ "$st" -eq 2 ]; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    [ "$st" -eq 0 ] || return 1
    run_in "$super" "$WT_NEW" 41
    assert_exit 0 "$RUN_RC" "worktree-new succeeds with a submodule present"
    # Dirty a tracked, non-submodule file in the worktree.
    command printf 'UNCOMMITTED USER WORK\n' >>"$super/.worktrees/issue-41/app.txt"
    run_in "$super" "$WT_RM" 41
    assert_exit 1 "$RUN_RC" "worktree-rm refuses a worktree with dirty regular files"
    assert_contains "$RUN_OUT" "uncommitted changes" "explains there are uncommitted changes"
    assert_file_contains "$super/.worktrees/issue-41/app.txt" "UNCOMMITTED USER WORK" \
        "the uncommitted work is preserved, not force-discarded"
}

# --- Stale symlink attributes (#768) ----------------------------------------
#
# On a macOS Docker bind mount (virtiofs/bindfs) a committed symlink can report
# `nlink=0 size=0`, which defeats git's stat comparison and makes it report the
# link `M` forever. worktree-rm.sh's dirty gate then reads a filesystem artifact
# as uncommitted work and refuses teardown — and since #662/#665 deny the
# main-session `--force`, nothing can tear the worktree down at all.
#
# WHAT THESE TESTS CAN AND CANNOT DO. The `size=0` staleness is a property of
# the FILESYSTEM and cannot be reproduced on ext4 — verified: a committed
# symlink here reports `nlink=1 size=10` and stays clean, and neither
# `update-index --cacheinfo`, a retarget-and-restore, nor `core.checkStat
# minimal` will manufacture it. More sharply: on a sane filesystem an UNSTAGED
# ` M ` symlink whose target matches the index is a contradiction, so the
# carve-out's positive arm is unreachable through an ordinary fixture.
#
# So the positive arm is driven through a `git` PATH stub that returns the
# `--raw` line ACTUALLY OBSERVED on the live .worktrees/issue-760 fixture
# (recorded on the issue), while every other git call runs for real. That keeps
# the assertion honest — it pins the helper against real-world input rather than
# an invented one — without pretending ext4 can produce the artifact.
#
# The negative arms need no stub: a genuinely retargeted symlink, a
# link-replaced-by-file, and a deletion are all reproducible directly, and they
# are the arms that protect real work.

# _plant_git_raw_stub <sandbox> <blob> <path> — put a `git` on PATH that makes
# real git BEHAVE as it does on a virtiofs mount where <path>'s stat attributes
# are stale. Mirrors plant_tmux_stub's shape (tests/lib/golem-sandbox.sh).
#
# The artifact is invisible to the script except through three git observations,
# so the stub forges exactly those three and delegates everything else:
#
#   status --porcelain   prepend ` M <path>` to real git's output — the stale
#                        link reads as modified while real changes still appear
#   worktree remove      refuse WITHOUT --force, as git does for a worktree it
#                        believes holds modified files; --force delegates
#   diff --raw           the observed shape: unchanged 120000 mode on both
#                        sides, all-zero destination hash
#
# Everything the carve-out actually DECIDES on still runs for real: `cat-file -p`
# reads the true index blob, `readlink` reads the true on-disk target, and the
# residue filter, helper and disclosure are the shipped code. So the stub
# supplies the filesystem's lie and nothing else — it cannot make a wrong
# implementation pass, which is what the mutation round below confirms.
#
# Single-use by design — it belongs to this area, so it stays in this fragment
# rather than accreting into the shared sandbox library.
_plant_git_raw_stub() {
    local sb="$1" blob="$2" path="$3" real
    real="$(command -v git)"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<EOF
#!/usr/bin/env bash
# Test stub (#768): forge the three git observations a stale-attr symlink
# produces on virtiofs; defer everything else to the real git.
_raw=0 _status=0 _wt_remove=0 _forced=0
for a in "\$@"; do
    case "\$a" in
        --raw) _raw=1 ;;
        --force) _forced=1 ;;
    esac
done
# Match the SUBCOMMAND, not a bare \`--porcelain\`: \`worktree list --porcelain\`
# also carries that flag, and hijacking it corrupts the worktree-detection grep
# that gates the whole teardown (verified — the script then found no worktree).
case " \$* " in *" status "*) _status=1 ;; esac
# \`worktree\` and \`remove\` are adjacent in argv, so match them as one token
# pair — a \`*" worktree "*" remove "*\` pattern requires an intervening word and
# silently never fires (verified).
case " \$* " in *" worktree remove "*) _wt_remove=1 ;; esac

if [ "\$_raw" = 1 ]; then
    command printf ':120000 120000 %s 0000000 M\t%s\n' "$blob" "$path"
    exit 0
fi
if [ "\$_status" = 1 ]; then
    command printf ' M %s\n' "$path"
    exec "$real" "\$@"
fi
if [ "\$_wt_remove" = 1 ] && [ "\$_forced" = 0 ]; then
    command printf 'fatal: %s contains modified or untracked files\n' "$path" >&2
    exit 1
fi
exec "$real" "\$@"
EOF
    command chmod +x "$sb/bin/git"
}

# _sandbox_with_symlink <out-var> <link> <target> — a sandbox whose committed
# tree contains <link> -> <target>, echoing the sandbox path into <out-var>.
#
# ALSO commits an `OTHER.md` for the retarget case to point at. That is not
# incidental tidiness — it is what makes the retarget test non-tautological. An
# UNCOMMITTED retarget destination shows up as `?? OTHER.md`, which keeps the
# residue non-empty ALL BY ITSELF, so teardown refuses because of the untracked
# file and the symlink check is never what decided. Verified: with the readlink
# comparison neutered, the untracked-destination version of this fixture still
# passed while a genuinely retargeted symlink WAS silently discarded — the
# fixture both armed and satisfied the gate
# ([[gate-and-evidence-converge-tautology]]). Committing the destination leaves
# the modified symlink as the ONLY dirty entry, so the assertion can only pass
# when the readlink comparison actually rejects it.
_sandbox_with_symlink() {
    # Internal local is `box`, deliberately NOT the caller's out-var name (`sb`):
    # the assignment below resolves against the current scope, so an internal
    # `sb` would shadow and overwrite the caller's local instead of exporting the
    # path back — the same pitfall _make_super_with_submodule documents.
    local __out="$1" link="$2" target="$3" box
    new_sandbox box || return 1
    command printf 'target contents\n' >"$box/$target"
    command printf 'other contents\n' >"$box/OTHER.md"
    (cd "$box" && command ln -s "$target" "$link") || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$box" add -A 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$box" commit -qm "add symlink" 2>/dev/null || return 1
    eval "$__out=\$box"
}

# THE carve-out, against the raw shape observed on the live #760 worktree: a
# symlink git calls modified whose on-disk target still matches the index blob
# is a stat artifact, so teardown proceeds and DISCLOSES why (AC#1, AC#4).
test_worktree_rm_forces_past_stale_symlink_attrs() {
    local sb blob
    _sandbox_with_symlink sb AGENTS.md CLAUDE.md || return 1
    run_in "$sb" "$WT_NEW" 60
    assert_exit 0 "$RUN_RC" "worktree-new succeeds with a committed symlink"
    blob="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb/.worktrees/issue-60" rev-parse HEAD:AGENTS.md 2>/dev/null || true)"
    assert_not_empty "$blob" "the symlink has an index blob to compare against"
    _plant_git_raw_stub "$sb" "$blob" AGENTS.md
    # PATH-prepend the stub so worktree-rm's own git calls see the forged --raw.
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 60 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "worktree-rm tears down past a stale-attr symlink"
    assert_contains "$RUN_OUT" "stale symlink attr" \
        "the forced path discloses the stale-symlink reason (AC#4)"
    assert_true "[ ! -e '$sb/.worktrees/issue-60' ]" \
        "the worktree directory is gone after rm"
}

# A symlink whose target GENUINELY changed is real work and must still block
# (AC#2). This is the arm that fails if the carve-out keys off the mode/hash
# shape instead of readlink — that shape is IDENTICAL for a real retarget
# (`:120000 120000 <blob> 0000000 M`), so a mode-only check would discard this.
test_worktree_rm_refuses_genuinely_retargeted_symlink() {
    local sb
    _sandbox_with_symlink sb AGENTS.md CLAUDE.md || return 1
    run_in "$sb" "$WT_NEW" 61
    assert_exit 0 "$RUN_RC" "worktree-new succeeds with a committed symlink"
    # OTHER.md is already COMMITTED by the fixture, so the retargeted symlink is
    # the ONLY dirty entry — see _sandbox_with_symlink's note on why an untracked
    # destination would make this assertion pass for the wrong reason.
    (cd "$sb/.worktrees/issue-61" && command ln -sfn OTHER.md AGENTS.md)
    run_in "$sb" "$WT_RM" 61
    assert_exit 1 "$RUN_RC" "worktree-rm refuses a genuinely retargeted symlink"
    assert_contains "$RUN_OUT" "uncommitted changes" "explains there are uncommitted changes"
    assert_equals "OTHER.md" "$(command readlink "$sb/.worktrees/issue-61/AGENTS.md")" \
        "the retargeted symlink is preserved, not force-discarded"
}

# A dirty REGULAR file alongside a stale-attr symlink still blocks (AC#3). The
# residue filter must subtract only the symlink line; the regular file keeps the
# residue non-empty, so the load-bearing gate survives the carve-out.
test_worktree_rm_refuses_dirty_regular_file_beside_symlink() {
    local sb blob
    _sandbox_with_symlink sb AGENTS.md CLAUDE.md || return 1
    run_in "$sb" "$WT_NEW" 62
    assert_exit 0 "$RUN_RC" "worktree-new succeeds with a committed symlink"
    blob="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb/.worktrees/issue-62" rev-parse HEAD:AGENTS.md 2>/dev/null || true)"
    command printf 'UNCOMMITTED USER WORK\n' >>"$sb/.worktrees/issue-62/seed.txt"
    _plant_git_raw_stub "$sb" "$blob" AGENTS.md
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 62 2>&1)" || RUN_RC=$?
    assert_exit 1 "$RUN_RC" "a dirty regular file still blocks despite a stale symlink"
    assert_file_contains "$sb/.worktrees/issue-62/seed.txt" "UNCOMMITTED USER WORK" \
        "the uncommitted work is preserved, not force-discarded (AC#3)"
}

# A path committed as a REGULAR FILE but replaced on disk by a symlink is a type
# change, not a stat artifact, and must still block teardown.
#
# HONEST SCOPE OF THIS TEST. It pins the OUTCOME, not the helper's index-side
# mode gate. git classifies a type change ` T `, and the residue filter only
# routes ` M ` lines to the helper, so this case refuses via the residue path
# without `symlink_is_false_dirty` ever being called. Neutering the
# `src_mode = 120000` check therefore leaves this test — and every other — green.
#
# That surviving mutation was chased rather than papered over
# ([[surviving-mutation-may-be-a-real-no-op]]). The probe: of the states a
# symlink-on-disk path can carry, a retarget is ` M ` and a file->link swap is
# ` T `, so whenever the helper IS reached `src_mode` is necessarily `120000`.
# The gate is unreachable defensive depth via the shipped call path — kept
# because the helper is a standalone predicate that must be correct if it is ever
# called from a second site, but deliberately NOT claimed as tested. Writing a
# test that "covers" it through the shipped path would be a test that cannot
# fail.
test_worktree_rm_refuses_file_replaced_by_symlink() {
    local sb
    _sandbox_with_symlink sb AGENTS.md CLAUDE.md || return 1
    run_in "$sb" "$WT_NEW" 65
    assert_exit 0 "$RUN_RC" "worktree-new succeeds with a committed symlink"
    # seed.txt is committed as a REGULAR file by new_sandbox; swap it for a link.
    command rm -f "$sb/.worktrees/issue-65/seed.txt"
    (cd "$sb/.worktrees/issue-65" && command ln -s CLAUDE.md seed.txt)
    run_in "$sb" "$WT_RM" 65
    assert_exit 1 "$RUN_RC" "worktree-rm refuses a regular file replaced by a symlink"
    assert_contains "$RUN_OUT" "uncommitted changes" "explains there are uncommitted changes"
    assert_true "[ -L '$sb/.worktrees/issue-65/seed.txt' ]" \
        "the type change is preserved, not force-discarded"
}

# A DELETED symlink is real work, not a stat artifact — the helper requires the
# path to still be a symlink on disk, so teardown must refuse.
test_worktree_rm_refuses_deleted_symlink() {
    local sb
    _sandbox_with_symlink sb AGENTS.md CLAUDE.md || return 1
    run_in "$sb" "$WT_NEW" 63
    assert_exit 0 "$RUN_RC" "worktree-new succeeds with a committed symlink"
    command rm -f "$sb/.worktrees/issue-63/AGENTS.md"
    run_in "$sb" "$WT_RM" 63
    assert_exit 1 "$RUN_RC" "worktree-rm refuses a worktree with a deleted symlink"
    assert_contains "$RUN_OUT" "uncommitted changes" "explains there are uncommitted changes"
}

# An ORDINARY clean teardown must not gain a spurious stale-symlink line — the
# disclosure fires only when the carve-out was actually used. Without this, the
# AC#4 assertion above could pass on a script that printed the line always.
test_worktree_rm_clean_teardown_has_no_symlink_disclosure() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 64
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    run_in "$sb" "$WT_RM" 64
    assert_exit 0 "$RUN_RC" "ordinary teardown succeeds"
    assert_not_contains "$RUN_OUT" "stale symlink attr" \
        "a clean teardown does not claim to have forced past stale symlinks"
}

# A stale core.worktree in the MAIN config pointing at a non-existent path is
# repaired: unset + rev-parse --is-inside-work-tree true again (#258).
test_worktree_rm_repairs_stale_core_worktree() {
    local sb
    new_sandbox sb
    # Simulate the corruption an interrupted `git worktree remove --force`
    # leaves behind: core.worktree pointing at a now-deleted worktree path.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" config core.worktree "$sb/.worktrees/issue-99"
    run_in "$sb" "$WT_RM" 99
    assert_exit 0 "$RUN_RC" "worktree-rm exits 0 while repairing a stale core.worktree"
    assert_contains "$RUN_OUT" "repaired stale core.worktree" "reports the repair"
    local val inside
    val="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" config --get core.worktree || true)"
    assert_equals "" "$val" "the stale core.worktree is unset after repair"
    inside="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" rev-parse --is-inside-work-tree 2>/dev/null || true)"
    assert_equals "true" "$inside" "the main checkout is a work tree again after repair"
}

# A core.worktree pointing at an EXISTING path is left untouched — no
# false-positive repair (#258).
test_worktree_rm_preserves_valid_core_worktree() {
    local sb
    new_sandbox sb
    # Point core.worktree at a path that exists on disk (the sandbox itself).
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" config core.worktree "$sb"
    run_in "$sb" "$WT_RM" 99
    assert_exit 0 "$RUN_RC" "worktree-rm exits 0 with a valid core.worktree"
    local val
    val="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" config --get core.worktree || true)"
    assert_equals "$sb" "$val" "a valid, existing core.worktree is left untouched"
}
