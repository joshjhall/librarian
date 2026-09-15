#!/usr/bin/env bash
# Coverage for the escalation premise checker
# plugins/workflow/scripts/premise-check.sh (issue #911).
#
# The script answers ONE question before an operator ever sees an escalation
# option: is this option's premise still true? #911 recorded four false-premise
# decisions in a single orchestration session, and the behaviours whose silent
# regression would bring them back are:
#
#   1. THE CLOSED CASE (#860, acceptance criterion 6) — an option proposing work
#      that is already filed AND CLOSED must resolve `verdict=closed`, which is
#      what tells the caller to REMOVE the option rather than offer it. This is
#      the reproduction the issue asks for by name. Its failure mode is not an
#      error: it is an operator approving a duplicate of finished work, and at
#      L4 it would suspend a lane behind a merged PR.
#   2. OPEN vs CLOSED ARE DISTINCT — an open match must resolve `verdict=open`
#      with the issue number, because the caller's action differs (rewrite to
#      reference it, not remove). A regression collapsing the two into a boolean
#      "found" loses exactly the distinction #911 turns on, and would do so while
#      still looking like it worked.
#   3. UNAVAILABLE IS NEVER ABSENT (acceptance criterion 5) — with the CLI
#      missing, or present but failing, the verdict must be `unavailable` with a
#      reason, NEVER `absent`. This is the fail-toward-asking rule: `absent`
#      reads as "nothing exists, go ahead and file", so an outage rendered as
#      absent is an all-clear nobody checked. Both arms are tested separately
#      because they reach the verdict by different paths (PATH probe vs exit
#      status), and a fix to one has historically left the other.
#   4. BODY CONSTRAINTS ARE EXTRACTED (#550) — a constraint stated in the issue
#      body must come back as a `constraint=` line, so an option cannot silently
#      contradict the issue's own text.
#   5. FAIL LOUD ON BAD INPUT — usage errors exit 2 rather than emitting a
#      verdict, so a malformed call can never be mistaken for a real answer.
#
# Test shape mirrors tests/validate-golem-inbox.sh: the REAL script runs inside a
# fresh `git init` sandbox under a module-level `mktemp -d`, with git's
# hook-exported environment scrubbed so a pre-push-hook run stays hermetic, and
# HOME repointed at the sandbox.
#
# `gh` IS ALWAYS A STUB — this suite never touches the live API. Every case
# writes a small `gh` (or `glab`) script into a per-sandbox stub dir and puts it
# first on PATH, so the verdicts are driven by fixture payloads rather than by
# whatever the real backlog happens to contain today. A suite that queried the
# live tracker would change its verdict when an issue was closed, which is the
# opposite of a regression test.
#
# BASH_ENV is unset for every child: this devcontainer's /etc/bash_env resets
# $PATH, which silently undoes the stub PATH and lets the REAL gh answer. That
# was observed during development — the stub never ran and every case reported
# `unavailable` — so the `-uBASH_ENV` below is load-bearing, not boilerplate.
#
# Pure bash + coreutils + git, reached per project convention. Uses the shared
# harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREMISE="$REPO_ROOT/plugins/workflow/scripts/premise-check.sh"

# Resolve the real bash / git / env once so a stubbed PATH still finds them.
REAL_BASH="$(command -v bash)"
REAL_GIT="$(command -v git 2>/dev/null || true)"
REAL_ENV="$(command -v env)"

# Git's hook-exported environment — scrub per invocation so each sandbox is
# hermetic even under a pre-push hook (see validate-golem-inbox.sh).
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "premise-check.sh escalation premise checker (#911)"

# --- Sandbox plumbing -------------------------------------------------------

# Module-level scratch dir, cleaned up once when the suite exits.
# PHYSICAL path: macOS $TMPDIR is under /var, a symlink to /private/var, so
# `mktemp -d` returns /var/... while git-based code resolves the same dir to
# /private/var/... Any prefix match between the two spellings fails (#932).
WORKDIR="$(command mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && command pwd -P)"
trap 'command rm -rf "$WORKDIR"' EXIT

