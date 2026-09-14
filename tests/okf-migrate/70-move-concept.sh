# shellcheck shell=bash
# okf-migrate — the move-concept transform (issue #934, OKF slice J).
#
# Fragment of tests/validate-okf-migrate.sh. Sourced, not executed.
#
# OKF concept IDs ARE the bundle path minus `.md` (§3), so a flat bundle throws
# away the format's one addressing mechanism. Moving a file is trivial; the two
# properties worth pinning are both about NOT LOSING THE FILE'S REACHABILITY:
#
#   * EVERY inbound link follows the move — not the first one found. A file
#     linked from two different directories is the case that separates a real
#     rewriter from one that stops at the first hit, so the AC3 fixture links
#     from two and asserts BOTH.
#   * THE INDEX POINTER follows. An index line is the only thing that makes a
#     memory recallable, so a move that leaves the pointer behind breaks nothing
#     visibly and the memory is simply never found again (#632's shape).
#
# The mutation case at the bottom is what makes those claims falsifiable: it
# neuters the rewriter and asserts a fixture FAILS. A green suite with the
# rewriter disabled would have proven only that the fixtures never expressed the
# divergent case.
#
# NOTE ON GIT IN FIXTURES: the AC7 case creates a throwaway `git init` repo under
# $WORKDIR to assert history survives. It is NOT a git WORKTREE, so this suite
# still belongs in the 30-scanners shard (tests/validate-shards.sh keys that rule
# on tests/lib/golem-sandbox.sh, not on git generally) — the same note
# 50-safety.sh carries.

# move_fixture — a bundle whose taxonomy routes `golem-thing.md` into `golem/`,
# printing `<root>`.
#
# THE INBOUND LINKS COME FROM TWO DIFFERENT DIRECTORIES (root and `sub/`) and in
# BOTH live link forms — `/`-rooted (what wikilink-convert emits) and plain
# relative (what a hand-written index uses). One fixture covering one form would
# leave the other silently unrewritten, and dangling pointers are the whole risk.
move_fixture() {
    local root
    root="$(fresh_bundle "$WORKDIR")"
    # EVERY ROOT-LEVEL concept is named by the root index. The reversibility case
    # (AC6) asserts zero memory-orphan rows, and a concept the FIXTURE left
    # unindexed would produce one no matter how the move behaved — an assertion
    # failing for a reason unrelated to its claim, which is worse than none.
    #
    # `sub/deep.md` is deliberately NOT named here. §8 routes a nested concept
    # through its OWN directory index, so a root line naming it would be a
    # genuine memory-dangling-index — a fixture encoding a spec violation and
    # then asserting the tool cleans it up. `sub/` has no index.md, so the
    # validator skips that directory entirely and deep.md is not an orphan; it
    # is here purely as a second INBOUND-LINK site for AC3.
    write_concept "$root" "MEMORY.md" '# Memory

- [Golem thing](golem-thing.md) — a hook
- [Other](other.md) — a hook'
    write_concept "$root" "index-golem.md" '# Golem

- [Golem thing](golem-thing.md) — a hook'
    write_concept "$root" "golem-thing.md" '---
type: feedback
---

Body.'
    write_concept "$root" "other.md" '---
type: feedback
---

See [Golem thing](/golem-thing.md).'
    write_concept "$root" "sub/deep.md" '---
type: feedback
---

See [Golem thing](../golem-thing.md).'
    command printf '%s' "$root"
}

# with_taxonomy ROOT RULES... — run the engine against a thresholds.yml whose
# taxonomy rules are RULES, printing nothing.
#
# The shipped default is an EMPTY rule list (AC10 below pins that), so every
# other case here needs a configured copy. The override is written to a private
# skill dir and pointed at with $OKF_MIGRATE_CONFIG_DIR rather than editing the
# repo's own thresholds.yml — a fixture that mutated the shipped file would
# leave the tree dirty and could not run in parallel with its siblings.
write_taxonomy() {
    local dir="$1"
    shift
    local rule
    command mkdir -p "$dir"
    command sed -e 's/^taxonomy:$/taxonomy_disabled:/' \
        "$SKILL_DIR/thresholds.yml" >"$dir/thresholds.yml"
    command printf 'taxonomy:\n  rules:\n' >>"$dir/thresholds.yml"
    for rule in "$@"; do
        command printf '    - %s\n' "$rule" >>"$dir/thresholds.yml"
    done
}

