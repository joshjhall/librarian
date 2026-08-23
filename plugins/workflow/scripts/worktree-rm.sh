#!/usr/bin/env bash
# worktree-rm.sh — post-merge cleanup: remove the issue-N worktree and its
# branch (clean no-op if absent).
#
# Replaces the containers `worktree-rm` just recipe so the golem/worktree flow
# runs WITHOUT `just`, on host / bare Linux / inside a devcontainer.
#
# Removes <GOLEM_WORKTREE_DIR>/issue-N, deletes branch <GOLEM_BRANCH_PREFIX>N,
# and kills the golem's tmux session golem-N (idempotent — ignore-if-absent),
# so worktree teardown and session teardown are ONE step and finished golems
# don't linger in `tmux ls` / golem-status.sh after a merge+prune (#27).
# Refuses to remove a worktree with uncommitted changes (re-run after
# committing, or force with `git worktree remove --force`).
#
# Belt-and-suspenders: after teardown it repairs a polluted main-repo
# `core.worktree` (#258). An interrupted `git worktree remove --force` can leave
# the MAIN checkout's .git/config with a stale `core.worktree` pointing at the
# just-removed worktree, which silently breaks it — `git status` shows the whole
# tree as deleted and `git rev-parse --is-inside-work-tree` returns false. No
# script legitimately sets `core.worktree` on the main config, so one pointing at
# a non-existent path is unambiguous corruption and is safe to unset.
#
# Config (env-overridable; defaults in config.sh):
#   GOLEM_WORKTREE_DIR (.worktrees)   GOLEM_BRANCH_PREFIX (feature/issue-)
#
# NOTE: the containers recipe also refreshed a bare host's on-disk runtime
# copies (.claude/hooks, justfile, bin) from origin/main after teardown — that
# was specific to the containers repo's bare-host golem layout and its
# bin/sync-host.sh, so it is intentionally NOT carried into this portable
# script.
#
# Usage: worktree-rm.sh <issue-number>
set -euo pipefail

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

# Scrub git's hook-exported environment process-wide (#328). repo_root()
# (config.sh) already scrubs its OWN rev-parse subshell (#279), but this script
# then runs its own git MUTATIONS below (worktree remove / branch -D /
# config --unset core.worktree / worktree prune); a tainted GIT_DIR/GIT_COMMON_DIR
# forwarded from a git hook would redirect those to an OUTER repo — deleting a
# branch or unsetting core.worktree in the wrong checkout. `cd "$root"` does not
# re-anchor git while GIT_DIR is set, so unset the whole set here, before
# repo_root() and every other git call. Deliberately NO `|| true`: a readonly
# GIT_DIR makes `unset` fail, which under `set -e` aborts LOUDLY before any
# mutation — the fail-loud outcome, never a silent wrong-repo write. Uses
# config.sh's shared _git_env_scrub_names (#356 / #355) so the scrub set — static
# vars PLUS the dynamic GIT_CONFIG_KEY_<n>/VALUE_<n> pairs — stays in lockstep
# with repo_root()'s and worktree-new.sh's, one source of truth.
# shellcheck disable=SC2046  # intentional word-split: unset each scrub var by name
unset $(_git_env_scrub_names)

N="${1:-}"
if ! [[ "$N" =~ ^[0-9]+$ ]]; then
    command echo "worktree-rm: N must be an issue number, got '$N'" >&2
    exit 2
fi

