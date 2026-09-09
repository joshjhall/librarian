#!/usr/bin/env bash
# Evidence-field CR-strip gate (#902).
#
# Every pre-scan ships two implementations under a byte-identical-TSV contract
# (file\tline\tcategory\tevidence\tcertainty). The EVIDENCE field is captured
# from the matched source line. Python reads in text mode, which drops a
# trailing `\r`; the bash fallback captures via `grep`, which keeps it. So a
# CRLF-terminated matched line emitted rows differing by one byte:
#
#   py: ... password = "realsecret123"\tHIGH\n
#   sh: ... password = "realsecret123"\r\tHIGH\n
#
# #902 fixed it in `truncate_chars` -- the helper #17 introduced as the single
# bash<->python evidence-equivalence point, through which every detector's
# evidence passes. The strip normalizes bash toward python because python is the
# primary impl and its CR-free evidence is what validate-python-ports.sh pins.
#
# The BEHAVIOR is pinned in tests/validate-python-ports.sh, whose corpus now
# carries a CRLF-content fixture that flows through every port's parity test.
# This gate is the structural backstop that fixture cannot be, for two reasons:
#
#   - The helper SPREADS BY COPY. It is byte-identical in 15 files across three
#     independently-installed plugins, because a new scanner is written by
#     copying a neighbour. Copy a pre-#902 neighbour -- or a post-#902 one whose
#     strip someone dropped in a refactor -- and the divergence returns in a file
#     no fixture reaches.
#   - pre-review-gates.sh has NO .py sibling at all. It carries the same helper
#     and the same defect, but validate-python-ports.sh drives parity by pairing
#     a .py with its .sh, so that file is structurally unreachable from the
#     behavioral corpus. Only a source-reading gate covers it.
#
# The defect is also SILENT: a dropped strip changes no exit code and emits no
# error. The scan simply goes back to reporting a CR that the other runtime does
# not, and nothing fails until a CRLF file reaches a scanner.
#
# Pure bash + coreutils. No network, no python (the checks are literal greps).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGINS_DIR="$REPO_ROOT/plugins"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Evidence-field CR strip (#902)"

# The floor is a VACUITY GUARD, not a census. It sits deliberately below the
# real count (15 at the time of writing) so that adding a scanner does not fail
# this gate, while a discovery regression that collapses the set to a handful
# does. Without it a glob typo yields "0 files checked, 0 failures" -- a green
# run that proves nothing, which is the shape of bug being gated.
MIN_EXPECTED=10

# list_truncate_chars_files — every file defining the shared helper, found by
# the DEFINITION rather than by filename. Filename discovery would miss
# pre-review-gates.sh (not named patterns.sh) -- and that is precisely the file
# the behavioral corpus cannot reach, so a filename glob would leave the one
# structurally-uncovered file uncovered here too.
list_truncate_chars_files() {
    command grep -rl '^truncate_chars() {' "$PLUGINS_DIR" \
        --include='*.sh' 2>/dev/null | command sort
}

# --- The strip is PRESENT in every copy -------------------------------------

test_strip_present() {
    local script count=0
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        count=$((count + 1))
        assert_true \
            "command grep -qF 's=\${s%\$'\"'\"'\\r'\"'\"'}' '$script'" \
            "${script#"$PLUGINS_DIR"/}: truncate_chars strips a trailing CR"
    done < <(list_truncate_chars_files)

    assert_true "[ $count -ge $MIN_EXPECTED ]" \
        "discovery found $count truncate_chars copies (floor $MIN_EXPECTED) — a lower count means discovery broke, not that the repo shrank"
}

# --- ...and strips BEFORE the slice, not after ------------------------------
#
# This pins the CONVENTION, and the honest reason is narrower than it looks.
# For the case #902 is about -- a single TRAILING CR -- the two orders are
# equivalent: measured across both slice spellings and n on either side of the
# string length, strip-then-slice and slice-then-strip agree everywhere. So this
# test is NOT protecting an observable behavior for CRLF input, and claiming
# otherwise would be a comment asserting a property the code does not have.
#
# What it does buy is that all 15 copies stay literally identical, which is what
# makes test_strip_present's single grep a sound check on every one of them. The
# orders DO diverge on an embedded or doubled CR (`a\rb`, `ab\r\r`) -- but such
# a string only reaches evidence via the lone-CR line-splitting divergence
# tracked separately in #980, and there the runtimes already disagree about line
# numbering, so the slice order is not what would save it.

