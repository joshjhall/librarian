#!/usr/bin/env bash
# review-engagement — MEASURE each review dimension's engagement from the
# Workflow run's transcript, and fold it into the cycle result (issue #1111).
#
# Why this runs OUTSIDE the harness. ship-issue/workflow.js cannot see what its
# own dimensions did: `agent()` returns only the schema-validated object (no
# usage, no tool calls), and `budget.spent()` is pooled across the turn, so it
# cannot attribute tokens to one dimension inside a parallel() barrier (probed
# live, #1111). The real counts exist only in the transcript dir the Workflow
# tool prints: per agent, `agent-<id>.meta.json` carries `description`
# (`review:<dim>`) and `model`, and `agent-<id>.jsonl` carries every assistant
# message's `tool_use` blocks and `usage.output_tokens`.
#
# What it does to the result JSON (rewritten in place):
#   dimension_metrics.<dim> = [{tool_calls, output_tokens, model}, ...]
#       one entry per agent run in transcript order — two when the harness
#       spent its opus re-dispatch. `tool_calls` excludes StructuredOutput.
#   unengaged_dimensions / dimensions_skipped  += <dim>, clean = false,
#   budget_exhausted = true — when the dimension's LAST run made ZERO
#       investigative tool calls, contributed NO finding, AND the harness marked
#       it `requires_code_reading`. That is the issue's measured signature (one
#       StructuredOutput call, ~53 tokens) and it catches a model that filled in
#       `checked` without opening anything. The `requires_code_reading` gate is
#       the operator's correction: scope-drift and decomposition are legitimately
#       diff-only, and flagging them would block convergence forever. The flag
#       comes from the harness's CODE_READING_DIMENSIONS, so this script keeps no
#       copy of that list to drift.
#   engagement_measured = true | false
#
# Failure posture:
#   - unreadable dir or result, or jq missing  -> exit 2, result untouched.
#   - a dir with NO review:* agents            -> exit 0, engagement_measured:
#       false, and a WARNING on stderr. A scan that looked at nothing must not
#       read as "every dimension engaged".
#
# Usage: review-engagement.sh <transcript-dir> <result.json>
# Emits key=value lines: measured, dimensions, unengaged.

set -euo pipefail

USAGE="Usage: review-engagement.sh <transcript-dir> <result.json>"

