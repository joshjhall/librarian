#!/usr/bin/env bash
# Per-domain deterministic-coverage report for the check-* scanner skills.
#
# Each check-* skill ships a contract.md with a `## Categories` table (the
# categories it is contracted to emit) plus a patterns.sh / patterns.py pre-scan
# (the categories it actually emits, as quoted kebab-case slug literals in the
# TSV `category` field). "Deterministic coverage" for a domain is the fraction of
# contract categories that the pre-scan implementation actually emits — the rest
# are left to the LLM heuristic pass. This tool computes that fraction per domain
# and overall.
#
# It exists because plugins/dev-core/skills/agent-authoring/patterns.md cited a
# coverage figure that was historically measured by hand (issue #240); this makes
# the metric live and re-runnable so patterns.md can point back at a real script.
#
# Usage:
#   check-patterns-coverage.sh [--strict [THRESHOLD]] [--skills-dir DIR]
#
#   --strict [THRESHOLD]  Exit non-zero if overall coverage is below THRESHOLD
#                         percent (default threshold 80). Without --strict the
#                         tool is report-only and always exits 0 (barring a
#                         fail-loud error below).
#   --skills-dir DIR      Scan DIR for check-* skill directories instead of the
#                         repo's plugins/review-audit/skills. Used by the tests.
#
# Fails loudly (non-zero + message on stderr) rather than reporting a misleading
# "0/0 = 100%" when no check-* domains or no contract tables are found.
#
# Runtime: pure bash 3.2 + coreutils (portable grep -oE, no PCRE). Runs on host
# macOS / bare-linux / container identically. See CLAUDE.md § Runtime policy.
# No Python port: the Python-primary/bash-fallback shim (patterns.py/patterns.sh)
# governs per-skill pre-scans under plugins/**, not bin/ maintainer utilities;
# this tool needs only line/string parsing (no PCRE), so bash alone suffices —
# matching the other bin/*.sh scripts (release.sh, generate-release-notes.sh).
set -euo pipefail

# --- Argument parsing -------------------------------------------------------

STRICT=false
THRESHOLD=80
SKILLS_DIR=""

usage() {
    command echo "Usage: $0 [--strict [THRESHOLD]] [--skills-dir DIR]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --strict)
            STRICT=true
            # An optional numeric threshold may follow --strict.
            if [ "$#" -ge 2 ] && command expr "$2" : '[0-9][0-9]*$' >/dev/null 2>&1; then
                THRESHOLD="$2"
                shift
            fi
            ;;
        --skills-dir)
            if [ "$#" -lt 2 ]; then
                usage
                exit 1
            fi
            SKILLS_DIR="$2"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            command echo "check-patterns-coverage: unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
    shift
done

# --- Locate the skills tree -------------------------------------------------

if [ -z "$SKILLS_DIR" ]; then
    BIN_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(command dirname "$BIN_DIR")"
    SKILLS_DIR="$REPO_ROOT/plugins/review-audit/skills"
fi

if [ ! -d "$SKILLS_DIR" ]; then
    command echo "check-patterns-coverage: skills dir not found: $SKILLS_DIR" >&2
    exit 1
fi

# --- Category extraction ----------------------------------------------------

# contract_categories <contract.md> — the category slugs declared in the file's
# `## Categories` table. Scoped to that section (via the sed range) so slugs
# mentioned elsewhere in the contract are not counted. Backtick-wrapped kebab
# tokens, backticks stripped, sorted-unique.
contract_categories() {
    # The trailing `|| true` mirrors the guard in emitted_categories(): `grep`
    # exits 1 when the Categories table yields zero slugs (a WIP/malformed
    # contract), which under `set -o pipefail` would abort the whole script at
    # the bare `contract_list="$(...)"` assignment — before the
    # `[ -n "$contract_list" ] || continue` guard that is meant to skip exactly
    # that domain. `|| true` keeps an empty result benign so the skip fires.
    command sed -n '/^## Categories/,/^## /p' "$1" |
        command grep -oE '`[a-z][a-z0-9-]+`' |
        command tr -d '`' |
        command sort -u || true
}

