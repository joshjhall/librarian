#!/usr/bin/env bash
# review-route — deterministic "full fan-out or cheap path?" DECISION for the
# ship-issue adversarial review loop (issue #550).
#
# The review harness fans out 7 agents (manifest + 5 dimensions + judge) on every
# diff regardless of shape. Measured on the #471/#472 run, cycles 1-2 reviewed
# TWO FILES and still burned 47M cache_read / 945k output between them. A
# doc-only change pays for `security`, `correctness`, `tests` and
# `decomposition` reviewers that have nothing to read.
#
# This script answers one question before the manifest agent is dispatched: does
# this diff contain anything the expensive dimensions can say something about?
#
# ---------------------------------------------------------------------------
# WHY A SCRIPT, and not logic inside workflow.js
#
#   - workflow.js runs in a sandbox with NO shell, NO filesystem, and NO git
#     (the two-runtime model). It cannot classify paths it cannot read, and a
#     path handed to it arrives as an unreadable string.
#   - Same "script owns the DECISION, the model performs the action" split as
#     workflow-wall-timeout.sh (#327), review-convergence.sh (#596) and
#     autonomy-resolve.sh (#190). A threshold a model re-derives each cycle
#     drifts; a script's cannot. #327 is the standing proof — a bound left in
#     prose wedged three golems.
#
# ---------------------------------------------------------------------------
# THE CLEAN-SEMANTICS ARGUMENT — the whole safety case, in one place.
#
# `clean` is half the merge invariant AND the review loop's terminator, so
# whether a routed cycle may return `clean: true` is not a detail. workflow.js
# already records the governing principle:
#
#     Gating on budget-exhaustion makes `clean` unforgeable by truncation: a
#     partial review can never terminate the loop as clean and reach the merge
#     gate — even when the surviving dimensions produced only deferrable
#     findings.
#
# So the design question is whether routing is COMPLETE-BY-DESIGN (like a
# narrowed dimension — legitimately clean) or TRUNCATION (like budget
# exhaustion — never clean).
#
# Routing is complete-by-design ONLY IF THIS CLASSIFIER IS CONSERVATIVE:
# any doubt resolves to the full fan-out, and ANY source-classified file forces
# it. SAFETY RESTS ON THE CLASSIFIER, NEVER ON THE REVIEWERS. That is why R2
# below treats an extension this table does not know as possibly-source rather
# than as inert, and why every ambiguous input lands on `full`.
#
# The alternative that returns `clean: false` for a routed cycle was rejected as
# self-defeating: a cycle that can never be clean can never terminate the loop,
# so every routed PR would burn cheap cycles to REVIEW_MAX_CYCLES and dead-end
# for a human — strictly worse than the status quo it optimizes.
#
# TWO REJECTED TRIGGERS, recorded so they are not re-proposed:
#
#   - Routing on a LINE COUNT alone. A small SOURCE diff would then merge having
#     never been read by the security or correctness dimensions, which is
#     precisely what the merge invariant exists to prevent — 20 lines of auth
#     code is where security matters most. `--diff-lines` therefore only ever
#     forces `full` (R5); it can never produce `cheap`.
#   - A cheap path running ONE COMBINED reviewer instead of the fan-out. That
#     reintroduces a judge-less self-grading path, the exact structure the fresh
#     judge exists to break (#580).
#
# WHY scope-drift STAYS on the cheap path. It is the one dimension that reads
# the issue's acceptance criteria for completeness, and a doc-only diff can
# absolutely fail an AC — documentation that does not describe what was asked
# for is incomplete work, not inert prose. It already always reads the full diff
# and is already exempt from narrowing, so keeping it costs one agent and
# preserves AC-completeness on every path.
#
# ---------------------------------------------------------------------------
# Subcommand (emits `key=value` lines to stdout):
#   check --files FILE [--diff-lines N]
#         -> route          full | cheap
#            rule           the deciding rule (R0-empty … R5-max-lines)
#            reason         a short slug naming why
#            source_files / doc_files / config_files / unknown_files   counts
#            dimensions     comma list of dimensions the caller should run
#
# Ordered first-match rule list — the first rule that matches decides, and the
# last has no condition, so the policy is total and non-overlapping. (Same
# authoring discipline as `dispositionOf` in ship-issue/workflow.js and the
# C0-C8 list in review-convergence.sh, and for the same reason: an LLM applying
# prose cannot be unit-tested, an ordered rule list can.)
#
#   R0-empty       empty or missing file list            -> full   (fail safe)
#   R1-forced      LIBRARIAN_REVIEW_ROUTE=full           -> full   (operator)
#   R2-source      ANY source-classified file            -> full
#   R3-unknown     ANY unrecognized extension            -> full   (fail safe)
#   R4-max-lines   --diff-lines over the ceiling         -> full
#   R5-doc-config  every file is doc or config           -> cheap
#
# Note R5 is the ONLY rule that yields `cheap`, and it is last: every fail-safe
# gets to fire first. There is deliberately no trailing catch-all yielding
# `cheap` — the default direction of this script is `full`.
#
# Environment:
#   LIBRARIAN_REVIEW_ROUTE            auto | full.  Default: auto.
#                                     `full` disables routing entirely (R1) —
#                                     the operator's off switch. Any value other
#                                     than `auto` is treated as `full`, so a
#                                     typo disables the optimization rather than
#                                     silently enabling it.
#   LIBRARIAN_REVIEW_ROUTE_MAX_LINES  Diff-line ceiling above which the cheap
#                                     path is refused even for doc-only diffs
#                                     (R4). Default: 2000. A 5,000-line docs
#                                     rewrite is a real review surface.
#                                     Only ever forces `full`, never `cheap`.
#
# Exit codes: 0 = success; 2 = usage error (bad subcommand / flag / value).
#
# Runtime: bash-only. bash-3.2 clean (no associative arrays / mapfile /
# namerefs / case-conversion), BSD-regex clean (no \s, \w, GNU BRE \| or
# grep -P), clean under shellcheck, coreutils reached via the `command` builtin,
# and fails loud on bad input rather than emitting a wrong verdict. See CLAUDE.md
# § Key conventions (runtime policy).
#
# The 77 skip sentinel does NOT apply here: that is for an absent LINTER, and
# this is a decision helper whose absence is handled by its CALLER degrading to
# the full fan-out (the safe direction).

