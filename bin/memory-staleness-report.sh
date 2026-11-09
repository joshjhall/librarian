#!/usr/bin/env bash
# Memory staleness reporter — the TIME-driven half of the OKF bundle check.
#
# WHY THIS EXISTS. `memory-stale` (a memory past its own `stale_after`) is the
# one OKF finding no commit can cause: the file is clean on D-1 and a finding on
# D with no byte changed. Judged by a commit-time gate against the real date, it
# turned tests/validate-okf-bundle.sh red on 2026-10-31 for EVERY branch at once
# — an unrelated dependabot action bump included — and it reached whoever pushed
# next rather than whoever owned the memory. That gate now pins its date (see its
# header), so its verdict is a function of the tree alone. Time-driven staleness
# is reported HERE instead, on a schedule, where time is the trigger:
# .github/workflows/memory-staleness.yml.
#
# IT LOOKS AHEAD. A memory is reported in one of two buckets:
#
#   expired    stale_after <  today               (already due)
#   expiring   today <= stale_after <= today + N  (due within the window)
#
# The boundaries are the SCANNER's, not a second opinion: it judges a memory
# stale when `stale_after < today`, so on the stale_after date itself a memory
# is still `expiring`, and it reads as `expired` from the next day.
#
# so a weekly run names a memory up to N days BEFORE it expires — the refresh
# happens on someone's schedule instead of as a surprise.
#
# ONE COMPARATOR, NOT TWO. Both buckets come from the real scanner
# (check-okf-conformance/patterns.sh) run at two injected dates — today, and
# today + N — and diffed. This script never compares a stale_after itself, so it
# cannot disagree with the scanner about what "stale" means (format checks,
# metadata-nested keys, the symlink guard, deprecated handling all come along).
# `status: deprecated` rows are excluded: that is a property of the FILE, which
# the commit-time gate still enforces.
#
# NO MEMORY CONTENT IN THE OUTPUT. Same rule as validate-okf-bundle.sh: the
# scanner's evidence column quotes the memory's `stale_check` sentence, and a CI
# log / step summary is a wider audience than the bundle. Only the path and the
# stale_after date (parsed back out of the scanner's own fixed label) are
# printed; the stale_check sentence is read where it lives, in the file.
#
# Usage:
#   bin/memory-staleness-report.sh [--window DAYS]     (default 30)
#
# Exit codes:
#   0 = nothing expired or expiring within the window
#   1 = at least one memory expired or expiring (the scheduled run goes red so
#       it is noticed), OR a usage error
#   2 = the scan could not run (scanner absent/failed, bad date) — never a
#       silent "nothing stale"
#
# Env overrides (for tests):
#   OKF_TODAY              the date judged against (default: the real date)
#   OKF_BUNDLE_ROOT        bundle root (default: <repo>/.claude/memory)
#   OKF_BUNDLE_SCANNER     scanner path
#
# bash-3.2 clean and BSD clean per CLAUDE.md § Runtime policy. The day
# arithmetic is pure-bash integer civil-date math, NOT `date -d`/`date -v`: the
# two are each one platform's spelling, and a wrong date here would shift the
# window silently.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCANNER="${OKF_BUNDLE_SCANNER:-$REPO_ROOT/plugins/review-audit/skills/check-okf-conformance/patterns.sh}"
if [ -n "${OKF_BUNDLE_ROOT+set}" ]; then
    BUNDLE_ROOT="$OKF_BUNDLE_ROOT"
else
    BUNDLE_ROOT="$REPO_ROOT/.claude/memory"
fi

WINDOW=30
while [ "$#" -gt 0 ]; do
    case "$1" in
        --window)
            [ "$#" -ge 2 ] || {
                command printf 'memory-staleness-report: --window needs a value\n' >&2
                exit 1
            }
            WINDOW="$2"
            shift 2
            ;;
        *)
            command printf 'memory-staleness-report: unknown argument %s (expected --window DAYS)\n' "$1" >&2
            exit 1
            ;;
    esac
done
case "$WINDOW" in
    '' | *[!0-9]*)
        command printf 'memory-staleness-report: --window must be a non-negative integer, got %s\n' "$WINDOW" >&2
        exit 1
        ;;
esac

fail2() {
    command printf 'memory-staleness-report: %s\n' "$1" >&2
    command printf '  Nothing was checked — do not read this as "no stale memories".\n' >&2
    exit 2
}

