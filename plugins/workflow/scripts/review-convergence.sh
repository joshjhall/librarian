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
#         [--attempt N] [--max-attempts N]
#         [--prev-result FILE ...] [--prev-delta-lines N] [--delta-files FILE]
#         [--partial true|false]
#         -> verdict   continue | stop
#            rule      the deciding rule (C0-attempt-cap … C8-novel)
#            capped_over  the rule that WOULD have decided had C1 not fired
#                         (empty unless rule=C1-cap) — see #635 below
#            reason    a short slug naming why
#            findings / novel / duplicate / refuted / recursive   counts
#
# Ordered first-match rule list — the first rule that matches decides, and the
# last has no condition, so the policy is total and non-overlapping. (Same
# authoring discipline as `dispositionOf` in ship-issue/workflow.js, and for the
# same reason: an LLM applying prose cannot be unit-tested, an ordered rule list
# can.)
#
#   C0-attempt-cap  attempt >= max-attempts                    -> stop
#   C0b-no-signal   the cycle produced NO review signal        -> continue
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
# C1 outranks every CONVERGENCE rule (C2-C8), so the cycle ceiling still binds
# regardless of the convergence signals (#596 AC#3). The two rules above it are
# not convergence signals at all — they are assertions about whether the cycle
# was a valid data point, and the absolute termination guarantee moves up to C0.
#
# C0b/C0 — a crashed cycle must not be charged to the cycle cap (#616).
#   A cycle in which no dimension reported at all produces no review signal:
#   `agent_count: 1, agents_done: 0, agents_error: 1`, nothing ever read the
#   diff. Observed live on PR #615, where a `$PARAMETER_VALUE`-wrapped manifest
#   payload failed schema validation identically on all five retries — but the
#   harness sets the flag for a fan-out-wide wipeout too (every dimension failed
#   or was skipped at the budget floor), which is the same void one phase later.
#   Strictly narrower than a PARTIAL cycle: a partial had some dimension report,
#   so its findings are evidence and it still charges the cap via C2.
#   Charging that to `max_cycles` makes a crashed cycle INDISTINGUISHABLE from a
#   substantive one: three infra flakes exhaust the cap and dead-end the PR with
#   a summary reading "review could not reach clean in N cycles" — implying
#   findings that were never produced. That is the mirror of #597: not a falsely
#   CLEAN cycle (the harness already forces `clean: false` here, correctly), but
#   a falsely EXHAUSTED loop.
#
#   So C0b returns `continue` without the cycle counter advancing — and because
#   that alone would let a persistently crashing harness loop forever, C0
#   bounds total ATTEMPTS above it. Cycles count reviews; attempts count tries.
#   The caller increments `attempt` every iteration and `cycle` only when the
#   cycle produced signal (`ci-review-protocol.md` step (f)).
#
#   `no_review_signal` is read from the result JSON as an EXPLICIT field the
#   harness sets, never inferred from a zero dimension count: a narrowed cycle
#   whose dimensions were all filtered out ran to completion by design (#492),
#   and inferring would conflate "reviewed nothing because nothing changed" with
#   "reviewed nothing because it crashed" — the exact conflation this rule exists
#   to end.
#
# capped_over — what C1 concealed (#635).
#   `verdict=stop` alone cannot distinguish `C4-zero` (reviewers found nothing on
#   a comparable surface — genuine convergence) from `C1-cap` (the loop ran out
#   of budget — says nothing about convergence). `ci-review-protocol.md` step (f)
#   acts on `verdict`, and ship-issue's merge invariant treats a clean cycle plus
#   `stop` as review-converged, so a `C1-cap` stop can satisfy that check while
#   providing none of the evidence it represents.
#
#   Observed on PR #634 cycle 5: zero findings over a 149-line delta against the
#   previous cycle's 647 — 23% of the prior surface, well under the ratio floor,
#   which the rule list itself calls uninformative (`C3-narrow-zero` ->
#   continue). The cap fired first and the loop terminated on a cycle whose own
#   zero the policy considers meaningless: the "looks converged, isn't" shape C3
#   exists to prevent, reintroduced at the cap boundary.
#
#   The fix does NOT reorder the rules — C1 must keep outranking C2-C8 or
#   termination is no longer guaranteed. Instead the ambiguity is made VISIBLE:
#   when C1 fires, the remaining conditions are evaluated anyway and the rule
#   that would have decided is reported as `capped_over`. A caller then reads
#   `rule=C1-cap capped_over=C3-narrow-zero` and can tell a real stop from a
#   budget artifact with no second invocation. The field is emitted on every
#   verdict (empty when the deciding rule was not C1-cap) so the output contract
#   is stable and a consumer never has to test for the key's presence.
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
                                  [--attempt N] [--max-attempts N]
                                  [--prev-result FILE ...] [--prev-delta-lines N]
                                  [--delta-files FILE] [--partial true|false]
  --cycle N             1-based number of cycles that PRODUCED A REVIEW (positive
                        integer). A no-signal cycle does not advance it.
  --max-cycles N        ceiling on reviewed cycles (positive integer;
                        REVIEW_MAX_CYCLES)
  --result FILE         this cycle's harness result JSON
  --delta-lines N       lines of diff this cycle reviewed (non-negative integer)
  --attempt N           1-based number of loop ATTEMPTS including crashed ones
                        (positive integer; defaults to --cycle)
  --max-attempts N      absolute ceiling on attempts (positive integer;
                        REVIEW_MAX_ATTEMPTS, default 2 x --max-cycles)
  --prev-result FILE    an earlier cycle's result JSON; repeatable
  --prev-delta-lines N  lines of diff the previous cycle reviewed
  --delta-files FILE    newline-delimited paths in this cycle's delta
                        (git diff --name-only), for the recursive check
  --partial true|false  whether the cycle was budget-exhausted or timed out
