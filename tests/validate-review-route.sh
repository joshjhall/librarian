#!/usr/bin/env bash
# review-route.sh — routing decision + fail-safe properties (issue #550).
#
# The script decides whether a review cycle runs the full 7-agent fan-out or the
# cheap doc/config-only path. Because a `cheap` cycle is allowed to return
# `clean: true` — and `clean` is half the merge invariant — THE CLASSIFIER IS
# THE ENTIRE SAFETY ARGUMENT. If it can be made permissive without a test going
# red, the invariant is protected by nothing but a comment.
#
# So this suite is organized around the direction of failure, not around
# coverage. Two kinds of case:
#
#   1. RULE CASES — each rule fires on an input that reaches it, pinning the
#      documented verdict, rule name and dimension list.
#
#   2. FAIL-SAFE CASES — the ones the suite exists for. Each is built on an
#      input where a PERMISSIVE classifier would answer `cheap` and the correct
#      one answers `full`. That is the discipline this repo's memory calls
#      "fixture must express the divergent case": asserting `full` on an input
#      both versions route `full` is a tautology that passes with AND without
#      the fix.
#
# The mutation obligation is stated per-case below: neutering R2-source,
# R3-unknown or the R1 env override must each turn a NAMED test red.
#
# Pure bash + coreutils via `command`; no node, no jq, no network. bash-3.2
# clean, BSD-regex clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RR="$REPO_ROOT/plugins/workflow/scripts/review-route.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "review-route.sh routing decision (#550)"

# val <key> <output> — echo the value of a `key=value` line. Keeps assertions
# terse and independent of line order.
val() {
    command printf '%s\n' "$2" | command grep "^$1=" | command sed "s/^$1=//"
}

# mklist <line>... — write a newline-separated file list to a temp file and echo
# its path.
mklist() {
    _f="$(command mktemp)"
    for _l in "$@"; do
        command printf '%s\n' "$_l"
    done >"$_f"
    command printf '%s\n' "$_f"
}

# route_of <file-list> [extra args...] — run the script and echo just the route.
route_of() {
    _list="$1"
    shift
    bash "$RR" check --files "$_list" "$@"
}

# --- 1. Rule cases -----------------------------------------------------------

# The one path to `cheap`. Also pins the dimension contract: scope-drift ALONE.
test_doc_and_config_only_routes_cheap() {
    local list out
    list="$(mklist 'README.md' 'docs/guide.md' 'CHANGELOG.md')"
    out="$(route_of "$list")"

    assert_equals "cheap" "$(val route "$out")" "doc-ONLY diff routes cheap"
    assert_equals "R7-doc-only" "$(val rule "$out")" "R7 is the deciding rule"
    assert_equals "scope-drift" "$(val dimensions "$out")" \
        "cheap path runs scope-drift ALONE"
    assert_equals "3" "$(val doc_files "$out")" "counts all three doc files"
}

# scope-drift surviving the cheap path is a REQUIREMENT, not an accident: it is
# the only dimension reading the issue's ACs, and a doc-only diff can fail one.
# Asserted by name so deleting it from the cheap branch fails here.
test_scope_drift_survives_the_cheap_route() {
    local list out
    list="$(mklist 'CHANGELOG.md')"
    out="$(route_of "$list")"

    assert_equals "cheap" "$(val route "$out")" "single doc file routes cheap"
    assert_contains "$(val dimensions "$out")" "scope-drift" \
        "scope-drift is retained on the cheap path (AC-completeness lens)"
}

test_full_route_names_every_dimension() {
    local list out dims
    list="$(mklist 'src/app.py')"
    out="$(route_of "$list")"
    dims="$(val dimensions "$out")"

    for d in security correctness tests conventions decomposition scope-drift; do
        assert_contains "$dims" "$d" "full route runs the $d dimension"
    done
}

# --- 2. Fail-safe cases ------------------------------------------------------
#
# Every case below is built so a PERMISSIVE classifier answers `cheap`.

# MUTATION TARGET: R2-source. Neuter it and this test must go red.
# The fixture is 20 docs plus ONE source file — a classifier that ignored the
# source file (e.g. checked "mostly docs", or a majority, or only the first
# entry) would route `cheap`. That is the divergent case.
test_one_source_file_among_many_docs_forces_full() {
    local list out
    list="$(mklist \
        'a.md' 'b.md' 'c.md' 'd.md' 'e.md' 'f.md' 'g.md' 'h.md' 'i.md' 'j.md' \
        'k.md' 'l.md' 'm.md' 'n.md' 'o.md' 'p.md' 'q.md' 'r.md' 's.md' 't.md' \
        'src/auth.py')"
    out="$(route_of "$list")"

    assert_equals "full" "$(val route "$out")" \
        "a SINGLE source file among 20 docs forces the full fan-out"
    assert_equals "R2-source" "$(val rule "$out")" "R2-source is the deciding rule"
    assert_equals "1" "$(val source_files "$out")" "the lone source file is counted"
}

