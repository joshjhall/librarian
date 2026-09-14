# shellcheck shell=bash
# TEMP-FILE LIFECYCLE — the mktemp/trap arming and re-arming.
#
# Sourced, not executed; see tests/validate-label-vocab-reconcile.sh.
#
# Two distinct arms, which is why both are kept: the re-arm case proves no temp
# file is orphaned when a LATER mktemp fails, and the gh-failure case proves the
# FIRST trap already covers the early exits.

test_first_temp_file_is_cleaned_when_second_mktemp_fails() {
    local box out rc=0 leftover
    box="$(make_sandbox status/in-progress)"
    stub_gh "$box" ok status/in-progress

    # A `mktemp` that SUCCEEDS once then FAILS, which is the exact shape cycle 1
    # found leaking: the trap used to be armed only after both calls, so the
    # second's `|| exit 2` ran with no trap and orphaned the first file. The
    # counter lives in the sandbox so the stub is stateful across invocations.
    #
    # This is the arm that DISAGREES if the re-arm is reverted — without it the
    # fix was asserted only by its own comment.
    command mkdir -p "$box/tmpbin"
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'c="%s/mktemp.count"\n' "$box"
        command printf 'n=0\n'
        command printf '[ -f "$c" ] && n="$(cat "$c")"\n'
        command printf 'n=$((n + 1)); printf "%%s" "$n" > "$c"\n'
        # Let the gh-stderr file and the FIRST comparison file through, then fail.
        command printf 'if [ "$n" -ge 3 ]; then printf "mktemp: no space\\n" >&2; exit 1; fi\n'
        command printf 'f="%s/scratch.$n"; : > "$f"; printf "%%s\\n" "$f"\n' "$box"
    } >"$box/tmpbin/mktemp"
    command chmod +x "$box/tmpbin/mktemp"

    out="$(/usr/bin/env -uBASH_ENV PATH="$box/tmpbin:$box/ghbin:$PATH" LABEL_VOCAB_ROOT="$box" \
        "$REAL_BASH" --noprofile --norc "$RECONCILE_SH" 2>&1)" || rc=$?
    assert_exit 2 "$rc" "a failing mktemp exits 2, not a clean or drift verdict"
    # THE PROPERTY: every scratch file handed out before the failure was removed.
    # A reverted re-arm leaves one behind.
    leftover="$(command ls "$box"/scratch.* 2>/dev/null | command grep -c . || true)"
    assert_equals "0" "$leftover" \
        "no temp file is orphaned when a later mktemp fails (the trap re-arm)"
    assert_not_contains "$out" "No drift" "a run that could not stage its files claims nothing"
}

test_gh_err_temp_file_is_cleaned_on_gh_failure_paths() {
    local box rc=0 leftover iso
    box="$(make_sandbox status/in-progress)"
    stub_gh "$box" fail

    # GH_ERR is mktemp'd BEFORE the comparison files, so its cleanup on gh's OWN
    # failure paths is a different arm from the mktemp-failure case above: that one
    # proves the re-arm, this one proves the FIRST trap covers the early exits.
    # An ISOLATED TMPDIR is essential — /tmp here is shared with peer golems, so a
    # count over it is noise (measured: a delta of 4 from other sessions while this
    # script left nothing).
    iso="$box/isotmp"
    command mkdir -p "$iso"
    /usr/bin/env -uBASH_ENV TMPDIR="$iso" PATH="$box/ghbin:$PATH" LABEL_VOCAB_ROOT="$box" \
        "$REAL_BASH" --noprofile --norc "$RECONCILE_SH" >/dev/null 2>&1 || rc=$?
    assert_exit 2 "$rc" "a failing gh still exits 2"
    leftover="$(command ls -A "$iso" 2>/dev/null | command grep -c . || true)"
    assert_equals "0" "$leftover" "the stderr temp file is cleaned up on gh's failure path"
}