env: REVIEW_CONVERGENCE_SURFACE_RATIO (percent, default 50)
     REVIEW_MAX_ATTEMPTS (positive integer, default 2 x --max-cycles)"

# die <message> — fail loud: actionable message + usage on stderr, exit 2.
die() {
    command printf '%s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

# opt <name> -- <args...>
# Echo the token following <name> in the args after `--`. A value that itself
# starts with `--`, or a flag with no following token at all, fails loud.
# Exit status: 0 found, 1 not found.
#
# FIRST-MATCH-WINS, deliberately: it `break`s on the first occurrence, so a
# repeated flag resolves from occurrence one and any later ones are never
# visited (including a dangling valueless repeat). That is the asymmetry with
# `opt_all`, which cannot break — it must collect EVERY occurrence — and
# therefore needs its post-loop trailing guard to catch a dangling repeat.
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
    # `.line_start` is interpolated into the fingerprint as a NUMBER, so unlike
    # `.file`/`.category` it never passes through `field`. That asymmetry rests on
    # an assumption nothing here enforced: `workflow.js`'s FINDING_SCHEMA declares
    # `line_start` an integer, but a result file can reach this script without
    # having passed that gate (a hand-built fixture, a corrupted file, a future
    # caller). A string `line_start` carrying a newline injects a whole extra
    # record and reopens the forging vector through a third field (#619).
    #
    # Validate here rather than sanitizing at the interpolation site, so the check
    # covers this cycle's result AND every `--prev-result` through one code path,
    # and so a malformed file fails loud (the script's contract) instead of being
    # silently coerced into a verdict. `null` stays valid — `fingerprints`
    # defaults it via `.line_start // 0`, and omitting the field is legitimate.
    if ! command jq -e 'all((.blocking // [])[], (.deferrable // [])[];
            .line_start == null
            or ((.line_start | type) == "number"
                and (.line_start | floor) == .line_start))' "$1" >/dev/null 2>&1; then
        die "review-convergence: result file '$1' has a finding whose line_start is not an integer (findings must satisfy FINDING_SCHEMA)"
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
# Neutralizing the separators INSIDE jq, before the value ever reaches the
# line-oriented layer, is what keeps one finding to one record. Applied to every
# interpolated field, not just `.file` — `.category` is equally attacker-shaped.
# TWO filters, because the two consumers have different delimiters and applying
# the stricter one everywhere would cause false NEGATIVES:
#
#   `flat`  — record separators only, collapsed to a space. For the C7 check,
#             where the whole line IS the value (`grep -F -x` of a path against
#             the delta-file list). A colon is not a delimiter there, so encoding
#             it would make a legitimate path containing one stop matching — a
#             missed recursive signal, not a forged one.
#   `field` — record separators AND the `:` field separator. For the fingerprint,
#             where values are colon-JOINED. Without it a `.file` of
#             `src/a.js:10:correctness` with an empty `.category` concatenates to
#             exactly another finding's fingerprint, forging a C6 match with no
#             newline involved at all.
#
# `field` PERCENT-ENCODES rather than substituting, because the fingerprint's
# correctness requirement is INJECTIVITY: distinct triples must produce distinct
# strings. A many-to-one sanitizer forges C6 matches by collision instead of by
# injection — the earlier `gsub(":";"_")` mapped `a:b` and `a_b` to one
# fingerprint, and underscores are common enough in real paths that this was
# reachable by accident, not only adversarially (#618). Percent-encoding is
# reversible, so no two inputs can share an output.
#
# Order is load-bearing: `%` is encoded FIRST, which makes the escape alphabet
# itself injective — a literal `a%3Ab` becomes `a%253Ab`, distinct from the
# encoding of `a:b` (`a%3Ab`). Encode `:` first and the two re-collide.
#
# `field` deliberately does NOT derive from `flat`: `flat` maps a newline and a
# literal space to the same space, so building on it would leave `field`
# many-to-one on that pair. It encodes the record separators itself.
#
# Both filters default a MISSING value with an explicit `. == null` test rather
# than `// ""`. jq's `//` fires on `false` as well as `null`, so a boolean-`false`
# field would coerce to `""` — indistinguishable from an absent one, which is a
# many-to-one map and so the same injectivity break the encoding exists to close.
# The explicit test stringifies `false` to the distinct text "false".
FLATTEN='def orblank: if . == null then "" else . end;
         def flat: orblank | tostring | gsub("[\n\r]";" ");
         def field: orblank | tostring
                    | gsub("%";"%25") | gsub(":";"%3A")
                    | gsub("\n";"%0A") | gsub("\r";"%0D");'

