#!/usr/bin/env bash
# okf-migrate — the OKF migration engine (slice D, #671).
#
# Slices A-C REPORT. This one changes things. A checker that only reports pushes
# the whole adoption cost onto every consuming repo, one hand-edit at a time —
# the failure #663 names, where detection without a mechanized recommendation
# gets ignored. This is the adoption path.
#
# THREE MODES:
#   check   report what would need migrating. Read-only. THE DEFAULT.
#   plan    render the full change set as a reviewable diff. Read-only.
#   apply   execute a plan. Explicit subcommand + --confirm. Never the default.
#
# TWO KINDS OF FAILURE, KEPT STRICTLY APART — the same split slice A draws, and
# for the same reason (#664 says conflating them is how this lands wrong):
#
#   * THE BUNDLE is never rejected. A non-conformant bundle is exactly what this
#     tool exists to fix, so every migration finding is reported at EXIT 0.
#   * THE TOOL fails loud. A usage error, an unresolvable version pin, a dirty
#     tree under `apply`, or an ambiguity needing a human exits NON-ZERO with an
#     actionable message (#538/#571).
#
# Exit codes:
#   0 = success (including "this bundle needs migrating")
#   1 = usage error, unresolvable version pin, or an unreadable bundle
#   2 = apply refused (dirty tree, missing --confirm, or a plan-only transform)
#   3 = apply blocked on an ambiguity that requires a human choice
#
# Runtime: Python 3.11+ primary (migrate.py) with this bash script as the
# portable fallback. The shim below exec's migrate.py when a python3>=3.11 is
# present (identical output contract); PATTERNS_FORCE_BASH=1 forces this body.
#
# bash-3.2 clean and BSD-regex safe: no declare -A / mapfile / namerefs /
# ${v,,} / ;;&, and no \s \w \b or grep -P — macOS ships bash 3.2 and BSD
# grep/sed, which read those as LITERALS and would silently match nothing.
# See CLAUDE.md § Runtime policy.
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/migrate.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/migrate.py" "$@"
fi

# fail MESSAGE [CODE] — actionable TOOL-side error, non-zero.
fail() {
    command printf 'ERROR: %s\n' "$1" >&2
    exit "${2:-1}"
}

usage() {
    command cat >&2 <<'USAGE'
Usage: migrate.sh [check|plan|apply] [--transform NAME] [--confirm]
                  [--allow-dirty]

  check   report what needs migrating (default, read-only)
  plan    render the change set for review (read-only)
  apply   execute the plan (requires --confirm)
USAGE
}

# The transform bodies travel with this file exactly as bundle_graph.py travels
# with patterns.py. An explicit check with a NAMED failure, not a bare `source`:
# under `set -e` a missing file aborts too, but with a raw bash diagnostic that
# says nothing about what is broken or why the run produced no plan.
[ -f "$_here/transforms.sh" ] ||
    fail "transforms.sh not found beside migrate.sh in $_here — no transform can run, and an empty plan would read as a bundle needing no migration"
# shellcheck source=plugins/review-audit/skills/okf-migrate/transforms.sh
. "$_here/transforms.sh"

# THE VERSION PIN lives in the VALIDATOR's thresholds.yml — the single source
# for the whole toolset. adopt-bundle stamps it into the index.md it writes, so
# a second copy here would let this engine create a bundle the validator then
# reports as drifted. Same rule as ruff's required-version.
VALIDATOR_DIR="$(cd "$_here/.." && pwd)/check-okf-conformance"
CONFIG="$_here/thresholds.yml"

# --- bundle discovery --------------------------------------------------------
#
# Resolution order and normalization are IDENTICAL to the validator's
# bundle_root() — the two tools must agree about which files are bundle files,
# or this engine migrates one set and the validator grades another.
bundle_root() {
    local root
    if [ -n "${OKF_BUNDLE_ROOT+x}" ]; then
        root="$OKF_BUNDLE_ROOT"
    else
        root="${MEMORY_BUNDLE_ROOT-.claude/memory}"
    fi
    root="${root#"${root%%[![:space:]]*}"}"
    root="${root%"${root##*[![:space:]]}"}"
    while :; do
        case "$root" in ./*) root="${root#./}" ;; *) break ;; esac
    done
    while :; do
        case "$root" in */) root="${root%/}" ;; *) break ;; esac
    done
    command printf '%s' "$root"
}

