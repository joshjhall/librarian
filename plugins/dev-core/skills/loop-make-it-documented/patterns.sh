#!/usr/bin/env bash
# loop-make-it-documented — Deterministic Pre-Scan
#
# Detects documentation gaps: public functions without docstrings, exported
# symbols without JSDoc/GoDoc, public classes without documentation.
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

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip test files and non-source files
    case "$file" in
        *test* | *spec* | *__pycache__* | *.md | *.yml | *.yaml | *.json | *.toml | *.lock) continue ;;
    esac

    basename=$(command basename "$file")
    ext="${basename##*.}"

    # CASE-INSENSITIVE dispatch (#754), matching patterns.py's `.lower()` on the
    # same extension. Without it `Api.PY` was scanned under python and skipped
    # under bash — silent, exit 0, and reported as a clean file.
    #
    # This detector switches on a BARE word rather than a `*.ext` glob, so the
    # normalization happens once here instead of as bracket classes in the arms.
    # `tr` is affordable at this site (once per file, and a `basename` fork
    # already happens two lines up); `${ext,,}` is bash 4 and macOS ships 3.2.
    ext=$(command printf '%s' "$ext" | LC_ALL=C command tr '[:upper:]' '[:lower:]')

    case "$ext" in
        py)
            # --- Python: public functions without docstrings ---
            # awk truncates by BYTES; it now emits `category \t line \t rawtext`
            # and the char-aware bash helper truncates rawtext, matching the
            # python primary on multibyte defs/classes (#17 equivalence). rawtext
            # is the trailing field so a `read -r cat line rawtext` keeps it whole.
            command awk '
                /^def [a-zA-Z][a-zA-Z0-9_]*\(/ {
                    func_line = NR
                    func_text = $0
                    getline
                    while (/^[[:space:]]*$/) getline
                    if (!/^[[:space:]]*"""/ && !/^[[:space:]]*\x27\x27\x27/) {
                        printf "undocumented-public-function\t%d\t%s\n", func_line, func_text
                    }
                }
                /^class [A-Z][a-zA-Z0-9_]*/ {
                    class_line = NR
                    class_text = $0
                    getline
                    while (/^[[:space:]]*$/) getline
                    if (!/^[[:space:]]*"""/ && !/^[[:space:]]*\x27\x27\x27/) {
                        printf "undocumented-public-class\t%d\t%s\n", class_line, class_text
                    }
                }
            ' "$file" 2>/dev/null |
                while IFS=$'\t' read -r category line_num rawtext; do
                    evidence=$(truncate_chars 60 "$rawtext")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "$category" \
                        "No docstring: ${evidence}" "HIGH"
                done || true
            ;;
        ts | js | tsx | jsx)
            # --- TypeScript/JavaScript: exported functions without JSDoc ---
            # grep -nE, and POSIX classes rather than \s / \w (#679). As a BASIC
            # regex this depended on THREE GNU extensions at once — `\|`
            # alternation, `\s`, and `\w` — none of which BSD grep honors, so on
            # macOS the whole arm matched nothing and silently found no
            # undocumented exports. Mirrors patterns.py's JS_EXPORT_RE, which is
            # already an ERE.
            command grep -nE '^export[[:space:]]+(async[[:space:]]+)?function[[:space:]]+[[:alnum:]_]+|^export[[:space:]]+(default[[:space:]]+)?class[[:space:]]+[[:alnum:]_]+' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    # Check if preceded by JSDoc comment (/** ... */)
                    prev_line=$((line_num - 1))
                    if [ "$prev_line" -gt 0 ]; then
                        prev_content=$(command sed -n "${prev_line}p" "$file")
                        if ! command printf '%s' "$prev_content" | command grep -qE '^[[:space:]]*\*/' 2>/dev/null; then
                            evidence=$(truncate_chars 60 "$content")
                            category="undocumented-export"
                            if command printf '%s' "$content" | command grep -q 'class' 2>/dev/null; then
                                category="undocumented-public-class"
                            fi
                            command printf '%s\t%s\t%s\t%s\t%s\n' \
                                "$file" "$line_num" "$category" \
                                "No JSDoc: ${evidence}" "HIGH"
                        fi
                    fi
                done || true
            ;;
        go)
            # --- Go: exported functions without GoDoc comments ---
            # grep -nE (extended regex): the pattern uses `\(` for a literal
            # paren, which in a BASIC regex opens an unclosed group (grep errors,
            # matches nothing). With -E the arm actually runs (#183; it was dead).
            command grep -nE '^func [A-Z][a-zA-Z0-9]*\(' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    func_name=$(command printf '%s' "$content" | command sed 's/^func \([A-Z][a-zA-Z0-9]*\).*/\1/')
                    prev_line=$((line_num - 1))
                    if [ "$prev_line" -gt 0 ]; then
                        prev_content=$(command sed -n "${prev_line}p" "$file")
                        if ! command printf '%s' "$prev_content" | command grep -qE "^// ${func_name}" 2>/dev/null; then
                            evidence=$(truncate_chars 60 "$content")
                            command printf '%s\t%s\t%s\t%s\t%s\n' \
                                "$file" "$line_num" "undocumented-export" \
                                "No GoDoc for ${func_name}: ${evidence}" "HIGH"
                        fi
                    fi
                done || true
            ;;
        sh | bash)
            # --- Shell: functions without usage comment ---
            command grep -nE '^[[:alnum:]_]+\(\)' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    prev_line=$((line_num - 1))
                    if [ "$prev_line" -gt 0 ]; then
                        prev_content=$(command sed -n "${prev_line}p" "$file")
                        if ! command printf '%s' "$prev_content" | command grep -qE '^[[:space:]]*#' 2>/dev/null; then
                            evidence=$(truncate_chars 60 "$content")
                            command printf '%s\t%s\t%s\t%s\t%s\n' \
                                "$file" "$line_num" "undocumented-public-function" \
                                "No comment before function: ${evidence}" "HIGH"
                        fi
                    fi
                done || true
            ;;
    esac

done <"$FILE_LIST"
