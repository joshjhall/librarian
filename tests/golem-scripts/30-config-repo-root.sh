# shellcheck shell=bash
# config.sh repo_root() — golem helper-script tests (issue #564 split).
#
# Covers PATH resolution, submodule superproject probing, the git-env/config-injection scrub class (#279/#328/#355/#376), and the GIT_ENV_SCRUB_VARS single-source pin (#356).
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / WT_NEW / STATUS / ...) and sources tests/lib/golem-sandbox.sh for the
# shared sandbox plumbing (new_sandbox / run_in / ...) BEFORE this file. This
# fragment therefore only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_test list.

# --- config.sh repo_root() ----------------------------------------------------

# Regression (#278): repo_root() must resolve its tools via PATH, not hardcoded
# /usr/bin/*. Off the standard layout (git elsewhere) /usr/bin/git exits 127,
# gets swallowed by `|| true`, and repo_root silently returns empty — tripping
# every caller's "not a repo" branch inside a valid repo. Static guard mirroring
# test_worktree_new_no_hardcoded_usr_bin (#228).
test_config_repo_root_no_hardcoded_usr_bin() {
    local body hits
    # Scope to repo_root()'s body (the header comment legitimately shows a
    # /usr/bin/dirname sourcing example) and drop comment lines, so only real
    # tool invocations are checked.
    body="$(command awk '/^repo_root\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$CONFIG")"
    hits="$(command printf '%s\n' "$body" |
        command grep -vE '^[[:space:]]*#' |
        command grep -nE '/usr/bin/(git|pwd|dirname)' || true)"
    assert_output_empty "$hits" \
        "config.sh repo_root invokes git/pwd/dirname via \`command\`/bash, not hardcoded /usr/bin/*"
}

# Functional regression (#278): with git resolvable via PATH but ABSENT at
# /usr/bin/git, repo_root() still resolves the repo root. A shim dir is prepended
# to PATH holding a `git` wrapper; PATH is then stripped to ONLY that shim, so a
# hardcoded /usr/bin/git would exit 127 and repo_root would return empty. Proves
# the fix honors PATH. Skips cleanly if the real git can't be located to wrap.
test_config_repo_root_honors_path() {
    local sb real_git
    new_sandbox sb
    real_git="$(command -v git || true)"
    if [ -z "$real_git" ]; then
        skip_test "git not on PATH — cannot build the shim wrapper"
        return 0
    fi
    # A `git` symlink to the real binary in a dir that is the ONLY entry on PATH
    # (no /usr/bin). A symlink — not a `#!/usr/bin/env bash` wrapper — because
    # PATH is stripped to just this dir, so a wrapper's interpreter (`bash`)
    # would be unresolvable; the symlink needs no interpreter. repo_root's other
    # tools (pwd/echo) are bash builtins, so git is the only PATH dependency.
    local shim="$sb/shim"
    command mkdir -p "$shim"
    command ln -s "$real_git" "$shim/git"

    local out rc=0
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            PATH="$shim" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 with git resolved via PATH only"
    # repo_root prints the sandbox root (the git common dir's parent). git
    # canonicalizes symlinks in that path (e.g. a symlinked /tmp on the CI
    # runner), so compare realpaths, not the raw mktemp path.
    local sb_real out_real
    sb_real="$(cd "$sb" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$sb_real" "$out_real" \
        "repo_root resolves the repo root via PATH, not command git"
}

# Edge case (#278): repo_root()'s pure-bash dirname must match GNU `dirname` for
# a single-slash git-common-dir (a bare repo rooted at "/" resolves to "/.git").
# Stripping "/.git" via ${common_dir%/*} yields "" — the fix falls back to "/",
# as `dirname /.git` does; without the ${parent:-/} guard repo_root would print
# an empty root at exit 0. A shim `git` (bin dir first on PATH) forces the
# --git-common-dir output to /.git; bash stays on PATH so the script shim runs.
test_config_repo_root_dirname_root_edge() {
    local sb bin
    new_sandbox sb
    bin="$sb/bin"
    command mkdir -p "$bin"
    {
        command printf '#!/usr/bin/env bash\n'
        # Only intercept the common-dir probe; anything else is unexpected here.
        command printf 'case "$*" in\n'
        command printf '  *--git-common-dir*) command echo "/.git" ;;\n'
        command printf '  *) exit 1 ;;\n'
        command printf 'esac\n'
    } >"$bin/git"
    command chmod +x "$bin/git"

    # Unset BASH_ENV too: /etc/bash_env re-adds the real PATH on the devcontainer
    # for non-interactive bash, which would let the real git outrank the shim.
    local out rc=0
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            PATH="$bin:$PATH" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 for a filesystem-root repo"
    assert_equals "/" "$out" \
        "repo_root returns '/' for a /.git common dir, matching GNU dirname"
}

