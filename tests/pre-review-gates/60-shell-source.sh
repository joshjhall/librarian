# shellcheck shell=bash
# Shell is a scanned source language (#598) + repo-rooted FOREIGN shell test for py (#644)
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.

# --- #598: shell is a scanned source language -------------------------------

# The headline #598 case. `*.sh` sat in test-skip-patterns.default, so shell
# files never reached scan_missing_tests — in a repo whose test suites ARE shell
# that silenced the scanner on the bulk of every diff, and an empty pre-scan is
# indistinguishable in the handoff from a clean one.
#
# An untested .sh must fire; one covered by tests/validate-<name>.sh must not.
# Both assertions live in ONE run so a pass cannot come from the scanner having
# gone globally silent.
test_sh_missing_test_fires_and_convention_silences() {
    local sb list tested control
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/tests"
    command printf '%s\n' "echo covered" >"$sb/scripts/covered.sh"
    command printf '%s\n' "# exercises covered.sh" >"$sb/tests/validate-covered.sh"
    command printf '%s\n' "echo lonely" >"$sb/scripts/lonely.sh"

    list="$sb/files.txt"
    command printf '%s\n' "$sb/scripts/covered.sh" "$sb/scripts/lonely.sh" >"$list"

    run_gate_in "$sb" "$list"

    tested="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'covered\.sh' || true)"
    control="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'lonely\.sh' || true)"

    assert_equals "0" "$tested" \
        "a .sh covered by tests/validate-<name>.sh emits no missing-test-file (#598 AC#2)"
    assert_equals "1" "$control" \
        "an untested .sh emits missing-test-file (#598 AC#1)"
}

# EVERY alternative sh_test_find_args builds, so a typo isolated to any single
# entry has a test that fails. Sampling one exemplar per stem would leave the
# wildcard forms unexercised — the trap #555's stem-form case documents.
#
# Each row runs in its own sandbox holding exactly ONE test file, so a match can
# only come from the alternative under test.
#
# Every row carries an UNTESTED control alongside the subject. Without it these
# rows assert only an ABSENCE and pass vacuously whenever the scanner is silent
# for an unrelated reason — verified: with `*.sh` restored to the skip list this
# case still passed until the control was added.
test_sh_stem_forms_all_match() {
    local sb stem form fname ext i=0
    local stems="validate-thing test-thing test_thing thing_test thing.test thing-test"

    for stem in $stems; do
        for form in exact hyphen underscore; do
            # Alternate the extension so both .sh and .bash are covered.
            if [ $((i % 2)) -eq 0 ]; then ext="sh"; else ext="bash"; fi
            i=$((i + 1))
            case "$form" in
                exact) fname="${stem}.${ext}" ;;
                hyphen) fname="${stem}-extra.${ext}" ;;
                underscore) fname="${stem}_extra.${ext}" ;;
            esac

            new_git_sandbox sb
            command mkdir -p "$sb/scripts" "$sb/tests"
            command printf '%s\n' "echo thing" >"$sb/scripts/thing.sh"
            command printf '%s\n' "# test" >"$sb/tests/$fname"
            command printf '%s\n' "echo lonely" >"$sb/scripts/lonely.sh"
            command printf '%s\n' \
                "$sb/scripts/thing.sh" "$sb/scripts/lonely.sh" >"$sb/files.txt"

            run_gate_in "$sb" "$sb/files.txt"

            assert_equals "0" \
                "$(category_rows "$GATE_OUT" "missing-test-file" |
                    command grep -c 'thing\.sh' || true)" \
                "tests/$fname suppresses missing-test-file for thing.sh (#598)"
            assert_equals "1" \
                "$(category_rows "$GATE_OUT" "missing-test-file" |
                    command grep -c 'lonely\.sh' || true)" \
                "...and the untested control still fires alongside tests/$fname (#598)"
        done
    done
}

