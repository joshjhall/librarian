#!/usr/bin/env bash
# loop-make-it-tested — Deterministic Pre-Scan
#
# Detects test coverage gaps: public functions without test files,
# test files without assertions, source modules without test counterparts.
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

# py_public_symbols_gate <file> — this MODULE's public-API policy (#606).
#
# The extractor below treats every non-underscore top-level `def` as public API,
# which is wrong for a `main()`-guarded CLI script: its internal helpers are
# driven end-to-end THROUGH the entry point, never imported and never named by a
# test, so a well-exercised helper reported HIGH "no tests reference".
#
# Three policies, echoed on stdout:
#   all:<space-separated names>  __all__ present — only these names are public
#   none                         main()-guarded, no __all__ — nothing is API
#   open                         plain module — every top-level def is public
#
# __all__ takes precedence over the main() guard deliberately: it is a POSITIVE
# declaration by the author, and it is the escape hatch for a module that is
# genuinely both a CLI and an importable library.
#
# Three copies of this logic exist: here, in the sibling patterns.py
# (_py_public_symbols_gate), and in ship-issue's pre-review-gates.sh. Both
# agreements are now mechanically ENFORCED:
#
#   this file <-> sibling patterns.py    — PINNED by tests/validate-python-ports.sh
#                                          (whole-corpus TSV parity), plus the
#                                          #606 cases in validate-loop-detectors.sh
#   this file <-> pre-review-gates.sh    — PINNED by the `shared:py-public-symbols`
#                                          region below, compared line-for-line by
#                                          tests/validate-shared-scanner-sync.sh (#609)
#
# The cross-plugin pair cannot share a sourced library (CLAUDE_PLUGIN_ROOT is
# plugin-scoped and `workflow` installs without `dev-core`), so the duplication is
# deliberate. Edit all three copies together: the two gates above will fail the
# build on a one-sided change, but neither can make the edit for you.
#
# Only the sentinel-bracketed FUNCTION BODIES are compared — this doc comment is
# outside the region and deliberately differs from pre-review-gates.sh's, which
# carries additional #600/#606 rationale. Comments INSIDE the region are compared
# like any other line.
# >>> shared:py-public-symbols (kept in sync with ship-issue/pre-review-gates.sh by tests/validate-shared-scanner-sync.sh)
py_public_symbols_gate() {
    local file="$1" all_names

    # `__all__ = [...]` / `(...)`, possibly spanning lines. Take from the first
    # __all__ assignment to the closing bracket, then keep only the quoted
    # names. A module with __all__ answers `all:` even if it is ALSO guarded.
    #
    # awk, not `sed -n '/start/,/end/p'`: a sed range looks for its END pattern
    # starting at the line AFTER the start, so a single-line `__all__ = ["x"]`
    # does not terminate on its own closing bracket and the range runs on to the
    # next `]` or `)` anywhere in the file — swallowing unrelated quoted strings
    # as if they were exported names. The awk below tests the start line itself.
    if command grep -qE '^__all__([[:space:]]*:[^=]*)?[[:space:]]*=' "$file" 2>/dev/null; then
        all_names=$(command awk '
            /^__all__([[:space:]]*:[^=]*)?[[:space:]]*=/ && !inb {
                inb = 1
                rest = substr($0, index($0, "=") + 1)
                print rest
                if (rest ~ /[])]/) exit
                next
            }
            inb { print; if ($0 ~ /[])]/) exit }
        ' "$file" 2>/dev/null |
            command grep -oE '"[a-zA-Z_][a-zA-Z0-9_]*"|'\''[a-zA-Z_][a-zA-Z0-9_]*'\''' |
            command tr -d '"'\''' | command tr '\n' ' ')
        command printf 'all:%s' "$all_names"
        return
    fi

    # The `if __name__ == "__main__":` guard, in either quote style. Anchored at
    # column 0: a guard nested inside a function or class is not the module's
    # entry point and must not gate the whole file.
    if command grep -qE '^if[[:space:]]+__name__[[:space:]]*==[[:space:]]*["'\'']__main__["'\'']' \
        "$file" 2>/dev/null; then
        command printf 'none'
        return
    fi

    command printf 'open'
}

# py_symbol_is_public <symbol> <gate> — 0 when <symbol> is public under <gate>.
py_symbol_is_public() {
    local symbol="$1" gate="$2"
    case "$gate" in
        none) return 1 ;;
        all:*)
            # Whole-word match within the space-delimited name list; the padding
            # keeps `check_mcp` from matching `check_mcp_config`.
            case " ${gate#all:} " in
                *" $symbol "*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *) return 0 ;;
    esac
}
# <<< shared:py-public-symbols

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip test files themselves and non-source files
    case "$file" in
        *test* | *spec* | *__pycache__* | *.md | *.yml | *.yaml | *.json | *.toml) continue ;;
    esac

    basename=$(command basename "$file")
    dirname=$(command dirname "$file")
    name_no_ext="${basename%.*}"
    ext="${basename##*.}"

    # --- Category: missing-test-file ---
    # Check if a corresponding test file exists
    has_test=false
    case "$ext" in
        py)
            for test_path in \
                "${dirname}/test_${name_no_ext}.py" \
                "${dirname}/tests/test_${name_no_ext}.py" \
                "${dirname}/../tests/test_${name_no_ext}.py" \
                "${dirname}/${name_no_ext}_test.py"; do
                if [ -f "$test_path" ]; then
                    has_test=true
                    break
                fi
            done
            ;;
        ts | js | tsx | jsx)
            for suffix in "test" "spec"; do
                for test_path in \
                    "${dirname}/${name_no_ext}.${suffix}.${ext}" \
                    "${dirname}/__tests__/${name_no_ext}.${suffix}.${ext}" \
                    "${dirname}/../__tests__/${name_no_ext}.${suffix}.${ext}"; do
                    if [ -f "$test_path" ]; then
                        has_test=true
                        break 2
                    fi
                done
            done
            ;;
        go)
            test_path="${dirname}/${name_no_ext}_test.go"
            if [ -f "$test_path" ]; then
                has_test=true
            fi
            ;;
        rs)
            # Rust: check for mod tests in same file or tests/ directory
            if command grep -q '#\[cfg(test)\]' "$file" 2>/dev/null; then
                has_test=true
            elif [ -d "${dirname}/../tests" ]; then
                has_test=true
            fi
            ;;
    esac

    if [ "$has_test" = "false" ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "missing-test-file" \
            "No test file found for ${basename}" "HIGH"
    fi

    # --- Category: untested-public-api ---
    # Public/exported functions that should have test coverage
    case "$ext" in
        py)
            # Public functions (not starting with _), minus this module's
            # non-public symbols (#606) — resolved ONCE per file, since the
            # policy is a property of the module and not of the symbol.
            py_gate="$(py_public_symbols_gate "$file")"
            command grep -nE '^def [a-zA-Z][a-zA-Z0-9_]*\(' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    func_name=$(command printf '%s' "$content" | command sed 's/^def \([a-zA-Z][a-zA-Z0-9_]*\).*/\1/')
                    # Not public API for this module — no test is EXPECTED to
                    # name it, so "no tests reference" is not a finding.
                    py_symbol_is_public "$func_name" "$py_gate" || continue
                    # Check if this function appears in any test file nearby.
                    # The third glob mirrors pre-review-gates.sh, whose py arm
                    # has always had it — a src/ module tested from a sibling
                    # tests/ tree is the commonest layout there is, and without
                    # it that whole shape reported HIGH (#606).
                    if ! command grep -rql "\b${func_name}\b" "${dirname}"/test_*.py "${dirname}"/tests/test_*.py "${dirname}"/../tests/test_*.py 2>/dev/null; then
                        evidence=$(truncate_chars 60 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "untested-public-api" \
                            "No tests reference ${func_name}: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
        go)
            # Exported functions (capitalized)
            command grep -nE '^func [A-Z][a-zA-Z0-9]*\(' "$file" 2>/dev/null |
                while IFS= read -r raw; do
                    line_num=${raw%%:*}
                    content=${raw#*:}
                    func_name=$(command printf '%s' "$content" | command sed 's/^func \([A-Z][a-zA-Z0-9]*\).*/\1/')
                    test_file="${dirname}/${name_no_ext}_test.go"
                    if [ -f "$test_file" ] && ! command grep -q "\b${func_name}\b" "$test_file" 2>/dev/null; then
                        evidence=$(truncate_chars 60 "$content")
                        command printf '%s\t%s\t%s\t%s\t%s\n' \
                            "$file" "$line_num" "untested-public-api" \
                            "No tests reference ${func_name}: ${evidence}" "HIGH"
                    fi
                done || true
            ;;
    esac

done <"$FILE_LIST"
