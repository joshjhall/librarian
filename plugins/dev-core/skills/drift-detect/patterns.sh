#!/usr/bin/env bash
# drift-detect — Deterministic Pre-Scan
#
# Compares planned files (from issue body) against actual changed files
# (from git diff) to detect file-level drift.
#
# Input:
#   $1 = file containing actual changed file paths (one per line)
#   $2 = file containing planned file paths (one per line)
#
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = success (zero or more findings)
#   1 = usage error (missing argument)
#
# Note: Uses full paths for commands per project shell-scripting conventions.
#
# Runtime: Python 3.11+ primary (patterns.py) with this bash script as the
# portable fallback. The shim below exec's patterns.py when a python3>=3.11 is
# present (identical TSV contract; both args forwarded); PATTERNS_FORCE_BASH=1
# forces this bash body. This tool is the two-arg outlier. See CLAUDE.md § Key
# conventions (runtime policy).
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/patterns.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/patterns.py" "$@"
fi

ACTUAL_FILES="${1:?Usage: patterns.sh <actual-files> <planned-files>}"
PLANNED_FILES="${2:?Usage: patterns.sh <actual-files> <planned-files>}"

if [ ! -f "$ACTUAL_FILES" ]; then
    echo "Error: actual files list not found: $ACTUAL_FILES" >&2
    exit 1
fi

if [ ! -f "$PLANNED_FILES" ]; then
    echo "Error: planned files list not found: $PLANNED_FILES" >&2
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

assert_file_list_shape "$ACTUAL_FILES"
assert_file_list_shape "$PLANNED_FILES"

# Known side-effect files that are commonly modified as a consequence
# of other changes (not scope drift)
SIDE_EFFECT_PATTERNS=(
    'package-lock.json'
    'yarn.lock'
    'pnpm-lock.yaml'
    'go.sum'
    'Cargo.lock'
    'Gemfile.lock'
    'poetry.lock'
    'composer.lock'
    '.gitignore'
)

# --- Category: planned-not-touched ---
# Files listed in the plan that are not in the actual diff
while IFS= read -r planned; do
    [ -z "$planned" ] && continue
    # Trim whitespace
    planned=$(command printf '%s' "$planned" | command sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$planned" ] && continue

    # Check if planned file (or a file within a planned directory) appears
    # in the actual changes
    found=0
    while IFS= read -r actual; do
        [ -z "$actual" ] && continue
        # Exact match
        if [ "$actual" = "$planned" ]; then
            found=1
            break
        fi
        # Directory match: planned path is a prefix of actual path
        case "$actual" in
            "${planned}/"*)
                found=1
                break
                ;;
        esac
    done <"$ACTUAL_FILES"

    if [ "$found" -eq 0 ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$planned" "0" "planned-not-touched" \
            "Planned file not found in git diff" "HIGH"
    fi
done <"$PLANNED_FILES"

# --- Category: unplanned-modification ---
# Files in the actual diff that are not in the plan
while IFS= read -r actual; do
    [ -z "$actual" ] && continue

    # Check if this file is in the planned list
    found=0
    while IFS= read -r planned; do
        [ -z "$planned" ] && continue
        planned=$(command printf '%s' "$planned" | command sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$planned" ] && continue
        # Exact match
        if [ "$actual" = "$planned" ]; then
            found=1
            break
        fi
        # Directory match: actual is within a planned directory
        case "$actual" in
            "${planned}/"*)
                found=1
                break
                ;;
        esac
    done <"$PLANNED_FILES"

    if [ "$found" -eq 0 ]; then
        # Check if this is a known side-effect file
        is_side_effect=0
        for pattern in "${SIDE_EFFECT_PATTERNS[@]}"; do
            case "$actual" in
                *"$pattern")
                    is_side_effect=1
                    break
                    ;;
            esac
        done

        # Check if this is a test file for a planned source file
        is_test_for_planned=0
        while IFS= read -r planned; do
            [ -z "$planned" ] && continue
            planned=$(command printf '%s' "$planned" | command sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$planned" ] && continue
            # Extract base name without extension for matching
            planned_base=$(command basename "$planned" | command sed 's/\.[^.]*$//')
            case "$actual" in
                *test*"$planned_base"* | *"$planned_base"*test* | *"$planned_base"*spec*)
                    is_test_for_planned=1
                    break
                    ;;
            esac
        done <"$PLANNED_FILES"

        if [ "$is_side_effect" -eq 1 ] || [ "$is_test_for_planned" -eq 1 ]; then
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$actual" "0" "unplanned-modification" \
                "Modified but not in plan (side-effect or test)" "LOW"
        else
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$actual" "0" "unplanned-modification" \
                "Modified but not listed in plan" "MEDIUM"
        fi
    fi
done <"$ACTUAL_FILES"