# symlink_is_false_dirty <worktree> <path> — true when <path> is a SYMLINK that
# git reports modified but whose target is byte-identical to the index (#768).
#
# On a macOS Docker bind mount (virtiofs/bindfs) a committed symlink can report
# stale stat attributes — `nlink=0 size=0`. `size=0` defeats git's stat
# comparison, so git marks the link `M` unconditionally and the dirty gate below
# reads it as uncommitted work that does not exist. Since #662/#665 (correctly)
# deny a main-session `git worktree remove --force` against a linked worktree,
# and this script is the sanctioned alternative, the false positive leaves NO
# working teardown path at all. Observed on .worktrees/issue-760 (AGENTS.md ->
# CLAUDE.md, .codegraph -> /cache/codegraph).
#
# The condition cannot be cleaned up from inside the worktree — `ln -sfn` clears
# it for minutes at most, and `git update-index --really-refresh` just prints
# `needs update` — so it has to be DISTINGUISHED here.
#
# READLINK-VS-INDEX IS THE LOAD-BEARING TEST; the mode check alone is a
# TAUTOLOGY. It is tempting to key off `git diff --raw` showing an unchanged
# `120000` mode and an all-zero destination hash, but a symlink whose target
# GENUINELY changed produces exactly that same shape:
#
#   :120000 120000 4cbb553 0000000 M   link.md    <- target really changed
#   :120000 120000 681311e 0000000 M   AGENTS.md  <- stale attrs, target identical
#
# The destination hash is all-zero in BOTH cases (git stages no blob for an
# unstaged change either way), so a check written against mode+hash would wave
# through every modified symlink and silently discard real work. Only comparing
# the on-disk target to the INDEX BLOB separates them. The mode test is kept
# purely as a cheap gate confirming we are looking at a symlink pair at all.
#
# FAIL-CLOSED everywhere: an unreadable blob, a missing file, a non-symlink, or
# any unexpected `--raw` shape returns non-zero, so teardown REFUSES rather than
# forcing past something it did not understand. A symlink whose target actually
# differs is real work and must still block.
#
# MUTATION-VERIFIED. Neutering the readlink comparison must turn the
# retargeted-symlink test red, and dropping the residue filter must turn the
# dirty-regular-file test red; both confirmed. The first mutation initially
# SURVIVED, and the reason is worth recording: the retarget fixture pointed the
# link at an UNCOMMITTED file, so `?? OTHER.md` kept the residue non-empty by
# itself and the refusal never depended on the symlink check at all — the fixture
# both armed and satisfied the gate. With the readlink test neutered and the
# destination committed, a genuinely retargeted symlink WAS silently discarded.
# The `src_mode` gate below is unreachable from this script's own call path (a
# type change is ` T `, and only ` M ` lines are routed here) and is kept as
# defensive depth for any future caller, not claimed as tested.
#
# Pure bash-3.2 + coreutils; no GNU-only regex (BSD `grep`/`sed` read `\s`/`\|`
# as literals, per project convention).
symlink_is_false_dirty() {
    local wtdir="$1" path="$2" raw src_mode dst_mode blob idx target

    # A symlink must still BE a symlink on disk; a delete or a replace-with-file
    # is real work.
    [ -L "$wtdir/$path" ] || return 1

    raw="$(command git -C "$wtdir" diff --raw -- "$path" 2>/dev/null || true)"
    [ -n "$raw" ] || return 1

    # `:<srcmode> <dstmode> <srcblob> <dstblob> <status>\t<path>`
    src_mode="$(command printf '%s' "$raw" | command awk '{print $1}')"
    src_mode="${src_mode#:}"
    dst_mode="$(command printf '%s' "$raw" | command awk '{print $2}')"
    blob="$(command printf '%s' "$raw" | command awk '{print $3}')"

    # Both sides must be symlink mode — a type change (link -> regular file)
    # is real work.
    [ "$src_mode" = "120000" ] || return 1
    [ "$dst_mode" = "120000" ] || return 1
    [ -n "$blob" ] || return 1

    # An all-zero source blob means git has no indexed content to compare
    # against; treat as real work rather than guessing.
    case "$blob" in *[!0]*) ;; *) return 1 ;; esac

    idx="$(command git -C "$wtdir" cat-file -p "$blob" 2>/dev/null)" || return 1
    target="$(command readlink "$wtdir/$path" 2>/dev/null)" || return 1

    # THE test: the indexed link target and the on-disk one must match exactly.
    [ "$idx" = "$target" ]
}

