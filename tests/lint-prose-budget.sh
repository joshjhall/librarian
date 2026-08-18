#!/usr/bin/env bash
# Prose-budget ratchet gate for plugins/**/*.md (issue #589).
#
# Markdown is the largest surface in this repo (20,492 lines across 106 files at
# the time of writing, up from 18,753 when #589 was filed — +9% while the issue
# sat open) and was the only surface with no size signal. Structure is gated by
# lint-skills-agents.sh, style by rumdl, slash-command form by
# lint-command-refs.sh; nothing said how long a skill's prose should be or
# noticed when it grew. That matters more here than for ordinary docs: these
# files are loaded into an agent's context at runtime, so length is a direct
# token and instruction-adherence cost.
#
# ONE THRESHOLD TABLE, NOT TWO. The budgets come from
# check-decomposition/thresholds.yml's `bloat_thresholds` — the same table the
# audit lens, the review lens, and index health already read. That file's own
# comment names this issue as the precedent:
#
#   "two threshold tables over the same files that must agree is exactly the
#    duplicated-prose failure #663 was filed to eliminate, and the same argument
#    already recorded on #589 for plugin prose."
#
# So this gate PARSES that YAML rather than hardcoding numbers. A threshold edit
# there needs no edit here. Hardcoding would have been easier and would have
# recreated the exact failure the table warns about.
#
# THE RATCHET, and why a fixed ceiling could not work. #589's AC asks for two
# things that a single constant cannot deliver together: fail above a documented
# ceiling, AND land green on the current tree. The tree already exceeds the
# audit thresholds in a dozen places (checker.md 676 > 400, mode-protocol.md
# 877 > 650). A constant set above today's worst offender is blind in between —
# mode-protocol.md could reach 899 with no signal — and hands every NEW file the
# loosest budget in the repo rather than its real one.
#
# So the ceiling is per-file: max(type high threshold, baseline entry).
#
#   over budget, no baseline entry      -> FAIL   (a new file gets the real budget)
#   over budget, at its baseline        -> pass   (today's tree, green)
#   one line above its baseline         -> FAIL   (the central property)
#   under its baseline                  -> pass, and --regen tightens the entry
#
# Shrinking a file therefore auto-tightens the ratchet; raising an entry is a
# deliberate, reviewable one-line diff. Growth is what this catches, which is
# what the issue asked for.
#
# CORPUS: plugins/**/*.md plus the top-level README.md — mirroring
# lint-command-refs.sh exactly, and for its reasons. docs/verification/** is out
# of scope BY CONSTRUCTION (outside the walked root), not by an active filter:
# those are dated end-to-end transcripts whose length is evidence, and a gate
# over them would pressure someone to edit a session log to fit a budget. There
# is no `grep -v` here that could regress; what validate-prose-budget.sh pins is
# the NARROWNESS of the root itself, since widening it to $REPO_ROOT is the
# plausible regression that would sweep them in.
#
# FAIL LOUD, NOT SKIP (AC4). This gate never returns the 77 skip sentinel. Per
# CLAUDE.md, 77 means "the gate's LINTER is absent" — an optional external tool
# like ruff or shellcheck. This gate's runtime is awk and coreutils; their
# absence is a broken environment, not an unavailable optional tool, so it exits
# non-zero with an actionable message. A gate that skipped green here would be
# indistinguishable from a pass, which is how a gate sits inert unnoticed.
#
# Pure bash, bash-3.2 clean (no declare -A, no mapfile, no namerefs) and BSD-safe
# (no \s/\w, no grep -P) per the repo's portability policy — macOS ships bash 3.2
# and BSD grep/sed.
#
# Usage:
#   tests/lint-prose-budget.sh            report + enforce (CI / pre-push)
#   tests/lint-prose-budget.sh --regen    rewrite the baseline from the tree

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The walked root. NARROW ON PURPOSE — see the corpus note in the header.
PLUGINS_DIR="${PROSE_BUDGET_PLUGINS_DIR:-$REPO_ROOT/plugins}"
THRESHOLDS_FILE="${PROSE_BUDGET_THRESHOLDS:-$REPO_ROOT/plugins/review-audit/skills/check-decomposition/thresholds.yml}"
BASELINE_FILE="${PROSE_BUDGET_BASELINE:-$SCRIPT_DIR/prose-budget.baseline}"