# The same property at the other boundary: the source file LAST in the list, so
# a classifier that stopped at the first non-source answer also diverges.
test_source_file_last_in_list_forces_full() {
    local list out
    list="$(mklist 'README.md' 'notes.md' 'setup.cfg' 'deploy.sh')"
    out="$(route_of "$list")"

    assert_equals "full" "$(val route "$out")" \
        "a source file in the FINAL position still forces full"
    assert_equals "R2-source" "$(val rule "$out")" "R2-source fires regardless of position"
}

# MUTATION TARGET: R3-unknown. Neuter it (or fold `unknown` into `doc`) and this
# must go red. A `.rb` file is not in the source table — a classifier treating
# "not known to be source" as "safe to skip" routes `cheap` here.
test_unknown_extension_forces_full() {
    local list out
    list="$(mklist 'README.md' 'lib/widget.rb')"
    out="$(route_of "$list")"

    assert_equals "full" "$(val route "$out")" \
        "an UNRECOGNIZED extension forces full — unknown means possibly-source"
    assert_equals "R3-unknown" "$(val rule "$out")" "R3-unknown is the deciding rule"
    assert_equals "1" "$(val unknown_files "$out")" "the unknown file is counted"
}

# Extensionless build/infra files are executable logic the security and
# correctness dimensions genuinely review. Classified `unknown`, never `config`.
test_extensionless_infra_files_force_full() {
    local list out name
    for name in Dockerfile Makefile justfile; do
        list="$(mklist 'README.md' "$name")"
        out="$(route_of "$list")"
        assert_equals "full" "$(val route "$out")" \
            "$name forces full (build logic, not inert config)"
    done
}

# MUTATION TARGET: the CI/container carve-out. Found by this feature's OWN
# pre-PR review, flagged independently by the security and correctness
# dimensions: `.github/workflows/*.yml` fell through to the generic `config`
# arm, so a docs-plus-workflow diff routed `cheap` and skipped security and
# correctness entirely while staying eligible to merge as `clean`.
#
# Every fixture pairs the infra file with a DOC, so the list is doc+config
# by extension alone — i.e. a classifier lacking the carve-out routes it
# `cheap`, which is exactly the divergent case. Asserting on the infra file
# alone would be weaker (a bare `.yml` is still doc/config-classified).
test_ci_and_container_files_force_full() {
    local list out path
    for path in \
        '.github/workflows/ci.yml' \
        '.github/workflows/release.yaml' \
        'nested/.github/workflows/deploy.yml' \
        '.gitlab-ci.yml' \
        '.circleci/config.yml' \
        'Jenkinsfile' \
        'docker-compose.yml' \
        'docker-compose.prod.yaml' \
        'compose.yaml' \
        '.dockerignore'; do
        list="$(mklist 'README.md' "$path")"
        out="$(route_of "$list")"
        assert_equals "full" "$(val route "$out")" \
            "$path is executable automation, not inert config — it forces the full fan-out"
    done
}

# RETIRED IN CYCLE 6, deliberately. This slot used to assert that ordinary
# config (config.yaml, data.json, settings.toml) STILL routed cheap — the
# narrowness half of the CI carve-out. Cycle 6 showed that premise was the bug:
# `config` is listed under security AND correctness in the normative
# DIMENSION_RELEVANT_TYPES table, so routing any config cheap is a fail-open
# hole (package.json, pnpm-lock.yaml). R5-config now forces full for all of it,
# and test_any_config_file_forces_full asserts the opposite of what stood here.
#
# The narrowness property it protected still matters, so it is preserved below
# against the class that CAN still route cheap — prose. Without this, making the
# classifier maximally paranoid (everything -> unknown) would satisfy every
# fail-safe test in this file while making the cheap path unreachable, i.e.
# a feature that is always green and never fires.
test_ordinary_prose_still_routes_cheap() {
    local list out
    list="$(mklist 'README.md' 'docs/guide.md' 'docs/api.rst' 'NOTES.adoc' 'CHANGELOG.md')"
    out="$(route_of "$list")"

    assert_equals "cheap" "$(val route "$out")" \
        "ordinary prose (.md/.rst/.adoc) still routes cheap — the fail-safes must not make the cheap path unreachable"
    assert_equals "5" "$(val doc_files "$out")" "all five prose files are counted as doc"
}

