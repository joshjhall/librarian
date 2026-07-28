#!/usr/bin/env bash
# agnix-normalize — map `agnix --format json` findings to the TSV contract.
#
# The boundary object of the agnix integration spine (issue #397; ADR
# plugins/review-audit/docs/adr/0001-agnix-check-ai-config-boundary.md). agnix is
# an external Rust linter for AI-config files whose findings enrich the
# check-ai-config pre-scan on the overlap set. agnix speaks github|json|sarif, NOT
# this repo's TSV finding contract (file\tline\tcategory\tevidence\tcertainty).
# This tool runs agnix over the manifest, maps each CC-* rule to a check-ai-config
# category, and emits the TSV rows for the checker path (#401) to merge.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#         evidence is `[<RULE-ID>|<agnix rule_severity>] <message>`; certainty is
#         a fixed MEDIUM (rationale at the jq program below; #470).
#
# Environment:
#   AGNIX_BIN     agnix executable (default: `agnix`)
#   AGNIX_CONFIG  operator-controlled config -> agnix --config (ADR §5 trust)
#
# Exit codes:
#   0 = success (>=0 findings), OR the agnix binary is absent (no-op)
#   1 = usage error (missing argument) or file list not found
#   2 = agnix ran but failed / emitted unparsable output, or jq is missing while
#       agnix is present (fail loud)
#
# No-op when agnix is absent: emit nothing, log one skip line to stderr, exit 0 —
# the floor (patterns.*) stands alone on platforms without agnix.
#
# Note: Uses full paths for commands per project shell-scripting conventions
# (aliases / PATH shadowing can change output format and corrupt the TSV stream).
#
# Runtime: Python 3.11+ primary (agnix-normalize.py) with this bash script as the
# portable fallback. The shim below exec's the .py when a python3>=3.11 is present
# (identical TSV contract); PATTERNS_FORCE_BASH=1 forces this bash body. Parity is
# pinned by tests/validate-agnix-normalize.sh. bash-3.2 clean (no associative
# arrays / mapfile / namerefs / case-conversion). See CLAUDE.md § Key conventions.
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/agnix-normalize.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/agnix-normalize.py" "$@"
fi

FILE_LIST="${1:-}"
if [ -z "$FILE_LIST" ]; then
    command printf '%s\n' "Usage: agnix-normalize.sh <file-list>" >&2
    exit 1
fi
if [ ! -f "$FILE_LIST" ]; then
    command printf '%s\n' "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

AGNIX_BIN="${AGNIX_BIN:-agnix}"

# --- no-op when the agnix binary is absent (not an error) --------------------
# Accept either a PATH-resolvable name or a direct executable/file path (the test
# stub and AGNIX_CONFIG posture both pass explicit paths).
if ! command -v "$AGNIX_BIN" >/dev/null 2>&1 && [ ! -f "$AGNIX_BIN" ]; then
    command printf '%s\n' "[skip] agnix-normalize: agnix binary not found (AGNIX_BIN=$AGNIX_BIN); floor pre-scan stands alone" >&2
    exit 0
fi

# Collect non-blank paths from the manifest into an indexed array (bash-3.2: no
# mapfile, but `arr+=(...)` is fine) so a path CONTAINING a space survives as one
# argv element to agnix — matching the Python primary, which passes each path as a
# distinct list element. A whitespace-joined string would word-split downstream.
# Skip blank AND whitespace-only lines (matching the Python primary's `ln.strip()`
# filter) so a stray space/tab line is never passed to agnix as a spurious path.
PATHS=()
while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
        *[![:space:]]*) PATHS+=("$_line") ;;
    esac
done <"$FILE_LIST"

# An empty manifest is a legitimate no-work case: emit nothing, exit 0, without
# invoking agnix over an empty path list.
if [ "${#PATHS[@]}" -eq 0 ]; then
    exit 0
fi

# agnix present but jq missing -> fail loud (the bash path parses JSON with jq).
if ! command -v jq >/dev/null 2>&1; then
    command printf '%s\n' "agnix-normalize: jq is required for the bash fallback but was not found" >&2
    exit 2
fi