# run_moves MODE ROOT [ARGS...] — run_sh with a golem taxonomy configured.
run_moves() {
    local mode="$1" root="$2"
    shift 2
    local cfg="$WORKDIR/cfg.$$"
    write_taxonomy "$cfg" "index:index-golem.md = golem"
    OKF_RC=0
    OKF_OUT="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" \
        OKF_MIGRATE_CONFIG_DIR="$cfg" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command bash "$OKF_MIGRATE_SH" "$mode" "$@" 2>&1)" || OKF_RC=$?
}

test_move_rewrites_every_inbound_link() {
    local root
    root="$(move_fixture)"

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "move-concept applies cleanly"

    assert_file_exists "$root/golem/golem-thing.md" "the concept moved into golem/"
    assert_true "[ ! -e '$root/golem-thing.md' ]" "nothing is left at the old path"

    # BOTH inbound links, from TWO different directories and in BOTH link forms.
    # Asserting only one would pass against a rewriter that stopped at the first
    # hit, leaving the second dangling — which is the failure this pins (AC3).
    assert_file_contains "$root/other.md" "(/golem/golem-thing.md)" \
        "the root-relative inbound link followed the move (AC3)"
    assert_file_contains "$root/sub/deep.md" "(../golem/golem-thing.md)" \
        "the inbound link from ANOTHER directory followed it too (AC3)"
    assert_file_not_contains "$root/other.md" "(/golem-thing.md)" \
        "no stale link to the old path survives"
    assert_file_not_contains "$root/sub/deep.md" "(../golem-thing.md)" \
        "no stale link survives in the second directory either"
}

test_index_pointer_follows_the_move() {
    local root
    root="$(move_fixture)"

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "move-concept applies cleanly"

    # THE INDEX LINE IS THE ONLY THING THAT MAKES A MEMORY RECALLABLE. A move
    # that leaves it behind breaks nothing visibly — the file exists, a per-file
    # check passes, and the memory is never found again (#632: 16 memories
    # written, never recallable). So this is a distinct claim from AC3, even
    # though one code path satisfies both (AC4).
    #
    # §8 ROUTING, which is the shape the real validator accepts: the concept is
    # named by its OWN directory's index, and the indexes that used to name it
    # now name that sub-index. A root line pointing straight at
    # `golem/golem-thing.md` would be the intuitive-looking answer and IS a
    # memory-dangling-index row — measured against the real validator, which is
    # what the reversibility case below re-checks end to end.
    assert_file_exists "$root/golem/index.md" \
        "the move created the §8 directory index (AC4)"
    assert_file_contains "$root/golem/index.md" "(golem-thing.md)" \
        "the directory index names the moved concept by its sibling basename (AC4)"
    assert_file_contains "$root/golem/index.md" "a hook" \
        "the ORIGINAL index line's hook text carried over, not a bare regenerated link"
    assert_file_contains "$root/index-golem.md" "(golem/index.md)" \
        "the index that named the concept now names the sub-index (AC4)"
    assert_file_contains "$root/MEMORY.md" "(golem/index.md)" \
        "the root index points at the sub-index too (AC4)"

    # THE CONCEPT IS NAMED BY EXACTLY ONE INDEX. Leaving the old line pointing at
    # the concept while the new directory index also names it is
    # memory-multi-index — a HIGH finding and a real ambiguity about ownership.
    assert_file_not_contains "$root/index-golem.md" "](golem-thing.md)" \
        "the old index line no longer names the concept directly (no multi-index)"
    assert_file_not_contains "$root/MEMORY.md" "](golem-thing.md)" \
        "nor does the root index"
}