set -euo pipefail

USAGE="Usage: review-route.sh check --files <file-list> [--diff-lines N]"

# die <message> — fail loud: actionable message + usage on stderr, exit 2.
die() {
    command printf '%s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

# --- Classification ----------------------------------------------------------
#
# THE EXTENSION SPELLINGS ARE NOT INVENTED HERE. ADR 0002 names ONE normative
# spelling of these lexical facts — EXT_LANG in
# check-decomposition/loc_engine.py — and makes every other copy a SUBSET of it:
# a scanner may cover FEWER extensions, but may never CONTRADICT it. The source
# list below is that subset (py/js/jsx/mjs/cjs/ts/tsx/rs/go/sh/bash/swift).
# tests/lint-language-table-sync.sh is the gate on that class of drift.
#
# The doc/config set follows the existing precedent in
# check-lifecycle/patterns.sh, which skips exactly
# `*.md *.txt *.json *.yaml *.yml *.toml *.ini *.cfg *.conf` as non-source.
#
# `classify <path>` echoes exactly one of: source | doc | config | unknown.
#
# THE `unknown` RETURN IS LOAD-BEARING, NOT A PLACEHOLDER. An extension absent
# from both lists is treated as POSSIBLY SOURCE by R3 — never as inert. A `.rb`,
# `.java` or `.kt` file this table does not yet know must widen the review, not
# narrow it. If you add an extension here, add it to the list it truly belongs
# to; do not "tidy up" unknown into doc.
classify() {
    # Basename-anchored so a directory named `docs.py/` cannot decide a file's
    # type, and an extensionless path (Dockerfile, Makefile) is never mistaken
    # for its parent directory's suffix.
    _cr_base="${1##*/}"

    case "$_cr_base" in
        # Extensionless build/infra files. Explicitly `unknown` rather than
        # `config`: a Dockerfile or Makefile is executable build logic that the
        # security and correctness dimensions genuinely review (the harness's
        # own DIMENSION_RELEVANT_TYPES lists `docker`/`ci` under both), so
        # routing around them would be exactly the silent narrowing this script
        # must not perform.
        Dockerfile | Dockerfile.* | Makefile | Justfile | justfile)
            command printf 'unknown\n'
            return 0
            ;;
    esac

    case "$_cr_base" in
        *.py | *.js | *.jsx | *.mjs | *.cjs | *.ts | *.tsx | *.rs | *.go | *.sh | *.bash | *.swift)
            command printf 'source\n'
            ;;
        *.md | *.markdown | *.rst | *.adoc | *.txt)
            command printf 'doc\n'
            ;;
        *.json | *.yaml | *.yml | *.toml | *.ini | *.cfg | *.conf)
            command printf 'config\n'
            ;;
        *)
            command printf 'unknown\n'
            ;;
    esac
}

