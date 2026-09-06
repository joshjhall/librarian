#!/usr/bin/env bash
# Behavioural coverage for tests/validate-okf-bundle.sh (issue #697).
#
# The gate under test has FOUR exit paths that a casual reading conflates, and
# three of them are indistinguishable from success if they regress:
#
#   77  scanner unreachable       — the gate did NOT run
#   0   bundle absent / empty     — the gate ran, corpus empty
#   0   findings within baseline  — advisory: reported, not fatal
#   1   growth, or any finding in blocking mode
#
# A gate whose skip renders as `[ok]` sits inert unnoticed (#538, #571); a gate
# whose advisory mode never fails cannot stop new drift, which is the thing #697
# asked for; and a gate that prints memory CONTENT leaks the bundle into every
# CI log. Each of those is pinned below.
#
# WHY A SIBLING FILE RATHER THAN CASES IN validate-lint-gates.sh. That file is
# the meta-gate for this class and these cases belong to the same family — but
# it measures 680 production LOC against a 700 `sh` warning budget, 20 lines of
# headroom (ship-issue/plan-lens.sh, 2026-09-06; an estimate of 30 already
# projects over). Adding ~200 lines there would have forced a 41-unit
# decomposition into an effort/small issue. What validate-lint-gates.sh DOES
# gain is the one assertion that must not fork: this gate's SKIP_EXIT_CODE is
# added to its sentinel cross-check, so the constant stays agreed repo-wide.
#
# TEST SHAPE. Each case runs the REAL tests/validate-okf-bundle.sh against a
# sandbox bundle and a sandbox baseline it controls, so behaviour is observed
# rather than asserted from the source text. The scanner is the real one — this
# gate tests the gate, not the scanner (that is tests/validate-okf-detectors.sh).
#
# BASH_ENV is unset for every child for the same reason validate-lint-gates.sh
# unsets it: in the devcontainer it points at /etc/bash_env, whose scripts reset
# $PATH and would let the environment outrank the sandbox.
#
# Pure bash, bash-3.2 clean and BSD-regex safe per CLAUDE.md § Runtime policy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GATE="$SCRIPT_DIR/validate-okf-bundle.sh"
RUN_ALL="$SCRIPT_DIR/run-all.sh"
SCANNER="$REPO_ROOT/plugins/review-audit/skills/check-okf-conformance/patterns.sh"

REAL_BASH="$(command -v bash)"

# The reserved "did not run" sentinel. Duplicated from the script under test on
# purpose: importing it would make the assertion tautological.
SKIP_SENTINEL=77

# Git's hook-exported environment, scrubbed so a pre-push run stays hermetic.
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "OKF bundle gate behaviour (advisory/blocking/skip) (#697)"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# --- sandbox plumbing -------------------------------------------------------

# make_bundle <varname> — a fresh non-git bundle dir. NOT a git checkout, so the
# gate takes its `find` fallback: that keeps each case's corpus exactly what it
# plants, with no dependency on what happens to be tracked in this worktree.
make_bundle() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/bundle.XXXXXX")"
    printf -v "$__out" '%s' "$dir"
}

# conformant <path> — a memory the scanner has nothing to say about.
conformant() {
    command cat >"$1" <<'EOF'
---
name: example
description: an example concept
type: reference
---

Body text.
EOF
}

# nonconformant <path> — frontmatter with no `type` key (okf-missing-type).
nonconformant() {
    command cat >"$1" <<'EOF'
---
name: example
description: an example concept
---

Body text.
EOF
}

# baseline_file <path> <content...> — write a baseline with the given entries.
write_baseline() {
    local path="$1"
    shift
    {
        command printf '# test baseline\n\n'
        local entry
        for entry in "$@"; do
            command printf '%s\n' "$entry"
        done
    } >"$path"
}

# run_gate <bundle> <baseline> [env assignments...] — run the real gate,
# capturing stdout+stderr in GATE_OUT and the status in GATE_RC.
GATE_OUT=""
GATE_RC=0
run_gate() {
    local bundle="$1" baseline="$2"
    shift 2
    GATE_RC=0
    GATE_OUT="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        --unset=BASH_ENV \
        OKF_BUNDLE_ROOT="$bundle" \
        OKF_BUNDLE_BASELINE="$baseline" \
        "$@" \
        "$REAL_BASH" "$GATE" 2>&1)" || GATE_RC=$?
}

# --- the skip sentinel ------------------------------------------------------

