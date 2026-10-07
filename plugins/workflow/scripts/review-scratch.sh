#!/usr/bin/env bash
# review-scratch — the ONE derivation of the ship-issue review loop's scratch
# directory (issue #1094).
#
# The review recipes write files.txt, diff.txt and each cycle's result JSON
# under $HOME/.cache/librarian-review/<gid>/, and the next cycle feeds the
# earlier JSONs back to review-convergence.sh as --prev-result history. That
# history decides `novel` vs `duplicate` and therefore when the loop stops — so
# a stale file is not clutter, it is a wrong input to a stop decision.
#
# Before #1094 three docs each spelled the derivation inline as
# `gid={GOLEM_ID or "solo"}`. GOLEM_ID is exported only by golem-launch.sh, so
# EVERY solo run shared `solo/`, which was never cleared: one machine held ~35
# files from six issues, and a refused Write of `solo/cycle1.json` left another
# issue's findings in place for convergence to read (`findings=4 novel=4` on a
# three-finding cycle). Two fixes, both here:
#
#   1. gid = $GOLEM_ID, else `solo-<issue>` — two solo runs on different issues
#      never share a directory.
#   2. `init` empties the directory — the first attempt of a review loop never
#      sees a file an earlier run left behind.
#
# #1157 ties the directory to ONE run. `init` writes a stamp file naming the
# issue and a fresh run nonce; `path` refuses a directory whose stamp is absent
# or names another issue, and echoes the stamp's nonce. The caller passes that
# nonce to the review harness (`args.run`, stamped into every result) and to
# `review-convergence.sh check --run`, which refuses any result file from a
# different run — even one with the same issue and cycle, which #1150's stamp
# cannot tell apart. `path` no longer creates the directory: a later attempt
# that finds no stamp has lost its run, and silently starting a fresh one would
# drop the --prev-result history the loop's stop decision reads.
#
# WHY A SCRIPT, and not a fourth copy of the inline spelling: three copies of a
# recipe drift (that is how this bug's fallback was duplicated in the first
# place), and the callers run worktree-isolated, where the Bash tool refuses a
# command substitution (#815). So this prints key=value lines the caller READS
# — next-issue/worktree-safe-recipes.md § Pattern 1 — instead of being
# `$(...)`-captured.
#
# Usage:
#   review-scratch.sh init --issue N   # empty + create + stamp; first attempt of a loop
#   review-scratch.sh path --issue N   # verify the stamp, keep contents
#
# Output (stdout):
#   dir=<absolute path>
#   gid=<golem id or solo-N>
#   run=<run nonce from the stamp>
#
# Exit codes: 0 = success; 2 = usage error, an unsafe input, or (path) a
# missing / foreign / malformed stamp. An unsafe input fails loud rather than
# falling back to a shared directory: falling back is exactly the collision
# this script exists to remove.
#
# Runtime: bash-only, bash-3.2 clean, BSD clean, coreutils via `command`.

set -euo pipefail

USAGE="Usage: review-scratch.sh init|path --issue N"

# die <message> — fail loud: actionable message + usage on stderr, exit 2.
die() {
    command printf '%s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

[ "$#" -ge 1 ] || die "a subcommand is required"
_subcmd="$1"
shift
case "$_subcmd" in
    init | path) ;;
    *) die "unknown subcommand: $_subcmd" ;;
esac

_issue=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --issue)
            [ "$#" -ge 2 ] || die "--issue requires a value"
            _issue="$2"
            shift 2
            ;;
        *) die "unknown flag: $1" ;;
    esac
done

# Canonical form only — no `0`, no leading zero — the same spelling
# review-convergence.sh's is_nonneg_int accepts. The stamp is an identity key
# compared as a string, so `007` and `7` must not both be valid (#1157).
case "$_issue" in
    '' | *[!0-9]* | 0*) die "--issue must be an issue number (digits, no leading zero), got '$_issue'" ;;
esac