test_strip_precedes_the_slice() {
    local script count=0
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        count=$((count + 1))

        local body strip_at slice_at
        body="$(command sed -n '/^truncate_chars() {/,/^}/p' "$script")"
        strip_at="$(command printf '%s\n' "$body" | command grep -nF 's=${s%' | command head -1 | command cut -d: -f1)"
        slice_at="$(command printf '%s\n' "$body" | command grep -nE '\$\{s:0:|printf "%\.' | command head -1 | command cut -d: -f1)"

        assert_true "[ -n '$strip_at' ] && [ -n '$slice_at' ] && [ '$strip_at' -lt '$slice_at' ]" \
            "${script#"$PLUGINS_DIR"/}: the CR strip runs BEFORE the character slice"
    done < <(list_truncate_chars_files)

    assert_true "[ $count -ge $MIN_EXPECTED ]" \
        "order sweep covered $count truncate_chars copies (floor $MIN_EXPECTED)"
}

# --- The strip actually behaves, in the shell that will run it --------------
#
# The two tests above read source. This one EXECUTES the helper as each file
# defines it, so a spelling that greps as present but does not strip (a typo
# inside the parameter expansion, say) still fails. It also pins the property
# the greps only approximate: a CRLF line and its LF twin produce identical
# evidence, and an ordinary line is left alone.

test_strip_is_behaviorally_correct() {
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
        # The range ends at the first column-0 `}`, which is truncate_chars's
        # own closing brace (the probe loop above it closes with `done`).
        command sed -n '/^_PRESCAN_UTF8_LOCALE=""/,/^}/p' "$script" >"$tmp/helper.sh"

        local out
        out="$(
            # shellcheck disable=SC1091
            . "$tmp/helper.sh"
            # Piped through `cat -v` so a stray CR renders as `^M` in the
            # failure diff. Without it the expected and actual strings print
            # IDENTICALLY on a real failure -- the offending byte is invisible,
            # and the report reads as a harness bug rather than a missing strip.
            command printf '[%s][%s][%s]' \
                "$(truncate_chars 80 "$(command printf 'password = "x"\r')")" \
                "$(truncate_chars 80 'password = "x"')" \
                "$(truncate_chars 4 "$(command printf 'abcdefgh\r')")" |
                command cat -v
        )"

        assert_equals '[password = "x"][password = "x"][abcd]' "$out" \
            "${script#"$PLUGINS_DIR"/}: CRLF and LF evidence are identical, and the slice is unaffected"
    done < <(list_truncate_chars_files)

    assert_true "[ $count -ge $MIN_EXPECTED ]" \
        "behavior sweep covered $count truncate_chars copies (floor $MIN_EXPECTED)"
}

# --- TEETH: the three checks above must FAIL on a broken copy ---------------
#
# All three assertions run against the real, already-fixed copies, so they only
# ever exercise the happy path. A grep pattern that matched nothing, or a sed
# range that extracted nothing, would pass every one of them while detecting
# nothing at all -- the inert-gate shape (#538/#571) this gate exists to prevent,
# reintroduced one level up in the gate itself.
#
# So each predicate is re-run here against synthetic broken bodies and REQUIRED
# to reject them. The predicates are duplicated rather than factored out on
# purpose: a helper shared with the tests above would let one edit silently
# change both the checker and its own teeth, and the whole point is that these
# two agree only when the predicate is genuinely right.

