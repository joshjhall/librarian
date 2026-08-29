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

# --- #813: the dirty gate must precede the mutation and classify three ways ---

# Slice worktree_dirty_state out of the script and drive it directly, the same
# way run_kill_outcome slices the tmux classifier. Runs in the caller's cwd so a
# relative worktree path resolves the way the script uses it.
run_dirty_state() {
    /usr/bin/env --unset=BASH_ENV "$REAL_BASH" -c '
        eval "$(command sed -n "/^worktree_dirty_state() {/,/^}/p" "$1")"
        worktree_dirty_state "$2"
    ' _ "$WT_RM" "$1" 2>&1
}

# The three-way classifier (#813). The two-way "empty status means clean" read
# this replaces is what produced a false `has uncommitted changes`: a probe that
# could not run returned empty, empty read as clean, and the force-remove that
# followed then failed into the dirty branch.
#
# The `unverifiable` cases are the point. Asserting only clean/dirty would pass
# against the OLD two-way logic too, so they are what give this test teeth.
test_worktree_rm_dirty_state_classifier() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 80
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"

    local st
    st="$(cd "$sb" && run_dirty_state ".worktrees/issue-80")"
    assert_equals "clean" "$st" "a fresh worktree classifies clean"

    command printf 'work\n' >>"$sb/.worktrees/issue-80/seed.txt"
    st="$(cd "$sb" && run_dirty_state ".worktrees/issue-80")"
    assert_equals "dirty" "$st" "a modified tracked file classifies dirty"

    # A path that is not a worktree at all cannot be probed.
    st="$(cd "$sb" && run_dirty_state ".worktrees/issue-does-not-exist")"
    assert_equals "unverifiable" "$st" "a missing path is unverifiable, never clean"

    # The reported state: the admin dir is gone, so the worktree's .git file
    # dangles and `git status` reports `fatal: not a git repository: (null)`.
    # The old code mapped that to empty and read it as CLEAN.
    command rm -rf "$sb/.git/worktrees/issue-80"
    st="$(cd "$sb" && run_dirty_state ".worktrees/issue-80")"
    assert_equals "unverifiable" "$st" \
        "a deregistered worktree is unverifiable, never clean"

    # The walk-up case: with the .git file gone entirely, git resolves the MAIN
    # checkout and answers about the WRONG repo — non-empty output that would
    # read as this worktree's dirtiness. The toplevel-anchor guard catches it.
    command rm -f "$sb/.worktrees/issue-80/.git"
    st="$(cd "$sb" && run_dirty_state ".worktrees/issue-80")"
    assert_equals "unverifiable" "$st" \
        "a directory whose git resolves the MAIN repo is unverifiable, not dirty"
}

# Regression (#813), the reported bug: a CLEAN worktree that git no longer lists
# must never be reported as having uncommitted changes. Before the fix the probe
# failed, read as clean, the force-remove failed `not a working tree`, and the
# else-arm printed the false claim.
#
# It also must not be skipped: the removal block used to be gated entirely on the
# worktree being listed, so a leftover directory was never cleaned and a re-run
# said "nothing to remove" while the directory sat on disk.
test_worktree_rm_deregistered_clean_is_not_reported_dirty() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 81
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    # Deregister exactly as an interrupted/failed `git worktree remove` does.
    command rm -rf "$sb/.git/worktrees/issue-81"

    run_in "$sb" "$WT_RM" 81
    assert_exit 0 "$RUN_RC" "worktree-rm succeeds on a deregistered clean worktree"
    assert_not_contains "$RUN_OUT" "uncommitted changes" \
        "never claims uncommitted changes for a state it could not probe"
    assert_contains "$RUN_OUT" "no longer registered" "names the actual state"
    assert_true "[ ! -e '$sb/.worktrees/issue-81' ]" \
        "the leftover directory is removed rather than skipped"
    local branches
    branches="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" branch --list "feature/issue-81")"
    assert_equals "" "$branches" "teardown continues to the branch after the leftover cleanup"
}

