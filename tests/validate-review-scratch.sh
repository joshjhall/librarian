#!/usr/bin/env bash
# review-scratch.sh — per-run review scratch directory (issue #1094).
#
# Every solo golem used to share $HOME/.cache/librarian-review/solo/, never
# cleared, so one issue's cycle JSON fed another issue's convergence decision.
# Each acceptance criterion maps to a case below, and each case is built on an
# input where the OLD derivation gives the wrong answer — asserting a fresh dir
# on a fixture that was already empty would pass with and without the fix.
#
#   AC1 different issues never share  -> test_solo_runs_on_different_issues_are_isolated
#   AC2 cycle 1 never sees stale files -> test_init_removes_an_earlier_runs_files
#   AC3 one derivation at every site   -> test_every_recipe_site_uses_the_helper
#       (+ #1107: each loop's init is cycle-1-only and paired with path)
#
# #1157 ties a dir to one run: init stamps the issue + a fresh run nonce, and
# path refuses a dir whose stamp is absent, foreign or malformed.
#   init stamps / path echoes the run  -> test_init_stamps_a_run_that_path_echoes
#   path refuses an unowned dir        -> test_path_refuses_a_dir_it_cannot_vouch_for
#
# #1166 adds `remove`, the teardown verb worktree-rm.sh calls.
#   remove deletes golem-N + solo-N    -> test_remove_deletes_both_ids_for_the_issue
#   remove refuses a link / escape     -> test_remove_refuses_a_dir_it_does_not_own
#
# Every run uses a sandboxed HOME; the real cache is never touched.
#
# Pure bash + coreutils via `command`. bash-3.2 clean, BSD-regex clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RS="$REPO_ROOT/plugins/workflow/scripts/review-scratch.sh"
SHIP="$REPO_ROOT/plugins/workflow/skills/ship-issue"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "review-scratch.sh per-run scratch dir (#1094)"

SANDBOX="$(command mktemp -d)"
trap 'command rm -rf "$SANDBOX"' EXIT

# val <key> <output> — echo the value of a `key=value` line.
val() {
    command printf '%s\n' "$2" | command grep "^$1=" | command sed "s/^$1=//"
}

# rs [ENV=...] -- <args> — run the helper with a sandboxed HOME and GOLEM_ID
# scrubbed unless the caller sets it. Prints combined output; status in $RC.
rs() {
    RC=0
    OUT="$(command env -uGOLEM_ID HOME="$SANDBOX/home" "$@" 2>&1)" || RC=$?
}

test_solo_runs_on_different_issues_are_isolated() {
    rs bash "$RS" init --issue 1094
    assert_exit 0 "$RC" "solo init succeeds"
    local a b
    a="$(val dir "$OUT")"
    assert_equals "solo-1094" "$(val gid "$OUT")" "solo gid is scoped by issue"
    assert_equals "$SANDBOX/home/.cache/librarian-review/solo-1094" "$a" \
        "dir sits under \$HOME/.cache/librarian-review"
    assert_true "[ -d '$a' ]" "init creates the directory"

    rs bash "$RS" init --issue 1095
    b="$(val dir "$OUT")"
    assert_not_empty "$b" "second issue yields a dir"
    if [ "$a" = "$b" ]; then
        _fail "two solo issues share one scratch dir" "Dir: $a"
    fi
}

test_golem_id_wins_over_the_issue() {
    rs GOLEM_ID=golem-7 bash "$RS" init --issue 1094
    assert_exit 0 "$RC" "orchestrated init succeeds"
    assert_equals "golem-7" "$(val gid "$OUT")" "GOLEM_ID is the gid when set"
    assert_equals "$SANDBOX/home/.cache/librarian-review/golem-7" "$(val dir "$OUT")" \
        "orchestrated dir is keyed by GOLEM_ID"

    rs GOLEM_ID= bash "$RS" init --issue 12
    assert_equals "solo-12" "$(val gid "$OUT")" "an empty GOLEM_ID reads as unset"
}

