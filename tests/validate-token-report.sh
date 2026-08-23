#!/usr/bin/env bash
# Coverage for plugins/workflow/scripts/token-report.sh (issue #781).
#
# The script's whole reason to exist is that the Bifrost gateway fails SILENTLY:
# `?models=<name>` filters, `?model=<name>` is ignored and returns the UNFILTERED
# total with HTTP 200 (measured live: 89,027 vs 359,642 requests). A typo does not
# error — it returns a wrong number that reads as right. The reconciliation guard
# is what converts that silent wrong answer into a loud failure, so the guard is
# this suite's real subject; the TSV plumbing is what makes it assertable.
#
# HERMETIC BY CONSTRUCTION. Every case runs against a local Python stub gateway
# on a loopback port, never the real Bifrost. Two reasons: a gate that needs a
# live external service is a gate that goes red on someone else's outage, and —
# more importantly — the failure cases here (a dropped filter param, a truncated
# model list) require a gateway that MISBEHAVES ON DEMAND. The real one cannot be
# asked to. A `mode` file in the sandbox selects the misbehavior, re-read per
# request, so one long-lived server covers every case without a restart.
#
# THE MUTATION CASE USES TWO MODELS ON PURPOSE (AC3). Under a dropped filter every
# per-model query returns the unfiltered total, so with ONE model the sum equals
# that total exactly and reconciliation PASSES. A one-model mutation test would be
# tautological — green with and without the fix. Two models make the sum overshoot
# (2N vs N) and the breach becomes detectable. test_single_model_cannot_detect
# pins that limitation explicitly so it stays a known property rather than a
# surprise, and the script warns about it at runtime.
#
# Pure bash + coreutils via the `command` builtin, python3 for the stub only.
# bash-3.2 clean, BSD-regex clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TR_SH="$REPO_ROOT/plugins/workflow/scripts/token-report.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "token-report.sh (#781)"

STUB_PID=""
STUB_PORT=""
STUB_DIR=""

# --- Stub gateway -------------------------------------------------------------
#
# Serves /api/logs/stats and /api/models, mimicking the real gateway's response
# shape. Behavior is selected by a `mode` file in the sandbox, so a single
# long-lived server covers every case without a restart:
#
#   normal      models= filters; two models sum to the unfiltered total exactly
#   tolerance   like normal, but the unfiltered total is 1 higher (the real
#               gateway does this — a few requests carry no attributable model)
#   breach      like normal, but the unfiltered total is far higher
#   dropfilter  ANY request returns the unfiltered total — what the gateway
#               really does when the filter param is misspelled or dropped
#   truncated   /api/models returns 1 of a claimed 14
start_stub() {
    STUB_DIR="$(command mktemp -d)"
    command printf 'normal' >"$STUB_DIR/mode"

    command cat >"$STUB_DIR/stub.py" <<'PYEOF'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

STUB_DIR = sys.argv[1]

# Per-model fixtures. Two models, deliberately: the dropped-filter breach is
# undetectable with one (see the suite header).
MODELS = {
    "model-a": {"total_requests": 100, "prompt_tokens": 1000000,
                "completion_tokens": 500, "total_cost": 10.5},
    "model-b": {"total_requests": 300, "prompt_tokens": 600000,
                "completion_tokens": 900, "total_cost": 4.25},
}
UNFILTERED = {"total_requests": 400, "prompt_tokens": 1600000,
              "completion_tokens": 1400, "total_cost": 14.75}


def mode():
    with open(os.path.join(STUB_DIR, "mode")) as fh:
        return fh.read().strip()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, payload, code=200):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        m = mode()

        if parsed.path == "/api/models":
            names = sorted(MODELS)
            if m == "truncated":
                # Returns fewer than it claims — exactly what the real endpoint
                # does without an explicit ?limit (5 returned, "total": 14).
                self._send({"models": [{"name": names[0]}], "total": 14})
            else:
                self._send({"models": [{"name": n} for n in names],
                            "total": len(names)})
            return

        if parsed.path == "/api/logs/stats":
            unfiltered = dict(UNFILTERED)
            if m == "tolerance":
                unfiltered["total_requests"] = 401   # 1 unattributed request
            elif m == "breach":
                unfiltered["total_requests"] = 800
            elif m == "empty":
                # A window with no traffic at all: every figure zero on BOTH the
                # filtered and unfiltered sides, as the live gateway returns for
                # a window predating any logs.
                unfiltered = {"total_requests": 0, "prompt_tokens": 0,
                              "completion_tokens": 0, "total_cost": 0}
                self._send(unfiltered)
                return

            # The heart of the stub: honor ONLY the plural `models=`. Any other
            # spelling is ignored and the unfiltered total comes back with HTTP
            # 200 — the real gateway's silent-failure behavior.
            if m == "dropfilter" or "models" not in params:
                self._send(unfiltered)
                return

            name = params["models"][0]
            self._send(MODELS.get(name, {"total_requests": 0, "prompt_tokens": 0,
                                         "completion_tokens": 0, "total_cost": 0}))
            return

        self._send({"error": "not found"}, 404)