# FORCED absence, not skip-if-absent. A case that skipped itself when the
# scanner happened to be missing would only ever exercise the present arm — the
# self-skipping-test trap. $OKF_BUNDLE_SCANNER points at a path that cannot
# exist, so the 77 branch is taken deterministically on every host.
test_absent_scanner_exits_the_skip_sentinel() {
    local bundle baseline
    make_bundle bundle
    conformant "$bundle/a.md"
    baseline="$WORKDIR/skip.baseline"
    write_baseline "$baseline"

    run_gate "$bundle" "$baseline" OKF_BUNDLE_SCANNER="$WORKDIR/no-such-scanner.sh"

    assert_exit "$SKIP_SENTINEL" "$GATE_RC" \
        "an unreachable scanner exits 77, not 0"
    assert_contains "$GATE_OUT" "GATE DID NOT RUN" \
        "the skip message says the gate did not run"
}

# The sentinel is only worth anything if run_stage renders it as a skip. Slice
# run_stage out of run-all.sh and drive it with a canned 77, the same technique
# validate-lint-gates.sh uses — asserting run-all.sh's TEXT would not prove the
# rendering.
render_stage() {
    local code="$1"
    /usr/bin/env --unset=BASH_ENV "$REAL_BASH" -c '
        set -uo pipefail
        SKIP_EXIT_CODE=77
        rc=0
        eval "$(command sed -n "/^run_stage() {/,/^}/p" "$1")"
        eval "$(command sed -n "/^note_skip_in_step_summary() {/,/^}/p" "$1")"
        run_stage "Demo stage" sh -c "exit $2"
        command printf "SUITE_RC=%s\n" "$rc"
    ' _ "$RUN_ALL" "$code" 2>&1
}

test_run_stage_renders_the_gate_skip_as_skip() {
    local out
    out="$(render_stage "$SKIP_SENTINEL")"

    assert_contains "$out" "[SKIP] Demo stage" "a 77 stage renders as [SKIP]"
    assert_contains "$out" "did not run" "the [SKIP] line says it did not run"
    assert_not_contains "$out" "[ok] Demo stage" \
        "a 77 stage is NOT rendered as [ok] (the inert-gate bug)"
    assert_contains "$out" "SUITE_RC=0" "a skipped stage does not fail the suite"
}

# --- the bundle-absent path -------------------------------------------------

# AC3. This must NOT be the 77 path: a fresh clone of a consuming repo that
# carries no bundle has a working gate and an empty corpus, which is a pass. If
# these two ever collapse into one branch, a genuinely broken scanner starts
# reporting a clean bundle it never read.
test_absent_bundle_exits_zero_not_the_sentinel() {
    local baseline
    baseline="$WORKDIR/absent.baseline"
    write_baseline "$baseline"

    run_gate "$WORKDIR/no-such-bundle" "$baseline"

    assert_exit "0" "$GATE_RC" "an absent bundle passes"
    assert_contains "$GATE_OUT" "nothing to check" \
        "an absent bundle says nothing to check"
    assert_not_contains "$GATE_OUT" "GATE DID NOT RUN" \
        "an absent bundle is NOT reported as a skipped gate"
}

test_empty_bundle_exits_zero() {
    local bundle baseline
    make_bundle bundle
    baseline="$WORKDIR/empty.baseline"
    write_baseline "$baseline"

    run_gate "$bundle" "$baseline"

    assert_exit "0" "$GATE_RC" "a bundle with no markdown passes"
    assert_contains "$GATE_OUT" "nothing to check" \
        "an empty bundle says nothing to check"
}

# --- advisory mode ----------------------------------------------------------

# The central advisory property, and it needs BOTH halves. Exit 0 alone would be
# satisfied by a gate that scanned nothing; the printed finding alone would be
# satisfied by a blocking gate. Advisory means reported AND not fatal.
test_advisory_reports_findings_without_failing() {
    local bundle baseline
    make_bundle bundle
    nonconformant "$bundle/drifted.md"
    baseline="$WORKDIR/advisory.baseline"
    write_baseline "$baseline" "okf-missing-type 1"

    run_gate "$bundle" "$baseline"

    assert_exit "0" "$GATE_RC" "a finding at its baseline does not fail advisory mode"
    assert_contains "$GATE_OUT" "okf-missing-type" \
        "the finding is REPORTED even though it does not fail"
}

# The teeth. Without this, advisory is a no-op and the gate cannot prevent new
# drift while #631 is in flight.
test_advisory_fails_on_growth_above_baseline() {
    local bundle baseline
    make_bundle bundle
    nonconformant "$bundle/one.md"
    nonconformant "$bundle/two.md"
    baseline="$WORKDIR/growth.baseline"
    write_baseline "$baseline" "okf-missing-type 1"

    run_gate "$bundle" "$baseline"

    assert_exit "1" "$GATE_RC" "a count above its baseline fails advisory mode"
    assert_contains "$GATE_OUT" "2 > 1" "the failure names the count and the baseline"
}

