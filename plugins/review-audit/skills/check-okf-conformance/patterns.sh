#!/usr/bin/env bash
# check-okf-conformance — Deterministic Pre-Scan
#
# Answers ONE question about a memory bundle: is it a conformant Open Knowledge
# Format bundle at the SCHEMA FLOOR (OKF §11)? Every non-reserved `.md` has a
# parseable frontmatter block carrying a non-empty `type`, and the reserved files
# (`index.md`, `log.md`) follow §8/§9 when present. Graph health, semantic
# quality, and migration are separate slices and out of scope.
#
# TWO KINDS OF FAILURE, KEPT STRICTLY APART:
#
#   * THE BUNDLE is never rejected. Unknown `type` values, unrecognized extra
#     keys, broken cross-links, a missing index.md, and a drifted okf_version are
#     FINDINGS AT EXIT 0 (§11, §12). Non-conformance is reported, never fatal.
#   * THE TOOL fails loud. A missing/malformed version pin, a usage error, or an
#     unreadable file list exits NON-ZERO with an actionable message — a tool
#     that cannot do its job must not report a clean bundle it never checked
#     (#538/#571).
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = success (zero or more findings), including a non-conformant bundle
#   1 = usage error, file list not found, or an unresolvable version pin
#
# Note: Uses full paths for commands per project shell-scripting conventions.
#
# Runtime: Python 3.11+ primary (patterns.py) with this bash script as the
# portable fallback. The shim below exec's patterns.py when a python3>=3.11 is
# present (identical TSV contract); PATTERNS_FORCE_BASH=1 forces this bash body.
#
# bash-3.2 clean and BSD-regex safe: no declare -A / mapfile / namerefs /
# ${v,,} / ;;&, and no \s \w \b or grep -P — macOS ships bash 3.2 and BSD
# grep/sed, which read those as LITERALS and would silently match nothing.
# See CLAUDE.md § Runtime policy.
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/patterns.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/patterns.py" "$@"
fi

# fail MESSAGE — actionable TOOL-side error, non-zero. Distinct from every
# bundle-conformance path, which emits findings and exits 0.
fail() {
    command printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

FILE_LIST="${1:-}"
if [ -z "$FILE_LIST" ]; then
    command printf 'Usage: patterns.sh <file-list>\n' >&2
    exit 1
fi

# --- the OKF version pin: single source, or a loud failure -------------------
# Mirrors read_pinned_version() in patterns.py: $OKF_PINNED_VERSION, else
# `okf.pinned_version` from thresholds.yml, else fail. A pure-bash parse rather
# than sed — BSD and GNU sed differ, and this shape is fixed (CLAUDE.md prefers
# a pure-bash parse for simple formats; read_yaml_list in ship-issue's
# pre-review-gates.sh is the worked example).
read_pinned_version() {
    local file="$1" line stripped val in_okf=0 first env_val
    # TRIM BEFORE THE EMPTINESS TEST, mirroring patterns.py's
    # os.environ.get(...).strip(). Testing the RAW value would make a
    # whitespace-only override (a CI template that expanded to nothing, a
    # stray `export OKF_PINNED_VERSION=" "`) non-empty here and empty in
    # python: bash would return the blank, fail the <major>.<minor> check, and
    # exit 1 "malformed pin", while python fell through to thresholds.yml and
    # scanned normally. Same environment, opposite verdicts — and on exactly
    # the fail-loud/permissive boundary this skill exists to keep straight.
    env_val="${OKF_PINNED_VERSION:-}"
    env_val="${env_val#"${env_val%%[![:space:]]*}"}"
    env_val="${env_val%"${env_val##*[![:space:]]}"}"
    if [ -n "$env_val" ]; then
        command printf '%s' "$env_val"
        return 0
    fi
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim leading whitespace for the blank/comment tests.
        stripped="${line#"${line%%[![:space:]]*}"}"
        [ -n "$stripped" ] || continue
        case "$stripped" in '#'*) continue ;; esac
        # A top-level key (column 0, not a list item) opens or closes the block.
        # The glob mirrors patterns.py's `not line[0].isspace() and not
        # line.startswith("-")` — deliberately NOT an alpha test, which would be
        # Unicode-aware in Python and ASCII-only in bash (the #686 divergence).
        first="${line%"${line#?}"}"
        case "$first" in
            ' ' | "$(command printf '\t')") ;;
            '-') in_okf=0 ;;
            *)
                case "$line" in
                    okf:*) in_okf=1 ;;
                    *) in_okf=0 ;;
                esac
                continue
                ;;
        esac
        [ "$in_okf" -eq 1 ] || continue
        case "$stripped" in
            pinned_version:*) ;;
            *) continue ;;
        esac
        val="${stripped#pinned_version:}"
        # Drop an inline comment BEFORE unquoting, so `"0.2" # OKF_PINNED_VERSION`
        # yields `0.2` rather than the whole tail.
        case "$val" in *'#'*) val="${val%%#*}" ;; esac
        # Trim surrounding whitespace, then one layer of quotes, then whitespace.
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        val="${val#\"}"
        val="${val%\"}"
        val="${val#\'}"
        val="${val%\'}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        command printf '%s' "$val"
        return 0
    done <"$file"
    return 0
}

