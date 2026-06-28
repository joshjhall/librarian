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
# Exit: always 0 (a trust-seed failure must never abort worktree creation).
set -euo pipefail

wt_path="${1:-}"
cfg="${2:-$HOME/.claude.json}"

if [ -z "$wt_path" ]; then
    command echo "seed-worktree-trust: missing worktree path argument" >&2
    exit 2
fi

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