# new_sandbox <varname>
# A fresh `git init` repo with a stub-bin dir. The script reads the origin remote
# for platform detection, so a bare init (no commit) is enough; every case passes
# --platform explicitly anyway, which keeps the fixtures independent of whatever
# remote the sandbox has.
new_sandbox() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
        git -C "$dir" init -q 2>/dev/null || return 1
    command mkdir -p "$dir/stub-bin"
    printf -v "$__out" '%s' "$dir"
}

# stub_cli <sandbox> <name> <body>
# Write an executable stub for `gh` or `glab` into the sandbox's stub dir.
# The body is the script's case logic; it receives the CLI's argv.
stub_cli() {
    local dir="$1" name="$2" body="$3"
    {
        command printf '%s\n' '#!/usr/bin/env bash'
        command printf '%s\n' "$body"
    } >"$dir/stub-bin/$name"
    command chmod +x "$dir/stub-bin/$name"
}

# Results of the most recent invocation. PC_OUT merges stdout+stderr (convenient
# for asserting on messages); PC_STDOUT holds stdout ALONE. The split matters for
# the usage cases: the help text on stderr legitimately documents the string
# "verdict=", so "a usage error emits no verdict" can only be asserted against
# the stream a caller actually parses.
PC_RC=0
PC_OUT=""
PC_STDOUT=""

# run_premise <sandbox> <arg...>
# Run the real script from inside the sandbox with the stub dir FIRST on PATH,
# GIT_* scrubbed, HOME pinned, and BASH_ENV unset (see the header — without it
# the devcontainer profile restores PATH and the real gh answers).
run_premise() {
    local dir="$1"
    shift
    PC_RC=0
    PC_STDOUT="$(
        cd "$dir" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
                PATH="$dir/stub-bin:$PATH" HOME="$dir" \
                "$REAL_BASH" "$PREMISE" "$@" 2>/dev/null
    )" || PC_RC=$?
    PC_OUT="$(
        cd "$dir" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
                PATH="$dir/stub-bin:$PATH" HOME="$dir" \
                "$REAL_BASH" "$PREMISE" "$@" 2>&1
    )" || true
}

# run_premise_bare <sandbox> <arg...>
# Same, but with a PATH holding ONLY bash (an empty stub dir) — so the CLI is
# genuinely absent and the not-found branch is reached. bash must stay on PATH
# for the shebang; git need not, since platform is passed explicitly.
run_premise_bare() {
    local dir="$1"
    shift
    local empty="$dir/empty-bin"
    command mkdir -p "$empty"
    command ln -sf "$REAL_BASH" "$empty/bash"
    [ -n "$REAL_GIT" ] && command ln -sf "$REAL_GIT" "$empty/git"
    command ln -sf "$REAL_ENV" "$empty/env"
    PC_RC=0
    PC_STDOUT="$(
        cd "$dir" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
                PATH="$empty" HOME="$dir" \
                "$REAL_BASH" "$PREMISE" "$@" 2>/dev/null
    )" || PC_RC=$?
    PC_OUT="$(
        cd "$dir" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
                PATH="$empty" HOME="$dir" \
                "$REAL_BASH" "$PREMISE" "$@" 2>&1
    )" || true
}

# --- Fixture payloads -------------------------------------------------------

# The #860 shape: the work IS tracked, and the tracking issue is CLOSED (it
# merged in PR #905). An option proposing to file it is premised on absence.
STUB_CLOSED='case "$*" in
  *"--json number,title,state,url"*)
    echo "[{\"number\":859,\"title\":\"split validate-source-detectors\",\"state\":\"CLOSED\",\"url\":\"https://example/859\"}]" ;;
  *) echo "[]" ;;
esac
exit 0'

# The #707 shape: already filed and still OPEN — the option should be rewritten
# to reference it, not removed.
STUB_OPEN='case "$*" in
  *"--json number,title,state,url"*)
    echo "[{\"number\":859,\"title\":\"split validate-source-detectors\",\"state\":\"OPEN\",\"url\":\"https://example/859\"}]" ;;
  *) echo "[]" ;;
esac
exit 0'

# Nothing tracked — the option stands as written.
STUB_EMPTY='echo "[]"
exit 0'

# Present but failing (auth expired, rate limited, offline).
STUB_FAILING='echo "API rate limit exceeded" >&2
exit 1'