# MUTATION TARGET: the database carve-out (cycle 3 of this PR's own review).
# `*.sql` and `models.py` already force full via the source/unknown arms, so
# those would be tautological fixtures. These use GENERIC extensions — the only
# inputs where the carve-out changes the answer.
test_database_shaped_paths_force_full() {
    local list out path
    for path in \
        'db/schema.json' \
        'schema.yaml' \
        'migrations/0007.yaml' \
        'app/db/migrations/001.json'; do
        list="$(mklist 'README.md' "$path")"
        out="$(route_of "$list")"
        assert_equals "full" "$(val route "$out")" \
            "$path is database-shaped — security/correctness and the database specialist must still run"
    done
}

# MUTATION TARGET: R4-prescan (#695, #699). Raised on issue #550 itself: a
# markdown decomposition row and an OKF memory-conformance row fire on exactly
# the doc-only diffs the cheap path targets, and the cheap path drops the
# `decomposition` dimension that would turn such a row into a judged finding —
# so it would decay to an advisory entry and vanish into `clean: true`.
#
# Fixtures are doc-ONLY, i.e. inputs that route cheap without the rule. That is
# the divergent case: delete R4 and each of these flips to cheap.
test_unsurfaceable_prescan_row_forces_full() {
    local list out cat
    list="$(mklist 'README.md' 'docs/guide.md')"
    for cat in file-length ai-file-bloat doc-file-bloat decomposition-seam \
        okf-missing-type okf-unparseable-frontmatter okf-reserved-file-structure okf-version-drift; do
        out="$(route_of "$list" --prescan-categories "$cat")"
        assert_equals "full" "$(val route "$out")" \
            "a HIGH '$cat' pre-scan row forces full — the cheap path cannot surface it as a judged finding (#695/#699)"
        assert_equals "R4-prescan" "$(val rule "$out")" "R4-prescan decides for '$cat'"
    done
}

# The other half: a category the cheap path CAN still surface must not force
# full. Without this, matching every category would satisfy the test above while
# making the cheap path unreachable whenever any pre-scan row exists.
test_surfaceable_prescan_row_still_routes_cheap() {
    local list out
    list="$(mklist 'README.md' 'docs/guide.md')"
    out="$(route_of "$list" --prescan-categories 'ai-slop,debug-statement,missing-test-file')"

    assert_equals "cheap" "$(val route "$out")" \
        "slop/debug/test-gap rows do NOT force full — they are surfaced by item 5 regardless of route"
    assert_equals "R7-doc-only" "$(val rule "$out")" "R7 still decides"
}

# MUTATION TARGET: R5-config (cycle 6). Four cycles found the SAME class of bug —
# a file the harness treats as security-relevant, classified here as inert and
# routed cheap: CI workflows (c1), database schemas (c3), then dependency
# manifests and lockfiles (c6). The root contradiction was one line in the
# normative table, workflow.src/74-narrowing.js:
#
#     security: ['source', 'database', 'config', 'ci', 'docker']
#
# `config` is listed there, and this script routed config cheap anyway. The fix
# is structural — config now forces `full` — so no carve-out list has to be
# complete. These fixtures are the class that motivated it: a dependency bump is
# the canonical supply-chain diff, and each pairs the manifest with a DOC so a
# classifier lacking R5 routes it cheap (the divergent case).
test_dependency_manifests_and_lockfiles_force_full() {
    local list out path
    for path in \
        'package.json' 'package-lock.json' 'pnpm-lock.yaml' 'yarn.lock' \
        'requirements.txt' 'requirements-dev.txt' 'pyproject.toml' \
        'Cargo.toml' 'Cargo.lock' 'composer.json' 'Gemfile.lock'; do
        list="$(mklist 'README.md' "$path")"
        out="$(route_of "$list")"
        assert_equals "full" "$(val route "$out")" \
            "$path is a dependency manifest/lockfile — a bump is the canonical supply-chain diff and must reach security/correctness"
    done
}