# Regression (#813), the walk-up half END TO END: with the worktree's own `.git`
# file broken, git walks UP and resolves the MAIN checkout, so an unanchored
# probe reports MAIN's untracked files as this worktree's uncommitted work — a
# refusal that looks legitimate while describing a different tree entirely.
#
# The ADMIN DIR IS LEFT INTACT ON PURPOSE, and that is the whole design of this
# fixture. Removing it (the obvious way to break the worktree) flips `listed` to
# 0 and routes the run into the leftover-directory branch, which refuses on the
# fingerprint check WITHOUT EVER CALLING worktree_dirty_state — so the
# assert_not_contains below would pass trivially, green whether or not the
# walk-up guard exists. Keeping the worktree listed is what forces execution
# through the classifier and gives this test teeth. (Verified: with the
# toplevel-anchor guard neutered, this test goes red.)
test_worktree_rm_leftover_dir_does_not_probe_main_repo() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 82
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    # REMOVE the worktree-side .git file but leave .git/worktrees/issue-82 in
    # place, so the worktree stays REGISTERED (classifier is consulted) while
    # git has nothing to resolve locally and walks UP to the main checkout.
    # Verified this is the genuine walk-up: `rev-parse --show-toplevel` from the
    # worktree answers with the MAIN root, and `status --porcelain` there
    # returns main's own `?? .worktrees/` — i.e. an unanchored probe would call
    # this worktree dirty on the strength of the main checkout's untracked files.
    #
    # Note a `.git` file pointing at the main `.git` does NOT reproduce this
    # (git resolves it correctly via core.worktree and reads clean); only the
    # absent pointer produces the walk-up.
    command rm -f "$sb/.worktrees/issue-82/.git"
    # An untracked file in MAIN — what the walk-up probe would wrongly report.
    command printf 'main-only\n' >"$sb/untracked-in-main.txt"

    run_in "$sb" "$WT_RM" 82
    assert_exit 1 "$RUN_RC" "an unprobeable worktree is refused, not removed"
    # The load-bearing assertion: whatever teardown decides, it must never
    # describe MAIN's untracked files as this worktree's dirtiness. Anchored on
    # the sentence start, because the correct "cannot verify whether X has
    # uncommitted changes" message legitimately contains the bare phrase.
    assert_not_contains "$RUN_OUT" "worktree-rm: .worktrees/issue-82 has uncommitted" \
        "main's untracked files are never reported as the worktree's dirtiness"
    assert_contains "$RUN_OUT" "cannot verify" "reports the unverifiable state instead"
    assert_file_exists "$sb/untracked-in-main.txt" "the main checkout is left untouched"
}

# The fingerprint gate end to end (#813 review): a leftover directory with no
# `.git` at all may never have been a worktree, so it is refused rather than
# deleted. Split out of the walk-up test above, which used to conflate the two
# by deleting both the admin dir and the .git file.
test_worktree_rm_leftover_dir_without_fingerprint_is_refused() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 85
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command rm -rf "$sb/.git/worktrees/issue-85"
    command rm -f "$sb/.worktrees/issue-85/.git"

    run_in "$sb" "$WT_RM" 85
    assert_exit 1 "$RUN_RC" "a directory with no worktree fingerprint is refused, not deleted"
    assert_contains "$RUN_OUT" "has no .git entry" \
        "the refusal names the FINGERPRINT as the reason, not a generic message"
    assert_true "[ -e '$sb/.worktrees/issue-85' ]" \
        "the unrecognized directory is left in place for inspection"
}

# A SYMLINK at the worktree path is never residue (#813 review). Only the parent
# is canonicalized, so a symlinked leaf would otherwise keep an in-repo-looking
# path for the containment check while the fingerprint test followed the link to
# an out-of-tree `.git` — containment satisfied by a lie. The fixture gives the
# target a `.git` ON PURPOSE so the fingerprint alone cannot refuse it, leaving
# the symlink guard as the only thing that can.
test_worktree_rm_refuses_a_symlinked_worktree_path() {
    local sb outside
    new_sandbox sb
    outside="$(command mktemp -d "$WORKDIR/linktarget.XXXXXX")" || return 1
    command printf 'OUTSIDE VIA SYMLINK\n' >"$outside/precious.txt"
    command touch "$outside/.git"
    command mkdir -p "$sb/.worktrees"
    command ln -s "$outside" "$sb/.worktrees/issue-86"

    run_in "$sb" "$WT_RM" 86
    assert_exit 1 "$RUN_RC" "a symlink at the worktree path is refused"
    assert_file_contains "$outside/precious.txt" "OUTSIDE VIA SYMLINK" \
        "the symlink target's contents are never touched"
    assert_true "[ -L '$sb/.worktrees/issue-86' ]" "the symlink itself is left in place"
}