# Edge case (#278): when git reports a RELATIVE --git-common-dir, repo_root()
# prepends `command pwd` to absolutize it before taking the dirname. A shim git
# emits the relative ".git"; repo_root should return the sandbox dir (pwd + /.git
# → parent = pwd). Exercises the `*) common_dir="$(command pwd)/$common_dir"` arm
# that this diff changed from /usr/bin/pwd.
test_config_repo_root_relative_common_dir() {
    local sb bin
    new_sandbox sb
    bin="$sb/bin"
    command mkdir -p "$bin"
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'case "$*" in\n'
        command printf '  *--git-common-dir*) command echo ".git" ;;\n'
        command printf '  *) exit 1 ;;\n'
        command printf 'esac\n'
    } >"$bin/git"
    command chmod +x "$bin/git"

    local out rc=0
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            PATH="$bin:$PATH" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 for a relative common dir"
    # pwd/.git → dirname → pwd. Compare realpaths (symlinked /tmp on CI).
    local sb_real out_real
    sb_real="$(cd "$sb" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$sb_real" "$out_real" \
        "repo_root absolutizes a relative --git-common-dir via command pwd"
}

# Edge case (#336): when git reports a RELATIVE
# --show-superproject-working-tree, repo_root() prepends `command pwd` to
# absolutize it before returning (the submodule super_root arm added in #324).
# --path-format=absolute makes real git always print an absolute path, so the
# #324 happy-path test never executes this fallback; a shim git emitting a
# relative "sup" forces it. repo_root should return pwd/sup (super_root is
# non-empty, so it returns early and never reaches the common-dir probe — one
# shim branch suffices). Mirrors test_config_repo_root_relative_common_dir.
test_config_repo_root_relative_super_root() {
    local sb bin
    new_sandbox sb
    bin="$sb/bin"
    command mkdir -p "$bin"
    # A real relative target so the realpath compare proves pwd was prepended.
    command mkdir -p "$sb/sup"
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'case "$*" in\n'
        command printf '  *--show-superproject-working-tree*) command echo "sup" ;;\n'
        command printf '  *) exit 1 ;;\n'
        command printf 'esac\n'
    } >"$bin/git"
    command chmod +x "$bin/git"

    local out rc=0
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            PATH="$bin:$PATH" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 for a relative super_root"
    # pwd/sup absolutized. Compare realpaths (symlinked /tmp on CI).
    local sup_real out_real
    sup_real="$(cd "$sb/sup" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$sup_real" "$out_real" \
        "repo_root absolutizes a relative --show-superproject-working-tree via command pwd"
}

# Security regression (#279): repo_root() scrubs git's hook-exported environment
# for its own rev-parse, so a tainted GIT_DIR/GIT_COMMON_DIR (as leaks in from a
# git hook or a wrapper forwarding the environment) cannot pin the resolved root
# to an OUTER repo. Direct unit test of repo_root() itself — decoupled from any
# caller — mirroring the #278 cases above: source config.sh in the sandbox with
# GIT_DIR/GIT_COMMON_DIR pointed at a SECOND real repo and assert repo_root()
# still prints the sandbox root, not the tainted one. Deliberately does NOT put
# GIT_DIR in GIT_SCRUB's unset list for this invocation — the taint must reach
# repo_root() for the test to mean anything.
test_config_repo_root_scrubs_tainted_git_env() {
    local sb outer
    new_sandbox sb
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1

    local out rc=0
    out="$(cd "$sb" &&
        GIT_DIR="$outer/.git" GIT_COMMON_DIR="$outer/.git" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 despite a tainted git environment"
    local sb_real out_real
    sb_real="$(cd "$sb" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$sb_real" "$out_real" \
        "repo_root resolves the sandbox root, not the tainted GIT_DIR/GIT_COMMON_DIR target"
}

