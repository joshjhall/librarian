# shellcheck shell=bash
# Shared sandbox plumbing for the golem/worktree helper-script test fragments
# (issue #564 — extracted from the 5,787-line tests/validate-golem-scripts.sh).
#
# Sourced by tests/validate-golem-scripts.sh BEFORE its area fragments under
# tests/golem-scripts/. Everything here is used by two or more fragments; a
# helper used by exactly one area stays in that area's file, so this library
# does not become the next monolith.
#
# The invariants these helpers carry (do not weaken them when editing):
#
#   * Every sandbox is a fresh `git init` under the module-level WORKDIR, so a
#     script's repo_root() resolves the sandbox and never the librarian checkout.
#   * Every git call and script invocation is wrapped in
#     `/usr/bin/env "${GIT_SCRUB[@]/#/-u}"` so git's hook-exported
#     environment (GIT_DIR / GIT_COMMON_DIR / ...) cannot pin repo_root to the
#     OUTER repo when the suite runs from a `git push` pre-push hook — the
#     failure mode root-caused in golem-gate-watch (PR #62).
#   * HOME is repointed at the sandbox, because worktree-new transitively seeds
#     trust into $HOME/.claude.json via seed-worktree-trust.sh; without the
#     override a sandbox run would write the operator's real config.
#   * GOLEM_CARGO_CACHE_DIR is pointed at a nonexistent path inside the sandbox,
#     so worktree-new.sh's cargo-target seed (#944) reads as UNSUITABLE and
#     no-ops. Without it the real default (/cache) is inherited: on any machine
#     where /cache happens to exist and be writable — every devcontainer — the
#     suite would WRITE THERE and every worktree-new test would gain an extra
#     output line. Same pin-the-ambient-dependency reasoning as GOLEM_PLUGIN_PROBE
#     and TMUX_TMPDIR; the seed's own tests set it explicitly instead.
#   * GOLEM_PLUGIN_PROBE is pointed at a nonexistent path, so golem-launch.sh's
#     plugin-resolvability guard (#946) reads as UNDETERMINABLE and skips. This
#     is the truthful setting, not a mute: HOME already points at an empty
#     sandbox with no plugin install, so a real probe there correctly finds
#     nothing — every `launch` in the suite would refuse with exit 3 and each
#     test's own subject would never run. Same reasoning as the TMUX_TMPDIR
#     isolation below: pin the ambient dependency so a test asserts its own
#     subject. A test that wants the guard ACTIVE overrides this with its own
#     stub (see 10-launch.sh's write_plugin_probe / _plugin_probe_run).
#
# The consts this file depends on (SCRIPTS, LAUNCH, REAL_BASH, GIT_SCRUB, ...)
# are defined by the entry point before it sources this file.

# shellcheck disable=SC2034  # WORKDIR / RUN_RC / RUN_OUT / TRANSCRIPT_* are read by the area fragments

# Module-level scratch dir, cleaned up once when the suite exits.
# Resolved to the PHYSICAL path: on macOS $TMPDIR is under /var, a symlink to
# /private/var, so `mktemp -d` returns /var/... while `git rev-parse
# --show-toplevel` (and realpath-based guards) report /private/var/... Code
# under test that prefix-matches the two spellings never matches (#932).
WORKDIR="$(command mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && command pwd -P)"
# A SHORT-rooted parent for tmux sockets. A unix socket path is capped at 104
# bytes (sun_path, darwin), and tmux appends `tmux-<uid>/default` to
# TMUX_TMPDIR. macOS $TMPDIR is itself ~49 chars, so a per-sandbox socket under
# WORKDIR reached 109 bytes and tmux failed with `error connecting to ...
# (File name too long)` — surfacing as unrelated-looking assertion failures (a
# spurious `WARNING:` from worktree-rm). Linux /tmp is short enough that this
# never bit (#932).
TMUX_ROOT="$(command mktemp -d /tmp/lgtmux.XXXXXX 2>/dev/null)" || TMUX_ROOT=""
trap 'command rm -rf "$WORKDIR" ${TMUX_ROOT:+"$TMUX_ROOT"}' EXIT

