#!/usr/bin/env bash
# check-docs-examples — Deterministic Pre-Scan
#
# Extracts code examples from markdown files and validates imports/references
# against actual project source files.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
set -euo pipefail

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

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

PROJECT_ROOT=$(command git rev-parse --show-toplevel 2>/dev/null || command echo ".")

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Only process markdown files
    case "$file" in
        *.md | *.rst) ;;
        *) continue ;;
    esac

    # --- Category: broken-example ---
    # Find Python imports in fenced code blocks and verify modules exist
    # Track if we're inside a code block
    in_code_block=false
    code_lang=""
    line_num=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))

        # Detect code block boundaries
        case "$line" in
            '```'python* | '```'py*)
                in_code_block=true
                code_lang="python"
                continue
                ;;
            '```'javascript* | '```'js* | '```'typescript* | '```'ts*)
                in_code_block=true
                code_lang="js"
                continue
                ;;
            '```'bash* | '```'shell* | '```'sh*)
                in_code_block=true
                code_lang="shell"
                continue
                ;;
            '```'*)
                if [ "$in_code_block" = "true" ]; then
                    in_code_block=false
                    code_lang=""
                else
                    in_code_block=true
                    code_lang="unknown"
                fi
                continue
                ;;
        esac

        [ "$in_code_block" = "false" ] && continue

        # Python: check imports
        if [ "$code_lang" = "python" ]; then
            # Match: from X import Y or import X. The trailing `|| true` is
            # load-bearing: under `set -euo pipefail`, a `grep` that finds no
            # match makes this command substitution non-zero and aborts the
            # WHOLE scan mid-file (silently dropping every later finding). The
            # empty result is already handled by the `[ -n "$module" ]` guard.
            module=$(command echo "$line" | command grep -oE '^(from|import) [a-zA-Z_][a-zA-Z0-9_.]*' | command awk '{print $2}' | command head -1 || true)
            if [ -n "$module" ]; then
                # Convert module path to file path
                module_path=$(command echo "$module" | command sed 's/\./\//g')
                # Check if the module exists as a file or directory
                if [ ! -f "${PROJECT_ROOT}/${module_path}.py" ] &&
                    [ ! -f "${PROJECT_ROOT}/${module_path}/__init__.py" ] &&
                    [ ! -d "${PROJECT_ROOT}/${module_path}" ]; then
                    # Skip standard library and common third-party modules
                    case "$module" in
                        os | sys | re | json | typing | pathlib | collections | functools | itertools | dataclasses | \
                            datetime | math | random | copy | io | abc | enum | logging | unittest | pytest | \
                            flask | django | fastapi | requests | numpy | pandas | click | pydantic) continue ;;
                    esac
                    evidence=$(truncate_chars 80 "Import not found in project: ${line}")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "broken-example" \
                        "$evidence" "HIGH"
                fi
            fi
        fi

        # Shell: check script references
        if [ "$code_lang" = "shell" ]; then
            # Match: ./scripts/foo.sh or bash scripts/foo.sh. `|| true` for the
            # same reason as the python arm above — a no-match grep here would
            # otherwise abort the whole scan under `set -e` (a shell code block
            # line without a `.sh` reference is common). Guarded by `[ -n "$script" ]`.
            script=$(command echo "$line" | command grep -oE '(\./|bash |sh )[a-zA-Z0-9_./-]+\.sh' | command sed 's/^bash //' | command sed 's/^sh //' | command head -1 || true)
            if [ -n "$script" ]; then
                if [ ! -f "${PROJECT_ROOT}/${script}" ]; then
                    evidence=$(truncate_chars 80 "Script not found: ${script}")
                    command printf '%s\t%s\t%s\t%s\t%s\n' \
                        "$file" "$line_num" "broken-example" \
                        "$evidence" "HIGH"
                fi
            fi
        fi

    done <"$file"

done <"$FILE_LIST"
