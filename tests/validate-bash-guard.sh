#!/usr/bin/env bash
# Coverage for the PreToolUse Bash-guard hook
# plugins/workflow/hooks/bash-guard.sh (issue #448).
#
# The guard blocks destructive shell in read-only review/analysis SUBAGENTS while
# never blocking the main interactive session. Three behaviours carry the risk a
# silent regression would ship unnoticed, and each is a safety property:
#   1. POSITIVE-BLOCK — a destructive command from a subagent (agent_id present,
#      live-tree target) must be DENIED. A parse/tokenizer regression that turned
#      the guard into a permanent no-op would silently defeat the control; the
#      block-case assertions fail CI if it does.
#   2. MAIN-SESSION SAFETY — a destructive command with NO agent_id (the main
#      session, e.g. worktree teardown `rm -rf .worktrees/issue-N`) must be
#      ALLOWED. A guard that blocked session-wide would break the orchestrator's
#      happy path.
#   3. SANDBOX CARVE-OUT — a destructive op confined to /tmp/$TMPDIR/var-tmp, or
#      an op on a variable target when the command stages a `mktemp -d`, must be
#      ALLOWED (the sanctioned reproduce-in-sandbox shape).
#
# The guard's decision travels in its STDOUT JSON (permissionDecision deny) or its
# absence (allow), not the exit code (always 0). Each case pipes an inline
# PreToolUse payload to the REAL hook and asserts the decision — mirroring the
# inline-JSON style of validate-golem-notify.sh (no fixture files). The no-jq path
# is exercised via a PATH-stub (bash-only) to prove the pure-bash fallback still
# enforces #1 and preserves #2. A hooks.json-integrity block asserts the guard is
# actually registered (no other gate checks hook wiring).
#
# Pure bash + coreutils (+ jq for decision parsing, which skips cleanly when jq is
# absent), reached via absolute /usr/bin/* paths per project convention. Uses the
# shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$REPO_ROOT/plugins/workflow/hooks/bash-guard.sh"
HOOKS_JSON="$REPO_ROOT/plugins/workflow/hooks/hooks.json"

# Resolve the real bash once so the no-jq case (which strips PATH) still finds an
# interpreter.
REAL_BASH="$(command -v bash)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "bash-guard.sh PreToolUse hook (#448)"

# Module-level scratch dir for the no-jq stub, cleaned up once at exit.
WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# --- Runner -----------------------------------------------------------------
# run_guard <payload-json> [nojq] — pipe the payload to the REAL hook; capture
# stdout in GUARD_OUT and exit code in GUARD_RC. In "nojq" mode the child runs
# under a PATH containing only a bash symlink (no jq, no coreutils on PATH) to
# force the pure-bash fallback; the hook reaches its own tools via absolute paths,
# so it still functions.
GUARD_OUT=""
GUARD_RC=0
run_guard() {
    local payload="$1" mode="${2:-}"
    GUARD_RC=0
    if [ "$mode" = "nojq" ]; then
        local stub="$WORKDIR/stub-bin"
        command mkdir -p "$stub"
        command ln -sf "$REAL_BASH" "$stub/bash"
        GUARD_OUT="$(printf '%s' "$payload" |
            /usr/bin/env -i PATH="$stub" "$REAL_BASH" "$GUARD" 2>/dev/null)" || GUARD_RC=$?
    else
        GUARD_OUT="$(printf '%s' "$payload" | "$REAL_BASH" "$GUARD" 2>/dev/null)" || GUARD_RC=$?
    fi
}

# decision <stdout> — echo the permissionDecision, or "allow" when the hook
# emitted nothing (the allow path). Requires jq; callers that use it are guarded
# by the jq-availability check.
decision() {
    local out="$1"
    if [ -z "$out" ]; then
        printf 'allow\n'
        return 0
    fi
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || printf 'parse-error\n'
}

# jsonpayload <agent-field-json> <command> — build a PreToolUse Bash payload.
# <agent-field-json> is either '' (main session) or e.g. '"agent_id":"a1",'.
jsonpayload() {
    printf '{"tool_name":"Bash",%s"tool_input":{"command":"%s"}}' "$1" "$2"
}