# The #550 shape: the issue body states a constraint the options dropped.
STUB_BODY='case "$*" in
  *"--json body"*)
    printf "%s" "{\"body\":\"## Problem\nSomething is wrong.\n\n- consider keeping \`scope-drift\` inline even on the cheap path\n- an ordinary descriptive line with no constraint\n\"}" ;;
  *) echo "{}" ;;
esac
exit 0'

# --- 1. The closed case (#860, acceptance criterion 6) ----------------------

# THE headline regression test. An option proposing work that is already filed
# and CLOSED must not reach the operator as offered — `verdict=closed` is the
# signal that removes it. Asserting `absent` is NOT present is the half that
# matters: a regression would most likely fail open (report nothing found), which
# renders as permission to file the duplicate.
test_closed_issue_is_flagged() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh "$STUB_CLOSED"
    run_premise "$sb" exists --title "split validate-source-detectors" --platform github
    assert_exit 0 "$PC_RC" "closed hit exits 0"
    assert_contains "$PC_OUT" "verdict=closed" \
        "#860 case: already-filed-and-closed work resolves verdict=closed"
    assert_contains "$PC_OUT" "issue=859" "closed hit names the tracking issue"
    assert_not_contains "$PC_OUT" "verdict=absent" \
        "#860 case: a closed match is NEVER reported as absent (that would offer the duplicate)"
}

# --- 2. Open and closed are distinct ---------------------------------------

test_open_issue_is_flagged() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh "$STUB_OPEN"
    run_premise "$sb" exists --title "split validate-source-detectors" --platform github
    assert_exit 0 "$PC_RC" "open hit exits 0"
    assert_contains "$PC_OUT" "verdict=open" \
        "#707 case: an open tracking issue resolves verdict=open (rewrite, not remove)"
    assert_contains "$PC_OUT" "issue=859" "open hit names the issue to reference"
    assert_contains "$PC_OUT" "url=https://example/859" "open hit carries the url"
    assert_not_contains "$PC_OUT" "verdict=closed" \
        "an OPEN match is not conflated with a closed one (different caller action)"
}

test_no_match_is_absent() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh "$STUB_EMPTY"
    run_premise "$sb" exists --title "something nobody has ever filed" --platform github
    assert_exit 0 "$PC_RC" "no match exits 0"
    assert_contains "$PC_OUT" "verdict=absent" \
        "nothing tracked resolves verdict=absent (the option stands)"
}

# --- 3. Unavailable is never absent (acceptance criterion 5) ----------------

# The CLI is not installed at all. The verdict must say the check did not run —
# reporting `absent` here would tell the caller "nothing exists" on the strength
# of no evidence whatsoever.
test_cli_missing_is_unavailable() {
    local sb
    new_sandbox sb
    run_premise_bare "$sb" exists --title "anything at all" --platform github
    assert_exit 0 "$PC_RC" "unavailable is a result, not a failure — exits 0"
    assert_contains "$PC_OUT" "verdict=unavailable" \
        "AC5: gh absent resolves verdict=unavailable"
    assert_contains "$PC_OUT" "reason=" "unavailable carries a reason the caller can quote"
    assert_not_contains "$PC_OUT" "verdict=absent" \
        "AC5: a missing CLI is NEVER reported as absent (an outage is not an all-clear)"
}

# The CLI exists but the query fails. Reached by a different path than the case
# above (exit status, not the PATH probe), and historically the arm that gets
# missed when the other is fixed.
test_cli_failing_is_unavailable() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh "$STUB_FAILING"
    run_premise "$sb" exists --title "anything at all" --platform github
    assert_exit 0 "$PC_RC" "a failed query still exits 0 with a verdict"
    assert_contains "$PC_OUT" "verdict=unavailable" \
        "AC5: a failing gh query resolves verdict=unavailable"
    assert_not_contains "$PC_OUT" "verdict=absent" \
        "AC5: a failed query is NEVER reported as absent"
}

test_constraints_unavailable_when_cli_missing() {
    local sb
    new_sandbox sb
    run_premise_bare "$sb" constraints --issue 550 --platform github
    assert_exit 0 "$PC_RC" "constraints unavailable exits 0"
    assert_contains "$PC_OUT" "verdict=unavailable" \
        "AC5: the constraint sweep also reports when it did not run"
    assert_not_contains "$PC_OUT" "verdict=none" \
        "AC5: an unrun sweep is NEVER reported as 'no constraints found'"
}