# read_pinned_version — $OKF_PINNED_VERSION, else `okf.pinned_version` from the
# VALIDATOR's thresholds.yml. A pure-bash parse rather than sed: BSD and GNU sed
# differ, and this shape is fixed.
read_pinned_version() {
    local file="$VALIDATOR_DIR/thresholds.yml" line stripped val in_okf=0 first env_val
    env_val="${OKF_PINNED_VERSION:-}"
    env_val="${env_val#"${env_val%%[![:space:]]*}"}"
    env_val="${env_val%"${env_val##*[![:space:]]}"}"
    if [ -n "$env_val" ]; then
        command printf '%s' "$env_val"
        return 0
    fi
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        [ -n "$stripped" ] || continue
        case "$stripped" in '#'*) continue ;; esac
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
        case "$stripped" in pinned_version:*) ;; *) continue ;; esac
        val="${stripped#pinned_version:}"
        case "$val" in *'#'*) val="${val%%#*}" ;; esac
        strip_quotes "$val"
        return 0
    done <"$file"
}

# read_config_list SECTION KEY — the `- item` list under <section>.<key>.
# The same tiny two-level parse the validator uses, for the same reason: a full
# YAML parser is a much larger surface for the two runtimes to disagree across.
read_config_list() {
    local section="$1" key="$2" line stripped first in_section=0 in_key=0 item
    [ -f "$CONFIG" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        [ -n "$stripped" ] || continue
        case "$stripped" in '#'*) continue ;; esac
        first="${line%"${line#?}"}"
        case "$first" in
            ' ' | "$(command printf '\t')") ;;
            *)
                case "$stripped" in
                    "$section":*) in_section=1 ;;
                    *) in_section=0 ;;
                esac
                in_key=0
                continue
                ;;
        esac
        [ "$in_section" -eq 1 ] || continue
        case "$stripped" in
            '- '*)
                if [ "$in_key" -eq 1 ]; then
                    item="${stripped#- }"
                    case "$item" in *' #'*) item="${item%% #*}" ;; esac
                    strip_quotes "$item"
                    command printf '\n'
                fi
                continue
                ;;
        esac
        case "$stripped" in
            "$key":*) in_key=1 ;;
            *) in_key=0 ;;
        esac
    done <"$CONFIG"
}

# read_config_scalar SECTION KEY DEFAULT
read_config_scalar() {
    local section="$1" key="$2" default="$3" line stripped first in_section=0 val
    [ -f "$CONFIG" ] || {
        command printf '%s' "$default"
        return 0
    }
    while IFS= read -r line || [ -n "$line" ]; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        [ -n "$stripped" ] || continue
        case "$stripped" in '#'*) continue ;; esac
        first="${line%"${line#?}"}"
        case "$first" in
            ' ' | "$(command printf '\t')") ;;
            *)
                case "$stripped" in
                    "$section":*) in_section=1 ;;
                    *) in_section=0 ;;
                esac
                continue
                ;;
        esac
        [ "$in_section" -eq 1 ] || continue
        case "$stripped" in "$key":*) ;; *) continue ;; esac
        val="${stripped#"$key":}"
        case "$val" in *'#'*) val="${val%%#*}" ;; esac
        val="$(strip_quotes "$val")"
        if [ -n "$val" ]; then
            command printf '%s' "$val"
        else
            command printf '%s' "$default"
        fi
        return 0
    done <"$CONFIG"
    command printf '%s' "$default"
}

# list_contains NEEDLE FILE
list_contains() {
    local needle="$1" file="$2" line
    while IFS= read -r line || [ -n "$line" ]; do
        [ "$line" = "$needle" ] && return 0
    done <"$file"
    return 1
}