# TOOL-side gate, resolved BEFORE any scanning: without a pin there is nothing to
# compare a declared okf_version against, so proceeding would emit a
# findings-free report of a bundle that was never fully checked.
PINNED="$(read_pinned_version "$_here/thresholds.yml")"
if [ -z "$PINNED" ]; then
    fail "no OKF version pin — set OKF_PINNED_VERSION or provide \`okf.pinned_version\` in thresholds.yml. It is the single source of the pin; without it version drift cannot be judged."
fi
if ! command printf '%s' "$PINNED" | command grep -qE '^[0-9]+\.[0-9]+$'; then
    fail "OKF version pin is not a <major>.<minor> version: $PINNED (spec §12). A malformed pin would silently never match a declared version."
fi

if [ ! -f "$FILE_LIST" ]; then
    command printf 'Error: file list not found: %s\n' "$FILE_LIST" >&2
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

# --- bundle root -------------------------------------------------------------
# $OKF_BUNDLE_ROOT -> $MEMORY_BUNDLE_ROOT -> .claude/memory. Mirrors
# bundle_root() in patterns.py. The `-` (not `:-`) default preserves an
# explicitly EMPTY value, which means "no bundle configured" — no findings, no
# error. Normalized so `.claude/memory`, `./.claude/memory` and `.claude/memory/`
# all decide alike; an unnormalized root would simply miss and still exit 0,
# the silent fail-open of the #662 class.
if [ -n "${OKF_BUNDLE_ROOT+set}" ]; then
    BUNDLE_ROOT="$OKF_BUNDLE_ROOT"
else
    BUNDLE_ROOT="${MEMORY_BUNDLE_ROOT-.claude/memory}"
fi
BUNDLE_ROOT="${BUNDLE_ROOT#"${BUNDLE_ROOT%%[![:space:]]*}"}"
BUNDLE_ROOT="${BUNDLE_ROOT%"${BUNDLE_ROOT##*[![:space:]]}"}"
while :; do
    case "$BUNDLE_ROOT" in
        ./*) BUNDLE_ROOT="${BUNDLE_ROOT#./}" ;;
        */) BUNDLE_ROOT="${BUNDLE_ROOT%/}" ;;
        *) break ;;
    esac
done

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
        command printf '%s' "${s:0:$n}"
    else
        command printf "%.${n}s" "$s"
    fi
}

# emit FILE LINE CATEGORY EVIDENCE CERTAINTY — one TSV row. Mirrors emit() in
# patterns.py, including the 80-CHARACTER evidence cap.
#
# Evidence carries a LABEL plus at most a fragment of the offending line, never a
# document's body: a memory bundle holds operator-specific working notes and, in
# a consumer repo, material this repo has never seen (#664 Notes).
emit() {
    command printf '%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$3" "$(truncate_chars 80 "$4")" "$5"
}

# Category slugs and evidence labels — ONE literal each, identical to the
# C_*/L_* constants in patterns.py (byte-parity insurance).
C_MISSING_TYPE="okf-missing-type"
C_UNPARSEABLE="okf-unparseable-frontmatter"
C_VERSION_DRIFT="okf-version-drift"
C_RESERVED_STRUCTURE="okf-reserved-file-structure"

L_NO_FRONTMATTER="Concept has no frontmatter block"
L_UNTERMINATED="Frontmatter block is not terminated"
L_BAD_LINE="Frontmatter line is not parseable"
L_TYPE_ABSENT="Concept frontmatter has no type key"
L_TYPE_EMPTY="Concept type is present but empty"
L_DRIFT="Bundle declares okf_version"
L_INDEX_FRONTMATTER="index.md carries frontmatter"
L_LOG_DATE="log.md date heading is not ISO 8601 YYYY-MM-DD"

TAB="$(command printf '\t')"

# is_delim LINE — `---` alone on its line (§4), trailing whitespace tolerated.
is_delim() {
    case "$1" in
        '---') return 0 ;;
        '---'*)
            case "${1#---}" in
                *[![:space:]]*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
    esac
    return 1
}

# key_of LINE — the key of a `key: value` line, or empty when the line is not
# one. Mirrors KEY_RE = ^([^:#\s][^:]*):(.*)$ in patterns.py: the first char may
# not be whitespace, `:` or `#`, and the key part holds no further `:`.
key_of() {
    local line="$1" head first
    case "$line" in *:*) ;; *) return 0 ;; esac
    head="${line%%:*}"
    [ -n "$head" ] || return 0
    first="${head%"${head#?}"}"
    case "$first" in
        ' ' | "$TAB" | '#') return 0 ;;
    esac
    # Trailing whitespace comes off the key (patterns.py's .rstrip()).
    head="${head%"${head##*[![:space:]]}"}"
    command printf '%s' "$head"
}

