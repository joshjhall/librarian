#!/usr/bin/env bash
# Prose-vs-code environment variable drift gate (issue #588).
#
# This plugin family documents a lot of `LIBRARIAN_*` / `GOLEM_*` tunables. Most
# are read by a bundled script, so setting one provably takes effect. But four
# `LIBRARIAN_CI_*` variables were documented across six files — with stated
# defaults, operational semantics, and an operator-facing table in
# plugins/workflow/README.md — while being read by NO code in any language. They
# read as working configuration and were not. #588 resolved each one (the
# CI-wait pair is now read by scripts/ci-wait-timeout.sh; the infra pair is
# declared agent-interpreted). This gate is what stops the class recurring: a
# NEW documented-only variable now fails here instead of sitting unnoticed.
#
# Two independent checks:
#
#   (a) PROSE-ONLY DETECTION. Every LIBRARIAN_*/GOLEM_* token appearing in the
#       prose corpus must also appear in a source file — unless it is on the
#       ALLOWLIST below, which is exactly the variables that are agent-interpreted
#       BY DESIGN. The allowlist is deliberately short and each entry states why.
#
#   (b) DEFAULT CONSISTENCY. An allowlisted variable has no execution to keep it
#       honest, so the one thing that CAN be checked is that every file stating
#       its default agrees. Each of the two allowlisted vars states a default in
#       3-4 files today; before this gate they could silently disagree, and the
#       reader of any one file would have no way to tell.
#
# WHY (b) ONLY COVERS THE ALLOWLIST. A script-read variable's default lives in
# the script, and its own test suite pins it (tests/validate-ci-wait-timeout.sh
# asserts the 15/2 -> 45 ceiling). Extending (b) to those would duplicate that
# coverage in a weaker, textual form. The allowlist is precisely the set with no
# executable source of truth, which is what makes textual agreement worth
# gating there and nowhere else.
#
# TRAILING-UNDERSCORE TOKENS ARE FAMILY REFERENCES, NOT VARIABLES. Prose refers
# to groups as `LIBRARIAN_CI_*` / `LIBRARIAN_WORKFLOW_*`; the token extractor
# stops at the `*`, yielding `LIBRARIAN_CI_` and `LIBRARIAN_WORKFLOW_`. Those
# name no variable and can never appear in code, so treating them as findings
# would make the gate permanently red on correct prose. They are skipped
# structurally (a trailing `_`), not by an allowlist entry — an allowlist entry
# would imply someone should one day implement them.
#
# Pure bash + coreutils + awk; no node, no jq, no network. bash-3.2 clean (flat
# newline-separated lists, no assoc arrays; `find` without GNU -printf).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

test_suite "Prose-vs-code env var drift (#588)"

# --- Allowlist ---------------------------------------------------------------
# Variables that are documented but read by no code ON PURPOSE. Each is
# agent-interpreted: the shipping agent reads it from the environment while it
# works, because the decision it feeds is a judgment rather than arithmetic.
# Adding an entry here is a claim that a helper CANNOT own the decision — not
# that one has not been written yet. Both current entries feed CI-failure
# triage, which classifies from `gh run view` JSON plus the PR's changed-file
# set; a script could own the retry count but not the classification.
#
# The CI-wait pair is deliberately ABSENT: #588 mechanized it into
# scripts/ci-wait-timeout.sh, so it must keep proving that by appearing in code.
# test_allowlist_is_not_stale fails if an allowlisted var gains a code reader,
# so an entry cannot outlive its reason.
ALLOWLIST="LIBRARIAN_CI_INFRA_STEPS
LIBRARIAN_CI_INFRA_RETRIES"

# --- Corpora -----------------------------------------------------------------

# collect_prose <plugins_dir> <repo_root> — markdown the gate treats as docs.
# Same corpus as lint-command-refs.sh: plugins/**/*.md plus the top-level
# README. README.md is REQUIRED, not best-effort — the issue's AC names it
# specifically, so silently skipping a missing one would narrow the gate without
# saying so.
collect_prose() {
    local plugins_dir="$1" repo_root="$2"
    command find "$plugins_dir" -type f -name '*.md' 2>/dev/null | command sort
    if [ ! -f "$repo_root/README.md" ]; then
        command printf 'lint-env-var-drift: README.md not found at %s\n' \
            "$repo_root/README.md" >&2
        return 1
    fi
    command printf '%s\n' "$repo_root/README.md"
}

