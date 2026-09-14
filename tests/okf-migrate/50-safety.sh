# shellcheck shell=bash
# okf-migrate — the apply safety gates.
#
# Fragment of tests/validate-okf-migrate.sh. Sourced, not executed.
#
# Everything here is about the difference between "it refused" and "it refused
# BEFORE WRITING". Only the second is a safety property, so every refusal case
# asserts the tree is unchanged rather than settling for a non-zero exit code.
#
# NOTE ON GIT IN FIXTURES: these cases create throwaway `git init` repos under
# $WORKDIR to exercise the dirty-tree gate. They are NOT git WORKTREES — nothing
# here sources tests/lib/golem-sandbox.sh — which is why this suite belongs in
# the 30-scanners shard rather than 20-golem (tests/validate-shards.sh keys that
# rule on the sandbox, not on git generally).

safety_bundle() {
    local root
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "alpha.md" '---
type: reference
---

See [[beta]].'
    write_concept "$root" "beta.md" '---
type: reference
---

Beta.'
    command printf '%s' "$root"
}

# init_repo_around ROOT — a committed git repo containing ROOT, printing its top
# level. Env is scrubbed so the host's git identity/config cannot leak in.
#
# `-uVAR` ATTACHED, never `--unset=VAR`: BSD env has no long options at all and
# reads `--unset=X` as `-u` with the operand `nset=X`, dying with an unhelpful
# message far from here (#932).
init_repo_around() {
    local root="$1" top
    top="$(command dirname "$(command dirname "$root")")"
    (
        cd "$top" || exit 1
        command env -uGIT_DIR -uGIT_WORK_TREE -uGIT_INDEX_FILE \
            git init -q . >/dev/null 2>&1
        command git config user.email t@example.com
        command git config user.name Test
        command git add -A >/dev/null 2>&1
        command git commit -q -m "fixture" >/dev/null 2>&1
    )
    command printf '%s' "$top"
}

test_dirty_tree_refuses() {
    local root before after out
    root="$(safety_bundle)"
    init_repo_around "$root" >/dev/null

    # Make the bundle dirty.
    command printf '%s\n' "an uncommitted edit" >>"$root/alpha.md"
    before="$(tree_digest "$root")"

    run_sh apply "$root" --confirm

    out="$OKF_OUT"
    assert_exit 2 "$OKF_RC" "a dirty bundle refuses apply at exit 2 (AC7)"
    assert_contains "$out" "uncommitted" "the refusal names the reason"

    after="$(tree_digest "$root")"
    assert_equals "$before" "$after" "the refused apply wrote nothing (AC7)"
}

test_allow_dirty_escapes() {
    local root out
    root="$(safety_bundle)"
    init_repo_around "$root" >/dev/null
    command printf '%s\n' "an uncommitted edit" >>"$root/alpha.md"

    run_sh apply "$root" --confirm --allow-dirty

    out="$OKF_OUT"
    assert_exit 0 "$OKF_RC" "--allow-dirty is the documented escape (AC7)"
    assert_not_contains "$out" "uncommitted" "no refusal is printed on the escape path"
    assert_file_exists "$root/index.md" "the migration actually ran"
}

test_non_repo_is_not_dirty() {
    local root
    # $WORKDIR is a mktemp dir, deliberately NOT a git repo.
    root="$(safety_bundle)"

    run_sh apply "$root" --confirm
    # A bundle outside version control must migrate WITHOUT --allow-dirty. This
    # tool runs against any repo's bundle, including a plain directory, so a gate
    # that refused there would be a portability bug rather than a safety feature
    # — the gate exists so a change is reviewable as its own diff, and where
    # there is no git there is no diff to muddy.
    assert_exit 0 "$OKF_RC" \
        "a bundle outside any git repo applies without --allow-dirty (AC9)"
    assert_file_exists "$root/index.md" "the migration ran outside version control"
}

test_apply_writes_only_planned_paths() {
    local root plan_files
    root="$(safety_bundle)"
    # A file the plan will NOT mention: already conformant, no wikilinks.
    write_concept "$root" "untouched.md" '---
type: reference
---

Nothing to migrate here.'

    run_sh plan "$root"
    plan_files="$(command printf '%s\n' "$OKF_OUT" | command grep '^+++ b/' |
        command sed -e 's|^+++ b/||' | command sort -u)"
    command cp "$root/untouched.md" "$WORKDIR/untouched.before"

    run_sh apply "$root" --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "the apply succeeded"

    # THE PLAN IS THE ALLOWLIST, not merely a preview. A file absent from the
    # plan must be byte-identical afterwards — that is what makes reviewing the
    # plan equivalent to reviewing the change.
    assert_true "command cmp -s '$root/untouched.md' '$WORKDIR/untouched.before'" \
        "a file the plan did not list is byte-identical after apply (AC7)"
    assert_not_contains "$plan_files" "untouched.md" \
        "the plan genuinely omitted it (guards against a vacuous comparison)"
    assert_contains "$plan_files" "alpha.md" "the plan did list the files it changed"
}