# --- Deny cases (subagent, live target) -------------------------------------
# Each asserts the hook emits a permissionDecision:deny for a destructive command
# from a subagent (agent_id set) against a live-tree target.
CUR_CMD=""
CUR_AGENT='"agent_id":"a1",'
assert_deny() {
    local desc="$1"
    run_guard "$(jsonpayload "$CUR_AGENT" "$CUR_CMD")"
    assert_valid_json "$GUARD_OUT" "deny output is valid JSON ($desc)"
    assert_equals "deny" "$(decision "$GUARD_OUT")" "denied ($desc)"
}
assert_allow() {
    local desc="$1"
    run_guard "$(jsonpayload "$CUR_AGENT" "$CUR_CMD")"
    assert_equals "allow" "$(decision "$GUARD_OUT")" "allowed ($desc)"
    assert_output_empty "$GUARD_OUT" "allow path emits nothing ($desc)"
}

# Wrap each case so run_test drives it and jq-dependent asserts skip cleanly.
jq_required() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq unavailable"
        return 1
    fi
    return 0
}

test_deny_rm() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='rm -rf src/'
    assert_deny "rm -rf live path"
}
test_deny_rm_camel() {
    jq_required || return 0
    CUR_AGENT='"agentId":"a1",'
    CUR_CMD='rm -rf src/'
    assert_deny "rm with camelCase agentId"
}
test_deny_git_clean() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='git clean -fd'
    assert_deny "git clean"
}
test_deny_git_reset() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='git reset --hard HEAD~1'
    assert_deny "git reset --hard"
}
test_deny_git_checkout() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='git checkout -- file.py'
    assert_deny "git checkout -- file"
}
test_deny_mv() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='mv src/a.py src/b.py'
    assert_deny "mv"
}
test_deny_truncate() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='truncate -s 0 file'
    assert_deny "truncate"
}
test_deny_redirect() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='echo x > tracked.py'
    assert_deny "redirect to tracked path"
}
test_deny_chained() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='ls && rm -rf src'
    assert_deny "deny-head after &&"
}
test_deny_chained_reset() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='git status && git reset --hard'
    assert_deny "chained git reset --hard"
}
test_deny_env_prefix() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='FOO=bar rm -rf src'
    assert_deny "rm behind a VAR= assignment"
}

# The deny reason must name the matched token so the model can react.
test_deny_reason_names_token() {
    jq_required || return 0
    run_guard "$(jsonpayload '"agent_id":"a1",' 'git clean -fd')"
    local reason
    reason="$(printf '%s' "$GUARD_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)"
    assert_contains "$reason" "git clean" "deny reason names the matched token"
    assert_contains "$reason" "mktemp -d" "deny reason points at the sandbox carve-out"
}

# --- Bypass regressions (#448 adversarial review) ---------------------------
# These build the payload via jq so backslash/quote/newline command strings are
# encoded correctly. Each is a false-negative bypass the first cut allowed; the
# guard must DENY every one. deny_cmd/allow_cmd assert the decision for a raw
# command string carried by a subagent (agent_id set).
deny_cmd() {
    jq_required || return 0
    local out
    out="$(printf '%s' "$(jq -cn --arg c "$1" '{tool_name:"Bash",agent_id:"a1",tool_input:{command:$c}}')" | "$REAL_BASH" "$GUARD" 2>/dev/null)"
    assert_equals "deny" "$(decision "$out")" "denied ($2)"
}
allow_cmd() {
    jq_required || return 0
    local out
    out="$(printf '%s' "$(jq -cn --arg c "$1" '{tool_name:"Bash",agent_id:"a1",tool_input:{command:$c}}')" | "$REAL_BASH" "$GUARD" 2>/dev/null)"
    assert_equals "allow" "$(decision "$out")" "allowed ($2)"
}