# Path safety for the leftover-directory cleanup (#813 review). "git does not
# list it" is NOT sufficient evidence to `rm -rf` a path: before this change an
# unlisted path was never touched at all, so the cleanup is the script's first
# unconditional recursive delete and has to earn it.
#
# Each case below is a distinct data-loss vector, and each is verified by the
# SURVIVAL of a file that only exists to be destroyed — an assertion that cannot
# pass if the guard is removed.
test_worktree_rm_refuses_to_delete_a_non_worktree_directory() {
    local sb
    new_sandbox sb
    # A directory at the predictable worktree path that was NEVER a worktree:
    # an operator's scratch dir, a stray editor copy, or a worktree-new.sh run
    # that died after mkdir but before `git worktree add`. It holds real,
    # never-tracked work that no git probe can see.
    command mkdir -p "$sb/.worktrees/issue-77"
    command printf 'IRREPLACEABLE USER WORK\n' >"$sb/.worktrees/issue-77/notes.txt"

    run_in "$sb" "$WT_RM" 77
    assert_exit 1 "$RUN_RC" "a directory with no .git fingerprint is refused"
    assert_contains "$RUN_OUT" "has no .git entry" \
        "the refusal names the FINGERPRINT as the reason"
    assert_file_contains "$sb/.worktrees/issue-77/notes.txt" "IRREPLACEABLE USER WORK" \
        "never-tracked work in a non-worktree directory survives teardown"
}

# The containment half: GOLEM_WORKTREE_DIR is env-overridable and never
# validated, so an absolute value makes `$wt` absolute and would aim the
# `rm -rf` outside the repo entirely. The fixture gives the target a `.git`
# fingerprint ON PURPOSE, so the fingerprint check alone cannot save it and only
# containment can — without that, this test would pass for the wrong reason.
test_worktree_rm_refuses_a_worktree_dir_outside_the_repo() {
    local sb outside
    new_sandbox sb
    outside="$(command mktemp -d "$WORKDIR/outside.XXXXXX")" || return 1
    command mkdir -p "$outside/issue-55"
    command printf 'OUTSIDE THE REPO\n' >"$outside/issue-55/precious.txt"
    command touch "$outside/issue-55/.git"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR="$outside" \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 55 2>&1)" || RUN_RC=$?

    assert_exit 1 "$RUN_RC" "a target resolving outside the repo root is refused"
    assert_contains "$RUN_OUT" "resolves outside the repo root" \
        "the refusal names CONTAINMENT as the reason"
    assert_file_contains "$outside/issue-55/precious.txt" "OUTSIDE THE REPO" \
        "a path outside the repo is never deleted, even with a .git fingerprint"
}