test_move_into_an_existing_directory_index() {
    local root
    root="$(fresh_bundle "$WORKDIR")"
    command mkdir -p "$root/golem"
    write_concept "$root" "MEMORY.md" '# Memory

- [Golem](golem/index.md) — bucket'
    # The directory index ALREADY EXISTS and carries a hand-written line.
    write_concept "$root" "golem/index.md" '# golem

- [Existing](existing.md) — a hook'
    write_concept "$root" "golem/existing.md" '---
type: feedback
---

Body.'
    write_concept "$root" "index-golem.md" '# Golem

- [New thing](new-thing.md) — a hook'
    write_concept "$root" "new-thing.md" '---
type: feedback
---

Body.'

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "move-concept applies cleanly"

    # BOTH HALVES. The existing index must not be regenerated (its hand-written
    # line is the operator's), AND it must gain a line for the arriving concept
    # — otherwise the concept is named by NO index: the old line was repointed
    # at the sub-index while the sub-index never learned about it. Measured:
    # that shape produced a memory-orphan row on a clean apply.
    assert_file_contains "$root/golem/index.md" "(existing.md)" \
        "the existing directory index is APPENDED to, never regenerated"
    assert_file_contains "$root/golem/index.md" "(new-thing.md)" \
        "...and it names the arriving concept, so nothing is orphaned"

    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        return 0
    fi
    validator_rows "$root"
    assert_true "[ '$OKF_LISTED' -gt 0 ]" "the validator actually scanned files"
    assert_not_contains "$OKF_ROWS" "memory-orphan" \
        "the real validator confirms the moved concept is reachable"
}

test_appending_three_concepts_keeps_their_order() {
    local root body
    root="$(fresh_bundle "$WORKDIR")"
    command mkdir -p "$root/golem"
    write_concept "$root" "MEMORY.md" '# Memory

- [Golem](golem/index.md) — bucket'
    write_concept "$root" "golem/index.md" '# golem

- [Zero](zero.md) — a hook'
    write_concept "$root" "golem/zero.md" '---
type: feedback
---

Body.'
    # THREE concepts, because the ordering defect needs 3+ to show. Edits to one
    # file apply HIGHEST LINE FIRST against a growing buffer, so N separate
    # appends at len+1, len+2, len+3 interleave: measured, `c1, c2, c3` was
    # written as `c1, c3, c2`. BOTH runtimes did it identically, so the parity
    # case could not catch it — only an ORDER assertion can.
    write_concept "$root" "index-golem.md" '# Golem

- [C one](c1.md) — a hook
- [C two](c2.md) — a hook
- [C three](c3.md) — a hook'
    write_concept "$root" "c1.md" '---
type: feedback
---

Body.'
    write_concept "$root" "c2.md" '---
type: feedback
---

Body.'
    write_concept "$root" "c3.md" '---
type: feedback
---

Body.'

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "move-concept applies cleanly"

    body="$(command cat "$root/golem/index.md")"
    assert_contains "$body" "(c1.md)" "the first arriving concept is named"
    assert_contains "$body" "(c2.md)" "the second arriving concept is named"
    assert_contains "$body" "(c3.md)" "the third arriving concept is named"

    # THE ORDER ITSELF. Asserting only presence would pass against the scrambled
    # output, which is exactly how this shipped unnoticed.
    assert_equals "zero.md c1.md c2.md c3.md" \
        "$(command printf '%s\n' "$body" | command sed -n 's/.*(\([^)]*\.md\)).*/\1/p' |
            command tr '\n' ' ' | command sed -e 's/ $//')" \
        "the appended block preserves sorted order (not c1, c3, c2)"
}

test_appended_line_keeps_literal_escape_sequences() {
    local root body
    root="$(fresh_bundle "$WORKDIR")"
    command mkdir -p "$root/golem"
    write_concept "$root" "MEMORY.md" '# Memory

- [Golem](golem/index.md) — bucket'
    write_concept "$root" "golem/index.md" '# golem

- [Zero](zero.md) — a hook'
    write_concept "$root" "golem/zero.md" '---
type: feedback
---

Body.'
    # A hook containing the two characters `\n` — ORDINARY in a repo that
    # documents regexes constantly, and the exact input that breaks a naive
    # block encoding. It must survive as two characters, never become a real
    # newline, and it must not defeat the claimed-line lookup either (an
    # `awk -v` assignment is escape-processed, which silently left this one
    # line pointing at the concept while its siblings pointed at the sub-index).
    write_concept "$root" "index-golem.md" '# Golem

- [Plain](plain.md) — a hook
- [Regex](rx.md) — matches \n and \t literally'
    write_concept "$root" "plain.md" '---
type: feedback
---

Body.'
    write_concept "$root" "rx.md" '---
type: feedback
---

Body.'

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "move-concept applies cleanly"

    body="$(command cat "$root/golem/index.md")"
    assert_contains "$body" 'matches \n and \t literally' \
        "a literal backslash-n in a hook survives the block encoding verbatim"
    # 5 = heading + blank + the 1 pre-existing entry + the 2 appended ones. A
    # decoded escape would split the Regex line and make it 6.
    assert_equals "5" "$(command wc -l <"$root/golem/index.md" | command tr -d ' ')" \
        "the block added exactly 2 lines — a decoded escape would add a third"

    # And the escape must not defeat the claimed-line lookup: BOTH old index
    # lines now point at the sub-index, not just the one without an escape.
    assert_file_contains "$root/index-golem.md" "(golem/index.md)" \
        "the plain line points at the sub-index"
    assert_equals "2" \
        "$(command grep -c "(golem/index.md)" "$root/index-golem.md")" \
        "BOTH lines point at the sub-index — the escaped one is not left behind"
}