# An unlisted category has an implicit baseline of 0. Without this a brand-new
# KIND of finding — the class most worth catching — slides in unnoticed while
# every listed category stays at its frozen count.
test_advisory_fails_on_an_unlisted_category() {
    local bundle baseline
    make_bundle bundle
    nonconformant "$bundle/drifted.md"
    baseline="$WORKDIR/unlisted.baseline"
    write_baseline "$baseline" "memory-stale 4"

    run_gate "$bundle" "$baseline"

    assert_exit "1" "$GATE_RC" "a category with no baseline entry fails"
    assert_contains "$GATE_OUT" "> 0 (baseline)" \
        "an unlisted category is treated as baseline 0"
}

# Shrinking must stay green — otherwise #631's progress would fail the gate it
# is supposed to satisfy.
test_advisory_passes_when_findings_drop() {
    local bundle baseline
    make_bundle bundle
    nonconformant "$bundle/one.md"
    baseline="$WORKDIR/shrink.baseline"
    write_baseline "$baseline" "okf-missing-type 9"

    run_gate "$bundle" "$baseline"

    assert_exit "0" "$GATE_RC" "a count below its baseline passes"
}

test_clean_bundle_passes_with_no_findings() {
    local bundle baseline
    make_bundle bundle
    conformant "$bundle/a.md"
    conformant "$bundle/b.md"
    baseline="$WORKDIR/clean.baseline"
    write_baseline "$baseline"

    run_gate "$bundle" "$baseline"

    assert_exit "0" "$GATE_RC" "a conformant bundle passes"
    assert_contains "$GATE_OUT" "0 findings" "a clean bundle reports zero findings"
}

# --- blocking mode ----------------------------------------------------------

# The flip is a TESTED switch, not a TODO (AC6). Same corpus, same baseline as
# test_advisory_reports_findings_without_failing — only the mode differs, so
# this pair IS the flip: it cannot pass unless the mode genuinely changes the
# verdict rather than merely changing a printed word.
test_blocking_fails_on_a_finding_at_its_baseline() {
    local bundle baseline
    make_bundle bundle
    nonconformant "$bundle/drifted.md"
    baseline="$WORKDIR/blocking.baseline"
    write_baseline "$baseline" "okf-missing-type 1"

    run_gate "$bundle" "$baseline" OKF_BUNDLE_GATE_MODE=blocking

    assert_exit "1" "$GATE_RC" \
        "blocking mode fails a finding that advisory mode grandfathers"
    assert_contains "$GATE_OUT" "blocking mode" "the failure names the mode"
}

test_blocking_passes_a_clean_bundle() {
    local bundle baseline
    make_bundle bundle
    conformant "$bundle/a.md"
    baseline="$WORKDIR/blocking-clean.baseline"
    write_baseline "$baseline"

    run_gate "$bundle" "$baseline" OKF_BUNDLE_GATE_MODE=blocking

    assert_exit "0" "$GATE_RC" "blocking mode passes a conformant bundle"
}

# A typo'd mode must not silently become advisory — that is how a blocking gate
# quietly stops blocking.
test_unknown_mode_fails_loud() {
    local bundle baseline
    make_bundle bundle
    conformant "$bundle/a.md"
    baseline="$WORKDIR/badmode.baseline"
    write_baseline "$baseline"

    run_gate "$bundle" "$baseline" OKF_BUNDLE_GATE_MODE=blockingg

    assert_exit "2" "$GATE_RC" "an unknown mode exits non-zero"
    assert_contains "$GATE_OUT" "must be advisory or blocking" \
        "the error names the valid modes"
    # A usage error is not a skip: 77 would render `[SKIP]` and hide a
    # misconfigured gate behind the rendering a missing tool uses.
    assert_true "[ \"$GATE_RC\" != \"$SKIP_SENTINEL\" ]" \
        "a usage error does not masquerade as the skip sentinel"
}

# --- the no-content rule (AC7) ----------------------------------------------