test_init_removes_an_earlier_runs_files() {
    rs bash "$RS" init --issue 77
    local d
    d="$(val dir "$OUT")"
    command printf '{"stale":true}\n' >"$d/cycle1.json"

    rs bash "$RS" path --issue 77
    assert_true "[ -f '$d/cycle1.json' ]" "path keeps the run's own files between cycles"

    rs bash "$RS" init --issue 77
    assert_exit 0 "$RC" "init succeeds"
    assert_equals "$d" "$(val dir "$OUT")" "init and path agree on the dir"
    assert_true "[ -d '$d' ]" "init leaves the directory in place"
    assert_true "[ ! -e '$d/cycle1.json' ]" "init removes an earlier run's cycle JSON"
}

test_init_on_a_symlinked_dir_removes_only_the_link() {
    local target="$SANDBOX/outside" base="$SANDBOX/home/.cache/librarian-review"
    command mkdir -p "$target" "$base"
    command printf 'keep\n' >"$target/sentinel"
    command ln -s "$target" "$base/solo-88"

    rs bash "$RS" init --issue 88
    assert_exit 0 "$RC" "init over a symlink succeeds"
    assert_true "[ -f '$target/sentinel' ]" "init never deletes through a symlink"
    assert_true "[ -d '$base/solo-88' ] && [ ! -L '$base/solo-88' ]" \
        "init replaces the link with a real directory"
}

test_unsafe_inputs_fail_loud() {
    local base="$SANDBOX/home/.cache/librarian-review"
    command mkdir -p "$base/keep"
    command printf 'keep\n' >"$base/keep/sentinel"

    rs bash "$RS" init
    assert_exit 2 "$RC" "missing --issue is refused"
    rs bash "$RS" init --issue abc
    assert_exit 2 "$RC" "non-numeric --issue is refused"
    rs bash "$RS" init --issue ""
    assert_exit 2 "$RC" "empty --issue is refused"
    rs bash "$RS" init --issue 0
    assert_exit 2 "$RC" "--issue 0 is refused"
    rs bash "$RS" init --issue 007
    assert_exit 2 "$RC" "a leading-zero --issue is refused (the stamp is compared as a string)"
    rs GOLEM_ID=.. bash "$RS" init --issue 1
    assert_exit 2 "$RC" "GOLEM_ID=.. is refused"
    rs GOLEM_ID=../keep bash "$RS" init --issue 1
    assert_exit 2 "$RC" "GOLEM_ID with a separator is refused"
    rs GOLEM_ID=. bash "$RS" init --issue 1
    assert_exit 2 "$RC" "GOLEM_ID=. is refused"
    assert_true "[ -f '$base/keep/sentinel' ]" "no refused init deleted anything"

    RC=0
    OUT="$(command env -uGOLEM_ID HOME= bash "$RS" path --issue 1 2>&1)" || RC=$?
    assert_exit 2 "$RC" "empty HOME is refused"
    RC=0
    OUT="$(command env -uGOLEM_ID HOME=relative bash "$RS" path --issue 1 2>&1)" || RC=$?
    assert_exit 2 "$RC" "relative HOME is refused"

    rs bash "$RS" wipe --issue 1
    assert_exit 2 "$RC" "unknown subcommand is refused"
    rs bash "$RS" path --issue 1 --bogus
    assert_exit 2 "$RC" "unknown flag is refused"
}

# stamp_of <dir> — the stamp file init writes; one spelling for every case.
stamp_of() {
    command printf '%s/.scratch-stamp' "$1"
}

test_init_stamps_a_run_that_path_echoes() {
    local d r1 r2
    rs bash "$RS" init --issue 1157
    assert_exit 0 "$RC" "init succeeds"
    d="$(val dir "$OUT")"
    r1="$(val run "$OUT")"
    assert_true "printf '%s' '$r1' | grep -E '^[0-9a-f]{16}\$' >/dev/null" \
        "init mints a 16-hex run nonce (got '$r1')"
    assert_equals "issue=1157" "$(command grep '^issue=' "$(stamp_of "$d")")" \
        "the stamp names the issue"
    assert_equals "run=$r1" "$(command grep '^run=' "$(stamp_of "$d")")" \
        "the stamp holds the nonce init printed"

    rs bash "$RS" path --issue 1157
    assert_exit 0 "$RC" "path on this issue's dir succeeds"
    assert_equals "$r1" "$(val run "$OUT")" "path echoes the stamped run, not a new one"
    assert_equals "$d" "$(val dir "$OUT")" "path and init agree on the dir"

    # A second init is a new run: a re-run of the same issue must not reuse the
    # nonce, or its result files would pass as this run's (#1157 gap 1).
    rs bash "$RS" init --issue 1157
    r2="$(val run "$OUT")"
    assert_not_empty "$r2" "the second init mints a run"
    if [ "$r1" = "$r2" ]; then
        _fail "two inits minted the same run nonce" "Run: $r1"
    fi
}