# new_sandbox <varname>
# Creates a fresh git repo sandbox with one seed commit (so HEAD exists and can
# serve as GOLEM_BASE_REF), a `.worktrees/.status/` dir, and an empty `{}` at
# <sandbox>/.claude.json (the seed-trust target HOME is pointed at). Assigns the
# sandbox path to the caller's named variable. `git init` + the seed commit run
# with the git environment scrubbed so the sandbox is hermetic under a hook.
new_sandbox() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$dir" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$dir" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$dir" config user.name "Test"
    command printf 'seed\n' >"$dir/seed.txt"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$dir" add seed.txt 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$dir" -c commit.gpgsign=false commit -qm seed 2>/dev/null || return 1
    command mkdir -p "$dir/.worktrees/.status"
    # Per-sandbox socket dir under the SHORT root (see TMUX_ROOT above), so the
    # per-sandbox isolation property is unchanged while the path stays under the
    # 104-byte socket cap. Assigned on EVERY new_sandbox call (never `local`, and
    # never left stale) so one sandbox's socket dir cannot leak into the next.
    # Falls back to the in-sandbox dir when the short root could not be made.
    if [ -n "$TMUX_ROOT" ]; then
        SANDBOX_TMUX_DIR="$(command mktemp -d "$TMUX_ROOT/s.XXXXXX")" ||
            SANDBOX_TMUX_DIR="$dir/.tmux"
    else
        SANDBOX_TMUX_DIR="$dir/.tmux"
    fi
    # An empty, per-sandbox tmux socket dir. Pointing TMUX_TMPDIR here makes
    # `tmux ls` find no server (so golem-status/attach see ZERO sessions),
    # isolating the tests from REAL golem-* tmux sessions on the host — without
    # it, golem-status.sh's `tmux ls` picks up live golems and the empty-state
    # branch never fires.
    command mkdir -p "$dir/.tmux"
    command printf '{}\n' >"$dir/.claude.json"
    printf -v "$__out" '%s' "$dir"
}

# Captured results of the most recent invocation.
RUN_RC=0
RUN_OUT=""

# run_in <sandbox-dir> <script> [args...]
# Invokes the script from within the sandbox (so repo_root resolves there) with
# the git environment scrubbed, GOLEM_* pinned to the sandbox's worktree/status
# dirs, HOME repointed at the sandbox (so the transitive seed-trust write cannot
# touch the real ~/.claude.json), and the local-file copy disabled. Captures
# combined stdout+stderr in RUN_OUT and the exit code in RUN_RC.
run_in() {
    local dir="$1" script="$2"
    shift 2
    RUN_RC=0
    RUN_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$dir" \
            GOLEM_PLUGIN_PROBE="$dir/no-plugin-probe" \
            TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$dir/.tmux}" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            GOLEM_CARGO_CACHE_DIR="$dir/no-cargo-cache" \
            "$REAL_BASH" "$script" "$@" 2>&1)" || RUN_RC=$?
}

