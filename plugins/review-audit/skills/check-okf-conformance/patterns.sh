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
    local file="$1" line stripped val in_okf=0 first
    if [ -n "${OKF_PINNED_VERSION:-}" ]; then
        command printf '%s' "$OKF_PINNED_VERSION"
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

# fm_has KEY / fm_value KEY / fm_line KEY — read the parsed block.
fm_has() {
    case "$TAB$FM_KEYS" in
        *"$TAB$1$TAB"*) return 0 ;;
    esac
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

# --- drive -------------------------------------------------------------------
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

    case "${file##*/}" in
        index.md) scan_index "$file" ;;
        log.md) scan_log "$file" ;;
        *) scan_concept "$file" ;;
    esac
done <"$FILE_LIST"