REGEN=0
if [ "${1:-}" = "--regen" ]; then
    REGEN=1
elif [ -n "${1:-}" ]; then
    command printf 'lint-prose-budget: unknown argument %s (expected --regen or none)\n' \
        "$1" >&2
    exit 2
fi

# --- Runtime check (fail loud, never 77) -------------------------------------

require_tool() {
    command -v "$1" >/dev/null 2>&1 && return 0
    command printf 'lint-prose-budget: FATAL — required tool %s not found on PATH.\n' "$1" >&2
    command printf '  This gate needs awk + coreutils. A missing one is a broken\n' >&2
    command printf '  environment, not an optional linter, so this is a hard failure\n' >&2
    command printf '  rather than a skip (see the header, AC4).\n' >&2
    exit 2
}
require_tool awk
require_tool find
require_tool sort

# --- Thresholds: parsed from check-decomposition/thresholds.yml --------------

# read_bloat_high TYPE — the `high` value under bloat_thresholds.<TYPE>.
#
# PURE BASH, no sed (#679): BSD sed rejects multi-command brace blocks and reads
# \s as a literal, and a swallowed sed error would silently yield an EMPTY
# threshold — which would compare as 0 and flag every file, or worse, be treated
# as absent. The format is a two-level map of scalars, so no regex engine is
# needed. An unparsable value is a hard failure, not a default.
read_bloat_high() {
    local want="$1" file="$2"
    local line in_bloat=false in_type=false value=""

    [ -f "$file" ] || {
        command printf 'lint-prose-budget: FATAL — thresholds file not found: %s\n' \
            "$file" >&2
        exit 2
    }

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "bloat_thresholds:"*)
                in_bloat=true
                in_type=false
                continue
                ;;
            # Any other line starting in column 0 with a letter/underscore is the
            # next TOP-LEVEL key, which ends the bloat_thresholds block.
            [a-zA-Z_]*)
                in_bloat=false
                in_type=false
                continue
                ;;
        esac

        $in_bloat || continue

        # A two-space-indented `name:` is a file-type key within the block.
        case "$line" in
            "  ${want}:"*)
                in_type=true
                continue
                ;;
            "  "[a-zA-Z_]*:*)
                in_type=false
                continue
                ;;
        esac

        $in_type || continue

        case "$line" in
            *"high:"*)
                # `    high: 650 # COMPANION_HIGH` -> 650
                value="${line#*high:}"
                value="${value%%#*}"
                # Trim surrounding whitespace without \s (BSD-safe).
                value="$(command printf '%s' "$value" | command tr -d '[:space:]')"
                command printf '%s\n' "$value"
                return 0
                ;;
        esac
    done <"$file"

    command printf 'lint-prose-budget: FATAL — no bloat_thresholds.%s.high in %s\n' \
        "$want" "$file" >&2
    command printf '  The budget table moved or was renamed. This gate reads it as the\n' >&2
    command printf '  single source of truth (see the header); it does not carry its own\n' >&2
    command printf '  copy of the numbers.\n' >&2
    exit 2
}

CLAUDE_MD_HIGH="$(read_bloat_high claude_md "$THRESHOLDS_FILE")"
SKILL_HIGH="$(read_bloat_high skill_md "$THRESHOLDS_FILE")"
AGENT_HIGH="$(read_bloat_high agent_md "$THRESHOLDS_FILE")"
DOC_HIGH="$(read_bloat_high doc_md "$THRESHOLDS_FILE")"
COMPANION_HIGH="$(read_bloat_high companion_md "$THRESHOLDS_FILE")"