# The end-to-end `unverifiable` refusal (#813 review, coverage gap). The two
# other e2e tests both remove the admin dir, which flips `listed` to 0 and
# routes into the leftover path — so neither ever reaches the branch that fires
# when git STILL LISTS the worktree but the probe cannot be evaluated. That
# branch prints the operator-facing "still registered" guidance, so its wording
# and exit code deserve a test of their own.
test_worktree_rm_listed_but_unprobeable_refuses_with_cannot_verify() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 84
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    # Leave the ADMIN dir intact (so the worktree stays listed) but break the
    # working-tree side, so rev-parse cannot resolve it.
    command printf 'gitdir: /nonexistent/admin/dir\n' >"$sb/.worktrees/issue-84/.git"

    run_in "$sb" "$WT_RM" 84
    assert_exit 1 "$RUN_RC" "a listed but unprobeable worktree is refused"
    assert_contains "$RUN_OUT" "cannot verify" "says it cannot verify, not that it is dirty"
    # Anchoring this absence is genuinely fiddly, and the two obvious spellings
    # are both WRONG — worth recording so nobody "fixes" it back:
    #
    #   has uncommitted changes            appears inside the CORRECT message
    #   issue-84 has uncommitted changes   ditto — "cannot verify whether
    #                                      .worktrees/issue-84 has uncommitted
    #                                      changes" ends in exactly that
    #
    # The dirty claim and its negation share their whole tail, so no
    # path-plus-phrase anchor can separate them. What differs is the SENTENCE
    # START: the false claim is `worktree-rm: <path> has uncommitted changes.`,
    # with the script's own `worktree-rm: ` prefix immediately before the path.
    assert_not_contains "$RUN_OUT" "worktree-rm: .worktrees/issue-84 has uncommitted" \
        "never claims dirtiness for a condition it could not evaluate"
    assert_true "[ -e '$sb/.worktrees/issue-84' ]" "the worktree is left in place for inspection"
    assert_true "[ -e '$sb/.git/worktrees/issue-84' ]" \
        "the still-registered worktree is not deregistered by the refusal"
}

# Regression (#813), the reorder itself: a genuinely dirty worktree must be
# refused BEFORE anything is mutated. The still-registered assertion is what
# pins the ordering — under the old mutate-then-check code the failed
# `git worktree remove` had already deregistered the worktree by the time the
# refusal printed, leaving the operator unable to run the very `git status` the
# message asks them to act on.
test_worktree_rm_dirty_refusal_leaves_worktree_registered() {
    local sb
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 83
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command printf 'REAL USER WORK\n' >>"$sb/.worktrees/issue-83/seed.txt"

    run_in "$sb" "$WT_RM" 83
    assert_exit 1 "$RUN_RC" "worktree-rm still refuses a genuinely dirty worktree"
    assert_contains "$RUN_OUT" "uncommitted changes" "reports the real dirtiness"
    assert_file_contains "$sb/.worktrees/issue-83/seed.txt" "REAL USER WORK" \
        "the uncommitted work is preserved"

    # The load-bearing half: the refusal happened before any mutation, so the
    # worktree is still registered and the operator's own `git status` works.
    local listed
    listed="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" worktree list --porcelain | command grep -c "issue-83" || true)"
    assert_true "[ '$listed' -gt 0 ]" \
        "the worktree is still registered after the refusal (check ran before the mutation)"
    assert_true "[ -e '$sb/.git/worktrees/issue-83' ]" \
        "the worktree admin dir survives the refusal"

    # And the refusal no longer advertises a blind --force, which is exactly what
    # a careful operator must not run when the claim cannot be verified.
    assert_not_contains "$RUN_OUT" "worktree remove --force" \
        "the refusal does not advertise a blind --force"
}

# The clean-but-unremovable branch (#813 review cycle 3). When the tree is
# classified CLEAN but both `git worktree remove` and its `--force` retry fail
# — the FUSE/bindfs undeletable-path case #834 tracks — teardown must report
# what GIT actually said, never the false dirtiness claim this issue is about.
#
# A `git` stub is what makes this drivable: it forwards every subcommand to the
# real git EXCEPT `worktree remove`, which it fails with a recognizable message.
# The tree is genuinely clean, so the classifier passes it through and the
# failure lands squarely on the new branch.
test_worktree_rm_clean_but_unremovable_reports_gits_error() {
    local sb real_git
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 87
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"

    real_git="$(command -v git)"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<EOF
#!/usr/bin/env bash
# Test stub: fail only \`worktree remove\`; forward everything else to real git.
if [ "\${1:-}" = "worktree" ] && [ "\${2:-}" = "remove" ]; then
    command echo "fatal: STUBBED REMOVAL FAILURE" >&2
    exit 128
fi
exec "$real_git" "\$@"
EOF
    command chmod +x "$sb/bin/git"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            PATH="$sb/bin:$PATH" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 87 2>&1)" || RUN_RC=$?

    assert_exit 1 "$RUN_RC" "an unremovable clean worktree exits 1"
    assert_contains "$RUN_OUT" "the tree was verified clean" \
        "says the tree was clean rather than claiming uncommitted changes"
    assert_contains "$RUN_OUT" "STUBBED REMOVAL FAILURE" \
        "surfaces git's actual error instead of swallowing it"
    # The whole point of #813: a removal that failed for a non-dirtiness reason
    # must never be reported as dirtiness.
    assert_not_contains "$RUN_OUT" "worktree-rm: .worktrees/issue-87 has uncommitted" \
        "never reports a non-dirtiness failure as uncommitted changes"
}

