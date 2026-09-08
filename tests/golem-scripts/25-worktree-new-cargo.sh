# shellcheck shell=bash
# worktree-new.sh — per-worktree CARGO_TARGET_DIR seeding (issue #944).
#
# Covers the prevention half of the virtiofs worktree wedge: worktree-new.sh
# seeds `env.CARGO_TARGET_DIR` into the worktree's `.claude/settings.local.json`
# so Rust build artifacts land OFF the repo mount, gated on a runtime probe that
# the cache location is present, writable, and not itself on a wedging
# filesystem.
#
# Its own area file rather than growth in 20-worktree-new.sh: that fragment
# measured 663 production LOC against a 700 budget, and these cases project it
# to ~793 (plan-lens).
#
# librarian has no Rust, so every fixture SYNTHESIZES the condition — nothing
# here depends on repo content, and no test touches the real /cache.
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts and
# sources tests/lib/golem-sandbox.sh BEFORE this file. Note run_in() pins
# GOLEM_CARGO_CACHE_DIR at a nonexistent sandbox path, so these tests invoke
# worktree-new.sh directly with their own value rather than through run_in.

# --- helpers (used only by this area, so they stay here) --------------------

# _cargo_run <sandbox> <cache-dir> <issue-N> [extra-env...]
# Invoke worktree-new.sh from the sandbox with GOLEM_CARGO_CACHE_DIR set to the
# caller's value and the local-file copy ENABLED (the seed writes the copied
# settings file). Captures combined output in RUN_OUT / exit code in RUN_RC.
_cargo_run() {
    local dir="$1" cache="$2" n="$3"
    shift 3
    RUN_RC=0
    RUN_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$dir" \
            GOLEM_PLUGIN_PROBE="$dir/no-plugin-probe" \
            TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$dir/.tmux}" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES=".claude/settings.local.json" \
            GOLEM_CARGO_CACHE_DIR="$cache" \
            "$@" \
            "$REAL_BASH" "$WT_NEW" "$n" 2>&1)" || RUN_RC=$?
}

# _seed_local_settings <sandbox> — plant a settings.local.json carrying a
# pre-existing key, so the merge tests can assert it SURVIVES.
_seed_local_settings() {
    command mkdir -p "$1/.claude"
    command printf '{"permissions":{"allow":["Bash(marker)"]}}\n' \
        >"$1/.claude/settings.local.json"
}

# _commit_gitignore <sandbox> — give the sandbox the TRACKED .gitignore that
# real repos have for the settings file. The seed refuses to write a path git
# does not already ignore (writing one would make the worktree read dirty and
# break teardown), so a sandbox without this covers only the refusal path.
_commit_gitignore() {
    command printf '.claude/settings.local.json\n.worktrees/\n' >"$1/.gitignore"
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git -C "$1" add .gitignore 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$1" -c commit.gpgsign=false commit -qm gitignore 2>/dev/null
}

# _cargo_target_of <sandbox> <issue-N> — echo the seeded CARGO_TARGET_DIR from
# the worktree's settings file, or nothing when absent/unparseable.
_cargo_target_of() {
    command jq -r '.env.CARGO_TARGET_DIR // empty' \
        "$1/.worktrees/issue-$2/.claude/settings.local.json" 2>/dev/null
}

# --- tests ------------------------------------------------------------------

