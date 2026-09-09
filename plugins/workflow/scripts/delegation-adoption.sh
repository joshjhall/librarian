#!/usr/bin/env bash
# delegation-adoption — shim for the Python delegation-adoption measurement tool.
#
# Reports whether read-only investigation is actually being delegated to
# subagents: the harness-vs-direct spawn split, the inline investigations that
# cleared the delegation break-even without being delegated, and whether the
# delegations that did happen returned conclusions rather than transcripts.
# Filed for issue #797; see docs/verification/delegation-recall-tally-785.md.
#
# Usage: delegation-adoption.sh [adoption|opportunities|ac5] [--root DIR]
#
# Runtime: Python 3.11+ ONLY — this tool has NO bash fallback, deliberately.
# The patterns.sh family keeps a bash body because it scans source with grep,
# which bash 3.2 can do; this one walks newline-delimited JSON transcripts,
# which it cannot do correctly. Per CLAUDE.md § Key conventions (runtime policy)
# a tool must FAIL LOUD rather than silently emit wrong or empty findings when
# its runtime is missing — so an absent or too-old python3 exits 77 (the
# reserved "did not run" sentinel) with an actionable message, never 0.
#
# That distinction matters more here than in most tools: this one's headline
# result is a ZERO, and a runtime failure that exited 0 would be indistinguishable
# from a measured "nobody delegated".
#
# Exit codes: 0 = success; 2 = usage error; 3 = no transcripts; 77 = no runtime.
# bash-3.2 clean. See CLAUDE.md § Key conventions.
set -euo pipefail

# Derive our own directory with BUILTINS only (parameter expansion + cd + pwd).
# `dirname` is external, so on a broken/empty PATH it fails and $_here silently
# collapses to the CWD — which made the sibling script report "plugin install is
# incomplete" when the real fault was the PATH. A wrong diagnosis is worse than
# none.
_dir="${BASH_SOURCE[0]%/*}"
[ "$_dir" = "${BASH_SOURCE[0]}" ] && _dir="."
_here="$(cd "$_dir" && pwd)"
_py="$_here/delegation-adoption.py"

if [ ! -f "$_py" ]; then
    command printf '%s\n' \
        "delegation-adoption: missing $_py — the plugin install is incomplete." >&2
    exit 77
fi

if ! command -v python3 >/dev/null 2>&1; then
    command printf '%s\n' \
        "delegation-adoption: python3 not found; this tool requires Python 3.11+." \
        "It parses JSONL transcripts and has no bash fallback by design." \
        "Install python3 >= 3.11 (macOS: brew install python@3.11)." >&2
    exit 77
fi

if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    command printf '%s\n' \
        "delegation-adoption: python3 is older than 3.11; refusing to run." \
        "Reporting nothing beats reporting a zero that is not a measurement." \
        "Install python3 >= 3.11 (macOS: brew install python@3.11)." >&2
    exit 77
fi

exec python3 "$_py" "$@"