test_multiple_edits_to_one_file_keep_their_order() {
    local root body
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "t.md" '---
type: reference
---

T.'
    # ONE FILE NEEDING TWO DIFFERENT TRANSFORMS: a `type:` INSERT at line 2 and a
    # wikilink REPLACE further down. The insert shifts every line below it, so
    # the edits must apply highest-line-first — apply the insert first and the
    # replace rewrites the wrong line.
    #
    # Measured before fixing: the bash fallback deleted "line one" and left the
    # wikilink unconverted, because its edit records are colon-prefixed (so `sort
    # -n` read every line number as 0) and every edit tied. Silent corruption of
    # a memory's body, reachable ONLY through a file needing two transforms —
    # which is why no single-transform fixture caught it, and why this case is
    # here rather than in 20-/30-/40-.
    write_concept "$root" "multi.md" '---
name: multi
metadata:
  type: project
---

line one
See [[t]] here.
line three'

    run_sh apply "$root" --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "a file needing two transforms applies cleanly"

    body="$(command cat "$root/multi.md")"
    assert_contains "$body" "line one" "no body line was lost to a mis-ordered edit"
    assert_contains "$body" "line three" "the line below the edits survived too"
    assert_contains "$body" "See [t](/t.md) here." "the wikilink on the shifted line converted"
    assert_true "[ \"\$(command head -n2 '$root/multi.md' | command tail -n1)\" = 'type: project' ]" \
        "the inserted type landed on line 2, not somewhere the shift moved it"
}

test_plan_only_transform_refuses_apply() {
    local root before after out
    root="$(safety_bundle)"
    before="$(tree_digest "$root")"

    run_sh apply "$root" --transform split-index --confirm --allow-dirty

    out="$OKF_OUT"
    assert_exit 2 "$OKF_RC" "a plan-only transform refuses apply at exit 2"
    assert_contains "$out" "plan-only" "the refusal says why"
    # The message must point at the DECISION, not just report a flag error: the
    # transform is refused because it would execute a judgment the engine did not
    # make, and a reader needs to know what to do instead.
    assert_contains "$out" "did not make" "the refusal names the missing human decision"

    after="$(tree_digest "$root")"
    assert_equals "$before" "$after" "the refused plan-only apply wrote nothing"

    run_sh apply "$root" --transform confirmed-merge --confirm --allow-dirty

    out="$OKF_OUT"
    assert_exit 2 "$OKF_RC" "confirmed-merge refuses apply too — merges are human-confirmed"
}

test_plan_only_transforms_are_visible_in_check() {
    local root out
    root="$(safety_bundle)"
    run_sh check "$root"
    out="$OKF_OUT"

    # SILENCE WOULD READ AS "nothing to migrate" — the silence-is-a-pass shape
    # this repo keeps filing issues about (#538/#571). A transform the engine
    # will not run must still be NAMED, so its absence from the applied set is a
    # stated fact rather than an omission the reader has to notice.
    assert_contains "$out" "split-index" "split-index is named in check output"
    assert_contains "$out" "confirmed-merge" "confirmed-merge is named in check output"
    assert_contains "$out" "plan-only" "each is labelled plan-only"
}

test_symlinked_concept_is_never_written_through() {
    local root outside before
    root="$(fresh_bundle "$WORKDIR")"
    outside="$(command mktemp -d "$WORKDIR/outside.XXXXXX")"
    command printf -- '---\nname: victim\n---\n\nOriginal.\n' >"$outside/target.md"
    before="$(command cat "$outside/target.md")"

    write_concept "$root" "real.md" '---
type: reference
---

Body.'
    # A symlink whose NAME matches a type-inference rule, so backfill-type wants
    # to edit it. An unmatched name would be blocked by the ambiguity gate and
    # the case would pass for the wrong reason.
    command mkdir -p "$root/feedback"
    command ln -s "$outside/target.md" "$root/feedback/lesson.md"

    run_sh apply "$root" --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "the bundle still migrates"

    # THE GUARANTEE: apply writes only inside the bundle. `open(path,"w")` and a
    # shell redirect both FOLLOW a symlink, and os.walk lists symlinked FILES
    # (it only declines to descend symlinked dirs) — so before the fix the
    # python impl rewrote the out-of-bundle target while the plan displayed the
    # in-bundle path. The reviewed plan and the real write target were different
    # files, which is precisely what "the plan is the write allowlist" denies.
    assert_equals "$before" "$(command cat "$outside/target.md")" \
        "a file outside the bundle root is NEVER written through a symlink (AC7)"

    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable — the python half of this case"
        return
    fi
    local proot poutside pbefore
    proot="$(fresh_bundle "$WORKDIR")"
    poutside="$(command mktemp -d "$WORKDIR/poutside.XXXXXX")"
    command printf -- '---\nname: victim\n---\n\nOriginal.\n' >"$poutside/target.md"
    pbefore="$(command cat "$poutside/target.md")"
    write_concept "$proot" "real.md" '---
type: reference
---

Body.'
    command mkdir -p "$proot/feedback"
    command ln -s "$poutside/target.md" "$proot/feedback/lesson.md"
    run_py apply "$proot" --confirm --allow-dirty
    assert_equals "$pbefore" "$(command cat "$poutside/target.md")" \
        "python refuses the write-through too — the runtimes agree on the boundary"
}

test_hidden_directories_are_not_part_of_the_bundle() {
    local root py_rows sh_rows
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "real.md" '---
type: reference
---

Body.'
    # A dot-directory of scratch markdown under the bundle root. python pruned
    # it via `dirnames[:] = [...]`; bash's plain `find` descended into it, so the
    # two runtimes disagreed about what the bundle CONTAINS — a parity break no
    # fixture created a hidden directory to catch.
    write_concept "$root" ".attic/scratch.md" '---
name: scratch
---

Scratch.'

    run_sh check "$root"
    sh_rows="$OKF_OUT"
    assert_not_contains "$sh_rows" "AMBIGUOUS" \
        "the hidden directory's file is not treated as a bundle concept"

    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable — the parity half of this case"
        return
    fi
    run_py check "$root"
    py_rows="$OKF_OUT"
    assert_equals "$py_rows" "$sh_rows" \
        "both runtimes agree on a bundle containing a hidden directory"
}