# collect_sources <root...> — every file that could READ a variable. Extensions,
# not a blanket walk: a variable named only in another markdown file has not
# been implemented, and counting docs as source would defeat the whole check.
#
# The caller passes plugins/ bin/ .github/ and deliberately NOT tests/. A test
# that names a variable is a CONSUMER of an implementation, not one — so
# counting tests/ as source would let a variable be "implemented" by the very
# gate that checks it, or by a test asserting behavior no shipped code has. It
# also makes this file self-satisfying: ALLOWLIST names its two entries in
# plain text, which under a tests/-inclusive corpus reads back as those two
# being code-read, and every allowlist entry becomes unfalsifiable.
collect_sources() {
    command find "$@" -type f \
        \( -name '*.sh' -o -name '*.py' -o -name '*.js' -o -name '*.mjs' \
        -o -name '*.json' -o -name '*.yml' -o -name '*.yaml' \) 2>/dev/null |
        command sort
}

# tokens_in <files> — every LIBRARIAN_*/GOLEM_* token in the listed files, one
# per line, sorted and de-duplicated. Trailing-underscore family references
# (`LIBRARIAN_CI_` from `LIBRARIAN_CI_*`) are dropped here — see the header.
tokens_in() {
    local files="$1" file
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        command grep -ohE '(LIBRARIAN|GOLEM)_[A-Z0-9_]+' "$file" 2>/dev/null || true
    done <<EOF
$files
EOF
}

# drop_family_refs — filter a token stream, removing trailing-underscore tokens.
drop_family_refs() {
    command grep -vE '_$' || true
}

# --- Check (a): prose-only detection ----------------------------------------

# scan_prose_only <prose_files> <source_files> <allowlist>
# Sets PROSE_ONLY (one "<token>" line per unallowlisted prose-only variable) and
# PROSE_COUNT / SOURCE_COUNT (so a caller can prove the scan was not vacuous).
# Parameterized rather than reading globals so the negative fixture can drive
# this exact function against a synthetic tree.
PROSE_ONLY=""
PROSE_COUNT=0
SOURCE_COUNT=0
scan_prose_only() {
    local prose_files="$1" source_files="$2" allowlist="$3"
    local prose_tokens source_tokens token
    PROSE_ONLY=""

    prose_tokens="$(tokens_in "$prose_files" | drop_family_refs | command sort -u)"
    source_tokens="$(tokens_in "$source_files" | command sort -u)"
    PROSE_COUNT="$(command printf '%s\n' "$prose_tokens" | command grep -c . || true)"
    SOURCE_COUNT="$(command printf '%s\n' "$source_tokens" | command grep -c . || true)"

    while IFS= read -r token; do
        [ -n "$token" ] || continue
        # In code? Then it is implemented — nothing to report.
        command printf '%s\n' "$source_tokens" |
            command grep -qxF "$token" && continue
        # Allowlisted? Then it is agent-interpreted by design.
        command printf '%s\n' "$allowlist" |
            command grep -qxF "$token" && continue
        PROSE_ONLY="${PROSE_ONLY}${token}"$'\n'
    done <<EOF
$prose_tokens
EOF
}

# --- Check (b): stated-default consistency ----------------------------------

# defaults_for <var> <files> — every default this corpus states for <var>, one
# per line (duplicates kept; the caller counts distinct values).
#
# Each file is FLATTENED to one line before scanning, because markdown wraps: two
# of the four sites today put `default` at the end of a line and its backticked
# value at the start of the next. A line-oriented scan would silently see zero
# defaults there — a check that reports "all agree" because it found nothing is
# worse than no check.
#
# Extraction: split on the variable name, take up to 200 chars after each
# occurrence, find `default`, and accept the next backticked value ONLY if
# nothing but spaces/colons/commas separates the two. That last condition is what
# keeps the window from drifting onto an unrelated later default — a mention of
# the var that states no default yields nothing rather than a wrong value.
defaults_for() {
    local var="$1" files="$2" file
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        command tr '\n' ' ' <"$file" | command awk -v var="$var" '
        {
            n = split($0, parts, var)
            for (i = 2; i <= n; i++) {
                seg = substr(parts[i], 1, 200)
                p = index(seg, "default")
                if (p == 0) continue
                rest = substr(seg, p + 7)
                a = index(rest, "`")
                if (a == 0) continue
                gap = substr(rest, 1, a - 1)
                if (gap !~ /^[ :,]*$/) continue
                tail = substr(rest, a + 1)
                b = index(tail, "`")
                if (b == 0) continue
                print substr(tail, 1, b - 1)
            }
        }'
    done <<EOF
$files
EOF
}