# value_of LINE — the value of a `key: value` line, whitespace-trimmed.
value_of() {
    local val="$1"
    val="${val#*:}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    command printf '%s' "$val"
}

# is_nested LINE — an indented / list / comment / blank continuation line.
# Mirrors NESTED_RE in patterns.py. Not interpreted: the floor asks only that the
# block is parseable.
is_nested() {
    case "$1" in
        '' | ' '* | "$TAB"* | '#'*) return 0 ;;
        '- '* | "-$TAB"*) return 0 ;;
    esac
    return 1
}

# unquote VALUE — strip one layer of surrounding quotes and re-trim.
unquote() {
    local v="$1"
    v="${v#\"}"
    v="${v%\"}"
    v="${v#\'}"
    v="${v%\'}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    command printf '%s' "$v"
}

# in_bundle PATH — PATH lies under $BUNDLE_ROOT.
#
# The `case` patterns QUOTE the root so bash matches it LITERALLY, which is what
# makes a root containing glob metacharacters (`[`, `*`, `?`) behave identically
# here and in patterns.py's literal containment test. An unquoted expansion would
# read `[x]` as a character class, and the two impls would disagree about the
# same file — silently, at exit 0.
in_bundle() {
    [ -n "$BUNDLE_ROOT" ] || return 1
    case "$1" in
        "$BUNDLE_ROOT"/* | */"$BUNDLE_ROOT"/*) return 0 ;;
    esac
    return 1
}

# bundle_dir_of PATH — the CONCRETE bundle directory PATH lives in (its prefix
# up to and including $BUNDLE_ROOT), or nothing when it is not in a bundle.
# Mirrors bundle_dir_of() in patterns.py.
#
# The slice-B pass needs a directory to enumerate, and it MUST come from the file
# list rather than from "$PWD/$BUNDLE_ROOT": the root is a RELATIVE fragment
# matched anywhere in a path, so resolving it against the CWD scans a different
# bundle than the caller passed whenever the two differ — for a fixture under
# /tmp while the CWD is a repo with its own .claude/memory, that silently reports
# on the repo's real bundle.
bundle_dir_of() {
    local path="$1" tail_part
    [ -n "$BUNDLE_ROOT" ] || return 0
    case "$path" in
        "$BUNDLE_ROOT"/*)
            command printf '%s' "$BUNDLE_ROOT"
            return 0
            ;;
        */"$BUNDLE_ROOT"/*)
            # Strip the shortest trailing match so the prefix ENDS at the root.
            tail_part="/${BUNDLE_ROOT}/${path#*/"$BUNDLE_ROOT"/}"
            command printf '%s' "${path%"$tail_part"}/$BUNDLE_ROOT"
            return 0
            ;;
    esac
    return 0
}