# Happy path: a suitable cache dir seeds a per-worktree CARGO_TARGET_DIR into
# the copied settings file, and pre-existing keys survive the merge.
#
# This is the test the whole area turns on. The first implementation passed
# every no-op case below while seeding NOTHING — the mount-prefix match built
# `//*` for the root mountpoint, so any path not under a deeper mount probed as
# UNKNOWN and silently refused. Only a positive assertion catches that.
test_worktree_new_cargo_seeds_target_dir() {
    local sb
    new_sandbox sb
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq unavailable — the seed is jq-gated by design"
        return
    fi
    _commit_gitignore "$sb"
    _seed_local_settings "$sb"
    local cache="$sb/cache"
    command mkdir -p "$cache"

    _cargo_run "$sb" "$cache" 41
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 when seeding the cargo target dir"
    assert_equals "$cache/issue-41" "$(_cargo_target_of "$sb" 41)" \
        "CARGO_TARGET_DIR is seeded per-worktree into settings.local.json"
    assert_contains "$RUN_OUT" "seeded CARGO_TARGET_DIR" "reports the seed"
    assert_true "[ -d \"$cache/issue-41\" ]" "The per-worktree target dir is created"

    # The merge must not clobber what the operator's copied settings carried.
    local kept
    kept="$(command jq -r '.permissions.allow[0] // empty' \
        "$sb/.worktrees/issue-41/.claude/settings.local.json" 2>/dev/null)"
    assert_equals "Bash(marker)" "$kept" \
        "the pre-existing settings keys survive the env merge"
}

# Per-worktree, not shared (#944 AC2): two issues in the SAME cache root must
# get DIFFERENT target dirs, or parallel golems serialise on cargo's file lock.
test_worktree_new_cargo_target_is_per_worktree() {
    local sb
    new_sandbox sb
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq unavailable — the seed is jq-gated by design"
        return
    fi
    _commit_gitignore "$sb"
    local cache="$sb/cache"
    command mkdir -p "$cache"

    _cargo_run "$sb" "$cache" 42
    _cargo_run "$sb" "$cache" 43
    local a b
    a="$(_cargo_target_of "$sb" 42)"
    b="$(_cargo_target_of "$sb" 43)"
    assert_equals "$cache/issue-42" "$a" "issue 42 gets its own target dir"
    assert_equals "$cache/issue-43" "$b" "issue 43 gets its own target dir"
    assert_true "[ \"$a\" != \"$b\" ]" \
        "Parallel worktrees get distinct target dirs (a shared one serialises cargo's lock)"
}

# AC4: an ABSENT cache location leaves behaviour unchanged — no write, and no
# new output line. Asserting the absence of the line (not just of the setting)
# is what pins "byte-identical", the property an operator on a bare host relies
# on.
test_worktree_new_cargo_absent_cache_is_noop() {
    local sb
    new_sandbox sb
    _commit_gitignore "$sb"
    _seed_local_settings "$sb"

    _cargo_run "$sb" "$sb/nonexistent/deeper/still" 44
    assert_exit 0 "$RUN_RC" "worktree-new still exits 0 with no cache location"
    assert_not_contains "$RUN_OUT" "seeded CARGO_TARGET_DIR" \
        "emits no cargo line when the cache location is absent"
    assert_equals "" "$(_cargo_target_of "$sb" 44)" \
        "writes no CARGO_TARGET_DIR when the cache location is absent"
    # The copied file must be untouched, not merely lacking the key.
    local kept
    kept="$(command jq -r '.permissions.allow[0] // empty' \
        "$sb/.worktrees/issue-44/.claude/settings.local.json" 2>/dev/null)"
    assert_equals "Bash(marker)" "$kept" "the copied settings file is left as-is"
}

# AC3/AC4: an UNWRITABLE cache location is refused the same way. Running as root
# defeats the permission bit, so skip rather than assert a false pass.
test_worktree_new_cargo_unwritable_cache_is_noop() {
    local sb
    new_sandbox sb
    _commit_gitignore "$sb"
    local cache="$sb/rocache"
    command mkdir -p "$cache"
    command chmod 500 "$cache" 2>/dev/null || true
    if [ -w "$cache" ]; then
        command chmod 700 "$cache" 2>/dev/null || true
        skip_test "cache dir still writable after chmod 500 (running as root?)"
        return
    fi

    _cargo_run "$sb" "$cache" 45
    local rc="$RUN_RC" out="$RUN_OUT"
    command chmod 700 "$cache" 2>/dev/null || true

    assert_exit 0 "$rc" "worktree-new still exits 0 with an unwritable cache location"
    assert_not_contains "$out" "seeded CARGO_TARGET_DIR" \
        "emits no cargo line when the cache location is unwritable"
    assert_equals "" "$(_cargo_target_of "$sb" 45)" \
        "writes no CARGO_TARGET_DIR when the cache location is unwritable"
}

