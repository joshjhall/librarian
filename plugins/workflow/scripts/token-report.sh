#!/usr/bin/env bash
# token-report.sh — per-model token/cost measurement over the Bifrost gateway's
# aggregate `/api/logs/stats` endpoint, with a reconciliation guard that makes a
# silently-dropped filter param impossible to report as a real number (#781).
#
# WHY THIS EXISTS. Issues #782–#788 are token-efficiency changes; none can be
# judged without a clean per-model before/after. The fleet baseline that motivated
# them was derived by ad-hoc curl+python against an endpoint found by guessing
# paths, and two properties made that un-repeatable:
#
#   1. `/api/logs` pagination is unusable for aggregation — ~52s per 500-row page,
#      ~50 minutes to walk a 29k-row day. `/api/logs/stats` returns the same
#      totals in ONE call (~16ms measured), which is why this tool speaks only to
#      the aggregate endpoint and never paginates.
#
#   2. `?models=<name>` filters; `?model=<name>` is SILENTLY IGNORED. The singular
#      spelling returns the *unfiltered* total with HTTP 200 — a wrong number that
#      reads as right, and one that looks plausible beside a filtered figure
#      (measured live: on a single-model query the singular spelling overstated
#      the request count by 4.0x). The trap is not limited to that one typo: an
#      entirely bogus `?zzznotaparam=1` also returns the unfiltered total, so ANY
#      dropped or renamed param degrades the same silent way.
#
# THE GUARD. Because (2) fails silently, correctness cannot rest on spelling the
# param right. After collecting per-model rows this tool queries the SAME window
# unfiltered and requires the per-model request counts to sum to the unfiltered
# total within TOKEN_REPORT_RECONCILE_PCT. A dropped filter makes every per-model
# query return the unfiltered total, so the sum overshoots by ~N-fold and the run
# fails loudly (exit 1) instead of emitting a number that silently compares
# all-models against one-model.
#
# The tolerance is headroom rather than an observed need: measured against the
# live gateway with a COMPLETE model list, a window reconciles EXACTLY (delta 0).
# It exists so a request the gateway attributes to no model cannot turn a healthy
# window into a hard failure. It must stay far below the N-fold gap a dropped
# filter opens — measured at a 14x overstatement on a full-fleet window.
#
# NOTE the guard needs >= 2 models to bite. With one model, "unfiltered total" and
# "that model's total" are the same number under a dropped filter, so the sum
# reconciles exactly and the breach is invisible. This is a property of the check,
# not a bug — but it is why the gate's mutation case must use two models, and why
# `window` warns when reconciling a single-model run.
#
# THE HEADLINE METRIC is avg_prompt_per_request (prompt_tokens / requests), not
# cost: cost moves with how hard the fleet is pushed, but the average isolates an
# efficiency change from a workload change. Every downstream issue is judged on
# it, so it is a first-class emitted column rather than something each consumer
# re-derives.
#
# Config (see config.sh for the authoritative documentation):
#   BIFROST_URL                 Gateway ADMIN API root. REQUIRED, no default.
#                               NOT ANTHROPIC_BASE_URL — that is the proxy path
#                               and answers /api/logs/stats with HTML + HTTP 200.
#   TOKEN_REPORT_TIMEOUT        Per-request timeout, seconds.       Default: 30
#   TOKEN_REPORT_RECONCILE_PCT  Tolerance, percent of total.        Default: 0.5
#
# Usage:
#   token-report.sh window --start <ISO> --end <ISO> [--models a,b] [--json]
#   token-report.sh compare --baseline <file> --compare <file> [--percent-only]
#   token-report.sh reconcile --start <ISO> --end <ISO> [--models a,b]
#
# PUBLISHING NOTE. `window` output and the default `compare` output carry raw
# request counts, token volumes and dollar figures — fleet-wide spend data. This
# repo is public, so those belong in /tmp, not in a commit or an issue. Use
# `compare --percent-only` for anything published: it prints percentage deltas
# alone, which is what the #782–#788 series is judged on anyway (see
# docs/verification/token-baseline-tally-781.md § Why no absolute figures).
#
# Output (window): the TSV contract #788 and the compare path both consume —
#   window_start<TAB>model<TAB>requests<TAB>prompt_tokens<TAB>completion_tokens<TAB>cost<TAB>avg_prompt_per_request
# preceded by `#`-prefixed comment lines (header + window metadata), so a
# consumer strips /^#/ and reads positional fields.
#
# Exit status — the distinction is the point (repo convention #538/#571):
#   0   rows written / reconciliation passed
#   1   RECONCILIATION FAILED, or model enumeration truncated. A real, loud
#       failure: the data is wrong, not absent.
#   2   usage error, including BIFROST_URL unset
#   3   a required dependency is missing from PATH (jq or curl). One code for
#       both: the operator response is identical — install the named tool — and
#       the stderr message always says which one is absent.
#   77  gateway UNREACHABLE — the reserved skip sentinel. An unavailable gateway
#       is a skipped gate, never a pass; run-all.sh renders it "[SKIP] … did not
#       run" rather than "[ok]". Deliberately NOT reachable from a reconciliation
#       breach: "I could not measure" and "I measured, and it is wrong" must never
#       collapse into one code.
#
# Portability: bash-3.2 clean (no declare -A / mapfile / namerefs / ${v,,}), BSD
# regex clean (POSIX classes, -E, no grep -P), coreutils via the `command`
# builtin. jq is a hard dependency that fails loud (exit 3), following
# golem-token-scrape.sh; the python-primary/bash-fallback rule governs the
# patterns.sh pre-scan family, not these scripts.
set -uo pipefail

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