# is_bundle_root_file PATH — PATH sits at the TOP level of the bundle rather than
# in a subdirectory. §8 permits frontmatter in a bundle-ROOT index.md only.
is_bundle_root_file() {
    local path="$1" rest
    [ -n "$BUNDLE_ROOT" ] || return 1
    case "$path" in
        "$BUNDLE_ROOT"/*)
            rest="${path#"$BUNDLE_ROOT"/}"
            ;;
        */"$BUNDLE_ROOT"/*)
            rest="${path#*/"$BUNDLE_ROOT"/}"
            ;;
        *) return 1 ;;
    esac
    case "$rest" in
        */*) return 1 ;;
    esac
    return 0
}

# --- frontmatter parse -------------------------------------------------------
# Sets, for the file whose lines are read from $1:
#   FM_ERR       "" or an L_* label
#   FM_ERR_LINE  1-based line the error refers to
#   FM_KEYS      newline-separated "key<TAB>value<TAB>lineno", first wins
#
# There is no FM_END counterpart to patterns.py's `end`: that value exists there
# only to bound _okf_version_line's search for the okf_version line, and this
# impl already records each key's line number in FM_KEYS.
# A parallel-array/associative shape is avoided deliberately: bash 3.2 has no
# `declare -A`, and one delimited string keeps the two impls' logic aligned.
FM_ERR=""
FM_ERR_LINE=0
FM_KEYS=""
parse_frontmatter() {
    local file="$1" line idx=0 key val seen
    FM_ERR=""
    FM_ERR_LINE=0
    FM_KEYS=""
    while IFS= read -r line || [ -n "$line" ]; do
        idx=$((idx + 1))
        if [ "$idx" -eq 1 ]; then
            if ! is_delim "$line"; then
                FM_ERR="$L_NO_FRONTMATTER"
                FM_ERR_LINE=1
                return 0
            fi
            continue
        fi
        if is_delim "$line"; then
            return 0
        fi
        key="$(key_of "$line")"
        if [ -n "$key" ]; then
            # First occurrence wins, so a duplicated key cannot mask the first
            # value. Duplicates are not themselves a finding — §11 does not make
            # them one.
            seen=0
            case "$TAB$FM_KEYS" in
                *"$TAB$key$TAB"*) seen=1 ;;
            esac
            if [ "$seen" -eq 0 ]; then
                val="$(value_of "$line")"
                FM_KEYS="${FM_KEYS}${key}${TAB}${val}${TAB}${idx}
"
            fi
            continue
        fi
        if is_nested "$line"; then
            continue
        fi
        FM_ERR="$L_BAD_LINE"
        FM_ERR_LINE="$idx"
        return 0
    done <"$file"
    if [ "$idx" -eq 0 ]; then
        # An empty file has no frontmatter block at all.
        FM_ERR="$L_NO_FRONTMATTER"
        FM_ERR_LINE=1
        return 0
    fi
    FM_ERR="$L_UNTERMINATED"
    FM_ERR_LINE=1
    return 0
}

# fm_has KEY — true when the parsed frontmatter carries KEY.
#
# LINE-ORIENTED, like fm_field/fm_extra_keys beside it, because FM_KEYS is
# NEWLINE-delimited rows of `key<TAB>value<TAB>line`. The previous single `case`
# tested "$TAB$FM_KEYS" for `<TAB>key<TAB>`, which can only align on the FIRST
# row: every later row is preceded by a NEWLINE, not a tab. So any concept whose
# `type` was not the very first frontmatter key was reported okf-missing-type
# despite declaring one.
#
# Not hypothetical, and not small: every one of this repo's own 215 memories
# writes `name:`/`description:` before `type:`, so all 215 were being reported
# as missing a type they actually have. Python's dict lookup has no such
# ordering dependence, which is why this surfaced as a bash/python divergence
# (#669 review cycle 1) rather than as a wrong-looking report.
fm_has() {
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            "$1$TAB"*) return 0 ;;
        esac
    done <<EOF
$FM_KEYS
EOF
    return 1
}
fm_field() {
    local key="$1" field="$2" line rest
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            "$key$TAB"*)
                rest="${line#*"$TAB"}"
                if [ "$field" = value ]; then
                    command printf '%s' "${rest%"$TAB"*}"
                else
                    command printf '%s' "${rest##*"$TAB"}"
                fi
                return 0
                ;;
        esac
    done <<EOF
$FM_KEYS
EOF
    return 0
}

# fm_extra_keys EXCEPT — 0 (true) when the block holds a key other than EXCEPT.
fm_extra_keys() {
    local except="$1" line key
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        key="${line%%"$TAB"*}"
        [ "$key" = "$except" ] || return 0
    done <<EOF
$FM_KEYS
EOF
    return 1
}

# --- per-file rules ----------------------------------------------------------

# scan_concept FILE — §4.1 / §11 items 1-2: parseable frontmatter with a
# non-empty `type`. Reserved files never reach here.
scan_concept() {
    local file="$1" tval
    parse_frontmatter "$file"
    if [ -n "$FM_ERR" ]; then
        emit "$file" "$FM_ERR_LINE" "$C_UNPARSEABLE" "$FM_ERR" "HIGH"
        return 0
    fi
    if ! fm_has type; then
        emit "$file" 1 "$C_MISSING_TYPE" "$L_TYPE_ABSENT" "HIGH"
        return 0
    fi
    tval="$(fm_field type value)"
    if [ -z "$tval" ]; then
        emit "$file" 1 "$C_MISSING_TYPE" "$L_TYPE_EMPTY" "HIGH"
    fi
    # An UNKNOWN type value is fully conformant (§4.1), as are any additional
    # producer-defined keys. Nothing more is checked — `type` is the entire floor.
}

# scan_index FILE — §8: an index.md carries NO frontmatter, with one exception —
# a bundle-ROOT index.md MAY carry `okf_version` (§12). An index.md with no
# frontmatter is the normal conformant case and is silent; a MISSING index.md is
# likewise never a finding (§11).
scan_index() {
    local file="$1" first_line declared at_root=0
    IFS= read -r first_line <"$file" || first_line=""
    is_delim "$first_line" || return 0
    parse_frontmatter "$file"
    if [ -n "$FM_ERR" ]; then
        emit "$file" "$FM_ERR_LINE" "$C_UNPARSEABLE" "$FM_ERR" "HIGH"
        return 0
    fi
    is_bundle_root_file "$file" && at_root=1
    if [ "$at_root" -eq 0 ] || fm_extra_keys okf_version; then
        emit "$file" 1 "$C_RESERVED_STRUCTURE" "$L_INDEX_FRONTMATTER" "MEDIUM"
    fi
    if [ "$at_root" -eq 1 ] && fm_has okf_version; then
        declared="$(unquote "$(fm_field okf_version value)")"
        # An ABSENT okf_version is not a finding (§12: bundles MAY declare one).
        # A declared version that differs from the pin is LOW and still exit 0 —
        # §12 asks for best-effort consumption, not refusal.
        if [ -n "$declared" ] && [ "$declared" != "$PINNED" ]; then
            emit "$file" "$(fm_field okf_version line)" "$C_VERSION_DRIFT" \
                "$L_DRIFT $declared, pinned $PINNED" "LOW"
        fi
    fi
}

# scan_log FILE — §9: date headings MUST use ISO 8601 YYYY-MM-DD. Entries are
# prose and the leading bold word is a convention, so nothing else is checked.
scan_log() {
    local file="$1" line idx=0 fenced=0 heading
    while IFS= read -r line || [ -n "$line" ]; do
        idx=$((idx + 1))
        case "$line" in
            '```'* | '~~~'*)
                if [ "$fenced" -eq 0 ]; then fenced=1; else fenced=0; fi
                continue
                ;;
        esac
        [ "$fenced" -eq 0 ] || continue
        case "$line" in
            '## '* | "##$TAB"*) ;;
            *) continue ;;
        esac
        heading="${line#\#\#}"
        heading="${heading#"${heading%%[![:space:]]*}"}"
        heading="${heading%"${heading##*[![:space:]]}"}"
        if ! command printf '%s' "$heading" | command grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
            emit "$file" "$idx" "$C_RESERVED_STRUCTURE" "$L_LOG_DATE: $heading" "MEDIUM"
        fi
    done <"$file"
}

# --- slice B: bundle graph + health (#669) -----------------------------------
# Mirrors bundle_graph.py function-for-function. Read that file's module
# docstring for the design: the pass enumerates the bundle ROOT rather than the
# file list, because an orphan is "no index names this concept" and the index is
# usually not in the same diff as the concept.
#
# Categories and evidence labels — ONE literal each, byte-identical to the C_*/
# L_* constants in bundle_graph.py.
C_ORPHAN="memory-orphan"
C_DANGLING_INDEX="memory-dangling-index"
C_MULTI_INDEX="memory-multi-index"
C_STALE="memory-stale"
C_MISSING_WHY="memory-missing-why"