# inbox_in <sandbox> <inbox-args...>
# Run golem-inbox.sh from INSIDE the sandbox with the same GIT_SCRUB + status-dir
# env as run_in, so its inbox write/read resolves the sandbox repo (not the outer
# checkout). Used to seed inbox state for the golem-status annotation tests.
# GOLEM_INBOX_WAIT=0 so a `consume` with an answer present returns immediately.
inbox_in() {
    local dir="$1"
    shift
    (cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$dir" \
            GOLEM_PLUGIN_PROBE="$dir/no-plugin-probe" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_INBOX_WAIT=0 GOLEM_INBOX_POLL=1 \
            "$REAL_BASH" "$INBOX" "$@" >/dev/null 2>&1) || true
}

# plant_tmux_stub <sandbox> — write $sb/bin/tmux that appends its args to
# $sb/tmux-args.log then exits 0 (never spawns a session). Returns the dir to
# prepend to PATH via stdout is unnecessary; callers use "$sb/bin".
plant_tmux_stub() {
    local sb="$1"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# Test stub: log argv, never start a real session.
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
}

# run_launch_auth <sandbox> [extra env KEY=VAL ...] — invoke `launch 7` with the
# tmux stub on PATH, rules-present settings, a real worktree dir, and both
# ANTHROPIC_* vars scrubbed. Extra positional args are prepended as env
# assignments. Captures RUN_RC / RUN_OUT; the tmux argv lands in $sb/tmux-args.log.
run_launch_auth() {
    local sb="$1"
    shift
    plant_tmux_stub "$sb"
    command mkdir -p "$sb/.worktrees/issue-7"
    command printf '{ "permissions": { "allow": ["Bash(tmux new-session:*)", "Bash(tmux ls:*)", "Bash(tmux kill-session:*)"] } }\n' >"$sb/proj-settings.json"
    command printf '{}\n' >"$sb/global-settings.json"
    # -uBASH_ENV is load-bearing: in the devcontainer BASH_ENV points at
    # /etc/bash_env, which every non-interactive bash sources — and its
    # /etc/bashrc.d/ scripts (a) hard-RESET $PATH (shadowing the $sb/bin stub
    # tmux with the real one) and (b) re-source the real op-secrets cache
    # (leaking a real ANTHROPIC_AUTH_TOKEN into the child, defeating the token
    # scrub). Both would corrupt these PATH/env-sensitive cases; unsetting it
    # makes the sandbox hermetic (see the devcontainer-bash-env-path-reset note).
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            -uANTHROPIC_AUTH_TOKEN -uANTHROPIC_BASE_URL \
            -uOP_ANTHROPIC_AUTH_TOKEN_REF \
            -uBASH_ENV \
            HOME="$sb" \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$sb/.tmux}" \
            TMUX_STUB_LOG="$sb/tmux-args.log" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$@" \
            "$REAL_BASH" "$LAUNCH" launch 7 2>&1)" || RUN_RC=$?
}

# _seed_failing_ref_hook <sandbox> <out-hooksdir-var>
# Writes a hooks dir containing a `reference-transaction` hook that ALWAYS fails,
# and returns its path via the named out-var. Injected as core.hooksPath, this
# hook aborts ANY git ref mutation (worktree add -b, branch -D) with
# "update aborted by the reference-transaction hook" (verified rc≠0) — so it is a
# DISCRIMINATING taint for the mutation-level scrub tests below: unscrubbed, the
# script's own `git worktree add`/`branch -D` fires the hook and fails; scrubbed,
# the injection is gone and the mutation runs clean. A nonexistent hooksPath would
# NOT discriminate (git silently finds no hook and proceeds), so the hook must
# exist and actively fail.
# Internal local is `hdir`, deliberately NOT the caller's out-var name (`hooks`):
# `printf -v "$__out"` resolves against the current scope, so an internal `hooks`
# would shadow and overwrite the caller's local instead of exporting the path back
# (the same pitfall _make_super_with_submodule sidesteps with its `sup`).
_seed_failing_ref_hook() {
    local __out="$2" hdir="$1/evil-hooks"
    command mkdir -p "$hdir"
    command printf '#!/bin/sh\nexit 1\n' >"$hdir/reference-transaction" # lint-allow-path: shebang in generated fixture-script data
    command chmod +x "$hdir/reference-transaction"
    printf -v "$__out" '%s' "$hdir"
}