EXIT_FAIL=1
EXIT_USAGE=2
EXIT_NO_DEPS=3
EXIT_UNREACHABLE=77

# Model-enumeration page size. /api/models SILENTLY TRUNCATES to a small page
# without an explicit limit — measured: 5 models returned while the body's own
# `total` field said 14 — so we always ask for a generous page AND verify the
# returned count against that `total` (see enumerate_models). Same
# silent-truncation class this tool exists to catch.
MODELS_LIMIT=1000

die() {
    command printf 'token-report: %s\n' "$1" >&2
    exit "$2"
}

usage() {
    command cat >&2 <<'EOF'
usage: token-report.sh <command> [options]

Commands:
  window     --start <ISO> --end <ISO> [--models a,b] [--json]
             Per-model breakdown for a window, reconciled against the
             unfiltered total. Emits the TSV (or JSON) contract on stdout.

  compare    --baseline <file> --compare <file> [--percent-only]
             Per-model deltas between two window files: requests, tokens,
             cost, and average prompt tokens per request. --percent-only
             omits absolute deltas, leaving output safe to publish.

  reconcile  --start <ISO> --end <ISO> [--models a,b]
             Run only the reconciliation guard; print the verdict.

Environment:
  BIFROST_URL                 Gateway admin API root (REQUIRED; no default).
                              Not ANTHROPIC_BASE_URL — that is the proxy path.
  TOKEN_REPORT_TIMEOUT        Per-request timeout, seconds (default 30).
  TOKEN_REPORT_RECONCILE_PCT  Tolerance, percent of total (default 0.5).

Exit: 0 ok · 1 reconciliation failed · 2 usage · 3 missing jq/curl · 77 gateway unreachable
EOF
}

# --- preflight ----------------------------------------------------------------

require_jq() {
    command -v jq >/dev/null 2>&1 ||
        die "jq not found on PATH — cannot parse gateway JSON" "$EXIT_NO_DEPS"
}

require_curl() {
    command -v curl >/dev/null 2>&1 ||
        die "curl not found on PATH — cannot reach the gateway" "$EXIT_NO_DEPS"
}