fingerprints() {
    command printf '%s' "$1" |
        command jq -r "$FLATTEN"'.[] | "\(.file | field):\(.line_start // 0):\(.category | field)"'
}

# no_review_signal <file> — echo `true` when the harness marked this cycle as
# having produced no review signal at all (it died before any dimension ran),
# else `false`. Absent field => false, so a result from a harness predating #616
# reads as an ordinary cycle rather than silently becoming uncharged.
#
# Only a literal JSON `true` counts. `jq`'s truthiness would accept any non-null
# non-false value, which would let a string "false" — the shape a shell-templated
# result file most plausibly gets wrong — read as no-signal and stop charging the
# cycle cap. The strict `== true` test keeps the uncharged path reachable only by
# the harness's own boolean.
#
# The `type == "object"` guard is not redundant: indexing a non-object with a
# string is a jq ERROR (exit 5), not a false, so without it a top-level array or
# scalar would abort the script with an uncaught jq diagnostic instead of the
# `die`-formatted exit 2 this script contracts for. Today `read_findings` runs
# first and already rejects such a file, so the guard is defence in depth — but
# relying on that ordering means any future reshuffle of these two calls silently
# converts a fail-loud path into a bare jq crash. Make this function correct on
# its own inputs rather than correct by virtue of its caller.
no_review_signal() {
    command jq -r 'if (type == "object" and .no_review_signal == true)
                   then "true" else "false" end' "$1"
}

# convergence_rule — evaluate the CONVERGENCE rules C2..C8 (i.e. everything the
# cap outranks) and echo `rule|verdict|reason`.
#
# Extracted so the C1 branch can ask "what would have decided here?" by calling
# the SAME code that decides normally. A second, hand-copied condition chain for
# `capped_over` would be free to drift from the real one — and a drifted copy is
# worse than no field at all, since it would misreport exactly the case the
# operator consults it for (#635).
#
# Reads the caller's already-computed signals from the enclosing scope
# (`partial`, `total`, `delta_lines`, `prev_delta_lines`, `ratio`, `refuted`,
# `duplicate`, `recursive`) rather than taking nine positional arguments, which
# in bash-3.2 would be its own class of ordering bug.
convergence_rule() {
    if [ "$partial" = "true" ]; then
        # C2: a partial cycle is not a converged one. Its counts describe the
        # dimensions that ran, not the review — the same reason `clean` is forced
        # false on budget exhaustion. Never let one end the loop.
        command printf 'C2-partial|continue|partial'
    elif [ "$total" -eq 0 ] && [ -n "$prev_delta_lines" ] &&
        [ $((delta_lines * 100)) -lt $((prev_delta_lines * ratio)) ]; then
        # C3: the #568 case, and the refinement the issue turns on (AC#2). A zero
        # only means "reviewers found nothing HERE" — if `here` was a fraction of
        # the previous surface, it says nothing about the material still
        # unreviewed. Withhold termination.
        command printf 'C3-narrow-zero|continue|narrow-surface-zero'
    elif [ "$total" -eq 0 ]; then
        # C4: zero on a comparable-or-larger surface (including cycle 1, where the
        # surface is the whole diff and there is no predecessor). This is the
        # #564 case — clean at cycle 1, where cycles 2-3 were pure cost.
        command printf 'C4-zero|stop|zero-comparable-surface'
    elif [ "$refuted" -eq "$total" ]; then
        # C5: the strongest signal in the batch (#555 cycle 3) — a cycle whose
        # only output did not survive verification is reviewers out of material.
        command printf 'C5-refuted-only|stop|refuted-only'
    elif [ "$duplicate" -eq "$total" ]; then
        # C6: nothing new, only earlier findings restated (#533 cycle 5, where 3
        # of 4 findings were one point seen from different dimensions).
        command printf 'C6-duplicate|stop|duplicate-findings'
    elif [ "$recursive" -eq "$total" ]; then
        # C7: findings about the machinery the last fix added (#498 cycle 4).
        # This class has no fixed point, so it is termination, not progress.
        command printf 'C7-recursive|stop|recursive-test-machinery'
    else
        # C8: novel, non-duplicative material remains. Unconditional, so the rule
        # list is total.
        command printf 'C8-novel|continue|novel-material'
    fi
}