# AC3: the filesystem-type probe classifies the wedging mounts as unsuitable.
# A test cannot mount a virtiofs to run against, so this asserts on the script's
# OWN refusal arm, read out of the file — not on a re-spelling of the case
# statement here. A local copy would pass happily while the script's arms said
# something else (the parity-gate-hides-a-shared-defect shape), and deleting an
# arm from the script is exactly the regression worth catching.
#
# virtiofs is the measured culprit (#936); fuse.* is the bindfs overlay above
# it; 9p is the same host-passthrough class; and an EMPTY type (no
# /proc/mounts, e.g. a bare macOS host) must also refuse, since seeding onto an
# unknown mount could relocate the very wedge this prevents.
test_worktree_new_cargo_refuses_wedging_filesystems() {
    local arms
    arms="$(command sed -n 's/^        "" | virtiofs.*$/&/p' "$WT_NEW")"
    assert_contains "$arms" "virtiofs" \
        "the script's refusal arm names virtiofs (the measured culprit, #936)"
    assert_contains "$arms" "fuse.*" \
        "the script's refusal arm covers the fuse/bindfs overlay above it"
    assert_contains "$arms" "9p" \
        "the script's refusal arm covers the 9p host-passthrough class"
    # The EMPTY arm is the fail-safe direction: an undeterminable fs (no
    # /proc/mounts, e.g. a bare macOS host) must refuse rather than seed onto a
    # mount that might be the wedging one.
    assert_contains "$arms" '""' \
        "an unknown filesystem type refuses rather than seeding blind"
}

# The probe must resolve a path under the ROOT mountpoint. Regression for the
# first implementation's `//*` prefix bug: `/` is a mountpoint on every system,
# so building the glob without stripping its trailing slash made every path
# outside a deeper mount probe as UNKNOWN — which the refuse-on-unknown rule
# then correctly-but-uselessly rejected, disabling the feature everywhere while
# every no-op test stayed green.
test_worktree_new_cargo_fstype_resolves_under_root_mount() {
    if [ ! -r /proc/mounts ]; then
        skip_test "/proc/mounts unreadable — the probe is Linux-only by design"
        return
    fi
    local fn fs
    fn="$(command sed -n '/^cargo_cache_fstype() {/,/^}/p' "$WT_NEW")"
    assert_not_empty "$fn" \
        "cargo_cache_fstype could be sliced out of worktree-new.sh (guards a vacuous pass)"
    fs="$(
        eval "$fn"
        cargo_cache_fstype /
    )"
    assert_not_empty "$fs" \
        "the fs probe resolves the ROOT mountpoint — empty means the '//*' prefix bug is back"

    # The root case alone cannot exercise the LONGEST-prefix comparison, since
    # `/` is a prefix of everything and wins by default. Pick a real nested
    # mountpoint and assert the probe reports ITS type rather than the root's:
    # that is the `${#mp} -ge ${#best_mp}` arm doing work. Without this the
    # comparison could be deleted entirely and the root test would stay green.
    local nested nested_fs root_fs
    nested="$(command awk '$2 != "/" && $3 != "" { print $2; exit }' /proc/mounts)"
    if [ -z "$nested" ]; then
        skip_test "no nested mountpoint available to exercise longest-prefix"
        return
    fi
    nested_fs="$(command awk -v m="$nested" '$2 == m { print $3; exit }' /proc/mounts)"
    root_fs="$(command awk '$2 == "/" { print $3; exit }' /proc/mounts)"
    fs="$(
        eval "$fn"
        cargo_cache_fstype "$nested"
    )"
    assert_equals "$nested_fs" "$fs" \
        "a nested mountpoint reports ITS OWN fstype — the longest-prefix arm wins over '/'"
    # Guard the guard: if the nested mount happens to share the root's type the
    # assertion above proves nothing, so say so rather than bank a vacuous pass.
    if [ "$nested_fs" = "$root_fs" ]; then
        skip_test "nested mount shares the root fstype ($root_fs) — longest-prefix not distinguishable here"
    fi
}