L_ORPHAN="Concept is named by no index"
L_DANGLING="Index names a file that does not exist"
L_MULTI="Concept is named by more than one index"
L_STALE_DATE="Memory is past its stale_after date"
L_STALE_DEPRECATED="Memory is marked status: deprecated"
L_MISSING_WHY="Body is missing a section required for this type"

DEFAULT_INDEX_NAMES="MEMORY.md index.md index-*.md"

# read_config_list FILE KEY — the `- item` list under `health.<KEY>`, one per
# line. Mirrors read_config_list() in bundle_graph.py, including the
# absent-vs-empty distinction: an ABSENT key prints nothing and returns 1, an
# empty one prints nothing and returns 0, so a caller can tell "use the default"
# from "the operator configured none". Collapsing them would make a rule
# impossible to turn off.
read_config_list() {
    local file="$1" key="$2" line stripped first in_health=0 in_key=0 found=1 item
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        stripped="${stripped%"${stripped##*[![:space:]]}"}"
        [ -n "$stripped" ] || continue
        case "$stripped" in '#'*) continue ;; esac
        first="${line%"${line#?}"}"
        case "$first" in
            ' ' | "$TAB") ;;
            *)
                # A column-0 line opens or closes `health:`, and always ends any
                # key block within it.
                case "$stripped" in
                    health:*) in_health=1 ;;
                    *) in_health=0 ;;
                esac
                in_key=0
                continue
                ;;
        esac
        [ "$in_health" -eq 1 ] || continue
        case "$stripped" in
            '- '*)
                if [ "$in_key" -eq 1 ]; then
                    item="${stripped#- }"
                    # Strip an inline comment, then one layer of quotes.
                    case "$item" in *' #'*) item="${item%% #*}" ;; esac
                    item="${item#"${item%%[![:space:]]*}"}"
                    item="${item%"${item##*[![:space:]]}"}"
                    item="${item#\"}"
                    item="${item%\"}"
                    item="${item#\'}"
                    item="${item%\'}"
                    command printf '%s\n' "$item"
                fi
                continue
                ;;
        esac
        case "$stripped" in
            "$key":*)
                in_key=1
                found=0
                ;;
            *) in_key=0 ;;
        esac
    done <"$file"
    return "$found"
}