# --- argument parsing --------------------------------------------------------
MODE="check"
TRANSFORM=""
CONFIRM=0
ALLOW_DIRTY=0

if [ "$#" -gt 0 ]; then
    case "$1" in
        -*) ;;
        check | plan | apply)
            MODE="$1"
            shift
            ;;
        *)
            command printf 'ERROR: unknown mode: %s\n' "$1" >&2
            usage
            exit 1
            ;;
    esac
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --transform)
            shift
            [ "$#" -gt 0 ] || fail "--transform requires a value"
            TRANSFORM="$1"
            ;;
        --confirm) CONFIRM=1 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            command printf 'ERROR: unknown argument: %s\n' "$1" >&2
            usage
            exit 1
            ;;
    esac
    shift
done

ROOT="$(bundle_root)"
# No bundle configured, or none on disk: "nothing to migrate" is exit 0, the
# same posture the validator takes.
[ -n "$ROOT" ] || exit 0
[ -d "$ROOT" ] || exit 0

VERSION="$(read_pinned_version)"
[ -n "$VERSION" ] || fail "no OKF version pin — set OKF_PINNED_VERSION or provide \`okf.pinned_version\` in check-okf-conformance/thresholds.yml. adopt-bundle stamps that version into the index.md it writes, so without it this engine would create a bundle it cannot declare."

WORK="$(command mktemp -d)"
trap 'command rm -rf "$WORK"' EXIT

read_config_list transforms applicable >"$WORK/applicable"
read_config_list transforms plan_only >"$WORK/plan_only"
read_config_list type_inference rules >"$WORK/rules"
read_config_list type_inference known_types >"$WORK/known"
LINK_FORM="$(read_config_scalar links form bundle_relative)"
CONVERT_UNRESOLVED="$(read_config_scalar links convert_unresolvable true)"
ADOPT_TITLE="$(read_config_scalar adopt title 'Memory Bundle')"

if [ -n "$TRANSFORM" ] && [ "$MODE" = "apply" ] && list_contains "$TRANSFORM" "$WORK/plan_only"; then
    fail "apply refused: '$TRANSFORM' is plan-only — it executes a decision this engine did not make. Review its plan output and apply the chosen change yourself." 2
fi

# --- collect the bundle ------------------------------------------------------
# A concept is any `.md` that is not a reserved OKF filename (§3.1). Non-markdown
# files inside a bundle are code or data, not concepts — the same exclusion the
# validator applies.
# `-type f` already excludes a SYMLINK (its own type is `l`), which is the
# safety boundary the python twin had to add explicitly: a `.md` symlink inside
# the bundle would otherwise be written through on apply, landing outside the
# bundle root while the plan displayed the in-bundle path. Measured on the
# python side before fixing; this impl was already correct, and the two now
# agree — that agreement is the parity contract, so do not "simplify" this to
# `-type f -o -type l`.
#
# DOT-DIRECTORIES are pruned BELOW the root, which the python twin does with
# `dirnames[:] = [...]`. Without it a `.attic/` of scratch markdown under the
# bundle root was part of the bundle here and not there — the same file set
# disagreeing across runtimes.
#
# THE FILTER IS RELATIVE TO THE ROOT, and that is the whole difficulty: the root
# is itself normally dot-bearing (`.claude/memory`), so a find predicate over the
# ABSOLUTE path — `-not -path '*/.*/*'` — matches the root's own `.claude`
# segment and excludes the ENTIRE bundle. Measured: with a `mktemp` root it
# returned zero files and every transform silently found nothing to do, which
# reads exactly like a clean bundle. Strip the root prefix first, then judge only
# what lies beneath it.
command find "$ROOT" -type f -name '*.md' | command sort >"$WORK/every.all"
: >"$WORK/every"
while IFS= read -r _p || [ -n "$_p" ]; do
    [ -n "$_p" ] || continue
    case "${_p#"$ROOT"/}" in
        .* | */.*) continue ;;
    esac
    command printf '%s\n' "$_p" >>"$WORK/every"