# Every value must be a positive integer — a blank or non-numeric parse would
# silently compare as 0 and flag the whole corpus.
for _pair in "claude_md:$CLAUDE_MD_HIGH" "skill_md:$SKILL_HIGH" \
    "agent_md:$AGENT_HIGH" "doc_md:$DOC_HIGH" "companion_md:$COMPANION_HIGH"; do
    _name="${_pair%%:*}"
    _val="${_pair#*:}"
    case "$_val" in
        '' | *[!0-9]*)
            command printf 'lint-prose-budget: FATAL — bloat_thresholds.%s.high parsed as "%s", not a number\n' \
                "$_name" "$_val" >&2
            exit 2
            ;;
    esac
done
unset _pair _name _val

# --- Classification: the SAME arms as check-decomposition's bloat_spec --------
#
# Order matters and mirrors patterns.sh exactly: `case` takes the first match, so
# the narrower */skills/*/SKILL.md pattern MUST precede the companion glob or
# every SKILL.md would be sized by the looser companion budget. Keeping the order
# identical to the scanner's is what makes "reuse the thresholds" a real claim
# rather than a resemblance.
classify() {
    case "$1" in
        */CLAUDE.md | */AGENTS.md) command printf 'CLAUDE.md\t%s\n' "$CLAUDE_MD_HIGH" ;;
        */skills/*/SKILL.md) command printf 'skill definition\t%s\n' "$SKILL_HIGH" ;;
        */agents/*/*.md | */agents/*.md) command printf 'agent definition\t%s\n' "$AGENT_HIGH" ;;
        */skills/*/*.md) command printf 'skill companion\t%s\n' "$COMPANION_HIGH" ;;
        */docs/*.md) command printf 'documentation\t%s\n' "$DOC_HIGH" ;;
        # Anything else under the root (README.md, a plugin-level page) is
        # documentation-shaped: not auto-loaded, but hard to navigate when huge.
        *) command printf 'documentation\t%s\n' "$DOC_HIGH" ;;
    esac
}

# --- Corpus ------------------------------------------------------------------
#
# README.md is REQUIRED, not best-effort — same reasoning as lint-command-refs.sh:
# silently skipping a missing one would narrow the corpus without saying so.
collect_corpus() {
    if [ ! -d "$PLUGINS_DIR" ]; then
        command printf 'lint-prose-budget: FATAL — plugins dir not found: %s\n' \
            "$PLUGINS_DIR" >&2
        exit 2
    fi
    command find "$PLUGINS_DIR" -type f -name '*.md' | command sort
    if [ -f "$REPO_ROOT/README.md" ] && [ "$PLUGINS_DIR" = "$REPO_ROOT/plugins" ]; then
        command printf '%s\n' "$REPO_ROOT/README.md"
    fi
}

# rel PATH — repo-relative, so baseline entries are portable across checkouts
# (a worktree and the main checkout have different absolute prefixes).
rel() {
    case "$1" in
        "$REPO_ROOT"/*) command printf '%s\n' "${1#"$REPO_ROOT"/}" ;;
        *) command printf '%s\n' "$1" ;;
    esac
}

# --- Baseline ----------------------------------------------------------------
#
# Format: `<repo-relative-path> <line-count> [# rationale]`, one per line, `#`
# comment lines ignored. Flat text rather than JSON so a raise is a one-line
# reviewable diff and needs no parser beyond the shell.
#
# THE BUDGETS ARE TARGETS, NOT LAWS. A file that is genuinely better long stays
# long — a contract gate's assertion list, a protocol that would only become
# harder to follow split across two files. What must not happen is exceptions
# accumulating silently until the budget means nothing. So this file is the
# EXCEPTIONS LEDGER: every entry is a file consciously over budget, the ratchet
# stops it growing further, and the trailing `#` rationale says why it is
# allowed. An entry without a rationale is an exception nobody has justified —
# reported (not failed) so the list stays honest without blocking a shrink.
#
# The rationale is stripped before the count is parsed, so an entry with or
# without one behaves identically to the ratchet.
baseline_for() {
    local want="$1" line rest path count
    [ -f "$BASELINE_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '#'* | '') continue ;;
        esac
        # Strip an inline rationale before parsing, so `path 676 # why` and
        # `path 676` parse the same.
        rest="${line%%#*}"
        # Trim trailing whitespace BEFORE splitting: `path 556 # why` leaves
        # `path 556 ` here, and `${rest##* }` on that yields the empty string —
        # the entry would parse as having no count and silently stop ratcheting.
        while :; do
            case "$rest" in
                *' ' | *"$(command printf '\t')") rest="${rest%?}" ;;
                *) break ;;
            esac
        done
        path="${rest%% *}"
        count="${rest##* }"
        if [ "$path" = "$want" ]; then
            command printf '%s\n' "$count"
            return 0
        fi
    done <"$BASELINE_FILE"
    return 0
}

# baseline_rationale <path> — the trailing `# ...` note for an entry, if any.
# Empty when the entry carries no rationale (or does not exist).
baseline_rationale() {
    local want="$1" line rest path note
    [ -f "$BASELINE_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '#'* | '') continue ;;
        esac
        rest="${line%%#*}"
        path="${rest%% *}"
        [ "$path" = "$want" ] || continue
        case "$line" in
            *'#'*)
                note="${line#*#}"
                # Trim one leading space; keep interior spacing.
                note="${note# }"
                command printf '%s\n' "$note"
                ;;
        esac
        return 0
    done <"$BASELINE_FILE"
    return 0
}

# --- Scan --------------------------------------------------------------------

TOTAL_LINES=0
TOTAL_FILES=0
VIOLATIONS=""
OVER_BUDGET=""
# `<relative-path>\t<count>` per file, fed to the report's awk on stdin so it
# never has to run `wc` on an attacker-influenced path. See the report block.
#
# KNOWN LIMIT, deliberately not defended: a filename containing a literal TAB or
# NEWLINE would confuse this field/record split and misattribute a row in the
# per-skill report. Three reasons it stops there rather than growing an escape
# layer. (1) BLAST RADIUS: FILE_COUNTS feeds only the cosmetic top-10 report.
# The ratchet, the violation list and the exit code all come from the scan loop
# above, which handles the path as a single quoted shell word and is unaffected
# — so the worst case is a wrong line in a table, never a wrong verdict.
# (2) It is NOT the security bug: no shell parses this data, so a corrupted
# split misprints, it does not execute. (3) Such a path cannot reach the corpus
# in practice — this gate walks a git working tree, and git quotes/rejects those
# bytes in a path. Revisit if FILE_COUNTS ever feeds a decision instead of a
# display.
FILE_COUNTS=""

CORPUS="$(collect_corpus)"

while IFS= read -r file; do
    [ -n "$file" ] || continue
    count="$(command wc -l <"$file" | command tr -d '[:space:]')"
    relpath="$(rel "$file")"
    spec="$(classify "$file")"
    ftype="${spec%%	*}"
    budget="${spec##*	}"

    TOTAL_FILES=$((TOTAL_FILES + 1))
    TOTAL_LINES=$((TOTAL_LINES + count))
    FILE_COUNTS="$FILE_COUNTS$relpath	$count
"

    [ "$count" -gt "$budget" ] || continue

    # Over its type budget. Record it for the baseline, then decide against the
    # ratchet ceiling: max(budget, baseline entry).
    #
    # The max() is defensive, and deliberately kept though it is currently
    # equivalence-preserving. Under the `count > budget` guard directly above,
    # max(budget, base) and base alone always agree: when base >= budget they
    # are the same number, and when base < budget the guard has already
    # established count > budget > base, so both fail. A mutation dropping the
    # max() therefore cannot be caught by any fixture — verified in the #589
    # mutation round rather than assumed, per the
    # measure-a-suppression-before-keeping-it lesson.
    #
    # It stays because it is what makes the ceiling correct INDEPENDENTLY of
    # that guard: move or relax the `-gt "$budget"` line and a hand-lowered
    # baseline entry would otherwise start failing files that are within their
    # type budget. The invariant is stated here so a future reader does not
    # re-derive it, or delete it as dead code.
    OVER_BUDGET="$OVER_BUDGET$relpath $count
"
    base="$(baseline_for "$relpath")"
    ceiling="$budget"
    if [ -n "$base" ] && [ "$base" -gt "$ceiling" ]; then
        ceiling="$base"
    fi

    if [ "$count" -gt "$ceiling" ]; then
        if [ -n "$base" ]; then
            VIOLATIONS="$VIOLATIONS  $relpath: $count lines > $base (baseline) — $ftype, budget $budget
"
        else
            VIOLATIONS="$VIOLATIONS  $relpath: $count lines > $budget ($ftype budget) — no baseline entry
"
        fi
    fi
done <<EOF
$CORPUS
EOF

# --- --regen -----------------------------------------------------------------

if [ "$REGEN" -eq 1 ]; then
    {
        command printf '# Prose-budget ratchet baseline — issue #589.\n'
        command printf '#\n'
        command printf '# Files currently OVER their type budget in\n'
        command printf '# check-decomposition/thresholds.yml (bloat_thresholds). The gate fails a\n'
        command printf '# file above max(its type budget, its entry here), so these are frozen at\n'
        command printf '# their present size: they may shrink freely, and any growth fails.\n'
        command printf '#\n'
        command printf '# Regenerate with: tests/lint-prose-budget.sh --regen\n'
        command printf '# RAISING an entry is a deliberate, reviewable decision — a bigger file\n'
        command printf '# needs a reason in the commit message, not a silent regen.\n'
        command printf '#\n'
        command printf '# THE BUDGETS ARE TARGETS, NOT LAWS. Some files are genuinely better long.\n'
        command printf '# This file is the EXCEPTIONS LEDGER: each entry is consciously over\n'
        command printf '# budget, the ratchet stops it growing, and the trailing `#` note says WHY\n'
        command printf '# it is allowed. Add a rationale when you add an entry — --regen preserves\n'
        command printf '# existing ones, and the report lists any entry still missing one.\n'
        command printf '#\n'
        command printf '# Format: <repo-relative-path> <line-count> [# why this exception stands]\n'
        # Re-attach each entry's existing rationale. A regen that dropped them
        # would silently erase every justification on a routine shrink — the
        # ledger would keep its numbers and lose its reasons.
        command printf '%s' "$OVER_BUDGET" | while IFS=' ' read -r _path _count; do
            [ -n "$_path" ] || continue
            _note="$(baseline_rationale "$_path")"
            if [ -n "$_note" ]; then
                command printf '%s %s # %s\n' "$_path" "$_count" "$_note"
            else
                command printf '%s %s\n' "$_path" "$_count"
            fi
        done
    } >"$BASELINE_FILE"
    command printf 'lint-prose-budget: baseline written to %s (%s entries)\n' \
        "$(rel "$BASELINE_FILE")" \
        "$(command printf '%s' "$OVER_BUDGET" | command grep -c . || true)"
    exit 0
fi

# --- Report (AC1: always reports, pass or fail) ------------------------------

command printf '\n=== Plugin prose size (plugins/**/*.md + README.md) ===\n\n'
command printf '  %s files, %s total lines\n\n' "$TOTAL_FILES" "$TOTAL_LINES"

