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

# --- input-shape guard (#816) -----------------------------------------------
# The file-list argument is a list of PATHS, one per line -- not a diff. Handed
# a diff, the scan loop reads each diff line as a path, matches nothing, emits
# nothing, and exits 0: an output indistinguishable from a genuinely clean scan.
# That is the #538/#571 failure (a gate that sits inert and reads as a pass)
# reached through the INPUT rather than the runtime, and it is easy to hit --
# both inputs come from adjacent `git diff` invocations differing only by
# `--name-only`, and both are plausibly named `*.diff`.
#
# Two checks, deliberately different in severity:
#
#   DIFF SHAPE -> hard failure (exit 1). Unambiguous: no file list contains a
#     `diff --git`/`@@`/`+++`/`--- ` line, so there is no legitimate input this
#     rejects, and the silent-zero scan is exactly what the caller must not get.
#
#   NOTHING RESOLVES -> stderr warning, exit code UNCHANGED. This one cannot be
#     an error: a list naming only deleted files is legitimate (the paths are
#     gone by design), and an EMPTY list exiting 0 in silence is a contract
#     tests/validate-prescans.sh pins for every pre-scan. So it is a warning
#     that catches stale lists and wrong-cwd invocations without breaking either
#     real case -- which is why it is guarded on a NON-EMPTY list.
#
# BASH_SOURCE[0], not $0: inside a function it names the file this function was
# DEFINED in, so the message stays correct under a symlink, a relative
# invocation from another cwd, or a `source` -- the same reasoning the SCRIPT_DIR
# computation elsewhere in these scanners uses.
# The multi-byte Unicode format characters the reflected line must not carry:
# the zero-width family (U+200B-200F), bidi overrides/embeddings (U+202A-202E),
# bidi isolates (U+2066-2069) and BOM (U+FEFF). A bidi override is the dangerous
# one: it makes the reflected text RENDER reversed, so a hostile path can display
# as something other than what it is.
#
# Built with printf as LITERAL UTF-8 bytes, not written as \xNN escapes -- those
# are a GNU sed extension that BSD sed reads as literal text, which is the silent
# #679 failure class (the pattern stops matching and nothing reports it).
# An ALTERNATION, not a bracket class: a bracket over multi-byte sequences
# matches byte-wise and can split a character.
#
# This is what keeps the bash fallback in step with _strip_control() in the
# python primary, whose isprintable() rejects category Cf for free. Without it
# the two runtimes diverge on exactly the path the fallback exists to serve
# (measured: RTLO survived in bash, was stripped in python).
_PRESCAN_BIDI_BYTES="$(command printf '\342\200\213|\342\200\214|\342\200\215|\342\200\216|\342\200\217|')"
_PRESCAN_BIDI_BYTES="${_PRESCAN_BIDI_BYTES}$(command printf '\342\200\252|\342\200\253|\342\200\254|\342\200\255|\342\200\256|')"
_PRESCAN_BIDI_BYTES="${_PRESCAN_BIDI_BYTES}$(command printf '\342\201\246|\342\201\247|\342\201\250|\342\201\251|\357\273\277')"

assert_file_list_shape() {
    local list="$1"
    local tool="${BASH_SOURCE[0]##*/}"
    local line total=0 resolved=0

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        total=$((total + 1))
        case "$line" in
            'diff --git '* | '--- '* | '+++ '* | '@@ '*)
                # STRIP CONTROL BYTES before echoing the line back. The input is
                # caller-supplied and may come from an untrusted diff; raw ESC/BEL
                # reaching the operator's terminal can move the cursor, hide
                # following output, or drive an OSC title-bar sequence. Keep tab
                # (\011) so indentation still reads. Measured: without this, a
                # crafted `diff --git \033[31m...\033]0;X\007` line renders as
                # live escapes rather than text.
                # Two passes, because one tool cannot do both portably.
                # (1) tr strips single-byte C0 controls + DEL (ESC, BEL, ...).
                #     Tab (\011) is kept so indentation still reads.
                # (2) sed strips the MULTI-BYTE Unicode format characters that
                #     tr cannot express: bidi overrides/isolates (U+202A-202E,
                #     U+2066-2069), the zero-width family (U+200B-200F) and BOM
                #     (U+FEFF). A bidi override is the dangerous one -- it makes
                #     the reflected path RENDER in reverse, so `evil.js` can be
                #     displayed as something else entirely. `tr -d '[:cntrl:]'`
                #     does NOT cover these (locale-dependent, and C0-only in the
                #     C locale, measured), which is why they are enumerated as
                #     literal UTF-8 byte sequences -- a spelling that behaves
                #     identically under BSD and GNU sed.
                #     This mirrors _strip_control() in the python primary, whose
                #     `isprintable()` rejects category Cf for free. Without pass
                #     (2) the two runtimes DIVERGE on exactly the fallback path
                #     the bash body exists to serve (verified: RTLO survived in
                #     bash and was stripped in python).
                _safe_line="$(command printf '%s' "$line" |
                    command tr -d '\000-\010\013-\037\177' |
                    command sed -E "s/(${_PRESCAN_BIDI_BYTES})//g")"
                echo "Error: ${tool}: input looks like a DIFF, not a file list: ${list}" >&2
                echo "  Offending line: ${_safe_line}" >&2
                echo "  Expected one path per line -- did you mean 'git diff --name-only'?" >&2
                echo "  Refusing to scan: a diff matches no path, so this would emit nothing and exit 0, which reads as a clean scan." >&2
                exit 1
                ;;
        esac
        if [ -e "$line" ]; then
            resolved=$((resolved + 1))
        fi
    done <"$list"

    if [ "$total" -gt 0 ] && [ "$resolved" -eq 0 ]; then
        echo "Warning: ${tool}: no path listed in ${list} exists (${total} non-empty lines); scanning nothing." >&2
        echo "  A stale list or a wrong working directory yields an empty scan that reads as clean. Findings below (if any) are from a partial view." >&2
    fi
}

assert_file_list_shape "$FILE_LIST"

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
# `--config` is a GLOBAL flag and MUST precede the `validate` subcommand — agnix
# (clap-based) rejects `validate --config …` with "unexpected argument
# '--config' found" and exit 2, verified on both the pinned 0.40.0 and 0.41.0.
# Emitting it after `validate` made the whole AGNIX_CONFIG branch non-functional;
# because stderr is discarded below, that surfaced only as the generic
# "produced no JSON output" fail-loud, never as the real cause.
AGNIX_OUT=""
if [ -n "${AGNIX_CONFIG:-}" ]; then
    AGNIX_OUT="$("$AGNIX_BIN" --format json --target claude-code \
        --config "$AGNIX_CONFIG" validate -- "${PATHS[@]}" 2>/dev/null || true)"
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
# Replace the TSV framing characters with a space, mirroring _scrub() in the
# Python primary — applied to the five FINAL fields (after the [0:80] slice) so
# both impls scrub at the same point and stay byte-identical. Untrusted agnix
# message/file text would otherwise forge extra columns (tab) or a whole extra
# row (newline) carrying a spoofed [<RULE-ID>|<SEVERITY>] prefix that Step 6
# Guard 2 reads to decide whether to drop a floor finding.
def scrub: gsub("[\t\n\r]"; " ");
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
| [ ($file | scrub),
    (((.line // "") | tostring) | scrub),
    $category,
    ((("[" + $rule + "|" + ((.rule_severity // "") | tostring) + "] "
       + ((.message // "") | tostring))[0:80]) | scrub),
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
