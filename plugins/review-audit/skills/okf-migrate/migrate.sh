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
[ -f "$_here/moves.sh" ] ||
    fail "moves.sh not found beside migrate.sh in $_here — no transform can run, and an empty plan would read as a bundle needing no migration"
# shellcheck source=plugins/review-audit/skills/okf-migrate/moves.sh
. "$_here/moves.sh"

# THE VERSION PIN lives in the VALIDATOR's thresholds.yml — the single source
# for the whole toolset. adopt-bundle stamps it into the index.md it writes, so
# a second copy here would let this engine create a bundle the validator then
# reports as drifted. Same rule as ruff's required-version.
VALIDATOR_DIR="$(cd "$_here/.." && pwd)/check-okf-conformance"
# $OKF_MIGRATE_CONFIG_DIR overrides where thresholds.yml is read from. It exists
# for the same reason $OKF_BUNDLE_ROOT does — a tool that runs against SOMEONE
# ELSE'S bundle must take its config from somewhere other than its own install
# dir — and it is what lets a fixture exercise a configured taxonomy without
# editing the shipped file (which would dirty the tree and break parallel runs).
CONFIG="${OKF_MIGRATE_CONFIG_DIR:-$_here}/thresholds.yml"

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
read_config_list taxonomy rules >"$WORK/taxonomy"
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
    # DIRECTORIES ONLY, matching the python twin's `dirnames[:] = [...]`, which
    # prunes dot-prefixed DIRECTORIES and says nothing about files. A `.*` arm
    # here would also drop a dot-prefixed FILE directly under the root, and the
    # two runtimes then disagree about it: measured, `.hidden.md` was a concept
    # in python (reported as an ambiguity) and invisible in bash. Parity is the
    # contract, and python's reading is the reference — a leading-dot FILE is
    # still a file someone put in the bundle.
    #
    # `*/.*/*` alone is not enough either: it misses a dot-directory whose file
    # sits directly inside it at the FIRST level (`.attic/x.md` has no leading
    # `*/`), which is the common shape. Both arms are needed.
    case "${_p#"$ROOT"/}" in
        .*/* | */.*/*) continue ;;
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
if list_contains "move-concept" "$WORK/applicable"; then
    # The link rewrites are derived from the SAME mapping the moves are, so the
    # two cannot disagree about where a file lands. Apply ORDERING (rewrites
    # before renames) is the driver's job — see the apply section.
    plan_moves "$ROOT" "$WORK/concepts" "$WORK/every" "$WORK/taxonomy" "$WORK/mapping" >>"$WORK/edits"
    # §8 ORDER: the directory indexes are built FIRST, because they CLAIM the
    # index lines that named the moved concepts. The inbound rewriter then
    # repoints those claimed lines at the sub-index rather than at the concept —
    # naming it in both places would be memory-multi-index.
    plan_directory_indexes "$ROOT" "$WORK/every" "$WORK/mapping" "$WORK/claimed" >>"$WORK/edits"
    rewrite_inbound_links "$ROOT" "$WORK/every" "$WORK/mapping" "$WORK/claimed" >>"$WORK/edits"
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
# field N FILE — column N of the padded edit records, colon stripped.
#
# DELIBERATELY DOES NOT DECODE escapes: the value it returns is used as a MATCH
# KEY against the records themselves (`grep "\t:$key\t"`), so it must stay in
# the same encoding the record holds. Decoding here would make a path carrying
# an escaped tab un-matchable against its own rows — the file would be listed
# and then silently skipped. Decode with `unpad` at the point of USE (display,
# or opening the file), never here.
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
        # NOT -F here: `^` must stay an anchor. The key is a transform NAME
        # (a fixed kebab token this file defines), never a path, so it carries
        # no regex metacharacter and no escaped tab.
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
        _shown="$(unpad "$cur")"
        command printf -- '--- a/%s\n+++ b/%s\n' "$_shown" "$_shown"
        # `grep -F`: the key is an ENCODED path and may hold a literal `\t`,
        # which basic grep would read as a regex escape and fail to match — the
        # file would render a header with no hunks under it. Fixed, not worked
        # around: every match on an encoded field is fixed-string.
        command grep -F "	:$cur	" "$WORK/edits" | command sort -t"$(command printf '\t')" -k4,4 |
            while IFS="$(command printf '\t')" read -r t p k l o n note; do
                t="$(unpad "$t")"
                k="$(unpad "$k")"
                o="$(unpad "$o")"
                n="$(unpad "$n")"
                note="$(unpad "$note")"
                : "$p" "$l"
                command printf -- '@@ %s: %s @@\n' "$t" "$note"
                if [ "$k" = "move" ]; then
                    # RENDERED AS A RENAME HEADER, not a +/- pair. A move changes
                    # no bytes, so showing it as content would misrepresent what
                    # apply does — and the destination is the single fact a
                    # reviewer is approving here.
                    command printf 'rename from %s\nrename to %s\n' "$o" "$n"
                    continue
                fi
                if [ "$k" = "create" ]; then
                    command printf '%s\n' "$n" | command sed -e 's/\\n/\
/g' | while IFS= read -r bl || [ -n "$bl" ]; do
                        command printf '+%s\n' "$bl"
                    done
                    continue
                fi
                [ -z "$o" ] || command printf -- '-%s\n' "$o"
                # A `\n`-escaped multi-line payload renders as SEVERAL `+`
                # lines: the plan is the reviewable artifact AND the write
                # allowlist, so it must show the lines actually written.
                command printf '%s\n' "$n" | command sed -e 's/\\n/\
/g' | while IFS= read -r _pl || [ -n "$_pl" ]; do
                    command printf '+%s\n' "$_pl"
                done
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
# MOVE RECORDS ARE SPLIT OUT AND RUN LAST. A link rewrite reads the file at its
# OLD path, so renaming first would leave those edits pointed at a path that no
# longer exists — they would silently no-op and every inbound link would be left
# dangling, which is the exact failure move-concept exists to prevent.
command grep -F '	:move	' "$WORK/edits" >"$WORK/moves" 2>/dev/null || :
command grep -vF '	:move	' "$WORK/edits" >"$WORK/edits.lines" 2>/dev/null || :
field 2 "$WORK/edits.lines" | command sort -u >"$WORK/targets"
ROOT_REAL="$(cd "$ROOT" && command pwd -P)"

# PRE-FLIGHT: every MOVE destination is checked before ANY edit is written.
#
# "Partial application is not a thing" (contract.md) is a claim about the WHOLE
# apply, and a check that runs when its own edit's turn comes cannot make it.
# move-concept forced this: renames run LAST (a link rewrite must read the file
# at its old path), so a destination check inside the rename loop fired only
# after every link rewrite was already on disk. Measured: a taxonomy rule spelled
# `= ../../../escaped` exited 2 with the right message and left the bundle's
# links rewritten to point outside it — a refusal that had already done most of
# the damage.
#
# The DESTINATION is the new surface a move introduces; every other transform
# only writes a path that already existed in the bundle. Resolved through its
# nearest EXISTING ancestor, since the directory need not exist yet.
if [ -s "$WORK/moves" ]; then
    while IFS="$(command printf '\t')" read -r _t _p _k _l _o _n _note || [ -n "$_t" ]; do
        [ -n "$_t" ] || continue
        _n="$(unpad "$_n")"
        _ndir="$ROOT/${_n%/*}"
        [ "${_n%/*}" != "$_n" ] || _ndir="$ROOT"
        _probe="$_ndir"
        while [ "$_probe" != "/" ] && [ ! -d "$_probe" ]; do
            _probe="${_probe%/*}"
            [ -n "$_probe" ] || _probe="/"
        done
        _preal="$(cd "$_probe" 2>/dev/null && command pwd -P)" || _preal=""
        case "$_preal" in
            "$ROOT_REAL" | "$ROOT_REAL"/*) ;;
            *)
                command printf 'ERROR: apply refused: %s resolves outside the bundle root %s — refusing to move through it\n' \
                    "$_n" "$ROOT" >&2
                exit 2
                ;;
        esac
    done <"$WORK/moves"
fi
while IFS= read -r target_enc || [ -n "$target_enc" ]; do
    [ -n "$target_enc" ] || continue
    # The ENCODED form matches the records; the DECODED form is the real path.
    target="$(unpad "$target_enc")"

    # THE RESOLVED-ROOT CHECK — the half of the allowlist that can actually
    # fail. The target list is derived from the edits themselves, so comparing
    # against it is a tautology; resolving the path and requiring it under the
    # bundle root enforces a claim no caller can launder. `cd … && pwd -P`
    # rather than `realpath -m`, which is GNU-only and whose usual `|| echo`
    # fallback returns the path UNRESOLVED — defeating exactly this guard
    # (#932, and issue #21's surface).
    # FAILS CLOSED when the parent cannot be resolved, but resolves through the
    # nearest EXISTING ancestor first. The original spelling resolved only a
    # parent that already existed, and its own comment predicted what broke it:
    # "one new transform away from being no guard at all". move-concept (#934)
    # was that transform — it creates `<root>/<dir>/index.md` for a directory
    # that does not exist yet, so the parent was unresolvable and a legitimate
    # in-bundle create was REFUSED. Walking up to the nearest existing ancestor
    # keeps the guard fail-closed (an escaping path still resolves outside the
    # root) while letting a new subdirectory through.
    _tdir="${target%/*}"
    [ "$_tdir" != "$target" ] || _tdir="."
    _probe_t="$_tdir"
    while [ "$_probe_t" != "/" ] && [ ! -d "$_probe_t" ]; do
        _probe_t="${_probe_t%/*}"
        [ -n "$_probe_t" ] || _probe_t="/"
    done
    _treal=""
    if [ -d "$_probe_t" ]; then
        _preal_t="$(cd "$_probe_t" && command pwd -P)"
        # The unresolved remainder is appended verbatim: it contains no symlink
        # to follow (none of it exists), and any `..` in it was already
        # normalized away by the transform that produced the path.
        _treal="$_preal_t${_tdir#"$_probe_t"}/${target##*/}"
    fi
    case "$_treal" in
        "$ROOT_REAL"/*) ;;
        *)
            command printf 'ERROR: apply refused: %s resolves outside the bundle root %s — refusing to write through it\n' \
                "$target" "$ROOT" >&2
            exit 2
            ;;
    esac

    command grep -F "	:$target_enc	" "$WORK/edits.lines" >"$WORK/group" || continue

    command grep -F '	:create	' "$WORK/group" >"$WORK/creates" 2>/dev/null || :
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
                # THE END BLOCK IS AN APPEND, and without it an insert at
                # len+1 matched NO record and was silently dropped while the
                # python twin's list.insert clamped and wrote it. move-concept
                # appends to an existing directory index, so the line that makes
                # a moved concept recallable was the one going missing (#934).
                #
                # A payload carrying `\n` expands to SEVERAL lines. move-concept
                # appends a whole ordered block as ONE edit (N separate appends
                # interleave, because edits apply highest-line-first against a
                # growing buffer), and the block travels through the
                # line-oriented record in the same `\n`-escaped form a `create`
                # body uses. awk's ENVIRON is not escape-processed, so the
                # expansion is done here rather than relying on the shell.
                OKF_NEW="$n" command awk \
                    'function emit(  k, parts, i) {
                         k = split(ENVIRON["OKF_NEW"], parts, /\\n/)
                         for (i = 1; i <= k; i++) print parts[i]
                     }
                     NR==ln{emit()}{print}
                     END{if (ln > NR) emit()}' \
                    ln="$l" "$WORK/buf" >"$WORK/buf.new"
                ;;
            *) command cp "$WORK/buf" "$WORK/buf.new" ;;
        esac
        command mv "$WORK/buf.new" "$WORK/buf"
    done <"$WORK/group.sorted"
    command cp "$WORK/buf" "$target"
done <"$WORK/targets"

# --- renames, after every line edit ------------------------------------------
#
# `git mv` RATHER THAN delete+create (AC7): the history is the reason a memory
# can be trusted, and `git log --follow` on a relocated concept must still reach
# the commit that explains why it was written. A delete+create severs that at
# exactly the moment the file becomes hardest to place.
#
# A NON-REPO FALLS BACK TO `mv`, the same line the dirty-tree gate draws: this
# tool migrates any repo's bundle including a plain directory under no version
# control, and refusing there would turn a history guarantee into a portability
# bug. A `git mv` failing for any other reason falls back too — the move is the
# contract, the history is the bonus.
if [ -s "$WORK/moves" ]; then
    command sort -t"$(command printf '\t')" -k5,5 "$WORK/moves" >"$WORK/moves.sorted"
    while IFS="$(command printf '\t')" read -r t p k l o n note || [ -n "$t" ]; do
        [ -n "$t" ] || continue
        o="$(unpad "$o")"
        n="$(unpad "$n")"
        : "$p" "$k" "$l" "$note"
        [ -e "$ROOT/$o" ] || continue

        _ndir="$ROOT/${n%/*}"
        [ "${n%/*}" != "$n" ] || _ndir="$ROOT"
        command mkdir -p "$_ndir"
        if ! (cd "$ROOT" && command git mv -- "$o" "$n" >/dev/null 2>&1); then
            command mv "$ROOT/$o" "$ROOT/$n"
        fi
    done <"$WORK/moves.sorted"
fi

exit 0
