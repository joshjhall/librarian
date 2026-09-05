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
        PreToolUse:*Read*)
            # Read/Grep/Glob — the read-scope guard (#630). Target inside the
            # repo root itself, which for that guard is the allow path: this
            # session's cwd is the repo root (a PRIMARY checkout, not a linked
            # worktree), so the caller gate clears it before any scoping. Listed
            # BEFORE the Edit/Write arm because `*Write*` would not match here
            # but a future combined matcher could; keeping the read arm first
            # makes the intended payload win rather than depending on arm order.
            printf '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"%s/README.md"},"cwd":"%s","session_id":"lint-hook-silence"}\n' \
                "$REPO_ROOT" "$REPO_ROOT" >"$out"
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
    # `set -f` disables pathname expansion for the unquoted split below. Without
    # it, a command string containing a glob metacharacter (`*`, `?`, `[...]`)
    # would be expanded against the cwd before the case match — turning an
    # opaque data string from hooks.json into shell-evaluated input. Today the
    # corpus is this repo's own trusted files, but the gate's premise is that it
    # keeps working as more hooks get registered.
    set -f
    for tok in $cmd; do
        tok="${tok%\"}"
        tok="${tok#\"}"
        case "$tok" in
            *'${CLAUDE_PLUGIN_ROOT}'*)
                set +f
                printf '%s' "${tok//\$\{CLAUDE_PLUGIN_ROOT\}/$plugin_root}"
                return 0
                ;;
        esac
    done
    set +f
    printf ''
}