done <"$WORK/every.all"
: >"$WORK/concepts"
while IFS= read -r _p || [ -n "$_p" ]; do
    case "${_p##*/}" in
        index.md | log.md) continue ;;
    esac
    command printf '%s\n' "$_p" >>"$WORK/concepts"
done <"$WORK/every"

# --- build the plan ----------------------------------------------------------
: >"$WORK/edits"
: >"$WORK/ambiguities"

if list_contains "adopt-bundle" "$WORK/applicable"; then
    adopt_bundle "$ROOT" "$VERSION" "$ADOPT_TITLE" "$WORK/concepts" >>"$WORK/edits"
fi
if list_contains "backfill-type" "$WORK/applicable"; then
    backfill_type "$ROOT" "$WORK/concepts" "$WORK/rules" "$WORK/ambiguities" >>"$WORK/edits"
fi
if list_contains "wikilink-convert" "$WORK/applicable"; then
    convert_wikilinks "$ROOT" "$WORK/every" "$LINK_FORM" "$CONVERT_UNRESOLVED" >>"$WORK/edits"
fi

if [ -n "$TRANSFORM" ]; then
    # `:` is emit_edit's field padding — see its comment. Anchoring on it keeps
    # the match on the transform FIELD rather than anywhere in the record.
    command grep "^:$TRANSFORM	" "$WORK/edits" >"$WORK/edits.f" 2>/dev/null || :
    command mv "$WORK/edits.f" "$WORK/edits"
    if [ "$TRANSFORM" != "backfill-type" ]; then
        : >"$WORK/ambiguities"
    fi
fi

# field N FILE — column N of the padded edit records, colon stripped.
field() {
    command cut -f"$1" "$2" | command sed -e 's/^://'
}

KNOWN="$(command tr '\n' ',' <"$WORK/known" | command sed -e 's/,$//' -e 's/,/, /g')"
[ -n "$KNOWN" ] || KNOWN="(none)"

# --- render ------------------------------------------------------------------

render_check() {
    local t count files
    command cut -f1,2 "$WORK/edits" | command sort -u >"$WORK/tf"
    field 1 "$WORK/edits" | command sort -u >"$WORK/tnames"
    while IFS= read -r t || [ -n "$t" ]; do
        [ -n "$t" ] || continue
        count="$(command grep -c "^:$t	" "$WORK/edits" || :)"
        files="$(command grep -c "^:$t	" "$WORK/tf" || :)"
        command printf '%-18s %4d file(s)  %4d edit(s)  [applicable]\n' "$t" "$files" "$count"
    done <"$WORK/tnames"
    # PLAN-ONLY TRANSFORMS are surfaced as notes rather than silently omitted.
    # Silence would read as "nothing to migrate" — the silence-is-a-pass shape.
    while IFS= read -r t || [ -n "$t" ]; do
        [ -n "$t" ] || continue
        command printf '%s: plan-only — requires a human decision this engine did not make\n' "$t"
    done <"$WORK/plan_only"
    while IFS="$(command printf '\t')" read -r p reason || [ -n "$p" ]; do
        [ -n "$p" ] || continue
        command printf 'AMBIGUOUS  %s  %s  candidates: %s\n' "$p" "$reason" "$KNOWN"
    done <"$WORK/ambiguities"
    if [ ! -s "$WORK/edits" ] && [ ! -s "$WORK/ambiguities" ]; then
        command printf 'bundle needs no mechanized migration\n'
    fi
}