# Security regression (#355): git honors GIT_CONFIG_COUNT + GIT_CONFIG_KEY_<n> /
# GIT_CONFIG_VALUE_<n> (and the single-var GIT_CONFIG_PARAMETERS form) to inject
# arbitrary config, changing what a later git call reads WITHOUT touching GIT_DIR
# (e.g. url.<base>.insteadOf redirecting a fetch). config.sh's _git_env_scrub_names
# scrubs the whole family — the static names plus the dynamic KEY_<n>/VALUE_<n>
# pairs — inside _repo_root_git, which is the shared arm every caller's git runs
# through.
#
# The test must DISCRIMINATE scrubbed from unscrubbed. `repo_root()` alone does
# NOT: its only git subcommand is `rev-parse --git-common-dir`, which is inert to
# core.worktree/config injection (the pre-PR review verified an injected
# core.worktree leaves --git-common-dir unchanged, so a repo_root()-level
# assertion passes even with ZERO scrubbing — a false-positive security test).
# Instead drive `_repo_root_git config --get <key>`: `git config` DOES honor the
# injected value, so the assertion actually fails when the scrub is dropped. The
# test proves both directions: (a) a BARE `git config --get` under the taint reads
# the INJECTED value (the vector is real and reaches this repo), and (b)
# `_repo_root_git config --get` reads the repo's REAL value (the scrub neutralizes
# it). Taint deliberately not in GIT_SCRUB — it must reach the child.
#
# Helper: run one injection encoding and assert the scrub wins while a bare git
# loses. $1 = label, remaining args = the env assignment(s) carrying the taint.
_assert_config_injection_scrubbed() {
    local label="$1"
    shift
    local sb
    new_sandbox sb
    # Seed a known real value the injection tries to override.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" config user.name "REALNAME"

    # (a) Bare git under the taint reads the INJECTED value — proves the vector is
    # live and reaches this repo (guards against a test that passes vacuously). The
    # bare git's own exit code is irrelevant here; only the value it reads matters.
    local bare
    bare="$(cd "$sb" &&
        /usr/bin/env "$@" "$REAL_BASH" -c 'git config --get user.name' 2>&1)" || true
    assert_equals "INJECTED" "$bare" \
        "$label: bare git honors the injected user.name (the taint is real)"

    # (b) _repo_root_git config --get reads the REAL value — the scrub neutralized
    # the injection. This FAILS (reads INJECTED) if the scrub is dropped.
    local scrubbed rc_b=0
    scrubbed="$(cd "$sb" &&
        /usr/bin/env "$@" "$REAL_BASH" -c '. "$1"; _repo_root_git config --get user.name' \
            _ "$CONFIG" 2>&1)" || rc_b=$?
    assert_exit 0 "$rc_b" "$label: _repo_root_git config exits 0 despite the taint"
    assert_equals "REALNAME" "$scrubbed" \
        "$label: _repo_root_git reads the REAL user.name, not the injected one (scrub works)"
}

# Indexed GIT_CONFIG_COUNT/KEY_<n>/VALUE_<n> encoding — the dynamic pairs
# _git_env_scrub_names enumerates.
test_config_repo_root_scrubs_git_config_injection() {
    _assert_config_injection_scrubbed "GIT_CONFIG_COUNT" \
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=INJECTED
}

# Single-var GIT_CONFIG_PARAMETERS encoding — a shell-quoted `'key=value'` list
# git honors identically. A FIXED name (unlike the dynamic pairs), so it lives in
# the static GIT_ENV_SCRUB_VARS. Its omission left the injection class
# half-closed (surfaced by the pre-PR review); this guards the fix.
test_config_repo_root_scrubs_git_config_parameters() {
    _assert_config_injection_scrubbed "GIT_CONFIG_PARAMETERS" \
        GIT_CONFIG_PARAMETERS="'user.name=INJECTED'"
}

# Availability regression (#355): GIT_CEILING_DIRECTORIES makes git STOP repo
# discovery at the named ceiling — set to the sandbox root, discovery from a
# subdir fails `fatal: not a git repository` (verified rc=128 unscrubbed). A golem
# host whose hook exports it would break every repo_root() caller inside a valid
# repo. config.sh scrubs it (now on GIT_ENV_SCRUB_VARS), so repo_root() resolves
# regardless. Run from a SUBDIR so the ceiling actually bites (from the root
# itself git is already at the boundary). Taint deliberately not in GIT_SCRUB.
test_config_repo_root_scrubs_git_ceiling_directories() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/sub"

    local out rc=0
    out="$(cd "$sb/sub" &&
        GIT_CEILING_DIRECTORIES="$sb" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 despite a GIT_CEILING_DIRECTORIES discovery block"
    local sb_real out_real
    sb_real="$(cd "$sb" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$sb_real" "$out_real" \
        "repo_root resolves the sandbox root despite a GIT_CEILING_DIRECTORIES taint"
}