# The general form of the same rule: ANY config file forces full, not just the
# manifests enumerated above. This is what makes the fix structural rather than
# another carve-out list that can never be complete.
test_any_config_file_forces_full() {
    local list out
    list="$(mklist 'README.md' 'settings.toml')"
    out="$(route_of "$list")"

    assert_equals "full" "$(val route "$out")" \
        "a plain config file forces full — DIMENSION_RELEVANT_TYPES lists 'config' under security AND correctness"
    assert_equals "R5-config" "$(val rule "$out")" "R5-config is the deciding rule"
}

# `.txt` is NOT prose for routing purposes: requirements.txt is a dependency pin
# file. Pinned separately because the doc arm is where it used to hide, so a
# future edit re-adding `*.txt` to that arm re-opens the hole silently.
test_txt_is_not_classified_as_doc() {
    local list out
    list="$(mklist 'README.md' 'notes.txt')"
    out="$(route_of "$list")"

    assert_equals "full" "$(val route "$out")" \
        "a .txt file does NOT count as doc — requirements.txt is a manifest, and the doc arm is where it used to route cheap"
}

# MUTATION TARGET: the `set -f` guard in _has_unsurfaceable_category (cycle 7).
# `for x in $list` performs word-splitting AND PATHNAME EXPANSION. The script
# runs from the repo root during a real cycle, so a category token containing a
# glob metacharacter was silently replaced by a matching FILENAME before the
# exact-match `case` ever saw it — defeating the documented "never
# substring-matched" guarantee that R4's soundness rests on.
#
# This fixture plants the trap: it runs from a directory containing a file whose
# name a glob-shaped token would match. Without `set -f` the token becomes
# `decomposition-seam-XYZ`, which is NOT a real category, so R4 does not fire
# and the diff routes cheap — the fail-open direction. With it, the literal
# token is compared and correctly does not match either, but for the right
# reason. The second half proves the guard did not break real matching.
test_prescan_categories_are_not_glob_expanded() {
    local dir list out
    dir="$(command mktemp -d)"
    # A file named EXACTLY like a real category. This is what makes the fixture
    # divergent rather than tautological: the token `decomposition-*` expands to
    # `decomposition-seam` — a REAL category — so the unguarded version MATCHES
    # and routes full, while the guarded version keeps the literal token, does
    # not match, and routes cheap. A near-miss filename (`decomposition-seam-XYZ`)
    # would NOT diverge: it expands to a non-category, both versions route cheap,
    # and the test passes with and without the fix. Verified by mutation.
    command touch "$dir/decomposition-seam"
    list="$(mklist 'README.md' 'docs/guide.md')"

    # Run FROM the hostile directory so pathname expansion has something to hit.
    out="$(cd "$dir" && bash "$RR" check --files "$list" --prescan-categories 'decomposition-*')"
    assert_equals "cheap" "$(val route "$out")" \
        "a glob-shaped token is NOT expanded against the cwd — without set -f it would expand to the real category 'decomposition-seam' and wrongly fire R4"

    # The guard must not break genuine matching.
    out="$(cd "$dir" && bash "$RR" check --files "$list" --prescan-categories 'decomposition-seam')"
    assert_equals "full" "$(val route "$out")" \
        "the real category still fires R4 from the same directory (set -f did not break matching)"
    assert_equals "R4-prescan" "$(val rule "$out")" "R4-prescan still decides"

    command rm -rf "$dir"
}

# Globbing must be RESTORED after the predicate runs, on both its exits. A
# leaked `set -f` would silently disable pathname expansion for the rest of the
# script. Asserted behaviorally: a later rule that depends on normal operation
# still works after a call that returns via the matched (early-return) path.
test_globbing_is_restored_after_the_predicate() {
    local list out
    list="$(mklist 'README.md')"
    # First call returns via the MATCHED branch (the early `return 0`).
    out="$(route_of "$list" --prescan-categories 'decomposition-seam')"
    assert_equals "full" "$(val route "$out")" "matched-branch call routes full"
    # A subsequent independent call must behave normally.
    out="$(route_of "$list")"
    assert_equals "cheap" "$(val route "$out")" \
        "a later invocation is unaffected — set +f runs on the early-return path too"
}

# Exact-token matching, not substring: a category that merely CONTAINS a
# blocked name must not trip the rule.
test_prescan_category_match_is_exact() {
    local list out
    list="$(mklist 'README.md')"
    out="$(route_of "$list" --prescan-categories 'no-file-length-issue,decomposition-seam-resolved')"

    assert_equals "cheap" "$(val route "$out")" \
        "categories are matched as exact tokens — a superstring must not force full"
}