# --- Corpus: every hook registered in every plugin's hooks.json -------------
# Flat "<script>\t<event>\t<matcher>" rows (no assoc arrays — bash-3.2 clean).
build_corpus() {
    local hj plugin_root _resolved
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
            # An unrecognized command shape resolves to an EMPTY script path. Emit
            # the row anyway, carrying the raw command as a 4th field: the
            # consumer turns it into a loud failure. Dropping it here instead
            # would make an unrecognized registration silently exempt — the exact
            # "covered automatically" claim this gate makes about itself.
            # NOTE the UNRESOLVED sentinel: an empty first field cannot survive
            # `read` with IFS=<tab>, because tab is IFS *whitespace* and a
            # leading run of it is stripped — every column would shift left and
            # the row would be misread as a different hook. A literal sentinel
            # keeps the field count fixed.
            _resolved="$(hook_script_path "$cmd" "$plugin_root")"
            [ -n "$_resolved" ] || _resolved="UNRESOLVED"
            printf '%s\t%s\t%s\t%s\n' "$_resolved" "$ev" "$matcher" "$cmd"
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
    local payload out err rc nbytes
    payload="$SANDBOX/payload.json"

    assert_file_exists "$CUR_SCRIPT" \
        "hooks.json registers $CUR_EVENT -> $CUR_SCRIPT but that script does not exist"
    [ -f "$CUR_SCRIPT" ] || return 0

    if ! write_noop_payload "$CUR_EVENT" "$CUR_MATCHER" "$payload"; then
        assert_true false \
            "No no-op payload defined for event '$CUR_EVENT' matcher '$CUR_MATCHER' ($CUR_SCRIPT). A newly registered event must get a payload here, or this gate silently stops covering it."
        return 0
    fi

    # Capture to a FILE and measure bytes. Command substitution strips trailing
    # newlines, so `out="$(...)"` would read a hook that emits a bare `\n` as
    # empty — passing a byte-emitting hook against a contract that says "zero
    # bytes". The byte count is the contract; the string is only for the message.
    #
    # RUN THE HOOK IN AN ISOLATED SANDBOX (cycle-2 review finding). A hook may
    # have SIDE EFFECTS that the stdout assertion cannot see. golem-notify.sh
    # resolves its status feed from the ACTUAL process cwd via
    # `git rev-parse --git-common-dir` — it never reads the payload's `cwd` —
    # so invoking it from the repo appended a synthetic line to the LIVE
    # `.worktrees/.status/feed.jsonl` that golem-status.sh and gate-watch read
    # to decide golem state. Measured before this fix: running the gate grew the
    # real feed by 1 line / 110 bytes, attributed to the current golem. The
    # stdout check passed throughout, so the corruption was invisible to the
    # test causing it.
    #
    # Three isolations, each closing one escape route:
    #   - cwd is a throwaway git repo, so git-common-dir resolves into $SANDBOX
    #   - GOLEM_* are pointed at the sandbox (belt-and-braces if cwd resolution
    #     is ever changed to honor the payload)
    #   - GOLEM_EVENT_SINKS is emptied so an operator env with a real sink
    #     cannot make this gate POST a synthetic event to a live endpoint
    # The isolation DEPENDS on hookcwd being a real git repo: that is what makes
    # `git rev-parse --git-common-dir` resolve inside the sandbox instead of
    # walking up to the real checkout. So a setup failure must FAIL, not be
    # swallowed — a bare directory with no .git leaves the walk-up free and
    # silently restores the very escape route this block closes.
    if [ ! -d "$SANDBOX/hookcwd/.git" ]; then
        if ! mkdir -p "$SANDBOX/hookcwd" 2>/dev/null ||
            ! git -C "$SANDBOX/hookcwd" init -q >/dev/null 2>&1; then
            assert_true false \
                "Could not build the isolated git cwd for hook execution. Refusing to run the hook against the ambient tree: golem-notify.sh resolves its status feed from the process cwd and would write to the real .worktrees/.status/feed.jsonl."
            return 0
        fi
    fi

    # Truncate the captures BEFORE the run. If the subshell dies early (a failed
    # cd), the redirections below never fire and these files would still hold
    # the PREVIOUS hook's output — reporting one hook's bytes against another's
    # name.
    : >"$SANDBOX/stdout.txt"
    : >"$SANDBOX/stderr.txt"

    set +e
    (
        cd "$SANDBOX/hookcwd" 2>/dev/null || exit 127
        GOLEM_WORKTREE_DIR="wt" \
            GOLEM_STATUS_DIR="wt/.status" \
            GOLEM_EVENT_SINKS="" \
            GOLEM_ID="lint-hook-silence" \
            bash "$CUR_SCRIPT" <"$payload" \
            >"$SANDBOX/stdout.txt" 2>"$SANDBOX/stderr.txt"
    )
    rc=$?
    set -e
    err="$(cat "$SANDBOX/stderr.txt")"

    # 127 is this subshell's own sentinel for "could not cd into the sandbox",
    # not the hook's exit code. Surface it as itself rather than letting the
    # assertions below read empty captures as a clean pass.
    if [ "$rc" -eq 127 ] && [ ! -s "$SANDBOX/stdout.txt" ]; then
        assert_true false \
            "Could not cd into the isolated sandbox cwd to run $(basename "$CUR_SCRIPT"). The hook was NOT executed; treating this as a pass would assert silence that was never measured."
        return 0
    fi

    nbytes="$(command wc -c <"$SANDBOX/stdout.txt" | command tr -d '[:space:]')"
    out="$(command head -c 200 "$SANDBOX/stdout.txt")"

    assert_equals "0" "$nbytes" \
        "$(basename "$CUR_SCRIPT") ($CUR_EVENT) wrote to stdout on its NO-OP path. Every byte here becomes a hook_success attachment re-read for the rest of the session (#782: 574,677 context tokens / 132.5M re-read over 24h for '{}' payloads). Emit nothing when there is no decision to convey; if a payload is genuinely required by the harness for this event, say so in a comment in the hook. Observed ${nbytes} byte(s): '$(printf '%s' "$out" | command tr -d '\n')'"

    assert_equals "0" "$rc" \
        "$(basename "$CUR_SCRIPT") ($CUR_EVENT) exited $rc on its no-op path; a no-op fire must exit 0. stderr: $(printf '%s' "$err" | command head -2)"
}