# --- run agnix ---------------------------------------------------------------
# agnix exits non-zero when it finds errors, so a non-zero exit is NOT a failure;
# only empty/blank stdout is. `set -e` must not abort on that expected non-zero,
# so guard the call.
# A `--` end-of-options marker precedes the paths so a manifest filename that
# legally begins with `-`/`--` (the audited tree is untrusted per ADR §5) is
# parsed by agnix as a positional path, never a flag — this is what fences off
# `--fix-unsafe`/`--config` injection. Mirrors the Python primary.
AGNIX_OUT=""
if [ -n "${AGNIX_CONFIG:-}" ]; then
    AGNIX_OUT="$("$AGNIX_BIN" --format json --target claude-code validate \
        --config "$AGNIX_CONFIG" -- "${PATHS[@]}" 2>/dev/null || true)"
else
    AGNIX_OUT="$("$AGNIX_BIN" --format json --target claude-code validate \
        -- "${PATHS[@]}" 2>/dev/null || true)"
fi

# Fail loud on empty output (agnix could not run usefully).
_trimmed="$(command printf '%s' "$AGNIX_OUT" | command tr -d '[:space:]')"
if [ -z "$_trimmed" ]; then
    command printf '%s\n' "agnix-normalize: agnix produced no JSON output" >&2
    exit 2
fi

# --- map diagnostics -> TSV (jq: prefix map, overlap filter, 80-codepoint cap) -
# .[0:80] slices by codepoint (matches Python str[:80]); join("\t") avoids @tsv's
# escaping so the row is byte-identical to the Python primary. Unmapped rules and
# empty-`file` diagnostics (project-level advisories) are dropped.
# Certainty is a fixed "MEDIUM" and agnix's own rule_severity rides in the
# evidence column instead (#470; mirrors AGNIX_CERTAINTY in the Python primary).
# rule_severity is issue SEVERITY, not detection CONFIDENCE, and agnix marks
# nearly the whole CC-* surface HIGH — passing it through would send every agnix
# row down the checker's certainty=HIGH auto-include fast path with no Pass-2 LLM
# confirmation, on a value the audited repo's own .agnix.toml can rewrite.
# The leading guards fail loud on a malformed top-level shape BEFORE emitting any
# row, matching the Python primary: a non-object top level (e.g. a bare array),
# or a `diagnostics` array holding a non-object element, `error`s out of jq
# (mapped to exit 2 below) rather than silently no-op'ing or emitting a partial
# stream. `select(type=="object")`-style asserts via `error` keep it explicit.
JQ_PROG='
def cat:
  if   startswith("CC-AG-")  then "agent-frontmatter"
  elif startswith("CC-SK-")  then "skill-frontmatter"
  elif startswith("CC-HK-")  then "hook-safety"
  elif startswith("CC-MCP-") then "mcp-misconfiguration"
  elif startswith("CC-PL-")  then "config-inconsistency"
  elif startswith("CC-MEM-") then "claude-md-drift"
  elif startswith("MCP-")    then "mcp-misconfiguration"
  else null end;
if type != "object" then error("not an object") else . end
| (.diagnostics // [])
| if type != "array" then error("diagnostics not an array") else . end
| (if all(.[]; type == "object") then . else error("non-object diagnostic") end)
| .[]
| (.rule // "" | tostring) as $rule
| ($rule | cat) as $category
| select($category != null)
| ((.file // "") | tostring) as $file
| select($file != "")
| [ $file,
    ((.line // "") | tostring),
    $category,
    (("[" + $rule + "|" + ((.rule_severity // "") | tostring) + "] "
      + ((.message // "") | tostring))[0:80]),
    "MEDIUM"
  ]
| join("\t")
'

# Buffer jq output and emit it ONLY on a clean parse (jq exit 0). Plain `jq -r`
# (NOT -e) exits 0 on any valid parse regardless of row count (zero mappable
# diagnostics is success), and non-zero on a genuine parse / type / assert error.
# Buffering makes emission atomic: a mid-stream `error()` (malformed diagnostics)
# fails loud with NO partial rows on stdout, matching the Python primary's
# fail-loud-before-output contract. Capture the rc without `set -e` aborting.
_jq_rc=0
_jq_out="$(command printf '%s' "$AGNIX_OUT" | jq -r "$JQ_PROG" 2>/dev/null)" || _jq_rc=$?
if [ "$_jq_rc" -ne 0 ]; then
    command printf '%s\n' "agnix-normalize: could not parse agnix JSON" >&2
    exit 2
fi
# Only print when there is something (an empty buffer must not emit a blank line).
if [ -n "$_jq_out" ]; then
    command printf '%s\n' "$_jq_out"
fi

exit 0