test_gate_rejects_a_broken_copy() {
    local tmp
    tmp="$(command mktemp -d 2>/dev/null)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    # (a) strip absent entirely -- the #902 defect, unfixed.
    command cat >"$tmp/absent.sh" <<'EOF'
truncate_chars() {
    local n="$1" s="$2"
    printf '%s' "${s:0:$n}"
}
EOF
    # The pattern is spelled EXACTLY as test_strip_present spells it -- `\\r`, not
    # `\r`. Inside these double quotes a single backslash is consumed by the shell,
    # so `\r` would search for a literal `r`, match nothing, and let this negated
    # assertion pass VACUOUSLY -- asserting nothing while looking correct.
    # SC1012 caught it; the control below is what keeps it caught.
    assert_true "! command grep -qF 's=\${s%\$'\"'\"'\\r'\"'\"'}' '$tmp/absent.sh'" \
        "TEETH: the presence grep REJECTS a copy with no CR strip"

    # CONTROL for the line above: the SAME pattern must FIND the strip in a
    # correct body. Without this, any pattern that matches nothing -- a typo, a
    # mis-escaped backslash -- satisfies the negation and the check is inert.
    command cat >"$tmp/present.sh" <<'EOF'
truncate_chars() {
    local n="$1" s="$2"
    s=${s%$'\r'}
    printf '%s' "${s:0:$n}"
}
EOF
    assert_true "command grep -qF 's=\${s%\$'\"'\"'\\r'\"'\"'}' '$tmp/present.sh'" \
        "TEETH control: the same pattern FINDS the strip in a correct copy"

    # (b) present but AFTER the slice -- passes a naive presence check, so this
    #     is what the order predicate is for.
    # The strip is spelled EXACTLY as the real copies spell it (`s=${s%...}`), so
    # the presence grep DOES find it -- otherwise strip_at comes back empty and
    # the assertion below would pass by short-circuit on absence, exercising the
    # wrong branch entirely. (Measured: an earlier `out=${out%...}` fixture did
    # exactly that, and this test survived a mutation of the slice regex.)
    command cat >"$tmp/after.sh" <<'EOF'
truncate_chars() {
    local n="$1" s="$2"
    local out="${s:0:$n}"
    s=${s%$'\r'}
    printf '%s' "$out"
}
EOF
    local body strip_at slice_at
    body="$(command sed -n '/^truncate_chars() {/,/^}/p' "$tmp/after.sh")"
    strip_at="$(command printf '%s\n' "$body" | command grep -nF 's=${s%' | command head -1 | command cut -d: -f1)"
    slice_at="$(command printf '%s\n' "$body" | command grep -nE '\$\{s:0:|printf "%\.' | command head -1 | command cut -d: -f1)"
    # Both offsets must be FOUND, then compared. Asserting the comparison alone
    # would let an extraction that returns nothing satisfy the test vacuously.
    assert_true "[ -n '$strip_at' ]" \
        "TEETH precondition: the order fixture's strip is visible to the presence grep"
    assert_true "[ -n '$slice_at' ]" \
        "TEETH precondition: the order fixture's slice is visible to the slice grep"
    assert_true "[ -n '$strip_at' ] && [ -n '$slice_at' ] && [ '$strip_at' -gt '$slice_at' ]" \
        "TEETH: the order predicate REJECTS a strip that follows the slice"

    # (c) greps as present but strips the WRONG character -- the case only
    #     executing the helper can catch.
    command cat >"$tmp/wrongchar.sh" <<'EOF'
_PRESCAN_UTF8_LOCALE=""
truncate_chars() {
    local n="$1" s="$2"
    s=${s%$'\n'}
    command printf "%.${n}s" "$s"
}
EOF
    local out
    out="$(
        # shellcheck disable=SC1091
        . "$tmp/wrongchar.sh"
        truncate_chars 80 "$(command printf 'password = "x"\r')" | command cat -v
    )"
    assert_true "[ '$out' != 'password = \"x\"' ]" \
        "TEETH: the behavior check REJECTS a strip of the wrong character"

    # ...and the same body must PASS once the strip is right, so (c) is failing
    # for the stated reason rather than because the harness is broken.
    command cat >"$tmp/right.sh" <<'EOF'
_PRESCAN_UTF8_LOCALE=""
truncate_chars() {
    local n="$1" s="$2"
    s=${s%$'\r'}
    command printf "%.${n}s" "$s"
}
EOF
    out="$(
        # shellcheck disable=SC1091
        . "$tmp/right.sh"
        truncate_chars 80 "$(command printf 'password = "x"\r')" | command cat -v
    )"
    assert_equals 'password = "x"' "$out" \
        "TEETH control: the same check PASSES a correctly-stripping copy"
}

# --- Run All Tests ----------------------------------------------------------

run_test test_strip_present "Every truncate_chars copy strips a trailing CR from evidence"
run_test test_strip_precedes_the_slice "The strip runs before the slice (a CR must not consume one of <maxchars>)"
run_test test_strip_is_behaviorally_correct "Each copy, executed, yields CR-free evidence identical to its LF twin"
run_test test_gate_rejects_a_broken_copy "TEETH: each check rejects a deliberately-broken copy (and passes a fixed one)"

generate_report