# The gate prints file, line and category — never the scanner's EVIDENCE column.
#
# THE FIXTURE MUST EXPRESS THE DIVERGENT CASE, and the first draft did not. It
# planted an `okf-missing-type` memory, whose evidence is the FIXED string
# "Concept frontmatter has no type key" — it quotes nothing from the file. So
# adding $4 back to the print statement changed no observable output and the
# mutation survived green: the case asserted the rule while being blind to it.
#
# `memory-stale` is the category that actually diverges. Its evidence quotes the
# memory's own `stale_check` sentence verbatim:
#
#   memory-stale  Memory is past its stale_after date (2020-01-01): <the text>
#
# so a canary planted in stale_check reaches stdout the instant the evidence
# column is printed. Verified by mutation: printing $4 now fails this case.
#
# $OKF_TODAY is injected rather than relying on the wall clock — a staleness
# fixture pinned to the real date stops testing what it claims once the date
# rolls past it, and the failure mode is a silent false pass.
#
# Asserted POSITIVELY as well as negatively: a bare `assert_not_contains` stays
# green if the gate stops printing findings at all, so the case also pins that
# the finding IS reported.
test_gate_prints_locations_but_never_memory_content() {
    local bundle baseline
    make_bundle bundle
    command cat >"$bundle/stale.md" <<'EOF'
---
name: stale-example
description: an example concept
type: reference
stale_after: 2020-01-01
stale_check: "PLANTEDCANARYSTRING re-derive this from the pinned table"
---

PLANTEDCANARYBODY should never reach a CI log either.
EOF
    baseline="$WORKDIR/content.baseline"
    write_baseline "$baseline" "memory-stale 1"

    run_gate "$bundle" "$baseline" OKF_TODAY=2026-09-06

    assert_contains "$GATE_OUT" "stale.md" "the finding's FILE is reported"
    assert_contains "$GATE_OUT" "memory-stale" "the finding's CATEGORY is reported"
    assert_not_contains "$GATE_OUT" "PLANTEDCANARYSTRING" \
        "the evidence column — which quotes stale_check — never reaches stdout"
    assert_not_contains "$GATE_OUT" "PLANTEDCANARYBODY" \
        "body content never reaches stdout"
}

# A scanner that FAILS is not a clean bundle. The scanner's own contract says a
# non-conformant bundle is exit 0 with findings, so a non-zero means the TOOL
# broke — an unresolvable version pin, an unreadable list. Reporting green there
# is the #538/#571 failure mode with the roles swapped: not a gate that skipped
# silently, but one that passed on a check it never performed.
#
# This is NOT the 77 path. 77 says "the scanner is absent, nothing ran"; this
# says "the scanner ran and broke", which must fail rather than skip — a skip
# would let a permanently broken scanner render `[SKIP]` forever.
test_a_failing_scanner_fails_the_gate() {
    local bundle baseline stub
    make_bundle bundle
    nonconformant "$bundle/drifted.md"
    baseline="$WORKDIR/scanfail.baseline"
    write_baseline "$baseline" "okf-missing-type 99"

    # Exits non-zero having emitted NO findings — the shape that would otherwise
    # read as "clean bundle" to a gate that only counted rows.
    stub="$WORKDIR/failing-scanner.sh"
    command cat >"$stub" <<'EOF'
#!/usr/bin/env bash
printf 'ERROR: malformed version pin\n' >&2
exit 1
EOF
    command chmod +x "$stub"

    run_gate "$bundle" "$baseline" OKF_BUNDLE_SCANNER="$stub"

    assert_exit "1" "$GATE_RC" "a failing scanner fails the gate"
    assert_true "[ \"$GATE_RC\" != \"$SKIP_SENTINEL\" ]" \
        "a failing scanner is NOT reported as a skip"
    assert_contains "$GATE_OUT" "scanner failed" \
        "the failure says the scanner failed"
    assert_contains "$GATE_OUT" "malformed version pin" \
        "the scanner's own stderr is surfaced for diagnosis"
    # The exit code alone does not pin this. Deleting the gate's failing
    # assertion leaves `exit 1` behind, so the status stays 1 while the gate's
    # own report says "Failed: 0" — a red gate that reports itself green to
    # anyone reading the summary rather than the status. Mutation-confirmed:
    # without this line that deletion survives.
    assert_contains "$GATE_OUT" "Failed:  1" \
        "the scanner failure is COUNTED in the gate's report, not just in its exit code"
}

# --- corpus scoping ---------------------------------------------------------