# AC3, the symlink direction: the fs probe must classify the mount that will
# actually hold the writes, not the one containing the path STRING. /proc/mounts
# lists RESOLVED mountpoints, so a literal-path prefix match reads the wrong
# mount whenever the cache dir (or an ancestor) is a symlink. Measured: one
# directory reads `overlay` through a /tmp symlink and `tmpfs` at its real
# /dev/shm path. The dangerous direction is a FALSE NEGATIVE — a benign fstype
# reported for a target whose real backing store is virtiofs, which is exactly
# what AC3 exists to refuse.
#
# Exercised end-to-end through the real script rather than against the sliced
# function, because the canonicalization lives in the CALLER: a function-level
# test would keep passing if the caller stopped canonicalizing.
test_worktree_new_cargo_probes_through_a_symlinked_cache_dir() {
    local sb
    new_sandbox sb
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq unavailable — the seed is jq-gated by design"
        return
    fi
    if ! command -v readlink >/dev/null 2>&1 ||
        ! command readlink -f / >/dev/null 2>&1; then
        skip_test "readlink -f unavailable — canonicalization degrades to the raw path"
        return
    fi
    _commit_gitignore "$sb"
    local real="$sb/real-cache" link="$sb/linked-cache"
    command mkdir -p "$real"
    command ln -sfn "$real" "$link"

    # Seeding THROUGH the symlink must still work, and the recorded target must
    # be usable. The canonicalized path is what the probe classifies; the value
    # written stays the operator's configured spelling.
    _cargo_run "$sb" "$link" 49
    assert_exit 0 "$RUN_RC" "worktree-new exits 0 with a symlinked cache dir"
    assert_contains "$RUN_OUT" "seeded CARGO_TARGET_DIR" \
        "a symlinked cache dir on a suitable fs still seeds (probe followed the link)"
    # The real directory is where the artifacts land, so it must exist.
    assert_true "[ -d \"$real/issue-49\" ]" \
        "The per-worktree target dir is created behind the symlink"
    # Pin the caller-side canonicalization directly: the fstype reported for the
    # link must equal the one for its resolved target. Before the fix these
    # differed whenever the two paths sat on different mounts.
    local fn via direct
    fn="$(command sed -n '/^cargo_cache_fstype() {/,/^}/p' "$WT_NEW")"
    assert_not_empty "$fn" "cargo_cache_fstype could be sliced out (guards a vacuous pass)"
    via="$(
        eval "$fn"
        cargo_cache_fstype "$(command readlink -f "$link")"
    )"
    direct="$(
        eval "$fn"
        cargo_cache_fstype "$real"
    )"
    assert_equals "$direct" "$via" \
        "the canonicalized path classifies as the mount that really backs the target"
}

# AC5 — the trap that sinks the naive `.cargo/config.toml` version: whatever the
# seed writes must NOT make the worktree read dirty, so teardown still succeeds.
# Measured on git 2.55: a per-worktree `.git/worktrees/<wt>/info/exclude` is NOT
# honored, so an untracked `.cargo/` shows as `?? .cargo/` and worktree-rm.sh
# refuses. settings.local.json avoids this only because the TRACKED .gitignore
# already covers it — a fact this test pins rather than assumes.
test_worktree_new_cargo_seed_leaves_worktree_clean() {
    local sb
    new_sandbox sb
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq unavailable — the seed is jq-gated by design"
        return
    fi
    _commit_gitignore "$sb"
    _seed_local_settings "$sb"
    local cache="$sb/cache"
    command mkdir -p "$cache"

    _cargo_run "$sb" "$cache" 46
    assert_equals "$cache/issue-46" "$(_cargo_target_of "$sb" 46)" \
        "the seed landed (guards against a vacuous clean/teardown pass below)"

    local st
    st="$(cd "$sb/.worktrees/issue-46" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git status --porcelain 2>&1)"
    assert_equals "" "$st" "the seeded worktree still reads CLEAN to git"

    local rc=0 out
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$sb/.tmux}" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" "$WT_RM" 46 2>&1)" || rc=$?
    assert_exit 0 "$rc" "teardown succeeds after the seed — no dirty refusal"
    assert_not_contains "$out" "uncommitted" "teardown does not report uncommitted changes"
}