srv = HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(STUB_DIR, "port"), "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF

    command python3 "$STUB_DIR/stub.py" "$STUB_DIR" >/dev/null 2>&1 &
    STUB_PID=$!

    # Wait for the port file; fail loud rather than run every case against a
    # gateway that never came up (which would look like a blanket 77 skip).
    local waited=0
    while [ ! -s "$STUB_DIR/port" ]; do
        command sleep 0.1
        waited=$((waited + 1))
        if [ "$waited" -gt 100 ]; then
            command printf 'stub gateway failed to start within 10s\n' >&2
            return 1
        fi
    done
    STUB_PORT="$(command cat "$STUB_DIR/port")"
    return 0
}

stop_stub() {
    [ -n "$STUB_PID" ] && command kill "$STUB_PID" 2>/dev/null
    [ -n "$STUB_DIR" ] && command rm -rf "$STUB_DIR"
    STUB_PID=""
}
trap stop_stub EXIT INT TERM

set_mode() {
    command printf '%s' "$1" >"$STUB_DIR/mode"
}

# run_tr <mode> <args...> — run token-report against the stub in <mode>.
# Stores combined output in TR_OUT and the exit status in TR_RC.
run_tr() {
    local m="$1"
    shift
    set_mode "$m"
    TR_OUT="$(BIFROST_URL="http://127.0.0.1:$STUB_PORT" "$TR_SH" "$@" 2>&1)"
    TR_RC=$?
}

W_START="2026-08-22T18:00:00Z"
W_END="2026-08-23T18:00:00Z"

# --- Happy path ---------------------------------------------------------------

test_window_emits_reconciled_rows() {
    run_tr normal window --start "$W_START" --end "$W_END"
    assert_exit 0 "$TR_RC" "A reconciling window exits 0"
    assert_contains "$TR_OUT" "model-a" "The breakdown names each model"
    assert_contains "$TR_OUT" "model-b" "Both models appear"
    assert_contains "$TR_OUT" "reconciled" "The verdict is reported"
}

test_tsv_contract_shape() {
    run_tr normal window --start "$W_START" --end "$W_END"
    local row
    row="$(command printf '%s\n' "$TR_OUT" | command grep -E "^${W_START}	model-a	")"
    assert_not_empty "$row" "A data row starts with window_start and model"
    # The 7-field contract #788 consumes. Asserting the field COUNT is what
    # catches a column silently inserted or dropped — a consumer reading
    # positionally would then misattribute every value after the change.
    local fields
    fields="$(command printf '%s' "$row" | command awk -F'\t' '{print NF}')"
    assert_equals "7" "$fields" "The TSV row carries exactly 7 tab-separated fields"
    assert_equals "100" "$(command printf '%s' "$row" | command cut -f3)" "requests is field 3"
    assert_equals "1000000" "$(command printf '%s' "$row" | command cut -f4)" "prompt_tokens is field 4"
}