# --- 4. Body constraints are extracted (#550) ------------------------------

test_constraints_extracted_from_body() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh "$STUB_BODY"
    run_premise "$sb" constraints --issue 550 --platform github
    assert_exit 0 "$PC_RC" "constraint sweep exits 0"
    assert_contains "$PC_OUT" "verdict=found" "a body constraint resolves verdict=found"
    assert_contains "$PC_OUT" "consider keeping" \
        "#550 case: the issue's own stated constraint is surfaced, not dropped"
    assert_contains "$PC_OUT" "scope-drift" "the constraint text carries its subject"
    assert_not_contains "$PC_OUT" "an ordinary descriptive line" \
        "a line with no constraint marker is not emitted (the sweep is not a body dump)"
}

test_constraints_none_when_body_is_plain() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh 'case "$*" in
  *"--json body"*) printf "%s" "{\"body\":\"Just a plain description with nothing binding in it.\"}" ;;
  *) echo "{}" ;;
esac
exit 0'
    run_premise "$sb" constraints --issue 551 --platform github
    assert_exit 0 "$PC_RC" "plain body exits 0"
    assert_contains "$PC_OUT" "verdict=none" "a body with no constraints resolves verdict=none"
}

# --- 5. Fail loud on bad input ---------------------------------------------

test_missing_title_fails_loud() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh "$STUB_EMPTY"
    run_premise "$sb" exists --platform github
    assert_exit 2 "$PC_RC" "exists without --title exits 2"
    assert_not_contains "$PC_STDOUT" "verdict=" \
        "a usage error emits NO verdict on stdout (it must not be mistaken for an answer)"
}

test_missing_issue_fails_loud() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh "$STUB_EMPTY"
    run_premise "$sb" constraints --platform github
    assert_exit 2 "$PC_RC" "constraints without --issue exits 2"
    assert_not_contains "$PC_STDOUT" "verdict=" "a usage error emits no verdict on stdout"
}

test_non_numeric_issue_fails_loud() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh "$STUB_EMPTY"
    run_premise "$sb" constraints --issue "not-a-number" --platform github
    assert_exit 2 "$PC_RC" "a non-numeric --issue exits 2"
}

test_bad_platform_fails_loud() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh "$STUB_EMPTY"
    run_premise "$sb" exists --title "x" --platform bitbucket
    assert_exit 2 "$PC_RC" "an unsupported --platform exits 2"
}

test_unknown_subcommand_fails_loud() {
    local sb
    new_sandbox sb
    run_premise "$sb" frobnicate
    assert_exit 2 "$PC_RC" "an unknown subcommand exits 2"
    assert_contains "$PC_OUT" "usage:" "the usage block is printed on a bad subcommand"
}

test_no_subcommand_fails_loud() {
    local sb
    new_sandbox sb
    run_premise "$sb"
    assert_exit 2 "$PC_RC" "no subcommand exits 2"
}

# --- 6. GitLab parity -------------------------------------------------------

# The same three-state contract must hold on the other platform, since a golem
# picks its CLI from the remote. `iid` + `web_url` + lowercase "opened" is
# GitLab's spelling of the same record.
test_gitlab_open_hit() {
    local sb
    new_sandbox sb
    stub_cli "$sb" glab 'echo "[{\"iid\":77,\"title\":\"a tracked thing\",\"state\":\"opened\",\"web_url\":\"https://gl/77\"}]"
exit 0'
    run_premise "$sb" exists --title "a tracked thing" --platform gitlab
    assert_exit 0 "$PC_RC" "gitlab open hit exits 0"
    assert_contains "$PC_OUT" "verdict=open" "gitlab: an opened issue resolves verdict=open"
    assert_contains "$PC_OUT" "issue=77" "gitlab: the iid is read as the issue number"
}

test_gitlab_missing_cli_is_unavailable() {
    local sb
    new_sandbox sb
    run_premise_bare "$sb" exists --title "x" --platform gitlab
    assert_contains "$PC_OUT" "verdict=unavailable" \
        "gitlab: a missing glab resolves unavailable, not absent"
    assert_not_contains "$PC_OUT" "verdict=absent" "gitlab: outage is not an all-clear"
}