# The write's failure branch: a MALFORMED existing settings file makes the jq
# merge fail, and the contract is that the original is left untouched and the
# temp file cleaned up — the corruption-avoidance property the adjacent
# tmp-file+atomic-mv discipline exists to guarantee. Without this, a future
# change that mv'd a failed/empty temp over the original, or skipped the rm,
# would pass the whole suite.
test_worktree_new_cargo_malformed_settings_leaves_original_intact() {
    local sb
    new_sandbox sb
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq unavailable — the seed is jq-gated by design"
        return
    fi
    _commit_gitignore "$sb"
    # Not valid JSON, so `jq '.env = ...'` over it fails.
    command mkdir -p "$sb/.claude"
    command printf 'this is not json {{{\n' >"$sb/.claude/settings.local.json"
    local cache="$sb/cache"
    command mkdir -p "$cache"

    _cargo_run "$sb" "$cache" 50
    assert_exit 0 "$RUN_RC" "worktree-new still exits 0 when the settings file is malformed"
    assert_not_contains "$RUN_OUT" "seeded CARGO_TARGET_DIR" \
        "reports no seed when the jq merge could not be performed"
    # The original bytes must survive verbatim — not be truncated or replaced.
    local body
    body="$(command cat "$sb/.worktrees/issue-50/.claude/settings.local.json" 2>/dev/null)"
    assert_contains "$body" "this is not json" \
        "the malformed original is left byte-intact, never half-written"
    # And the temp file must not be left behind.
    local leftovers
    leftovers="$(command find "$sb/.worktrees/issue-50/.claude" -name '*.944.*' 2>/dev/null)"
    assert_equals "" "$leftovers" "the failed write's temp file is cleaned up"
}

# The seed refuses to write a settings file the repo does NOT already ignore.
# This is the generalisation of AC5 to a consuming repo: librarian's own
# .gitignore covers the path, but a repo without it would get an untracked
# `.claude/` — the worktree reads dirty and worktree-rm.sh refuses teardown on
# every golem, which is precisely the failure that ruled out `.cargo/config.toml`.
# Regression: the first implementation omitted this check and turned 18 unrelated
# worktree-rm tests red with `?? .claude/`.
test_worktree_new_cargo_unignored_settings_is_noop() {
    local sb
    new_sandbox sb
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq unavailable — the seed is jq-gated by design"
        return
    fi
    # Deliberately NO _commit_gitignore: the sandbox does not ignore the path.
    # Everything ELSE is the seeding configuration — a present, writable cache
    # dir on a suitable fs, with jq available — so the only reason the seed can
    # decline is the ignore check. Without that, this would pass vacuously on
    # any sandbox where the seed never had a chance to fire.
    local cache="$sb/cache"
    command mkdir -p "$cache"

    _cargo_run "$sb" "$cache" 48
    # Snapshot immediately: RUN_OUT/RUN_RC are globals that the control run
    # below overwrites, and asserting on them afterwards would silently inspect
    # the CONTROL's output instead of this one's.
    local subject_rc="$RUN_RC" subject_out="$RUN_OUT"
    assert_exit 0 "$subject_rc" "worktree-new still exits 0 when the settings path is not ignored"
    assert_not_contains "$subject_out" "seeded CARGO_TARGET_DIR" \
        "does not seed into a repo that would show the settings file as untracked"

    # The control: the SAME configuration in a repo that DOES ignore the path
    # seeds. Without it the assertion above could pass for any unrelated reason
    # the seed declined, and would stop being evidence about the ignore check.
    local sb2
    new_sandbox sb2
    _commit_gitignore "$sb2"
    local cache2="$sb2/cache"
    command mkdir -p "$cache2"
    _cargo_run "$sb2" "$cache2" 48
    assert_equals "$cache2/issue-48" "$(_cargo_target_of "$sb2" 48)" \
        "control: the identical setup DOES seed when the path is gitignored"
    local st
    st="$(cd "$sb/.worktrees/issue-48" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git status --porcelain 2>&1)"
    assert_equals "" "$st" \
        "the worktree stays CLEAN — no '?? .claude/' to block teardown"
}