# read_index_names — $OKF_INDEX_NAMES -> thresholds.yml -> built-in default.
# An explicitly EMPTY env override means "no indexes configured", distinct from
# unset, matching the python twin.
read_index_names() {
    local from_config
    if [ -n "${OKF_INDEX_NAMES+set}" ]; then
        command printf '%s' "$OKF_INDEX_NAMES"
        return 0
    fi
    if from_config="$(read_config_list "$_here/thresholds.yml" index_names)"; then
        command printf '%s' "$(command printf '%s' "$from_config" | command tr '\n' ' ')"
        return 0
    fi
    command printf '%s' "$DEFAULT_INDEX_NAMES"
}

# is_index BASENAME NAMES — true when BASENAME routes recall. Mirrors
# is_index() in bundle_graph.py, including the two-pass order.
#
# LITERAL EQUALITY FIRST, for every name, before any glob interpretation: a
# configured name is operator input rather than a pattern language they opted
# into. Checking metacharacters first makes `notes[1].md` a character class that
# does not match the file literally called `notes[1].md`, so the repo's only
# index is classified as a concept and every memory in the bundle is reported as
# an orphan. Both impls did this identically, so parity held while both were
# wrong — see the python twin for the measurement.
is_index() {
    local base="$1" names="$2" n
    for n in $names; do
        [ "$base" = "$n" ] && return 0
    done
    for n in $names; do
        case "$n" in
            *'*'* | *'?'* | *'['*)
                # shellcheck disable=SC2254 # intentional: a configured glob.
                case "$base" in
                    $n) return 0 ;;
                esac
                ;;
        esac
    done
    return 1
}