render_plan() {
    local t p k l o n note cur=""
    field 2 "$WORK/edits" | command sort -u >"$WORK/files"
    while IFS= read -r cur || [ -n "$cur" ]; do
        [ -n "$cur" ] || continue
        command printf -- '--- a/%s\n+++ b/%s\n' "$cur" "$cur"
        command grep "	:$cur	" "$WORK/edits" | command sort -t"$(command printf '\t')" -k4,4 |
            while IFS="$(command printf '\t')" read -r t p k l o n note; do
                t="$(unpad "$t")"
                k="$(unpad "$k")"
                o="$(unpad "$o")"
                n="$(unpad "$n")"
                note="$(unpad "$note")"
                : "$p" "$l"
                command printf -- '@@ %s: %s @@\n' "$t" "$note"
                if [ "$k" = "create" ]; then
                    command printf '%s\n' "$n" | command sed -e 's/\\n/\
/g' | while IFS= read -r bl || [ -n "$bl" ]; do
                        command printf '+%s\n' "$bl"
                    done
                    continue
                fi
                [ -z "$o" ] || command printf -- '-%s\n' "$o"
                command printf '+%s\n' "$n"
            done
    done <"$WORK/files"
    while IFS= read -r t || [ -n "$t" ]; do
        [ -n "$t" ] || continue
        command printf '# %s: plan-only — requires a human decision this engine did not make\n' "$t"
    done <"$WORK/plan_only"
    while IFS="$(command printf '\t')" read -r p reason || [ -n "$p" ]; do
        [ -n "$p" ] || continue
        command printf '# AMBIGUOUS %s: %s — choose one of: %s\n' "$p" "$reason" "$KNOWN"
    done <"$WORK/ambiguities"
}

case "$MODE" in
    check)
        render_check
        exit 0
        ;;
    plan)
        render_plan
        exit 0
        ;;
esac

# --- apply -------------------------------------------------------------------
[ "$CONFIRM" -eq 1 ] ||
    fail "apply requires --confirm. Run \`plan\` first and review the diff; apply writes only what that plan listed." 2

if [ -s "$WORK/ambiguities" ]; then
    _n="$(command wc -l <"$WORK/ambiguities" | command tr -d ' ')"
    command printf 'ERROR: apply blocked: %s file(s) need a human choice. Nothing was written.\n' "$_n" >&2
    while IFS="$(command printf '\t')" read -r p reason || [ -n "$p" ]; do
        [ -n "$p" ] || continue
        command printf '  %s: %s — candidates: %s\n' "$p" "$reason" "$KNOWN" >&2
    done <"$WORK/ambiguities"
    exit 3
fi

# A NON-REPO IS NOT DIRTY. This tool migrates any repo's bundle, including a
# plain directory not under version control, and refusing there would make the
# safety gate a portability bug. The gate exists so an applied change is
# reviewable as its own diff; where there is no git there is no diff to muddy.
#
# `-C "$ROOT"` IS LOAD-BEARING: git runs inside the BUNDLE's directory, not the
# caller's. Without it the status is taken in whatever repo the process happens
# to sit in, so a bundle elsewhere is checked against the WRONG tree — and when
# that path lies outside the current repo, git errors, the error reads as "not a
# repo", and the gate silently passes a genuinely dirty bundle. Measured: the
# gate reported clean for a dirty fixture whenever the caller's cwd was a
# different repository — the normal case for a tool built to run against someone
# else's bundle.
if [ "$ALLOW_DIRTY" -eq 0 ] && command -v git >/dev/null 2>&1; then
    _status=""
    _status="$(command git -C "$ROOT" status --porcelain -- . 2>/dev/null)" || _status=""
    if [ -n "$_status" ]; then
        command printf 'ERROR: apply refused: the bundle has uncommitted changes. Commit or stash them so the migration is reviewable as its own diff, or pass --allow-dirty.\n' >&2
        command printf '%s\n' "$_status" >&2
        exit 2
    fi
fi

[ -s "$WORK/edits" ] || exit 0