# GIT-TRACKED ONLY. `.claude/memory/tmp/` is gitignored per-session scratch —
# churny, disposable, and not reviewable repo content. Gating it would fail PRs
# over notes nobody ships.
#
# Every other case here builds a NON-git bundle (so the gate takes its `find`
# fallback and the corpus is exactly what the case plants), which means the git
# branch would otherwise be exercised only by the real repo bundle — where an
# untracked file happens not to exist, so the exclusion would be asserted by
# absence rather than tested. This case builds a real git repo and plants an
# untracked non-conformant file in it: without the `ls-files` scoping the file
# is scanned, the count exceeds the baseline, and the gate fails.
test_untracked_files_are_out_of_scope() {
    local bundle baseline
    make_bundle bundle
    command git -C "$bundle" init -q 2>/dev/null || {
        skip_test "git unavailable — cannot test tracked-only scoping"
        return 0
    }
    command git -C "$bundle" config user.email t@example.com
    command git -C "$bundle" config user.name Test

    nonconformant "$bundle/tracked.md"
    command git -C "$bundle" add tracked.md
    command git -C "$bundle" commit -qm "add tracked" 2>/dev/null

    # Untracked, and non-conformant: it would push okf-missing-type to 2.
    nonconformant "$bundle/untracked-scratch.md"

    baseline="$WORKDIR/tracked.baseline"
    write_baseline "$baseline" "okf-missing-type 1"

    run_gate "$bundle" "$baseline"

    assert_exit "0" "$GATE_RC" \
        "an untracked file does not push the count over the baseline"
    assert_contains "$GATE_OUT" "tracked.md" "the TRACKED file is scanned"
    assert_not_contains "$GATE_OUT" "untracked-scratch.md" \
        "the UNTRACKED file is out of scope"
}

# A bundle root holding a sed metacharacter must still be scanned. The first
# draft prefixed `ls-files` output with `sed "s|^|$BUNDLE_ROOT/|"`, splicing an
# operator-controlled value ($OKF_BUNDLE_ROOT is documented as overridable) into
# the replacement side, where `&` means "the matched text". With a `&` in the
# root every emitted path lost that character, the scanner skipped paths that
# did not exist, and the gate reported "1 files, 0 findings" and PASSED over a
# bundle holding a real violation — a gate reading green on a corpus it never
# checked, which is the exact failure this file exists to prevent.
#
# The fixture uses `&` because that is the character that SILENTLY corrupts: a
# `|` breaks the s-command loudly, so a test built on `|` alone would have been
# satisfied by a merely-different bug. The assertion is positive (the finding IS
# reported) rather than a bare exit-code check, since exit 0 was itself the
# symptom.
test_bundle_root_with_sed_metacharacter_is_still_scanned() {
    local parent bundle baseline
    parent="$(command mktemp -d "$WORKDIR/meta.XXXXXX")"
    bundle="$parent/a&b"
    command mkdir -p "$bundle"
    command git -C "$bundle" init -q 2>/dev/null || {
        skip_test "git unavailable — cannot test metacharacter bundle roots"
        return 0
    }
    command git -C "$bundle" config user.email t@example.com
    command git -C "$bundle" config user.name Test

    nonconformant "$bundle/drifted.md"
    command git -C "$bundle" add drifted.md
    command git -C "$bundle" commit -qm "add" 2>/dev/null

    baseline="$WORKDIR/meta.baseline"
    write_baseline "$baseline"

    run_gate "$bundle" "$baseline"

    # `(1 files,` not `1 files`: assert_contains is a plain substring test, and
    # the bare needle is satisfied by "21 files" / "31 files" too, so it could
    # not distinguish "counted once" from "counted eleven times". The paren and
    # comma come from the `(%s files, %s findings)` format string.
    assert_contains "$GATE_OUT" "(1 files," \
        "exactly one file under a metacharacter root is counted"
    assert_contains "$GATE_OUT" "okf-missing-type" \
        "the finding under a metacharacter root is REPORTED, not silently skipped"
    assert_exit "1" "$GATE_RC" \
        "the gate FAILS rather than passing over a corpus it could not read"
}

# A baseline entry may carry a trailing `# why` rationale — raising an entry is
# meant to be a reviewable decision, so the reason belongs next to it. That form
# is what makes the whitespace trim in baseline_for() load-bearing:
# `cat 218 # why` strips to `cat 218 ` and a naive `${rest##* }` yields the
# EMPTY string, so the entry parses as having no count and silently stops
# ratcheting — the annotated entry, the one someone deliberately justified, is
# exactly the one that would quietly go unenforced.
#
# Every other case here writes bare `category count` pairs (and the committed
# baseline carries none either), so without this fixture the trim loop has no
# coverage at all. Confirmed by mutation: neutering it makes this case report
# "no baseline entry" and fail.
test_baseline_entry_with_trailing_comment_still_parses() {
    local bundle baseline
    make_bundle bundle
    nonconformant "$bundle/drifted.md"

    baseline="$WORKDIR/annotated.baseline"
    {
        command printf '# annotated baseline\n\n'
        command printf 'okf-missing-type 1 # deliberate, tracked by #631\n'
    } >"$baseline"

    run_gate "$bundle" "$baseline"

    assert_exit "0" "$GATE_RC" \
        "an annotated entry still ratchets (its count is not lost to the comment)"
    assert_contains "$GATE_OUT" "(baseline 1)" \
        "the count is parsed from an entry carrying a trailing rationale"
    assert_not_contains "$GATE_OUT" "no baseline entry" \
        "an annotated entry is not read as unlisted"
}

