#!/usr/bin/env bash
# review-convergence — deterministic "keep reviewing or stop?" DECISION for the
# ship-issue multi-cycle adversarial review loop (issue #596).
#
# Replaces "stop at cycle 3" with "stop when converged, bounded by a hard cap".
# `REVIEW_MAX_CYCLES` defaulted to 3, and that counter was the only stop signal
# the loop consulted. #567's 26-cycle batch showed the number is BOTH too low and
# too high:
#
#   too low  — #533 and #498 each ran to 5 cycles still finding confirmed
#              defects; #533's ONLY blocking finding in the whole batch
#              (security, 0.92) arrived in cycle 4. Under the cap it would have
#              shipped.
#   too high — #564 was verifiably clean at cycle 1 (move-only refactor). Cycles
#              2 and 3 would have been pure cost.
#
# And the one signal the loop DID react to — a zero-finding cycle, via `clean` —
# is the WEAKEST one the batch produced. #568 cycle 2 returned zero across five
# dimensions and was immediately followed by a cycle finding a 0.88-certainty
# real defect: the zero covered a narrow test-only delta, the next delta touched
# three scanner copies. A zero says nothing about the NEXT delta, so this script
# only lets a zero terminate when the cycle actually had comparable material to
# review (rule C3 vs C4 below — issue #596 AC#2, the refinement the issue turns
# on).
#
# WHY A SCRIPT, and not workflow.js or skill prose:
#   - not workflow.js — that harness runs exactly ONE cycle per invocation and
#     has no cross-cycle memory (`maxCycles` is informational there; the SKILL
#     owns the loop). Convergence is by definition a cross-cycle judgement.
#   - not prose — that is precisely the #327 failure. #307 expressed the
#     wall-time bound as skill instructions the model applied by hand; three
#     golems (266/252/263) wedged unbounded. The fix was
#     workflow-wall-timeout.sh, and this is the same shape: the script owns the
#     DECISION, the model performs the action. A threshold a model re-derives
#     each cycle drifts; a script's cannot.
#
# What this does NOT do: it does not run a review cycle, read git, or stop
# anything. It reads one cycle's already-returned result JSON and returns a
# verdict. The caller (ship-issue's review loop) acts on it.
#
# Subcommand (emits `key=value` lines to stdout):
#   check --cycle N --max-cycles N --result FILE --delta-lines N
#         [--prev-result FILE ...] [--prev-delta-lines N] [--delta-files FILE]
#         [--partial true|false]
#         -> verdict   continue | stop
#            rule      the deciding rule (C1-cap … C8-novel)
#            reason    a short slug naming why
#            findings / novel / duplicate / refuted / recursive   counts
#
# Ordered first-match rule list — the first rule that matches decides, and the
# last has no condition, so the policy is total and non-overlapping. (Same
# authoring discipline as `dispositionOf` in ship-issue/workflow.js, and for the
# same reason: an LLM applying prose cannot be unit-tested, an ordered rule list
# can.)
#
#   C1-cap        cycle >= max-cycles                          -> stop
#   C2-partial    the cycle was partial                        -> continue
#   C3-narrow-zero  zero findings on a NARROWER surface        -> continue
#   C4-zero       zero findings on a comparable/full surface   -> stop
#   C5-refuted-only  every finding was refuted on verification -> stop
#   C6-duplicate  every finding duplicates an earlier cycle's  -> stop
#   C7-recursive  every finding is test machinery about the    -> stop
#                 previous cycle's own fix
#   C8-novel      (everything else)                            -> continue
#
# C1 outranks everything, so termination is GUARANTEED regardless of the
# convergence signals — the hard ceiling is retained (#596 AC#3).
#
# C2 sits directly under it and is the safety rule: a budget-exhausted or
# wall-timed-out cycle can never be a convergence stop. It is partial, not
# converged — its zero/duplicate/refuted counts describe the dimensions that ran,
# not the review. This mirrors `computeClean` forcing `clean` false on
# `budget_exhausted`. Only the cap may end a partial run.
#
# Signals are derived from what the harness ALREADY returns — no new judge axis,
# no new producer contract:
#   duplicate — fingerprint `file:line_start:category`. Deliberately NOT the
#               finding's `ref`, whose `#i` index suffix is per-cycle and so
#               never matches across cycles.
#   refuted   — `disposition_rule == "R2-low-certainty"`, which is exactly "the
#               fresh judge re-scored this to LOW on verification".
#   recursive — the finding is in a test file AND that file is in the delta the
#               previous cycle's own fix produced. This class has no fixed
#               point: each fix adds machinery for the next cycle to find
#               untested (#498 cycle 4).
#
# Runtime: bash-only, no python port (precedent: workflow-wall-timeout.sh,
# recover-journal-partials.sh). bash-3.2 clean (no associative arrays / mapfile /
# namerefs / case-conversion), clean under shellcheck, coreutils reached via the
# `command` builtin, and fails loud on bad input or a missing `jq` rather than
# emitting a wrong verdict. See CLAUDE.md § Key conventions (runtime policy).
set -euo pipefail