test_backslash_in_a_path_keeps_the_operator_hook() {
    local root body
    root="$(fresh_bundle "$WORKDIR")"
    command mkdir -p "$root/golem"
    write_concept "$root" "MEMORY.md" '# Memory

- [Golem](golem/index.md) — bucket'
    write_concept "$root" "golem/index.md" '# golem

- [Zero](zero.md) — a hook'
    write_concept "$root" "golem/zero.md" '---
type: feedback
---

Body.'
    # A FILENAME CONTAINING A BACKSLASH — legal on POSIX, and the input that
    # separates an ENVIRON lookup from an `awk -v` one: a `-v` assignment is
    # escape-processed, so the key is mangled, the claimed-line lookup MISSES,
    # and the operator's hook text is silently replaced by a regenerated bare
    # link. Measured: `- [Odd](od\nd.md) — a hook` became `- [od\nd](od\nd.md)`.
    write_concept "$root" "index-golem.md" '# Golem

- [Odd](od\nd.md) — a hook'
    write_concept "$root" "od\nd.md" '---
type: feedback
---

Body.'

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "move-concept applies cleanly"

    body="$(command cat "$root/golem/index.md")"
    # THE HOOK IS THE POINT, not merely the link: the hook is the operator's
    # prose and is what makes an index entry useful to recall against, so losing
    # it is a silent content regression rather than a broken link.
    assert_contains "$body" "— a hook" \
        "the ORIGINAL index line hook survived a backslash-bearing path"
    assert_not_contains "$body" "[od" \
        "...and was not replaced by a regenerated bare link"
}

test_destination_collision_leaves_the_file_put() {
    local root before after
    root="$(fresh_bundle "$WORKDIR")"
    command mkdir -p "$root/golem"
    write_concept "$root" "MEMORY.md" '# Memory

- [Golem](golem/index.md) — bucket'
    write_concept "$root" "golem/index.md" '# golem

- [Clash](clash.md) — a hook'
    # A concept ALREADY occupying the destination path.
    write_concept "$root" "golem/clash.md" '---
type: feedback
---

The incumbent.'
    # ...and a DIFFERENT concept whose taxonomy destination is the same path.
    write_concept "$root" "index-golem.md" '# Golem

- [Clash](clash.md) — a hook'
    write_concept "$root" "clash.md" '---
type: feedback
---

The arriving one.'

    before="$(command cat "$root/golem/clash.md")"
    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "a collision is not an error — the move is simply skipped"

    # A COLLISION MUST NEVER OVERWRITE. Two concepts sharing a basename routed to
    # one directory would otherwise have the second silently destroy the first —
    # an unrecoverable loss of a memory, from a tool whose premise is running
    # against someone else's bundle.
    after="$(command cat "$root/golem/clash.md")"
    assert_equals "$before" "$after" \
        "the incumbent at the destination is byte-identical — never overwritten"
    assert_file_exists "$root/clash.md" \
        "the colliding concept stays PUT rather than vanishing"
}

test_move_is_idempotent() {
    local root once twice
    root="$(move_fixture)"

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "the first apply succeeds"
    once="$(tree_digest "$root")"

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "the second apply succeeds"
    twice="$(tree_digest "$root")"

    # Byte-compared, not "exits 0 again": a transform can re-run cleanly and
    # still have rewritten a link into a double-prefixed path (AC5).
    assert_equals "$once" "$twice" "applying twice equals applying once (AC5)"

    run_moves check "$root" --transform move-concept
    assert_contains "$OKF_OUT" "bundle needs no mechanized migration" \
        "a migrated bundle reports nothing left to move"
}

