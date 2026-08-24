#!/usr/bin/env bash
# Hook no-op silence gate (issue #782).
#
# WHAT THIS EXISTS TO STOP. A hook that fires and has nothing to say must write
# NOTHING to stdout. Every byte it does write becomes a `hook_success`
# attachment in the session transcript — and that attachment is then re-read on
# every subsequent turn for the rest of the session.
#
# The cost is invisible at the hook's own call site, which is exactly why this
# needs a gate rather than a note. Running the hook is cheap (~25ms). What is
# expensive is that a zero-information record enters context and is re-sent 800+
# times. Measured on one machine over 24h: `hook_success` attachments totalled
# **574,677 context tokens** with **132.5M re-read tokens** (size x
# turns-remaining) — the single largest attachment category, ahead of
# `edited_text_file` (27.5M) — for payloads whose entire content was `{}`.
#
# The wrong version of this is a live third-party example, not a hypothetical:
# the `hookify` plugin's `hooks/pretooluse.py` carries the line
#
#     # Always output JSON (even if empty)
#     print(json.dumps(result), file=sys.stdout)
#
# ...which is where the 1,645 `{}` payloads in the measured session came from.
# It looks harmless and reads as defensive. It is neither.
#
# THE RULE. For every hook registered in `plugins/**/hooks/hooks.json`, feed the
# script a no-op payload for its registered event and require **zero bytes on
# stdout**.
#
# THIS GATE EXECUTES THE HOOKS; it does not grep them. A grep would be
# satisfiable by a comment claiming silence, and the property at stake is
# behavioral — what actually reaches stdout. The corpus is read from
# `hooks.json` rather than hardcoded here so a NEWLY registered hook is covered
# automatically instead of being silently exempt (the "harden one knob, grep
# siblings" failure this repo keeps re-learning).
#
# WHY THERE IS ALSO A DENY ASSERTION. Silence-on-no-op is only half the
# contract, and a gate that checks one direction passes for the wrong reason: a
# hook that emits NOTHING EVER — including when it must deny — would satisfy a
# silence-only gate while having lost its entire purpose. So the deny path is
# asserted to still emit. Both directions, or this is not a gate.
#
# Pure bash + coreutils; no network. bash-3.2 clean, no GNU-only regex.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# Absent-runtime contract (#538/#571): a gate whose required tool is missing
# exits the reserved sentinel 77 so run-all.sh renders `[SKIP] ... did not run`
# rather than a green `[ok]`. A silent skip is indistinguishable from a pass,
# which is how a gate sits inert unnoticed. jq parses the hook registrations.
if ! command -v jq >/dev/null 2>&1; then
    printf 'lint-hook-silence: jq not found; cannot parse hooks.json — not enforcing.\n' >&2
    exit 77
fi

test_suite "Hook no-op silence (#782)"

SANDBOX=""
cleanup() { [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

SANDBOX="$(command mktemp -d)" || {
    printf 'lint-hook-silence: mktemp failed — not enforcing.\n' >&2
    exit 77
}

# --- Payload construction ---------------------------------------------------
# A no-op payload per registered event: one that lands on the hook's allow /
# nothing-to-say path. `write_noop_payload <event> <matcher> <outfile>` returns
# non-zero for an event shape this gate has no payload for, so an unrecognized
# registration is reported rather than silently passing on an empty run.
write_noop_payload() {
    local event="$1" matcher="$2" out="$3"
    case "$event:$matcher" in
        PreToolUse:*Bash*)
            printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"%s","session_id":"lint-hook-silence"}\n' \
                "$REPO_ROOT" >"$out"
            ;;
        PreToolUse:*Edit* | PreToolUse:*Write*)
            # Target inside the repo root itself: for the worktree guard this is the
            # in-scope (allow) path.
            printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s/README.md","old_string":"a","new_string":"b"},"cwd":"%s","session_id":"lint-hook-silence"}\n' \
                "$REPO_ROOT" "$REPO_ROOT" >"$out"
            ;;
        Notification:*)
            printf '{"hook_event_name":"Notification","message":"Claude is waiting for your input","cwd":"%s","session_id":"lint-hook-silence"}\n' \
                "$REPO_ROOT" >"$out"
            ;;
        *) return 1 ;;
    esac
    return 0
}

# `hook_script_path <command>` — echo the script path a hooks.json `command`
# invokes, with ${CLAUDE_PLUGIN_ROOT} resolved to the plugin dir. Empty output
# means the command shape was not recognized.
hook_script_path() {
    local cmd="$1" plugin_root="$2" tok
    for tok in $cmd; do
        tok="${tok%\"}"
        tok="${tok#\"}"
        case "$tok" in
            *'${CLAUDE_PLUGIN_ROOT}'*)
                printf '%s' "${tok//\$\{CLAUDE_PLUGIN_ROOT\}/$plugin_root}"
                return 0
                ;;
        esac
    done
    printf ''
}

