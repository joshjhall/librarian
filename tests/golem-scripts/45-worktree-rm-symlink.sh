# shellcheck shell=bash
# Stale symlink attributes — worktree-rm.sh teardown tests (#768).
#
# Split out of 40-worktree-rm.sh, which this block pushed past the shell
# review-lens high threshold (thresholds.yml `review_size_thresholds`). The
# seam was already cut: these three helpers and eight tests share no state with
# the kill-session / submodule / core.worktree cases next door and touch only
# worktree-rm.sh's `symlink_is_false_dirty` carve-out.
#
# Sourced by tests/validate-golem-scripts.sh, which defines WT_NEW / WT_RM /
# GIT_SCRUB / REAL_BASH and sources tests/lib/golem-sandbox.sh (new_sandbox,
# run_in) BEFORE this file. This fragment only DEFINES test functions; the entry
# point dispatches them from its explicit ordered run_fragment_test list.

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
    local sb="$1" blob="$2" path="$3" real quoted
    real="$(command -v git)"
    # How REAL git renders <path> in `status --porcelain` at the default
    # core.quotePath=true. Ask git itself rather than reimplementing its
    # C-quoting: hand-rolled octal escaping drifts (git escapes only the
    # non-ASCII bytes, `od` would encode every byte), and a fixture that encodes
    # its own idea of the format stops testing the real one.
    #
    # The probe needs a path git will actually REPORT, and the sandbox's link is
    # clean on ext4 — so probe a throwaway untracked file of the same name in a
    # scratch repo, strip the `?? ` prefix, and reuse that rendering.
    # `-c core.quotePath=true` is PINNED, and HOME is repointed at the probe dir:
    # without both, a host whose global ~/.gitconfig already sets
    # `core.quotePath = false` would render the name bare, `quoted` would equal
    # `$path`, and the non-ASCII test would only ever drive the stub's `_bare`
    # branch — passing with OR without the script's fix on exactly the hosts
    # where the ambient config hid the bug. The probe must reflect git's DEFAULT,
    # not the operator's preference.
    quoted="$(
        probe="$(command mktemp -d "$WORKDIR/quote.XXXXXX")" || exit 1
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" HOME="$probe" \
            git -C "$probe" init -q 2>/dev/null
        command touch "$probe/$path" 2>/dev/null
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" HOME="$probe" \
            git -C "$probe" -c core.quotePath=true status --porcelain 2>/dev/null |
            command sed -n '1s/^...//p'
    )"
    # FAIL LOUD on an empty probe — never fall back to the bare path. The probe
    # reports an untracked file, so it always yields a `?? <name>` line; empty
    # means the probe itself broke (mktemp/init/touch failed, all of which are
    # stderr-suppressed). Defaulting to `$path` there would hand the stub a bare
    # name, and when the script under test LACKS the quoting fix (`_bare=0`) the
    # stub would print bare anyway — so the non-ASCII test would pass precisely
    # when the fix is missing. That is the fixture's failure path converging with
    # its pass path ([[gate-and-evidence-converge-tautology]]), the same class of
    # bug this probe was added to fix. A broken probe must redden the run.
    if [ -z "$quoted" ]; then
        command printf 'FATAL: quoting probe produced no output for %s\n' "$path" >&2
        return 1
    fi
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<EOF
#!/usr/bin/env bash
# Test stub (#768): forge the three git observations a stale-attr symlink
# produces on virtiofs; defer everything else to the real git.
_raw=0 _status=0 _wt_remove=0 _forced=0 _bare=0
for a in "\$@"; do
    case "\$a" in
        --raw) _raw=1 ;;
        --force) _forced=1 ;;
        core.quotePath=false) _bare=1 ;;
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
    # Emit the status line the REAL git would produce for a stale-attr <path>,
    # including its C-quoting: when core.quotePath is at its default \`true\`,
    # git renders a non-ASCII path as \` M "caf\\303\\251.md"\`, and honoring the
    # script's \`-c core.quotePath=false\` means emitting the bare path instead.
    # The stub must respect that flag rather than always printing bare, or the
    # non-ASCII test would assert the stub's own output and pass with OR without
    # the fix. \$_bare is set from the parsed argv above.
    if [ "\$_bare" = 1 ]; then
        command printf ' M %s\n' "$path"
    else
        command printf ' M %s\n' "$quoted"
    fi
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