# An empty GOLEM_ID is treated as unset — the same reading the inline
# `{GOLEM_ID or "solo"}` gave it.
_gid="${GOLEM_ID:-}"
if [ -z "$_gid" ]; then
    _gid="solo-$_issue"
fi
# The gid becomes one path segment under a directory `init` deletes, so it must
# not be able to name anything else: no separator, no `.`/`..`, no empty.
case "$_gid" in
    . | .. | *[!A-Za-z0-9._-]*)
        die "GOLEM_ID must be one path segment of [A-Za-z0-9._-], got '$_gid'"
        ;;
esac

[ -n "${HOME:-}" ] || die "HOME is unset or empty; refusing to guess a scratch root"
case "$HOME" in
    /*) ;;
    *) die "HOME must be an absolute path, got '$HOME'" ;;
esac

_dir="$HOME/.cache/librarian-review/$_gid"
_stamp="$_dir/.scratch-stamp"

if [ "$_subcmd" = "init" ]; then
    # 16 hex chars from the kernel RNG. `od` + `tr` rather than `xxd` or
    # `openssl`, which base macOS / bare linux may lack. Minted BEFORE the wipe
    # so a host with no RNG fails without having deleted the old run.
    _run="$(command od -An -N8 -tx1 /dev/urandom 2>/dev/null | command tr -d ' \n')" || _run=""
    case "$_run" in
        *[!0-9a-f]*) _run="" ;;
    esac
    [ "${#_run}" -eq 16 ] || die "could not mint a run nonce from /dev/urandom (got '$_run')"
    # No trailing slash: if $_dir is a symlink this removes the LINK, never the
    # tree it points at.
    command rm -rf -- "$_dir"
    command mkdir -p -- "$_dir"
    command printf 'issue=%s\nrun=%s\n' "$_issue" "$_run" >"$_stamp"
else
    # path: the directory must already belong to THIS issue's run. Read the
    # stamp with a pure-bash parse (CLAUDE.md runtime policy: no sed for a
    # trivial format). Unknown keys are ignored; a missing key is malformed.
    _hint="run 'review-scratch.sh init --issue $_issue' on the loop's first attempt, which starts a new run"
    if [ -L "$_dir" ] || [ ! -d "$_dir" ]; then
        die "no scratch dir for this run at '$_dir'; $_hint"
    fi
    if [ ! -f "$_stamp" ] || [ ! -r "$_stamp" ]; then
        die "scratch dir '$_dir' has no readable run stamp (made before #1157, or not by init); $_hint"
    fi
    _st_issue=""
    _run=""
    while IFS='=' read -r _k _v || [ -n "$_k" ]; do
        case "$_k" in
            issue) _st_issue="$_v" ;;
            run) _run="$_v" ;;
        esac
    done <"$_stamp"
    # Exactly the shape init writes: a canonical issue number and a 16-hex
    # nonce. Anything else was not written by init, so it fails HERE with the
    # malformed-stamp message rather than downstream as a misleading mismatch.
    case "$_st_issue" in
        '' | *[!0-9]* | 0*) die "scratch dir '$_dir' has a malformed run stamp (issue='$_st_issue'); $_hint" ;;
    esac
    case "$_run" in
        *[!0-9a-f]*) _bad_run=1 ;;
        *) _bad_run=0 ;;
    esac
    if [ "$_bad_run" -eq 1 ] || [ "${#_run}" -ne 16 ]; then
        die "scratch dir '$_dir' has a malformed run stamp (run='$_run'); $_hint"
    fi
    if [ "$_st_issue" != "$_issue" ]; then
        die "scratch dir '$_dir' is stamped for issue $_st_issue, not --issue $_issue — another issue's run (a GOLEM_ID reused across issues?); $_hint"
    fi
fi

command printf 'dir=%s\n' "$_dir"
command printf 'gid=%s\n' "$_gid"
command printf 'run=%s\n' "$_run"
