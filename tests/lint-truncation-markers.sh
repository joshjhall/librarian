#!/usr/bin/env bash
# Truncation-marker gate (#786).
#
# A clamp that cuts silently is worse than no clamp, because the reader reasons
# confidently over a partial value. Evidence is captured from a matched source
# line and clamped to a fixed width; before #786 that clamp emitted nothing, so
#
#   Possible hardcoded credential (password): password = "hunter2_aaaa…aaa
#
# and a line that genuinely ended there were the same bytes. A reviewer cannot
# tell whether the match continued, and the repo has been bitten by exactly this
# shape before (the #267 manifest round-trip truncation).
#
# The repo already had the right pattern in one place and the wrong one in
# another. ship-issue/workflow.js clamps LOUDLY -- PRESCAN_MAX discloses "N
# further candidate(s) were omitted for size", DIGEST_MAX_CHARS discloses "AND
# IT WAS TRUNCATED for size" -- and its own rationale comment already stated the
# thesis: a silently trimmed list reads as a complete one. `truncate_chars` was
# the remaining silent clamp, in 15 bash copies and 14 python peers.
#
# This gate pins three things, and the third is the one most likely to be
# eroded by a future well-meaning "cap everything" change:
#
#   1. Every truncate_chars copy (both runtimes) emits a marker when it cuts.
#   2. The marker is CONDITIONAL -- absent when nothing was cut. A clamp that
#      always appends an ellipsis is as uninformative as one that never does,
#      and it would also break AC6 (a legitimately large read still gets it,
#      with the marker absent).
#   3. The review diff stays BYTE-FAITHFUL and is never clamped (#267). Diffs
#      handed to reviewers are exact by design; a ceiling applied there would
#      corrupt the artifact review depends on. The behavioral pin lives in
#      tests/workflow-helpers/ship-issue/04-tdz-and-diff.mjs (the
#      *-BYTE-FAITHFUL-* sentinel); this gate pins that the EXEMPTION is
#      deliberate, so a later sweep cannot quietly fold the diff into the cap.
#
# Like the defect in #902, the failure here is SILENT: a dropped marker changes
# no exit code and emits no error. The scan simply goes back to reporting cut
# evidence as if it were whole.
#
# Pure bash + coreutils for the structural checks; the behavioral check executes
# each bash helper, and the python check needs python3 only if one is present
# (its absence skips that one case, never the gate).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGINS_DIR="$REPO_ROOT/plugins"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Truncation markers (#786)"

# Vacuity guards, deliberately below the real counts (15 bash / 14 python at the
# time of writing) so adding a scanner does not fail this gate, while a
# discovery regression that collapses the set does. Without them a glob typo
# yields "0 files checked, 0 failures" -- a green run proving nothing, which is
# the very shape of bug being gated.
MIN_EXPECTED_SH=10
MIN_EXPECTED_PY=10

# Discover by the DEFINITION, never by filename -- the same rule (and the same
# reason) as lint-evidence-cr-strip.sh: pre-review-gates.sh carries the helper
# but is not named patterns.sh, so a filename glob would miss the one file the
# bash<->python behavioral corpus also cannot reach.
list_truncate_chars_files() {
    command grep -rl '^truncate_chars() {' "$PLUGINS_DIR" \
        --include='*.sh' 2>/dev/null | command sort
}

list_py_truncate_files() {
    command grep -rl '^def truncate_chars' "$PLUGINS_DIR" \
        --include='*.py' 2>/dev/null | command sort
}

# --- The marker is PRESENT in every copy ------------------------------------

test_marker_present_bash() {
    local script count=0
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        count=$((count + 1))
        assert_true \
            "command grep -qF '…' '$script'" \
            "${script#"$PLUGINS_DIR"/}: truncate_chars carries a truncation marker"
    done < <(list_truncate_chars_files)

    assert_true "[ $count -ge $MIN_EXPECTED_SH ]" \
        "discovery found $count bash truncate_chars copies (floor $MIN_EXPECTED_SH) — a lower count means discovery broke, not that the repo shrank"
}

test_marker_present_python() {
    local script count=0 ret marker_found
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        count=$((count + 1))

        # Anchor on the RETURN STATEMENT, not a function range. A range that
        # overruns into the rest of the module can be satisfied by an unrelated
        # `...` in some later comment (measured: check-lifecycle/patterns.py:259
        # has one), so it would fail OPEN -- passing a file whose helper had
        # been reverted to a silent slice.
        #
        # Captured into a variable rather than piped into `grep -q`: `-q` exits
        # on the first match and SIGPIPEs its writer, which under pipefail
        # inverts the verdict (#928). The marker itself is then matched with a
        # `case` rather than a second grep, because assert_true evals its
        # command and that eats the backslash layer `\\u2026` needs.
        #
        # Two signatures exist and both are correct: most ports slice against a
        # module-level `EVIDENCE_CAP`, while loop-make-it-tested takes the cap
        # as an argument because its two call sites cap at 60 to match its
        # patterns.sh. Match `- 1]` -- the "leave room for the marker" slice
        # common to both -- rather than either constant's name.
        ret="$(command grep -E '^ *return s\[: *[A-Za-z_]+ - 1\]' "$script" || true)"

        assert_true "[ -n '$ret' ]" \
            "${script#"$PLUGINS_DIR"/}: truncate_chars slices one short of its cap to leave room for a marker"

        # Accept either spelling: the python sources write the escape
        # `\u2026`, but a literal ellipsis byte is equally valid.
        case $ret in
            *'\u2026'* | *'…'*) marker_found=yes ;;
            *) marker_found=no ;;
        esac
        assert_equals yes "$marker_found" \
            "${script#"$PLUGINS_DIR"/}: truncate_chars appends a truncation marker"
    done < <(list_py_truncate_files)

    assert_true "[ $count -ge $MIN_EXPECTED_PY ]" \
        "discovery found $count python truncate_chars peers (floor $MIN_EXPECTED_PY) — a lower count means discovery broke, not that the repo shrank"
}