root="$(repo_root)"
cd "$root"
wt="$GOLEM_WORKTREE_DIR/issue-$N"
br="${GOLEM_BRANCH_PREFIX}${N}"
removed=0

if command git worktree list --porcelain | command grep -qx "worktree $root/$wt"; then
    if command git worktree remove "$wt" 2>/dev/null; then
        command echo "  removed worktree $wt"
        removed=1
    else
        # Plain `git worktree remove` refuses a worktree that contains a
        # POPULATED submodule ("working trees containing submodules cannot be
        # moved or removed") even when the submodule is clean — and
        # worktree-new.sh now populates submodules on creation (#325), so this
        # now fires on ORDINARY teardown, not just on genuine uncommitted work.
        # Distinguish the two before forcing: `status --ignore-submodules=all`
        # reports only NON-submodule changes, so an EMPTY result means the
        # submodule presence is the sole blocker → safe to force-remove; a
        # NON-EMPTY result is real uncommitted regular-file work → refuse as
        # before. This gate is load-bearing: when a worktree has BOTH a dirty
        # regular file AND a populated submodule, git prints the submodule
        # message, so a bare `--force` would SILENTLY discard the user's changes
        # (verified) — the ignore-submodules status is what tells them apart.
        # `-c core.quotePath=false` so a non-ASCII path arrives verbatim rather
        # than C-quoted-and-octal-escaped (#768 review). At git's default
        # `core.quotePath=true`, `café.md` is reported as ` M "caf\303\251.md"`,
        # and the `${line#???}` strip below then yields that literal escaped
        # string — a path no `[ -L ]` will ever find. That fails CLOSED (teardown
        # refuses, no work is discarded), but it means the carve-out silently
        # never fires for an internationalized filename, re-creating the exact
        # deadlock this fix exists to remove. Verified both ways.
        dirty="$(command git -C "$wt" -c core.quotePath=false \
            status --porcelain --ignore-submodules=all 2>/dev/null || true)"

        # Subtract stale-attribute symlinks from the dirty set (#768). Each ` M
        # <path>` line whose path is a symlink with an index-identical target is
        # a filesystem artifact, not work; everything else — a modified regular
        # file, an added/deleted path, a genuinely retargeted symlink — stays in
        # the RESIDUE and still refuses below.
        #
        # Filtering the residue rather than short-circuiting on "all lines are
        # symlinks" is what preserves the load-bearing gate above: a worktree
        # with BOTH a stale symlink AND a dirty regular file keeps the regular
        # file in the residue and is refused, so the force can never silently
        # discard real work.
        stale_links=0
        if [ -n "$dirty" ]; then
            residue=""
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                # Only an unstaged modification (` M path`) can be this artifact.
                # Staged/added/deleted states are real work by construction.
                case "$line" in
                    " M "*)
                        if symlink_is_false_dirty "$wt" "${line#???}"; then
                            stale_links=$((stale_links + 1))
                            continue
                        fi
                        ;;
                esac
                residue="$residue$line
"
            done <<EOF
$dirty
EOF
            dirty="$(command printf '%s' "$residue")"
        fi

        if [ -z "$dirty" ] && command git worktree remove --force "$wt" 2>/dev/null; then
            if [ "$stale_links" -gt 0 ]; then
                command echo "  removed worktree $wt (forced past $stale_links stale symlink attr(s))"
            else
                command echo "  removed worktree $wt (forced past clean submodules)"
            fi
            removed=1
        else
            command echo "worktree-rm: $wt has uncommitted changes." >&2
            command echo "  Re-run after committing, or force: git worktree remove --force $wt" >&2
            exit 1
        fi
    fi
fi

if [ -n "$(command git branch --list "$br")" ]; then
    command git branch -D "$br"
    command echo "  deleted branch $br"
    removed=1
fi