test_move_reversibility() {
    local root
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable — the validator is python-only"
        return 0
    fi
    root="$(move_fixture)"
    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "move-concept applies cleanly"

    validator_rows "$root"
    # THE VACUITY GUARD FIRST. patterns.py takes a newline FILE LIST, never a
    # directory: handed the wrong shape it scans nothing and still exits 0, so a
    # zero-row assertion would pass while checking nothing at all.
    assert_true "[ '$OKF_LISTED' -gt 0 ]" \
        "the validator actually scanned files (guards a vacuous zero)"
    assert_not_contains "$OKF_ROWS" "memory-dangling-index" \
        "no index line dangles after the move (AC6)"
    assert_not_contains "$OKF_ROWS" "memory-orphan" \
        "the moved concept is still reachable from an index (AC6)"
}

test_move_preserves_git_history() {
    local root top log
    root="$(move_fixture)"
    top="$(init_repo_around "$root")"

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "move-concept applies cleanly"

    (
        cd "$top" || exit 1
        command git add -A >/dev/null 2>&1
        command git commit -q -m "move" >/dev/null 2>&1
    )
    log="$(cd "$top" && command git log --follow --oneline -- \
        ".claude/memory/golem/golem-thing.md" 2>/dev/null)"

    # `git mv` RATHER THAN delete+create (AC7). The history is the reason a
    # memory can be trusted, and a delete+create severs it at exactly the moment
    # the file becomes hardest to place. Two commits reachable through --follow
    # means the rename was tracked; one means the history stops at the move.
    assert_contains "$log" "fixture" \
        "git log --follow reaches the PRE-MOVE commit — the rename kept history (AC7)"
    assert_equals "2" "$(command printf '%s\n' "$log" | command wc -l | command tr -d ' ')" \
        "exactly the two commits are reachable, not a severed single one"
}

test_unconfigured_bundle_has_nothing_to_move() {
    local root before after
    root="$(move_fixture)"
    before="$(tree_digest "$root")"

    # NO taxonomy override — the SHIPPED default, which is an empty rule list.
    run_sh check "$root" --transform move-concept
    assert_exit 0 "$OKF_RC" "an unconfigured repo exits 0, never an error (AC10)"
    assert_contains "$OKF_OUT" "bundle needs no mechanized migration" \
        "an unconfigured repo reports nothing to move (AC10)"

    run_sh apply "$root" --transform move-concept --confirm --allow-dirty
    after="$(tree_digest "$root")"
    # A move engine that invented a taxonomy would be authoring the judgment
    # rather than executing it, and a wrongly-placed file changes its concept ID
    # — which every link in the bundle is expressed in terms of.
    assert_equals "$before" "$after" \
        "an unconfigured apply moves nothing at all (AC10)"
}

test_move_plan_writes_nothing() {
    local root before after
    root="$(move_fixture)"
    before="$(tree_digest "$root")"

    run_moves plan "$root" --transform move-concept
    assert_exit 0 "$OKF_RC" "plan exits 0"
    # A move renders as a RENAME HEADER, not a +/- pair: it changes no bytes, so
    # showing it as content would misrepresent what apply does.
    assert_contains "$OKF_OUT" "rename from golem-thing.md" \
        "plan renders the move as a reviewable rename (AC2)"
    assert_contains "$OKF_OUT" "rename to golem/golem-thing.md" \
        "plan names the destination"

    after="$(tree_digest "$root")"
    assert_equals "$before" "$after" "plan wrote nothing (AC2)"
}

test_move_apply_requires_confirm() {
    local root before after
    root="$(move_fixture)"
    before="$(tree_digest "$root")"

    run_moves apply "$root" --transform move-concept --allow-dirty
    assert_exit 2 "$OKF_RC" "apply without --confirm refuses at exit 2"

    after="$(tree_digest "$root")"
    # "It errored" and "it errored BEFORE MOVING" are different claims, and only
    # the second is a safety property.
    assert_equals "$before" "$after" "the refused apply moved nothing"
}

