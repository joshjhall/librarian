# shellcheck shell=bash
# okf-migrate — the wikilink-convert transform.
#
# Fragment of tests/validate-okf-migrate.sh. Sourced, not executed.
#
# `[[name]]` is NOT an OKF link form — §6.1 specifies ordinary markdown links.
# This is the main portability cost of adoption (238 of this repo's 255 memory
# files still carry wikilinks) and exactly the edit nobody should do by hand
# across N repos.
#
# The two properties worth pinning are both about NOT LOSING ANYTHING: an
# unresolvable target is still converted, and a wikilink inside a code fence is
# left alone.

wikilink_fixture() {
    local root
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "target.md" '---
type: reference
---

The target.'
    command printf '%s' "$root"
}

test_wikilink_converted_to_configured_form() {
    local root body
    root="$(wikilink_fixture)"
    write_concept "$root" "source.md" '---
type: reference
---

See [[target]] for details.'

    run_sh apply "$root" --transform wikilink-convert --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "wikilink-convert applies cleanly"

    body="$(command cat "$root/source.md")"
    # §6.1's recommended form is `/`-rooted (bundle-relative): it survives a file
    # moving within its subdirectory, which the `./` form does not.
    assert_contains "$body" "[target](/target.md)" \
        "a resolvable wikilink becomes a bundle-relative markdown link (§6.1)"
    assert_not_contains "$body" "[[" "no wikilink syntax survives the conversion"
}

test_unresolvable_target_is_preserved() {
    local root body
    root="$(wikilink_fixture)"
    write_concept "$root" "source.md" '---
type: reference
---

See [[not-yet-written]] for details.'

    run_sh apply "$root" --transform wikilink-convert --confirm --allow-dirty
    body="$(command cat "$root/source.md")"

    # §6.1 says a broken link may simply represent knowledge NOT YET WRITTEN, and
    # this repo's own practice is to link memories before writing them. So the
    # link is converted to the path the target WOULD occupy: the conversion is
    # lossless, and the fact that someone meant to link there survives. Dropping
    # the link — or leaving it as a wikilink — would lose that.
    assert_contains "$body" "[not-yet-written](/not-yet-written.md)" \
        "an unresolvable target is converted to the path it WOULD occupy (AC6)"
    assert_not_contains "$body" "[[" "the unresolvable wikilink was not left behind"
}

test_labelled_wikilink_keeps_its_label() {
    local root body
    root="$(wikilink_fixture)"
    write_concept "$root" "source.md" '---
type: reference
---

See [[target|the target concept]] for details.'

    run_sh apply "$root" --transform wikilink-convert --confirm --allow-dirty
    body="$(command cat "$root/source.md")"
    assert_contains "$body" "[the target concept](/target.md)" \
        "the label becomes the link text and the target becomes the href"
}

test_fenced_wikilink_is_not_rewritten() {
    local root body
    root="$(wikilink_fixture)"
    write_concept "$root" "doc.md" '---
type: reference
---

Live link: [[target]]

```markdown
The old syntax looked like [[target]].
```'

    run_sh apply "$root" --transform wikilink-convert --confirm --allow-dirty
    body="$(command cat "$root/doc.md")"

    # A memory DOCUMENTING the old syntax must not have its examples rewritten
    # out from under it — that turns documentation of a format into a claim about
    # a different one. This repo has several such memories, so the case is real
    # rather than theoretical.
    assert_contains "$body" "[target](/target.md)" "the live wikilink outside the fence was converted"
    assert_contains "$body" "looked like [[target]]" \
        "the wikilink INSIDE the fence is sample text and was left alone"
}

test_printf_metacharacters_in_content_survive() {
    local root body
    root="$(wikilink_fixture)"
    write_concept "$root" "source.md" '---
type: reference
---

A %s placeholder, 100% sure, and a [[target]] on the same line.'

    run_sh apply "$root" --transform wikilink-convert --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "content carrying printf metacharacters applies cleanly"

    body="$(command cat "$root/source.md")"
    # THE BASH IMPL CARRIES EVERY LINE THROUGH printf AND A TAB-DELIMITED RECORD.
    # A `%s` or a bare `%` in a memory's body is ordinary prose — this repo's own
    # bundle has plenty — but it is also a printf directive, so a single
    # `printf "$line"` anywhere in the pipeline would eat it or emit garbage.
    # Cheap to assert, and the failure would be silent corruption of someone's
    # notes rather than an error.
    assert_contains "$body" "A %s placeholder, 100% sure" \
        "printf metacharacters in the body are carried through verbatim"
    assert_contains "$body" "[target](/target.md)" "the wikilink on that line still converted"
}

test_wikilink_is_idempotent() {
    local root first second
    root="$(wikilink_fixture)"
    write_concept "$root" "source.md" '---
type: reference
---

See [[target]] and [[missing]].'

    run_sh apply "$root" --transform wikilink-convert --confirm --allow-dirty
    first="$(tree_digest "$root")"
    run_sh apply "$root" --transform wikilink-convert --confirm --allow-dirty
    second="$(tree_digest "$root")"

    # Idempotence here is structural rather than guarded: the output contains no
    # `[[`, so a second pass matches nothing to convert.
    assert_equals "$first" "$second" "applying wikilink-convert twice equals applying once (AC4)"
}

test_wikilink_reversibility() {
    local root rows body
    root="$(wikilink_fixture)"
    write_concept "$root" "source.md" '---
type: reference
---

See [[target]] and [[missing]].'

    run_sh apply "$root" --transform wikilink-convert --confirm --allow-dirty
    body="$(command cat "$root/source.md")"
    assert_not_contains "$body" "[[" "the converted bundle carries no wikilink syntax (AC3)"

    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable — the validator drives the rest of this check"
        return
    fi
    validator_rows "$root"
    rows="$OKF_ROWS"
    assert_true "[ '$OKF_LISTED' -gt 0 ]" \
        "the reversibility scan actually listed files (vacuity guard)"
    # The link to `missing.md` is deliberately still broken, and that is CORRECT:
    # §11 forbids rejecting a bundle for broken cross-links, and a dangling
    # markdown link in a CONCEPT is not a finding at all (only a dangling INDEX
    # line is). So the conversion must not have introduced any conformance row.
    assert_not_contains "$rows" "okf-unparseable-frontmatter" \
        "conversion left every frontmatter block intact"
    assert_not_contains "$rows" "memory-dangling-index" \
        "a broken link in a concept body is tolerated (§6.1) and is not an index row"
}