# The SIBLING of the metacharacter case above, and the reason to grep for a
# class rather than patch the one instance a reviewer named. Fixing the sed
# splice addressed the corruption on the WRITING side of the pipe; plain
# `ls-files` corrupts on the READING side. It C-QUOTES any path holding a quote,
# a tab, or a non-ASCII byte, so a memory named `café.md` arrives as the literal
# 20-character string `"caf\303\251.md"` — quotes and octal escapes included.
# That names no file on disk, the scanner skips it, and the gate reports
# "1 files, 0 findings" and PASSES: byte-identical to the symptom the sed fix
# had just removed. `-z` plus `read -r -d ''` carries raw NUL-delimited paths,
# and NUL is the one byte a filename cannot contain.
#
# This repo's own bundle is all-ASCII, so nothing here would have caught it —
# but the gate ships to consuming repos whose bundles are not, and a silent pass
# there is the whole failure this file exists to prevent.
test_non_ascii_filename_is_still_scanned() {
    local bundle baseline
    make_bundle bundle
    command git -C "$bundle" init -q 2>/dev/null || {
        skip_test "git unavailable — cannot test non-ASCII filenames"
        return 0
    }
    command git -C "$bundle" config user.email t@example.com
    command git -C "$bundle" config user.name Test

    # ALL THREE ARMS of the C-quoting rule, not just the non-ASCII one. The
    # comment on the fix names a quote, a tab, AND a non-ASCII byte as triggers;
    # pinning only the third would leave the other two verified once by hand and
    # never again, so a later "simplification" back to a bare `read -r` could
    # reintroduce them with the suite still green. Written via printf so the
    # fixture does not depend on this file's own encoding surviving an editor
    # round-trip. A tab is included only when the filesystem accepts it.
    local fname n=0
    for fname in "$(command printf 'caf\303\251.md')" \
        "$(command printf 'quote\"me.md')" \
        "$(command printf 'tab\tme.md')"; do
        nonconformant "$bundle/$fname" 2>/dev/null || continue
        n=$((n + 1))
    done
    command git -C "$bundle" add -A
    command git -C "$bundle" commit -qm "add" 2>/dev/null

    baseline="$WORKDIR/nonascii.baseline"
    write_baseline "$baseline"

    run_gate "$bundle" "$baseline"

    assert_contains "$GATE_OUT" "($n files," \
        "every C-quoted path is counted, none dropped as an unresolvable name"
    assert_contains "$GATE_OUT" "okf-missing-type" \
        "the findings under C-quoted filenames are REPORTED, not silently skipped"
    assert_exit "1" "$GATE_RC" \
        "the gate FAILS rather than passing over files it could not resolve"
}

# The residual gap the -z fix does NOT close, pinned so it stays loud. $FILE_LIST
# is one path per line — the scanner's contract (patterns.sh's read loops and
# patterns.py's splitlines()), not this gate's choice — so a filename containing
# a literal LF survives `-z` and then splits into two useless lines. Before the
# guard this reported "2 files, 0 findings" and PASSED, the same silent symptom
# as the other two. Widening the contract to NUL would mean changing the sibling
# review-audit plugin, out of scope for #697; failing loud is the right answer
# either way, since "cannot represent this bundle" must never render as clean.
test_newline_in_filename_fails_loud_rather_than_silently_skipping() {
    local bundle baseline fname
    make_bundle bundle
    command git -C "$bundle" init -q 2>/dev/null || {
        skip_test "git unavailable — cannot test newline filenames"
        return 0
    }
    command git -C "$bundle" config user.email t@example.com
    command git -C "$bundle" config user.name Test

    fname="$(command printf 'new\nline.md')"
    nonconformant "$bundle/$fname" 2>/dev/null || {
        skip_test "filesystem rejects a newline in a filename"
        return 0
    }
    command git -C "$bundle" add -A
    command git -C "$bundle" commit -qm "add" 2>/dev/null

    baseline="$WORKDIR/newline.baseline"
    write_baseline "$baseline"

    run_gate "$bundle" "$baseline"

    assert_exit "1" "$GATE_RC" \
        "an unrepresentable path fails the gate rather than passing"
    assert_contains "$GATE_OUT" "contains a newline" \
        "the failure names the actual cause"
    assert_not_contains "$GATE_OUT" "(2 files," \
        "the corrupted two-line split is never reported as a real count"
}