# emitted_categories <domain_dir> — the category slugs the domain's pre-scan
# implementation actually emits, unioned across patterns.sh and patterns.py
# (a domain may ship either or both behind the shared TSV contract). Quoted
# kebab slug literals, quotes stripped, sorted-unique. Mirrors the portable
# extractor in tests/validate-scanner-category-parity.sh.
emitted_categories() {
    local dir="$1"
    # A trailing `:` keeps the group's exit status 0 even when the last
    # patterns.* file is absent — otherwise a failing `[ -f ]` test would, under
    # `set -o pipefail`, abort the whole script for a domain that ships only one
    # of the two impls.
    {
        [ -f "$dir/patterns.sh" ] &&
            command grep -oE '"[a-z][a-z0-9]+-[a-z][a-z0-9-]*"' "$dir/patterns.sh"
        [ -f "$dir/patterns.py" ] &&
            command grep -oE '"[a-z][a-z0-9]+-[a-z][a-z0-9-]*"' "$dir/patterns.py"
        :
    } |
        command tr -d '"' |
        command sort -u
}

# --- Per-domain walk --------------------------------------------------------

total_categories=0
covered_categories=0
domains_seen=0

# Sorted, stable domain order for reproducible output.
for domain_dir in "$SKILLS_DIR"/check-*; do
    [ -d "$domain_dir" ] || continue
    contract_file="$domain_dir/contract.md"
    [ -f "$contract_file" ] || continue

    domain_name="$(command basename "$domain_dir")"

    contract_list="$(contract_categories "$contract_file")"
    # A contract with no Categories table is not a coverable domain; skip it.
    [ -n "$contract_list" ] || continue

    emitted_list="$(emitted_categories "$domain_dir")"

    # Count non-empty lines. `grep -c .` exits 1 on a zero count, which under
    # `set -o pipefail` would abort the script — the trailing `|| true` keeps a
    # legitimately-empty result (a domain with zero covered categories) benign.
    domain_total="$(command printf '%s\n' "$contract_list" | command grep -c . || true)"
    # Covered = contract categories that also appear in the emitted set.
    covered_list="$(command comm -12 \
        <(command printf '%s\n' "$contract_list") \
        <(command printf '%s\n' "$emitted_list"))"
    domain_covered="$(command printf '%s\n' "$covered_list" | command grep -c . || true)"
    # The categories in the contract that the pre-scan does NOT emit. `grep .`
    # exits 1 when nothing is missing (a fully-covered domain); `|| true` stops
    # pipefail+set -e from treating that empty diff as a fatal error.
    missing_list="$({ command comm -23 \
        <(command printf '%s\n' "$contract_list") \
        <(command printf '%s\n' "$emitted_list") |
        command grep . |
        command paste -sd ',' - |
        command sed 's/,/, /g'; } || true)"

    domains_seen=$((domains_seen + 1))
    total_categories=$((total_categories + domain_total))
    covered_categories=$((covered_categories + domain_covered))

    domain_pct=$((domain_covered * 100 / domain_total))
    if [ -n "$missing_list" ]; then
        command printf '%-26s %d/%d  (%d%%)  missing: %s\n' \
            "$domain_name" "$domain_covered" "$domain_total" "$domain_pct" "$missing_list"
    else
        command printf '%-26s %d/%d  (%d%%)\n' \
            "$domain_name" "$domain_covered" "$domain_total" "$domain_pct"
    fi
done

# --- Fail loud on an empty scan ---------------------------------------------

if [ "$domains_seen" -eq 0 ] || [ "$total_categories" -eq 0 ]; then
    command echo "check-patterns-coverage: no check-* domains with a Categories table found under $SKILLS_DIR" >&2
    exit 1
fi

# --- Overall summary --------------------------------------------------------

overall_pct=$((covered_categories * 100 / total_categories))
command printf '\nOverall: %d/%d categories (%d%%) deterministic coverage across %d domains\n' \
    "$covered_categories" "$total_categories" "$overall_pct" "$domains_seen"

# --- Strict gate ------------------------------------------------------------

if [ "$STRICT" = true ] && [ "$overall_pct" -lt "$THRESHOLD" ]; then
    command echo "check-patterns-coverage: coverage ${overall_pct}% is below --strict threshold ${THRESHOLD}%" >&2
    exit 1
fi