# scan_defaults <files> <allowlist>
# Sets DEFAULT_CONFLICTS (one line per var whose stated defaults disagree) and
# DEFAULT_SEEN (one "<var>=<value> x<count>" line per var, for non-vacuity).
DEFAULT_CONFLICTS=""
DEFAULT_SEEN=""
scan_defaults() {
    local files="$1" allowlist="$2"
    local var vals distinct count joined
    DEFAULT_CONFLICTS=""
    DEFAULT_SEEN=""
    while IFS= read -r var; do
        [ -n "$var" ] || continue
        vals="$(defaults_for "$var" "$files")"
        count="$(command printf '%s\n' "$vals" | command grep -c . || true)"
        distinct="$(command printf '%s\n' "$vals" | command grep . |
            command sort -u || true)"
        local ndistinct
        ndistinct="$(command printf '%s\n' "$distinct" | command grep -c . || true)"
        if [ "$ndistinct" -gt 1 ]; then
            joined="$(command printf '%s\n' "$distinct" | command tr '\n' '/' |
                command sed 's:/$::')"
            DEFAULT_CONFLICTS="${DEFAULT_CONFLICTS}${var}: ${ndistinct} different defaults stated (${joined})"$'\n'
        fi
        DEFAULT_SEEN="${DEFAULT_SEEN}${var}=${distinct} x${count}"$'\n'
    done <<EOF
$allowlist
EOF
}

# --- Real-corpus state -------------------------------------------------------

PROSE_FILES="$(collect_prose "$PLUGINS_DIR" "$REPO_ROOT")"
SOURCE_FILES="$(collect_sources "$PLUGINS_DIR" "$REPO_ROOT/bin" "$REPO_ROOT/.github")"

# --- Tests -------------------------------------------------------------------

test_no_prose_only_vars() {
    scan_prose_only "$PROSE_FILES" "$SOURCE_FILES" "$ALLOWLIST"
    if [ -n "$PROSE_ONLY" ]; then
        local detail=() line
        while IFS= read -r line; do
            [ -n "$line" ] && detail+=("$line — documented but read by no code")
        done <<<"$PROSE_ONLY"
        detail+=("Fix by: implementing the read, deleting the prose, or — if it is")
        detail+=("agent-interpreted BY DESIGN — adding it to ALLOWLIST with a reason.")
        _fail "Environment variable(s) documented in prose but read by no source file" \
            "${detail[@]}"
    fi
}

# A whole-corpus check goes green when discovery is broken, so pin that both
# corpora were genuinely populated and that tokens were actually extracted.
# The tests/ exclusion is a tested decision, not an accident of the find roots.
# Widening the source corpus to include tests/ is the plausible regression, and
# it is a QUIET one: every check stays green while the allowlist becomes
# unfalsifiable (this file names its own entries in plain text, so they would
# read back as code-read) and any variable named only in a test would count as
# implemented. Assert the roots directly so that edit fails here, at the
# reasoning, rather than downstream as a mystery pass.
test_source_corpus_excludes_tests() {
    assert_not_contains "$SOURCE_FILES" "$REPO_ROOT/tests/" \
        "tests/ is NOT part of the source corpus (a test consumes an implementation, it is not one)"
    # And the positive side — the roots that ARE walked, so the exclusion cannot
    # be satisfied by an empty corpus.
    assert_contains "$SOURCE_FILES" "/plugins/workflow/scripts/ci-wait-timeout.sh" \
        "plugins/ is walked (the bundled scripts are in scope)"
    assert_contains "$SOURCE_FILES" "/bin/" "bin/ is walked"
}