# --- The other direction: a deny still emits --------------------------------
# Silence-on-no-op alone is satisfiable by a hook that never speaks at all,
# including when it must DENY. That would be a correctness regression wearing a
# green gate, so assert the deny path still produces its envelope.
#
# THE FIXTURE IS BUILT, NOT BORROWED. An earlier version of this check ran only
# when the AMBIENT checkout happened to be a linked worktree, and called
# `skip_test` otherwise. That is the self-skipping-test trap: `actions/checkout`
# produces a plain clone where git-dir EQUALS git-common-dir, so the assertion
# skipped on every CI run — the one environment that gates merge — while passing
# locally in a golem worktree and looking covered. A skip reads the same as a
# pass at a glance, so the deny direction was unguarded exactly where it
# mattered. This version CONSTRUCTS a throwaway superproject + linked worktree
# in the sandbox, so it runs identically in a plain clone, in CI, and inside a
# golem worktree.
make_worktree_fixture() {
    local root="$1"
    mkdir -p "$root/main" || return 1
    git -C "$root/main" init -q >/dev/null 2>&1 || return 1
    git -C "$root/main" config user.email "lint@example.invalid" || return 1
    git -C "$root/main" config user.name "lint-hook-silence" || return 1
    printf 'fixture\n' >"$root/main/README.md" || return 1
    git -C "$root/main" add README.md >/dev/null 2>&1 || return 1
    git -C "$root/main" commit -qm "fixture" >/dev/null 2>&1 || return 1
    git -C "$root/main" worktree add -q "$root/wt" -b fixture-wt >/dev/null 2>&1 || return 1
    # A SECOND worktree, as a sibling of the first under a shared parent named
    # `issue-*`. The read-scope guard (#630) denies only PEER worktrees, so its
    # deny direction cannot be exercised by the single-worktree shape above —
    # there is nothing to be a peer OF. Best-effort: a git too old for two
    # worktrees still builds the write-guard fixture, and the read-guard case
    # detects the absence and fails loudly rather than passing quietly.
    mkdir -p "$root/wts" || return 0
    git -C "$root/main" worktree add -q "$root/wts/issue-1" -b fixture-wt-1 >/dev/null 2>&1 || return 0
    git -C "$root/main" worktree add -q "$root/wts/issue-2" -b fixture-wt-2 >/dev/null 2>&1 || return 0
    return 0
}

test_deny_path_still_emits() {
    local guard payload out fixture main_root wt_root
    guard="$REPO_ROOT/plugins/workflow/hooks/worktree-guard.sh"
    assert_file_exists "$guard" "worktree-guard.sh must exist to verify the deny direction"
    [ -f "$guard" ] || return 0

    if ! command -v git >/dev/null 2>&1; then
        skip_test "git unavailable — cannot build the worktree fixture"
        return 0
    fi

    fixture="$SANDBOX/deny-fixture"
    if ! make_worktree_fixture "$fixture"; then
        # A fixture that cannot be built is a broken environment, not a reason
        # to pass: fail loudly rather than silently skipping the half of the
        # contract this assertion exists to hold.
        assert_true false \
            "Could not build the git worktree fixture for the deny-direction check. This assertion must not be skipped — it is the only automated guard that worktree-guard.sh still emits when it must DENY."
        return 0
    fi

    main_root="$(cd "$fixture/main" && pwd)"
    wt_root="$(cd "$fixture/wt" && pwd)"

    # A worktree-escaping target: cwd inside the linked worktree, file_path in
    # the superproject checkout.
    payload="$SANDBOX/deny.json"
    printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s/README.md","old_string":"a","new_string":"b"},"cwd":"%s","session_id":"lint-hook-silence"}\n' \
        "$main_root" "$wt_root" >"$payload"

    out="$(bash "$guard" <"$payload" 2>/dev/null || true)"
    assert_contains "$out" '"permissionDecision":"deny"' \
        "worktree-guard.sh must STILL emit a deny envelope for a worktree-escaping edit. Silence-on-no-op must not be achieved by going silent everywhere — that trades a token cost for a correctness hole (#475/#782)."
}