# _make_super_with_submodule <out-super-var>
# Builds a superproject sandbox (git repo + one commit + .worktrees/.status +
# .tmux + {} .claude.json + a $super/.gitconfig enabling file:// submodules) that
# embeds an inner submodule "mod" carrying a marker bin/fix.sh, and assigns the
# superproject path to the caller's named variable. Returns 1 on any git failure
# and, distinctly, prints a SKIP sentinel + returns 2 when `git submodule add` is
# unavailable (old git / file protocol disallowed) so the caller can skip_test.
# Shared by the worktree-new populate test and the worktree-rm teardown tests.
_make_super_with_submodule() {
    # Internal locals are `inner`/`sup`, deliberately NOT the caller's out-var
    # name (`super`): `printf -v "$__out"` at the end resolves against the current
    # scope, so an internal `super` would shadow and overwrite the caller's local
    # instead of exporting the path back (the pitfall new_sandbox sidesteps with
    # its `dir`).
    local __out="$1" inner sup
    inner="$(command mktemp -d "$WORKDIR/smsub.XXXXXX")" || return 1
    sup="$(command mktemp -d "$WORKDIR/smsuper.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$inner" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$inner" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$inner" config user.name "Test"
    command mkdir -p "$inner/bin"
    command printf '#!/bin/sh\n' >"$inner/bin/fix.sh" # lint-allow-path: shebang in generated fixture-script data
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$inner" add bin/fix.sh 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$inner" -c commit.gpgsign=false commit -qm seed 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sup" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sup" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sup" config user.name "Test"
    command printf 'main\n' >"$sup/app.txt"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sup" add app.txt 2>/dev/null
    if ! /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sup" -c protocol.file.allow=always -c commit.gpgsign=false \
        submodule add -q "$inner" mod 2>/dev/null; then
        return 2
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sup" -c commit.gpgsign=false commit -qm "add mod" 2>/dev/null || return 1
    command mkdir -p "$sup/.worktrees/.status" "$sup/.tmux"
    command printf '{}\n' >"$sup/.claude.json"
    # A submodule clone reads the invoking user's GLOBAL config (not the
    # superproject's repo-local config), and run_in pins HOME=$dir, so put
    # protocol.file.allow here to let the file:// submodule clone succeed.
    command printf '[protocol "file"]\n\tallow = always\n' >"$sup/.gitconfig"
    printf -v "$__out" '%s' "$sup"
    return 0
}

# gate_age_unit <outvar> <sandbox> <golem> <feed> <jq_mode>
#   Source $STATUS inside the sandbox (GIT_*/GOLEM_* scrubbed, HOME pinned, like
#   run_in) and call _gate_age_suffix <golem> <feed>, capturing its stdout into
#   the caller's named variable. <jq_mode> "nojq" stubs jq off PATH (bash-only
#   PATH, BASH_ENV unset so /etc/bash_env cannot restore it — mirrors
#   validate-golem-notify.sh's run_notify nojq); "jq" leaves PATH intact. The
#   source guard means sourcing runs only the helper defs, not the drive.
# The internal capture var is prefixed (`_gau_out`, not `out`) so it can't shadow
# the caller's chosen output variable: `printf -v "$__out"` would otherwise set
# this function's local instead of the caller's, leaving the caller unbound under
# `set -u` when it passes the name `out`.
gate_age_unit() {
    local __out="$1" dir="$2" golem="$3" feed="$4" jq_mode="$5" _gau_out
    if [ "$jq_mode" = "nojq" ]; then
        local stub="$dir/stub-bin"
        command mkdir -p "$stub"
        command ln -sf "$REAL_BASH" "$stub/bash"
        _gau_out="$(cd "$dir" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
                PATH="$stub" HOME="$dir" \
                GOLEM_PLUGIN_PROBE="$dir/no-plugin-probe" \
                GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
                "$REAL_BASH" -c 'source "$1"; _gate_age_suffix "$2" "$3"' \
                _ "$STATUS" "$golem" "$feed" 2>/dev/null || true)"
    else
        _gau_out="$(cd "$dir" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
                HOME="$dir" \
                GOLEM_PLUGIN_PROBE="$dir/no-plugin-probe" \
                GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
                "$REAL_BASH" -c 'source "$1"; _gate_age_suffix "$2" "$3"' \
                _ "$STATUS" "$golem" "$feed" 2>/dev/null || true)"
    fi
    printf -v "$__out" '%s' "$_gau_out"
}