# require_base_url — validate BIFROST_URL in the CALLER'S shell, at preflight.
#
# Unset is a USAGE error, not a skip: a missing config is the operator's to fix,
# whereas 77 means "configured correctly, gateway is down". Collapsing them would
# let a forgotten export read as a clean skip forever.
#
# This MUST run at preflight rather than lazily inside base_url, because base_url
# is called from within `$( )`. A `die` there exits only the SUBSHELL — the caller
# then proceeds with an empty URL, curl fails to connect, and the run reports 77.
# Verified before the fix: an unset BIFROST_URL exited 77 instead of 2, silently
# converting a misconfiguration into a skip. The subshell cannot fail the script,
# so the check belongs where it can.
require_base_url() {
    if [ -z "${BIFROST_URL:-}" ]; then
        die "BIFROST_URL is not set — point it at the Bifrost gateway ADMIN root
  (e.g. BIFROST_URL=https://bifrost.example). Note this is NOT ANTHROPIC_BASE_URL:
  that variable addresses the proxy path, whose /api/logs/stats returns the web
  UI's HTML with HTTP 200 rather than JSON." "$EXIT_USAGE"
    fi
}

# base_url — the gateway root, trailing slash stripped. Safe to call from a
# subshell: require_base_url has already guaranteed the variable is set.
base_url() {
    command printf '%s' "${BIFROST_URL%/}"
}

# --- gateway I/O --------------------------------------------------------------

# api_get <path-with-query> — GET the gateway, echo the body on stdout.
#
# Separates the two failure modes the exit table keeps apart. A transport failure
# (curl non-zero: DNS, refused, timeout) is UNREACHABLE → 77. A reply that is not
# JSON is a real failure → 1, because the gateway answered and the answer is
# wrong; the overwhelmingly likely cause is BIFROST_URL aimed at the proxy path,
# which serves the SPA's HTML shell with HTTP 200, so the message says so.
api_get() {
    local path="$1" url body http rc
    url="$(base_url)$path"

    body="$(command curl -s \
        --connect-timeout "$TOKEN_REPORT_TIMEOUT" \
        -m "$TOKEN_REPORT_TIMEOUT" \
        -H 'Accept: application/json' \
        -w '\n%{http_code}' \
        "$url" 2>/dev/null)"
    rc=$?

    if [ "$rc" -ne 0 ]; then
        die "gateway unreachable at $(base_url) (curl exit $rc) — skipping, not passing" \
            "$EXIT_UNREACHABLE"
    fi

    http="${body##*$'\n'}"
    body="${body%$'\n'*}"

    if [ "$http" = "000" ]; then
        die "gateway unreachable at $(base_url) (no HTTP response) — skipping, not passing" \
            "$EXIT_UNREACHABLE"
    fi

    case "$http" in
        2*) ;;
        *) die "gateway returned HTTP $http for $path" "$EXIT_FAIL" ;;
    esac

    if ! command printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
        die "gateway returned non-JSON for $path (HTTP $http).
  If BIFROST_URL points at the proxy path (…/anthropic) rather than the gateway
  root, /api/logs/stats serves the web UI's HTML with HTTP 200 — a silent wrong
  answer. Point BIFROST_URL at the admin root." "$EXIT_FAIL"
    fi

    command printf '%s' "$body"
}

# stats_query <start> <end> [model] — echo one stats object.
# The model filter uses the PLURAL `models=` param. The singular `model=` is
# accepted and silently ignored by the gateway, returning the unfiltered total;
# the reconciliation guard exists because this line cannot be trusted on sight.
stats_query() {
    local start="$1" end="$2" model="${3:-}" q
    q="start_time=$start&end_time=$end"
    [ -n "$model" ] && q="$q&models=$model"
    api_get "/api/logs/stats?$q"
}

# enumerate_models — echo one model name per line.
#
# Passes an explicit limit AND asserts the returned count matches the body's own
# `total`. Without the limit the endpoint returns a truncated page while still
# reporting the full total (measured: 5 returned, "total": 14) — a silent
# truncation that would drop whole models from the breakdown and, worse, from the
# reconciliation sum, manufacturing a breach out of a complete dataset. Failing
# loud here is what keeps the guard's verdict meaningful.
enumerate_models() {
    local body count total
    body="$(api_get "/api/models?limit=$MODELS_LIMIT")" || exit $?

    count="$(command printf '%s' "$body" | jq -r '.models | length')"
    total="$(command printf '%s' "$body" | jq -r '.total // (.models | length)')"

    if [ "$count" != "$total" ]; then
        die "model enumeration truncated: got $count of $total models from /api/models.
  A truncated list drops models from the breakdown AND from the reconciliation
  sum, so the guard would report a breach on complete data. Raise MODELS_LIMIT
  or pass --models explicitly." "$EXIT_FAIL"
    fi

    command printf '%s' "$body" | jq -r '.models[].name'
}