test_avg_prompt_per_request_is_computed() {
    run_tr normal window --start "$W_START" --end "$W_END"
    local row avg
    row="$(command printf '%s\n' "$TR_OUT" | command grep -E "	model-a	")"
    avg="$(command printf '%s' "$row" | command cut -f7)"
    # 1000000 / 100 = 10000. The headline metric of the whole issue series, so a
    # silent arithmetic regression here would mis-grade #782-#788.
    assert_equals "10000" "$avg" "avg_prompt_per_request = prompt_tokens / requests"
}

test_header_is_comment_prefixed() {
    run_tr normal window --start "$W_START" --end "$W_END"
    assert_contains "$TR_OUT" "# window_start	model	requests" \
        "The column header is '#'-prefixed so consumers can strip comments"
}

test_json_output_is_valid() {
    # Captures stdout ALONE, not the merged stream run_tr uses. That separation
    # is itself the assertion: the reconciliation verdict goes to stderr so that
    # stdout stays a clean machine-readable payload. If the verdict ever leaked
    # into stdout, `jq` here would fail — which is exactly how this case caught a
    # merged-stream capture during development.
    set_mode normal
    local out
    out="$(BIFROST_URL="http://127.0.0.1:$STUB_PORT" "$TR_SH" window \
        --start "$W_START" --end "$W_END" --json 2>/dev/null)"
    TR_RC=$?
    assert_exit 0 "$TR_RC" "--json exits 0"
    assert_valid_json "$out" "--json emits parseable JSON on stdout alone"
    local n
    n="$(command printf '%s' "$out" | jq 'length')"
    assert_equals "2" "$n" "--json carries one object per model with traffic"
}

test_stdout_is_free_of_diagnostics() {
    # Generalizes the property above to the TSV path: every diagnostic line must
    # be on stderr, so a consumer can pipe stdout straight into a parser.
    set_mode normal
    local out
    out="$(BIFROST_URL="http://127.0.0.1:$STUB_PORT" "$TR_SH" window \
        --start "$W_START" --end "$W_END" 2>/dev/null)"
    assert_not_contains "$out" "token-report:" \
        "Diagnostics go to stderr, never into the stdout data stream"
}

test_explicit_models_flag() {
    run_tr normal window --start "$W_START" --end "$W_END" --models model-a,model-b
    assert_exit 0 "$TR_RC" "--models bypasses enumeration and still reconciles"
    assert_contains "$TR_OUT" "model-b" "Both named models are queried"
}

# --- The reconciliation guard (the point of the tool) -------------------------

test_dropped_filter_is_caught() {
    # AC3: the models= -> model= mutation. In dropfilter mode every per-model
    # query answers with the unfiltered total, so two models sum to 800 against
    # an actual 400 and the guard must refuse.
    run_tr dropfilter window --start "$W_START" --end "$W_END" --models model-a,model-b
    assert_exit 1 "$TR_RC" "A dropped/renamed filter param fails LOUD, exit 1"
    assert_contains "$TR_OUT" "RECONCILIATION FAILED" "The failure names itself"
    assert_contains "$TR_OUT" "models=" "The message names the correct plural spelling"
}

test_dropped_filter_emits_no_rows() {
    # Refusing to exit 0 is not enough: a consumer that reads stdout and ignores
    # the status must not find usable rows. This is why the script collects
    # everything before emitting anything.
    set_mode dropfilter
    local rows
    rows="$(BIFROST_URL="http://127.0.0.1:$STUB_PORT" "$TR_SH" window \
        --start "$W_START" --end "$W_END" --models model-a,model-b 2>/dev/null)"
    assert_output_empty "$rows" "A failed reconciliation emits NOTHING on stdout"
}

test_within_tolerance_passes() {
    # The tolerance is headroom, not an observed need: the live gateway
    # reconciles exactly with a complete model list. This case pins that a single
    # unattributed request cannot turn a healthy window into a hard failure —
    # i.e. that the guard is not a bare equality check.
    run_tr tolerance window --start "$W_START" --end "$W_END"
    assert_exit 0 "$TR_RC" "A 1-request gap is inside the default 0.5% tolerance"
}