# --- civil-date arithmetic (Howard Hinnant's days_from_civil) --------------------
# 10#: strip leading zeros so `08`/`09` are not read as invalid octal.
days_from_civil() {
    local y=$((10#$1)) m=$((10#$2)) d=$((10#$3)) era yoe doy doe
    [ "$m" -le 2 ] && y=$((y - 1))
    era=$(((y >= 0 ? y : y - 399) / 400))
    yoe=$((y - era * 400))
    doy=$(((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1))
    doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
    command printf '%s' $((era * 146097 + doe - 719468))
}

civil_from_days() {
    local z=$(($1 + 719468)) era doe yoe y doy mp d m
    era=$(((z >= 0 ? z : z - 146096) / 146097))
    doe=$((z - era * 146097))
    yoe=$(((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365))
    y=$((yoe + era * 400))
    doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100)))
    mp=$(((5 * doy + 2) / 153))
    d=$((doy - (153 * mp + 2) / 5 + 1))
    m=$((mp < 10 ? mp + 3 : mp - 9))
    [ "$m" -le 2 ] && y=$((y + 1))
    command printf '%04d-%02d-%02d' "$y" "$m" "$d"
}

TODAY="${OKF_TODAY:-}"
TODAY="${TODAY#"${TODAY%%[![:space:]]*}"}"
TODAY="${TODAY%"${TODAY##*[![:space:]]}"}"
[ -n "$TODAY" ] || TODAY="$(command date +%Y-%m-%d)"
case "$TODAY" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) fail2 "today must be YYYY-MM-DD, got '$TODAY'" ;;
esac
# Round-trip check: rejects 2026-02-30 and 2026-13-01, which the shape allows.
TODAY_N="$(days_from_civil "${TODAY%%-*}" "$(command printf '%s' "$TODAY" | command cut -d- -f2)" "${TODAY##*-}")"
[ "$(civil_from_days "$TODAY_N")" = "$TODAY" ] || fail2 "today is not a real calendar date: '$TODAY'"
HORIZON="$(civil_from_days $((TODAY_N + WINDOW)))"

# --- the scan ------------------------------------------------------------------
[ -f "$SCANNER" ] || fail2 "scanner not found at $SCANNER"
[ -d "$BUNDLE_ROOT" ] || {
    command printf 'No memory bundle at %s — nothing to check.\n' "$BUNDLE_ROOT"
    exit 0
}

WORKDIR="$(command mktemp -d)" || fail2 "mktemp failed"
trap 'command rm -rf "$WORKDIR"' EXIT

# Tracked files only, matching validate-okf-bundle.sh: gitignored scratch under
# the bundle is not repo content. Non-git tree -> find.
if command git -C "$BUNDLE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    command git -C "$BUNDLE_ROOT" ls-files -z -- '*.md' |
        while IFS= read -r -d '' rel; do
            [ -n "$rel" ] && command printf '%s\n' "$BUNDLE_ROOT/$rel"
        done >"$WORKDIR/files"
else
    command find "$BUNDLE_ROOT" -type f -name '*.md' | command sort >"$WORKDIR/files"
fi

# scan_at DATE OUT — date-driven stale rows only, as "path<TAB>stale_after".
# The date is parsed out of the scanner's FIXED label "...stale_after date
# (YYYY-MM-DD)", which is the scanner's text, not the memory's.
scan_at() {
    local rc=0
    OKF_TODAY="$1" MEMORY_BUNDLE_ROOT="$BUNDLE_ROOT" command bash "$SCANNER" \
        "$WORKDIR/files" >"$WORKDIR/raw" 2>"$WORKDIR/err" || rc=$?
    if [ "$rc" -ne 0 ]; then
        command sed 's/^/  /' "$WORKDIR/err" >&2
        fail2 "scanner failed (exit $rc) at OKF_TODAY=$1"
    fi
    command awk -F'\t' '
        $3 == "memory-stale" && index($4, "past its stale_after date (") {
            d = substr($4, index($4, "date (") + 6, 10)
            print $1 "\t" d
        }' "$WORKDIR/raw" | command sort -u >"$2"
}

# The scanner's comparison is strict (`stale_after < today`), so a memory dated
# exactly on its horizon fires one day later. Scan at HORIZON+1 so `expiring`
# includes stale_after == HORIZON, matching the "<= today + N" contract above.
scan_at "$TODAY" "$WORKDIR/now"
scan_at "$(civil_from_days $((TODAY_N + WINDOW + 1)))" "$WORKDIR/ahead"
command comm -13 "$WORKDIR/now" "$WORKDIR/ahead" >"$WORKDIR/soon"

count() { command awk 'END { print NR }' "$1"; }
N_NOW="$(count "$WORKDIR/now")"
N_SOON="$(count "$WORKDIR/soon")"

# --- report --------------------------------------------------------------------
emit() {
    command printf '%s\n' "$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        command printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
    fi
}

rel() { command printf '%s' "${1#"$REPO_ROOT"/}"; }

emit "## Memory staleness ($TODAY, window ${WINDOW}d → $HORIZON)"
emit ""
if [ "$N_NOW" -eq 0 ] && [ "$N_SOON" -eq 0 ]; then
    emit "No memory is expired or expiring within ${WINDOW} days."
    exit 0
fi
if [ "$N_NOW" -gt 0 ]; then
    emit "**Expired ($N_NOW)** — past \`stale_after\`:"
    while IFS="$(command printf '\t')" read -r path d; do
        emit "- \`$(rel "$path")\` (stale_after $d)"
    done <"$WORKDIR/now"
    emit ""
fi
if [ "$N_SOON" -gt 0 ]; then
    emit "**Expiring within ${WINDOW} days ($N_SOON):**"
    while IFS="$(command printf '\t')" read -r path d; do
        emit "- \`$(rel "$path")\` (stale_after $d)"
    done <"$WORKDIR/soon"
    emit ""
fi
emit "For each: re-verify the sentence its \`stale_check\` names and move \`stale_after\` forward;"
emit "or graduate it to a lesson-named memory; or delete it. See MEMORY.md § Conventions."
exit 1