# The seed is jq-gated and best-effort: with jq off PATH it must skip cleanly,
# leaving an otherwise-good worktree rather than failing the run. Mirrors the
# jq-absent posture of seed-worktree-trust.sh.
test_worktree_new_cargo_no_jq_is_noop() {
    local sb
    new_sandbox sb
    _commit_gitignore "$sb"
    _seed_local_settings "$sb"
    local cache="$sb/cache"
    command mkdir -p "$cache"
    # A PATH holding every tool the script reaches for EXCEPT jq. The tool list
    # is DERIVED from the sources rather than hand-written: worktree-new.sh and
    # the config.sh it sources call externals as `command <tool>`, so scrape
    # those names. A hand-listed allow-list is a standing trap — it drifts as
    # either script reaches for one more binary, and the run then dies 127 for a
    # reason unrelated to jq (measured: a missing `env` from config.sh did
    # exactly that here).
    #
    # Shadowing jq with a non-executable file does NOT work as an alternative:
    # `command -v` skips a non-executable entry and finds the real jq further
    # along the path (also measured).
    # Two additions on top of the scrape, each for a distinct reason:
    #   * bash/sh — the scripts invoke the interpreter without a `command `
    #     prefix (and config.sh re-execs through `env`), so a PATH built purely
    #     from the scrape dies 127 on the INTERPRETER, a failure that looks
    #     exactly like the jq path under test;
    #   * sed/uname/cmp/tr — git's own `git-submodule`/`git-sh-setup` helpers
    #     shell out to these, and their absence prints `uname: not found` noise
    #     into the captured output that the assertions below would then be
    #     reading around.
    command mkdir -p "$sb/binnojq"
    local tool tools
    tools="$(command sed -n 's/.*command \([a-z][a-z]*\).*/\1/p' \
        "$WT_NEW" "$SCRIPTS/config.sh" | command sort -u)"
    for tool in $tools bash sh sed uname cmp tr; do
        [ "$tool" = "jq" ] && continue
        if command -v "$tool" >/dev/null 2>&1; then
            command ln -sf "$(command -v "$tool")" "$sb/binnojq/$tool" 2>/dev/null || true
        fi
    done
    # Guard the derivation itself: if the scrape came back empty or without the
    # tools the script cannot run without, this test would "pass" by failing for
    # the wrong reason.
    assert_true "[ -x \"$sb/binnojq/git\" ]" "The jq-absent fixture provides git"
    assert_true "[ ! -e \"$sb/binnojq/jq\" ]" "The jq-absent fixture does NOT provide jq"
    # BASH_ENV must be cleared alongside the PATH override, or the fixture does
    # nothing: this image sets BASH_ENV=/etc/bash_env, whose /etc/bashrc.d/*.sh
    # re-export a full PATH into every non-interactive bash — so the narrowed
    # PATH is silently restored and `jq` is found again (measured). The test
    # would then assert the jq-PRESENT path while claiming to cover its absence.
    _cargo_run "$sb" "$cache" 47 PATH="$sb/binnojq" BASH_ENV=
    assert_exit 0 "$RUN_RC" "worktree-new still exits 0 with jq absent"
    assert_not_contains "$RUN_OUT" "seeded CARGO_TARGET_DIR" \
        "emits no cargo line when jq is unavailable"
    assert_file_exists "$sb/.worktrees/issue-47/.claude/settings.local.json" \
        "the worktree is otherwise good — the copied settings file is present"
}