test_path_refuses_a_dir_it_cannot_vouch_for() {
    local base="$SANDBOX/home/.cache/librarian-review" d
    # No dir at all: path used to CREATE it, silently starting a fresh run with
    # no --prev-result history.
    rs bash "$RS" path --issue 501
    assert_exit 2 "$RC" "path with no dir is refused"
    assert_contains "$OUT" "no scratch dir for this run" "the refusal names the missing dir"
    assert_contains "$OUT" "init --issue 501" "the refusal says to run init"
    assert_true "[ ! -e '$base/solo-501' ]" "a refused path creates nothing"

    # An unstamped dir — what every pre-#1157 run left behind.
    command mkdir -p "$base/solo-502"
    rs bash "$RS" path --issue 502
    assert_exit 2 "$RC" "path on an unstamped dir is refused"
    assert_contains "$OUT" "no readable run stamp" "the refusal names the missing stamp"

    # A stamp for another issue: one GOLEM_ID reused across two issues.
    rs GOLEM_ID=golem-9 bash "$RS" init --issue 503
    rs GOLEM_ID=golem-9 bash "$RS" path --issue 504
    assert_exit 2 "$RC" "path on another issue's dir is refused"
    assert_contains "$OUT" "stamped for issue 503, not --issue 504" "the refusal names both issues"
    rs GOLEM_ID=golem-9 bash "$RS" path --issue 503
    assert_exit 0 "$RC" "control: the same dir under its own issue is accepted"

    # Malformed stamps: each key missing or garbled in turn.
    d="$base/solo-505"
    command mkdir -p "$d"
    command printf 'run=0123456789abcdef\n' >"$(stamp_of "$d")"
    rs bash "$RS" path --issue 505
    assert_exit 2 "$RC" "a stamp with no issue is refused"
    assert_contains "$OUT" "malformed run stamp (issue=''" "a missing issue reads as malformed, not as a mismatch"
    command printf 'issue=505\n' >"$(stamp_of "$d")"
    rs bash "$RS" path --issue 505
    assert_exit 2 "$RC" "a stamp with no run is refused"
    command printf 'issue=505\nrun=../x\n' >"$(stamp_of "$d")"
    rs bash "$RS" path --issue 505
    assert_exit 2 "$RC" "a stamp with an unsafe run is refused"
    assert_contains "$OUT" "malformed run stamp" "the refusal names the malformed stamp"
    # Shapes init never writes: each must fail HERE, as malformed, not later as
    # a misleading harness null-run or another-issue mismatch.
    command printf 'issue=505\nrun=0123456789abcdef0\n' >"$(stamp_of "$d")"
    rs bash "$RS" path --issue 505
    assert_contains "$OUT" "malformed run stamp (run=" "a 17-char run is malformed"
    command printf 'issue=505\nrun=0123456789abcdeg\n' >"$(stamp_of "$d")"
    rs bash "$RS" path --issue 505
    assert_contains "$OUT" "malformed run stamp (run=" "a non-hex run is malformed"
    command printf 'issue=0505\nrun=0123456789abcdef\n' >"$(stamp_of "$d")"
    rs bash "$RS" path --issue 505
    assert_contains "$OUT" "malformed run stamp (issue=" "a leading-zero stamp issue is malformed, not a mismatch"
    # No trailing newline: the last line must still be read.
    command printf 'issue=505\nrun=0123456789abcdef' >"$(stamp_of "$d")"
    rs bash "$RS" path --issue 505
    assert_exit 0 "$RC" "a stamp without a trailing newline is still read"
    assert_equals "0123456789abcdef" "$(val run "$OUT")" "its run is echoed"

    # A symlinked dir is not this run's dir, even when its target carries a
    # VALID stamp for this very issue — the link itself was never made by init.
    command mkdir -p "$SANDBOX/planted"
    command printf 'issue=507\nrun=0123456789abcdef\n' >"$(stamp_of "$SANDBOX/planted")"
    command ln -s "$SANDBOX/planted" "$base/solo-507"
    rs bash "$RS" path --issue 507
    assert_exit 2 "$RC" "path through a symlinked dir is refused"
    assert_contains "$OUT" "no scratch dir for this run" "the symlink is refused as not-a-dir"
}