# The non-stem arms: an exact same-name suite (tests/<name>.sh) and the
# split-suite fragment layout (#564), where cases live at tests/<suite>/NN-<area>.sh.
# Same control discipline as the stem-form case above.
test_sh_exact_and_fragment_arms_match() {
    local sb fname
    for fname in "gate-watch.sh" "suite/20-gate-watch.sh" "suite/20-gate-watch-extra.sh"; do
        new_git_sandbox sb
        command mkdir -p "$sb/scripts" "$sb/tests/suite"
        command printf '%s\n' "echo x" >"$sb/scripts/gate-watch.sh"
        command printf '%s\n' "# test" >"$sb/tests/$fname"
        command printf '%s\n' "echo lonely" >"$sb/scripts/lonely.sh"
        command printf '%s\n' \
            "$sb/scripts/gate-watch.sh" "$sb/scripts/lonely.sh" >"$sb/files.txt"

        run_gate_in "$sb" "$sb/files.txt"

        assert_equals "0" \
            "$(category_rows "$GATE_OUT" "missing-test-file" |
                command grep -c 'gate-watch\.sh' || true)" \
            "tests/$fname suppresses missing-test-file for gate-watch.sh (#598)"
        assert_equals "1" \
            "$(category_rows "$GATE_OUT" "missing-test-file" |
                command grep -c 'lonely\.sh' || true)" \
            "...and the untested control still fires alongside tests/$fname (#598)"
    done
}

# The hyphen-stripped candidate (golem-status -> status) is what lets a
# tests/golem-scripts/60-status.sh count for scripts/golem-status.sh.
#
# It is EXACT-ONLY, and the negative half is the point: allowing wildcard forms
# on the stripped token was measured to match bin/ruff-version.sh against
# tests/release/10-version-utils.sh via a bare `version` — a silent false
# negative on a file with no test of its own. If that arm is ever loosened, the
# second assertion here fails.
test_sh_stripped_candidate_is_exact_only() {
    local sb hit miss
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/tests/golem-scripts" "$sb/tests/release"
    command printf '%s\n' "echo s" >"$sb/scripts/golem-status.sh"
    command printf '%s\n' "# test" >"$sb/tests/golem-scripts/60-status.sh"
    # No test named after ruff-version; only a WILDCARD-form file on the bare
    # stripped token `version`, which must NOT count.
    command printf '%s\n' "echo r" >"$sb/scripts/ruff-version.sh"
    command printf '%s\n' "# test" >"$sb/tests/release/10-version-utils.sh"

    command printf '%s\n' \
        "$sb/scripts/golem-status.sh" "$sb/scripts/ruff-version.sh" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    hit="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'golem-status\.sh' || true)"
    miss="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'ruff-version\.sh' || true)"

    assert_equals "0" "$hit" \
        "the stripped candidate matches an EXACT NN-<cand>.sh fragment (#598)"
    assert_equals "1" "$miss" \
        "the stripped candidate does NOT match a wildcard form — no false negative (#598)"
}

# The strip removes ONE leading segment, not all of them: `golem-gate-watch`
# becomes `gate-watch`, not `watch`. Only the single-hyphen case was covered
# above, so the multi-hyphen behaviour — which segment actually goes, and
# whether the remaining multi-word candidate still reaches the exact-only arms —
# was unexercised.
#
# The sandbox holds ONLY the stripped-form fragment, so a match can come from
# nothing else, and a `watch`-only file is present as a negative: if the strip
# ever became greedy (`${name##*-}`) the first assertion would still pass on
# that file, so the second pins the direction.
test_sh_stripped_candidate_strips_one_segment() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/tests/suite"
    command printf '%s\n' "echo x" >"$sb/scripts/golem-gate-watch.sh"
    command printf '%s\n' "# test" >"$sb/tests/suite/20-gate-watch.sh"
    # Greedy-strip bait: matches `watch`, which a one-segment strip never yields.
    command printf '%s\n' "echo y" >"$sb/scripts/golem-token-scrape.sh"
    command printf '%s\n' "# test" >"$sb/tests/suite/30-scrape.sh"
    command printf '%s\n' \
        "$sb/scripts/golem-gate-watch.sh" "$sb/scripts/golem-token-scrape.sh" \
        >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "0" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'golem-gate-watch\.sh' || true)" \
        "a multi-hyphen name strips ONE segment: golem-gate-watch -> gate-watch (#598)"
    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'golem-token-scrape\.sh' || true)" \
        "...and does NOT strip to the last segment — 30-scrape.sh must not match (#598)"
}