# An EXPLICITLY EMPTY $OKF_BUNDLE_ROOT means "no bundle configured — scan
# nothing", and is how a consuming repo opts out. The scanner resolves its root
# with `+set`/bare-`-` precisely to preserve that, so the gate must too: with
# `:-` an empty override reads as unset and falls back to the real bundle, so
# the gate would scan .claude/memory while the scanner it drives scanned
# nothing. Mutation-confirmed — reverting to `:-` turns this case red, and
# nothing else in the suite noticed.
test_explicitly_empty_bundle_root_scans_nothing() {
    local baseline
    baseline="$WORKDIR/emptyroot.baseline"
    write_baseline "$baseline"

    # run_gate always passes OKF_BUNDLE_ROOT, so an empty value here is exactly
    # the `set but empty` case (not an absent variable).
    run_gate "" "$baseline"

    assert_exit "0" "$GATE_RC" "an explicitly empty bundle root is not an error"
    assert_contains "$GATE_OUT" "nothing to check" \
        "an explicitly empty bundle root scans nothing"
    # THE DIVERGENT SIGNAL, chosen by measuring both spellings rather than
    # guessing. Under `:-` the gate does not error and does not print a
    # category — it prints `Bundle: <repo>/.claude/memory (225 files, ...)`,
    # having silently scanned the real bundle. So the assertion that separates
    # the two is the absence of a Bundle: line at all; a `not_contains` on a
    # category name passes under BOTH spellings and would have been a
    # tautology.
    assert_not_contains "$GATE_OUT" "Bundle:" \
        "it does NOT silently fall back to scanning the repo's real bundle"
}

# --- --regen ----------------------------------------------------------------

test_regen_writes_the_observed_counts() {
    local bundle baseline out rc=0
    make_bundle bundle
    nonconformant "$bundle/one.md"
    nonconformant "$bundle/two.md"
    baseline="$WORKDIR/regen.baseline"
    write_baseline "$baseline" "okf-missing-type 99"

    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        --unset=BASH_ENV \
        OKF_BUNDLE_ROOT="$bundle" \
        OKF_BUNDLE_BASELINE="$baseline" \
        "$REAL_BASH" "$GATE" --regen 2>&1)" || rc=$?

    assert_exit "0" "$rc" "--regen succeeds"
    assert_contains "$out" "Baseline regenerated" "--regen says what it did"
    assert_file_contains "$baseline" "okf-missing-type 2" \
        "--regen TIGHTENS the entry to the observed count (99 -> 2)"

    # And the regenerated baseline is immediately satisfiable — a --regen that
    # wrote counts the gate then rejects would be useless.
    run_gate "$bundle" "$baseline"
    assert_exit "0" "$GATE_RC" "the regenerated baseline passes"
}

test_unknown_argument_is_rejected() {
    local bundle baseline out rc=0
    make_bundle bundle
    conformant "$bundle/a.md"
    baseline="$WORKDIR/arg.baseline"
    write_baseline "$baseline"

    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        --unset=BASH_ENV \
        OKF_BUNDLE_ROOT="$bundle" \
        OKF_BUNDLE_BASELINE="$baseline" \
        "$REAL_BASH" "$GATE" --wat 2>&1)" || rc=$?

    assert_exit "2" "$rc" "an unknown argument exits non-zero"
    assert_contains "$out" "unknown argument" "the error names the problem"
}

# --- wiring -----------------------------------------------------------------

# AC1. Both halves: run-all.sh must actually dispatch the gate, and the numbered
# header block must document it. A dispatch with no header entry drifts from the
# documented suite; a header entry with no dispatch is a gate that never runs.
test_run_all_dispatches_the_gate() {
    assert_file_contains "$RUN_ALL" "validate-okf-bundle.sh" \
        "run-all.sh dispatches the OKF bundle gate"
    assert_file_contains "$RUN_ALL" "OKF bundle conformance" \
        "run-all.sh's header block documents the gate"
}

# The scanner this gate drives must exist at the path the gate defaults to —
# otherwise every run of the real suite takes the 77 branch and reports [SKIP]
# forever, which is precisely the inert-gate outcome the sentinel exists to make
# visible rather than to normalise.
test_default_scanner_path_resolves() {
    assert_file_exists "$SCANNER" \
        "the check-okf-conformance scanner exists at the gate's default path"
}