# --- Corpus: every hook registered in every plugin's hooks.json -------------
# Flat "<script>\t<event>\t<matcher>" rows (no assoc arrays — bash-3.2 clean).
build_corpus() {
    local hj plugin_root
    while IFS= read -r hj; do
        [ -n "$hj" ] || continue
        plugin_root="$(cd "$(dirname "$(dirname "$hj")")" && pwd)"
        jq -r '
            .hooks | to_entries[] as $ev
            | $ev.value[] as $group
            | ($group.matcher // "(all)") as $m
            | $group.hooks[]
            | [$ev.key, $m, .command] | @tsv
        ' "$hj" | while IFS="$(printf '\t')" read -r ev matcher cmd; do
            [ -n "$cmd" ] || continue
            printf '%s\t%s\t%s\n' "$(hook_script_path "$cmd" "$plugin_root")" "$ev" "$matcher"
        done
    done <<EOF
$(find "$REPO_ROOT/plugins" -name hooks.json -type f | command sort)
EOF
}

CORPUS="$(build_corpus)"

# Per-row test body (reads CUR_SCRIPT / CUR_EVENT / CUR_MATCHER).
CUR_SCRIPT=""
CUR_EVENT=""
CUR_MATCHER=""
test_hook_is_silent_on_noop() {
    local payload out err rc
    payload="$SANDBOX/payload.json"

    assert_file_exists "$CUR_SCRIPT" \
        "hooks.json registers $CUR_EVENT -> $CUR_SCRIPT but that script does not exist"
    [ -f "$CUR_SCRIPT" ] || return 0

    if ! write_noop_payload "$CUR_EVENT" "$CUR_MATCHER" "$payload"; then
        assert_true false \
            "No no-op payload defined for event '$CUR_EVENT' matcher '$CUR_MATCHER' ($CUR_SCRIPT). A newly registered event must get a payload here, or this gate silently stops covering it."
        return 0
    fi

    set +e
    out="$(bash "$CUR_SCRIPT" <"$payload" 2>"$SANDBOX/stderr.txt")"
    rc=$?
    set -e
    err="$(cat "$SANDBOX/stderr.txt")"

    assert_output_empty "$out" \
        "$(basename "$CUR_SCRIPT") ($CUR_EVENT) wrote to stdout on its NO-OP path. Every byte here becomes a hook_success attachment re-read for the rest of the session (#782: 574,677 context tokens / 132.5M re-read over 24h for '{}' payloads). Emit nothing when there is no decision to convey; if a payload is genuinely required by the harness for this event, say so in a comment in the hook."

    assert_equals "0" "$rc" \
        "$(basename "$CUR_SCRIPT") ($CUR_EVENT) exited $rc on its no-op path; a no-op fire must exit 0. stderr: $(printf '%s' "$err" | command head -2)"
}

# --- The other direction: a deny still emits --------------------------------
# Silence-on-no-op alone is satisfiable by a hook that never speaks at all,
# including when it must DENY. That would be a correctness regression wearing a
# green gate, so assert the deny path still produces its envelope.
test_deny_path_still_emits() {
    local guard payload out
    guard="$REPO_ROOT/plugins/workflow/hooks/worktree-guard.sh"
    assert_file_exists "$guard" "worktree-guard.sh must exist to verify the deny direction"
    [ -f "$guard" ] || return 0

    # A worktree-escaping target: cwd inside a linked worktree, file_path in the
    # main checkout. Only meaningful when this checkout HAS a linked worktree to
    # name; otherwise the guard correctly allows and there is nothing to assert.
    local wt
    wt="$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null || true)"
    if [ "$wt" = "$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)" ]; then
        skip_test "deny-direction check needs a linked worktree; this is a primary checkout"
        return 0
    fi

    local main_root
    main_root="$(cd "$(git -C "$REPO_ROOT" rev-parse --git-common-dir)/.." && pwd)"
    payload="$SANDBOX/deny.json"
    printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s/README.md","old_string":"a","new_string":"b"},"cwd":"%s","session_id":"lint-hook-silence"}\n' \
        "$main_root" "$REPO_ROOT" >"$payload"

    out="$(bash "$guard" <"$payload" 2>/dev/null || true)"
    assert_contains "$out" '"permissionDecision":"deny"' \
        "worktree-guard.sh must STILL emit a deny envelope for a worktree-escaping edit. Silence-on-no-op must not be achieved by going silent everywhere — that trades a token cost for a correctness hole (#475/#782)."
}

# --- Guards on the gate itself ----------------------------------------------
test_corpus_non_empty() {
    assert_not_empty "$CORPUS" \
        "No hooks discovered in plugins/**/hooks.json — a gate that checks zero hooks is worse than no gate. Did the registration format change?"
}

# The silence detector must be able to FAIL. Without this, a gate that always
# passes (wrong path, unreadable script, swallowed output) looks identical to a
# clean tree.
test_detector_fires() {
    local noisy quiet out
    noisy="$SANDBOX/noisy.sh"
    quiet="$SANDBOX/quiet.sh"
    printf '#!/usr/bin/env bash\nprintf "{}\\n"\nexit 0\n' >"$noisy"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$quiet"

    out="$(bash "$noisy" </dev/null 2>/dev/null)"
    assert_contains "$out" "{}" \
        "Control: a hook that prints '{}' must be observed as non-empty (else the gate cannot detect the very pattern it exists to catch)"

    out="$(bash "$quiet" </dev/null 2>/dev/null)"
    assert_output_empty "$out" "Control: a silent hook is observed as empty"
}

run_test test_corpus_non_empty "Hook corpus is non-empty (gate is not a no-op)"
run_test test_detector_fires "Silence detector distinguishes a '{}' emitter from a silent hook"

while IFS="$(printf '\t')" read -r script event matcher; do
    [ -n "$script" ] || continue
    CUR_SCRIPT="$script"
    CUR_EVENT="$event"
    CUR_MATCHER="$matcher"
    run_test test_hook_is_silent_on_noop "$(basename "$script") :: $event is silent on no-op"
done <<EOF
$CORPUS
EOF

run_test test_deny_path_still_emits "worktree-guard.sh still emits on the DENY path"

generate_report