# --- check subcommand --------------------------------------------------------

cmd_check() {
    _files=""
    _diff_lines=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --files)
                [ "$#" -ge 2 ] || die "--files requires a value"
                _files="$2"
                shift 2
                ;;
            --diff-lines)
                [ "$#" -ge 2 ] || die "--diff-lines requires a value"
                _diff_lines="$2"
                shift 2
                ;;
            *)
                die "unknown flag: $1"
                ;;
        esac
    done

    [ -n "$_files" ] || die "--files is required"

    # A non-numeric --diff-lines is a caller bug, never intent: fail loud rather
    # than coercing it to 0, which would silently disable the R4 ceiling.
    if [ -n "$_diff_lines" ]; then
        case "$_diff_lines" in
            '' | *[!0-9]*) die "--diff-lines must be a non-negative integer, got '$_diff_lines'" ;;
        esac
    fi

    _max_lines="${LIBRARIAN_REVIEW_ROUTE_MAX_LINES:-2000}"
    case "$_max_lines" in
        '' | *[!0-9]*)
            die "LIBRARIAN_REVIEW_ROUTE_MAX_LINES must be a non-negative integer, got '$_max_lines'"
            ;;
    esac

    # Count by class. A missing file list is NOT an error — it is the R0
    # fail-safe case (the caller may legitimately have no list yet), and it
    # routes `full` like every other ambiguity.
    _n_source=0
    _n_doc=0
    _n_config=0
    _n_unknown=0
    _n_total=0

    if [ -f "$_files" ]; then
        while IFS= read -r _line || [ -n "$_line" ]; do
            # Skip blank lines; a trailing newline in the list is normal.
            [ -n "$_line" ] || continue
            _n_total=$((_n_total + 1))
            case "$(classify "$_line")" in
                source) _n_source=$((_n_source + 1)) ;;
                doc) _n_doc=$((_n_doc + 1)) ;;
                config) _n_config=$((_n_config + 1)) ;;
                *) _n_unknown=$((_n_unknown + 1)) ;;
            esac
        done <"$_files"
    fi

    # --- The ordered rule list. First match decides. -------------------------
    _route=""
    _rule=""
    _reason=""

    if [ "$_n_total" -eq 0 ]; then
        _route="full"
        _rule="R0-empty"
        _reason="no-files-to-classify"
    elif [ "${LIBRARIAN_REVIEW_ROUTE:-auto}" != "auto" ]; then
        _route="full"
        _rule="R1-forced"
        _reason="operator-disabled-routing"
    elif [ "$_n_source" -gt 0 ]; then
        _route="full"
        _rule="R2-source"
        _reason="source-file-present"
    elif [ "$_n_unknown" -gt 0 ]; then
        _route="full"
        _rule="R3-unknown"
        _reason="unrecognized-extension"
    elif [ -n "$_diff_lines" ] && [ "$_diff_lines" -gt "$_max_lines" ]; then
        _route="full"
        _rule="R4-max-lines"
        _reason="diff-over-line-ceiling"
    else
        # Reached only when every file classified doc or config and no fail-safe
        # fired. This is the ONLY path to `cheap`.
        _route="cheap"
        _rule="R5-doc-config"
        _reason="doc-config-only"
    fi

    # The dimensions the caller should run. On the cheap path this is
    # scope-drift ALONE — see the header for why it survives routing. Emitted
    # rather than left for the caller to infer, so the contract is observable in
    # the output and pinned by the test suite.
    if [ "$_route" = "cheap" ]; then
        _dimensions="scope-drift"
    else
        _dimensions="security,correctness,tests,conventions,decomposition,scope-drift"
    fi

    command printf 'route=%s\n' "$_route"
    command printf 'rule=%s\n' "$_rule"
    command printf 'reason=%s\n' "$_reason"
    command printf 'source_files=%s\n' "$_n_source"
    command printf 'doc_files=%s\n' "$_n_doc"
    command printf 'config_files=%s\n' "$_n_config"
    command printf 'unknown_files=%s\n' "$_n_unknown"
    command printf 'dimensions=%s\n' "$_dimensions"
}

# --- Dispatch ----------------------------------------------------------------

[ "$#" -ge 1 ] || die "a subcommand is required"

_subcmd="$1"
shift

case "$_subcmd" in
    check) cmd_check "$@" ;;
    *) die "unknown subcommand: $_subcmd" ;;
esac