# A `.bash` SOURCE file end-to-end. The `sh | bash)` case label claims .bash is
# handled, and both the colocated list and the repo-rooted globs carry .bash
# arms — but every other case here scans a `.sh` source and varies .bash only on
# the discovered TEST file. A regression breaking .bash-source handling outright
# would have gone unnoticed, so this scans the .bash source itself, through both
# the colocated path and the repo-rooted path, with an untested control.
test_bash_source_is_scanned() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/tests"
    # colocated .bash test for a .bash source
    command printf '%s\n' "echo c" >"$sb/scripts/colo.bash"
    command printf '%s\n' "# test" >"$sb/scripts/test_colo.bash"
    # repo-rooted test for a .bash source
    command printf '%s\n' "echo r" >"$sb/scripts/rooted.bash"
    command printf '%s\n' "# test" >"$sb/tests/validate-rooted.sh"
    # untested control
    command printf '%s\n' "echo l" >"$sb/scripts/lonely.bash"

    command printf '%s\n' \
        "$sb/scripts/colo.bash" "$sb/scripts/rooted.bash" "$sb/scripts/lonely.bash" \
        >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "0" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'colo\.bash' || true)" \
        "a .bash source with a colocated test_<name>.bash is silent (#598)"
    assert_equals "0" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'rooted\.bash' || true)" \
        "a .bash source with a repo-rooted tests/validate-<name>.sh is silent (#598)"
    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'lonely\.bash' || true)" \
        "an untested .bash source still emits missing-test-file (#598)"
}

# The colocated list accepts the hyphen `test-<name>` form, not just the
# underscore one — the repo-rooted stem set has always accepted both, and the
# two discovery paths must agree on what a test is named.
test_sh_colocated_hyphen_form_matches() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/scripts/tests"
    command printf '%s\n' "echo a" >"$sb/scripts/alpha.sh"
    command printf '%s\n' "# test" >"$sb/scripts/test-alpha.sh"
    command printf '%s\n' "echo b" >"$sb/scripts/beta.sh"
    command printf '%s\n' "# test" >"$sb/scripts/tests/test-beta.sh"
    command printf '%s\n' "echo l" >"$sb/scripts/lonely.sh"
    command printf '%s\n' \
        "$sb/scripts/alpha.sh" "$sb/scripts/beta.sh" "$sb/scripts/lonely.sh" \
        >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "0" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'alpha\.sh' || true)" \
        "a colocated sibling test-<name>.sh suppresses missing-test-file (#598)"
    assert_equals "0" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'beta\.sh' || true)" \
        "a colocated tests/test-<name>.sh suppresses missing-test-file (#598)"
    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'lonely\.sh' || true)" \
        "...while the untested control still fires (#598)"
}

# A DIRECTORY named like a test must not suppress a finding — the `-type f`
# guard carried over from find_repo_rooted_js_tests. Without it a snapshot or
# fixture dir silently hides exactly the bug this scanner reports.
test_sh_probe_ignores_directories() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/tests/validate-thing.sh"
    command printf '%s\n' "echo thing" >"$sb/scripts/thing.sh"
    command printf '%s\n' "$sb/scripts/thing.sh" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'thing\.sh' || true)" \
        "a DIRECTORY named tests/validate-thing.sh does not suppress the finding (#598)"
}

# tests/fixtures/** is excluded. This repo keeps scanner fixtures at
# tests/fixtures/category-parity/match/patterns.sh; without the exclusion every
# plugins/**/patterns.sh matched that one file and 14 real scanners went
# silently "covered". A fixture is an input to a test, not a test.
test_sh_probe_excludes_fixtures() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/skills" "$sb/tests/fixtures/parity/match"
    command printf '%s\n' "echo p" >"$sb/skills/patterns.sh"
    command printf '%s\n' "# fixture, not a test" \
        >"$sb/tests/fixtures/parity/match/patterns.sh"
    command printf '%s\n' "$sb/skills/patterns.sh" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'patterns\.sh' || true)" \
        "a same-named file under tests/fixtures/ does not count as a test (#598)"
}