test_scan_is_not_vacuous() {
    local nprose nsource ge_prose=0 ge_source=0
    nprose="$(command printf '%s\n' "$PROSE_FILES" | command grep -c . || true)"
    nsource="$(command printf '%s\n' "$SOURCE_FILES" | command grep -c . || true)"
    [ "$nprose" -ge 50 ] && ge_prose=1
    [ "$nsource" -ge 30 ] && ge_source=1
    assert_equals "1" "$ge_prose" "At least 50 prose files are scanned (found $nprose)"
    assert_equals "1" "$ge_source" "At least 30 source files are scanned (found $nsource)"

    scan_prose_only "$PROSE_FILES" "$SOURCE_FILES" "$ALLOWLIST"
    local ge_tokens=0 ge_src_tokens=0
    [ "$PROSE_COUNT" -ge 15 ] && ge_tokens=1
    [ "$SOURCE_COUNT" -ge 15 ] && ge_src_tokens=1
    assert_equals "1" "$ge_tokens" \
        "At least 15 variables are found in prose (found $PROSE_COUNT)"
    assert_equals "1" "$ge_src_tokens" \
        "At least 15 variables are found in source (found $SOURCE_COUNT)"
}

# The CI-wait pair is the whole point of #588's implement half. If it ever stops
# appearing in code, check (a) would report it — but only if it is still absent
# from the allowlist. Assert both halves directly so a future edit cannot quietly
# park it on the allowlist and call the drift resolved.
test_ci_wait_pair_is_implemented() {
    local source_tokens
    source_tokens="$(tokens_in "$SOURCE_FILES" | command sort -u)"
    assert_contains "$source_tokens" "LIBRARIAN_CI_WAIT_TIMEOUT" \
        "LIBRARIAN_CI_WAIT_TIMEOUT is read by code (ci-wait-timeout.sh), not prose-only"
    assert_contains "$source_tokens" "LIBRARIAN_CI_WAIT_MAX_EXTENSIONS" \
        "LIBRARIAN_CI_WAIT_MAX_EXTENSIONS is read by code, not prose-only"
    assert_not_contains "$ALLOWLIST" "LIBRARIAN_CI_WAIT" \
        "The CI-wait pair is NOT allowlisted — it must keep proving it is implemented"
}

# An allowlist entry is a claim that no code reads the variable. If code starts
# reading one, the entry is stale and its "agent-interpreted by design" comment
# has become false — the comment-asserts-intent-not-code failure mode. Fail so
# the entry is removed rather than quietly outliving its reason.
test_allowlist_is_not_stale() {
    local source_tokens var stale=""
    source_tokens="$(tokens_in "$SOURCE_FILES" | command sort -u)"
    while IFS= read -r var; do
        [ -n "$var" ] || continue
        command printf '%s\n' "$source_tokens" | command grep -qxF "$var" &&
            stale="${stale}${var}"$'\n'
    done <<EOF
$ALLOWLIST
EOF
    assert_equals "" "$stale" \
        "No allowlisted var is read by code (a stale entry hides a real implementation)"
}

# An allowlisted var that nothing documents any more is dead weight: the entry
# suppresses a finding that can no longer occur, and the next reader has to
# re-derive why it is there.
test_allowlist_entries_are_documented() {
    local prose_tokens var missing=""
    prose_tokens="$(tokens_in "$PROSE_FILES" | drop_family_refs | command sort -u)"
    while IFS= read -r var; do
        [ -n "$var" ] || continue
        command printf '%s\n' "$prose_tokens" | command grep -qxF "$var" ||
            missing="${missing}${var}"$'\n'
    done <<EOF
$ALLOWLIST
EOF
    assert_equals "" "$missing" \
        "Every allowlisted var is still documented somewhere (no dead entries)"
}

test_defaults_agree() {
    scan_defaults "$PROSE_FILES" "$ALLOWLIST"
    if [ -n "$DEFAULT_CONFLICTS" ]; then
        local detail=() line
        while IFS= read -r line; do
            [ -n "$line" ] && detail+=("$line")
        done <<<"$DEFAULT_CONFLICTS"
        detail+=("An agent-interpreted var has no execution to keep it honest —")
        detail+=("every file stating its default must state the same one.")
        _fail "Allowlisted variable(s) state disagreeing defaults across files" \
            "${detail[@]}"
    fi
}