# run_in_watch <sandbox> <timeout-secs> [env KEY=VAL ...] -- <args...>
# Like run_in but for the never-terminating --watch loop: runs golem-status.sh
# under `timeout` (SIGTERM after N s) so the poll loop is bounded, with optional
# extra env (e.g. GOLEM_SWEEP_INTERVAL) prepended. `timeout` exit 124 (killed)
# is normalized to 0 — a bounded watch that had to be killed is the SUCCESS case
# here. Captures combined output in RUN_OUT, the (normalized) code in RUN_RC.
run_in_watch() {
    local dir="$1" secs="$2"
    shift 2
    local extra_env=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        extra_env+=("$1")
        shift
    done
    shift # drop the `--`
    RUN_RC=0
    RUN_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$dir" \
            GOLEM_PLUGIN_PROBE="$dir/no-plugin-probe" \
            TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$dir/.tmux}" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "${extra_env[@]}" \
            "$REAL_BASH" -c '
                # Bound via bin/bounded-run.sh, NOT GNU `timeout` (#543/#932).
                # `timeout` ships with GNU coreutils and is ABSENT on base macOS,
                # where this line failed with `env: timeout: No such file or
                # directory` and rc=127. The calling test guards on
                # `command -v timeout` and skips, but that guard never protected
                # this helper: the check lives in the fragment while the call
                # lives here, so on a Mac the arm ran anyway and reported 127 as
                # a test failure. bounded_run has timeout(1) semantics (including
                # the 124 bound-fired status) with no coreutils dependency.
                #
                # Those fragment guards are GONE as of #960. Once the bound moved
                # here they protected nothing and only hid coverage: measured on a
                # PATH with neither `timeout` nor `gtimeout`, every case they
                # skipped PASSES. The note above had said as much for two issues
                # without anyone acting on it — which is the lesson. If a caller
                # ever needs a real bound again, use bounded_run; do not
                # reintroduce a presence check.
                source "$1"; shift
                bounded_run "$@"
            ' _ "$REPO_ROOT/bin/bounded-run.sh" "$secs" \
            "$REAL_BASH" "$STATUS" "$@" 2>&1)" || RUN_RC=$?
    [ "$RUN_RC" = "124" ] && RUN_RC=0
}

# slug_for <abs-worktree-path> — the Claude Code project-dir slug for a worktree:
# its absolute path with every `/` and `.` replaced by `-`. Mirrors the
# derivation in golem-token-scrape.sh so fixtures land where the script looks.
slug_for() {
    local p="$1"
    command echo "${p//[\/.]/-}"
}

# plant_transcript <sandbox> <issue-N> <jsonl-body> — write a Claude Code session
# transcript for the sandbox's issue-N worktree under a fake projects base
# ($sb/projects), so golem-token-scrape.sh (CLAUDE_PROJECTS_DIR pointed there)
# resolves it. The body is raw JSONL (one record per line).
plant_transcript() {
    local sb="$1" n="$2" body="$3"
    local wt="$sb/.worktrees/issue-$n"
    local slug dir
    slug="$(slug_for "$wt")"
    dir="$sb/projects/$slug"
    command mkdir -p "$dir"
    command printf '%s\n' "$body" >"$dir/session.jsonl"
}

# --- background-work registry fixtures (issue #949) -------------------------
#
# IDENTITY MUST BE UNSET IN EVERY RUNNER BELOW, and this is the first thing to
# know about them. golem-work.sh derives a golem id from $GOLEM_ID, else the
# worktree basename, else $AGENT_ID — and THIS SUITE MAY ITSELF BE RUNNING INSIDE
# A LIVE GOLEM, whose launch stamped GOLEM_ID into the environment. A runner that
# inherits it files every fixture under the RUNNER's id, so the assertions pass
# while testing the harness's identity rather than the code's derivation. One of
# the two fixture defects that sank the withdrawn first attempt was exactly this.
# The `-u` list below is therefore load-bearing, not hygiene.
WORK_ID_SCRUB=(GOLEM_ID AGENT_ID)