# --- ...and it is CONDITIONAL, in the shell that will run it ----------------
#
# The greps above prove the marker is in the source. This EXECUTES each helper,
# so a copy that greps as marked but appends unconditionally -- or never -- still
# fails. Three cases, and the middle one is AC6: an uncut value must come back
# untouched, or every full read would look truncated.

test_marker_is_conditional_bash() {
    local tmp
    tmp="$(command mktemp -d 2>/dev/null)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    local script count=0
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        count=$((count + 1))

        # Slice out the locale probe plus the helper it configures, and source
        # THAT -- not the whole scanner, which would run a scan on no arguments.
        command sed -n '/^_PRESCAN_UTF8_LOCALE=""/,/^}/p' "$script" >"$tmp/helper.sh"

        local out
        out="$(
            # shellcheck disable=SC1091
            . "$tmp/helper.sh"
            # over-cap (cuts) | exactly-at-cap (must NOT) | short (must NOT)
            command printf '[%s][%s][%s]' \
                "$(truncate_chars 8 'abcdefghij')" \
                "$(truncate_chars 8 'abcdefgh')" \
                "$(truncate_chars 8 'abc')"
        )"

        # The cut case keeps the cap's width: 7 sliced characters plus the
        # ellipsis, because the marker REPLACES the last character rather than
        # extending past the cap. A caller that budgeted 8 still gets 8.
        assert_equals '[abcdefg…][abcdefgh][abc]' "$out" \
            "${script#"$PLUGINS_DIR"/}: the marker appears only when the value was actually cut"
    done < <(list_truncate_chars_files)

    assert_true "[ $count -ge $MIN_EXPECTED_SH ]" \
        "behavior sweep covered $count truncate_chars copies (floor $MIN_EXPECTED_SH)"
}

test_marker_is_conditional_python() {
    command -v python3 >/dev/null 2>&1 || {
        skip_test "python3 unavailable"
        return 0
    }

    local script count=0 out
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        count=$((count + 1))

        # Import the module by path and exercise its helper against its OWN cap.
        # Two signatures exist: most ports read a module-level EVIDENCE_CAP,
        # while loop-make-it-tested takes the cap as a second argument (its call
        # sites use 60 to match its patterns.sh). inspect the arity rather than
        # assuming one, so a port using either shape is really exercised instead
        # of erroring into a FAIL that looks like a missing marker.
        #
        # The helper reports its own verdict rather than the raw values, so the
        # assertion below is one fixed string for every port regardless of cap.
        out="$(python3 -c '
import importlib.util, inspect, sys

spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

fn = m.truncate_chars
if len(inspect.signature(fn).parameters) == 2:
    cap = 60
    call = lambda s: fn(s, cap)
else:
    cap = m.EVIDENCE_CAP
    call = fn

cut, exact, short = call("a" * (cap + 1)), call("a" * cap), call("ab")
print("cut_marked=%s width_held=%s exact_clean=%s short_clean=%s" % (
    cut.endswith("\u2026"),
    len(cut) == cap,
    "\u2026" not in exact,
    "\u2026" not in short,
))
' "$script" 2>&1)"

        assert_equals \
            "cut_marked=True width_held=True exact_clean=True short_clean=True" "$out" \
            "${script#"$PLUGINS_DIR"/}: the marker appears only when the value was actually cut"
    done < <(list_py_truncate_files)

    assert_true "[ $count -ge $MIN_EXPECTED_PY ]" \
        "behavior sweep covered $count python truncate_chars peers (floor $MIN_EXPECTED_PY)"
}

# --- The review diff is EXEMPT and stays byte-faithful (#267) ---------------
#
# The exemption is the boundary on everything above: fidelity is the point for a
# reviewer's diff, so no ceiling may reach it. This is a source-structure check,
# not a behavioral one -- the behavior is pinned by the *-BYTE-FAITHFUL-*
# sentinel in tests/workflow-helpers/ship-issue/04-tdz-and-diff.mjs, and
# duplicating it here would create two tables that must agree.