# A path whose DIRECTORY looks documentary but whose file is source. Pins the
# basename anchoring: a classifier matching on the whole path could route cheap.
test_source_file_under_docs_directory_forces_full() {
    local list out
    list="$(mklist 'docs/examples/build.sh')"
    out="$(route_of "$list")"

    assert_equals "full" "$(val route "$out")" \
        "a .sh under docs/ is classified by BASENAME, not by directory"
    assert_equals "R2-source" "$(val rule "$out")" "R2-source fires on the basename"
}

# The inverse anchoring trap: a directory named like a source file.
test_doc_under_source_looking_directory_still_routes_cheap() {
    local list out
    list="$(mklist 'app.py/NOTES.md')"
    out="$(route_of "$list")"

    assert_equals "cheap" "$(val route "$out")" \
        "a .md inside a directory named app.py is still a doc"
}

# An empty or missing list is ambiguity, not emptiness-as-permission.
test_empty_list_forces_full() {
    local list out
    list="$(mklist)"
    out="$(route_of "$list")"

    assert_equals "full" "$(val route "$out")" "an EMPTY file list forces full"
    assert_equals "R0-empty" "$(val rule "$out")" "R0-empty is the deciding rule"
}

test_missing_list_file_forces_full() {
    local out
    out="$(bash "$RR" check --files "$REPO_ROOT/no-such-file-xyz.txt")"

    assert_equals "full" "$(val route "$out")" \
        "a MISSING file list forces full rather than reading as zero source files"
    assert_equals "R0-empty" "$(val rule "$out")" "R0-empty covers the missing-file case"
}

# MUTATION TARGET: the R1 env override. Neuter it and this goes red. The fixture
# is doc-only — i.e. a diff the classifier WOULD route cheap — so the test can
# only pass when the override is honored.
test_operator_override_forces_full() {
    local list out
    list="$(mklist 'README.md' 'docs/a.md')"
    out="$(LIBRARIAN_REVIEW_ROUTE=full bash "$RR" check --files "$list")"

    assert_equals "full" "$(val route "$out")" \
        "LIBRARIAN_REVIEW_ROUTE=full disables routing on a would-be-cheap diff"
    assert_equals "R1-forced" "$(val rule "$out")" "R1-forced is the deciding rule"
}

# A typo in the override must disable the optimization, not silently enable it.
test_malformed_override_value_forces_full() {
    local list out
    list="$(mklist 'README.md')"
    out="$(LIBRARIAN_REVIEW_ROUTE=cheep bash "$RR" check --files "$list")"

    assert_equals "full" "$(val route "$out")" \
        "a TYPO'd override value fails safe to full, never to cheap"
}

# `auto` is the documented default and must still permit routing — without this
# the override test above would also pass if the script ignored the var entirely
# and always returned full.
test_auto_override_permits_cheap() {
    local list out
    list="$(mklist 'README.md')"
    out="$(LIBRARIAN_REVIEW_ROUTE=auto bash "$RR" check --files "$list")"

    assert_equals "cheap" "$(val route "$out")" \
        "LIBRARIAN_REVIEW_ROUTE=auto still allows the cheap path"
}

# --- 3. The line ceiling (R4) ------------------------------------------------
# It may only ever force `full`. The paired under/over cases prove it is read at
# all, and that it cannot manufacture a `cheap`.

test_diff_over_line_ceiling_forces_full() {
    local list out
    list="$(mklist 'README.md')"
    out="$(route_of "$list" --diff-lines 5000)"

    assert_equals "full" "$(val route "$out")" \
        "a doc-only diff OVER the line ceiling still forces full"
    assert_equals "R6-max-lines" "$(val rule "$out")" "R6-max-lines is the deciding rule"
}

test_diff_under_line_ceiling_routes_cheap() {
    local list out
    list="$(mklist 'README.md')"
    out="$(route_of "$list" --diff-lines 100)"

    assert_equals "cheap" "$(val route "$out")" \
        "a doc-only diff under the ceiling routes cheap"
}

test_line_ceiling_is_env_overridable() {
    local list out
    list="$(mklist 'README.md')"
    out="$(LIBRARIAN_REVIEW_ROUTE_MAX_LINES=50 bash "$RR" check --files "$list" --diff-lines 100)"

    assert_equals "full" "$(val route "$out")" \
        "LIBRARIAN_REVIEW_ROUTE_MAX_LINES lowers the ceiling"
}