command printf '  Per-skill / per-directory totals (top 10):\n'
# awk receives `<relative-path>\t<count>` pairs on STDIN and never runs a
# command. It deliberately does NOT shell out to `wc` with an interpolated
# path: git allows almost any byte in a filename except `/` and NUL, so a file
# named with a `"` or `$(...)` would escape the quoting and be executed by the
# shell awk spawns. This gate walks all of plugins/ and runs in CI and pre-push,
# so that path is reachable by anyone who can add a file in a PR. The counts are
# already computed in the scan loop above, which makes passing them in both
# safer and cheaper than recomputing — there is no tradeoff to weigh here.
command printf '%s' "$FILE_COUNTS" | LC_ALL=C command awk -F '\t' '
  NF < 2 { next }
  {
    path = $1
    c = $2 + 0
    n = split(path, p, "/")
    # Group a skill by its directory, an agents/ file by its plugin.
    key = path
    for (i = 1; i < n; i++) {
      if (p[i] == "skills" || p[i] == "agents") {
        key = ""
        stop = (p[i] == "skills") ? i + 1 : i
        for (j = 1; j <= stop; j++) key = key (j > 1 ? "/" : "") p[j]
        break
      }
    }
    sum[key] += c
    cnt[key]++
  }
  END {
    for (k in sum) printf "%8d  %3d files  %s\n", sum[k], cnt[k], k
  }