test_move_destination_outside_the_bundle_is_refused() {
    local root cfg before after
    root="$(move_fixture)"
    before="$(tree_digest "$root")"
    cfg="$WORKDIR/cfg.escape.$$"
    # A taxonomy rule aiming OUTSIDE the bundle. The destination is the new
    # surface a move introduces — every other transform only ever writes a path
    # that already existed in the bundle — so it gets its own resolved-root
    # check, and this is the case that can actually fail it.
    write_taxonomy "$cfg" "index:index-golem.md = ../../../escaped"

    OKF_RC=0
    OKF_OUT="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" \
        OKF_MIGRATE_CONFIG_DIR="$cfg" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command bash "$OKF_MIGRATE_SH" apply --transform move-concept \
        --confirm --allow-dirty 2>&1)" || OKF_RC=$?

    assert_exit 2 "$OKF_RC" "a destination outside the bundle root is refused"
    assert_contains "$OKF_OUT" "outside the bundle root" \
        "the refusal names the reason"
    after="$(tree_digest "$root")"
    assert_equals "$before" "$after" "the refused move wrote nothing"
}

test_neutered_rewriter_fails_the_inbound_fixture() {
    local root mutant cfg out
    # THE MUTATION ROUND (AC8). Every assertion above claims the rewriter works;
    # this one claims the FIXTURES WOULD NOTICE IF IT DID NOT. A suite that
    # stayed green with the rewriter disabled would have proven only that its
    # fixtures never expressed the divergent case — which is the whole reason
    # this repo files mutation-round criteria.
    mutant="$WORKDIR/mutant.$$"
    command mkdir -p "$mutant"
    command cp "$SKILL_DIR"/*.sh "$SKILL_DIR"/*.py "$SKILL_DIR"/*.yml "$mutant/" 2>/dev/null

    # Neuter ONLY the inbound-link rewriter: it returns immediately, so files
    # still move and every link is left pointing at the vacated path.
    command sed -e 's|^rewrite_inbound_links() {$|rewrite_inbound_links() { return 0;|' \
        "$SKILL_DIR/moves.sh" >"$mutant/moves.sh"

    root="$(move_fixture)"
    cfg="$WORKDIR/cfg.mut.$$"
    write_taxonomy "$cfg" "index:index-golem.md = golem"

    out="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" \
        OKF_MIGRATE_CONFIG_DIR="$cfg" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command bash "$mutant/migrate.sh" apply --transform move-concept \
        --confirm --allow-dirty 2>&1)" || :
    : "$out"

    # The mutant must still MOVE the file — otherwise this proves nothing about
    # the rewriter, only that a broken script writes nothing.
    assert_file_exists "$root/golem/golem-thing.md" \
        "the mutant still performs the move (the mutation is scoped to the rewriter)"

    # …and the AC3/AC4 assertions must now FAIL. Asserting the STALE state is
    # how a bash suite expresses "that fixture would have gone red".
    assert_file_contains "$root/other.md" "(/golem-thing.md)" \
        "with the rewriter neutered the inbound link is STALE — the AC3 fixture would fail (AC8)"
    assert_file_contains "$root/index-golem.md" "](golem-thing.md)" \
        "with the rewriter neutered the index pointer is STALE — the AC4 fixture would fail (AC8)"
}

test_move_parity_between_runtimes() {
    local root_py root_sh cfg
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable"
        return 0
    fi
    cfg="$WORKDIR/cfg.parity.$$"
    write_taxonomy "$cfg" "index:index-golem.md = golem"
    root_py="$(move_fixture)"
    root_sh="$(move_fixture)"

    OKF_MIGRATE_CONFIG_DIR="$cfg" run_py apply "$root_py" \
        --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "the python impl applies cleanly"
    OKF_MIGRATE_CONFIG_DIR="$cfg" run_sh apply "$root_sh" \
        --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "the bash impl applies cleanly"

    # Paths differ per fixture, so the digests are compared with each root
    # stripped — the tree SHAPE and every byte of content must agree.
    assert_equals \
        "$(tree_digest "$root_py" | command sed -e "s|$root_py||g")" \
        "$(tree_digest "$root_sh" | command sed -e "s|$root_sh||g")" \
        "bash and python produce byte-identical moved trees"
}