# The re-read guard (#813 review cycle 3). Between the classifier's `dirty`
# verdict and the second status read that fetches the LINES, a failure must not
# fall through to `clean` — that would be this issue's own bug one layer down,
# and ending in a force-remove rather than a false refusal.
#
# The stub makes the FIRST status call succeed (so the classifier says dirty)
# and every later one fail, which is exactly the window being guarded.
test_worktree_rm_status_reread_failure_refuses() {
    local sb real_git
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 88
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command printf 'REAL USER WORK\n' >>"$sb/.worktrees/issue-88/seed.txt"

    real_git="$(command -v git)"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<EOF
#!/usr/bin/env bash
# Test stub: let the FIRST \`status\` through (classifier reads dirty), then fail
# every subsequent one — the re-read the guard under test protects.
_seen="\$HOME/.status-calls"
for _a in "\$@"; do
    if [ "\$_a" = "status" ]; then
        if [ -e "\$_seen" ]; then
            command echo "fatal: STUBBED STATUS FAILURE" >&2
            exit 128
        fi
        : >"\$_seen"
        break
    fi
done
exec "$real_git" "\$@"
EOF
    command chmod +x "$sb/bin/git"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            PATH="$sb/bin:$PATH" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 88 2>&1)" || RUN_RC=$?

    assert_exit 1 "$RUN_RC" "a failed status re-read refuses rather than falling through"
    assert_contains "$RUN_OUT" "cannot re-read the status" "names the re-read failure"
    assert_file_contains "$sb/.worktrees/issue-88/seed.txt" "REAL USER WORK" \
        "the uncommitted work is preserved, never force-removed"
    assert_true "[ -e '$sb/.worktrees/issue-88' ]" "the worktree is left in place"
}

# The refusal message must name the guard that ACTUALLY tripped (#813 review
# cycle 3). A symlinked path can legitimately carry a valid `.git` at its target
# and resolve inside the root, so the fingerprint/containment wording would be
# false on both counts — misreporting a state you did not evaluate is the very
# defect this issue exists to fix.
test_worktree_rm_residue_refusal_names_the_actual_reason() {
    local sb outside
    new_sandbox sb

    # symlink -> a target that HAS a .git, so only the symlink guard can refuse.
    outside="$(command mktemp -d "$WORKDIR/reason.XXXXXX")" || return 1
    command touch "$outside/.git"
    command mkdir -p "$sb/.worktrees"
    command ln -s "$outside" "$sb/.worktrees/issue-90"
    run_in "$sb" "$WT_RM" 90
    assert_exit 1 "$RUN_RC" "a symlinked path is refused"
    assert_contains "$RUN_OUT" "is a symlink" "the symlink refusal says SYMLINK"
    assert_not_contains "$RUN_OUT" "has no .git entry" \
        "does not blame a missing fingerprint the target actually has"

    # A plain directory with no .git — the fingerprint reason.
    command mkdir -p "$sb/.worktrees/issue-91"
    run_in "$sb" "$WT_RM" 91
    assert_exit 1 "$RUN_RC" "a non-worktree directory is refused"
    assert_contains "$RUN_OUT" "has no .git entry" "the fingerprint refusal says FINGERPRINT"
    assert_not_contains "$RUN_OUT" "is a symlink" "does not call a plain directory a symlink"
}