test_bypass_bare_amp() { deny_cmd 'sleep 1 & rm -rf src' "deny-head after a bare & separator"; }
test_bypass_newline() { deny_cmd 'echo checking
rm -rf src' "deny-head after a literal newline"; }
test_bypass_dquote_head() { deny_cmd '"rm" -rf src/' "double-quoted command head"; }
test_bypass_squote_head() { deny_cmd "'rm' -rf src/" "single-quoted command head"; }
test_bypass_backslash_head() { deny_cmd '\rm -rf src/' "backslash-escaped command head (alias bypass)"; }
test_bypass_tmp_traversal() { deny_cmd 'rm -rf /tmp/../etc/passwd' "/tmp/.. path traversal out of the sandbox"; }
test_bypass_tmp_substring() { deny_cmd 'rm -rf src/tmp/live' "live path merely containing /tmp/"; }
test_bypass_early_redirect() { deny_cmd 'cmd 2> tracked.py > /tmp/log' "an early non-scratch redirect before a scratch one"; }
test_bypass_mixed_targets() { deny_cmd 'rm -rf /tmp/a live/b' "mixed scratch + live-literal rm targets"; }
# And the carve-outs these fixes must NOT over-broaden:
test_bypass_allow_multi_tmp() { allow_cmd 'rm -rf /tmp/a /tmp/b' "multiple scratch targets stay allowed"; }
test_bypass_allow_truncate_size() { allow_cmd 'truncate -s 0 /tmp/x' "truncate -s <size> value is not a path operand"; }
test_bypass_allow_fd_dup() { allow_cmd 'ls 2>&1 | wc -l' "a 2>&1 fd-dup is not a file redirect"; }
# Second adversarial pass (#448 review 2): these were regressions in the FIRST
# round of fixes — the deny path must survive them.
test_bypass_r_flag_skip() { deny_cmd 'rm -r src/live /tmp' "-r must not skip the live operand (rm recursive flag)"; }
test_bypass_r_flag_gitclean() { deny_cmd 'git clean -fd -r src/live -x /tmp' "git clean -r must not skip the live operand"; }
test_bypass_truncate_size_path() { deny_cmd 'truncate -s live/file.py /tmp/x' "a path-like -s value is still checked"; }
test_bypass_mktemp_unrelated_var() { deny_cmd 'd=$(mktemp -d); rm -rf $HOME/repo' "an unrelated \$HOME does not piggyback on a stray mktemp"; }
test_bypass_mktemp_pwd() { deny_cmd 'mktemp -d && rm -rf $PWD/src' "\$PWD live target is not the mktemp var"; }
# The genuine carve-out — deleting the exact mktemp var — must still be allowed,
# including a non-`d` variable name and a subpath under it.
test_carveout_named_var() { allow_cmd 'TMP=$(mktemp -d); rm -rf "$TMP"' "deleting the named mktemp var is allowed"; }
test_carveout_var_subpath() { allow_cmd 'd=$(mktemp -d); rm -rf "$d"/sub' "deleting a subpath of the mktemp var is allowed"; }
# Third adversarial pass (#448 review 3): compound-command keywords must not hide
# a deny-head, and the mktemp-var carve-out must survive the fix.
test_bypass_if_then() { deny_cmd 'if true; then rm -rf src; fi' "rm inside if/then is denied"; }
test_bypass_if_test_then() { deny_cmd 'if [ -d src ]; then rm -rf src; fi' "rm inside if [test]/then is denied"; }
test_bypass_case() { deny_cmd 'case x in *) rm -rf src ;; esac' "rm inside a case arm is denied"; }
test_bypass_while_do() { deny_cmd 'while true; do rm -rf src; break; done' "rm inside while/do is denied"; }
test_bypass_for_do() { deny_cmd 'for i in 1; do rm -rf src; done' "rm inside for/do is denied"; }
test_bypass_brace_group() { deny_cmd '{ rm -rf src; }' "rm inside a brace group is denied"; }
test_bypass_if_then_reset() { deny_cmd 'if true; then git reset --hard; fi' "git reset --hard inside if/then is denied"; }
test_carveout_survives_keywords() { allow_cmd 'd=$(mktemp -d); rm -rf "$d"' "the mktemp carve-out survives the keyword fix"; }
# Fourth adversarial pass (#448 review 4): git global options must not hide the
# destructive subcommand, and read-only git under -C must stay allowed.
test_bypass_git_C_clean() { deny_cmd 'git -C src clean -fd' "git -C <dir> clean is denied"; }
test_bypass_git_C_reset() { deny_cmd 'git -C src reset --hard' "git -C <dir> reset --hard is denied"; }
test_bypass_git_gitdir() { deny_cmd 'git --git-dir=.git clean -fd' "git --git-dir= clean is denied"; }
test_bypass_git_c_config() { deny_cmd 'git -c user.name=x reset --hard' "git -c cfg reset --hard is denied"; }
test_allow_git_C_diff() { allow_cmd 'git -C src diff --name-only' "read-only git -C diff stays allowed"; }
test_allow_git_C_log() { allow_cmd 'git -C src log --oneline' "read-only git -C log stays allowed"; }

# --- Allow cases (subagent, read-only) --------------------------------------
test_allow_gh() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='gh pr view 12 --json title'
    assert_allow "gh pr view"
}
test_allow_glab() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='glab pr checks'
    assert_allow "glab pr checks"
}
test_allow_git_diff() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='git diff --name-only main...HEAD'
    assert_allow "git diff --name-only"
}
test_allow_git_status() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='git status'
    assert_allow "git status"
}
test_allow_wc() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='wc -l file.py'
    assert_allow "wc"
}
test_allow_patterns() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='bash /skill/patterns.sh /tmp/scan.txt'
    assert_allow "patterns.sh prescan"
}
test_allow_checkout_branch() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='git checkout main'
    assert_allow "git checkout <branch> (no --)"
}
test_allow_reset_soft() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='git reset HEAD file'
    assert_allow "git reset HEAD (no --hard)"
}