# Edits are applied per file, HIGHEST LINE FIRST, so an insert cannot shift the
# line numbers of edits not yet applied.
#
# THE ALLOWLIST IS THE PLAN (AC7) — the edit list built above is the only source
# of paths, so a file that was not planned cannot be written by construction.
field 2 "$WORK/edits" | command sort -u >"$WORK/targets"
ROOT_REAL="$(cd "$ROOT" && command pwd -P)"
while IFS= read -r target || [ -n "$target" ]; do
    [ -n "$target" ] || continue

    # THE RESOLVED-ROOT CHECK — the half of the allowlist that can actually
    # fail. The target list is derived from the edits themselves, so comparing
    # against it is a tautology; resolving the path and requiring it under the
    # bundle root enforces a claim no caller can launder. `cd … && pwd -P`
    # rather than `realpath -m`, which is GNU-only and whose usual `|| echo`
    # fallback returns the path UNRESOLVED — defeating exactly this guard
    # (#932, and issue #21's surface).
    _tdir="${target%/*}"
    [ "$_tdir" != "$target" ] || _tdir="."
    if [ -d "$_tdir" ]; then
        _treal="$(cd "$_tdir" && command pwd -P)/${target##*/}"
        case "$_treal" in
            "$ROOT_REAL"/*) ;;
            *)
                command printf 'ERROR: apply refused: %s resolves outside the bundle root %s — refusing to write through it\n' \
                    "$target" "$ROOT" >&2
                exit 2
                ;;
        esac
    fi

    command grep "	:$target	" "$WORK/edits" >"$WORK/group" || continue

    command grep '	:create	' "$WORK/group" >"$WORK/creates" 2>/dev/null || :
    if [ -s "$WORK/creates" ]; then
        _dir="${target%/*}"
        [ "$_dir" = "$target" ] || command mkdir -p "$_dir"
        # ONE DECODER for every field: unpad handles the `\n` a create body
        # carries AND the `\t`/`\\` esc_field adds. The old `sed 's/\\n/…/'`
        # here was a SECOND decoder over already-escaped bytes, so an escaped
        # backslash survived into the file (`---` was written as `---\`).
        _body="$(command cut -f6 "$WORK/creates" | command head -n1)"
        unpad "$_body" >"$target"
        command printf '\n' >>"$target"
        continue
    fi

    command cp "$target" "$WORK/buf"
    # LEXICAL reverse sort, not -nr: the line field is colon-prefixed (so not
    # numeric) and zero-padded (so lexical order IS numeric order). See
    # emit_edit in transforms.sh for what a tie costs.
    command sort -t"$(command printf '\t')" -k4,4r "$WORK/group" >"$WORK/group.sorted"
    while IFS="$(command printf '\t')" read -r t p k l o n note || [ -n "$t" ]; do
        [ -n "$t" ] || continue
        k="$(unpad "$k")"
        l="$(unpad "$l")"
        n="$(unpad "$n")"
        : "$p" "$o" "$note"
        # THE LINE CONTENT TRAVELS THROUGH THE ENVIRONMENT, never `awk -v`.
        # POSIX awk processes escape sequences in a `-v` assignment, so a body
        # line legitimately containing the two characters `\t` — ordinary in a
        # repo that documents regexes — is turned into a REAL TAB by awk itself,
        # no matter how faithfully the edit record carried it. Measured:
        # `Regex \t means tab.` was written back as `Regex <TAB> means tab.`,
        # while python left it alone. ENVIRON[] is not escape-processed, so the
        # bytes arrive verbatim. Also covers `\\`, `\n` and friends.
        case "$k" in
            replace-line)
                OKF_NEW="$n" command awk \
                    'NR==ln{print ENVIRON["OKF_NEW"]; next}{print}' \
                    ln="$l" "$WORK/buf" >"$WORK/buf.new"
                ;;
            insert-line)
                OKF_NEW="$n" command awk \
                    'NR==ln{print ENVIRON["OKF_NEW"]}{print}' \
                    ln="$l" "$WORK/buf" >"$WORK/buf.new"
                ;;
            *) command cp "$WORK/buf" "$WORK/buf.new" ;;
        esac
        command mv "$WORK/buf.new" "$WORK/buf"
    done <"$WORK/group.sorted"
    command cp "$WORK/buf" "$target"
done <"$WORK/targets"

exit 0