# _plant_git_raw_stub_multi <sandbox> <blobA> <pathA> <blobB> <pathB> — as
# _plant_git_raw_stub but forging TWO stale symlinks, so the accumulator and the
# `forced past N` disclosure can be pinned at N=2 (the motivating #760 shape).
# `status` reports both links; `diff --raw` answers per-path, keyed off the
# `--` operand the helper passes.
_plant_git_raw_stub_multi() {
    local sb="$1" blob_a="$2" path_a="$3" blob_b="$4" path_b="$5" real
    real="$(command -v git)"
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/git" <<EOF
#!/usr/bin/env bash
# Test stub (#768): forge TWO stale-attr symlinks; defer everything else.
_raw=0 _status=0 _wt_remove=0 _forced=0
for a in "\$@"; do
    case "\$a" in
        --raw) _raw=1 ;;
        --force) _forced=1 ;;
    esac
done
case " \$* " in *" status "*) _status=1 ;; esac
case " \$* " in *" worktree remove "*) _wt_remove=1 ;; esac

if [ "\$_raw" = 1 ]; then
    # Answer for whichever path the helper asked about.
    case " \$* " in
        *" $path_a"*) command printf ':120000 120000 %s 0000000 M\t%s\n' "$blob_a" "$path_a" ;;
        *" $path_b"*) command printf ':120000 120000 %s 0000000 M\t%s\n' "$blob_b" "$path_b" ;;
    esac
    exit 0
fi
if [ "\$_status" = 1 ]; then
    command printf ' M %s\n' "$path_a"
    command printf ' M %s\n' "$path_b"
    exec "$real" "\$@"
fi
if [ "\$_wt_remove" = 1 ] && [ "\$_forced" = 0 ]; then
    command printf 'fatal: contains modified or untracked files\n' >&2
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
    _plant_git_raw_stub "$sb" "$blob" AGENTS.md || return 1
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
    _plant_git_raw_stub "$sb" "$blob" AGENTS.md || return 1
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

# A NON-ASCII symlink path must reach the carve-out (#768 review). At git's
# default `core.quotePath=true`, `status --porcelain` reports `café.md` as
# ` M "caf\303\251.md"` — C-quoted with octal escapes — and the fixed-width
# `${line#???}` strip then yields that literal escaped string, which no `[ -L ]`
# can find. The failure is CLOSED (teardown refuses rather than discarding
# work), which is why no other assertion here catches it: the suite would stay
# green while the carve-out silently never fired for an internationalized path,
# re-creating the very deadlock this issue fixes. The script pins
# `-c core.quotePath=false`; this test is what keeps that from being dropped.
test_worktree_rm_forces_past_stale_symlink_non_ascii_path() {
    local sb blob link='café.md'
    _sandbox_with_symlink sb "$link" CLAUDE.md || return 1
    run_in "$sb" "$WT_NEW" 66
    assert_exit 0 "$RUN_RC" "worktree-new succeeds with a non-ASCII symlink path"
    blob="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb/.worktrees/issue-66" rev-parse "HEAD:$link" 2>/dev/null || true)"
    assert_not_empty "$blob" "the non-ASCII symlink has an index blob"
    _plant_git_raw_stub "$sb" "$blob" "$link" || return 1
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
            "$REAL_BASH" "$WT_RM" 66 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "worktree-rm tears down past a stale-attr non-ASCII symlink"
    assert_contains "$RUN_OUT" "stale symlink attr" \
        "the carve-out fires for a non-ASCII path, not only an ASCII one"
    assert_true "[ ! -e '$sb/.worktrees/issue-66' ]" \
        "the worktree directory is gone after rm"
}

# TWO stale symlinks are counted and disclosed as 2 — the motivating #760 case
# had exactly two (AGENTS.md and .codegraph), and every other test here stubs a
# single link, so the accumulator was otherwise pinned only at N=1 where a
# `stale_links=1` assignment would pass just as well as `+= 1`.
test_worktree_rm_counts_multiple_stale_symlinks() {
    local sb blob_a blob_b
    _sandbox_with_symlink sb AGENTS.md CLAUDE.md || return 1
    # A second committed symlink, mirroring .codegraph in the real fixture.
    (cd "$sb" && command ln -s CLAUDE.md SECOND.md)
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" git -C "$sb" add -A 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb" commit -qm "second symlink" 2>/dev/null
    run_in "$sb" "$WT_NEW" 67
    assert_exit 0 "$RUN_RC" "worktree-new succeeds with two committed symlinks"
    blob_a="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb/.worktrees/issue-67" rev-parse HEAD:AGENTS.md 2>/dev/null || true)"
    blob_b="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$sb/.worktrees/issue-67" rev-parse HEAD:SECOND.md 2>/dev/null || true)"
    _plant_git_raw_stub_multi "$sb" "$blob_a" AGENTS.md "$blob_b" SECOND.md
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
            "$REAL_BASH" "$WT_RM" 67 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "worktree-rm tears down past two stale-attr symlinks"
    assert_contains "$RUN_OUT" "forced past 2 stale symlink attr(s)" \
        "the disclosure counts BOTH stale symlinks, not just one"
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