USAGE="Usage: review-convergence check --cycle N --max-cycles N --result FILE --delta-lines N
                                  [--prev-result FILE ...] [--prev-delta-lines N]
                                  [--delta-files FILE] [--partial true|false]
  --cycle N             1-based cycle number just completed (positive integer)
  --max-cycles N        hard ceiling (positive integer; REVIEW_MAX_CYCLES)
  --result FILE         this cycle's harness result JSON
  --delta-lines N       lines of diff this cycle reviewed (non-negative integer)
  --prev-result FILE    an earlier cycle's result JSON; repeatable
  --prev-delta-lines N  lines of diff the previous cycle reviewed
  --delta-files FILE    newline-delimited paths in this cycle's delta
                        (git diff --name-only), for the recursive check
  --partial true|false  whether the cycle was budget-exhausted or timed out
env: REVIEW_CONVERGENCE_SURFACE_RATIO (percent, default 50)"

# die <message> — fail loud: actionable message + usage on stderr, exit 2.
die() {
    command printf '%s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

# opt <name> -- <args...>
# Echo the token following <name> in the args after `--`. A value that itself
# starts with `--` is treated as absent. Exit status: 0 found, 1 not found.
opt() {
    _opt_name="$1"
    shift
    shift # consume the literal `--` separator
    _opt_prev=""
    _opt_found=1
    _opt_val=""
    for _opt_tok in "$@"; do
        if [ "$_opt_prev" = "$_opt_name" ]; then
            _opt_found=0
            case "$_opt_tok" in
                --*)
                    die "review-convergence: $_opt_name needs a value, got the flag '$_opt_tok' (a value may not begin with '--')"
                    ;;
                *) _opt_val="$_opt_tok" ;;
            esac
            _opt_prev=""
            break
        fi
        _opt_prev="$_opt_tok"
    done
    # Trailing-flag case: the `--*` guard needs a following token to exist, so a
    # flag that is the LAST argument falls off the end with an empty value. That
    # is silent for the OPTIONAL flags (--delta-files, --prev-delta-lines), where
    # empty is indistinguishable from "not passed" and quietly disables the C7
    # recursive signal or the C3/C4 surface comparison. Fail instead.
    #
    # `_opt_prev` is cleared on the match-and-break above, so reaching here with
    # it still equal to the flag name means the loop ENDED on the flag — i.e. the
    # flag was last. Without that reset this fires on every ordinary call whose
    # final token happens to be the matched flag's own value.
    if [ "$_opt_prev" = "$_opt_name" ]; then
        die "review-convergence: $_opt_name needs a value but was the last argument"
    fi
    command printf '%s' "$_opt_val"
    return "$_opt_found"
}