' | command sort -rn | command head -10 | LC_ALL=C command awk '{ print "  " $0 }'

over_count="$(command printf '%s' "$OVER_BUDGET" | command grep -c . || true)"
command printf '\n  %s file(s) over their type budget (ratcheted by tests/prose-budget.baseline)\n' \
    "$over_count"

# List the exceptions with their rationale. The budgets are targets, not laws —
# a file that is genuinely better long stays long. The risk is not any single
# exception, it is exceptions ACCUMULATING UNNOTICED until the budget means
# nothing. Printing the ledger on every run (pass or fail) is what keeps that
# visible: an unjustified entry is called out by name rather than blending into
# a count. This reports, never fails — the ratchet already prevents growth, and
# failing a green tree over a missing note would just get the gate turned off.
if [ "$over_count" -gt 0 ]; then
    command printf '\n  Exceptions (over budget by choice — ratcheted at their current size):\n'
    command printf '%s' "$OVER_BUDGET" | while IFS=' ' read -r _path _count; do
        [ -n "$_path" ] || continue
        _note="$(baseline_rationale "$_path")"
        if [ -n "$_note" ]; then
            command printf '    %s (%s) — %s\n' "$_path" "$_count" "$_note"
        else
            command printf '    %s (%s) — NO RATIONALE RECORDED\n' "$_path" "$_count"
        fi
    done
    # Count unjustified entries in the parent shell (the loop above runs in a
    # subshell, so its increments would not survive).
    _unjustified=0
    for _p in $(command printf '%s' "$OVER_BUDGET" | LC_ALL=C command awk '{ print $1 }'); do
        [ -n "$(baseline_rationale "$_p")" ] || _unjustified=$((_unjustified + 1))
    done
    if [ "$_unjustified" -gt 0 ]; then
        command printf '\n  %s exception(s) carry no rationale. Add one as a trailing\n' "$_unjustified"
        command printf '  `# why` in tests/prose-budget.baseline so the ledger stays reviewable.\n'
    fi
fi

if [ -n "$VIOLATIONS" ]; then
    command printf '\n[FAIL] Prose budget exceeded:\n\n'
    command printf '%s' "$VIOLATIONS"
    command printf '\nA file may not grow past max(its type budget, its baseline entry).\n'
    command printf 'Either trim the prose, or — if the growth is justified — raise the entry\n'
    command printf 'in tests/prose-budget.baseline and say why in the commit message.\n'
    command printf 'Budgets live in check-decomposition/thresholds.yml (bloat_thresholds).\n\n'
    exit 1
fi

command printf '\n[ok] All prose within budget.\n\n'
exit 0