test_beyond_tolerance_fails() {
    run_tr breach window --start "$W_START" --end "$W_END"
    assert_exit 1 "$TR_RC" "A gap beyond tolerance fails even without a dropped filter"
    assert_contains "$TR_OUT" "RECONCILIATION FAILED" "The breach is named"
}

test_tolerance_is_configurable() {
    set_mode breach
    TR_OUT="$(BIFROST_URL="http://127.0.0.1:$STUB_PORT" \
        TOKEN_REPORT_RECONCILE_PCT=200 "$TR_SH" window \
        --start "$W_START" --end "$W_END" 2>&1)"
    TR_RC=$?
    assert_exit 0 "$TR_RC" "A wide TOKEN_REPORT_RECONCILE_PCT admits the same gap"
}

test_single_model_cannot_detect() {
    # Pins the guard's known blind spot rather than leaving it to be rediscovered:
    # with ONE model the dropped-filter sum equals the unfiltered total exactly,
    # so reconciliation passes. This is why test_dropped_filter_is_caught uses
    # two. The script must warn so a green verdict does not imply a real check.
    run_tr dropfilter window --start "$W_START" --end "$W_END" --models model-a
    assert_exit 0 "$TR_RC" "One model cannot expose a dropped filter (known limitation)"
    assert_contains "$TR_OUT" "WARNING" "A single-model reconciliation warns it is unproven"
}

test_empty_window_is_not_an_error() {
    # A window with no traffic must reconcile 0 against 0 rather than divide by
    # zero or invent rows. Verified against the LIVE gateway on a 2020 window,
    # which returns zeros on both the filtered and unfiltered sides.
    #
    # Note "empty" means both sides zero. A window where the models return
    # nothing but the unfiltered total does NOT is a genuine breach, not an empty
    # window — see test_zero_models_against_nonzero_total below, which pins that
    # the two are not confused.
    run_tr empty window --start "$W_START" --end "$W_END"
    assert_exit 0 "$TR_RC" "An empty window is a valid measurement, not a failure"
    assert_contains "$TR_OUT" "reconciled" "0 vs 0 reconciles rather than dividing by zero"
}

test_zero_models_against_nonzero_total() {
    # The inverse of the case above, and the more dangerous one: if every
    # per-model query came back empty while the gateway still reports traffic,
    # something is wrong with the filter — that must fail, not read as "quiet
    # period". Guards against a fix for the empty-window case that special-cases
    # a zero sum into a pass.
    run_tr normal window --start "$W_START" --end "$W_END" --models no-such-model
    assert_exit 1 "$TR_RC" "Zero per-model requests against a non-zero total is a breach"
}

test_reconcile_subcommand() {
    run_tr normal reconcile --start "$W_START" --end "$W_END"
    assert_exit 0 "$TR_RC" "reconcile exits 0 on healthy data"
    run_tr dropfilter reconcile --start "$W_START" --end "$W_END" --models model-a,model-b
    assert_exit 1 "$TR_RC" "reconcile alone also catches the dropped filter"
}

# --- Silent truncation --------------------------------------------------------

test_truncated_model_list_fails_loud() {
    # /api/models really does return 5 of a claimed 14 without ?limit. A silently
    # short list drops models from the sum and manufactures a breach out of
    # complete data, so it must fail as itself rather than as a reconciliation
    # error.
    run_tr truncated window --start "$W_START" --end "$W_END"
    assert_exit 1 "$TR_RC" "A truncated model list fails loud"
    assert_contains "$TR_OUT" "truncated" "The message names the real cause"
}

# --- Exit-code separation -----------------------------------------------------

