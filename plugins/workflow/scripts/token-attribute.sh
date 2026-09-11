#!/usr/bin/env bash
# token-attribute — shim for the Python transcript-attribution tool.
#
# The gateway (#781, token-report.sh) says HOW MUCH the fleet spent; this says
# WHERE it went — per-tool re-read debt, context-floor decomposition, per-decile
# growth, spawn prefix distribution, Bash read-vs-mutate, attachment volume.
# Filed for issue #788.
#
# Usage: token-attribute.sh [debt|floor|growth|prefix|bash-class|attachments]
#                           [--root DIR] [--tz ZONE]
#
# THE BASH-FALLBACK DECISION, AND ITS REASON (#788 AC8). There is NO bash
# fallback, and that is a decision rather than a default in either direction.
# The patterns.sh pre-scan family keeps a bash body because it scans source with
# grep, which bash 3.2 can do. This tool walks newline-delimited JSON, unions
# content blocks across duplicate message ids, and sums per-turn usage
# accounting — none of which bash 3.2 can do correctly. It is also an OPERATOR
# ANALYSIS TOOL, not a member of the pre-scan family, so the dual-runtime
# convention does not reach it.
#
# Per CLAUDE.md § Key conventions (runtime policy) a tool must FAIL LOUD rather
# than silently emit wrong or empty findings when its runtime is missing — so an
# absent or too-old python3 exits 77 (the reserved "did not run" sentinel) with
# an actionable message, never 0. A silent 0 here would be the worst outcome
# available: this tool's whole purpose is to stop measurements that are
# confidently wrong.
#
# Exit codes: 0 = success; 2 = usage error; 3 = no transcripts; 77 = no runtime.
# bash-3.2 clean. See CLAUDE.md § Key conventions.
set -euo pipefail

# Derive our own directory with BUILTINS only (parameter expansion + cd + pwd).
# `dirname` is external, so on a broken/empty PATH it fails and $_here silently
# collapses to the CWD — which makes this script report "the plugin install is
# incomplete" when the real fault is the PATH. A wrong diagnosis is worse than
# none; the sibling measure-spawn-prefix.sh documents the same measured trap.
_dir="${BASH_SOURCE[0]%/*}"
[ "$_dir" = "${BASH_SOURCE[0]}" ] && _dir="."
_here="$(cd "$_dir" && pwd)"
_py="$_here/token-attribute.py"

if [ ! -f "$_py" ]; then
    command printf '%s\n' \
        "token-attribute: missing $_py — the plugin install is incomplete." >&2
    exit 77
fi

if ! command -v python3 >/dev/null 2>&1; then
    command printf '%s\n' \
        "token-attribute: python3 not found; this tool requires Python 3.11+." \
        "It parses JSONL transcripts and has no bash fallback by design." \
        "Install python3 >= 3.11 (macOS: brew install python@3.11)." >&2
    exit 77
fi

if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    command printf '%s\n' \
        "token-attribute: python3 is older than 3.11; refusing to run." \
        "Reporting nothing beats reporting wrong token attribution." \
        "Install python3 >= 3.11 (macOS: brew install python@3.11)." >&2
    exit 77
fi

exec python3 "$_py" "$@"