# --- 7. Record parsing is BSD-clean (review cycle 1) ------------------------

# The number/state/url extraction originally used BRE alternation (`\(number\|iid\)`),
# which is a GNU sed extension: BSD sed reads `\|` as a LITERAL pipe, so the
# substitution never fires, `_pm_num` stays empty, every record is skipped, and
# the verdict falls through to `absent` — on macOS, silently, at exit 0. That is
# the #860 defect reached through the parser instead of through the query, and it
# is invisible to a GNU-sed CI runner.
#
# This case pins the parse against a record whose keys appear in a DIFFERENT
# order from the fixtures above (url before number, state last) and whose title
# itself contains the substrings `number` and `state`. A pattern that anchors
# loosely, or one that has stopped matching and is being rescued by some other
# code path, does not survive it.
test_record_parse_is_order_independent() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh 'case "$*" in
  *"--json number,title,state,url"*)
    echo "[{\"url\":\"https://example/861\",\"title\":\"renumber the state machine\",\"number\":861,\"state\":\"OPEN\"}]" ;;
  *) echo "[]" ;;
esac
exit 0'
    run_premise "$sb" exists --title "renumber the state machine" --platform github
    assert_contains "$PC_OUT" "verdict=open" \
        "a record with reordered keys still parses (no BRE alternation to lose on BSD)"
    assert_contains "$PC_OUT" "issue=861" \
        "the issue number is extracted, not a digit from the title or url"
    assert_contains "$PC_OUT" "url=https://example/861" "the url is extracted"
    assert_not_contains "$PC_OUT" "verdict=absent" \
        "a parse that stops matching must never degrade to absent (it would offer the duplicate)"
}

# A multi-record payload is the NORMAL case, not an edge one: the query passes
# `--limit 20`, so any real backlog hit arrives alongside neighbours. The
# record-splitting sed and the open-preferred-over-closed precedence only do
# anything at all on such a payload, and both were previously exercised only by
# single-record fixtures.
#
# The fixture puts the CLOSED record FIRST so the precedence is doing real work:
# a scan that simply took the first record would answer `closed` here, which is
# the opposite caller action (remove the option rather than reference it).
test_open_wins_over_closed_in_multi_record() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh 'case "$*" in
  *"--json number,title,state,url"*)
    echo "[{\"number\":801,\"title\":\"older attempt\",\"state\":\"CLOSED\",\"url\":\"https://example/801\"},{\"number\":859,\"title\":\"the live one\",\"state\":\"OPEN\",\"url\":\"https://example/859\"},{\"number\":700,\"title\":\"another\",\"state\":\"CLOSED\",\"url\":\"https://example/700\"}]" ;;
  *) echo "[]" ;;
esac
exit 0'
    run_premise "$sb" exists --title "the live one" --platform github
    assert_contains "$PC_OUT" "verdict=open" \
        "an OPEN record wins over a CLOSED one listed before it (precedence, not first-record)"
    assert_contains "$PC_OUT" "issue=859" "the OPEN issue is the one reported"
    assert_not_contains "$PC_OUT" "issue=801" "the earlier closed record is not reported"
}

# All-closed multi-record: the #860 shape as it actually arrives from a real
# query. The first closed record wins, and `absent` must not appear.
test_multi_record_all_closed() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh 'case "$*" in
  *"--json number,title,state,url"*)
    echo "[{\"number\":859,\"title\":\"the merged split\",\"state\":\"CLOSED\",\"url\":\"https://example/859\"},{\"number\":700,\"title\":\"another\",\"state\":\"CLOSED\",\"url\":\"https://example/700\"}]" ;;
  *) echo "[]" ;;
esac
exit 0'
    run_premise "$sb" exists --title "the merged split" --platform github
    assert_contains "$PC_OUT" "verdict=closed" \
        "#860 at real payload size: an all-closed multi-record result resolves closed"
    assert_contains "$PC_OUT" "issue=859" "the first closed record is reported"
    assert_not_contains "$PC_OUT" "verdict=absent" \
        "a multi-record closed hit is NEVER absent (the record split must actually split)"
}

