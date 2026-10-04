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
# shellcheck disable=SC2064  # expand the paths now, at trap-set time
trap "command rm -f '$rows' '$order' '$tmp_out'" EXIT

# Run order: the journal records `started` with each agentId in dispatch order.
# Absent journal -> fall back to file-name order (an opus retry is then not
# guaranteed to be last; the harness's own `dimension_engagement.retried` still
# says whether one ran).
if [ -r "$dir/journal.jsonl" ]; then
    command jq -r 'select(.type == "started") | .agentId' "$dir/journal.jsonl" 2>/dev/null >"$order" || : >"$order"
fi

emit_row() {
    # $1 = agent id. Reads its meta + jsonl; prints a row if it is a review agent.
    local id="$1" meta jsonl desc dim model
    meta="$dir/agent-$id.meta.json"
    jsonl="$dir/agent-$id.jsonl"
    [ -r "$meta" ] && [ -r "$jsonl" ] || return 0
    desc="$(command jq -r '.description // ""' "$meta")"
    case "$desc" in
        review:*) dim="${desc#review:}" ;;
        *) return 0 ;;
    esac
    model="$(command jq -r '.model // "unknown"' "$meta")"
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
        | [$dim, ($tools | tostring), ($tokens | tostring), $model] | @tsv
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

# Fold the rows into the result. A dimension is flagged when its LAST run had
# zero investigative tool calls, the cycle carries no finding from it, and the
# harness says it must read code. Already-flagged dimensions are not duplicated.
command jq --rawfile rows "$rows" '
    ($rows | split("\n") | map(select(length > 0) | split("\t")
        | {dim: .[0], tool_calls: (.[1] | tonumber), output_tokens: (.[2] | tonumber), model: .[3]})) as $r
    | (reduce $r[] as $x ({}; .[$x.dim] += [$x | del(.dim)])) as $metrics
    | ([(.blocking // [])[], (.deferrable // [])[]] | map(.dimension) | unique) as $withFindings
    | (.dimension_engagement // {}) as $eng
    | ([$metrics | to_entries[] | . as $e
        | select($e.value[-1].tool_calls == 0)
        | select(($withFindings | index($e.key)) == null)
        | select($eng[$e.key].requires_code_reading == true)
        | $e.key]) as $flag
    | .dimension_metrics = $metrics
    | .engagement_measured = true
    | .unengaged_dimensions = (((.unengaged_dimensions // []) + $flag) | unique)
    | .dimensions_skipped = (((.dimensions_skipped // []) + $flag) | unique)
    | if ($flag | length) > 0 then .clean = false | .budget_exhausted = true else . end
' "$result" >"$tmp_out" || die "review-engagement: failed to fold metrics into '$result'"
command cat "$tmp_out" >"$result"

command printf 'measured=true\n'
command printf 'dimensions=%s\n' "$(command jq -r '.dimension_metrics | length' "$result")"
command printf 'unengaged=%s\n' "$(command jq -r '.unengaged_dimensions | length' "$result")"
