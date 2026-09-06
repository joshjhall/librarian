#!/usr/bin/env bash
# loop-make-it-right — Deterministic Pre-Scan
#
# Detects structural quality issues: long functions, deep nesting, and
# single-character variable names outside loop counters.
#
# Input:  $1 = file containing paths to scan (one per line)
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
# present (identical TSV contract); PATTERNS_FORCE_BASH=1 forces this bash body.
# See CLAUDE.md § Key conventions (runtime policy).
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/patterns.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/patterns.py" "$@"
fi

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
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

# --- char-aware evidence truncation (#17 bash<->python equivalence) ----------
# Evidence is truncated to a fixed number of CHARACTERS to match the Python
# primary's str[:N]. `printf '%.Ns'` truncates by BYTES (and can split a UTF-8
# character), so multibyte evidence diverged between the two impls. Detect a
# UTF-8 locale once, then slice with bash parameter expansion under it
# (char-wise); fall back to the byte-wise printf if no UTF-8 locale exists.
_PRESCAN_UTF8_LOCALE=""
for _cand in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if locale -a 2>/dev/null | command grep -qixF "$_cand"; then
        _PRESCAN_UTF8_LOCALE="$_cand"
        break
    fi
done
unset _cand
# truncate_chars <maxchars> <string> — first <maxchars> characters on stdout.
truncate_chars() {
    local n="$1" s="$2"
    if [ -n "$_PRESCAN_UTF8_LOCALE" ]; then
        local LC_CTYPE="$_PRESCAN_UTF8_LOCALE"
        printf '%s' "${s:0:$n}"
    else
        command printf "%.${n}s" "$s"
    fi
}

