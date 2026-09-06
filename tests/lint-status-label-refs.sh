#!/usr/bin/env bash
# Status-label vocabulary + transition-shape gate (issue #921).
#
# Two invariants, one gate, both offline.
#
# RULE 1 — every `status/*` named in plugins/**/*.md must be DECLARED.
# #921 found 18 references to `status/commit-pending` and 4 to `status/blocked`,
# neither of which existed in the repo. A `gh issue edit --add-label` with a
# nonexistent label fails the whole call, so those references were instructions
# to run a command that could not work. The declared vocabulary is the union of
# the `labels:` blocks in plugins/**/metadata.yml — four skills already publish
# one, so this makes an existing structure load-bearing rather than inventing a
# registry.
#
# RULE 2 — no markdown recipe may carry an add and a remove in ONE call.
# That combination is worse than atomic — it PARTIALLY APPLIES. Measured against
# real `gh` on #921 (2026-09-06): the remove lands and persists, then the add
# fails validation and the call reports failure, leaving the issue with NO
# status label at all. That is the #636 outcome exactly: an in-flight issue
# briefly re-selectable by another golem. The fix is
# scripts/label-transition.sh (add first, remove only on success); this rule is
# what stops a future edit from collapsing a transition back into one call.
#
# WHY OFFLINE, when `gh label list` is the truest source. tests/run-all.sh gates
# run in CI *and* in lefthook's pre-push, neither of which can rely on `gh` being
# authenticated. A network-dependent gate would spend most of its life on the 77
# skip sentinel — rendered `[SKIP] … did not run`, which catches nothing. The
# metadata.yml union is checkable everywhere, always.
#
# THE OTHER HALF OF THE CONTRACT — AND THIS GATE'S BLIND SPOT (#938).
# Being offline costs one direction, and it is the direction that caused #921:
#
#   prose names a label no metadata.yml declares   -> caught HERE
#   a declared label is deleted/renamed IN THE REPO -> INVISIBLE here
#
# Nothing in plugins/** changes when someone renames a label in the GitHub UI, so
# this gate stays green while the pipeline's label calls start failing exactly as
# they did on #636. Closing that requires network + `gh` auth, which is why it is
# a SCHEDULED job rather than a stage here — tracked as #938, modelled on
# .github/workflows/ai-config-prescan.yml (#907), this repo's one scheduled
# workflow. Read the two as one contract: neither half is sufficient alone.
#
# PROSE THAT FORBIDS THE PATTERN IS NOT AN INSTANCE OF IT. execute-protocol.md
# now says "never collapse this back into one `gh issue edit --add-label …
# --remove-label …` call". Gating that sentence would make the documentation of
# the rule violate the rule — the same self-contradiction lint-command-refs.sh
# avoids by exempting docs/verification/**. Rule 2 therefore skips any line
# containing the `…` ellipsis (U+2026), which is the repo's established spelling
# for an elided illustrative command and never appears in a runnable recipe.
#
# bash-3.2 clean, BSD-regex clean (no \s, \w, `grep -P`, or BRE \|): macOS ships
# BSD grep, where those read as literals and a scanner silently emits zero rows.
# Exits the reserved 77 sentinel when a required tool is absent — never 0, which
# would be indistinguishable from a pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGINS_DIR="$REPO_ROOT/plugins"

for tool in grep find sort awk sed; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        command printf '[SKIP] lint-status-label-refs: %s not found on PATH\n' "$tool" >&2
        exit 77
    fi
done

if [ ! -d "$PLUGINS_DIR" ]; then
    command printf 'plugins/ not found at %s — wrong working directory?\n' "$PLUGINS_DIR" >&2
    exit 1
fi

FAILURES=0

# --- The declared vocabulary ------------------------------------------------
# Union of `- name: status/...` entries across every plugins/**/metadata.yml.
declared_labels() {
    command find "$PLUGINS_DIR" -type f -name 'metadata.yml' 2>/dev/null |
        while IFS= read -r meta; do
            [ -n "$meta" ] || continue
            command awk '
                /^labels:/ { inblock = 1; next }
                inblock && /^[a-zA-Z_]+:/ { inblock = 0 }
                inblock && /^[[:space:]]*-[[:space:]]*name:[[:space:]]*status\// {
                    sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
                    gsub(/"/, "")
                    print
                }
            ' "$meta"
        done | command sort -u
}

DECLARED="$(declared_labels)"

if [ -z "$DECLARED" ]; then
    command printf 'No status/* labels declared in any metadata.yml — the gate has nothing to check against.\n' >&2
    command printf 'That is almost certainly a parser regression, not an empty vocabulary.\n' >&2
    exit 1
fi