# --- field extraction ---------------------------------------------------------

stat_field() {
    command printf '%s' "$1" | jq -r ".${2} // 0"
}

# avg_prompt <prompt_tokens> <requests> — integer average, 0 when no requests.
# Integer because the metric is ~150k; fractional precision is noise, and integer
# output keeps the TSV diffable.
avg_prompt() {
    local prompt="$1" requests="$2"
    if [ "$requests" = "0" ] || [ -z "$requests" ]; then
        command printf '0'
        return
    fi
    command awk -v p="$prompt" -v r="$requests" 'BEGIN { printf "%d", p / r }'
}

# --- reconciliation -----------------------------------------------------------

# reconcile_check <summed_requests> <unfiltered_requests> <model_count>
# Returns 0 within tolerance, 1 outside. Prints the verdict to stderr.
#
# THE LOAD-BEARING PREDICATE. Everything else in this script is plumbing; this is
# what makes a silently-dropped filter param impossible to report as a real
# number.
reconcile_check() {
    local summed="$1" unfiltered="$2" model_count="$3" delta tolerance

    delta="$(command awk -v a="$summed" -v b="$unfiltered" \
        'BEGIN { d = a - b; if (d < 0) d = -d; printf "%d", d }')"
    tolerance="$(command awk -v t="$unfiltered" -v p="$TOKEN_REPORT_RECONCILE_PCT" \
        'BEGIN { printf "%d", (t * p / 100) + 0.5 }')"

    if [ "$delta" -le "$tolerance" ]; then
        command printf 'token-report: reconciled — %s per-model requests vs %s unfiltered (delta %s, tolerance %s)\n' \
            "$summed" "$unfiltered" "$delta" "$tolerance" >&2
        # A single-model run cannot detect a dropped filter: the filtered and
        # unfiltered totals coincide, so the sum reconciles no matter what. Say
        # so rather than let a green verdict imply a check that did not happen.
        if [ "$model_count" -lt 2 ]; then
            command printf 'token-report: WARNING — reconciliation ran over %s model(s); it cannot detect a dropped filter param below 2. Treat this verdict as unproven.\n' \
                "$model_count" >&2
        fi
        return 0
    fi

    command printf 'token-report: RECONCILIATION FAILED — per-model requests sum to %s, unfiltered total is %s (delta %s exceeds tolerance %s at %s%%).
  Most likely a filter param was dropped or renamed: the gateway ignores an
  unrecognized query param SILENTLY and returns the UNFILTERED total with HTTP
  200, so each per-model query answered for every model at once. Verify the
  filter is spelled `models=` (plural); the singular `model=` is ignored.
  Refusing to emit numbers that would compare all-models against one-model.\n' \
        "$summed" "$unfiltered" "$delta" "$tolerance" "$TOKEN_REPORT_RECONCILE_PCT" >&2
    return 1
}

# --- commands -----------------------------------------------------------------

cmd_window() {
    local start="" end="" models="" as_json=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --start)
                start="${2:-}"
                shift 2
                ;;
            --end)
                end="${2:-}"
                shift 2
                ;;
            --models)
                models="${2:-}"
                shift 2
                ;;
            --json)
                as_json=1
                shift
                ;;
            *)
                usage
                exit "$EXIT_USAGE"
                ;;
        esac
    done

    [ -n "$start" ] && [ -n "$end" ] ||
        die "window requires --start and --end (ISO 8601, e.g. 2026-08-22T18:00:00Z)" "$EXIT_USAGE"

    require_base_url
    require_jq
    require_curl

    local model_list
    if [ -n "$models" ]; then
        model_list="$(command printf '%s' "$models" | command tr ',' '\n')"
    else
        model_list="$(enumerate_models)" || exit $?
    fi

    # Collect rows first, reconcile second, EMIT LAST. Emitting as we go would
    # print unreconciled rows before the guard could reject them — and a consumer
    # reading stdout would have already banked numbers the exit code then
    # disowns. Nothing reaches stdout until the guard passes.
    local rows="" summed=0 model_count=0
    local model body requests prompt completion cost avg

    for model in $model_list; do
        [ -n "$model" ] || continue
        body="$(stats_query "$start" "$end" "$model")" || exit $?

        requests="$(stat_field "$body" total_requests)"
        prompt="$(stat_field "$body" prompt_tokens)"
        completion="$(stat_field "$body" completion_tokens)"
        cost="$(stat_field "$body" total_cost)"

        # Skip models with no traffic in the window: they are noise in the
        # breakdown and contribute nothing to the sum.
        [ "$requests" = "0" ] && continue

        avg="$(avg_prompt "$prompt" "$requests")"
        rows="$rows$start	$model	$requests	$prompt	$completion	$cost	$avg