# make_golem_worktree <sandbox> <issue-N> [worktree-dir]
# Add a REAL linked git worktree at <worktree-dir>/issue-N (default .worktrees)
# and echo its absolute path.
#
# `git worktree add`, NOT `mkdir`, and that is the second fixture defect from the
# withdrawn attempt. The id derivation reads `git rev-parse --show-toplevel`, and
# the observer's status-dir derivation reads `git rev-parse --git-common-dir`;
# BOTH only answer correctly from a genuine linked worktree. A mkdir-ed directory
# resolves to the SANDBOX root instead, so the fixture silently exercises a
# different code path than production and passes.
#
# <worktree-dir> is a parameter because the multi-segment case (`nested/worktrees`)
# is precisely where the withdrawn grandparent-derivation defect hid: a fixture
# that can only build the default single-segment layout cannot reach it.
make_golem_worktree() {
    local sb="$1" n="$2" wtdir="${3:-.worktrees}"
    command mkdir -p "$sb/$wtdir"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$sb" worktree add -q "$sb/$wtdir/issue-$n" -b "issue-$n" >/dev/null 2>&1 || return 1
    command echo "$sb/$wtdir/issue-$n"
}

# dead_pid <varname> — assign a pid that is verified NOT signalable right now.
# Returns 1 if it cannot obtain one, so the caller can skip rather than assert
# against a precondition that does not hold.
#
# WHY THIS EXISTS RATHER THAN AN INLINE `(exit 0) & dead=$!; wait`. That idiom
# looks deterministic and is not: it asserts a fact about the OS — "this pid is
# now gone" — that the test does not control. Under a long suite that forks
# thousands of processes, the number can be live again by the time it is read.
# Measured: the dead-pid reap case passed three consecutive full runs and then
# failed the fourth with `Expected: '0' / Actual: '1'`, i.e. the entry was kept
# because its pid answered `kill -0`.
#
# A flaky test here is worse than elsewhere, because this one guards a BOUND:
# a red run reads as "the reaper is broken" and a green run as "the reaper
# works", when neither was actually measured. So the precondition is CHECKED —
# allocate, reap, confirm it is unsignalable, and retry a bounded number of
# times — which makes the assertion that follows about the code under test
# rather than about process-table luck.
#
# Deliberately NOT a large out-of-range constant (pid_max + 1). That is
# genuinely unsignalable on Linux, but pid_max is not portable to the macOS
# target this repo supports, and a pid that could never have existed also would
# not exercise the reaper's real input.
dead_pid() {
    local __out="$1" _p _try=0
    while [ "$_try" -lt 20 ]; do
        (exit 0) &
        _p=$!
        wait "$_p" 2>/dev/null || true
        if ! kill -0 "$_p" 2>/dev/null; then
            printf -v "$__out" '%s' "$_p"
            return 0
        fi
        _try=$((_try + 1))
    done
    return 1
}

# live_pid <varname> — start a long-lived child and assign its pid, VERIFIED
# signalable. Returns 1 if it cannot obtain one. The caller must
# `kill`/`wait` the pid when done.
#
# The mirror of dead_pid, and needed for the same reason. `command sleep 30 &
# live=$!` assumes the child is running by the time the assertion reads it; if
# the fork failed or the child was reaped early, the registry entry is dropped
# and the test reports "the reaper ate a live entry" when nothing of the sort
# happened. Checking is one `kill -0`, and it converts a spurious red into an
# honest skip.
live_pid() {
    local __out="$1" _p
    command sleep 30 &
    _p=$!
    if kill -0 "$_p" 2>/dev/null; then
        printf -v "$__out" '%s' "$_p"
        return 0
    fi
    kill "$_p" 2>/dev/null || true
    wait "$_p" 2>/dev/null || true
    return 1
}

# plant_work_registry <sandbox> <golem-id> <jsonl-body> [status-dir]
# Write a background-work registry where golem-work.sh resolves it. <status-dir>
# is sandbox-relative and defaults to .worktrees/.status.
#
# An EMPTY body writes an EMPTY FILE, deliberately distinct from writing NO file:
# both must read as "nothing open", and having both fixtures is what pins the
# fail-soft contract rather than assuming it.
plant_work_registry() {
    local sb="$1" golem="$2" body="$3" sd="${4:-.worktrees/.status}"
    local dir="$sb/$sd"
    command mkdir -p "$dir"
    if [ -n "$body" ]; then
        command printf '%s\n' "$body" >"$dir/$golem.work.jsonl"
    else
        : >"$dir/$golem.work.jsonl"
    fi
}

