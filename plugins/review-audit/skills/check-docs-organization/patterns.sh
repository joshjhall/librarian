#!/usr/bin/env bash
# check-docs-organization — Deterministic Pre-Scan
#
# Checks for missing standard root documents and directories without READMEs.
# The checks are DRIVEN BY the passed file list: an empty list (a PR that
# touched no relevant files) produces empty output and exit 0 — a deterministic
# pre-scan must never emit project-level findings on empty input (issue #64).
# When the list is non-empty the root-document check runs against the project
# root, and the directory-README check runs only for directories that contain a
# listed file (and their ancestors up to the root), not the whole tree.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
set -euo pipefail

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
# Runtime: Python 3.11+ primary (patterns.py); this bash body is the portable
# fallback. PATTERNS_FORCE_BASH=1 forces bash. See CLAUDE.md § Key conventions.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/patterns.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/patterns.py" "$@"
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

# Read the passed file list into an array of non-empty, non-blank paths. The
# whole scan is gated on this: an empty list means there is nothing to evaluate,
# so emit nothing and exit 0 rather than scanning the project root regardless.
FILES=()
while IFS= read -r _line || [ -n "$_line" ]; do
    # Trim surrounding whitespace; skip blank lines.
    _line="${_line#"${_line%%[![:space:]]*}"}"
    _line="${_line%"${_line##*[![:space:]]}"}"
    [ -n "$_line" ] && FILES+=("$_line")
done <"$FILE_LIST"

if [ "${#FILES[@]}" -eq 0 ]; then
    exit 0
fi

# Determine project root from the file list (use the common prefix)
# For simplicity, use the directory of the first file's git root
PROJECT_ROOT=$(command git rev-parse --show-toplevel 2>/dev/null || command echo ".")

# --- Category: missing-root-doc ---
# Check for standard root-level documentation files
for expected_file in README.md LICENSE CHANGELOG.md; do
    found=false
    # Check common variations
    case "$expected_file" in
        LICENSE)
            for variant in LICENSE LICENSE.md LICENSE.txt LICENCE LICENCE.md; do
                [ -f "${PROJECT_ROOT}/${variant}" ] && found=true && break
            done
            ;;
        *)
            [ -f "${PROJECT_ROOT}/${expected_file}" ] && found=true
            ;;
    esac

    if [ "$found" = "false" ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "${PROJECT_ROOT}" "1" "missing-root-doc" \
            "Missing standard file: ${expected_file}" "HIGH"
    fi
done

# --- Category: missing-dir-readme ---
# Check directories with significant content but no README. Driven by the passed
# file list: only the directories that actually contain a listed file are
# candidates (capped at the configured depth below the project root), so a PR
# emits a finding only for a directory it touched — never for the whole tree.
MAX_DEPTH="${CHECK_ORG_README_DEPTH:-2}"
MIN_FILES="${CHECK_ORG_MIN_FILES:-5}"

# Collect the unique directories of the listed files (absolute paths), so the
# missing-README check considers only touched directories.
candidate_dirs() {
    local f abs
    for f in "${FILES[@]}"; do
        case "$f" in
            /*) abs="$f" ;;
            *) abs="${PROJECT_ROOT}/${f}" ;;
        esac
        command dirname "$abs"
    done | command sort -u
}

candidate_dirs | while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    # Skip project root (covered by the missing-root-doc check above).
    [ "$dir" = "$PROJECT_ROOT" ] && continue
    # Only consider directories that exist and live under the project root.
    [ -d "$dir" ] || continue
    case "$dir" in
        "${PROJECT_ROOT}"/*) : ;;
        *) continue ;;
    esac

    # Respect the configured max depth below the project root.
    rel="${dir#"${PROJECT_ROOT}"/}"
    depth=$(command printf '%s\n' "$rel" | command awk -F/ '{print NF}')
    [ "$depth" -le "$MAX_DEPTH" ] || continue

    # Skip excluded / generated trees. `*/.*` already covers any hidden
    # directory (including .git), so it is not listed separately.
    case "$dir" in
        */.* | */node_modules/* | */vendor/* | */__pycache__/* | */dist/* | */build/*) continue ;;
    esac

    # Skip if README exists
    [ -f "${dir}/README.md" ] && continue
    [ -f "${dir}/README.rst" ] && continue
    [ -f "${dir}/README" ] && continue

    # Count meaningful files (exclude hidden, generated)
    file_count=$(command find "$dir" -maxdepth 1 -type f \
        -not -name '.*' \
        -not -name '*.pyc' \
        -not -name '*.o' \
        2>/dev/null | command wc -l)

    if [ "$file_count" -ge "$MIN_FILES" ]; then
        relative_dir=$(command echo "$dir" | command sed "s|^${PROJECT_ROOT}/||")
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$dir" "1" "missing-dir-readme" \
            "Directory ${relative_dir}/ has ${file_count} files but no README" "HIGH"
    fi
done || true