# read-scope-guard.sh is the THIRD hook that can deny (#630), and it is the one
# most at risk of the failure this whole gate exists to catch. Its no-op payload
# above is an ALLOW, and its rule is deliberately narrow — it allows the main
# checkout, out-of-repo paths, relative targets, and an absent path field — so a
# regression that made it allow EVERYTHING would keep the silence assertion green
# while having lost its entire purpose. Silence-on-no-op is only half a contract;
# without this arm the new hook would be enrolled in the half that a broken guard
# passes trivially.
test_read_guard_deny_path_still_emits() {
    local guard payload out fixture main_root wt_root peer_root
    guard="$REPO_ROOT/plugins/workflow/hooks/read-scope-guard.sh"
    assert_file_exists "$guard" "read-scope-guard.sh must exist to verify the deny direction"
    [ -f "$guard" ] || return 0

    if ! command -v git >/dev/null 2>&1; then
        skip_test "git unavailable — cannot build the worktree fixture"
        return 0
    fi

    fixture="$SANDBOX/read-deny-fixture"
    if ! make_worktree_fixture "$fixture"; then
        assert_true false \
            "Could not build the git worktree fixture for the read-guard deny-direction check. This assertion must not be skipped — it is the only automated guard that read-scope-guard.sh still emits when it must DENY."
        return 0
    fi
    if [ ! -d "$fixture/wts/issue-2" ]; then
        # The peer pair is what makes this case a DENY rather than an allow. If
        # it is missing the payload below would exercise the allow path and the
        # assertion would fail confusingly; say why instead.
        assert_true false \
            "The peer-worktree pair (wts/issue-1 + wts/issue-2) was not created, so the read-guard deny direction cannot be exercised. Fix make_worktree_fixture rather than weakening this assertion."
        return 0
    fi

    main_root="$(cd "$fixture/main" && pwd)"
    wt_root="$(cd "$fixture/wts/issue-1" && pwd)"
    peer_root="$(cd "$fixture/wts/issue-2" && pwd)"
    : "$main_root"

    # cwd inside one golem worktree, target inside its PEER.
    payload="$SANDBOX/read-deny.json"
    printf '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"%s/README.md"},"cwd":"%s","session_id":"lint-hook-silence"}\n' \
        "$peer_root" "$wt_root" >"$payload"

    out="$(bash "$guard" <"$payload" 2>/dev/null || true)"
    assert_contains "$out" '"permissionDecision":"deny"' \
        "read-scope-guard.sh must STILL emit a deny envelope for a peer-worktree read. Silence-on-no-op must not be achieved by going silent everywhere — that trades a token cost for a correctness hole (#630/#782)."
}

# A registered hook whose command shape `hook_script_path` cannot resolve must
# FAIL, never vanish. Otherwise a hook registered with a hardcoded path (or any
# spelling other than the ${CLAUDE_PLUGIN_ROOT} literal) would be silently
# exempt while `test_corpus_non_empty` still passed on its siblings.
CUR_RAWCMD=""
test_unresolved_command() {
    assert_true false \
        "hooks.json registers $CUR_EVENT with a command this gate cannot resolve to a script path: '$CUR_RAWCMD'. Teach hook_script_path() that shape — an unresolved registration must not silently drop out of the corpus."
}

# bash-guard.sh is the OTHER hook that can deny, and the higher-stakes one — it
# guards destructive shell in read-only subagents (#448/#662). Pinning only
# worktree-guard's deny path would leave the two-sided contract half-enforced on
# the hook where going silent costs the most.
test_bash_guard_deny_path_still_emits() {
    local guard payload out
    guard="$REPO_ROOT/plugins/workflow/hooks/bash-guard.sh"
    assert_file_exists "$guard" "bash-guard.sh must exist to verify its deny direction"
    [ -f "$guard" ] || return 0

    # A read-only subagent (agent_id present) running destructive shell: Rule A,
    # tree-independent, so this needs no worktree fixture.
    payload="$SANDBOX/bg-deny.json"
    printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf src"},"cwd":"%s","session_id":"lint-hook-silence","agent_id":"a-review-1","agent_type":"code-reviewer"}\n' \
        "$REPO_ROOT" >"$payload"

    out="$(bash "$guard" <"$payload" 2>/dev/null || true)"
    assert_contains "$out" '"permissionDecision":"deny"' \
        "bash-guard.sh must STILL emit a deny envelope for destructive shell in a read-only subagent. Silence-on-no-op must not be achieved by going silent everywhere (#448/#662/#782)."
}