# --- Rule 1: every referenced status/* label is declared --------------------
# Referenced names are scraped from plugins/**/*.md.
#
# A LABEL IS DELIMITED; A PATH FRAGMENT IS NOT. Requiring a leading delimiter
# (backtick, quote, colon, or table pipe) is what separates the two classes the
# corpus actually contains, and it is a WHITELIST — the same shape, and the same
# reasoning, as lint-command-refs.sh. A blocklist of known-innocent spellings
# would need a new entry every time someone adds a status directory.
#
# What the delimiter requirement excludes today, all measured, none of them
# labels:
#   `.status/agent{N}.json`, `.status/tracks`, `.status/feed`, `.status/pool`
#       — the golem feed's on-disk state paths (a leading `.` is never a label)
#   `status/sink` in docs/adr/0001 — prose, "its status/sink config"
#
# The trailing class stops the match at a label boundary, so
# `status/blocked-by-design` cannot read as `status/blocked` (the
# prefix-match-is-not-an-exact-pin class); tests/golem-scripts/110 plants exactly
# that string as a negative fixture for the runtime twin of this rule.
referenced_labels() {
    command find "$PLUGINS_DIR" -type f -name '*.md' 2>/dev/null |
        while IFS= read -r md; do
            [ -n "$md" ] || continue
            # Same no-match-under-set-e guard as Rule 2 below; here the `|| true`
            # must wrap the GREP, not the pipeline, or a no-match still
            # propagates out of the pipe's first stage.
            { command grep -oE '[`"'"'"':|]status/[a-z][a-z0-9-]*' "$md" 2>/dev/null || true; } |
                command sed 's/^.//'
        done | command sort -u
}

for ref in $(referenced_labels); do
    found=0
    for dec in $DECLARED; do
        if [ "$ref" = "$dec" ]; then
            found=1
            break
        fi
    done
    if [ "$found" -eq 0 ]; then
        command printf 'UNDECLARED LABEL: %s is referenced in plugins/**/*.md but declared in no metadata.yml labels: block\n' "$ref" >&2
        # `--include` MUST precede the path operand: after it, grep reads the
        # flag as a FILENAME, prints "No such file or directory", and exits 2 —
        # which under `set -e`/`pipefail` aborted this report mid-line, so the
        # gate exited non-zero with the finding printed but no [FAIL] summary.
        # `|| true` additionally absorbs a legitimate no-match.
        { command grep -rn --include='*.md' -- "$ref" "$PLUGINS_DIR" 2>/dev/null || true; } |
            command head -n 3 | command sed 's/^/    /' >&2
        FAILURES=$((FAILURES + 1))
    fi
done

# --- Rule 2: no combined add+remove in one call -----------------------------
# Both platform spellings. The `…` guard exempts prose that quotes the forbidden
# shape in order to forbid it (see the header).
check_combined_calls() {
    command find "$PLUGINS_DIR" -type f -name '*.md' 2>/dev/null |
        while IFS= read -r md; do
            [ -n "$md" ] || continue
            # `|| true` is load-bearing: grep exits 1 on NO MATCH, and under
            # `set -e` a no-match on the LAST file walked kills the whole
            # pipeline before the report runs — the gate then exits non-zero
            # with completely empty output, which reads as a mysterious failure
            # rather than a pass. Observed while building this gate.
            { command grep -nE -- '(--add-label.*--remove-label|--remove-label.*--add-label|--label[^|]*--unlabel|--unlabel[^|]*--label)' \
                "$md" 2>/dev/null || true; } |
                while IFS= read -r hit; do
                    [ -n "$hit" ] || continue
                    case "$hit" in
                        *…*) continue ;; # illustrative prose, not a recipe
                    esac
                    command printf '%s:%s\n' "${md#"$REPO_ROOT"/}" "$hit"
                done
        done
}

COMBINED="$(check_combined_calls)"
if [ -n "$COMBINED" ]; then
    command printf 'COMBINED add+remove LABEL CALL (the remove lands, then the add fails — issue left with NO status label, #636/#921):\n' >&2
    command printf '%s\n' "$COMBINED" | command sed 's/^/    /' >&2
    command printf '  Use scripts/label-transition.sh instead: it adds first and removes only on success.\n' >&2
    # Count the hits so the report is honest about scale rather than "1 problem".
    hits="$(command printf '%s\n' "$COMBINED" | command grep -c . || true)"
    FAILURES=$((FAILURES + hits))
fi

# --- Report -----------------------------------------------------------------
if [ "$FAILURES" -gt 0 ]; then
    command printf '\n[FAIL] lint-status-label-refs: %s problem(s)\n' "$FAILURES" >&2
    exit 1
fi

command printf '[ok] status/* label refs: %s declared, all references resolve, no combined add+remove calls.\n' \
    "$(command printf '%s\n' "$DECLARED" | command grep -c .)"
