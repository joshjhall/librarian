# shellcheck shell=bash
# pane idle read backed by the #949 work registry (#1097) — golem-gate-watch
# tests (issue #564 split).
#
# The pane channel used to decide "own work pending" from footer TEXT alone
# (OWN_WORK_RE), so every Claude Code footer redesign re-opened the false "idle
# at prompt" push (#517, #890, #1089). pane_registry_has_work backs it with the
# registry a golem writes when it starts background work. These cases pin the
# three properties the issue asks for: a live entry suppresses the idle line
# whatever the footer shows; no/expired/completed entries do NOT (the backstop
# is not a blanket mute); and an unreadable registry, or a read that hangs past
# its bound, yields exactly today's output (the detector fails OPEN).
#
# Own file rather than 30-helpers-and-modes.sh, which had 13 production LOC of
# headroom left under the shell warning budget.
#
# Sourced by tests/golem-gate-watch.sh, which defines GATE_WATCH and sources
# tests/lib/gate-watch-sandbox.sh first.

# The footer under test matches NO OWN_WORK_RE alternative: the background
# `git push` shape (`· 1 shell ·`) observed on 2026-10-03. Every case below
# therefore turns on the registry alone.
_REG_PANE="⏺ pushing"$'\n'"  ⏵⏵ auto mode on · 1 shell ·"
_REG_IDLE="golem-9"$'\t'"⚠ idle at prompt — turn ended, awaiting input (check pane)"

# _reg_line <epoch> [id] — one `register` record for golem-9.
_reg_line() {
    command printf '{"event":"register","id":"%s","golem":"golem-9","kind":"bash","description":"git push","started":"2026-01-01T00:00:00Z","started_epoch":%s}' \
        "${2:-work-1-aaaa}" "$1"
}

# _run_panes_registry <pane> <registry> [gate-watch] — run the pane channel
# against ONE tmux session (golem-9) whose worktree is a REAL linked worktree
# (`count --worktree` derives the golem id and status dir through `git rev-parse
# --git-common-dir`; a mkdir-ed path would read an empty registry and every case
# would pass while exercising nothing — the #949 fixture lesson).
#
# <registry>: empty = no file; the literal DIR = a directory at the registry path
# (unreadable as a file — tests may run as root, where chmod 000 reads fine);
# anything else = the file's contents. [gate-watch] defaults to $GATE_WATCH; the
# mutation and bound cases pass a copy. Mode comes from $GW_MODE (default
# --once-panes). Sets REG_OUT / REG_RC.
#
# PATH carries real sleep + mktemp + cat (bounded_run's output relay) so
# bounded_run is genuinely armed — except in --stream-panes, whose `sleep` must
# be the poll stub; there mktemp is withheld so bounded_run_available is false and
# the unbounded (still correct) path runs, rather than the watcher calling the
# poll stub.
_run_panes_registry() {
    local pane="$1" registry="$2" gw="${3:-$GATE_WATCH}"
    local tmp
    tmp="$(command mktemp -d)" || return 1
    tmp="$(cd "$tmp" && command pwd -P)" || return 1
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    local git_scrub=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)
    local g=(/usr/bin/env "${git_scrub[@]/#/-u}" git -C "$tmp")
    "${g[@]}" init -q 2>/dev/null || return 1
    "${g[@]}" config user.email "test@example.com" 2>/dev/null
    "${g[@]}" config user.name "Test" 2>/dev/null
    command printf 'seed\n' >"$tmp/seed.txt"
    "${g[@]}" add seed.txt 2>/dev/null
    "${g[@]}" -c commit.gpgsign=false commit -qm seed 2>/dev/null || return 1
    "${g[@]}" worktree add -q "$tmp/.worktrees/issue-9" -b issue-9 >/dev/null 2>&1 || return 1
    command mkdir -p "$tmp/.worktrees/.status"
    # Status cache so the liveness sweep enumerates golem-9.
    command printf '%s\n' '{"golem":"golem-9","issue":9}' >"$tmp/.worktrees/.status/golem-9.json"
    case "$registry" in
        '') ;;
        DIR) command mkdir -p "$tmp/.worktrees/.status/golem-9.work.jsonl" ;;
        *) command printf '%s\n' "$registry" >"$tmp/.worktrees/.status/golem-9.work.jsonl" ;;
    esac

    local stub_bin="$tmp/stub-bin" mode_args b
    command mkdir -p "$stub_bin"
    for b in bash git jq; do
        command -v "$b" >/dev/null 2>&1 && command ln -s "$(command -v "$b")" "$stub_bin/$b"
    done
    read -r -a mode_args <<<"${GW_MODE:---once-panes}"
    if [ "${mode_args[0]}" = "--stream-panes" ]; then
        _write_poll_stub "$stub_bin" "$tmp/polls"
    else
        for b in sleep mktemp cat; do
            command ln -s "$(command -v "$b")" "$stub_bin/$b"
        done
    fi
    command cat >"$stub_bin/tmux" <<'TMUX_STUB'