# --- Main-session safety (no agent_id) --------------------------------------
# Since #662 the main session is no longer an UNCONDITIONAL allow: a destructive
# GIT verb aimed at ANOTHER session's linked worktree is denied (Rule B). These
# two cases keep asserting the allow side, and — because `jsonpayload` emits no
# `cwd` — they specifically pin Rule B's FAIL-OPEN path: with no cwd the target
# tree is unresolvable, and the guard must fall back to the historical allow
# rather than deny. The tree-aware cases (a real worktree topology on disk, and
# both mutation checks) live in the sibling tests/validate-bash-guard-worktree.sh,
# which this suite deliberately stays free of git fixtures for.
test_main_rm() {
    jq_required || return 0
    CUR_AGENT=''
    CUR_CMD='rm -rf .worktrees/issue-42'
    assert_allow "main-session worktree teardown rm"
}
test_main_git_clean() {
    jq_required || return 0
    CUR_AGENT=''
    CUR_CMD='git clean -fd'
    assert_allow "main-session git clean"
}

# --- Sandbox carve-out (subagent, scratch target) ---------------------------
test_scratch_rm_tmp() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='rm -rf /tmp/scan.XX/out'
    assert_allow "rm under /tmp"
}
test_scratch_rm_vartmp() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='rm -rf /var/tmp/x'
    assert_allow "rm under /var/tmp"
}
test_scratch_mktemp_var() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='d=$(mktemp -d) && rm -rf \"$d\"'
    assert_allow "mktemp -d then rm of the variable"
}
test_scratch_redirect_tmp() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='echo x > /tmp/scan/out'
    assert_allow "redirect into /tmp"
}
# A mktemp-staged command whose rm still targets a LIVE literal must NOT be carved out.
test_scratch_not_over_broad() {
    jq_required || return 0
    CUR_AGENT='"agent_id":"a1",'
    CUR_CMD='d=$(mktemp -d); rm -rf src/live'
    assert_deny "mktemp staged but rm targets a live literal"
}

# The mktemp_var extractor must be PORTABLE, not merely correct on this host
# (#679). It previously used a BRE whose `\(^\|…\)` alternation is a GNU
# extension: under BSD sed the substitution never fired, mktemp_var came back
# EMPTY, and the scratch-dir carve-out stopped recognizing its own subject —
# so the guard over-blocked a legitimate `rm -rf "$d"` (fail-safe, but wrong).
#
# The carve-out tests above cannot catch that: they run the extractor through
# whatever sed is on PATH, which in CI is always GNU, so they passed BOTH before
# and after the fix. This case pins the property directly instead — it runs the
# extractor's own expression under `sed --posix`, which reproduces BSD's reading
# of GNU regex extensions, and asserts the ERE selects the same variable name a
# GNU-flavored run does.
#
# Mutating the shipped expression back to the BRE makes the --posix arm return
# empty and this test fail, which is what makes it a real regression guard
# rather than a restatement of the happy path.
test_mktemp_extractor_is_sed_flavor_portable() {
    local expr line gnu posix
    # The exact expression bash-guard.sh uses (kept in sync by the assertion
    # below, which fails loudly if the script's form drifts from this one).
    expr='s/.*(^|[^A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=[`$]{1}[({]*mktemp[[:space:]].*/\2/p'
    line='d=$(mktemp -d)'

    gnu="$(command printf '%s\n' "$line" | command sed -E -n "$expr")"
    posix="$(command printf '%s\n' "$line" | command sed --posix -E -n "$expr" 2>/dev/null)"

    assert_equals "d" "$gnu" "the ERE extractor selects the mktemp var under GNU sed (#679)"
    # `sed --posix` is a GNU build flag; where it is unavailable the arm yields
    # empty and the equivalence assertion below is skipped rather than failing
    # for the wrong reason.
    if [ -n "$posix" ]; then
        assert_equals "$gnu" "$posix" \
            "...and selects the SAME name under BSD-flavored regex semantics (#679)"
    else
        skip_test "sed --posix unavailable — cannot exercise BSD regex semantics"
    fi

    # Guard against drift: the expression asserted above must be the one the
    # hook actually ships, or this test silently stops covering it.
    assert_contains "$(command cat "$GUARD")" "$expr" \
        "the expression under test is the one bash-guard.sh ships (anti-drift)"
}

