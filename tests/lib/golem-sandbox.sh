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
#     `/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}"` so git's hook-exported
#     environment (GIT_DIR / GIT_COMMON_DIR / ...) cannot pin repo_root to the
#     OUTER repo when the suite runs from a `git push` pre-push hook — the
#     failure mode root-caused in golem-gate-watch (PR #62).
#   * HOME is repointed at the sandbox, because worktree-new transitively seeds
#     trust into $HOME/.claude.json via seed-worktree-trust.sh; without the
#     override a sandbox run would write the operator's real config.
#
# The consts this file depends on (SCRIPTS, LAUNCH, REAL_BASH, GIT_SCRUB, ...)
# are defined by the entry point before it sources this file.

# shellcheck disable=SC2034  # WORKDIR / RUN_RC / RUN_OUT / TRANSCRIPT_* are read by the area fragments

# Module-level scratch dir, cleaned up once when the suite exits.
WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# new_sandbox <varname>
# Creates a fresh git repo sandbox with one seed commit (so HEAD exists and can
# serve as GOLEM_BASE_REF), a `.worktrees/.status/` dir, and an empty `{}` at
# <sandbox>/.claude.json (the seed-trust target HOME is pointed at). Assigns the
# sandbox path to the caller's named variable. `git init` + the seed commit run
# with the git environment scrubbed so the sandbox is hermetic under a hook.
new_sandbox() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" config user.name "Test"
    command printf 'seed\n' >"$dir/seed.txt"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" add seed.txt 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" -c commit.gpgsign=false commit -qm seed 2>/dev/null || return 1
    command mkdir -p "$dir/.worktrees/.status"
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$dir" \
            TMUX= TMUX_TMPDIR="$dir/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$dir" \
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
    # --unset=BASH_ENV is load-bearing: in the devcontainer BASH_ENV points at
    # /etc/bash_env, which every non-interactive bash sources — and its
    # /etc/bashrc.d/ scripts (a) hard-RESET $PATH (shadowing the $sb/bin stub
    # tmux with the real one) and (b) re-source the real op-secrets cache
    # (leaking a real ANTHROPIC_AUTH_TOKEN into the child, defeating the token
    # scrub). Both would corrupt these PATH/env-sensitive cases; unsetting it
    # makes the sandbox hermetic (see the devcontainer-bash-env-path-reset note).
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=ANTHROPIC_AUTH_TOKEN --unset=ANTHROPIC_BASE_URL \
            --unset=OP_ANTHROPIC_AUTH_TOKEN_REF \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
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
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$inner" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$inner" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$inner" config user.name "Test"
    command mkdir -p "$inner/bin"
    command printf '#!/bin/sh\n' >"$inner/bin/fix.sh" # lint-allow-path: shebang in generated fixture-script data
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$inner" add bin/fix.sh 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$inner" -c commit.gpgsign=false commit -qm seed 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sup" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sup" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sup" config user.name "Test"
    command printf 'main\n' >"$sup/app.txt"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sup" add app.txt 2>/dev/null
    if ! /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sup" -c protocol.file.allow=always -c commit.gpgsign=false \
        submodule add -q "$inner" mod 2>/dev/null; then
        return 2
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
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
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub" HOME="$dir" \
                GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
                "$REAL_BASH" -c 'source "$1"; _gate_age_suffix "$2" "$3"' \
                _ "$STATUS" "$golem" "$feed" 2>/dev/null || true)"
    else
        _gau_out="$(cd "$dir" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                HOME="$dir" \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$dir" \
            TMUX= TMUX_TMPDIR="$dir/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            "${extra_env[@]}" \
            timeout "$secs" "$REAL_BASH" "$STATUS" "$@" 2>&1)" || RUN_RC=$?
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

# run_scrape <sandbox> <worktree-arg> — invoke golem-token-scrape.sh with the
# projects base pointed at the sandbox's fake $sb/projects. Captures RUN_RC/RUN_OUT.
run_scrape() {
    local sb="$1" arg="$2"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
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
    command date -u -d "@$past" +%FT%TZ 2>/dev/null && return 0
    command date -u -r "$past" +%FT%TZ 2>/dev/null && return 0
    return 1
}