#!/usr/bin/env bash
case "$1" in
    ls) command printf '%s\n' "golem-9: 1 windows" ;;
    capture-pane) command printf '%s\n' "$FAKE_PANE_TEXT" ;;
    *) exit 0 ;;
esac
TMUX_STUB
    command chmod +x "$stub_bin/tmux"

    REG_RC=0
    (
        cd "$tmp" &&
            bounded_run 60 /usr/bin/env "${git_scrub[@]/#/-u}" -uBASH_ENV \
                PATH="$stub_bin" FAKE_PANE_TEXT="$pane" \
                GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
                GOLEM_BLOCK_TTL=3600 GOLEM_STALL_THRESHOLD=1200 \
                GOLEM_PANE_REGISTRY_TIMEOUT="${GOLEM_PANE_REGISTRY_TIMEOUT:-3}" \
                "$(command -v bash)" "$gw" "${mode_args[@]}"
    ) >"$tmp/out" 2>/dev/null && REG_RC=0 || REG_RC=$?
    REG_OUT="$(command cat "$tmp/out")"
}
REG_OUT=""
REG_RC=""

# _reg_scripts_copy <dest> — a private copy of the scripts dir, so a case can
# mutate gate-watch or stub golem-work.sh (SCRIPT_DIR resolves from the script's
# own path, so the copy calls its sibling copies).
_reg_scripts_copy() {
    command cp -R "$REPO_ROOT/plugins/workflow/scripts" "$1"
}

# AC1 — THE POINT OF THE CHANGE. A footer no OWN_WORK_RE alternative matches, on
# a golem with a live registered job, is NOT reported idle.
test_pane_registry_live_entry_suppresses_idle() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (registry read no-ops without jq)"
        return 0
    fi
    _run_panes_registry "$_REG_PANE" "$(_reg_line "$(command date -u +%s)")"
    assert_equals "0" "$REG_RC" "--once-panes exits 0 with a live registry entry"
    assert_not_contains "$REG_OUT" "idle at prompt" \
        "A live registered job suppresses the idle line whatever the footer shows (#1097)"
    assert_not_contains "$REG_OUT" "golem-9" \
        "The suppression is silent, like pane_pending_own_work's (no golem line)"
}

# AC2 — THE CONTROL. Same pane, no registry: idle IS reported. Without this the
# case above could pass on a matcher that never says idle.
test_pane_registry_absent_reports_idle() {
    _run_panes_registry "$_REG_PANE" ""
    assert_equals "0" "$REG_RC" "--once-panes exits 0 with no registry"
    assert_contains "$REG_OUT" "$_REG_IDLE" \
        "No registry entry: the unmatched footer is still reported idle (not a blanket mute)"
}

# AC2 — an entry past GOLEM_WORK_MAX_AGE (default 3600) is reaped on read, and a
# registered-then-completed one is closed: neither may suppress.
test_pane_registry_expired_or_completed_reports_idle() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (registry read no-ops without jq)"
        return 0
    fi
    local now
    now="$(command date -u +%s)"
    _run_panes_registry "$_REG_PANE" "$(_reg_line "$((now - 7200))")"
    assert_contains "$REG_OUT" "$_REG_IDLE" \
        "Only an expired entry: idle is reported (the age-out bound holds)"

    _run_panes_registry "$_REG_PANE" "$(command printf '%s\n%s' \
        "$(_reg_line "$now" work-1-cccc)" \
        '{"event":"complete","id":"work-1-cccc","golem":"golem-9","ts":"2026-01-01T00:00:00Z"}')"
    assert_contains "$REG_OUT" "$_REG_IDLE" \
        "A registered-then-completed job does not suppress idle"
}

# AC3 — an unreadable registry produces EXACTLY today's output: byte-compare it
# against the no-registry run rather than asserting a substring.
test_pane_registry_unreadable_is_todays_output() {
    local baseline
    _run_panes_registry "$_REG_PANE" ""
    baseline="$REG_OUT"
    _run_panes_registry "$_REG_PANE" DIR
    assert_equals "0" "$REG_RC" "--once-panes exits 0 with an unreadable registry"
    assert_equals "$baseline" "$REG_OUT" \
        "An unreadable registry yields output byte-identical to no registry (fails open)"
    assert_contains "$REG_OUT" "$_REG_IDLE" "...and that output is the idle line"
}