# --- Parse-failure: fail-open + loud stderr ---------------------------------
test_parse_empty_allows() {
    run_guard ""
    assert_equals "0" "$GUARD_RC" "empty stdin exits 0 (fail-open)"
    assert_output_empty "$GUARD_OUT" "empty stdin emits no deny (allow)"
}
test_parse_empty_is_loud() {
    local err
    err="$(printf '' | "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)"
    assert_contains "$err" "bash-guard" "empty stdin logs a loud diagnostic"
}
test_parse_nonjson_allows() {
    run_guard "this is not json"
    assert_equals "allow" "$([ -z "$GUARD_OUT" ] && echo allow || echo other)" "non-JSON stdin allows"
}
test_parse_nonjson_is_loud() {
    local err
    err="$(printf 'not json' | "$REAL_BASH" "$GUARD" 2>&1 >/dev/null)"
    assert_contains "$err" "bash-guard" "non-JSON stdin logs a loud diagnostic"
}

# --- No-jq fallback still enforces the two core safety properties -----------
# Under a PATH with only bash, the pure-bash extractor must still (a) DENY a
# subagent rm and (b) ALLOW a main-session rm. Decision is read WITHOUT jq (the
# child had none), so we assert on the raw stdout shape.
test_nojq_blocks_subagent_rm() {
    run_guard "$(jsonpayload '"agent_id":"a1",' 'rm -rf src/')" nojq
    assert_contains "$GUARD_OUT" '"permissionDecision":"deny"' "no-jq path still denies a subagent rm"
}
test_nojq_allows_main_rm() {
    run_guard "$(jsonpayload '' 'rm -rf .worktrees/issue-1')" nojq
    assert_output_empty "$GUARD_OUT" "no-jq path allows a main-session rm"
}