test_init_without_a_nonce_keeps_the_old_run() {
    # An `od` that yields no usable bytes: init must fail loud AND, because the
    # nonce is minted before the wipe, leave the existing run untouched.
    local d stub="$SANDBOX/stub-od"
    rs bash "$RS" init --issue 601
    d="$(val dir "$OUT")"
    command printf '{"kept":true}\n' >"$d/attempt1.json"
    command mkdir -p "$stub"
    command printf '#!/usr/bin/env bash\nexit 1\n' >"$stub/od"
    command chmod +x "$stub/od"
    # BASH_ENV scrubbed so no profile can put the real od back ahead of the stub.
    rs BASH_ENV= PATH="$stub:$PATH" bash "$RS" init --issue 601
    assert_exit 2 "$RC" "init with no RNG output is refused"
    assert_contains "$OUT" "could not mint a run nonce" "the refusal names the nonce"
    assert_true "[ -f '$d/attempt1.json' ]" "a failed mint deletes nothing (mint precedes the wipe)"
    assert_true "[ -f '$(stamp_of "$d")' ]" "the old run's stamp survives"
}

# fenced_bash <file> — print only the lines inside ```bash fences: the recipe
# an agent executes, so a prose mention of the helper cannot satisfy AC3.
fenced_bash() {
    command awk '/^```bash/ { f = 1; next } /^```/ { f = 0 } f' "$1"
}

# A recipe line STARTS with the call: anchoring on a leading newline keeps a
# commented-out `# <skill-base-dir>/…` line from satisfying the assertion.
NL='
'
CALL='<skill-base-dir>/../../scripts/review-scratch.sh'

# init_path_shape <file> <unit> — inside ```bash fences, count `init` recipe
# lines, how many carry the `# <unit> 1 only` marker, and how many are followed
# by a `path` recipe line BEFORE their fence closes. Prints
# `init=N marked=N paired=N`. Column-1 anchoring, as with NL above, keeps a
# commented-out call from counting.
init_path_shape() {
    command awk -v call="$CALL" -v unit="$2" '
        /^```bash/ { f = 1; seen = 0; next }
        /^```/     { f = 0; seen = 0; next }
        !f { next }
        index($0, call " init --issue {N}") == 1 {
            n++; seen = 1
            if (index($0, "# " unit " 1 only")) marked++
            next
        }
        seen && index($0, call " path --issue {N}") == 1 { paired++; seen = 0 }
        END { printf "init=%d marked=%d paired=%d\n", n, marked, paired }
    ' "$1"
}

# AC3: the three recipe sites that used to spell the derivation inline must all
# call the helper from a fenced recipe, worktree-safely, and none may keep the
# old shared fallback.
test_every_recipe_site_uses_the_helper() {
    local f body
    for f in adversarial-review-step.md ci-review-protocol.md review-routing.md; do
        body="$NL$(fenced_bash "$SHIP/$f")"
        assert_contains "$body" "$NL$CALL path --issue {N}" \
            "$f has a fenced review-scratch.sh path recipe"
        assert_not_contains "$body" 'GOLEM_ID or "solo"' \
            "$f no longer carries the shared solo fallback"
        # #815: the helper must be run bare and READ, never captured.
        if command printf '%s\n' "$body" | command grep 'review-scratch' |
            command grep -E '\$\(|CLAUDE_PLUGIN_ROOT' >/dev/null; then
            _fail "$f captures review-scratch.sh in a worktree-unsafe spelling"
        fi
    done
    # Both review LOOPS must show the cycle-1 wipe AND the later-cycle keep as
    # alternatives (#1107): exactly one `init`, marked first-iteration-only, with
    # `path` beside it in the SAME fence. An unmarked init, or a path moved to
    # another fence, reads as "always run init" — and on cycle 2 init deletes
    # the cycle JSON review-convergence.sh reads as --prev-result.
    local pair unit
    for pair in adversarial-review-step.md:cycle ci-review-protocol.md:attempt; do
        f="${pair%%:*}" unit="${pair#*:}"
        assert_equals "init=1 marked=1 paired=1" "$(init_path_shape "$SHIP/$f" "$unit")" \
            "$f: one fenced init, '# $unit 1 only', path in the same fence"
    done
}