"
        summed="$(command awk -v a="$summed" -v b="$requests" 'BEGIN { printf "%d", a + b }')"
        model_count=$((model_count + 1))
    done

    local unfiltered_body unfiltered_requests
    unfiltered_body="$(stats_query "$start" "$end")" || exit $?
    unfiltered_requests="$(stat_field "$unfiltered_body" total_requests)"

    reconcile_check "$summed" "$unfiltered_requests" "$model_count" ||
        exit "$EXIT_FAIL"

    if [ "$as_json" -eq 1 ]; then
        command printf '%s' "$rows" | jq -R -s 'split("\n") | map(select(length > 0)) | map(split("\t")) | map({
            window_start: .[0], model: .[1],
            requests: (.[2] | tonumber), prompt_tokens: (.[3] | tonumber),
            completion_tokens: (.[4] | tonumber), cost: (.[5] | tonumber),
            avg_prompt_per_request: (.[6] | tonumber)
        })'
        return 0
    fi

    command printf '# token-report window %s .. %s\n' "$start" "$end"
    command printf '# reconciled: %s per-model requests vs %s unfiltered\n' \
        "$summed" "$unfiltered_requests"
    command printf '# window_start\tmodel\trequests\tprompt_tokens\tcompletion_tokens\tcost\tavg_prompt_per_request\n'
    command printf '%s' "$rows"
}

cmd_reconcile() {
    local start="" end="" models=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --start)
                start="${2:-}"
                shift 2
                ;;
            --end)
                end="${2:-}"
                shift 2
                ;;
            --models)
                models="${2:-}"
                shift 2
                ;;
            *)
                usage
                exit "$EXIT_USAGE"
                ;;
        esac
    done

    [ -n "$start" ] && [ -n "$end" ] ||
        die "reconcile requires --start and --end" "$EXIT_USAGE"

    require_base_url
    require_jq
    require_curl

    local model_list
    if [ -n "$models" ]; then
        model_list="$(command printf '%s' "$models" | command tr ',' '\n')"
    else
        model_list="$(enumerate_models)" || exit $?
    fi

    local summed=0 model_count=0 model body requests
    for model in $model_list; do
        [ -n "$model" ] || continue
        body="$(stats_query "$start" "$end" "$model")" || exit $?
        requests="$(stat_field "$body" total_requests)"
        [ "$requests" = "0" ] && continue
        summed="$(command awk -v a="$summed" -v b="$requests" 'BEGIN { printf "%d", a + b }')"
        model_count=$((model_count + 1))
    done

    local unfiltered_body unfiltered_requests
    unfiltered_body="$(stats_query "$start" "$end")" || exit $?
    unfiltered_requests="$(stat_field "$unfiltered_body" total_requests)"

    reconcile_check "$summed" "$unfiltered_requests" "$model_count" ||
        exit "$EXIT_FAIL"
}