# opt_all <name> -- <args...>
# Like `opt`, but echoes EVERY occurrence's value, one per line. `--prev-result`
# is repeatable because duplicate detection is against all earlier cycles, not
# just the immediately preceding one: a finding that reappears after being
# skipped for a cycle is still a duplicate, not novel material.
#
# A value that itself starts with `--` is a caller bug, and here it must FAIL
# rather than be dropped: `opt`'s single-value flags are all required, so a
# dropped value trips an explicit `-z` check downstream — but a dropped
# `--prev-result` is invisible. The loop would just see one fewer prior cycle,
# quietly weakening duplicate detection toward `novel`/continue. That is a wrong
# verdict computed from silently-incomplete input, which this script must never
# emit.
opt_all() {
    _all_name="$1"
    shift
    shift # consume the literal `--` separator
    _all_prev=""
    for _all_tok in "$@"; do
        if [ "$_all_prev" = "$_all_name" ]; then
            case "$_all_tok" in
                --*)
                    die "review-convergence: $_all_name needs a value, got the flag '$_all_tok' (a value may not begin with '--')"
                    ;;
                *) command printf '%s\n' "$_all_tok" ;;
            esac
        fi
        _all_prev="$_all_tok"
    done
    # The `--*` guard above only fires on the iteration AFTER the flag, so it
    # needs a following token to exist. When the flag is the LAST token there is
    # no next iteration and the value is silently empty — the same invisible drop,
    # reached by falling off the end of the loop instead of by a `--`-shaped
    # value. Check the trailing case explicitly.
    if [ "$_all_prev" = "$_all_name" ]; then
        die "review-convergence: $_all_name needs a value but was the last argument"
    fi
}

# is_nonneg_int <value> — 0 if value is a non-negative integer in canonical
# base-10 form, else 1. Empty, any non-digit, AND a leading-zero numeral all
# fail. Rejecting leading zeros is deliberate: these values feed bash arithmetic,
# where `030` is read as OCTAL (a silently wrong threshold) and `08` crashes —
# both bypassing the fail-loud exit-2 contract. `0` itself is the sole valid zero.
is_nonneg_int() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        0) return 0 ;;
        0*) return 1 ;;
        *) return 0 ;;
    esac
}