# work_register_line <id> <kind> <desc> <started_epoch> [pid] [max_age] [golem]
# One `register` event in the shape the real writer emits. Built here rather than
# hand-typed per test so a schema change lands in ONE place; `started_epoch` is a
# parameter because the age-out bound is exactly what several cases exercise.
work_register_line() {
    local id="$1" kind="$2" desc="$3" epoch="$4" pid="${5:-}" max_age="${6:-}"
    local golem="${7:-golem-42}" extra=""
    [ -n "$pid" ] && extra="$extra,\"pid\":$pid"
    [ -n "$max_age" ] && extra="$extra,\"max_age\":$max_age"
    command printf '{"event":"register","id":"%s","golem":"%s","kind":"%s","description":"%s","started":"2026-01-01T00:00:00Z","started_epoch":%s%s}' \
        "$id" "$golem" "$kind" "$desc" "$epoch" "$extra"
}

# run_scrape <sandbox> <worktree-arg> — invoke golem-token-scrape.sh with the
# projects base pointed at the sandbox's fake $sb/projects. Captures RUN_RC/RUN_OUT.
run_scrape() {
    local sb="$1" arg="$2"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$SCRAPE" "$arg" 2>&1)" || RUN_RC=$?
}

# run_status_scrape <sandbox> [args...] — like run_in for golem-status.sh but with
# CLAUDE_PROJECTS_DIR pointed at the sandbox's fake projects base so the token
# scrape resolves planted transcripts. Captures RUN_RC/RUN_OUT.
run_status_scrape() {
    local sb="$1"
    shift
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$sb/.tmux}" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$STATUS" "$@" 2>&1)" || RUN_RC=$?
}

# A transcript body with mixed sidechain records mirroring the REAL on-disk shape:
# Claude Code writes one line per assistant CONTENT BLOCK, all sharing the turn's
# message.id and repeating the same output_tokens. Here turn "m1" spans THREE
# blocks (output_tokens 100 x3 — must be counted ONCE) and turn "m2" is one block
# (50), for a correct top-level total of 150. One SUB-WORKFLOW record
# (output_tokens 999) MUST be excluded; a summary record carries no usage. A
# naive per-line sum would wrongly count 100x3 + 50 = 350 — so this fixture pins the
# message.id dedup (bug caught in #371 pre-PR review).
TRANSCRIPT_MIXED='{"isSidechain":false,"message":{"id":"m1","usage":{"output_tokens":100}}}
{"isSidechain":false,"message":{"id":"m1","usage":{"output_tokens":100}}}
{"isSidechain":false,"message":{"id":"m1","usage":{"output_tokens":100}}}
{"isSidechain":true,"message":{"id":"s1","usage":{"output_tokens":999}}}
{"isSidechain":false,"message":{"id":"m2","usage":{"output_tokens":50}}}
{"type":"summary"}'

# --- context-budget.sh fixtures (#784) --------------------------------------
#
# These pin the POINT-READING contract: context size is the LAST top-level
# record's input side, NOT a sum over the transcript (the opposite of
# golem-token-scrape.sh, which sums). Every fixture below is built so that a
# summing regression produces a DIFFERENT number than the correct answer — a
# fixture whose sum happens to equal its last record would pass under both
# implementations and pin nothing.
#
# Last top-level record: 10000 + 140000 + 10000 = 160000 (91% of the 175000
# default → `advise`). The earlier top-level record totals 60000 and the
# sidechain totals 900000: a naive SUM would give 1120000 and a
# top-level-but-summing regression 220000 — both far from 160000, so either
# error is caught. The trailing `{"type":"summary"}` record models the real
# on-disk tail, which carries no usage: reading `.[-1]` blindly instead of the
# last USAGE-bearing record would find no reading at all and wrongly exit 2.
TRANSCRIPT_CTX_ADVISE='{"isSidechain":false,"message":{"id":"c1","usage":{"input_tokens":10000,"cache_read_input_tokens":40000,"cache_creation_input_tokens":10000}}}
{"isSidechain":true,"message":{"id":"s1","usage":{"input_tokens":100000,"cache_read_input_tokens":800000}}}
{"isSidechain":false,"message":{"id":"c2","usage":{"input_tokens":10000,"cache_read_input_tokens":140000,"cache_creation_input_tokens":10000}}}
{"type":"summary"}'