# cmd_compare — per-model deltas between two window files.
#
# Reads TSVs (skipping `#` comments), joins on model name, and prints requests,
# prompt-token, cost, and avg-prompt-per-request deltas with percentages. The
# avg row is the one that matters: it isolates an efficiency change from a
# workload change, so it is printed even for models present in only one file.
cmd_compare() {
    local baseline="" compare="" percent_only=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --baseline)
                baseline="${2:-}"
                shift 2
                ;;
            --compare)
                compare="${2:-}"
                shift 2
                ;;
            --percent-only)
                percent_only=1
                shift
                ;;
            *)
                usage
                exit "$EXIT_USAGE"
                ;;
        esac
    done

    [ -n "$baseline" ] && [ -n "$compare" ] ||
        die "compare requires --baseline <file> and --compare <file>" "$EXIT_USAGE"
    [ -r "$baseline" ] || die "baseline file not readable: $baseline" "$EXIT_USAGE"
    [ -r "$compare" ] || die "compare file not readable: $compare" "$EXIT_USAGE"

    command awk -F'\t' -v percent_only="$percent_only" '
        function pct(a, b) { return (b == 0) ? "n/a" : sprintf("%+.1f%%", (a - b) * 100.0 / b) }
        function sign(x)   { return sprintf("%+d", x) }
        FNR == NR {
            if ($0 ~ /^#/ || NF < 7) next
            b_req[$2] = $3; b_prompt[$2] = $4; b_cost[$2] = $6; b_avg[$2] = $7
            seen[$2] = 1
            next
        }
        {
            if ($0 ~ /^#/ || NF < 7) next
            c_req[$2] = $3; c_prompt[$2] = $4; c_cost[$2] = $6; c_avg[$2] = $7
            seen[$2] = 1
        }
        END {
            printf "%-28s %14s %14s %12s %10s\n", "model", "requests", "prompt_tokens", "cost", "avg/req"
            for (m in seen) {
                # --percent-only folds the percentages onto the model row and
                # omits the absolute row entirely, so the output can be pasted
                # into a public issue without leaking raw counts or dollars.
                if (percent_only) {
                    printf "%-28s %14s %14s %12s %10s\n", m, \
                        pct(c_req[m], b_req[m]), pct(c_prompt[m], b_prompt[m]), \
                        pct(c_cost[m], b_cost[m]), pct(c_avg[m], b_avg[m])
                } else {
                    printf "%-28s %14s %14s %12s %10s\n", m, \
                        sign(c_req[m] - b_req[m]), \
                        sign(c_prompt[m] - b_prompt[m]), \
                        sprintf("%+.2f", c_cost[m] - b_cost[m]), \
                        sign(c_avg[m] - b_avg[m])
                    printf "%-28s %14s %14s %12s %10s\n", "", \
                        pct(c_req[m], b_req[m]), pct(c_prompt[m], b_prompt[m]), \
                        pct(c_cost[m], b_cost[m]), pct(c_avg[m], b_avg[m])
                }
                t_breq += b_req[m]; t_creq += c_req[m]
                t_bprompt += b_prompt[m]; t_cprompt += c_prompt[m]
                t_bcost += b_cost[m]; t_ccost += c_cost[m]
            }
            b_all = (t_breq == 0) ? 0 : t_bprompt / t_breq
            c_all = (t_creq == 0) ? 0 : t_cprompt / t_creq
            if (percent_only) {
                printf "%-28s %14s %14s %12s %10s\n", "TOTAL", \
                    pct(t_creq, t_breq), pct(t_cprompt, t_bprompt), \
                    pct(t_ccost, t_bcost), pct(c_all, b_all)
            } else {
                printf "%-28s %14s %14s %12s %10s\n", "TOTAL", \
                    sign(t_creq - t_breq), sign(t_cprompt - t_bprompt), \
                    sprintf("%+.2f", t_ccost - t_bcost), sign(c_all - b_all)
                printf "%-28s %14s %14s %12s %10s\n", "", \
                    pct(t_creq, t_breq), pct(t_cprompt, t_bprompt), \
                    pct(t_ccost, t_bcost), pct(c_all, b_all)
            }
        }
    ' "$baseline" "$compare"
}

# --- dispatch -----------------------------------------------------------------

if [ "$#" -eq 0 ]; then
    usage
    exit "$EXIT_USAGE"
fi

cmd="$1"
shift

case "$cmd" in
    window) cmd_window "$@" ;;
    compare) cmd_compare "$@" ;;
    reconcile) cmd_reconcile "$@" ;;
    -h | --help | help)
        usage
        exit 0
        ;;
    *)
        usage
        exit "$EXIT_USAGE"
        ;;
esac