# Captured git stderr is SANITIZED before it reaches the operator's terminal
# (#813 review cycle 4). The tmux failure path in this same script already
# strips C0 controls and DEL because its message embeds a socket path; the git
# removal errors embed FILE paths and reach the terminal the same way, so a
# crafted filename would otherwise smuggle ANSI escapes or a CR line-overwrite
# into the operator's session.
#
# The stub emits a CR and an ANSI sequence in its error text. CR is the
# load-bearing one: a terminal renders it by returning the cursor to column 0,
# letting the tail of the message overwrite the warning that preceded it.
test_worktree_rm_sanitizes_git_error_text() {
    local sb real_git
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 92
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"

    real_git="$(command -v git)"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<EOF
#!/usr/bin/env bash
# Test stub: fail \`worktree remove\` with control characters in the message.
if [ "\${1:-}" = "worktree" ] && [ "\${2:-}" = "remove" ]; then
    command printf 'fatal: BEGINMARK\\033[31m\\rOVERWRITE ENDMARK\\n' >&2
    exit 128
fi
exec "$real_git" "\$@"
EOF
    command chmod +x "$sb/bin/git"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            PATH="$sb/bin:$PATH" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 92 2>&1)" || RUN_RC=$?

    assert_exit 1 "$RUN_RC" "the removal failure still exits 1"
    # The TEXT survives — sanitizing must not swallow the diagnostic.
    assert_contains "$RUN_OUT" "BEGINMARK" "the error text still reaches the operator"
    assert_contains "$RUN_OUT" "ENDMARK" "the whole message survives, not just its head"

    # The CONTROL BYTES do not. Checked with printf-built literals so the test
    # cannot accidentally assert against its own escaped source text.
    local cr esc
    cr="$(command printf '\r')"
    esc="$(command printf '\033')"
    case "$RUN_OUT" in
        *"$cr"*) assert_true "false" "a CR must not reach the terminal (line-overwrite spoofing)" ;;
        *) assert_true "true" "CR is stripped from the reported git error" ;;
    esac
    case "$RUN_OUT" in
        *"$esc"*) assert_true "false" "an ESC must not reach the terminal (ANSI injection)" ;;
        *) assert_true "true" "ESC is stripped from the reported git error" ;;
    esac
}

# The force path re-verifies (#813 review cycle 5). The up-front classification
# fixes this issue's ordering bug, but it is NOT sufficient authority to force:
# the plain removal can fail precisely BECAUSE the tree went dirty after that
# classification, and forcing on the stale verdict would silently discard work
# that landed in the window. Pre-#813 this freshness came for free, because the
# old code read status inside this same failure branch; moving the read earlier
# is what created the gap.
#
# THE FIXTURE MUST DIRTY THE TREE MID-RUN, and getting this wrong is easy: an
# earlier version of this test dirtied the file BEFORE invoking worktree-rm, so
# the UP-FRONT check refused it and the force re-verify never executed at all.
# It passed with and without the guard — a fixture that both armed and satisfied
# its own gate. The stub below is what actually reaches the force path: the tree
# is clean when the classifier reads it, and a writer lands only when git is
# asked to REMOVE it.
test_worktree_rm_force_reverifies_before_discarding() {
    local sb real_git
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 93
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"

    real_git="$(command -v git)"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<EOF
#!/usr/bin/env bash
# Test stub: the tree is clean when the classifier reads it; a concurrent writer
# lands just before the removal, exactly the window the guard covers. The plain
# removal then fails on the new dirt (git refuses without --force), so execution
# reaches the force path — where the re-check must refuse.
if [ "\${1:-}" = "worktree" ] && [ "\${2:-}" = "remove" ]; then
    command printf 'WORK THAT LANDED AFTER THE CHECK\n' \
        >>"$sb/.worktrees/issue-93/seed.txt"
fi
exec "$real_git" "\$@"
EOF
    command chmod +x "$sb/bin/git"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            PATH="$sb/bin:$PATH" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 93 2>&1)" || RUN_RC=$?

    assert_exit 1 "$RUN_RC" "teardown refuses rather than forcing past the new work"
    assert_contains "$RUN_OUT" "after it was checked" \
        "names the re-check, not the up-front classification"
    assert_file_contains "$sb/.worktrees/issue-93/seed.txt" "WORK THAT LANDED AFTER THE CHECK" \
        "work that appeared after the check is never silently discarded"
    assert_true "[ -e '$sb/.worktrees/issue-93' ]" "the worktree is left in place"
}