# A live entry must never mute a REAL gate: the registry is consulted only in the
# turn-end branch, after every modal matcher.
test_pane_registry_never_mutes_a_gate() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (registry read no-ops without jq)"
        return 0
    fi
    _run_panes_registry "Do you want to proceed?"$'\n'"  ⏵⏵ auto mode on" \
        "$(_reg_line "$(command date -u +%s)")"
    assert_contains "$REG_OUT" "golem-9"$'\t'"permission gate — awaiting decision" \
        "A permission gate still surfaces with live registered work"
}

# The push channel end-to-end: across several --stream-panes polls (past the #447
# debounce) a live entry never pushes idle; the control does.
test_pane_registry_stream_panes() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (registry read no-ops without jq)"
        return 0
    fi
    GW_MODE="--stream-panes" GW_POLLS=3 \
        _run_panes_registry "$_REG_PANE" "$(_reg_line "$(command date -u +%s)")"
    assert_contains "$REG_OUT" "[poll3]" "The stream ran past the two-poll debounce"
    assert_not_contains "$REG_OUT" "idle at prompt" \
        "--stream-panes never pushes idle for a golem with live registered work"

    GW_MODE="--stream-panes" GW_POLLS=3 _run_panes_registry "$_REG_PANE" ""
    assert_contains "$REG_OUT" "$_REG_IDLE" \
        "Control: with no registry the confirmed idle IS pushed"
}

# The pull channel stays consistent: the liveness sweep's pane-idle verdict also
# yields to a live entry (falling through to the transcript/registry tier).
test_pane_registry_liveness_consistent() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (registry read no-ops without jq)"
        return 0
    fi
    GW_MODE="--once-liveness" \
        _run_panes_registry "$_REG_PANE" "$(_reg_line "$(command date -u +%s)")"
    assert_contains "$REG_OUT" "golem-9" "The golem appears in the liveness sweep"
    assert_not_contains "$REG_OUT" "idle at prompt" \
        "--once-liveness does not call a golem with live registered work idle"

    GW_MODE="--once-liveness" _run_panes_registry "$_REG_PANE" ""
    assert_contains "$REG_OUT" "idle at prompt" \
        "Control: with no registry the pane-idle verdict stands"
}

# AC4 — MUTATION. Remove the registry guard from panes_snapshot and the AC1
# fixture must report idle again; otherwise AC1 passes on something else.
test_pane_registry_mutation_removes_guard() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (registry read no-ops without jq)"
        return 0
    fi
    local mut guard
    mut="$(command mktemp -d)" || return 1
    _reg_scripts_copy "$mut/scripts"
    # shellcheck disable=SC2016  # the literal source text being removed
    guard=' && ! pane_registry_has_work "${sess#golem-}"'
    assert_contains "$(command cat "$mut/scripts/golem-gate-watch.sh")" "$guard" \
        "Vacuity guard: the guard text exists to be removed"
    command sed -e 's/ \&\& ! pane_registry_has_work "\${sess#golem-}"//' \
        "$mut/scripts/golem-gate-watch.sh" >"$mut/gw.tmp"
    command mv "$mut/gw.tmp" "$mut/scripts/golem-gate-watch.sh"
    assert_not_contains "$(command cat "$mut/scripts/golem-gate-watch.sh")" "$guard" \
        "Vacuity guard: the mutation actually removed the guard"

    _run_panes_registry "$_REG_PANE" "$(_reg_line "$(command date -u +%s)")" \
        "$mut/scripts/golem-gate-watch.sh"
    assert_contains "$REG_OUT" "$_REG_IDLE" \
        "Mutant without the registry guard reports idle: the AC1 test is not vacuous"
    command rm -rf "$mut"
}

# The read is BOUNDED and fails open: a golem-work.sh that would answer "1 open"
# only after 20s is cut off at GOLEM_PANE_REGISTRY_TIMEOUT=1, and the idle line is
# emitted. The stub's late "1" is what makes this discriminating — an unbounded
# read would wait for it and suppress.
test_pane_registry_bounded_read_fails_open() {
    local cp start elapsed
    cp="$(command mktemp -d)" || return 1
    _reg_scripts_copy "$cp/scripts"
    command printf '%s\n' '#!/usr/bin/env bash' 'command sleep 20' 'command echo 1' \
        >"$cp/scripts/golem-work.sh"
    command chmod +x "$cp/scripts/golem-work.sh"

    start="$(command date +%s)"
    GOLEM_PANE_REGISTRY_TIMEOUT=1 \
        _run_panes_registry "$_REG_PANE" "" "$cp/scripts/golem-gate-watch.sh"
    elapsed=$(($(command date +%s) - start))
    assert_contains "$REG_OUT" "$_REG_IDLE" \
        "A registry read past its bound fails open: idle is reported, not suppressed"
    assert_true "[ $elapsed -lt 15 ]" "The bound fired well before the stub's 20s (took ${elapsed}s)"
    command rm -rf "$cp"
}