test_review_diff_is_not_clamped() {
    local wf="$PLUGINS_DIR/workflow/skills/ship-issue/workflow.js"

    assert_true "[ -f '$wf' ]" \
        "ship-issue/workflow.js exists (the exemption has something to be about)"
    [ -f "$wf" ] || return 0

    # The diff is ingested raw -- a type guard and an empty-string default, but
    # no width. Matched as a regex rather than a fixed literal so a whitespace
    # or guard change does not read as a clamp; what must not appear is a
    # ceiling, which the next assertion covers.
    assert_true \
        "command grep -qE '^const scopeDiff = args && typeof args\\.diff' '$wf'" \
        "the review diff is ingested unclamped (a type guard, not a width)"

    # ...and nothing clamps it on the way into the prompt.
    assert_true \
        "! command grep -nE 'scopeDiff[[:space:]]*\\.[[:space:]]*slice|scopeDiff\\.substring' '$wf' >/dev/null" \
        "no ceiling is applied to the review diff (#267 byte-faithful exemption)"

    # The behavioral pin must still exist; if it is renamed or deleted, the
    # comment above becomes a lie and this gate says so.
    local sentinel="$REPO_ROOT/tests/workflow-helpers/ship-issue/04-tdz-and-diff.mjs"
    assert_true "[ -f '$sentinel' ] && command grep -qF 'BYTE-FAITHFUL' '$sentinel'" \
        "the behavioral byte-faithful sentinel this exemption defers to still exists"
}

# --- TEETH: the checks reject a deliberately-broken copy --------------------
#
# Each assertion above must be shown to FIRE, or a discovery/spelling regression
# would render this gate inert while still reporting green -- the #538/#571
# silence-reads-as-a-pass shape.

test_gate_rejects_a_broken_copy() {
    local tmp
    tmp="$(command mktemp -d 2>/dev/null)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    local out

    # (a) A SILENT clamp -- the pre-#786 body. Must not produce the marker.
    command cat >"$tmp/silent.sh" <<'EOF'
_PRESCAN_UTF8_LOCALE=""
truncate_chars() {
    local n="$1" s="$2"
    s=${s%$'\r'}
    command printf "%.${n}s" "$s"
}
EOF
    out="$(
        # shellcheck disable=SC1091
        . "$tmp/silent.sh"
        truncate_chars 8 'abcdefghij'
    )"
    assert_true "[ '$out' != 'abcdefg…' ]" \
        "TEETH: the behavior check REJECTS a silently-truncating copy"

    # (b) An UNCONDITIONAL marker -- appends even when nothing was cut. This is
    # the failure the conditional case exists to catch, and it is the one a
    # careless fix actually produces.
    command cat >"$tmp/always.sh" <<'EOF'
_PRESCAN_UTF8_LOCALE=""
truncate_chars() {
    local n="$1" s="$2"
    s=${s%$'\r'}
    command printf "%.$((n - 1))s…" "$s"
}
EOF
    out="$(
        # shellcheck disable=SC1091
        . "$tmp/always.sh"
        truncate_chars 8 'abc'
    )"
    assert_true "[ '$out' != 'abc' ]" \
        "TEETH: the conditional check REJECTS a copy that always appends the marker"

    # (c) ...and a correct copy PASSES both, so (a) and (b) fail for the stated
    # reason rather than because the harness is broken.
    command cat >"$tmp/right.sh" <<'EOF'
_PRESCAN_UTF8_LOCALE=""
truncate_chars() {
    local n="$1" s="$2"
    s=${s%$'\r'}
    if [ "${#s}" -gt "$n" ]; then
        command printf "%.$((n - 1))s…" "$s"
    else
        command printf '%s' "$s"
    fi
}
EOF
    out="$(
        # shellcheck disable=SC1091
        . "$tmp/right.sh"
        command printf '[%s][%s]' "$(truncate_chars 8 'abcdefghij')" "$(truncate_chars 8 'abc')"
    )"
    assert_equals '[abcdefg…][abc]' "$out" \
        "TEETH control: the same checks PASS a correctly-marking copy"

    # (d) The byte-faithful check must fire on a clamped diff, or the exemption
    # is asserted rather than verified.
    command cat >"$tmp/clamped.js" <<'EOF'
const scopeDiff = args.diff.slice(0, 4000)
EOF
    assert_true \
        "command grep -nE 'scopeDiff[[:space:]]*\\.[[:space:]]*slice|args\\.diff\\.slice' '$tmp/clamped.js' >/dev/null" \
        "TEETH: the byte-faithful check REJECTS a clamped review diff"
}

# --- Run All Tests ----------------------------------------------------------

run_test test_marker_present_bash "Every bash truncate_chars copy carries a truncation marker"
run_test test_marker_present_python "Every python truncate_chars peer carries a truncation marker"
run_test test_marker_is_conditional_bash "Each bash copy, executed, marks only what it actually cut"
run_test test_marker_is_conditional_python "Each python peer, executed, marks only what it actually cut"
run_test test_review_diff_is_not_clamped "The review diff stays byte-faithful and unclamped (#267 exemption)"
run_test test_gate_rejects_a_broken_copy "TEETH: each check rejects a deliberately-broken copy (and passes a fixed one)"

generate_report