cmd_check() {
    cycle="$(opt --cycle -- "$@" || true)"
    max_cycles="$(opt --max-cycles -- "$@" || true)"
    result="$(opt --result -- "$@" || true)"
    delta_lines="$(opt --delta-lines -- "$@" || true)"
    prev_delta_lines="$(opt --prev-delta-lines -- "$@" || true)"
    delta_files="$(opt --delta-files -- "$@" || true)"
    partial="$(opt --partial -- "$@" || true)"
    attempt="$(opt --attempt -- "$@" || true)"
    max_attempts="$(opt --max-attempts -- "$@" || true)"

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

    # --attempt defaults to --cycle: a caller that has not adopted the #616
    # attempt/cycle split passes only --cycle, and with the two equal the C0
    # ceiling sits at 2x the cycle cap and never fires before C1. So the new
    # rules are inert for an un-migrated caller rather than changing its
    # verdicts — the same additive posture as the #492 delta args.
    if [ -z "$attempt" ]; then
        attempt="$cycle"
    fi
    if ! is_nonneg_int "$attempt" || [ "$attempt" -lt 1 ]; then
        die "review-convergence: --attempt must be an integer >= 1, got '$attempt'"
    fi
    if [ -z "$max_attempts" ]; then
        max_attempts="${REVIEW_MAX_ATTEMPTS:-$((max_cycles * 2))}"
    fi
    if ! is_nonneg_int "$max_attempts" || [ "$max_attempts" -lt 1 ]; then
        die "review-convergence: --max-attempts must be an integer >= 1, got '$max_attempts'"
    fi
    # An attempts ceiling below the cycles ceiling makes C1 unreachable — the
    # loop would always die at C0 first, silently converting every cycle cap into
    # an attempt cap and discarding the convergence policy. That is a
    # misconfiguration, not a policy choice, so it fails loud rather than
    # quietly clamping (which would hide the operator's mistake).
    if [ "$max_attempts" -lt "$max_cycles" ]; then
        die "review-convergence: --max-attempts ($max_attempts) must be >= --max-cycles ($max_cycles), or the cycle cap is unreachable"
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
    # Read AFTER read_findings, which is what validates the file is readable and
    # parseable — so a malformed result still fails loud there rather than
    # reaching a bare `jq` here that would emit "false" and quietly proceed.
    no_signal="$(no_review_signal "$result")"

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
    # `capped_over` is empty for every rule but C1, where it names what C1
    # concealed. Set once here so each branch below need not clear it.
    capped_over=""
    if [ "$attempt" -ge "$max_attempts" ]; then
        # C0: the absolute ceiling, in ATTEMPTS rather than reviewed cycles. This
        # is what guarantees termination now that C0b can decline to charge the
        # cycle cap — a persistently crashing harness stops here (#616).
        rule="C0-attempt-cap"
        verdict="stop"
        reason="attempt-cap"
    elif [ "$no_signal" = "true" ]; then
        # C0b: the cycle died before any dimension ran, so it is not a data point
        # about convergence in either direction. Continue WITHOUT the caller
        # charging a cycle — see the header for why charging it makes a crashed
        # cycle indistinguishable from a substantive one at the cap (#616).
        rule="C0b-no-signal"
        verdict="continue"
        reason="no-review-signal"
    elif [ "$cycle" -ge "$max_cycles" ]; then
        # C1: the cycle ceiling. Outranks every convergence signal (C2-C8) so the
        # loop still terminates on reviewed cycles alone (#596 AC#3).
        #
        # Evaluate the convergence rules anyway and report what WOULD have
        # decided: a stop here says only "out of budget", and without this field
        # a caller cannot tell it from a genuine C4-zero convergence (#635).
        rule="C1-cap"
        verdict="stop"
        reason="cap"
        _cr="$(convergence_rule)"
        capped_over="${_cr%%|*}"
    else
        _cr="$(convergence_rule)"
        rule="${_cr%%|*}"
        _cr="${_cr#*|}"
        verdict="${_cr%%|*}"
        reason="${_cr#*|}"
    fi

    command printf 'verdict=%s\n' "$verdict"
    command printf 'rule=%s\n' "$rule"
    command printf 'capped_over=%s\n' "$capped_over"
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