# Configurable via environment (thresholds.yml values passed by orchestrator)
MAX_FUNCTION_LINES="${LOOP_MAX_FUNCTION_LINES:-50}"
MAX_NESTING_DEPTH="${LOOP_MAX_NESTING_DEPTH:-4}"

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # --- Category: long-function ---
    # Detect function definitions and count lines until closing
    #
    # CASE-INSENSITIVE extension arms (#754), matching patterns.py's `.lower()`
    # before dispatch. A literal `case` here skipped `Mod.PY` under bash while
    # python scanned it — silent, exit 0, reported as a clean file. Bracket
    # classes keep the match fork-free and bash-3.2 clean (`${file,,}` is
    # bash 4; macOS ships 3.2). Same rule at every `case "$file"` below.
    case "$file" in
        *.[Pp][Yy])
            # Python: count lines from def to next def/class or dedent
            command grep -nE '^[[:space:]]*def [[:alnum:]_]+' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    # Count lines until next function/class at same or lower indent.
                    #
                    # INDENT IS COUNTED IN PURE BASH, not `sed | wc -c` (#932).
                    # That pipeline was doubly BSD-unsafe, and its failure was the
                    # silent #679 shape -- a clean report of the WRONG thing:
                    #
                    #   (1) BSD `wc` PADS its count to width 7 (`%7ju`), so indent
                    #       came back as `"      0"`, and the bounded-repeat BRE
                    #       below interpolated to `^.\{0,      0\}[^ ]` -- a
                    #       malformed interval. Whether the host's grep rejects it
                    #       or reads it as literal text, it matches NOTHING, so
                    #       end_line stayed empty and EVERY def fell through to the
                    #       `total - line_num` fallback. On macOS that turned this
                    #       arm from 0 findings into 114 false HIGHs on the parity
                    #       fixture -- the exact counts issue #932 reports.
                    #   (2) BSD `sed` appends a trailing newline to input that
                    #       lacks one (GNU does not), so `wc -c` would ALSO have
                    #       read one byte high even unpadded.
                    #
                    # `${content%%[! ]*}` is the leading-space run; its length is
                    # the column the first non-space sits at, which is the value
                    # the `^.\{0,N\}[^ ]` probe actually wants. Fork-free,
                    # bash-3.2 clean, and identical on both userlands. It matches
                    # GNU's old value exactly, so this is not a behavior change on
                    # Linux -- verify with the `--- Category: long-function ---`
                    # cases in tests/validate-loop-detectors.sh.
                    _lead=${content%%[! ]*}
                    indent=${#_lead}
                    end_line=$(command sed -n "$((line_num + 1)),\$p" "$file" |
                        command grep -n "^.\{0,${indent}\}[^ ]" |
                        command head -1 | command cut -d: -f1)
                    if [ -n "$end_line" ]; then
                        func_lines=$((end_line))
                    else
                        total=$(command wc -l <"$file")
                        func_lines=$((total - line_num))
                    fi
                    if [ "$func_lines" -gt "$MAX_FUNCTION_LINES" ]; then
                        evidence=$(truncate_chars 60 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "long-function" \
                            "Function ${func_lines} lines (max ${MAX_FUNCTION_LINES}): ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        *.[Tt][Ss] | *.[Jj][Ss] | *.[Tt][Ss][Xx] | *.[Jj][Ss][Xx] | *.[Gg][Oo] | *.[Rr][Ss])
            # Brace-delimited languages: count from opening { to closing }
            command grep -nE '^[[:space:]]*(export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+[[:alnum:]_]+|^func[[:space:]]+|^(pub[[:space:]]+)?fn[[:space:]]+' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    _content=${raw#*:}
                    # Simple heuristic: count lines from definition to next function
                    next_func=$(command sed -n "$((line_num + 1)),\$p" "$file" |
                        command grep -nE '^[[:space:]]*(export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+[[:alnum:]_]+|^func[[:space:]]+|^(pub[[:space:]]+)?fn[[:space:]]+' |
                        command head -1 | command cut -d: -f1)
                    if [ -n "$next_func" ]; then
                        func_lines=$((next_func))
                    else
                        total=$(command wc -l <"$file")
                        func_lines=$((total - line_num))
                    fi
                    if [ "$func_lines" -gt "$MAX_FUNCTION_LINES" ]; then
                        evidence=$(truncate_chars 60 "$_content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "long-function" \
                            "Function ${func_lines} lines (max ${MAX_FUNCTION_LINES}): ${evidence}" "HIGH"
                    fi
                done || true
            ;;
    esac

    # --- Category: deep-nesting ---
    # Count leading whitespace to detect excessive nesting. awk truncates by
    # BYTES (its `%.60s` / substr are byte-based even under a UTF-8 locale), which
    # diverged from the python primary's char slice on multibyte lines. So awk now
    # emits the RAW line as a trailing field and the char-aware bash helper
    # truncates it (#17 equivalence). Fields before the raw line are tab-free, and
    # `read -r ... rawline` captures the (possibly tab-bearing) line whole.
    nest_unit=0
    case "$file" in
        *.[Pp][Yy]) nest_unit=4 ;;
        *.[Tt][Ss] | *.[Jj][Ss] | *.[Tt][Ss][Xx] | *.[Jj][Ss][Xx] | *.[Gg][Oo] | *.[Rr][Ss]) nest_unit=2 ;;
    esac
    if [ "$nest_unit" -ne 0 ]; then
        command awk -v max="$MAX_NESTING_DEPTH" -v unit="$nest_unit" '
            /^[[:space:]]+[^[:space:]]/ {
                match($0, /^[[:space:]]+/)
                depth = int(RLENGTH / unit)
                if (depth > max) {
                    printf "%d\t%d\t%s\n", NR, depth, $0
                }
            }
        ' "$file" 2>/dev/null |
            while IFS=$'\t' read -r line_num depth rawline; do
                evidence=$(truncate_chars 60 "$rawline")
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "deep-nesting" \
                    "Nesting depth ${depth} (max ${MAX_NESTING_DEPTH}): ${evidence}" "HIGH"
            done || true
    fi

    # --- Category: single-char-name ---
    # Single-character variable names outside common loop patterns
    case "$file" in
        *.[Pp][Yy])
            command grep -nE '^[[:space:]]+[a-zA-Z][[:space:]]*=' "$file" 2>/dev/null |
                command grep -vE '^[[:space:]]*(for|with)[[:space:]]+[a-zA-Z][[:space:]]+in\b|_[[:space:]]*=' |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    # Extract the variable name
                    varname=$(command printf '%s' "$content" | command sed 's/^[[:space:]]*\([a-zA-Z]\)[[:space:]]*=.*/\1/')
                    # Skip common loop vars and conventional single-char names
                    case "$varname" in
                        i | j | k | n | x | y | _ | e | f) continue ;;
                    esac
                    evidence=$(truncate_chars 60 "$content")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "single-char-name" \
                        "Single-character variable '${varname}': ${evidence}" "HIGH"
                done || true
            ;;
    esac

done <"$FILE_LIST"