# Security regression (#376, deferred from the #355/PR #375 pre-PR review): four
# static scrub names — GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM / GIT_CONFIG_NOSYSTEM
# / GIT_DISCOVERY_ACROSS_FILESYSTEM — were on GIT_ENV_SCRUB_VARS but covered ONLY
# by the static list-equality assertion in
# test_config_git_env_scrub_vars_single_source, never by a live-taint behavioral
# test proving the scrub actually neutralizes them. A partial-scrub refactor
# per-name could drop one silently. These tests close that gap, each
# DISCRIMINATING (fails when the scrub is dropped, per the #355 vector tests'
# rationale above): a BARE git under the taint honors it, while the same call
# through _repo_root_git is unaffected.
#
# Two distinct vector shapes need two helpers:
#
# GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM point git at an arbitrary config FILE
# (unlike the indexed GIT_CONFIG_COUNT pairs), injecting values without touching
# GIT_DIR — e.g. a url.<base>.insteadOf redirect or a hostile core.hooksPath.
# NOTE these inject at GLOBAL/SYSTEM precedence, which repo-LOCAL config OUTRANKS,
# so (unlike the command-scope GIT_CONFIG_COUNT pairs) the sandbox must NOT seed a
# competing repo-local inject.marker — the injected key must be one the repo does
# not set, so the bare read actually surfaces the injected value. Helper: seed a
# config file setting inject.marker=INJECTED, then assert (a) a bare
# `git config --get inject.marker` under the taint reads INJECTED (the vector is
# live and reaches this repo — guards against a vacuous pass), and (b)
# `_repo_root_git config --get inject.marker` reads NOTHING and exits non-zero (the
# scrub removed the file redirect, so the key is simply absent). $1 = the env var
# name carrying the file path.
_assert_config_file_injection_scrubbed() {
    local var="$1"
    local sb
    new_sandbox sb
    # The injected config file (points $var at it below). A FILE, not indexed pairs.
    # inject.marker is deliberately NOT set in the sandbox's repo-local config:
    # GLOBAL/SYSTEM scope loses to repo-local, so a local seed would shadow the
    # injection and the bare read would never surface INJECTED (a vacuous test).
    local injfile="$sb/inject.cfg"
    command printf '[inject]\n\tmarker = INJECTED\n' >"$injfile"

    # (a) Bare git under the taint reads the INJECTED value — the file redirect is
    # live. HOME is pinned at the sandbox so a stray real ~/.gitconfig can't shadow
    # GIT_CONFIG_GLOBAL. The bare git's own exit code is irrelevant; only the value.
    local bare
    bare="$(cd "$sb" &&
        /usr/bin/env "$var=$injfile" HOME="$sb" \
            "$REAL_BASH" -c 'command git config --get inject.marker' 2>&1)" || true
    assert_equals "INJECTED" "$bare" \
        "$var: bare git honors the injected config file (the taint is real)"

    # (b) _repo_root_git config --get finds NOTHING — the scrub removed the file
    # redirect, so inject.marker is unset (config --get exits 1 with empty output).
    # READS INJECTED (exit 0) if the scrub drops this name.
    local scrubbed rc_b=0
    scrubbed="$(cd "$sb" &&
        /usr/bin/env "$var=$injfile" HOME="$sb" \
            "$REAL_BASH" -c '. "$1"; _repo_root_git config --get inject.marker' \
            _ "$CONFIG" 2>&1)" || rc_b=$?
    assert_output_empty "$scrubbed" \
        "$var: _repo_root_git reads no inject.marker — the injected file was scrubbed away (scrub works)"
    assert_true "[ '$rc_b' -ne 0 ]" \
        "$var: _repo_root_git config exits non-zero (the injected key is gone, not read)"
}