# tmux_kill_outcome <rc> <stderr> — classify one `tmux kill-session` attempt as
# exactly one of `killed` / `absent` / `failed` (#533).
#
# `kill-session` returns the SAME non-zero exit for "there was no such session"
# (an expected no-op) and for a real fault — a wedged or unreachable server, a
# permission error — where the session is STILL ALIVE and the kill did not
# happen. Only the stderr text separates them, so it is classified rather than
# discarded.
#
# The benign set is wider than "session not found": tmux 3.5a emits three
# distinct shapes for "nothing to kill", and two never mention a session at all.
#
#   server up, session absent   can't find session: golem-N
#   no server ever started      error connecting to <sock> (No such file …)
#   server started then exited  no server running on <sock>
#
# Matching only the first would warn on every ordinary teardown on a host with
# no tmux server — noise operators would learn to ignore, defeating the warning.
#
# But `error connecting to` alone is TOO wide, and dangerously so: tmux formats
# it as `error connecting to <sock> (<strerror>)`, and only the ENOENT variant
# means "no server". The same prefix carries `(Permission denied)` for a LOCKED
# socket whose session is very much STILL RUNNING (verified: chmod 000 on a live
# socket yields exactly that message, and the session survives). Swallowing that
# would re-create this script's original bug under a new message, so the socket
# arm must ALSO see the no-such-file wording; anything else about connecting
# falls through to `failed`.
#
# That parenthetical is libc's `strerror`, which — unlike the three tmux-authored
# literals above — is TRANSLATED via LC_MESSAGES (glibc ships e.g. "Aucun fichier
# ou dossier de ce nom" for ENOENT). Under a non-English locale the substring
# would miss and every teardown on a server-less host would warn: exactly the
# noise this arm exists to prevent. The caller therefore pins LC_ALL=C on the
# tmux invocation so the text is guaranteed English; see the dispatch below.
#
# A crashed server leaving a STALE socket does NOT reach this arm at all —
# verified against tmux 3.5a with a bound, non-listening socket, which reports
# `no server running on <sock>` (already benign above) rather than ECONNREFUSED.
#
# Anything else, INCLUDING an empty stderr, is `failed`. A tmux that fails
# without saying why is exactly the unexplained case an operator needs to see;
# defaulting the unknown to benign would re-create the swallowed-error bug.
#
# Pure: no I/O beyond the verdict, no globals, no side effects — so the tests
# can slice it out and drive every branch directly. `rc` is compared as a
# STRING so a non-numeric argument yields `failed` rather than aborting on an
# arithmetic error. Lowercased with `tr`, not `${v,,}` (bash-4, banned by
# tests/lint-shell-portability.sh).
tmux_kill_outcome() {
    local rc="$1" err="$2" low
    if [ "$rc" = "0" ]; then
        command echo "killed"
        return 0
    fi
    # Fall back to the RAW text if `tr` is unavailable: an empty `low` would send
    # every message — including the benign ones — down the `failed` arm, warning
    # on ordinary teardowns. tmux's own wording is already lowercase so those
    # still match; what degrades is case-insensitivity, which costs only the
    # ENOENT variant (libc capitalizes "No such file or directory"). That lands
    # on `failed` — a spurious warning rather than a swallowed failure, i.e. the
    # safe direction. `|| true` keeps set -e from aborting teardown here (same
    # guard as the sanitizer below).
    low="$(command printf '%s' "$err" | command tr '[:upper:]' '[:lower:]' || true)"
    low="${low:-$err}"
    case "$low" in
        *"can't find session"* | *"session not found"* | \
            *"no server running"* | \
            *"error connecting to"*"no such file"*)
            command echo "absent"
            ;;
        *)
            command echo "failed"
            ;;
    esac
}