# is_test_path <path> — 0 if the path looks like test machinery. Used only by the
# C7 recursive check, which additionally requires the file to be in the previous
# cycle's own fix delta, so a false positive here cannot stop a loop on its own.
is_test_path() {
    case "$1" in
        test/* | tests/* | */test/* | */tests/*) return 0 ;;
        spec/* | */spec/*) return 0 ;;
        *_test.* | *_spec.*) return 0 ;;
        *.test.* | *.spec.*) return 0 ;;
        *) return 1 ;;
    esac
}

# read_findings <file> — emit the cycle's findings as one compact JSON array
# (blocking + deferrable). Both buckets count: convergence is about whether
# reviewers still have MATERIAL, which a deferrable finding is just as much as a
# blocking one. Fails loud on unreadable or malformed JSON — a review loop must
# never get a verdict computed from a file it could not parse.
read_findings() {
    if [ ! -r "$1" ]; then
        die "review-convergence: cannot read result file '$1'"
    fi
    # `jq empty` is the validity probe: `jq -e .` misreports a valid `false`/
    # `null` document as invalid.
    if ! command jq empty "$1" >/dev/null 2>&1; then
        die "review-convergence: result file '$1' is not valid JSON"
    fi
    command jq -c '[(.blocking // [])[], (.deferrable // [])[]]' "$1"
}

# fingerprints <findings-json> — one `file:line_start:category` line per finding.
# Both readers below emit ONE RECORD PER LINE and are consumed by line-oriented
# `grep -F -x`, but their input is finding text that ultimately originates from an
# LLM reviewer describing a diff — untrusted, and potentially influenced by
# prompt-injected content in that diff. `jq -r` decodes JSON escapes, so a `.file`
# value containing a literal `\n` becomes a REAL newline and injects an extra
# synthetic record. That is not cosmetic: a crafted `.file` can forge a
# fingerprint match (C6) or a delta-membership match (C7), and BOTH of those rules
# STOP the review loop — so the injection's payoff is ending a review early and
# shipping a defect. Same class as the agnix TSV injection (#470).
#
# `gsub("[\n\r]";" ")` collapses any embedded newline/CR into a space INSIDE jq,
# before the value ever reaches the line-oriented layer, so one finding can only
# ever produce one record. Applied to every interpolated field, not just `.file` —
# `.category` is equally attacker-shaped.
# TWO filters, because the two consumers have different delimiters and applying
# the stricter one everywhere would cause false NEGATIVES:
#
#   `flat`  — record separators only. For the C7 check, where the whole line IS
#             the value (`grep -F -x` of a path against the delta-file list). A
#             colon is not a delimiter there, so substituting it would make a
#             legitimate path containing one stop matching — a missed recursive
#             signal, not a forged one.
#   `field` — record separators AND the `:` field separator. For the fingerprint,
#             where values are colon-JOINED. Without it a `.file` of
#             `src/a.js:10:correctness` with an empty `.category` concatenates to
#             exactly another finding's fingerprint, forging a C6 match with no
#             newline involved at all.
#
# Substitution rather than rejection: a colon in a path is legitimate on some
# platforms, and mapping it to `_` keeps ordinary values usable while making
# forgery require guessing the victim's post-substitution form.
FLATTEN='def flat: (. // "") | tostring | gsub("[\n\r]";" ");
         def field: flat | gsub(":";"_");'

fingerprints() {
    command printf '%s' "$1" |
        command jq -r "$FLATTEN"'.[] | "\(.file | field):\(.line_start // 0):\(.category | field)"'
}

cmd_check() {
    cycle="$(opt --cycle -- "$@" || true)"
    max_cycles="$(opt --max-cycles -- "$@" || true)"
    result="$(opt --result -- "$@" || true)"
    delta_lines="$(opt --delta-lines -- "$@" || true)"
    prev_delta_lines="$(opt --prev-delta-lines -- "$@" || true)"
    delta_files="$(opt --delta-files -- "$@" || true)"
    partial="$(opt --partial -- "$@" || true)"

    if [ -z "$partial" ]; then
        partial="false"
    fi

    if [ -z "$cycle" ]; then
        die "review-convergence: check needs --cycle N"
    fi
    if ! is_nonneg_int "$cycle" || [ "$cycle" -lt 1 ]; then
        die "review-convergence: --cycle must be an integer >= 1, got '$cycle'"
    fi
    if [ -z "$max_cycles" ]; then
        die "review-convergence: check needs --max-cycles N"
    fi
    if ! is_nonneg_int "$max_cycles" || [ "$max_cycles" -lt 1 ]; then
        die "review-convergence: --max-cycles must be an integer >= 1, got '$max_cycles'"
    fi
    if [ -z "$result" ]; then
        die "review-convergence: check needs --result FILE"
    fi
    # --delta-lines is REQUIRED, not defaulted. Defaulting it to 0 would make
    # every zero-finding cycle look maximally narrow and silently route to C3
    # (continue) — a caller that forgot the flag would get an extra cycle every
    # time with no signal. The C3/C4 split is the whole point of the issue, so
    # its input fails loud instead.
    if [ -z "$delta_lines" ]; then
        die "review-convergence: check needs --delta-lines N"
    fi
    if ! is_nonneg_int "$delta_lines"; then
        die "review-convergence: --delta-lines must be a non-negative integer, got '$delta_lines'"
    fi
    if [ -n "$prev_delta_lines" ] && ! is_nonneg_int "$prev_delta_lines"; then
        die "review-convergence: --prev-delta-lines must be a non-negative integer, got '$prev_delta_lines'"
    fi
    case "$partial" in
        true | false) ;;
        *) die "review-convergence: --partial must be true or false, got '$partial'" ;;
    esac

    ratio="${REVIEW_CONVERGENCE_SURFACE_RATIO:-50}"
    if ! is_nonneg_int "$ratio" || [ "$ratio" -lt 1 ] || [ "$ratio" -gt 100 ]; then
        die "review-convergence: REVIEW_CONVERGENCE_SURFACE_RATIO must be an integer 1-100, got '$ratio'"
    fi

    # `jq` is the JSON reader. Missing it must fail loud: a verdict computed
    # without reading the findings would be a confident wrong answer, and
    # `continue` vs `stop` are both consequential (wasted cycles vs a shipped
    # defect).
    if ! command -v jq >/dev/null 2>&1; then
        die "review-convergence: jq is required to read the cycle result JSON but was not found on PATH"
    fi

    # Materialize the repeatable --prev-result list ONCE, in the parent shell, so
    # `opt_all`'s die propagates. Consuming it inline as a here-doc
    # (`done <<EOF\n$(opt_all ...)\nEOF`) would run it in a subshell whose exit
    # status the here-doc discards — the die would print its message and the run
    # would carry on to emit a verdict anyway, the same swallowed-exit bug as
    # read_findings' below. Same reason it is not `$(...)` in the loop header.
    prev_results="$(opt_all --prev-result -- "$@")" || exit 2

    findings="$(read_findings "$result")"
    total="$(command printf '%s' "$findings" | command jq -r 'length')"

    # --- Signal counts (computed before the rule list so every verdict reports
    # the same numbers, whichever rule fires). ---
    refuted=0
    duplicate=0
    recursive=0
    if [ "$total" -gt 0 ]; then
        refuted="$(command printf '%s' "$findings" |
            command jq -r '[.[] | select(.disposition_rule == "R2-low-certainty")] | length')"

        # Duplicates: fingerprints seen in ANY earlier cycle's result.
        seen="$(command mktemp)"
        cur="$(command mktemp)"
        # shellcheck disable=SC2064  # expand the paths now, at trap-set time
        trap "command rm -f '$seen' '$cur'" EXIT
        # Read line-wise rather than word-splitting `$(...)`, so a path
        # containing a space is one file rather than two unreadable ones (which
        # `read_findings` would then fail loud on).
        # `read_findings` fails loud via `die` (exit 2) — but a `$(...)` command
        # substitution only ends the SUBSHELL, so a naive
        # `fingerprints "$(read_findings "$prev")"` swallows that exit and the
        # loop goes on to compute a verdict from partial history (an unreadable
        # prior cycle silently meaning "no duplicates", which biases toward
        # C8-continue — a wrong verdict from invalid state, the one thing this
        # script must never produce).
        #
        # So capture ONCE and check the substitution's own status: `local`-less
        # assignment from `$(...)` propagates the command's exit code, and `|| die`
        # converts a subshell death into a parent-shell one. Deliberately NOT a
        # pre-check followed by a re-read — that would validate a different read
        # than the one used (a TOCTOU window if the file changes in between) and
        # would duplicate `read_findings`'s checks, so the two could drift apart
        # as it gains new ones. One read, one status, one source of truth.
        while IFS= read -r prev; do
            [ -n "$prev" ] || continue
            prev_findings="$(read_findings "$prev")" ||
                die "review-convergence: cannot read prior-cycle result '$prev'"
            fingerprints "$prev_findings" >>"$seen"
        done <<EOF
$prev_results
EOF
        fingerprints "$findings" >"$cur"
        if [ -s "$seen" ]; then
            # grep -c would exit 1 on a zero count under `set -e`; count lines.
            duplicate="$(command grep -c -F -x -f "$seen" "$cur" 2>/dev/null || true)"
            if [ -z "$duplicate" ]; then
                duplicate=0
            fi
        fi

        # Recursive: a test file that the previous cycle's own fix delta touched.
        if [ -n "$delta_files" ] && [ -r "$delta_files" ]; then
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                if is_test_path "$f" && command grep -q -F -x -- "$f" "$delta_files"; then
                    recursive=$((recursive + 1))
                fi
            done <<EOF
$(command printf '%s' "$findings" | command jq -r "$FLATTEN"'.[] | select(.file != null and .file != "") | .file | flat')
EOF
        fi
    fi
    novel=$((total - duplicate))
    if [ "$novel" -lt 0 ]; then
        novel=0
    fi

    # --- Ordered first-match rule list ---------------------------------------
    if [ "$cycle" -ge "$max_cycles" ]; then
        # C1: the hard ceiling. Outranks every convergence signal so the loop
        # always terminates (#596 AC#3).
        rule="C1-cap"
        verdict="stop"
        reason="cap"
    elif [ "$partial" = "true" ]; then
        # C2: a partial cycle is not a converged one. Its counts describe the
        # dimensions that ran, not the review — the same reason `clean` is forced
        # false on budget exhaustion. Never let one end the loop.
        rule="C2-partial"
        verdict="continue"
        reason="partial"
    elif [ "$total" -eq 0 ] && [ -n "$prev_delta_lines" ] &&
        [ $((delta_lines * 100)) -lt $((prev_delta_lines * ratio)) ]; then
        # C3: the #568 case, and the refinement the issue turns on (AC#2). A zero
        # only means "reviewers found nothing HERE" — if `here` was a fraction of
        # the previous surface, it says nothing about the material still
        # unreviewed. Withhold termination.
        rule="C3-narrow-zero"
        verdict="continue"
        reason="narrow-surface-zero"
    elif [ "$total" -eq 0 ]; then
        # C4: zero on a comparable-or-larger surface (including cycle 1, where the
        # surface is the whole diff and there is no predecessor). This is the
        # #564 case — clean at cycle 1, where cycles 2-3 were pure cost.
        rule="C4-zero"
        verdict="stop"
        reason="zero-comparable-surface"
    elif [ "$refuted" -eq "$total" ]; then
        # C5: the strongest signal in the batch (#555 cycle 3) — a cycle whose
        # only output did not survive verification is reviewers out of material.
        rule="C5-refuted-only"
        verdict="stop"
        reason="refuted-only"
    elif [ "$duplicate" -eq "$total" ]; then
        # C6: nothing new, only earlier findings restated (#533 cycle 5, where 3
        # of 4 findings were one point seen from different dimensions).
        rule="C6-duplicate"
        verdict="stop"
        reason="duplicate-findings"
    elif [ "$recursive" -eq "$total" ]; then
        # C7: findings about the machinery the last fix added (#498 cycle 4).
        # This class has no fixed point, so it is termination, not progress.
        rule="C7-recursive"
        verdict="stop"
        reason="recursive-test-machinery"
    else
        # C8: novel, non-duplicative material remains. Unconditional, so the rule
        # list is total.
        rule="C8-novel"
        verdict="continue"
        reason="novel-material"
    fi

    command printf 'verdict=%s\n' "$verdict"
    command printf 'rule=%s\n' "$rule"
    command printf 'reason=%s\n' "$reason"
    command printf 'findings=%s\n' "$total"
    command printf 'novel=%s\n' "$novel"
    command printf 'duplicate=%s\n' "$duplicate"
    command printf 'refuted=%s\n' "$refuted"
    command printf 'recursive=%s\n' "$recursive"
}

if [ "$#" -eq 0 ]; then
    die "review-convergence: missing subcommand"
fi
sub="$1"
shift
case "$sub" in
    check) cmd_check "$@" ;;
    *) die "review-convergence: unknown subcommand '$sub'" ;;
esac