# test_defaults_agree passes trivially if the extractor finds NO defaults at all
# — the markdown-wrap case the flattening exists to handle. Assert each
# allowlisted var's default was actually found, in more than one file, with the
# value pinned. If a doc site rewords past the extractor, this fails rather than
# going quietly green.
test_defaults_were_actually_found() {
    scan_defaults "$PROSE_FILES" "$ALLOWLIST"
    local retries_n steps_n ge_retries=0 ge_steps=0
    retries_n="$(defaults_for LIBRARIAN_CI_INFRA_RETRIES "$PROSE_FILES" |
        command grep -c . || true)"
    steps_n="$(defaults_for LIBRARIAN_CI_INFRA_STEPS "$PROSE_FILES" |
        command grep -c . || true)"
    [ "$retries_n" -ge 2 ] && ge_retries=1
    [ "$steps_n" -ge 2 ] && ge_steps=1
    assert_equals "1" "$ge_retries" \
        "LIBRARIAN_CI_INFRA_RETRIES' default is found in 2+ files (found $retries_n)"
    assert_equals "1" "$ge_steps" \
        "LIBRARIAN_CI_INFRA_STEPS' default is found in 2+ files (found $steps_n)"
    # Pin the agreed values themselves — a check that only compares sites to each
    # other cannot notice them drifting together away from the implementation's
    # documented behavior.
    assert_contains "$DEFAULT_SEEN" "LIBRARIAN_CI_INFRA_RETRIES=1 " \
        "The agreed LIBRARIAN_CI_INFRA_RETRIES default is 1"
    assert_contains "$DEFAULT_SEEN" "Set up Docker Buildx|Checkout" \
        "The agreed LIBRARIAN_CI_INFRA_STEPS default is the known infra-step regex"
}

# --- Negative fixtures -------------------------------------------------------
# Both checks are whole-corpus assertions that are GREEN on a correct tree, so
# without these the gate could enforce nothing and still report PASS. Each
# fixture drives the real scan function against a synthetic corpus.

test_prose_only_detection_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command mkdir -p "$tmp/prose" "$tmp/src"
    command cat >"$tmp/prose/doc.md" <<'EOF'
Set `LIBRARIAN_FAKE_KNOB` (default 7) to tune the thing.
`GOLEM_REAL_KNOB` is also configurable.
The `LIBRARIAN_CI_INFRA_RETRIES` retry count is agent-interpreted.
Family references like `LIBRARIAN_CI_*` group several vars.
EOF
    command cat >"$tmp/src/reader.sh" <<'EOF'
: "${GOLEM_REAL_KNOB:=5}"
EOF

    scan_prose_only "$tmp/prose/doc.md" "$tmp/src/reader.sh" "$ALLOWLIST"

    assert_not_empty "$PROSE_ONLY" "The prose-only branch fires"
    assert_contains "$PROSE_ONLY" "LIBRARIAN_FAKE_KNOB" \
        "A variable documented with a default but read by nothing is flagged"
    assert_not_contains "$PROSE_ONLY" "GOLEM_REAL_KNOB" \
        "A variable that IS read by a source file is not flagged"
    assert_not_contains "$PROSE_ONLY" "LIBRARIAN_CI_INFRA_RETRIES" \
        "An allowlisted (agent-interpreted) variable is not flagged"
    # The family-reference skip, driven end-to-end rather than asserted about the
    # regex: `LIBRARIAN_CI_*` yields the token `LIBRARIAN_CI_`, which is read by
    # no code and is not on the allowlist, so ONLY the trailing-underscore rule
    # can be keeping it out of the findings.
    assert_not_contains "$PROSE_ONLY" "LIBRARIAN_CI_"$'\n' \
        "A trailing-underscore family reference is not flagged as a variable"
}

