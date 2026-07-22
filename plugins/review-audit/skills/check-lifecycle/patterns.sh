#!/usr/bin/env bash
# check-lifecycle — Deterministic Pre-Scan
#
# Detects resource-lifecycle CANDIDATES catchable by a single-line regex:
# subprocess spawn sites, SIGTERM/terminate sites, unscoped handle acquisitions,
# and listener/timer registrations. Each is suspicious on one line but the paired
# release may live elsewhere in the scope, so every row is certainty MEDIUM — a
# candidate the LLM pass-2 confirms/dismisses, never an auto-fix. The
# judgment-heavy categories (unjoined-worker, unbounded-growth) are LLM-only.
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
# The is_test_file() block mirrors the segment-anchored check-code-health /
# ship-issue copies for classification uniformity, but is NOT wired into the
# validate-shared-scanner-sync.sh drift gate (that gate covers only the
# check-code-health <-> ship-issue pair); this copy stands alone. See
# CLAUDE.md § Key conventions.
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

# is_test_file PATH — return 0 (true) if PATH is a test file by path/name
# convention. Segment-anchored so that contest.py / latest.js / attestation.go
# (which a bare *test* glob wrongly matches) are NOT skipped, while
# tests/helper.py IS. Mirrors the check-code-health / ship-issue copies for
# classification uniformity (not gated by validate-shared-scanner-sync.sh — see
# the header note). check-lifecycle skips a test file WHOLESALE (below).
is_test_file() {
    case "$1" in
        tests/* | */tests/* | test/* | */test/* | \
            __tests__/* | */__tests__/* | spec/* | */spec/* | \
            __pycache__/* | */__pycache__/*) return 0 ;;
        test_*.* | */test_*.*) return 0 ;;
        *_test.* | *_spec.* | *.test.* | *.spec.*) return 0 ;;
    esac
    return 1
}

# emit_rows PATTERN CATEGORY LABEL FILE — one MEDIUM row per matching line,
# evidence = "LABEL: <first 80 chars of the line>". Mirrors patterns.py emit().
emit_rows() {
    command grep -nE -- "$1" "$4" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$4" "$line_num" "$2" "$3: ${evidence}" "MEDIUM"
        done || true
}

# Per-category labels — ONE literal per category across every language arm, kept
# identical to patterns.py's L_* constants (byte-parity insurance).
L_SUBPROCESS="Subprocess spawned without visible reap"
L_TERMINATE="Terminate without kill escalation"
L_HANDLE="Handle acquired without scoped close"
L_LISTENER="Listener/timer registered without visible removal"

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip non-source files (lock files before generic extensions)
    case "$file" in
        *.lock | *lock.json | *go.sum) continue ;;
        *.md | *.txt | *.json | *.yaml | *.yml | *.toml | *.ini | *.cfg | *.conf) continue ;;
    esac

    # Lifecycle shortcuts in test scaffolding are expected — skip test files
    # WHOLESALE (unlike check-code-health, which only gates debug-statement).
    is_test_file "$file" && continue

    case "$file" in
        *.swift)
            emit_rows '\bProcess\s*\(' "unreaped-subprocess" "$L_SUBPROCESS" "$file"
            emit_rows '\.terminate\s*\(\)' "terminate-without-kill" "$L_TERMINATE" "$file"
            emit_rows '=\s*FileHandle\s*\(' "unclosed-handle" "$L_HANDLE" "$file"
            emit_rows '\.addObserver\s*\(|\bscheduledTimer\b' "unpaired-listener" "$L_LISTENER" "$file"
            ;;
        *.py)
            emit_rows '\b(subprocess\.)?Popen\s*\(' "unreaped-subprocess" "$L_SUBPROCESS" "$file"
            emit_rows '\.terminate\s*\(\)' "terminate-without-kill" "$L_TERMINATE" "$file"
            emit_rows '=\s*open\s*\(' "unclosed-handle" "$L_HANDLE" "$file"
            ;;
        *.js | *.ts | *.jsx | *.tsx)
            emit_rows '\b(spawn|spawnSync|exec|execFile|execFileSync|execSync)\s*\(' "unreaped-subprocess" "$L_SUBPROCESS" "$file"
            emit_rows '\.terminate\s*\(\)' "terminate-without-kill" "$L_TERMINATE" "$file"
            emit_rows '=\s*fs\.(openSync|createReadStream|createWriteStream)\s*\(' "unclosed-handle" "$L_HANDLE" "$file"
            emit_rows '\.addEventListener\s*\(|\bsetInterval\s*\(|\.on\s*\(' "unpaired-listener" "$L_LISTENER" "$file"
            ;;
        *.go)
            emit_rows '\bexec\.Command\s*\(' "unreaped-subprocess" "$L_SUBPROCESS" "$file"
            emit_rows '\bos\.Interrupt\b' "terminate-without-kill" "$L_TERMINATE" "$file"
            emit_rows '\bos\.(Open|Create)\s*\(' "unclosed-handle" "$L_HANDLE" "$file"
            ;;
    esac

done <"$FILE_LIST"