# --- 8. Search-term filtering (review cycle 1) ------------------------------

# `search_terms` drops one-character tokens. A single global sed substitution
# cannot do this — adjacent singles share the space the pattern consumes, so
# `a b c split` keeps `b` — hence the per-token loop. This asserts the adjacency
# case specifically, since that is the spelling that silently half-works.
test_single_char_tokens_are_dropped() {
    local sb
    new_sandbox sb
    # The stub RECORDS the --search terms it was handed to a side file, so the
    # assertion reads the ACTUAL query rather than trusting the function in
    # isolation. A side file, not stdout: stdout is the JSON payload the script
    # parses, so anything echoed there would be consumed as a record instead.
    stub_cli "$sb" gh 'prev=""
for a in "$@"; do
  case "$prev" in --search) printf "%s" "$a" >"$HOME/terms.txt" ;; esac
  prev="$a"
done
echo "[]"
exit 0'
    run_premise "$sb" exists --title "a b c split detectors" --platform github
    local terms=""
    [ -f "$sb/terms.txt" ] && terms="$(command cat "$sb/terms.txt")"
    assert_equals "split detectors" "$terms" \
        "adjacent single-character tokens are ALL dropped (a global sed pass would keep 'b')"
}

# The empty-keyword branch: a title with no multi-character token yields no
# searchable terms, which must resolve `unavailable` — never a search on an empty
# string, and never `absent`.
test_no_searchable_keywords_is_unavailable() {
    local sb
    new_sandbox sb
    stub_cli "$sb" gh "$STUB_EMPTY"
    run_premise "$sb" exists --title "?! x y ?!" --platform github
    assert_exit 0 "$PC_RC" "no searchable keywords exits 0"
    assert_contains "$PC_OUT" "verdict=unavailable" \
        "a title yielding no keywords resolves unavailable (the check did not run)"
    assert_contains "$PC_OUT" "searchable keywords" "the reason names the cause"
    assert_not_contains "$PC_OUT" "verdict=absent" \
        "an unsearchable title is NEVER reported as absent"
}

# --- Dispatch ---------------------------------------------------------------

run_test test_closed_issue_is_flagged "#860 repro: already-filed-and-closed work → verdict=closed"
run_test test_open_issue_is_flagged "#707 repro: open tracking issue → verdict=open (rewrite)"
run_test test_no_match_is_absent "nothing tracked → verdict=absent"
run_test test_cli_missing_is_unavailable "AC5: gh absent → unavailable, never absent"
run_test test_cli_failing_is_unavailable "AC5: gh failing → unavailable, never absent"
run_test test_constraints_unavailable_when_cli_missing "AC5: unrun sweep → unavailable, never none"
run_test test_constraints_extracted_from_body "#550 repro: body constraint is surfaced"
run_test test_constraints_none_when_body_is_plain "plain body → verdict=none"
run_test test_missing_title_fails_loud "usage: exists without --title → exit 2, no verdict"
run_test test_missing_issue_fails_loud "usage: constraints without --issue → exit 2, no verdict"
run_test test_non_numeric_issue_fails_loud "usage: non-numeric --issue → exit 2"
run_test test_bad_platform_fails_loud "usage: unsupported --platform → exit 2"
run_test test_unknown_subcommand_fails_loud "usage: unknown subcommand → exit 2 + usage"
run_test test_no_subcommand_fails_loud "usage: no subcommand → exit 2"
run_test test_gitlab_open_hit "gitlab: iid/web_url/opened parse to verdict=open"
run_test test_gitlab_missing_cli_is_unavailable "gitlab: missing glab → unavailable"
run_test test_record_parse_is_order_independent "parse: reordered keys still resolve (no BRE \\| to lose on BSD)"
run_test test_open_wins_over_closed_in_multi_record "parse: OPEN wins over a CLOSED record listed first"
run_test test_multi_record_all_closed "parse: all-closed multi-record → closed, never absent"
run_test test_single_char_tokens_are_dropped "search terms: adjacent single-char tokens are all dropped"
run_test test_no_searchable_keywords_is_unavailable "search terms: no keywords → unavailable, never absent"

generate_report