test_unreachable_gateway_exits_77() {
    # Port 9 (discard) refuses fast. 77 is the reserved skip sentinel: an
    # unavailable gateway is a skipped gate, never a pass.
    TR_OUT="$(BIFROST_URL="http://127.0.0.1:9" "$TR_SH" window \
        --start "$W_START" --end "$W_END" 2>&1)"
    TR_RC=$?
    assert_exit 77 "$TR_RC" "An unreachable gateway exits the 77 skip sentinel"
    assert_contains "$TR_OUT" "unreachable" "The message says why it skipped"
}

test_unreachable_is_not_reconciliation_failure() {
    # The two must never collapse: "I could not measure" and "I measured and it
    # is wrong" demand different operator responses.
    TR_OUT="$(BIFROST_URL="http://127.0.0.1:9" "$TR_SH" window \
        --start "$W_START" --end "$W_END" 2>&1)"
    assert_not_contains "$TR_OUT" "RECONCILIATION FAILED" \
        "An unreachable gateway is never reported as a reconciliation failure"
}

test_breach_is_not_the_skip_sentinel() {
    run_tr breach window --start "$W_START" --end "$W_END"
    assert_exit 1 "$TR_RC" "A real data failure must NOT exit 77 and read as a skip"
}

test_missing_bifrost_url_is_usage_error() {
    # Exit 2, not 77: a forgotten export is the operator's to fix. Were this 77 it
    # would render as a clean skip and the gate could sit inert forever.
    TR_OUT="$(env -u BIFROST_URL "$TR_SH" window --start "$W_START" --end "$W_END" 2>&1)"
    TR_RC=$?
    assert_exit 2 "$TR_RC" "Unset BIFROST_URL is a usage error, not a skip"
    assert_contains "$TR_OUT" "BIFROST_URL" "The message names the variable"
    assert_contains "$TR_OUT" "ANTHROPIC_BASE_URL" \
        "and warns against the plausible-but-wrong candidate"
}

test_non_json_response_is_failure_not_skip() {
    # BIFROST_URL aimed at the proxy path returns the web UI's HTML with HTTP
    # 200. The gateway answered, so this is a failure (1), not unreachable (77).
    TR_OUT="$(BIFROST_URL="http://127.0.0.1:$STUB_PORT/nonexistent" "$TR_SH" window \
        --start "$W_START" --end "$W_END" 2>&1)"
    TR_RC=$?
    assert_exit 1 "$TR_RC" "A reachable gateway returning the wrong thing exits 1"
}

test_usage_errors() {
    TR_OUT="$("$TR_SH" 2>&1)"
    assert_exit 2 "$?" "No subcommand -> exit 2"
    TR_OUT="$("$TR_SH" bogus-command 2>&1)"
    assert_exit 2 "$?" "Unknown subcommand -> exit 2"
    TR_OUT="$(BIFROST_URL="http://127.0.0.1:$STUB_PORT" "$TR_SH" window --start "$W_START" 2>&1)"
    assert_exit 2 "$?" "window without --end -> exit 2"
}

# --- compare ------------------------------------------------------------------

test_compare_prints_per_model_deltas() {
    local dir base cmp
    dir="$(command mktemp -d)"
    base="$dir/base.tsv"
    cmp="$dir/cmp.tsv"
    command printf '# header\n%s\tmodel-a\t100\t1000000\t500\t10.5\t10000\n' "$W_START" >"$base"
    command printf '# header\n%s\tmodel-a\t100\t800000\t500\t8.4\t8000\n' "$W_END" >"$cmp"

    TR_OUT="$("$TR_SH" compare --baseline "$base" --compare "$cmp" 2>&1)"
    TR_RC=$?
    command rm -rf "$dir"

    assert_exit 0 "$TR_RC" "compare exits 0"
    assert_contains "$TR_OUT" "model-a" "Deltas are reported per model"
    assert_contains "$TR_OUT" "avg/req" "The headline metric is a named column"
    assert_contains "$TR_OUT" "-2000" "The avg-prompt-per-request delta is shown (10000 -> 8000)"
    assert_contains "$TR_OUT" "-200000" "The prompt-token delta is shown"
    assert_contains "$TR_OUT" "TOTAL" "A fleet-level total row is printed"
}