# index_targets FILE — `<basename>.md<TAB><line>` for every concept an index
# line points at. Markdown link targets first, else bare mentions on that line,
# mirroring the python twin's two regexes. Only the basename is kept.
index_targets() {
    command awk '
        {
            n = 0
            s = $0
            while (match(s, /\]\([^)]*\.md\)/)) {
                t = substr(s, RSTART + 2, RLENGTH - 3)
                sub(/^.*\//, "", t)
                print t "\t" NR
                n++
                s = substr(s, RSTART + RLENGTH)
            }
            if (n == 0) {
                s = $0
                while (match(s, /[A-Za-z0-9._-]+\.md/)) {
                    t = substr(s, RSTART, RLENGTH)
                    pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
                    s = substr(s, RSTART + RLENGTH)
                    # Mirror the python negative lookbehind: a target preceded
                    # by (, a word char, / or - was part of a link or path we
                    # already handled.
                    if (pre ~ /[(A-Za-z0-9_\/-]/) continue
                    sub(/^.*\//, "", t)
                    print t "\t" NR
                }
            }
        }
    ' "$1"
}

# fm_get FILE NAME — a frontmatter value by bare name: TOP LEVEL, or under a
# top-level block literally named `metadata:`. Mirrors frontmatter_fields()+
# field() in the python twin, whose dict holds top-level keys plus `metadata.*`
# flattened, and whose field() looks up only those two spellings.
#
# DEPTH IS NOT LIMITED, and saying so is deliberate. `parent` is reset only by a
# top-level line, so ANY depth under an open `metadata:` block resolves —
# `metadata:` / `sub:` / `status: deprecated` yields `deprecated`. The python
# twin does exactly the same (its `prefix` is likewise touched only by
# non-indented lines), so this is parity, not a bash quirk. An earlier draft of
# this comment claimed "exactly one level"; the code never enforced that, and a
# maintainer who "fixed" the code to match would have BROKEN parity rather than
# restored it (#669 review cycle 2). Pinned by a two-level fixture in
# tests/validate-okf-detectors.sh.
#
# THE SCOPING IS THE POINT, and an earlier version of this function had the
# comment without the code: it stripped indentation from every line and returned
# the first bare-key match at ANY depth under ANY parent. Three divergences from
# the python twin, all reproduced (#669 review cycle 1):
#
#   * `some_other_block:` / `status: deprecated` — bash fired memory-stale on a
#     file python considered clean.
#   * `nested:` / `deeper:` / `stale_after: …` — same, at arbitrary depth.
#   * a nested `type:` appearing BEFORE the real top-level one — bash returned
#     the nested value, so a document legitimately declaring `type: feedback`
#     was reported okf-missing-type and never got its body-requirement check.
#
# That is a live production path (PATTERNS_FORCE_BASH, and any host without
# python3.11+), not just a parity-gate concern: a producer's own structured data
# under an unrelated key would silently mis-scan.
#
# Tracks the current top-level parent the way the python twin tracks `prefix`,
# and matches an indented line only while that parent is `metadata`.
fm_get() {
    command awk -v want="$2" '
        NR == 1 && $0 != "---" { exit }
        NR == 1 { next }
        $0 == "---" { exit }
        {
            raw = $0
            line = raw
            sub(/^[ \t]+/, "", line)
            if (line == "" || substr(line, 1, 1) == "#") next
            # Indented iff the raw line began with whitespace.
            indented = (raw ~ /^[ \t]/)
            p = index(line, ":")
            if (p == 0) next
            k = substr(line, 1, p - 1)
            v = substr(line, p + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", k)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            gsub(/^["'"'"']|["'"'"']$/, "", v)
            if (!indented) {
                # A top-level key with no value OPENS a block; one with a value
                # closes any open block, mirroring the python twin, where
                # `prefix` is set only for a valueless top-level key.
                parent = (v == "") ? k : ""
                if (k == want && v != "") { print v; exit }
                next
            }
            # Indented: visible only while the open block is `metadata:`. Depth
            # is NOT limited — `parent` survives until the next top-level line,
            # so a key two levels down still resolves, matching the python twin.
            if (parent == "metadata" && k == want && v != "") { print v; exit }
        }
    ' "$1"
}

# okf_today — the date staleness is judged against. INJECTED via $OKF_TODAY so a
# fixture cannot rot into a false pass (#669 AC); production falls back to the
# real date.
okf_today() {
    local env_val="${OKF_TODAY:-}"
    env_val="${env_val#"${env_val%%[![:space:]]*}"}"
    env_val="${env_val%"${env_val##*[![:space:]]}"}"
    if [ -n "$env_val" ]; then
        command printf '%s' "$env_val"
    else
        command date +%Y-%m-%d
    fi
}

# scan_bundle ROOT — the whole-bundle pass.
#
# THE ROOT LEVEL ONLY, not a recursive walk — the same deliberate scope limit
# the python twin documents: OKF §8 gives each directory its own index.md, so
# judging a concept in sub/ against the ROOT index would report an orphan for
# every correctly-nested file.
scan_bundle() {
    local root="$1" f base names now
    [ -n "$root" ] || return 0
    [ -d "$root" ] || return 0
    names="$(read_index_names)"
    now="$(okf_today)"

    # Partition the bundle root into indexes and concepts. A reserved non-index
    # file (log.md) is NEITHER: §9 makes it a changelog, and calling it an
    # orphan would fire on every conformant bundle in existence.
    local indexes="" concepts=""
    for f in "$root"/*.md; do
        [ -f "$f" ] || continue
        base="${f##*/}"
        if is_index "$base" "$names"; then
            indexes="${indexes}${base}
"
        else
            case "$base" in
                index.md | log.md) continue ;;
            esac
            concepts="${concepts}${base}
"
        fi
    done

    # named = "<target>\t<index>\t<line>" rows. bash-3.2 has no associative
    # arrays (tests/lint-shell-portability.sh bans `declare -A`), so the graph is
    # accumulated as newline-delimited text and queried with grep/case — the
    # idiom the portability gate documents.
    local named="" idx targets target line_no seen_here
    while IFS= read -r idx; do
        [ -n "$idx" ] || continue
        seen_here=""
        targets="$(index_targets "$root/$idx")"
        while IFS="$TAB" read -r target line_no; do
            [ -n "$target" ] || continue
            # One index naming a concept twice is a duplicate LINE, not a
            # multi-index — that category is about two DIFFERENT indexes.
            case "$seen_here" in
                *"|$target|"*) continue ;;
            esac
            seen_here="${seen_here}|$target|"
            named="${named}${target}${TAB}${idx}${TAB}${line_no}
"
        done <<EOF
$targets
EOF
    done <<EOF
$indexes
EOF

    # Dangling + multi-index, walking each distinct target once in first-seen
    # order (the python twin sorts; both emit one row per target).
    local seen_targets="" sites n first_idx first_line where
    while IFS="$TAB" read -r target idx line_no; do
        [ -n "$target" ] || continue
        case "$seen_targets" in
            *"|$target|"*) continue ;;
        esac
        seen_targets="${seen_targets}|$target|"
        # An index pointing at another INDEX is ordinary structure (a root index
        # naming its sub-indexes), so it is neither dangling nor multi-indexed.
        case "
$indexes" in
            *"
$target
"*) continue ;;
        esac
        sites="$(command printf '%s' "$named" | command awk -F"$TAB" -v t="$target" '$1 == t { print $2 "\t" $3 }')"
        first_idx="$(command printf '%s\n' "$sites" | command head -1 | command cut -f1)"
        first_line="$(command printf '%s\n' "$sites" | command head -1 | command cut -f2)"
        case "
$concepts" in
            *"
$target
"*) ;;
            *)
                emit "$root/$first_idx" "$first_line" "$C_DANGLING_INDEX" \
                    "$L_DANGLING: $target" "HIGH"
                continue
                ;;
        esac
        n="$(command printf '%s\n' "$sites" | command grep -c .)"
        if [ "$n" -gt 1 ]; then
            where="$(command printf '%s\n' "$sites" | command cut -f1 | command tr '\n' ',' | command sed 's/,$//; s/,/, /g')"
            emit "$root/$target" 1 "$C_MULTI_INDEX" "$L_MULTI: $where" "HIGH"
        fi
    done <<EOF