die() {
    command printf '%s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

[ "$#" -eq 2 ] || die "review-engagement: expected 2 arguments, got $#"
dir="$1"
result="$2"

command -v jq >/dev/null 2>&1 ||
    die "review-engagement: jq is required to read transcripts but was not found on PATH"
[ -d "$dir" ] && [ -r "$dir" ] || die "review-engagement: transcript dir '$dir' is not a readable directory"
[ -f "$result" ] && [ -r "$result" ] || die "review-engagement: result file '$result' is not readable"
command jq -e 'type == "object"' "$result" >/dev/null 2>&1 ||
    die "review-engagement: result file '$result' is not a JSON object"

# One TSV row per review agent: dim, tool_calls, output_tokens, model.
# Rows are emitted in meta-file name order, which is NOT run order; the run
# order comes from the journal's `started` lines when present (below).
rows="$(command mktemp)"
order="$(command mktemp)"
tmp_out="$(command mktemp)"
tmp_ua="$(command mktemp)"
tmp_final="$(command mktemp)"
# shellcheck disable=SC2064  # expand the paths now, at trap-set time
trap "command rm -f '$rows' '$order' '$tmp_out' '$tmp_ua' '$tmp_final'" EXIT

# Dispatch order: the journal records `started` with each agentId in order. It
# only makes `dimension_metrics` read chronologically; the unengaged decision
# below does NOT depend on it. Absent journal -> meta-file name order, which
# is effectively random (ids are `a` + hex).
if [ -r "$dir/journal.jsonl" ]; then
    command jq -r 'select(.type == "started") | .agentId' "$dir/journal.jsonl" 2>/dev/null >"$order" || : >"$order"
fi

emit_row() {
    # $1 = agent id. Reads its meta + jsonl; prints a row if it is a review agent.
    local id="$1" meta jsonl desc dim model
    # The id comes from journal.jsonl content and becomes part of a path, so a
    # `/` or `..` in it would read a file outside the transcript dir. Real ids
    # are `a` + hex; accept only that alphabet (a case glob: bash-3.2 and BSD
    # safe, no regex engine).
    case "$id" in
        '' | *[!A-Za-z0-9_-]*) return 0 ;;
    esac
    meta="$dir/agent-$id.meta.json"
    jsonl="$dir/agent-$id.jsonl"
    [ -r "$meta" ] && [ -r "$jsonl" ] || return 0
    desc="$(command jq -r '.description // ""' "$meta")"
    case "$desc" in
        review:*) dim="${desc#review:}" ;;
        *) return 0 ;;
    esac
    # The model is read from the transcript's own `message.model` — the model
    # that actually answered. `meta.json` carries a `model` key only when the
    # dispatch passed an explicit override (measured on a live review run: an
    # inheriting dimension's meta has none), so it is the fallback, not the source.
    model="$(command jq -r '.model // ""' "$meta")"
    # Same reading idiom as golem-token-scrape.sh: `-R` + `fromjson?` skips a
    # partial trailing line (a transcript captured mid-write), and usage — which
    # repeats once per content block — is summed ONE value per message.id, with
    # an id-less record keyed uniquely rather than collapsed. tool_use blocks are
    # counted per block, since each block is one call.
    command jq -R -s -r --arg dim "$dim" --arg model "$model" '
        [ split("\n")[] | select(length > 0) | (fromjson? // empty)
          | select(.type == "assistant") | .message ] as $msgs
        | ([ $msgs[] | (.content // []) | if type == "array" then .[] else empty end
             | select(.type == "tool_use" and .name != "StructuredOutput") ] | length) as $tools
        | ([ $msgs | to_entries[] | select(.value.usage.output_tokens != null) ]
             | group_by(.value.id // "__noid__\(.key)")
             | map(.[0].value.usage.output_tokens) | add // 0) as $tokens
        | ([ $msgs[] | .model // empty ] | last // (if $model == "" then "unknown" else $model end)) as $m
        | [$dim, ($tools | tostring), ($tokens | tostring), $m] | @tsv
    ' "$jsonl"
}

seen=" "
while IFS= read -r id; do
    [ -n "$id" ] || continue
    seen="$seen$id "
    emit_row "$id" >>"$rows"
done <"$order"
for meta in "$dir"/agent-*.meta.json; do
    [ -e "$meta" ] || continue
    id="${meta##*/agent-}"
    id="${id%.meta.json}"
    case "$seen" in
        *" $id "*) continue ;;
    esac
    emit_row "$id" >>"$rows"
done

if [ ! -s "$rows" ]; then
    command printf 'WARNING: review-engagement: no review:* agents in %s — engagement NOT measured\n' "$dir" >&2
    command jq '.engagement_measured = false' "$result" >"$tmp_out"
    command cat "$tmp_out" >"$result"
    command printf 'measured=false\ndimensions=0\nunengaged=0\n'
    exit 0
fi

# Fold the rows into the result. A code-reading dimension that produced no
# finding is flagged when the run whose answer the harness KEPT made zero
# investigative tool calls. Already-flagged dimensions are not duplicated.
#
# Which run was kept is decided WITHOUT run order (cycle-6 review: `[-1]` read
# "last" from file-name order whenever the journal was absent, and could judge
# the sonnet run while the harness had kept an engaged opus retry):
#   - one run                        -> that run.
#   - several, harness says the opus  -> the opus-model run(s); the retry is the
#     retry succeeded (retry_succeeded)   only `opus` dispatch, so model, not
#                                         position, identifies it.
#   - several, retry did not succeed  -> the non-opus run(s): the sonnet result
#                                         stayed in place.
#   - several, no harness signal      -> flag only if EVERY run made zero calls,
#     (an older harness)                  so ambiguity can never manufacture an
#                                         unengaged verdict.
#   - several, harness signal, but    -> the no-signal rule above, plus a
#     NO run matches its model filter     WARNING naming the dimension (#1133):
#     (usually a model read `unknown`)    an empty subset used to SKIP the
#                                         dimension, so an unengaged kept retry
#                                         went unflagged.
command jq --rawfile rows "$rows" '
    ($rows | split("\n") | map(select(length > 0) | split("\t")
        | {dim: .[0], tool_calls: (.[1] | tonumber), output_tokens: (.[2] | tonumber), model: .[3]})) as $r
    | (reduce $r[] as $x ({}; .[$x.dim] += [$x | del(.dim)])) as $metrics
    # "Produced a finding" comes from the RAW per-dimension count the harness records
    # (dimension_engagement.<dim>.findings) when present: the post-judge arrays
    # agree only while the judge drops nothing, which this script must not
    # silently depend on. A result without that count (an older harness) falls
    # back to the arrays.
    | ([(.blocking // [])[], (.deferrable // [])[]] | map(.dimension) | unique) as $inArrays
    | (.dimension_engagement // {}) as $engRaw
    | ([$engRaw | to_entries[] | select((.value.findings // 0) > 0) | .key] + $inArrays | unique) as $withFindings
    | (.dimension_engagement // {}) as $eng
    | ([$metrics | to_entries[] | . as $e
        | ($eng[$e.key] // {}) as $de
        | ($e.value | if length == 1 then .
            elif $de.retry_succeeded == true then map(select(.model | test("opus")))
            elif $de.retry_attempted == true then map(select(.model | test("opus") | not))
            else . end) as $selected
        | {key: $e.key, unattributed: (($selected | length) == 0),
           kept: (if ($selected | length) > 0 then $selected else $e.value end)}]) as $judged
    | ([$judged[] | select(.kept | all(.tool_calls == 0)) | .key as $k
        | select(($withFindings | index($k)) == null)
        | select($eng[$k].requires_code_reading == true)
        | $k]) as $flag
    | ([$judged[] | select(.unattributed) | .key]) as $unattributed
    | .dimension_metrics = $metrics
    | .engagement_measured = true
    | ._unattributed = $unattributed
    | .unengaged_dimensions = (((.unengaged_dimensions // []) + $flag) | unique)
    | .dimensions_skipped = (((.dimensions_skipped // []) + $flag) | unique)
    | if ($flag | length) > 0 then .clean = false | .budget_exhausted = true else . end
' "$result" >"$tmp_out" || die "review-engagement: failed to fold metrics into '$result'"
# The fold hands the fallback dims out through a scratch key (jq's `stderr`
# builtin varies by version); warn on each, then strip the key. Both reads
# finish into temp files BEFORE "$result" is touched, so a jq failure here
# dies with the result untouched rather than truncated.
command jq -r '._unattributed[]' "$tmp_out" >"$tmp_ua" ||
    die "review-engagement: failed to read unattributed dimensions from the fold"
command jq 'del(._unattributed)' "$tmp_out" >"$tmp_final" ||
    die "review-engagement: failed to strip the scratch key from the fold"
while IFS= read -r ua; do
    command printf 'WARNING: review-engagement: no run of %s matched the kept-run model filter (model unattributable?) — judged on every run\n' "$ua" >&2
done <"$tmp_ua"
command cat "$tmp_final" >"$result"

command printf 'measured=true\n'
command printf 'dimensions=%s\n' "$(command jq -r '.dimension_metrics | length' "$result")"
command printf 'unengaged=%s\n' "$(command jq -r '.unengaged_dimensions | length' "$result")"