test_compare_skips_comment_lines() {
    # The window output is comment-prefixed; if compare parsed those as data the
    # totals would be silently wrong rather than obviously broken.
    local dir base cmp
    dir="$(command mktemp -d)"
    base="$dir/base.tsv"
    cmp="$dir/cmp.tsv"
    command printf '# token-report window x .. y\n# reconciled: 400 vs 400\n%s\tmodel-a\t100\t1000000\t500\t10.5\t10000\n' "$W_START" >"$base"
    command printf '# token-report window x .. y\n%s\tmodel-a\t50\t500000\t250\t5.25\t10000\n' "$W_END" >"$cmp"

    TR_OUT="$("$TR_SH" compare --baseline "$base" --compare "$cmp" 2>&1)"
    command rm -rf "$dir"

    assert_not_contains "$TR_OUT" "reconciled" "Comment lines are not parsed as models"
    assert_contains "$TR_OUT" "+0" "An unchanged avg/req reports a zero delta, not garbage"
}

test_compare_missing_file_is_usage_error() {
    TR_OUT="$("$TR_SH" compare --baseline /nonexistent/a --compare /nonexistent/b 2>&1)"
    assert_exit 2 "$?" "An unreadable input file is a usage error"
}

# --- Dispatch -----------------------------------------------------------------

if ! command -v python3 >/dev/null 2>&1; then
    # Whole-gate skip: without python3 there is no stub, and every case would
    # otherwise pass vacuously against an absent gateway.
    command printf 'token-report gate: python3 not available — cannot run stub gateway\n' >&2
    exit 77
fi

if ! start_stub; then
    command printf 'token-report gate: stub gateway did not start\n' >&2
    exit 1
fi

run_test test_window_emits_reconciled_rows "window emits reconciled per-model rows"
run_test test_tsv_contract_shape "TSV carries the 7-field contract"
run_test test_avg_prompt_per_request_is_computed "avg_prompt_per_request is computed correctly"
run_test test_header_is_comment_prefixed "column header is '#'-prefixed"
run_test test_json_output_is_valid "--json emits valid JSON, one object per model"
run_test test_stdout_is_free_of_diagnostics "diagnostics stay on stderr"
run_test test_explicit_models_flag "--models bypasses enumeration"
run_test test_dropped_filter_is_caught "AC3: models= -> model= mutation fails loud"
run_test test_dropped_filter_emits_no_rows "a failed reconciliation emits no rows"
run_test test_within_tolerance_passes "an unattributed request stays within tolerance"
run_test test_beyond_tolerance_fails "a gap beyond tolerance fails"
run_test test_tolerance_is_configurable "TOKEN_REPORT_RECONCILE_PCT retunes the guard"
run_test test_single_model_cannot_detect "single-model reconciliation warns it is unproven"
run_test test_empty_window_is_not_an_error "an empty window reconciles 0 vs 0"
run_test test_zero_models_against_nonzero_total "zero models vs non-zero total is a breach"
run_test test_reconcile_subcommand "reconcile subcommand shares the guard"
run_test test_truncated_model_list_fails_loud "a truncated /api/models fails loud"
run_test test_unreachable_gateway_exits_77 "unreachable gateway exits 77"
run_test test_unreachable_is_not_reconciliation_failure "77 and 1 do not collapse (unreachable)"
run_test test_breach_is_not_the_skip_sentinel "77 and 1 do not collapse (breach)"
run_test test_missing_bifrost_url_is_usage_error "unset BIFROST_URL exits 2, not 77"
run_test test_non_json_response_is_failure_not_skip "non-JSON response exits 1, not 77"
run_test test_usage_errors "usage errors exit 2"
run_test test_compare_prints_per_model_deltas "compare prints per-model deltas incl. avg/req"
run_test test_compare_skips_comment_lines "compare ignores comment lines"
run_test test_compare_missing_file_is_usage_error "compare rejects unreadable files"

stop_stub
generate_report