test_default_conflict_detection_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command mkdir -p "$tmp/a"
    command printf 'The `LIBRARIAN_CI_INFRA_RETRIES` knob — integer, default `1`.\n' \
        >"$tmp/a/one.md"
    # Second site states a DIFFERENT default. Also exercises the markdown-wrap
    # case: the value sits on the line after the word `default`.
    command printf 'See `LIBRARIAN_CI_INFRA_RETRIES` — retry count, default\n`4`.\n' \
        >"$tmp/a/two.md"
    # A third site agrees with the first; a conflict must be reported once for
    # the var, not once per disagreeing pair.
    command printf 'Also `LIBRARIAN_CI_INFRA_RETRIES`, default `1`, elsewhere.\n' \
        >"$tmp/a/three.md"

    local files
    files="$(command printf '%s\n%s\n%s\n' "$tmp/a/one.md" "$tmp/a/two.md" "$tmp/a/three.md")"
    scan_defaults "$files" "LIBRARIAN_CI_INFRA_RETRIES"

    assert_not_empty "$DEFAULT_CONFLICTS" "The default-conflict branch fires"
    assert_contains "$DEFAULT_CONFLICTS" "LIBRARIAN_CI_INFRA_RETRIES" \
        "The conflicting variable is named"
    assert_contains "$DEFAULT_CONFLICTS" "2 different defaults" \
        "The two distinct values are counted (not the three statements)"
    assert_contains "$DEFAULT_CONFLICTS" "4" "The disagreeing value appears in the detail"

    # And the agreeing case must NOT fire — otherwise the check would fail on any
    # var stated more than once, which is every var it covers.
    local agree
    agree="$(command printf '%s\n%s\n' "$tmp/a/one.md" "$tmp/a/three.md")"
    scan_defaults "$agree" "LIBRARIAN_CI_INFRA_RETRIES"
    assert_equals "" "$DEFAULT_CONFLICTS" \
        "Three files stating the SAME default do not conflict"
    assert_contains "$DEFAULT_SEEN" "LIBRARIAN_CI_INFRA_RETRIES=1 x2" \
        "Both agreeing statements were seen (the pass is not from finding nothing)"
}

# The extractor must not manufacture a default from a mention that states none —
# that would be a wrong value reported as a conflict, sending a reader to fix
# prose that is correct. The 200-char window makes this a live risk: an unrelated
# `default` downstream is well within reach.
test_mention_without_default_yields_nothing() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/mention.md" <<'EOF'
A failing step matching `LIBRARIAN_CI_INFRA_STEPS` is treated as a flake and
retried once before escalating to the human operator for a decision.
Separately, `REVIEW_MAX_CYCLES` has a default of `5` in this repo.
EOF

    local vals n
    vals="$(defaults_for LIBRARIAN_CI_INFRA_STEPS "$tmp/mention.md")"
    n="$(command printf '%s\n' "$vals" | command grep -c . || true)"
    assert_equals "0" "$n" \
        "A mention that states no default yields no value (found: $vals)"
}

test_missing_readme_fails_loudly() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command mkdir -p "$tmp/root/plugins"
    local rc=0
    collect_prose "$tmp/root/plugins" "$tmp/root" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "A missing README.md makes corpus collection fail, not narrow"

    command printf '# root\n' >"$tmp/root/README.md"
    local out rc2=0
    out="$(collect_prose "$tmp/root/plugins" "$tmp/root" 2>/dev/null)" || rc2=$?
    assert_equals "0" "$rc2" "With README.md present, collection succeeds"
    assert_contains "$out" "README.md" "The README is part of the corpus it returns"
}

run_test test_scan_is_not_vacuous "Both corpora and the token extraction are non-empty"
run_test test_source_corpus_excludes_tests "The source corpus excludes tests/ on purpose"
run_test test_no_prose_only_vars "No variable is documented in prose but read by no code"
run_test test_ci_wait_pair_is_implemented "The CI-wait pair is code-read and not allowlisted"
run_test test_allowlist_is_not_stale "No allowlist entry has quietly gained a code reader"
run_test test_allowlist_entries_are_documented "Every allowlist entry is still documented"
run_test test_defaults_agree "Allowlisted vars state one consistent default everywhere"
run_test test_defaults_were_actually_found "The default extraction found real values (not vacuous)"
run_test test_prose_only_detection_fires "scan_prose_only flags a prose-only var and honors both exemptions"
run_test test_default_conflict_detection_fires "scan_defaults flags disagreeing defaults, passes agreeing ones"
run_test test_mention_without_default_yields_nothing "A mention stating no default yields no value"
run_test test_missing_readme_fails_loudly "A missing README.md fails loudly instead of narrowing the corpus"

generate_report