# GIT_CONFIG_NOSYSTEM / GIT_DISCOVERY_ACROSS_FILESYSTEM are BOOLEAN control vars,
# not value injectors: NOSYSTEM suppresses system config, DISCOVERY controls
# crossing a filesystem boundary. A value-injection discriminator doesn't fit
# (suppression is indistinguishable from absence; a cross-FS fixture isn't
# portable), but git VALIDATES both as booleans on every invocation, so an INVALID
# bool (`notabool`) makes any git call fatal (rc 128) — a clean, portable
# discriminator that still proves the var reaches the child and the scrub removes
# it. We assert on the rc DELTA across three runs of the same fixture, not on
# git's internal fatal-error wording (which carries no version floor and could be
# reworded upstream): seed a REAL inject.marker=REALNAME, then triangulate
# (a0) a bare `git config --get` with NO taint exits 0 (the fixture is sound, so
# the fatal in (a) is caused by the taint — not a broken sandbox),
# (a) the same bare call under the invalid-bool taint fatals (rc 128, the var is
# live and git honors it), and
# (b) `_repo_root_git config --get` under the same taint exits 0 reading REALNAME
# (the scrub removed the bad var so git runs clean). The 0 → 128 → 0 sequence
# proves the taint specifically causes the fatal and the scrub specifically
# removes it. $1 = the env var name.
_assert_bool_var_scrubbed() {
    local var="$1"
    local sb
    new_sandbox sb
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" config inject.marker "REALNAME"

    # (a0) Baseline: the SAME bare call with NO taint exits 0. Proves the fixture
    # is sound, so the fatal in (a) is attributable to the taint — not a broken
    # sandbox. This is the version-independent replacement for asserting on git's
    # fatal-error wording. GIT_SCRUB is applied so an INHERITED GIT_DIR (which the
    # git pre-push hook exports into this harness's environment) cannot pin git at
    # the outer repo and make the sandbox's inject.marker unreadable — the leak
    # that made these two tests fail under `git push` but pass on a bare run.
    local rc_a0=0
    (cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" HOME="$sb" \
            "$REAL_BASH" -c 'command git config --get inject.marker' >/dev/null 2>&1) || rc_a0=$?
    assert_exit 0 "$rc_a0" \
        "$var: baseline bare git succeeds without the taint (fixture is sound)"

    # (a) Bare git under an invalid-bool taint fatals (rc 128) — the var reaches the
    # child and git honors it. Guards against a vacuous pass. Same GIT_SCRUB as (a0)
    # so ONLY the deliberate `$var=notabool` taint (not a leaked GIT_DIR) drives the
    # fatal.
    local rc_a=0
    (cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$var=notabool" HOME="$sb" \
            "$REAL_BASH" -c 'command git config --get inject.marker' >/dev/null 2>&1) || rc_a=$?
    assert_exit 128 "$rc_a" \
        "$var: bare git fatals on the invalid-bool taint (the taint is real)"

    # (b) _repo_root_git scrubs the name, so git runs clean and reads the REAL
    # value. FAILS (fatals, rc 128) if the scrub drops this name.
    local scrubbed rc_b=0
    scrubbed="$(cd "$sb" &&
        /usr/bin/env "$var=notabool" HOME="$sb" \
            "$REAL_BASH" -c '. "$1"; _repo_root_git config --get inject.marker' \
            _ "$CONFIG" 2>&1)" || rc_b=$?
    assert_exit 0 "$rc_b" \
        "$var: _repo_root_git config exits 0 despite the invalid-bool taint"
    assert_equals "REALNAME" "$scrubbed" \
        "$var: _repo_root_git reads the REAL inject.marker (scrub works)"
}

# GIT_CONFIG_GLOBAL file-injection — the ~/.gitconfig-slot redirect.
test_config_repo_root_scrubs_git_config_global() {
    _assert_config_file_injection_scrubbed GIT_CONFIG_GLOBAL
}

# GIT_CONFIG_SYSTEM file-injection — the /etc/gitconfig-slot redirect.
test_config_repo_root_scrubs_git_config_system() {
    _assert_config_file_injection_scrubbed GIT_CONFIG_SYSTEM
}

# GIT_CONFIG_NOSYSTEM — the system-config suppression bool.
test_config_repo_root_scrubs_git_config_nosystem() {
    _assert_bool_var_scrubbed GIT_CONFIG_NOSYSTEM
}

# GIT_DISCOVERY_ACROSS_FILESYSTEM — the cross-filesystem-boundary discovery bool.
test_config_repo_root_scrubs_git_discovery_across_filesystem() {
    _assert_bool_var_scrubbed GIT_DISCOVERY_ACROSS_FILESYSTEM
}

# Regression (#328): the #279 scrub used a bare `unset`, which SILENTLY NO-OPS on
# a READONLY GIT_* var (`declare -rx GIT_DIR=…`) — the unset fails to stderr but
# the command-substitution subshell continues (no inherit_errexit), so
# `git rev-parse` still reads the tainted value and repo_root() returns the OUTER
# repo. _repo_root_git (config.sh) closes this: plain unset first (dependency-
# free common path), falling back to `env -u` (unexports regardless of the
# readonly attribute) when unset fails. Direct repo_root() unit test with a
# readonly-exported taint, asserting the sandbox root still resolves. Mirrors
# test_config_repo_root_scrubs_tainted_git_env but with `declare -rx`.
test_config_repo_root_scrubs_readonly_tainted_git_env() {
    local sb outer
    new_sandbox sb
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1

    # declare -rx makes GIT_DIR/GIT_COMMON_DIR readonly AND exported inside the
    # child bash before sourcing config.sh, so a bare `unset` in repo_root's
    # subshell cannot clear them — the env -u fallback must.
    local out rc=0
    out="$(cd "$sb" &&
        "$REAL_BASH" -c 'declare -rx GIT_DIR="$2/.git"; declare -rx GIT_COMMON_DIR="$2/.git"; . "$1"; repo_root' \
            _ "$CONFIG" "$outer" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 despite a readonly tainted git environment"
    local sb_real out_real
    sb_real="$(cd "$sb" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$sb_real" "$out_real" \
        "repo_root resolves the sandbox root despite a readonly GIT_DIR/GIT_COMMON_DIR taint"
}

# Regression (#324): inside a git SUBMODULE working tree, --git-common-dir
# resolves to <super>/.git/modules/<name>, so the common-dir logic alone would
# return <super>/.git/modules — a git-internal path — and worktree-new.sh would
# land worktrees under .git/modules/.worktrees/issue-N. repo_root() must instead
# return the SUPERPROJECT working-tree root. Build a real super+submodule fixture
# and assert repo_root, invoked from inside the submodule tree, returns <super>
# (not <super>/.git/modules). Skips cleanly if `submodule add` is unavailable
# (old git / file protocol disallowed).
test_config_repo_root_submodule_superproject() {
    local sub super name rc=0
    sub="$(command mktemp -d "$WORKDIR/sub.XXXXXX")" || return 1
    super="$(command mktemp -d "$WORKDIR/super.XXXXXX")" || return 1
    name="mod"
    # Inner submodule repo with one commit so it can be added.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" -c commit.gpgsign=false commit -q --allow-empty -m seed 2>/dev/null || return 1
    # Superproject that embeds it as a submodule. `protocol.file.allow=always`
    # is required for a local-path submodule add on modern git.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" config user.name "Test"
    if ! /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" -c protocol.file.allow=always -c commit.gpgsign=false \
        submodule add -q "$sub" "$name" 2>/dev/null; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" -c commit.gpgsign=false commit -qm "add $name" 2>/dev/null || return 1

    # Invoke repo_root from INSIDE the submodule working tree.
    local out
    out="$(cd "$super/$name" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 inside a submodule working tree"
    # Compare realpaths (symlinked /tmp on CI runners).
    local super_real out_real
    super_real="$(cd "$super" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$super_real" "$out_real" \
        "repo_root returns the superproject root, not <super>/.git/modules"
}

# Security regression (#337, closing a coverage gap flagged in the #335 pre-PR
# review): the super_root probe (#324) runs its
# `rev-parse --show-superproject-working-tree` through _repo_root_git, so a
# tainted GIT_DIR/GIT_COMMON_DIR (from a git hook or an env-forwarding wrapper)
# cannot pin the resolved root to an OUTER repo — the same #279 hook-safety
# guarantee already proven for the common-dir probe. But
# test_config_repo_root_scrubs_tainted_git_env exercises only a PLAIN
# (non-submodule) sandbox, where --show-superproject-working-tree is always
# empty, so the super_root arm's scrub path is never taken under taint. This test
# closes that hole: build the same real super+submodule fixture as the #324 test,
# then invoke repo_root from INSIDE the submodule working tree under taint. On an
# unscrubbed probe the tainted GIT_WORK_TREE makes git treat the OUTER repo as
# the work tree, so --show-superproject-working-tree returns EMPTY and repo_root
# falls through to the common-dir arm — which the same taint pins to
# <super>/.git/modules, the exact #324 bug value. With the scrub intact repo_root
# returns the true superproject root instead. The taint must include
# GIT_WORK_TREE, not just GIT_DIR/GIT_COMMON_DIR: from a submodule working tree
# git still detects the superproject from cwd under a GIT_DIR/GIT_COMMON_DIR-only
# taint, so GIT_WORK_TREE is what actually diverges the scrubbed and unscrubbed
# probes (both are on the #279 scrub list, as a real git hook exports them
# together). Deliberately does NOT wrap the invocation in
# `env "${GIT_SCRUB[@]/#/--unset=}"` (unlike the #324 test) — the taint must
# reach repo_root() for the assertion to mean anything (same rationale as
# test_config_repo_root_scrubs_tainted_git_env). Skips cleanly if
# `git submodule add` is unavailable (old git / file protocol disallowed).
test_config_repo_root_submodule_superproject_scrubs_tainted_git_env() {
    local sub super outer name rc=0
    sub="$(command mktemp -d "$WORKDIR/sub.XXXXXX")" || return 1
    super="$(command mktemp -d "$WORKDIR/super.XXXXXX")" || return 1
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    name="mod"
    # Inner submodule repo with one commit so it can be added.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" -c commit.gpgsign=false commit -q --allow-empty -m seed 2>/dev/null || return 1
    # Superproject that embeds it as a submodule.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" config user.name "Test"
    if ! /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" -c protocol.file.allow=always -c commit.gpgsign=false \
        submodule add -q "$sub" "$name" 2>/dev/null; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" -c commit.gpgsign=false commit -qm "add $name" 2>/dev/null || return 1
    # Third, unrelated outer repo whose .git the taint points at.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1

    # Invoke repo_root from INSIDE the submodule working tree UNDER TAINT: the
    # invocation is NOT scrubbed (no `env --unset`), and GIT_DIR/GIT_WORK_TREE/
    # GIT_COMMON_DIR point at the outer repo, so the taint reaches repo_root().
    # GIT_WORK_TREE is essential — it is what makes an unscrubbed super_root probe
    # miss the submodule and fall through to the tainted common-dir arm.
    local out
    out="$(cd "$super/$name" &&
        GIT_DIR="$outer/.git" GIT_WORK_TREE="$outer" GIT_COMMON_DIR="$outer/.git" \
            "$REAL_BASH" -c '. "$1"; repo_root' _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 inside a tainted submodule working tree"
    # Compare realpaths (symlinked /tmp on CI runners).
    local super_real out_real
    super_real="$(cd "$super" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$super_real" "$out_real" \
        "repo_root returns the superproject root, not the tainted outer repo"
}

# Regression (#363, closing the last cell of the readonly-taint × probe-arm 2×2
# matrix). Two independent hardening dimensions cross here: the taint KIND —
# plain exported (a bare `unset` clears it) vs READONLY exported
# (`declare -rx GIT_DIR=…`, which a bare `unset` SILENTLY no-ops, #328) — and the
# probe ARM — the common-dir arm (plain sandbox) vs the super_root arm
# (`--show-superproject-working-tree`, only taken inside a submodule, #324/#337).
# Three cells are already covered:
#   test_config_repo_root_scrubs_tainted_git_env                 (plain × common-dir, #279)
#   test_config_repo_root_scrubs_readonly_tainted_git_env        (readonly × common-dir, #328)
#   test_config_repo_root_submodule_superproject_scrubs_tainted_git_env
#                                                                 (plain × super_root, #337)
# This closes the fourth: readonly × super_root. Both probes route through the
# same _repo_root_git (config.sh), whose `env -u` fallback unexports a readonly
# GIT_* regardless of the attribute, so this is NOT a functional blind spot
# today — but there is no direct regression proving that fallback also protects
# the super_root probe. If a future change ever forked _repo_root_git per-probe
# or added probe-specific scrub logic, a readonly taint against the submodule
# fixture would go unverified; this test is the guard.
#
# Builds the same real super+submodule+outer fixture as the #337 test, then
# invokes repo_root from INSIDE the submodule working tree under a taint passed as
# `declare -rx` (readonly+exported) inside the child bash — so the bare `unset` in
# _repo_root_git FAILS and the `env -u` fallback is what must clear the taint for
# the super_root probe. GIT_WORK_TREE is load-bearing (same rationale as the #337
# test): from a submodule working tree git still detects the superproject from cwd
# under a GIT_DIR/GIT_COMMON_DIR-only taint, so GIT_WORK_TREE is what makes an
# unscrubbed super_root probe miss the submodule and fall through to the tainted
# common-dir arm (which the same taint pins to <super>/.git/modules, the #324
# bug). The invocation is deliberately NOT wrapped in `env --unset` — the taint
# must reach repo_root() for the assertion to mean anything. Skips cleanly if
# `git submodule add` is unavailable (old git / file protocol disallowed).
test_config_repo_root_submodule_superproject_scrubs_readonly_tainted_git_env() {
    local sub super outer name rc=0
    sub="$(command mktemp -d "$WORKDIR/sub.XXXXXX")" || return 1
    super="$(command mktemp -d "$WORKDIR/super.XXXXXX")" || return 1
    outer="$(command mktemp -d "$WORKDIR/outer.XXXXXX")" || return 1
    name="mod"
    # Inner submodule repo with one commit so it can be added.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" config user.name "Test"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sub" -c commit.gpgsign=false commit -q --allow-empty -m seed 2>/dev/null || return 1
    # Superproject that embeds it as a submodule.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" config user.name "Test"
    if ! /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" -c protocol.file.allow=always -c commit.gpgsign=false \
        submodule add -q "$sub" "$name" 2>/dev/null; then
        skip_test "git submodule add unavailable — cannot build the fixture"
        return 0
    fi
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$super" -c commit.gpgsign=false commit -qm "add $name" 2>/dev/null || return 1
    # Third, unrelated outer repo whose .git the taint points at.
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$outer" init -q 2>/dev/null || return 1

    # Invoke repo_root from INSIDE the submodule working tree UNDER a READONLY
    # taint: GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR are `declare -rx` (readonly +
    # exported) inside the child bash before sourcing config.sh, so repo_root's
    # bare `unset` cannot clear them — the `env -u` fallback in _repo_root_git
    # must, on the super_root probe. The invocation is NOT scrubbed (no
    # `env --unset`), so the taint reaches repo_root(). GIT_WORK_TREE is what
    # diverges the scrubbed and unscrubbed super_root probes.
    local out
    out="$(cd "$super/$name" &&
        "$REAL_BASH" -c 'declare -rx GIT_DIR="$2/.git"; declare -rx GIT_WORK_TREE="$2"; declare -rx GIT_COMMON_DIR="$2/.git"; . "$1"; repo_root' \
            _ "$CONFIG" "$outer" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "repo_root exits 0 inside a readonly-tainted submodule working tree"
    # Compare realpaths (symlinked /tmp on CI runners).
    local super_real out_real
    super_real="$(cd "$super" && command pwd -P)"
    out_real="$(cd "$out" 2>/dev/null && command pwd -P || command echo "$out")"
    assert_equals "$super_real" "$out_real" \
        "repo_root returns the superproject root despite a readonly super_root taint"
}

# --- config.sh GIT_ENV_SCRUB_VARS single source (#356) -----------------------

# Regression (#356 / #355): the git hook-exported scrub var list must live in
# exactly ONE place — config.sh's GIT_ENV_SCRUB_VARS, surfaced through
# _git_env_scrub_names — with _repo_root_git and both worktree callers referencing
# it. Before #356 the list was copy-pasted into three files; a future addition
# (e.g. #355's GIT_CONFIG_*) applied to some but not all silently reopens the
# tainted-env vulnerability class (#279/#328), and nothing cross-checked the
# copies. #355 grew the static list to 14 names and added the dynamic
# GIT_CONFIG_KEY_<n>/VALUE_<n> pairs enumerated by _git_env_scrub_names. This
# static guard pins the single source:
#   1. sourcing config.sh yields the exact 14-name list, in order;
#   2. the literal set (fingerprinted by its most-likely-forgotten member
#      GIT_ALTERNATE_OBJECT_DIRECTORIES) appears under plugins/ ONLY in
#      config.sh and exactly once — no site re-lists it;
#   3. both callers scrub via $(_git_env_scrub_names), not a re-listed literal.
test_config_git_env_scrub_vars_single_source() {
    local out rc=0
    # (1) Sourcing config.sh defines GIT_ENV_SCRUB_VARS as the expected list.
    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" -c '. "$1"; command printf "%s" "$GIT_ENV_SCRUB_VARS"' \
        _ "$CONFIG" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "sourcing config.sh succeeds and exposes GIT_ENV_SCRUB_VARS"
    assert_equals \
        "GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM" \
        "$out" \
        "GIT_ENV_SCRUB_VARS is the exact 14-name scrub list, in order (#355)"

    # (1b) The list is a SECURITY INVARIANT: a plain assignment, NOT an
    # env-overridable `: "${GIT_ENV_SCRUB_VARS:=…}"` default. Pre-set a truncated
    # value in the child's environment before sourcing config.sh and confirm the
    # source CLOBBERS it back to the full 14-name list — a compromised git hook (or
    # a harness bug) pre-exporting an empty/short list must NOT be able to shrink
    # the scrub set and defeat the taint defense (#356).
    local override rc2=0
    override="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" GIT_ENV_SCRUB_VARS="GIT_DIR" \
        "$REAL_BASH" -c '. "$1"; command printf "%s" "$GIT_ENV_SCRUB_VARS"' \
        _ "$CONFIG" 2>&1)" || rc2=$?
    assert_exit 0 "$rc2" "sourcing config.sh with a pre-set GIT_ENV_SCRUB_VARS succeeds"
    assert_equals \
        "GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM" \
        "$override" \
        "config.sh clobbers an inherited GIT_ENV_SCRUB_VARS — the scrub set can't be shrunk from the env (#356)"

    # (2) The literal list appears under plugins/ only in config.sh, exactly once.
    # Fingerprint on the trailing member: a re-listed copy elsewhere would name it
    # too. `grep -rc` prints <file>:<count>; expect one line, config.sh, count 1.
    local hits
    hits="$(command grep -rlF 'GIT_ALTERNATE_OBJECT_DIRECTORIES' \
        "$REPO_ROOT/plugins" 2>/dev/null | command sort)"
    assert_equals "$CONFIG" "$hits" \
        "GIT_ALTERNATE_OBJECT_DIRECTORIES appears under plugins/ only in config.sh (#356)"
    local count
    count="$(command grep -cF 'GIT_ALTERNATE_OBJECT_DIRECTORIES' "$CONFIG" 2>/dev/null || command echo 0)"
    assert_equals "1" "$count" \
        "config.sh names the literal scrub set exactly once (the single source)"

    # (3) Both worktree callers scrub via the shared helper, not a literal list.
    assert_file_contains "$WT_NEW" 'unset $(_git_env_scrub_names)' \
        "worktree-new.sh scrubs via the shared _git_env_scrub_names"
    assert_file_contains "$WT_RM" 'unset $(_git_env_scrub_names)' \
        "worktree-rm.sh scrubs via the shared _git_env_scrub_names"

    # (4) _git_env_scrub_names appends the dynamically-indexed GIT_CONFIG_KEY_<n> /
    # GIT_CONFIG_VALUE_<n> pairs present in the environment to the static list —
    # these can't be fixed names (the count is dynamic), so the helper is what
    # keeps them in the scrub set (#355). Pre-set two pairs and assert both indices
    # appear after the 14 static names.
    local pairs rc4=0
    pairs="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        GIT_CONFIG_COUNT=2 \
        GIT_CONFIG_KEY_0=core.worktree GIT_CONFIG_VALUE_0=/x \
        GIT_CONFIG_KEY_1=url.z.insteadOf GIT_CONFIG_VALUE_1=/y \
        "$REAL_BASH" -c '. "$1"; command printf "%s" "$(_git_env_scrub_names)"' \
        _ "$CONFIG" 2>&1)" || rc4=$?
    assert_exit 0 "$rc4" "_git_env_scrub_names runs with GIT_CONFIG_* pairs present"
    assert_contains "$pairs" "GIT_CONFIG_KEY_0" \
        "_git_env_scrub_names enumerates the dynamic GIT_CONFIG_KEY_<n> pairs (#355)"
    assert_contains "$pairs" "GIT_CONFIG_VALUE_1" \
        "_git_env_scrub_names enumerates the dynamic GIT_CONFIG_VALUE_<n> pairs (#355)"
}