# --- hooks.json integrity (no other gate checks hook registration) ----------
test_hooks_registered() {
    jq_required || return 0
    assert_file_exists "$HOOKS_JSON" "hooks.json exists"
    local ok
    ok="$(jq -r '
        (.hooks.PreToolUse // [])
        | map(select(.matcher == "Bash"
              and ((.hooks // []) | any(.command | test("bash-guard\\.sh")))))
        | length' "$HOOKS_JSON" 2>/dev/null || echo 0)"
    assert_equals "1" "$ok" "hooks.json registers a PreToolUse Bash matcher invoking bash-guard.sh"
}
test_guard_executable() {
    assert_true "[ -x \"$GUARD\" ]" "bash-guard.sh is executable"
}

# --- Dispatch ---------------------------------------------------------------
run_test test_deny_rm "deny: rm -rf against the live tree"
run_test test_deny_rm_camel "deny: rm with camelCase agentId"
run_test test_deny_git_clean "deny: git clean"
run_test test_deny_git_reset "deny: git reset --hard"
run_test test_deny_git_checkout "deny: git checkout -- file"
run_test test_deny_mv "deny: mv"
run_test test_deny_truncate "deny: truncate"
run_test test_deny_redirect "deny: redirect to tracked path"
run_test test_deny_chained "deny: deny-head after &&"
run_test test_deny_chained_reset "deny: chained git reset --hard"
run_test test_deny_env_prefix "deny: rm behind a VAR= assignment"
run_test test_deny_reason_names_token "deny reason names the token + sandbox"
run_test test_bypass_bare_amp "bypass: bare & separator denied"
run_test test_bypass_newline "bypass: literal newline separator denied"
run_test test_bypass_dquote_head "bypass: double-quoted head denied"
run_test test_bypass_squote_head "bypass: single-quoted head denied"
run_test test_bypass_backslash_head "bypass: backslash-escaped head denied"
run_test test_bypass_tmp_traversal "bypass: /tmp/.. traversal denied"
run_test test_bypass_tmp_substring "bypass: /tmp substring path denied"
run_test test_bypass_early_redirect "bypass: early non-scratch redirect denied"
run_test test_bypass_mixed_targets "bypass: mixed scratch+live targets denied"
run_test test_bypass_allow_multi_tmp "carve-out: multiple /tmp targets allowed"
run_test test_bypass_allow_truncate_size "carve-out: truncate -s value not a path"
run_test test_bypass_allow_fd_dup "carve-out: 2>&1 fd-dup allowed"
run_test test_bypass_r_flag_skip "review2: -r does not skip a live rm operand"
run_test test_bypass_r_flag_gitclean "review2: git clean -r does not skip live operand"
run_test test_bypass_truncate_size_path "review2: path-like -s value still checked"
run_test test_bypass_mktemp_unrelated_var "review2: unrelated \$HOME denied despite mktemp"
run_test test_bypass_mktemp_pwd "review2: \$PWD denied despite mktemp"
run_test test_carveout_named_var "carve-out: named mktemp var (\$TMP) allowed"
run_test test_carveout_var_subpath "carve-out: mktemp var subpath allowed"
run_test test_bypass_if_then "review3: rm inside if/then denied"
run_test test_bypass_if_test_then "review3: rm inside if [test]/then denied"
run_test test_bypass_case "review3: rm inside case arm denied"
run_test test_bypass_while_do "review3: rm inside while/do denied"
run_test test_bypass_for_do "review3: rm inside for/do denied"
run_test test_bypass_brace_group "review3: rm inside brace group denied"
run_test test_bypass_if_then_reset "review3: git reset --hard inside if denied"
run_test test_carveout_survives_keywords "review3: carve-out survives keyword fix"
run_test test_bypass_git_C_clean "review4: git -C clean denied"
run_test test_bypass_git_C_reset "review4: git -C reset --hard denied"
run_test test_bypass_git_gitdir "review4: git --git-dir= clean denied"
run_test test_bypass_git_c_config "review4: git -c cfg reset denied"
run_test test_allow_git_C_diff "review4: git -C diff allowed"
run_test test_allow_git_C_log "review4: git -C log allowed"
run_test test_allow_gh "allow: gh pr view"
run_test test_allow_glab "allow: glab pr checks"
run_test test_allow_git_diff "allow: git diff --name-only"
run_test test_allow_git_status "allow: git status"
run_test test_allow_wc "allow: wc"
run_test test_allow_patterns "allow: patterns.sh prescan"
run_test test_allow_checkout_branch "allow: git checkout <branch>"
run_test test_allow_reset_soft "allow: git reset HEAD (no --hard)"
run_test test_main_rm "main-session: teardown rm allowed"
run_test test_main_git_clean "main-session: git clean allowed"
run_test test_scratch_rm_tmp "scratch: rm under /tmp allowed"
run_test test_scratch_rm_vartmp "scratch: rm under /var/tmp allowed"
run_test test_scratch_mktemp_var "scratch: mktemp -d then rm var allowed"
run_test test_scratch_redirect_tmp "scratch: redirect into /tmp allowed"
run_test test_scratch_not_over_broad "scratch carve-out is not over-broad"
run_test test_mktemp_extractor_is_sed_flavor_portable "scratch: mktemp_var extractor is sed-flavor portable (#679)"
run_test test_parse_empty_allows "parse-fail: empty stdin allows"
run_test test_parse_empty_is_loud "parse-fail: empty stdin is loud"
run_test test_parse_nonjson_allows "parse-fail: non-JSON allows"
run_test test_parse_nonjson_is_loud "parse-fail: non-JSON is loud"
run_test test_nojq_blocks_subagent_rm "no-jq: still denies a subagent rm"
run_test test_nojq_allows_main_rm "no-jq: still allows a main rm"
run_test test_hooks_registered "hooks.json registers the guard"
run_test test_guard_executable "bash-guard.sh is executable"

generate_report