# Kill the golem's tmux session so a finished golem does not linger in
# `tmux ls` / golem-status.sh after merge+prune (#27). Idempotent and
# ignore-if-absent: a missing session (or no tmux at all) is a clean no-op.
#
# Kill UNCONDITIONALLY rather than has-session-then-kill (#486): the old guard
# `tmux has-session -t "$sess"` raced the golem's own `claude … ; claude …`
# self-teardown and intermittently reported the session absent while it lingered
# a beat longer, so the kill was skipped and the session leaked. `kill-session`
# is the very operation the guard protected and is already a safe no-op on a
# missing session, so dropping the pre-check removes the race with no downside.
# `-t "=$sess"` forces exact-name matching (the `=` prefix) instead of tmux's
# prefix/fnmatch target matching. The echo + `removed=1` fire only when a session
# was actually killed, preserving the contract that the line prints on a real
# kill.
#
# stderr is CAPTURED rather than sent to /dev/null (#533) so tmux_kill_outcome
# can tell an absent session from a real failure. On `failed` we warn and carry
# on: `removed` deliberately stays 0 — nothing was removed, and setting it would
# fire the terminal `reaped` feed event (#446) for a golem whose session is still
# alive, telling golem-status.sh the opposite of the truth. Nor does it abort:
# teardown is already past the destructive git mutations, so failing here would
# strand a removed worktree behind a non-zero exit. The `*)` arm is reserved for
# an internal-contract violation — never a duplicate of a real outcome, so a
# future typo in the helper cannot masquerade as one (#542).
sess="golem-$N"
if command -v tmux >/dev/null 2>&1; then
    # LC_ALL=C so the `(<strerror>)` parenthetical tmux appends to a connect
    # failure is guaranteed English — it is libc-translated, and the classifier's
    # no-such-file match would miss under a non-English locale, warning on every
    # server-less teardown. Scoped to this one call, not exported.
    tmux_rc=0
    tmux_err="$(LC_ALL=C tmux kill-session -t "=$sess" 2>&1)" || tmux_rc=$?
    case "$(tmux_kill_outcome "$tmux_rc" "$tmux_err")" in
        killed)
            command echo "  killed tmux session $sess"
            removed=1
            ;;
        absent) ;;
        failed)
            # `${tmux_err:-…}` because an EMPTY stderr is itself a `failed` case
            # (an unexplained non-zero is the one an operator most needs to see);
            # interpolating it raw ended the line at a dangling `): `. Control
            # characters are stripped: this text is now echoed to a terminal
            # rather than discarded, and it embeds the socket path, so a crafted
            # path or a spoofed tmux earlier on PATH could otherwise smuggle ANSI
            # escapes into the operator's session. The class drops every C0
            # control plus DEL (\177), deliberately KEEPING only tab (\011) and
            # newline (\012) so a genuine multi-line tmux error stays legible —
            # which is why this is not simply `[:cntrl:]`, a class that would eat
            # both. Octal ranges rather than named classes so GNU and BSD `tr`
            # agree. `printf '%s'` keeps the format string fixed, so stderr
            # containing a literal `%s` or a backslash is data, never format.
            #
            # `\013-\037` is ONE range on purpose. Enumerating it as
            # `\013\014\016-\037` silently skipped \015 (CR), which a terminal
            # renders by returning the cursor to column 0 — letting crafted
            # stderr overwrite the WARNING text and make the line read as
            # something else entirely. That is line-overwrite spoofing, the same
            # class as the ANSI escapes this strip exists to stop, so the range
            # is kept contiguous rather than spelled out byte by byte.
            #
            # The C1 range (\200-\237, 8-bit CSI/OSC) is deliberately NOT stripped.
            # Those byte values are also UTF-8 CONTINUATION bytes, so deleting
            # them corrupts any multibyte character in a socket path — U+011B is
            # `c4 9b`, and stripping the `9b` leaves an invalid lone `c4` that
            # renders as mojibake. That would break legitimate non-ASCII paths in
            # exchange for defending a form most terminals ignore by default.
            # Residual risk accepted, and stated here so it is a decision rather
            # than an oversight.
            # `|| true` because a bare assignment from a command substitution IS
            # subject to `set -e`: were `tr` unavailable, the script would abort
            # at 127 here — AFTER the destructive git mutations, stranding a
            # removed worktree behind a non-zero exit. This warning is
            # best-effort diagnostics and must never be the thing that fails
            # teardown, the same reasoning as the `|| true` on the reaped hook
            # below. The `:-` fallback then covers the empty result.
            # Three distinguishable states, not two: tmux said nothing; tmux said
            # something printable; or tmux said something that survived sanitizing
            # as nothing (an all-control payload, or a `tr` that could not run).
            # The third is the most suspicious and most actionable, so it gets its
            # own wording rather than being folded into the boring default.
            if [ -z "$tmux_err" ]; then
                tmux_err_safe="(no stderr from tmux)"
            else
                tmux_err_safe="$(command printf '%s' "$tmux_err" |
                    command tr -d '\000-\010\013-\037\177' || true)"
                tmux_err_safe="${tmux_err_safe:-(stderr present but unprintable)}"
            fi
            command echo "worktree-rm: WARNING: tmux kill-session failed for $sess" \
                "(session may still be running): $tmux_err_safe" >&2
            ;;
        *)
            command echo "worktree-rm: ERROR: internal — tmux_kill_outcome returned an unknown outcome" >&2
            ;;
    esac