# The "changed between two status checks" branch (#813 review cycle 5). Distinct
# from a re-read that FAILS: here the re-read SUCCEEDS and finds nothing, i.e.
# the tree went dirty-then-clean between the two probes. Refusing is right —
# something else is writing — but the message must say that rather than claim a
# read failure that did not happen.
#
# The stub lets the classifier's first `status` through (so it reads dirty) and
# returns EMPTY, exit 0, for every later one — precisely the succeed-but-empty
# shape, which no other test produces.
test_worktree_rm_status_changed_between_checks_refuses() {
    local sb real_git
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 94
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"
    command printf 'REAL USER WORK\n' >>"$sb/.worktrees/issue-94/seed.txt"

    real_git="$(command -v git)"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<EOF
#!/usr/bin/env bash
# Test stub: first \`status\` passes through (classifier reads dirty); every
# later one SUCCEEDS with empty output — the succeed-but-empty race shape.
_seen="\$HOME/.status-calls"
for _a in "\$@"; do
    if [ "\$_a" = "status" ]; then
        if [ -e "\$_seen" ]; then
            exit 0
        fi
        : >"\$_seen"
        break
    fi
done
exec "$real_git" "\$@"
EOF
    command chmod +x "$sb/bin/git"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            PATH="$sb/bin:$PATH" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 94 2>&1)" || RUN_RC=$?

    assert_exit 1 "$RUN_RC" "a tree that changed between checks is refused"
    assert_contains "$RUN_OUT" "changed between two status checks" \
        "names the race rather than claiming a read failure"
    assert_not_contains "$RUN_OUT" "cannot re-read the status" \
        "does not report a failure that did not happen"
    assert_file_contains "$sb/.worktrees/issue-94/seed.txt" "REAL USER WORK" \
        "the work is preserved"
}

# The force-path `unverifiable` refusal (#813 review cycle 6). The force re-check
# has three outcomes — dirty (residue-filtered), clean (proceed), and anything
# else, which lands on the "could not be re-checked before forcing" refusal.
#
# That third branch is NOT hypothetical: it is the very condition this issue was
# filed about, arriving one step later. A failing `git worktree remove`
# DEREGISTERS the worktree before reporting failure (verified on git 2.55.0), so
# the re-check that follows can find a worktree git no longer resolves. Forcing
# on an unevaluable state is exactly what must not happen.
#
# The stub reproduces that sequence faithfully: the plain removal fails AND
# breaks the worktree's .git pointer, so the re-check cannot resolve it.
test_worktree_rm_force_recheck_unverifiable_refuses() {
    local sb real_git
    new_sandbox sb
    run_in "$sb" "$WT_NEW" 95
    assert_exit 0 "$RUN_RC" "worktree-new succeeds"

    real_git="$(command -v git)"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<EOF
#!/usr/bin/env bash
# Test stub: the plain \`worktree remove\` fails AND deregisters as it goes —
# the observed git behavior this issue documents. The force re-check then finds
# a worktree it cannot resolve.
if [ "\${1:-}" = "worktree" ] && [ "\${2:-}" = "remove" ]; then
    command printf 'gitdir: /nonexistent/admin/dir\n' >"$sb/.worktrees/issue-95/.git"
    command echo "fatal: STUBBED REMOVAL FAILURE" >&2
    exit 128
fi
exec "$real_git" "\$@"
EOF
    command chmod +x "$sb/bin/git"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            PATH="$sb/bin:$PATH" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "$REAL_BASH" "$WT_RM" 95 2>&1)" || RUN_RC=$?

    assert_exit 1 "$RUN_RC" "an unverifiable re-check refuses rather than forcing"
    assert_contains "$RUN_OUT" "re-check" "names the re-check as what could not be completed"
    # The defining property of this whole issue: never claim dirtiness for a
    # state the guard could not evaluate.
    assert_not_contains "$RUN_OUT" "worktree-rm: .worktrees/issue-95 has uncommitted" \
        "never claims uncommitted changes for an unevaluable state"
    assert_true "[ -e '$sb/.worktrees/issue-95' ]" "nothing is removed"
}