# The probe stays name-anchored: an unrelated shell test in the tree must not
# satisfy a source it says nothing about.
test_sh_probe_is_name_anchored() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/tests"
    command printf '%s\n' "echo orphan" >"$sb/scripts/orphan.sh"
    command printf '%s\n' "# unrelated" >"$sb/tests/validate-something-else.sh"
    command printf '%s\n' "$sb/scripts/orphan.sh" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'orphan\.sh' || true)" \
        "an unrelated tests/*.sh does not suppress missing-test-file (#598)"
}

# Two boundaries of the skip-list edit, in one run.
#
# *.zsh STAYS skipped: it has no discovery arm, so un-skipping it would route
# zsh to the unknown-extension MEDIUM branch — noise, not a finding. And a .sh
# must NOT produce untested-public-api: shell has no export syntax and #598
# explicitly defers that to its own design. Un-skipping *.sh routes shell into
# scan_untested_public_api for the first time, so this pins that it stays a
# no-op there rather than silently gaining a half-designed category.
test_sh_skip_and_category_boundaries() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/scripts"
    command printf '%s\n' "echo z" >"$sb/scripts/thing.zsh"
    command printf '%s\n' "run() { echo hi; }" "run" >"$sb/scripts/exports.sh"
    command printf '%s\n' "$sb/scripts/thing.zsh" "$sb/scripts/exports.sh" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "0" \
        "$(command printf '%s\n' "$GATE_OUT" | command grep -c 'thing\.zsh' || true)" \
        "*.zsh is still skipped — no unknown-extension MEDIUM row (#598)"
    assert_equals "0" \
        "$(category_rows "$GATE_OUT" "untested-public-api" |
            command grep -c 'exports\.sh' || true)" \
        "a .sh emits no untested-public-api — shell has no arm there (#598)"
    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'exports\.sh' || true)" \
        "...while the same .sh still emits missing-test-file (not globally silent)"
}

# This repo's OWN tree: the naming convention resolves for real files, so the
# fix cannot be passing only on synthetic sandboxes. Uses sources whose tests
# reach them through three DIFFERENT arms.
test_real_repo_sh_sources_not_flagged() {
    local d list rows control
    d="$(fresh_dir)"
    list="$d/files.txt"
    # An untested control OUTSIDE the repo accompanies the three real sources,
    # so a pass cannot come from the scanner being silent for shell generally.
    command printf '%s\n' "echo lonely" >"$d/lonely.sh"
    # validate-<name>.sh | exact same-name suite | NN-<stripped> fragment
    command printf '%s\n' \
        "$REPO_ROOT/plugins/workflow/hooks/bash-guard.sh" \
        "$REPO_ROOT/plugins/workflow/scripts/golem-gate-watch.sh" \
        "$REPO_ROOT/plugins/workflow/scripts/golem-status.sh" \
        "$d/lonely.sh" >"$list"

    run_gate "$list"

    rows="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -cE 'bash-guard\.sh|golem-gate-watch\.sh|golem-status\.sh' || true)"
    control="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'lonely\.sh' || true)"

    assert_equals "0" "$rows" \
        "real repo shell sources covered by the convention emit no missing-test-file (#598 AC#3)"
    assert_equals "1" "$control" \
        "...while an untested control in the same run still fires (#598)"
}

# --- missing-test-file: repo-rooted FOREIGN (shell) test for py (#644) -------

# The headline #644 case. A .py source whose only coverage is a repo-rooted
# SHELL gate must not emit missing-test-file. Before the fix the py arm probed
# only python-named tests, so in this repo — whose python IS tested from bash —
# it could not resolve by construction and all 15 plugins/**/patterns.py fired
# while 0 of 15 sibling patterns.sh did.
#
# ONE fixture asserts BOTH branches (AC#4): the covered source goes silent AND
# an uncovered control in the same run still fires. A case that only asserted
# the silence would pass just as well if the detector had stopped working.
test_py_repo_rooted_foreign_test_detected() {
    local sb covered control
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "x = 1" >"$sb/src/thing.py"
    # Named for the source AND mentioning it — both anchors satisfied.
    command printf '%s\n' "# exercises thing.py" \
        >"$sb/tests/validate-thing-coverage.sh"
    command printf '%s\n' "y = 2" >"$sb/src/lonely.py"
    command printf '%s\n' "$sb/src/thing.py" "$sb/src/lonely.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    covered="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'thing\.py' || true)"
    control="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'lonely\.py' || true)"

    assert_equals "0" "$covered" \
        "a .py covered by a repo-rooted shell gate emits no missing-test-file (#644 AC#1)"
    assert_equals "1" "$control" \
        "...while an uncovered .py in the same run still fires (#644 AC#4)"
}