$named
EOF

    # Orphans. A BUNDLE WITH NO INDEX HAS NO ORPHANS — §11 forbids rejecting a
    # bundle for missing index.md files, so a bundle that does not route through
    # indexes must not have every concept reported. Guarded here rather than by
    # an early return, because the health rules below are per-file and hold
    # whether or not the bundle indexes anything. Mirrors the python twin.
    if [ -n "$indexes" ]; then
        while IFS= read -r base; do
            [ -n "$base" ] || continue
            case "
$named" in
                *"
$base$TAB"*) continue ;;
            esac
            emit "$root/$base" 1 "$C_ORPHAN" "$L_ORPHAN" "HIGH"
        done <<EOF
$concepts
EOF
    fi

    # Health: staleness and per-type body requirements.
    #
    # The config is read ONCE, outside the per-file loop. Reading it inside meant
    # re-parsing thresholds.yml for every concept — 222 redundant parses on this
    # repo's own bundle, for a file that cannot change mid-scan.
    local status stale_after stale_check ftype reqs spec sections sec missing ev
    reqs="$(read_config_list "$_here/thresholds.yml" body_requirements || true)"
    while IFS= read -r base; do
        [ -n "$base" ] || continue
        f="$root/$base"
        status="$(fm_get "$f" status)"
        stale_after="$(fm_get "$f" stale_after)"
        stale_check="$(fm_get "$f" stale_check)"
        if [ "$status" = "deprecated" ]; then
            emit "$f" 1 "$C_STALE" "$L_STALE_DEPRECATED" "MEDIUM"
        elif command printf '%s' "$stale_after" | command grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' &&
            [ "$stale_after" \< "$now" ]; then
            # QUOTE THE MEMORY'S OWN stale_check (#669) — that field names the
            # sentence to re-verify, so it beats "may be out of date".
            ev="$L_STALE_DATE ($stale_after)"
            [ -n "$stale_check" ] && ev="$ev: $stale_check"
            emit "$f" 1 "$C_STALE" "$ev" "MEDIUM"
        fi

        ftype="$(fm_get "$f" type)"
        [ -n "$ftype" ] || continue
        missing=""
        while IFS= read -r spec; do
            [ -n "$spec" ] || continue
            case "$spec" in *'='*) ;; *) continue ;; esac
            sections="${spec#*=}"
            spec="${spec%%=*}"
            spec="${spec#"${spec%%[![:space:]]*}"}"
            spec="${spec%"${spec##*[![:space:]]}"}"
            [ "$spec" = "$ftype" ] || continue
            # Sections are `|`-separated; IFS splitting on | is bash-3.2 clean.
            local old_ifs="$IFS"
            IFS='|'
            for sec in $sections; do
                sec="${sec#"${sec%%[![:space:]]*}"}"
                sec="${sec%"${sec##*[![:space:]]}"}"
                [ -n "$sec" ] || continue
                command grep -qF -- "$sec" "$f" && continue
                if [ -z "$missing" ]; then
                    missing="$sec"
                else
                    missing="$missing, $sec"
                fi
            done
            IFS="$old_ifs"
        done <<EOF
$reqs
EOF
        if [ -n "$missing" ]; then
            emit "$f" 1 "$C_MISSING_WHY" "$L_MISSING_WHY: $missing" "MEDIUM"
        fi
    done <<EOF
$concepts
EOF
}

# --- drive -------------------------------------------------------------------
# The CONCRETE bundle directories seen in the file list, newline-delimited in
# first-seen order. One list may span more than one bundle (a fixture tree, a
# monorepo), so the graph pass runs once per distinct directory.
BUNDLE_DIRS=""
while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "$file" ] || continue

    # Only markdown inside the configured bundle is OKF content. A repo with no
    # bundle (or no configured root) simply produces nothing: "nothing to check"
    # is exit 0, not an error.
    case "$file" in
        *.md) ;;
        *) continue ;;
    esac
    in_bundle "$file" || continue
    seen_dir="$(bundle_dir_of "$file")"
    if [ -n "$seen_dir" ]; then
        case "
$BUNDLE_DIRS" in
            *"
$seen_dir
"*) ;;
            *) BUNDLE_DIRS="${BUNDLE_DIRS}${seen_dir}
" ;;
        esac
    fi

    case "${file##*/}" in
        index.md) scan_index "$file" ;;
        log.md) scan_log "$file" ;;
        *) scan_concept "$file" ;;
    esac
done <"$FILE_LIST"

# Slice B (#669): GATED ON the file list, not DRIVEN by it. Running the pass only
# for bundles the list actually referenced keeps a non-bundle diff silent and
# preserves the empty-list contract; the pass itself reads the bundle from disk,
# because an index that should name a concept is rarely in the same diff as the
# concept.
while IFS= read -r bundle_dir; do
    [ -n "$bundle_dir" ] || continue
    scan_bundle "$bundle_dir"
done <<EOF
$BUNDLE_DIRS
EOF