fi

# Repair a polluted main-repo core.worktree (#258). An interrupted
# `git worktree remove --force` can leave the MAIN config with a stale
# core.worktree pointing at a now-deleted path, which makes the whole checkout
# look deleted (git status = all D, rev-parse --is-inside-work-tree = false).
# Only unset it when it points at a path that no longer exists — a legit,
# existing core.worktree is left untouched. `cd "$root"` above put us in the main
# checkout, so `git config` reads/writes the main config.
stale_wt="$(command git config --get core.worktree 2>/dev/null || true)"
if [ -n "$stale_wt" ] && [ ! -e "$stale_wt" ]; then
    command git config --unset core.worktree || true
    command git worktree prune || true
    command echo "  repaired stale core.worktree ($stale_wt no longer exists)"
    removed=1
    if [ "$(command git rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]; then
        command echo "worktree-rm: WARNING: main checkout still not a work tree after core.worktree repair" >&2
    fi
fi

# Emit a terminal `reaped` feed event so a golem torn down here does not linger
# on golem-status.sh's BLOCKED list (#446). Teardown otherwise leaves the golem's
# last `gate` line as its most-recent feed entry, so the reader keeps rendering
# it BLOCKED for the whole GOLEM_BLOCK_TTL window even though its PR merged and
# its session is gone (the `golem-743` ghost in the issue). A `REAPED:`-prefixed
# Notification classifies as the `reaped` kind, which — like `idle`/`resolved` —
# is NOT in the BLOCKED set, so as the golem's most-recent line it supersedes the
# stale gate on the next sweep. Only when something was actually removed
# (`removed=1`): a no-op teardown had no live golem to reap.
#
# GOLEM_ID=golem-$N is forced for the same reason golem-resolve.sh forces it:
# this script runs in the MAIN checkout (`cd "$root"` above), so the hook's
# git-worktree-basename fallback would resolve to the main repo and stamp
# `golem-?`, never correlating to the reaped golem. Best-effort and never fails
# teardown — the hook always exits 0, and `|| true` keeps `set -e` from aborting
# over a missing hook / absent jq.
if [ "$removed" -eq 1 ]; then
    notify_hook="$SCRIPT_DIR/../hooks/golem-notify.sh"
    if [ -x "$notify_hook" ]; then
        msg="REAPED: worktree/session for golem-$N torn down"
        if command -v jq >/dev/null 2>&1; then
            reaped_payload="$(jq -cn --arg m "$msg" '{message: $m}')"
        else
            reaped_payload="$(command printf '{"message":"%s"}' "$msg")"
        fi
        command printf '%s' "$reaped_payload" | GOLEM_ID="golem-$N" "$notify_hook" || true
    fi
fi

if [ "$removed" -eq 0 ]; then
    command echo "worktree-rm: nothing to remove for issue $N ($wt / $br / $sess absent)"
fi