# The committed baseline must match the real bundle in BOTH directions. Drifting
# LOW turns the suite red for everyone; drifting HIGH loosens the ratchet so new
# findings slip in under an inflated allowance — and the second is the dangerous
# one, because it is silent.
#
# THE EXIT CODE ONLY CATCHES THE FIRST. That was this case's original bug: it
# asserted `rc == 0 || rc == 77` under a comment claiming it "catches both",
# while hand-editing the baseline to `okf-missing-type 500` left the gate at
# exit 0 and this case green. A comment asserting what the code does not check
# is worse than no check, because it stops anyone else from adding one.
#
# So the counts are compared for EQUALITY, parsed from the gate's own
# `category N (baseline M)` report: every category must sit exactly at its
# entry, neither under nor over.
test_committed_baseline_matches_the_real_bundle() {
    local out rc=0
    out="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        --unset=BASH_ENV \
        "$REAL_BASH" "$GATE" 2>&1)" || rc=$?

    if [ "$rc" -ne 0 ] && [ "$rc" -ne "$SKIP_SENTINEL" ]; then
        command printf '%s\n' "$out"
    fi
    assert_true "[ \"$rc\" -eq 0 ] || [ \"$rc\" -eq $SKIP_SENTINEL ]" \
        "the committed baseline is not TIGHTER than this repo's own bundle"

    # A skipped gate produced no report to parse; the sentinel case is covered
    # by its own test.
    if [ "$rc" -eq "$SKIP_SENTINEL" ]; then
        return 0
    fi

    # Rows look like:  okf-missing-type   220  (baseline 220)
    # A row reading `(no baseline entry)` or a mismatched pair is drift.
    local drift
    drift="$(command printf '%s\n' "$out" | command awk '
        /\(baseline [0-9]+\)$/ {
            count = $2
            gsub(/[^0-9]/, "", $NF)
            if (count != $NF) print "  " $1 ": observed " count " but baseline " $NF
            seen++
        }
        /\(no baseline entry\)$/ { print "  " $1 ": observed " $2 " with NO baseline entry"; seen++ }
        END { if (seen == 0) print "  no category rows parsed — the report format changed" }
    ')"

    assert_equals "" "$drift" \
        "every category sits EXACTLY at its baseline entry (neither tighter nor inflated)"
}

run_test test_absent_scanner_exits_the_skip_sentinel \
    "an unreachable scanner exits 77, not 0"
run_test test_run_stage_renders_the_gate_skip_as_skip \
    "run_stage renders the gate's 77 as [SKIP] without failing the suite"
run_test test_absent_bundle_exits_zero_not_the_sentinel \
    "an absent bundle exits 0 'nothing to check', not 77 (AC3)"
run_test test_empty_bundle_exits_zero \
    "a bundle with no markdown exits 0"
run_test test_advisory_reports_findings_without_failing \
    "advisory mode reports findings AND exits 0 (AC5)"
run_test test_advisory_fails_on_growth_above_baseline \
    "advisory mode fails on growth above the baseline"
run_test test_advisory_fails_on_an_unlisted_category \
    "an unlisted finding category is treated as baseline 0"
run_test test_advisory_passes_when_findings_drop \
    "a count below its baseline passes (#631 progress stays green)"
run_test test_clean_bundle_passes_with_no_findings \
    "a conformant bundle passes with zero findings"
run_test test_blocking_fails_on_a_finding_at_its_baseline \
    "blocking mode fails what advisory grandfathers — the flip (AC6)"
run_test test_blocking_passes_a_clean_bundle \
    "blocking mode passes a conformant bundle"
run_test test_unknown_mode_fails_loud \
    "an unknown gate mode fails loud rather than defaulting to advisory"
run_test test_gate_prints_locations_but_never_memory_content \
    "the gate prints file/line/category and never memory content (AC7)"
run_test test_a_failing_scanner_fails_the_gate \
    "a scanner that fails is not reported as a clean bundle"
run_test test_untracked_files_are_out_of_scope \
    "gitignored/untracked scratch is out of scope (git-tracked corpus)"
run_test test_bundle_root_with_sed_metacharacter_is_still_scanned \
    "a bundle root containing \`&\` is still scanned, not silently skipped"
run_test test_baseline_entry_with_trailing_comment_still_parses \
    "a baseline entry with a trailing # rationale still ratchets"
run_test test_non_ascii_filename_is_still_scanned \
    "a non-ASCII bundle filename is still scanned (ls-files -z, not C-quoted)"
run_test test_newline_in_filename_fails_loud_rather_than_silently_skipping \
    "a newline in a filename fails loud, never a silent partial scan"
run_test test_explicitly_empty_bundle_root_scans_nothing \
    "an explicitly empty OKF_BUNDLE_ROOT scans nothing (opt-out preserved)"
run_test test_regen_writes_the_observed_counts \
    "--regen tightens the baseline to the observed counts"
run_test test_unknown_argument_is_rejected \
    "an unknown argument is rejected"
run_test test_run_all_dispatches_the_gate \
    "run-all.sh dispatches the gate and documents it in the header (AC1)"
run_test test_default_scanner_path_resolves \
    "the gate's default scanner path resolves"
run_test test_committed_baseline_matches_the_real_bundle \
    "the committed baseline satisfies this repo's own bundle"

generate_report