# #1166: remove deletes BOTH ids the issue can have run under, whatever GOLEM_ID
# the caller carries (teardown runs from the main checkout, where it is unset or
# names another golem), and leaves a sibling issue's dirs alone.
test_remove_deletes_both_ids_for_the_issue() {
    local base="$SANDBOX/home/.cache/librarian-review" g
    for g in golem-31 solo-31 golem-32 solo-32; do
        command mkdir -p "$base/$g"
        command printf 'x\n' >"$base/$g/cycle1.json"
    done
    rs GOLEM_ID=golem-32 bash "$RS" remove --issue 31
    assert_exit 0 "$RC" "remove succeeds"
    assert_contains "$OUT" "removed=$base/golem-31" "remove reports golem-31"
    assert_contains "$OUT" "removed=$base/solo-31" "remove reports solo-31"
    assert_true "[ ! -e '$base/golem-31' ]" "golem-31 is gone"
    assert_true "[ ! -e '$base/solo-31' ]" "solo-31 is gone"
    assert_true "[ -f '$base/golem-32/cycle1.json' ]" "GOLEM_ID never redirects remove"
    assert_true "[ -f '$base/solo-32/cycle1.json' ]" "a sibling issue's solo dir survives"

    rs bash "$RS" remove --issue 31
    assert_exit 0 "$RC" "remove of absent dirs is a clean no-op"
    assert_equals "" "$OUT" "an absent dir prints nothing"

    rs bash "$RS" remove --issue 031
    assert_exit 2 "$RC" "remove keeps the canonical issue gate"
}

# #1166: a link at the leaf, or a scratch root that resolves somewhere its
# children do not, is refused with a WARNING and exit 1 — and the target is
# untouched. The other id is still processed.
test_remove_refuses_a_dir_it_does_not_own() {
    local base="$SANDBOX/home/.cache/librarian-review" target="$SANDBOX/victim"
    command mkdir -p "$base/solo-41" "$target"
    command printf 'keep\n' >"$target/sentinel"
    command ln -s "$target" "$base/golem-41"
    rs bash "$RS" remove --issue 41
    assert_exit 1 "$RC" "a refused dir makes remove exit 1"
    assert_contains "$OUT" "WARNING: refusing to remove $base/golem-41" "the refusal names the dir"
    assert_true "[ -f '$target/sentinel' ]" "remove never deletes through a symlink"
    assert_true "[ -L '$base/golem-41' ]" "the refused link is left in place"
    assert_true "[ ! -e '$base/solo-41' ]" "the other id is still removed"

    # A dangling link is refused too, not mistaken for absent.
    command ln -s "$SANDBOX/nowhere" "$base/solo-42"
    rs bash "$RS" remove --issue 42
    assert_exit 1 "$RC" "a dangling link is refused, not skipped"
    assert_true "[ -L '$base/solo-42' ]" "the dangling link is left in place"

    # A regular file where the dir should be is refused, not rm'd.
    command printf 'x\n' >"$base/solo-43"
    rs bash "$RS" remove --issue 43
    assert_exit 1 "$RC" "a non-directory is refused"
    assert_true "[ -f '$base/solo-43' ]" "the file is left in place"
}

run_test test_solo_runs_on_different_issues_are_isolated
run_test test_golem_id_wins_over_the_issue
run_test test_init_removes_an_earlier_runs_files
run_test test_init_on_a_symlinked_dir_removes_only_the_link
run_test test_unsafe_inputs_fail_loud
run_test test_init_stamps_a_run_that_path_echoes
run_test test_path_refuses_a_dir_it_cannot_vouch_for
run_test test_init_without_a_nonce_keeps_the_old_run
run_test test_every_recipe_site_uses_the_helper
run_test test_remove_deletes_both_ids_for_the_issue
run_test test_remove_refuses_a_dir_it_does_not_own

generate_report