# The CONTENT anchor is a real filter, not documented intent. A shell test named
# correctly for the source but never mentioning it must NOT suppress: sharing a
# stem with a suite is not evidence that the suite exercises the python file.
#
# This is the half that makes the foreign probe stricter than the sh arm it
# mirrors. Without it, the name arms alone decide, and this fixture would go
# silent.
#
# KNOWN UNCOVERED, recorded here because it is not evident from the suite: that
# the candidate loop keeps scanning PAST a failed candidate to a later
# satisfying one. Pinning it needs a miss visited before a match, and the visit
# order is `find ... -print`'s, which is unspecified — measured here it is
# directory-hash order, neither name nor creation (five files created 01..05 came
# back 02, 04, 05, 01, 03). With two candidates the outcome flips on which one
# find reaches first, so such a fixture passes WITH a return-after-first
# regression whenever the match comes first; several arrangements do not rescue
# it (an arbitrary permutation has no finite set of orders to enumerate), and a
# many-misses/one-match shape only makes the bug PROBABLY caught, which is flaky
# rather than pinned. `find` also cannot be stubbed through this harness:
# run_gate_in execs the gate via /usr/bin/env with a scrubbed environment and the
# probe calls `command find`, which bypasses functions and aliases. So that
# property rests on construction review, not on a fixture here.
test_py_foreign_probe_requires_content_anchor() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "x = 1" >"$sb/src/thing.py"
    # Right name, says nothing about thing.py — it tests the shell sibling.
    command printf '%s\n' "# exercises thing.sh only" \
        >"$sb/tests/validate-thing-coverage.sh"
    command printf '%s\n' "$sb/src/thing.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'thing\.py' || true)" \
        "a name-matching shell test that never mentions the .py does not suppress (#644)"
}

# The NAME anchor holds — and this is the #601 regression pinned at the probe.
#
# #601 was a test_discovery template with no {name}: a CONSTANT that resolved for
# every source and would have silenced missing-test-file repo-wide. The foreign
# probe cannot degenerate that way because its find args are built from the
# source's own basename. Here the tests/ tree is populated and every file MENTIONS
# thing.py — so the content anchor alone would be satisfied — but none is NAMED
# for it, and the row must still fire. If the name arms were ever dropped in
# favour of a bare content search, this is what fails.
test_py_foreign_probe_is_name_anchored() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "x = 1" >"$sb/src/thing.py"
    command printf '%s\n' "# mentions thing.py in passing" \
        >"$sb/tests/validate-something-else.sh"
    command printf '%s\n' "# also mentions thing.py" \
        >"$sb/tests/validate-unrelated-suite.sh"
    command printf '%s\n' "$sb/src/thing.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'thing\.py' || true)" \
        "a populated tests/ tree that names the .py but isn't NAMED for it still fires (#644 AC#3)"
}

# The fixtures exclusion, which is load-bearing: a fixture is an INPUT to a test
# (#598's rationale, where one tests/fixtures/.../patterns.sh silently "covered"
# 14 real scanners). MEASURED — dropping `-not -path '*/fixtures/*'` from the
# probe fails this case.
#
# There is deliberately NO markdown half, though the sibling symbol helper
# excludes `*.md` and an earlier version of this case asserted it here. That
# assertion was a tautology: this probe only sees candidates that already matched
# sh_test_find_args, and all 40 of those arms end in `.sh`/`.bash`, so no `.md`
# can be in the candidate set. The fixture passed with the `-not -name '*.md'`
# clause DELETED — proving nothing, and presenting dead code as covered. The
# clause is now gone from the probe.
test_py_foreign_probe_excludes_fixtures() {
    local sb

    new_git_sandbox sb
    command mkdir -p "$sb/src" "$sb/tests/fixtures/parity"
    command printf '%s\n' "x = 1" >"$sb/src/thing.py"
    command printf '%s\n' "# fixture referencing thing.py" \
        >"$sb/tests/fixtures/parity/validate-thing.sh"
    command printf '%s\n' "$sb/src/thing.py" >"$sb/files.txt"
    run_gate_in "$sb" "$sb/files.txt"
    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'thing\.py' || true)" \
        "a matching candidate under tests/fixtures/ is not coverage for a .py (#644)"

}