# The ceiling cannot rescue a source diff into the cheap path — R2 outranks R4.
test_line_ceiling_cannot_make_a_source_diff_cheap() {
    local list out
    list="$(mklist 'src/tiny.py')"
    out="$(route_of "$list" --diff-lines 1)"

    assert_equals "full" "$(val route "$out")" \
        "a ONE-LINE source diff is still full — line count never yields cheap"
    assert_equals "R2-source" "$(val rule "$out")" "R2 outranks the line ceiling"
}

# --- 4. Fail-loud input validation -------------------------------------------

test_bad_diff_lines_fails_loud() {
    local out status
    local list
    list="$(mklist 'README.md')"
    set +e
    out="$(bash "$RR" check --files "$list" --diff-lines abc 2>&1)"
    status=$?
    set -e

    assert_equals "2" "$status" "a non-numeric --diff-lines exits 2"
    assert_contains "$out" "non-negative integer" "the error names the expected shape"
}

test_bad_env_ceiling_fails_loud() {
    local out status list
    list="$(mklist 'README.md')"
    set +e
    out="$(LIBRARIAN_REVIEW_ROUTE_MAX_LINES=xx bash "$RR" check --files "$list" 2>&1)"
    status=$?
    set -e

    assert_equals "2" "$status" "a non-numeric ceiling exits 2"
    assert_contains "$out" "LIBRARIAN_REVIEW_ROUTE_MAX_LINES" "the error names the variable"
}

test_missing_files_flag_fails_loud() {
    local out status
    set +e
    out="$(bash "$RR" check 2>&1)"
    status=$?
    set -e

    assert_equals "2" "$status" "omitting --files exits 2"
    assert_contains "$out" "--files is required" "the error says what is missing"
}

test_unknown_flag_and_subcommand_fail_loud() {
    local out status list
    list="$(mklist 'README.md')"
    set +e
    out="$(bash "$RR" check --files "$list" --bogus x 2>&1)"
    status=$?
    set -e
    assert_equals "2" "$status" "an unknown flag exits 2"
    assert_contains "$out" "unknown flag" "the error names the problem"

    set +e
    out="$(bash "$RR" frobnicate 2>&1)"
    status=$?
    set -e
    assert_equals "2" "$status" "an unknown subcommand exits 2"
    assert_contains "$out" "unknown subcommand" "the error names the problem"
}

# --- 5. Anti-vacuity ---------------------------------------------------------
# Every fail-safe test above asserts `full`. If the script were broken such that
# it returned `full` unconditionally, ALL of them would still pass. This is the
# guard against that whole class: at least one input must reach `cheap`.
test_cheap_is_reachable_at_all() {
    local list out
    list="$(mklist 'README.md')"
    out="$(route_of "$list")"

    assert_equals "cheap" "$(val route "$out")" \
        "ANTI-VACUITY: a plain doc-only diff reaches cheap — without this, a script \
that always returned 'full' would satisfy every fail-safe assertion in this file"
}

run_test test_doc_and_config_only_routes_cheap
run_test test_scope_drift_survives_the_cheap_route
run_test test_full_route_names_every_dimension
run_test test_one_source_file_among_many_docs_forces_full
run_test test_source_file_last_in_list_forces_full
run_test test_unknown_extension_forces_full
run_test test_extensionless_infra_files_force_full
run_test test_ci_and_container_files_force_full
run_test test_database_shaped_paths_force_full
run_test test_unsurfaceable_prescan_row_forces_full
run_test test_dependency_manifests_and_lockfiles_force_full
run_test test_any_config_file_forces_full
run_test test_txt_is_not_classified_as_doc
run_test test_surfaceable_prescan_row_still_routes_cheap
run_test test_prescan_categories_are_not_glob_expanded
run_test test_globbing_is_restored_after_the_predicate
run_test test_prescan_category_match_is_exact
run_test test_ordinary_prose_still_routes_cheap
run_test test_source_file_under_docs_directory_forces_full
run_test test_doc_under_source_looking_directory_still_routes_cheap
run_test test_empty_list_forces_full
run_test test_missing_list_file_forces_full
run_test test_operator_override_forces_full
run_test test_malformed_override_value_forces_full
run_test test_auto_override_permits_cheap
run_test test_diff_over_line_ceiling_forces_full
run_test test_diff_under_line_ceiling_routes_cheap
run_test test_line_ceiling_is_env_overridable
run_test test_line_ceiling_cannot_make_a_source_diff_cheap
run_test test_bad_diff_lines_fails_loud
run_test test_bad_env_ceiling_fails_loud
run_test test_missing_files_flag_fails_loud
run_test test_unknown_flag_and_subcommand_fail_loud
run_test test_cheap_is_reachable_at_all

generate_report