# Last top-level record: 5000 + 15000 = 20000 (11% → `ok`). Deliberately has a
# LARGER earlier record (300000) so a regression that reads the FIRST match, or
# the max, or the sum lands in `handoff` instead of `ok` — an inverted verdict,
# the loudest possible failure.
TRANSCRIPT_CTX_OK='{"isSidechain":false,"message":{"id":"c1","usage":{"input_tokens":100000,"cache_read_input_tokens":200000}}}
{"isSidechain":false,"message":{"id":"c2","usage":{"input_tokens":5000,"cache_read_input_tokens":15000}}}
{"type":"summary"}'

# Last top-level record: 200000 + 100 = 200100 (114% → `handoff`).
TRANSCRIPT_CTX_HANDOFF='{"isSidechain":false,"message":{"id":"c1","usage":{"input_tokens":100,"cache_read_input_tokens":200000}}}
{"type":"summary"}'

# A transcript with a malformed/partial TRAILING line, as captured mid-write. The
# `fromjson?` guard must skip it and read the last COMPLETE record (150000), not
# fail the whole parse.
TRANSCRIPT_CTX_PARTIAL='{"isSidechain":false,"message":{"id":"c1","usage":{"input_tokens":50000,"cache_read_input_tokens":100000}}}
{"isSidechain":false,"message":{"id":"c2","usa'

# A transcript whose only usage-bearing records are SUB-WORKFLOWS. There is no
# top-level reading at all, so this must FAIL LOUD (exit 2) rather than report 0
# — a silent 0 would say "plenty of headroom" for a session whose real size is
# unknown, suppressing a handoff that may be due. Note this differs from the
# token scrape's contract for the same shape, where 0 is a real answer ("no
# output produced yet"); absence and zero are the same number for a sum and
# different states for a point reading.
TRANSCRIPT_CTX_NO_TOPLEVEL='{"isSidechain":true,"message":{"id":"s1","usage":{"input_tokens":100000,"cache_read_input_tokens":50000}}}
{"type":"summary"}'

# run_ctx_budget <sandbox> <worktree-arg> [env-assignments...] — invoke
# context-budget.sh with the projects base pointed at the sandbox's fake
# $sb/projects. Trailing VAR=VAL arguments are passed into the script's
# environment, so a test can override the threshold/floor knobs. Captures
# RUN_RC/RUN_OUT.
run_ctx_budget() {
    local sb="$1" arg="$2"
    shift 2
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$@" \
            "$REAL_BASH" "$CTX_BUDGET" check "$arg" 2>&1)" || RUN_RC=$?
}

# A transcript whose every usage-bearing record is a SUB-WORKFLOW (isSidechain
# true) — no top-level output yet. The scrape's `add // 0` must yield the
# documented `0`, and golem-status must render "0 tokens (first reading)", NOT
# "tokens unknown" (a real 0 is a digit, distinct from an empty/failed scrape).
TRANSCRIPT_ALL_SIDECHAIN='{"isSidechain":true,"message":{"id":"s1","usage":{"output_tokens":100}}}
{"isSidechain":true,"message":{"id":"s2","usage":{"output_tokens":50}}}
{"type":"summary"}'

# iso_ago <seconds> — an ISO-8601 Z timestamp <seconds> in the past, in the same
# %FT%TZ shape golem-status.sh's _now_iso writes. Uses the same GNU-then-BSD
# `date` toolchain the script's _iso_to_epoch parses, so a seeded anchor maps
# back to a frozen-duration in the expected band. Prints nothing on failure.
iso_ago() {
    local n="$1" now past
    now="$(command date -u +%s)"
    past=$((now - n))
    command date -u -d "@$past" +%FT%TZ 2>/dev/null && return 0 # lint-allow-gnu-flag: GNU form, BSD -r fallback on the next line
    command date -u -r "$past" +%FT%TZ 2>/dev/null && return 0
    return 1
}