# The two FALLBACK branches — hook_script_path()'s UNRESOLVED result and
# write_noop_payload()'s catch-all — exist to make a registration this gate
# cannot model fail LOUDLY instead of dropping out of the corpus. But the real
# corpus matches every case today, so neither branch executes in a normal run:
# they are dead code in CI, and a regression in either (a ${CLAUDE_PLUGIN_ROOT}
# spelling that stops resolving, a case arm that drifts from a future event
# shape) would restore the silent-exemption this gate was written to prevent,
# with nothing failing to say so. These call the helpers directly so the
# fallbacks are exercised independently of what happens to be registered.
test_unresolved_command_detector() {
    local out
    out="$(hook_script_path 'python3 /opt/elsewhere/rogue.py' '/plugin/root')"
    assert_output_empty "$out" \
        "hook_script_path must return EMPTY for a command with no \${CLAUDE_PLUGIN_ROOT} token, so build_corpus marks the row UNRESOLVED rather than emitting a bogus path"

    out="$(hook_script_path 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/x.sh"' '/plugin/root')"
    assert_equals "/plugin/root/hooks/x.sh" "$out" \
        "...and must still resolve the supported spelling (or the check above would pass by being broken for everything)"
}

test_unmatched_event_detector() {
    local rc=0
    write_noop_payload "SomeFutureEvent" "(all)" "$SANDBOX/unused.json" || rc=$?
    assert_equals "1" "$rc" \
        "write_noop_payload must return non-zero for an event shape it cannot model, so the consumer turns it into a loud failure instead of skipping the hook"

    rc=0
    write_noop_payload "PreToolUse" "Bash" "$SANDBOX/matched.json" || rc=$?
    assert_equals "0" "$rc" \
        "...and must still succeed for a supported event (or the check above would pass by rejecting everything)"
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

    # The bare-newline case is why this gate measures BYTES rather than string
    # emptiness. Command substitution strips trailing newlines, so a hook that
    # emits only `\n` reads as an empty string and would pass a contract that
    # says "zero bytes" while having written one. Assert the measurement method
    # the real check relies on, so a future edit cannot quietly regress it back
    # to `out="$(...)"` emptiness with every test still green.
    local newline_only nbytes
    newline_only="$SANDBOX/newline.sh"
    printf '#!/usr/bin/env bash\nprintf "\\n"\nexit 0\n' >"$newline_only"

    bash "$newline_only" </dev/null >"$SANDBOX/nl-stdout.txt" 2>/dev/null
    nbytes="$(command wc -c <"$SANDBOX/nl-stdout.txt" | command tr -d '[:space:]')"
    assert_equals "1" "$nbytes" \
        "A hook emitting a bare newline must measure as 1 byte — this is the case string-emptiness misses"

    out="$(bash "$newline_only" </dev/null 2>/dev/null)"
    assert_output_empty "$out" \
        "...and the same output read via command substitution IS empty — which is precisely why the gate must not use that method"
}

run_test test_corpus_non_empty "Hook corpus is non-empty (gate is not a no-op)"
run_test test_unresolved_command_detector "Unresolvable command shape is detected (fallback branch is live)"
run_test test_unmatched_event_detector "Unmodellable event shape is rejected (fallback branch is live)"
run_test test_detector_fires "Silence detector distinguishes a '{}' emitter from a silent hook"

while IFS="$(printf '\t')" read -r script event matcher rawcmd; do
    [ -n "$event" ] || continue
    CUR_SCRIPT="$script"
    CUR_EVENT="$event"
    CUR_MATCHER="$matcher"
    CUR_RAWCMD="$rawcmd"
    if [ "$script" = "UNRESOLVED" ]; then
        run_test test_unresolved_command "$event :: hooks.json command shape is unrecognized"
        continue
    fi
    run_test test_hook_is_silent_on_noop "$(basename "$script") :: $event is silent on no-op"
done <<EOF
$CORPUS
EOF

run_test test_deny_path_still_emits "worktree-guard.sh still emits on the DENY path"
run_test test_bash_guard_deny_path_still_emits "bash-guard.sh still emits on the DENY path"
run_test test_read_guard_deny_path_still_emits "read-scope-guard.sh still emits on the DENY path"

generate_report