# The content anchor is DELIMITED, not a bare substring — the pre-PR review
# caught this as a live false negative, not a hypothetical.
#
# An unanchored `grep -F "patterns.py"` also matches `get_patterns.py`,
# `not_patterns.py` and `patterns.py.bak`. Both anchors were satisfied by a suite
# NAMED validate-patterns.sh that only discussed an unrelated get_patterns.py, so
# a real HIGH row was silently suppressed — the over-match class #598/#601 exist
# to prevent.
#
# Three superstring shapes (prefix, suffix, both) must each still fire, and the
# two legitimate shapes — the bare basename and a PATH-QUALIFIED reference — must
# still suppress. Without those last two this case would pass just as well if the
# anchor had over-tightened into matching nothing.
test_py_foreign_probe_content_anchor_is_delimited() {
    local sb
    new_git_sandbox sb
    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "x = 1" >"$sb/src/patterns.py"
    command printf '%s\n' "y = 2" >"$sb/src/widget.py"
    command printf '%s\n' "z = 3" >"$sb/src/gadget.py"
    # Each names its source but mentions only a SUPERSTRING of it.
    command printf '%s\n' "# exercises get_patterns.py, an unrelated file" \
        >"$sb/tests/validate-patterns.sh"
    command printf '%s\n' "# exercises widget.py.bak, a stale copy" \
        >"$sb/tests/validate-widget.sh"
    command printf '%s\n' "# exercises my_gadget.pyc, a build artifact" \
        >"$sb/tests/validate-gadget.sh"
    command printf '%s\n' "$sb/src/patterns.py" "$sb/src/widget.py" \
        "$sb/src/gadget.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c '/patterns\.py' || true)" \
        "a PREFIX superstring (get_patterns.py) does not suppress patterns.py (#644)"
    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c '/widget\.py' || true)" \
        "a SUFFIX superstring (widget.py.bak) does not suppress widget.py (#644)"
    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c '/gadget\.py' || true)" \
        "a both-ends superstring (my_gadget.pyc) does not suppress gadget.py (#644)"

    # The positive direction, so the anchor cannot pass by matching NOTHING: a
    # bare mention and a path-qualified mention must both still resolve.
    new_git_sandbox sb
    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "x = 1" >"$sb/src/patterns.py"
    command printf '%s\n' "y = 2" >"$sb/src/widget.py"
    command printf '%s\n' "# exercises patterns.py" \
        >"$sb/tests/validate-patterns.sh"
    command printf '%s\n' "# exercises src/widget.py end to end" \
        >"$sb/tests/validate-widget.sh"
    command printf '%s\n' "$sb/src/patterns.py" "$sb/src/widget.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_output_empty "$(category_rows "$GATE_OUT" "missing-test-file" || true)" \
        "a bare and a PATH-QUALIFIED mention both still suppress (#644)"
}

# A basename carrying regex metacharacters must be matched LITERALLY, so the
# escaping in the content anchor is load-bearing in the suite and not only in the
# comment. `.` is the reachable metacharacter in a python basename: unescaped, it
# is "any char", so `c.d.py` would match the text `cXdYpy` and suppress a source
# that nothing tests.
test_py_foreign_probe_escapes_regex_metacharacters() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "x = 1" >"$sb/src/c.d.py"
    # Matches `c.d.py` as a REGEX but not as a literal.
    command printf '%s\n' "# exercises cXdYpy and nothing else" \
        >"$sb/tests/validate-c.d.sh"
    command printf '%s\n' "$sb/src/c.d.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'c\.d\.py' || true)" \
        "a dot in the basename is escaped, not treated as any-char (#644)"

    # ...and the same name still resolves on a LITERAL mention, so the escaping
    # did not simply break the match.
    new_git_sandbox sb
    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "x = 1" >"$sb/src/c.d.py"
    command printf '%s\n' "# exercises c.d.py" >"$sb/tests/validate-c.d.sh"
    command printf '%s\n' "$sb/src/c.d.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_output_empty "$(category_rows "$GATE_OUT" "missing-test-file" || true)" \
        "...while a LITERAL mention of the same metacharacter name still suppresses (#644)"
}

# The REAL tree — the measurement the issue opens with, pinned. Mirrors
# test_real_repo_sh_sources_not_flagged so the fix cannot be passing only on
# synthetic sandboxes.
#
# Sources reach their gates through two different shapes: the 15 same-stemmed
# patterns.py (all resolving to tests/validate-patterns-coverage.sh, the case
# test_discovery provably could not express) and a uniquely-named script. An
# untested control OUTSIDE the repo rides along, so a pass cannot come from the
# scanner having gone silent for python generally.
test_real_repo_py_sources_not_flagged() {
    local d list rows control
    d="$(fresh_dir)"
    list="$d/files.txt"
    command printf '%s\n' "z = 1" >"$d/lonely.py"
    command printf '%s\n' \
        "$REPO_ROOT/plugins/review-audit/skills/check-security/patterns.py" \
        "$REPO_ROOT/plugins/dev-core/skills/drift-detect/patterns.py" \
        "$REPO_ROOT/plugins/workflow/scripts/autonomy-resolve.py" \
        "$d/lonely.py" >"$list"

    run_gate "$list"

    rows="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -cE 'patterns\.py|autonomy-resolve\.py' || true)"
    control="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'lonely\.py' || true)"

    assert_equals "0" "$rows" \
        "real repo .py sources covered by bash gates emit no missing-test-file (#644 AC#1)"
    assert_equals "1" "$control" \
        "...while an untested control in the same run still fires (#644 AC#4)"
}
