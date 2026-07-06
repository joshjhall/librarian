#!/usr/bin/env bash
# seed-worktree-trust.sh — seed a Claude Code workspace-trust entry for a
# worktree path.
#
# A fresh git worktree path has never been trusted, so Claude Code does NOT load
# its project settings (including a copied `.claude/settings.local.json` with
# `permissions.defaultMode: "auto"` and the push/PR `ask` gates) for that
# untrusted folder. A non-interactive `tmux` golem launch can't show the trust
# dialog, so without this seed the session silently falls back to `default`
# permission mode and prompt-storms on every read/edit/test.
#
# This sets `projects["<worktree>"].hasTrustDialogAccepted = true` in the user's
# `~/.claude.json` so the copied settings actually load. It COMPLEMENTS — does
# not replace — the explicit `--permission-mode auto` flag on the golem launch
# command: the flag is the trust-independent guarantee for `auto` mode, while
# this seed is what makes the `ask` gates in settings.local.json take effect.
#
# Best-effort and idempotent: if `jq` or the config file is absent it prints a
# "skipped" line and exits 0 (the launch flag still works without it). The write
# goes to a temp file ADJACENT to the config and is committed with an atomic
# `mv` rename — never a `cat >` truncate, which could corrupt the host's primary
# Claude Code config on an interrupted write.
#
# Usage: seed-worktree-trust.sh <absolute-worktree-path> [config-path]
#   config-path defaults to ~/.claude.json (overridable for testing).
#
# Granting workspace trust makes Claude Code load a folder's project settings
# (including `defaultMode: "auto"`) without the interactive trust dialog, so the
# target path is security-sensitive: a caller able to influence the argument
# must not be able to pre-trust an ARBITRARY host directory. This helper
# therefore validates, BEFORE the jq write, that the path is a worktree under
# THIS repository's root and matches the expected `<worktrees>/issue-<N>` shape.
# `jq --arg` already blocks JSON injection; this guard constrains the trust
# GRANT TARGET (issue #21).
#
# Exit codes:
#   0  trust seeded, OR best-effort skip (jq/config absent, or jq write failed)
#   2  missing worktree-path argument
#   3  path failed validation (outside repo root, or wrong shape) — trust
#      refused. This is a hard refusal (non-zero) so an attacker-influenced
#      target is never silently honoured; the legitimate caller always passes a
#      `<repo>/<GOLEM_WORKTREE_DIR>/issue-N` path, which validates.
#   4  cannot resolve the script's own directory (invoked by bare name with no
#      path component) — refused rather than sourcing config.sh from cwd.
set -euo pipefail

# Resolve SCRIPT_DIR from this script's own path with pure-bash parameter
# expansion (no external `dirname`), so it works even when a caller strips PATH
# (as the jq-absent test does) without a PATH-dependent `command dirname`. cd/pwd
# are builtins. If BASH_SOURCE has no directory component (script invoked by bare
# name), we CANNOT trust `$(pwd)` as a stand-in for the install dir — sourcing
# `$(pwd)/config.sh` would run whatever config.sh sits in the caller's cwd, a
# code-injection vector in a script whose whole job is a trust boundary (#21).
# Fail loud instead: this never happens for the real callers (worktree-new.sh and
# the tests always pass an absolute path).
_seed_src="${BASH_SOURCE[0]}"
case "$_seed_src" in
    */*)
        SCRIPT_DIR="$(cd "${_seed_src%/*}" && pwd)"
        ;;
    *)
        command echo "seed-worktree-trust: cannot resolve script dir from bare invocation '$_seed_src' — invoke with a path" >&2
        exit 4
        ;;
esac
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

wt_path="${1:-}"
cfg="${2:-$HOME/.claude.json}"

if [ -z "$wt_path" ]; then
    command echo "seed-worktree-trust: missing worktree path argument" >&2
    exit 2
fi

# --- Validate the trust-grant target (issue #21) -----------------------------
# Resolve this repository's MAIN checkout root via config.sh's shared repo_root()
# (dirname of `git rev-parse --git-common-dir`) — cwd- and worktree-independent,
# and the exact resolver the caller worktree-new.sh already uses. The earlier
# inline `--show-toplevel`-first resolution was cwd-DEPENDENT: from a shell whose
# cwd is a sibling (or just-reaped) worktree — routine during /orchestrate lane
# refill — `--show-toplevel` returns that OTHER worktree's toplevel, so a valid
# new worktree under the main root was falsely judged "not under repo root" and
# refused (issue #242). repo_root() has no such dependence.
repo_root="$(repo_root 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
    command echo "seed-worktree-trust: refusing trust seed — not inside a git repository" >&2
    exit 3
fi

# Canonicalize both sides so `..` / symlink traversal can't escape the root.
# The worktree path may not exist yet (parent dir does), so resolve leniently.
canon() { /usr/bin/realpath -m -- "$1" 2>/dev/null || command echo "$1"; }
repo_root_canon="$(canon "$repo_root")"
wt_canon="$(canon "$wt_path")"

# 1) Must be strictly UNDER the repo root (not the root itself).
case "$wt_canon/" in
    "$repo_root_canon"/*) ;;
    *)
        command echo "seed-worktree-trust: refusing trust seed — '$wt_path' is not under repo root '$repo_root'" >&2
        exit 3
        ;;
esac

# 2) Narrow to the expected `<GOLEM_WORKTREE_DIR>/issue-<digits>` shape so the
#    grant can't target an arbitrary in-tree directory either. GOLEM_WORKTREE_DIR
#    is repo-root-relative and env-overridable (default .worktrees), mirroring
#    config.sh; the leaf must be `issue-<N>` with N all digits.
rel="${wt_canon#"$repo_root_canon"/}"
wt_dir="${GOLEM_WORKTREE_DIR:-.worktrees}"
case "$rel" in
    "$wt_dir"/issue-[0-9]*)
        leaf="${rel##*/issue-}"
        case "$leaf" in
            *[!0-9]*)
                command echo "seed-worktree-trust: refusing trust seed — '$rel' issue suffix is not all-digits" >&2
                exit 3
                ;;
        esac
        ;;
    *)
        command echo "seed-worktree-trust: refusing trust seed — '$rel' is not a '$wt_dir/issue-<N>' worktree" >&2
        exit 3
        ;;
esac
# -----------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1 || [ ! -f "$cfg" ]; then
    command echo "  skipped trust seed (jq or $cfg not available)"
    exit 0
fi

# Temp file adjacent to $cfg (same filesystem) so the final rename is atomic.
tmp="$(/usr/bin/mktemp "${cfg}.XXXXXX")"
if command jq --arg p "$wt_path" \
    '.projects[$p].hasTrustDialogAccepted = true' "$cfg" >"$tmp" 2>/dev/null; then
    /usr/bin/mv "$tmp" "$cfg"
    command echo "  seeded workspace trust for $wt_path (settings.local.json + defaultMode:auto will load)"
else
    # jq failed (malformed config, etc.) — leave $cfg untouched and clean up.
    command echo "  skipped trust seed (could not update $cfg)"
fi
# Safety net for the failure path; on success $tmp was renamed away (no-op).
/usr/bin/rm -f "$tmp"
exit 0
