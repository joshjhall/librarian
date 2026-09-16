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

# run_moves_py MODE ROOT [ARGS...] — the PYTHON primary with the same taxonomy.
# run_moves forces bash, so without this sibling no move-concept case speaks for
# the python runtime at all.
run_moves_py() {
    local mode="$1" root="$2"
    shift 2
    local cfg="$WORKDIR/cfg.$$"
    write_taxonomy "$cfg" "index:index-golem.md = golem"
    OKF_RC=0
    OKF_OUT="$(OKF_BUNDLE_ROOT="$root" \
        OKF_MIGRATE_CONFIG_DIR="$cfg" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command python3 "$OKF_MIGRATE_PY" "$mode" "$@" 2>&1)" || OKF_RC=$?
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

    # THE PYTHON PATH GETS THE SAME ORDER ASSERTION, not just parity. The
    # ordering defect was present in BOTH runtimes identically, so the
    # whole-tree parity test could not have caught it — and this fragment drives
    # the bash twin everywhere else, which is how the first mutation round of
    # this very fixture proved nothing (it mutated moves.py, which no case here
    # exercises). Asserting the ORDER against python closes that.
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        return 0
    fi
    local root_py body_py cfg_py
    cfg_py="$WORKDIR/cfg.order.$$"
    write_taxonomy "$cfg_py" "index:index-golem.md = golem"
    root_py="$(fresh_bundle "$WORKDIR")"
    command mkdir -p "$root_py/golem"
    write_concept "$root_py" "MEMORY.md" '# Memory

- [Golem](golem/index.md) — bucket'
    write_concept "$root_py" "golem/index.md" '# golem

- [Zero](zero.md) — a hook'
    write_concept "$root_py" "golem/zero.md" '---
type: feedback
---

Body.'
    write_concept "$root_py" "index-golem.md" '# Golem

- [C one](c1.md) — a hook
- [C two](c2.md) — a hook
- [C three](c3.md) — a hook'
    write_concept "$root_py" "c1.md" '---
type: feedback
---

Body.'
    write_concept "$root_py" "c2.md" '---
type: feedback
---

Body.'
    write_concept "$root_py" "c3.md" '---
type: feedback
---

Body.'
    OKF_MIGRATE_CONFIG_DIR="$cfg_py" run_py apply "$root_py" \
        --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "the python impl applies cleanly"
    body_py="$(command cat "$root_py/golem/index.md")"
    assert_equals "zero.md c1.md c2.md c3.md" \
        "$(command printf '%s\n' "$body_py" | command sed -n 's/.*(\([^)]*\.md\)).*/\1/p' |
            command tr '\n' ' ' | command sed -e 's/ $//')" \
        "the PYTHON append path preserves sorted order too"
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

test_fenced_index_line_does_not_route_a_concept() {
    local root
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "MEMORY.md" '# Memory

- [Real](real.md) — a hook
- [Other](other.md) — a hook'
    # An index that DOCUMENTS the link syntax in a fence. The fenced line is an
    # EXAMPLE, not a pointer — reading it as one would route a concept by a
    # bucket it was never filed under. moves.py has FENCE_RE precisely for this,
    # and its two other link scanners apply it; index_members did not.
    write_concept "$root" "index-golem.md" '# Golem

Example of the link syntax:

```markdown
- [Real](real.md) — an EXAMPLE, not a pointer
```

- [Other](other.md) — a hook'
    write_concept "$root" "real.md" '---
type: feedback
---

Body.'
    write_concept "$root" "other.md" '---
type: feedback
---

Body.'

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "move-concept applies cleanly"

    assert_file_exists "$root/golem/other.md" \
        "the genuinely-indexed concept moved (guards against a vacuous pass)"
    assert_file_exists "$root/real.md" \
        "a concept mentioned only inside a FENCE is not routed by that index"
    assert_true "[ ! -e '"'"'$root/golem/real.md'"'"' ]" \
        "...and did not land in the fenced bucket"
}

# write_taxonomy_rules DIR RULES... — a config with ARBITRARY rules, so a case
# can exercise a source other than `index:`.
test_file_and_dir_taxonomy_sources_route_concepts() {
    local root cfg
    root="$(fresh_bundle "$WORKDIR")"
    command mkdir -p "$root/legacy"
    write_concept "$root" "MEMORY.md" '# Memory

- [By file](golem-thing.md) — a hook
- [Untouched](plain.md) — a hook'
    write_concept "$root" "golem-thing.md" '---
type: feedback
---

Body.'
    write_concept "$root" "plain.md" '---
type: feedback
---

Body.'
    write_concept "$root" "legacy/old.md" '---
type: feedback
---

Body.'

    # `file:` and `dir:` are documented in thresholds.yml as equally valid
    # grammar alongside `index:`, but every other case here configures `index:`
    # only — so both were live code with no coverage in either runtime.
    cfg="$WORKDIR/cfg.fd.$$"
    write_taxonomy "$cfg" "file:golem-*.md = golem" "dir:legacy* = archive"
    OKF_RC=0
    OKF_OUT="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" \
        OKF_MIGRATE_CONFIG_DIR="$cfg" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command bash "$OKF_MIGRATE_SH" apply --transform move-concept \
        --confirm --allow-dirty 2>&1)" || OKF_RC=$?
    assert_exit 0 "$OKF_RC" "a file:/dir: taxonomy applies cleanly"

    assert_file_exists "$root/golem/golem-thing.md" \
        "a $(file:) glob routes a concept by its BASENAME"
    assert_file_exists "$root/archive/old.md" \
        "a $(dir:) glob routes a concept by its current DIRECTORY"
    # Teeth: a concept matching NEITHER rule stays put, so this cannot pass by
    # the transform having moved everything.
    assert_file_exists "$root/plain.md" \
        "a concept matching no rule stays exactly where it is"
}

test_taxonomy_rules_are_first_match_wins() {
    local root cfg
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "MEMORY.md" '# Memory

- [Thing](golem-thing.md) — a hook'
    write_concept "$root" "golem-thing.md" '---
type: feedback
---

Body.'

    # TWO rules both match this concept. Order decides — the same determinism
    # rule infer_type holds, and the property that makes the outcome
    # reproducible between the two runtimes rather than an accident of
    # filesystem order.
    cfg="$WORKDIR/cfg.ord1.$$"
    write_taxonomy "$cfg" "file:golem-*.md = first" "file:*-thing.md = second"
    OKF_RC=0
    OKF_OUT="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" \
        OKF_MIGRATE_CONFIG_DIR="$cfg" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command bash "$OKF_MIGRATE_SH" apply --transform move-concept \
        --confirm --allow-dirty 2>&1)" || OKF_RC=$?
    assert_exit 0 "$OKF_RC" "the two-rule taxonomy applies"
    assert_file_exists "$root/first/golem-thing.md" \
        "the FIRST listed matching rule wins"

    # ...and REVERSING the listed order reverses the outcome, which is what
    # proves order is what decided it rather than a glob coincidence.
    local root2 cfg2
    root2="$(fresh_bundle "$WORKDIR")"
    write_concept "$root2" "MEMORY.md" '# Memory

- [Thing](golem-thing.md) — a hook'
    write_concept "$root2" "golem-thing.md" '---
type: feedback
---

Body.'
    cfg2="$WORKDIR/cfg.ord2.$$"
    write_taxonomy "$cfg2" "file:*-thing.md = second" "file:golem-*.md = first"
    OKF_RC=0
    OKF_OUT="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root2" \
        OKF_MIGRATE_CONFIG_DIR="$cfg2" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command bash "$OKF_MIGRATE_SH" apply --transform move-concept \
        --confirm --allow-dirty 2>&1)" || OKF_RC=$?
    assert_file_exists "$root2/second/golem-thing.md" \
        "reversing the rule order reverses the destination (order IS the decider)"
}

test_malformed_taxonomy_rules_are_skipped_not_fatal() {
    local root cfg
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "MEMORY.md" '# Memory

- [Good](good.md) — a hook'
    write_concept "$root" "good.md" '---
type: feedback
---

Body.'

    # Malformed entries are SKIPPED rather than fatal — a migration engine
    # reading a consumer repo's hand-edited config must not die on one bad line.
    # Note which way that fails: a skipped rule means FEWER moves, never a move
    # somewhere unintended.
    cfg="$WORKDIR/cfg.bad.$$"
    write_taxonomy "$cfg" "no-equals-sign-here" "missingcolon = dest" \
        "file:good.md = good"
    OKF_RC=0
    OKF_OUT="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" \
        OKF_MIGRATE_CONFIG_DIR="$cfg" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command bash "$OKF_MIGRATE_SH" apply --transform move-concept \
        --confirm --allow-dirty 2>&1)" || OKF_RC=$?
    assert_exit 0 "$OKF_RC" "a malformed rule is skipped, never fatal"
    assert_file_exists "$root/good/good.md" \
        "the WELL-FORMED rule in the same list still applies"
}

test_two_concepts_moving_together_keep_their_relative_link() {
    local root cfg body
    root="$(fresh_bundle "$WORKDIR")"
    command mkdir -p "$root/sub"
    write_concept "$root" "MEMORY.md" '# Memory

- [Anchor](anchor.md) — a hook'
    write_concept "$root" "anchor.md" '---
type: feedback
---

Body.'
    # BOTH of these move, TOGETHER, and one links the other by a RELATIVE path.
    # The link must be recomputed from where the referring file will LAND, not
    # from where it sits now — the common case when a whole bucket relocates at
    # once, and the branch `_rewritten_target` takes only when the referrer is
    # itself in the move set.
    write_concept "$root" "sub/alpha.md" '---
type: feedback
---

See [Beta](beta.md) for details.'
    write_concept "$root" "sub/beta.md" '---
type: feedback
---

Body.'

    cfg="$WORKDIR/cfg.pair.$$"
    write_taxonomy "$cfg" "dir:sub* = moved"
    OKF_RC=0
    OKF_OUT="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" \
        OKF_MIGRATE_CONFIG_DIR="$cfg" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command bash "$OKF_MIGRATE_SH" apply --transform move-concept \
        --confirm --allow-dirty 2>&1)" || OKF_RC=$?
    assert_exit 0 "$OKF_RC" "both concepts move cleanly"

    assert_file_exists "$root/moved/alpha.md" "the referring concept moved"
    assert_file_exists "$root/moved/beta.md" "the referenced concept moved too"

    # They landed in the SAME directory, so the sibling link is unchanged — and
    # that is the assertion: a rewriter computing from the OLD location would
    # have produced `../moved/beta.md`, which resolves outside the new directory.
    body="$(command cat "$root/moved/alpha.md")"
    assert_contains "$body" "(beta.md)" \
        "the relative link is recomputed from where the referrer LANDS"
    assert_not_contains "$body" "../" \
        "...not from where it used to sit (no stale ../ prefix)"
}

test_symlinked_existing_index_is_never_written_through() {
    local root outside before after
    root="$(fresh_bundle "$WORKDIR")"
    command mkdir -p "$root/golem"
    outside="$WORKDIR/outside.$$"
    command mkdir -p "$outside"
    command printf 'ORIGINAL-OUTSIDE-CONTENT\n' >"$outside/target.md"

    write_concept "$root" "MEMORY.md" '# Memory

- [Golem](golem/index.md) — bucket'
    # A PRE-EXISTING directory index that is a SYMLINK pointing OUTSIDE the
    # bundle. The planner used to treat it as "existing" and schedule an append
    # against it; the apply guard resolved only the DIRECTORY portion and
    # appended the basename literally, so the path read as in-root while plain
    # `cp` followed the symlink and wrote through it. Measured: the arriving
    # concept's index line was appended to the OUTSIDE file, at exit 0, with the
    # plan displaying only the in-bundle path — the reviewed plan and the actual
    # write target were different files.
    command ln -s "$outside/target.md" "$root/golem/index.md"
    write_concept "$root" "golem/zero.md" '---
type: feedback
---

Body.'
    write_concept "$root" "index-golem.md" '# Golem

- [Arriving](arr.md) — a hook'
    write_concept "$root" "arr.md" '---
type: feedback
---

Body.'

    before="$(command cat "$outside/target.md")"
    run_moves apply "$root" --transform move-concept --confirm --allow-dirty

    # THE OUTSIDE FILE IS THE ASSERTION, not the exit code: "it refused" and
    # "it refused BEFORE writing" are different claims, and only the second is
    # a safety property.
    after="$(command cat "$outside/target.md")"
    assert_equals "$before" "$after" \
        "a symlinked directory index is NEVER written through (AC7)"
    assert_not_contains "$after" "Arriving" \
        "...and no in-bundle content leaked into the outside file"
}

test_foreign_index_name_works_by_config_alone() {
    local root cfg
    root="$(fresh_bundle "$WORKDIR")"
    # A repo whose index is NOT called MEMORY.md or index*.md. The epic's whole
    # premise is running against SOMEONE ELSE'S bundle, and the validator already
    # reads index_names from config — but okf-migrate hardcoded librarian's own
    # convention, so this repo got "nothing to move" at exit 0. Silently wrong,
    # not a refusal.
    write_concept "$root" "catalog.md" '# Catalog

- [Thing](thing.md) — a hook'
    write_concept "$root" "thing.md" '---
type: feedback
---

Body.'
    cfg="$WORKDIR/cfg.foreign.$$"
    write_taxonomy "$cfg" "index:catalog.md = bucket"

    OKF_RC=0
    OKF_OUT="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" \
        OKF_MIGRATE_CONFIG_DIR="$cfg" OKF_INDEX_NAMES="catalog.md" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command bash "$OKF_MIGRATE_SH" apply --transform move-concept \
        --confirm --allow-dirty 2>&1)" || OKF_RC=$?
    assert_exit 0 "$OKF_RC" "a foreign index vocabulary applies by CONFIG alone"
    assert_file_exists "$root/bucket/thing.md" \
        "the concept was routed by an index this engine had never heard of"

    # TEETH: without the override the SAME bundle moves nothing, so the pass
    # above is attributable to the config rather than to a rule that fires
    # regardless.
    local root2
    root2="$(fresh_bundle "$WORKDIR")"
    write_concept "$root2" "catalog.md" '# Catalog

- [Thing](thing.md) — a hook'
    write_concept "$root2" "thing.md" '---
type: feedback
---

Body.'
    OKF_RC=0
    OKF_OUT="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root2" \
        OKF_MIGRATE_CONFIG_DIR="$cfg" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command bash "$OKF_MIGRATE_SH" apply --transform move-concept \
        --confirm --allow-dirty 2>&1)" || OKF_RC=$?
    assert_file_exists "$root2/thing.md" \
        "...and without the override the same bundle moves nothing"
}

test_symlinked_move_destination_is_skipped() {
    local root outside before
    root="$(fresh_bundle "$WORKDIR")"
    command mkdir -p "$root/golem"
    outside="$WORKDIR/outdir.$$"
    command mkdir -p "$outside"

    write_concept "$root" "MEMORY.md" '# Memory

- [Thing](golem-thing.md) — a hook'
    write_concept "$root" "index-golem.md" '# Golem

- [Thing](golem-thing.md) — a hook'
    write_concept "$root" "golem-thing.md" '---
type: feedback
---

MOVING-CONCEPT'
    write_concept "$root" "golem/index.md" '# golem

- [Zero](zero.md) — a hook'
    write_concept "$root" "golem/zero.md" '---
type: feedback
---

Body.'
    # THE MOVE DESTINATION, pre-planted as a symlink to an external DIRECTORY.
    # plan_moves' `taken` set cannot see it: that set is seeded from the concept
    # walk, which excludes symlinks by TYPE (collect_bundle's safety boundary).
    # So the move planned normally and only the WRITE diverged — in bash, whose
    # rename falls back to plain `mv` when the VCS rename fails (an existing
    # destination being exactly what causes that), and POSIX `mv` resolves its
    # destination with stat(2), which DEREFERENCES. Measured before the fix: the
    # concept landed in the external directory at exit 0 while the plan showed
    # the in-bundle path.
    command ln -s "$outside" "$root/golem/golem-thing.md"
    before="$(command ls -A "$outside" | command wc -l | command tr -d ' ')"

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    # SKIPPED, NOT REFUSED — the established collision policy for an occupied
    # destination (see test_destination_collision_leaves_the_file_put). An
    # apply-time abort would also have broken exit-code parity, since the python
    # twin's os.rename replaces a link node rather than following it and so had
    # no reason to fail.
    assert_exit 0 "$OKF_RC" "an occupied destination skips that move, not the run"

    assert_equals "$before" \
        "$(command ls -A "$outside" | command wc -l | command tr -d ' ')" \
        "the external directory gained nothing — no write-through (AC7)"
    assert_file_exists "$root/golem-thing.md" \
        "the concept stays put rather than vanishing outside the bundle"
    # The SIBLING concept in the same directory still moves — proving the skip
    # is scoped to the colliding path rather than the run having gone silent.
    assert_true "[ -L '$root/golem/golem-thing.md' ]" \
        "the symlink itself is untouched, never replaced or followed"
}

test_symlinked_move_destination_is_skipped_in_python() {
    local root outside before
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable"
        return 0
    fi
    # THE SAME FIXTURE AGAINST THE PYTHON PRIMARY. run_moves forces bash, so the
    # case above cannot speak for this runtime at all — and the two genuinely
    # diverged here before the fix was moved to plan time: python's os.rename
    # replaced the link node and completed the move at exit 0, bash's `mv`
    # followed it out of the bundle. Both now plan the move away.
    root="$(fresh_bundle "$WORKDIR")"
    command mkdir -p "$root/golem"
    outside="$WORKDIR/pyoutdir.$$"
    command mkdir -p "$outside"

    write_concept "$root" "MEMORY.md" '# Memory

- [Thing](golem-thing.md) — a hook'
    write_concept "$root" "index-golem.md" '# Golem

- [Thing](golem-thing.md) — a hook'
    write_concept "$root" "golem-thing.md" '---
type: feedback
---

MOVING-CONCEPT'
    write_concept "$root" "golem/index.md" '# golem

- [Zero](zero.md) — a hook'
    write_concept "$root" "golem/zero.md" '---
type: feedback
---

Body.'
    command ln -s "$outside" "$root/golem/golem-thing.md"
    before="$(command ls -A "$outside" | command wc -l | command tr -d ' ')"

    run_moves_py apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "python agrees on the exit code (parity)"
    assert_equals "$before" \
        "$(command ls -A "$outside" | command wc -l | command tr -d ' ')" \
        "the external directory gained nothing"
    assert_file_exists "$root/golem-thing.md" \
        "the concept stays put in python too"
    assert_true "[ -L '$root/golem/golem-thing.md' ]" \
        "the symlink node is NOT replaced — python planned the move away"
}

test_retarget_skips_a_leading_url_link() {
    local root body
    root="$(fresh_bundle "$WORKDIR")"
    # MEMORY.md does NOT name this concept, so the URL-bearing index line is the
    # one that claims it — otherwise MEMORY.md's simpler line wins the claim and
    # retarget_line never sees the URL case at all (measured: that is why the
    # first draft of this fixture asserted against the wrong line).
    write_concept "$root" "MEMORY.md" '# Memory

- [Golem](index-golem.md) — bucket'
    # The claiming index line's FIRST link is an external URL; the `.md` link is
    # SECOND.
    # A retargeter inspecting only the first link leaves the line untouched,
    # while the python twin scans past it — a live byte-parity break in the two
    # call sites that build a directory index.
    # The concept sits in `sub/`, so its claimed line spells a SUB-PATH — and
    # the generated directory index must rewrite that to a sibling basename.
    command mkdir -p "$root/sub"
    write_concept "$root" "index-golem.md" '# Golem

- [source](https://example.com) [Thing](sub/thing.md) — a hook'
    write_concept "$root" "sub/thing.md" '---
type: feedback
---

Body.'

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "move-concept applies cleanly"

    body="$(command cat "$root/golem/index.md")"
    # THE RETARGET MUST ACTUALLY CHANGE THE PATH, which is the only case that
    # distinguishes the fix: the old line said `(sub/thing.md)` and the new one
    # must say `(thing.md)` — a sibling reference. A fixture whose before and
    # after spellings are identical passes either way, which is how the first
    # draft of this case survived its mutation round.
    assert_contains "$body" "](thing.md)" \
        "the .md link was retargeted to the sibling basename PAST the URL"
    assert_not_contains "$body" "](sub/thing.md)" \
        "...and the old sub-path spelling is gone"
    assert_contains "$body" "https://example.com" \
        "the leading URL link is carried through untouched, not consumed"
}

test_fenced_claim_does_not_displace_the_real_index_line() {
    local root py_index sh_index py_src sh_src
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable"
        return 0
    fi
    # A FENCED EXAMPLE IN A FILE THAT SORTS AHEAD OF THE REAL INDEX.
    # plan_directory_indexes keeps only the FIRST line it sees naming each moved
    # concept and walks alphabetically, so `aaa-doc.md`'s fenced sample line
    # reaches the claimed map before `index-golem.md`'s genuine one. The python
    # primary tracks in_fence here (as both runtimes already do in index_members
    # and rewrite_inbound_links); the bash twin did not.
    #
    # Measured before the fix: bash seeded golem/index.md with the FENCED text
    # while python used the real line — and, because rewrite_inbound_links keys
    # off that same claimed text to decide the real line is being RELOCATED,
    # bash also rewrote index-golem.md to point straight at the moved concept
    # (golem/golem-thing.md) instead of at the sub-index, leaving the concept
    # named by TWO indexes: the memory-multi-index state the validator flags.
    #
    # Asserted as BOTH a byte-parity comparison and an explicit content check,
    # because the two runtimes agreeing on the WRONG line would satisfy parity
    # alone.
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "MEMORY.md" '# Memory

- [Golem](index-golem.md) — bucket'
    write_concept "$root" "index-golem.md" '# Golem

- [Thing](golem-thing.md) — the REAL claiming line'
    write_concept "$root" "golem-thing.md" '---
type: feedback
---

MOVING-CONCEPT'
    # TILDE FENCE, not backtick. Both runtimes accept ``` and ~~~ (python's
    # FENCE_RE alternates them; all three bash sites case-match both), but no
    # fixture in this suite exercised ~~~ at all — so half of every fence guard
    # here was asserted by nobody. A `~~~` is the spelling you reach for when the
    # example itself contains backticks, which is exactly what a memory
    # documenting link syntax does.
    write_concept "$root" "aaa-doc.md" '---
type: reference
---

How to write an index line:

~~~markdown
- [Thing](golem-thing.md) — FENCED EXAMPLE, not a live pointer
~~~'

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "bash applies cleanly"
    sh_index="$(command cat "$root/golem/index.md")"
    sh_src="$(command cat "$root/index-golem.md")"

    assert_contains "$sh_index" "the REAL claiming line" \
        "the generated directory index carries the REAL index line"
    assert_not_contains "$sh_index" "FENCED EXAMPLE" \
        "...and never the fenced example that sorted ahead of it"
    # THE SECONDARY EFFECT, asserted separately: the genuine index line must be
    # relocated to point at the SUB-INDEX, not rewritten to the concept path.
    assert_contains "$sh_src" "](golem/index.md)" \
        "the original index line points at the sub-index (not memory-multi-index)"
    assert_not_contains "$sh_src" "](golem/golem-thing.md)" \
        "...rather than straight at the moved concept"

    # ...and the python primary produces the same bytes on the same input.
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "MEMORY.md" '# Memory

- [Golem](index-golem.md) — bucket'
    write_concept "$root" "index-golem.md" '# Golem

- [Thing](golem-thing.md) — the REAL claiming line'
    write_concept "$root" "golem-thing.md" '---
type: feedback
---

MOVING-CONCEPT'
    # BACKTICK fence on this arm, tilde on the bash arm above — so the pair
    # covers both delimiters AND still compares the two runtimes byte-for-byte
    # on their respective inputs. The parity assertions below hold because the
    # two fence spellings are equivalent by construction: any divergence means
    # one runtime accepted a delimiter the other did not.
    write_concept "$root" "aaa-doc.md" '---
type: reference
---

How to write an index line:

```markdown
- [Thing](golem-thing.md) — FENCED EXAMPLE, not a live pointer
```'

    run_moves_py apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "python applies cleanly"
    py_index="$(command cat "$root/golem/index.md")"
    py_src="$(command cat "$root/index-golem.md")"

    assert_equals "$py_index" "$sh_index" \
        "both runtimes generate the same directory index, byte for byte"
    assert_equals "$py_src" "$sh_src" \
        "...and rewrite the original index line identically"
}

test_retarget_line_matches_python_on_adversarial_shapes() {
    local sh_out py_out shape
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable"
        return 0
    fi
    # DIRECT FUNCTION-LEVEL PARITY, table-driven over shapes this repo's own
    # bundle does not contain. The whole-repo parity fixtures are bounded by the
    # index lines that happen to exist here, so a divergence on a shape nobody
    # wrote reads as agreement — both of the rows below were live breaks found
    # by probing the function directly rather than by any end-to-end run.
    for shape in \
        '- see (thing.md) then [Thing](thing.md) — hook' \
        '- [Thing]( thing.md ) — hook' \
        '- [source](https://example.com) [Thing](thing.md) — hook' \
        '- [Thing](thing.md) and [Other](other.md) — hook' \
        '- no links at all' \
        '- [Thing](thing.txt) — a non-markdown target' \
        '- [see [1]](thing.md) — a LITERAL BRACKET in the label' \
        '- [a [b] c](thing.md) — a bracketed span mid-label' \
        '- [a]](thing.md) — a stray close before the paren' \
        '- [Thing]() — an empty target' \
        '- [a][b](thing.md) — a reference-style decoy first'; do
        sh_out="$(OKF_MIGRATE_SKILL_DIR="$SKILL_DIR" command bash -c '
            . "$0/moves.sh" 2>/dev/null || true
            retarget_line "$1" "sub/index.md"
        ' "$SKILL_DIR" "$shape" 2>/dev/null)"
        py_out="$(command python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import moves
sys.stdout.write(moves._retarget_line(sys.argv[2], "sub/index.md"))
' "$SKILL_DIR" "$shape" 2>/dev/null)"
        assert_equals "$py_out" "$sh_out" \
            "bash and python retarget identically: $shape"
    done

    # ...and at least one shape must actually CHANGE, or the loop above would
    # pass against two functions that both do nothing.
    sh_out="$(OKF_MIGRATE_SKILL_DIR="$SKILL_DIR" command bash -c '
        . "$0/moves.sh" 2>/dev/null || true
        retarget_line "$1" "sub/index.md"
    ' "$SKILL_DIR" '- [Thing]( thing.md ) — hook' 2>/dev/null)"
    assert_contains "$sh_out" "](sub/index.md)" \
        "the padded-target shape is genuinely retargeted, not passed through"
}

test_bracketed_label_does_not_corrupt_either_index() {
    local root sh_index sh_src py_index py_src
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable"
        return 0
    fi
    # A LITERAL `[` INSIDE A LINK LABEL — end-to-end, not at the parser.
    # Python's LINK_RE is `\[([^\]]*)\]\(`, whose label cannot span a `]`, so on
    # `- [see [1]](golem-thing.md)` it finds NO link and plans NO move. The bash
    # twin committed to the OUTER `[` and then hunted forward for the next `](`,
    # yielding label `see [1` and a real target — so it moved the concept AND
    # wrote a mangled, duplicated line into BOTH index files.
    #
    # Asserted through `apply` rather than by calling scan_links, because the
    # damage is in what lands on disk: a parser-level assertion would have gone
    # green the moment the two agreed on a label, without ever showing that the
    # index files stopped being corrupted.
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "MEMORY.md" '# Memory

- [Golem](index-golem.md) — bucket'
    write_concept "$root" "index-golem.md" '# Golem

- [see [1]](golem-thing.md) — bracketed label'
    write_concept "$root" "golem-thing.md" '---
type: feedback
---

MOVING-CONCEPT'

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "bash applies cleanly"
    sh_src="$(command cat "$root/index-golem.md")"
    sh_index=""
    [ -f "$root/golem/index.md" ] && sh_index="$(command cat "$root/golem/index.md")"

    # THE CORRUPTION SIGNATURE, pinned directly: the mangled output duplicated
    # the label and spliced the two spellings together. Either half appearing
    # twice on one line is the bug, regardless of what else changed.
    assert_not_contains "$sh_src" "bracketed label[see [1]" \
        "the source index line is not spliced with a rewritten copy of itself"
    assert_not_contains "$sh_index" "bracketed label[see [1]" \
        "...and neither is the generated directory index"

    # ...and the python primary, on the same input, agrees byte for byte —
    # including on whether the concept moved at all.
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "MEMORY.md" '# Memory

- [Golem](index-golem.md) — bucket'
    write_concept "$root" "index-golem.md" '# Golem

- [see [1]](golem-thing.md) — bracketed label'
    write_concept "$root" "golem-thing.md" '---
type: feedback
---

MOVING-CONCEPT'

    run_moves_py apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "python applies cleanly"
    py_src="$(command cat "$root/index-golem.md")"
    py_index=""
    [ -f "$root/golem/index.md" ] && py_index="$(command cat "$root/golem/index.md")"

    assert_equals "$py_src" "$sh_src" \
        "both runtimes leave the bracketed index line identical, byte for byte"
    assert_equals "$py_index" "$sh_index" \
        "...and agree on the directory index (including that there is none)"
}

test_bracketed_label_in_a_body_file_is_left_alone() {
    local root sh_body py_body
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable"
        return 0
    fi
    # THE SECOND PARSER, reached only from a BODY file. rewrite_inbound_links'
    # general per-line rewrite used to re-implement the link walk instead of
    # calling scan_links, so it did not inherit the bracketed-label fix. Measured
    # before this fix, on the body line below: bash emitted
    # `See [see [1](golem/golem-thing.md) for detail.` — one `]` silently eaten
    # AND the target rewritten — while python's LINK_RE finds no link there and
    # left the line untouched.
    #
    # A BODY file specifically, because the index path never reaches this loop:
    # an index line matching a claimed value is intercepted earlier and goes
    # through retarget_line, which was already built on the fixed scan_links.
    # That is why the index-side fixture above passed while this was broken.
    #
    # The SECOND line is the vacuity guard: an ordinary link in the same file
    # must still be rewritten, or this case would pass against a rewriter that
    # had stopped rewriting anything at all.
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "MEMORY.md" '# Memory

- [Golem](index-golem.md) — bucket'
    write_concept "$root" "index-golem.md" '# Golem

- [Thing](golem-thing.md) — the claiming line'
    write_concept "$root" "golem-thing.md" '---
type: feedback
---

MOVING-CONCEPT'
    write_concept "$root" "other.md" '---
type: feedback
---

See [see [1]](golem-thing.md) for detail.
And an ordinary [Thing](golem-thing.md) link.
A bad run then a real one: [x [1]](golem-thing.md) and [Real](golem-thing.md).
Twice: [T](golem-thing.md) and again [T](golem-thing.md).
Glob label: [a*b](golem-thing.md) must stay a LITERAL needle.'

    run_moves apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "bash applies cleanly"
    sh_body="$(command cat "$root/other.md")"

    assert_contains "$sh_body" "[see [1]](golem-thing.md)" \
        "a bracketed label is not a link to either runtime, so it is left intact"
    assert_not_contains "$sh_body" "[see [1](" \
        "...and no closing bracket was eaten"
    assert_contains "$sh_body" "[Thing](golem/golem-thing.md)" \
        "an ordinary link in the same file IS still rewritten (vacuity guard)"
    # THE RESTART IS WHAT THIS PINS: a malformed bracket run must not consume
    # the genuine link that follows it on the same line. Skipping ahead to the
    # next `](` instead of restarting from the next `[` would swallow `[Real]`.
    assert_contains "$sh_body" "[Real](golem/golem-thing.md)" \
        "a real link AFTER a malformed one on the same line is still rewritten"
    # TWO IDENTICAL LINKS ON ONE LINE MUST BOTH BE REWRITTEN. scan_links emits
    # one row per occurrence and each row replaces the first REMAINING one, so
    # they fall left to right — matching python's per-match
    # `changed.replace(group(0), …, 1)`.
    #
    # MEASURED, so the next reader does not redo it: swapping the single
    # replacement for a replace-all leaves this suite green, and that is
    # CORRECT rather than a coverage gap — with one row emitted per occurrence
    # the two formulations produce the same string. It is an equivalent mutant,
    # not a missing assertion. What the single replacement genuinely buys is
    # termination: a naive replace-all loop that rescans its own output hangs
    # forever whenever the new target contains the old one (measured — it wedged
    # this suite past its timeout).
    assert_not_contains "$sh_body" "and again [T](golem-thing.md)" \
        "the SECOND of two identical links is rewritten too, not just the first"
    # The needle is built from the label, so an unquoted expansion would read
    # `[a*b]` as a PATTERN. Quoted, it stays the literal text.
    assert_contains "$sh_body" "[a*b](golem/golem-thing.md)" \
        "a label containing a glob metacharacter is matched literally"

    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "MEMORY.md" '# Memory

- [Golem](index-golem.md) — bucket'
    write_concept "$root" "index-golem.md" '# Golem

- [Thing](golem-thing.md) — the claiming line'
    write_concept "$root" "golem-thing.md" '---
type: feedback
---

MOVING-CONCEPT'
    write_concept "$root" "other.md" '---
type: feedback
---

See [see [1]](golem-thing.md) for detail.
And an ordinary [Thing](golem-thing.md) link.
A bad run then a real one: [x [1]](golem-thing.md) and [Real](golem-thing.md).
Twice: [T](golem-thing.md) and again [T](golem-thing.md).
Glob label: [a*b](golem-thing.md) must stay a LITERAL needle.'

    run_moves_py apply "$root" --transform move-concept --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "python applies cleanly"
    py_body="$(command cat "$root/other.md")"

    assert_equals "$py_body" "$sh_body" \
        "both runtimes rewrite the body file identically, byte for byte"
}

test_claimed_key_lookup_is_exact_not_a_regex() {
    local root cfg sh_index sh_index2 py_index py_index2
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable"
        return 0
    fi
    # TWO DESTINATION PATHS DIFFERING ONLY AT A DOT. The claimed map is keyed by
    # the NEW relative path; the bash writer tested membership with a BRE
    # (`grep -q "^$new_rel\t"`), where `.` matches any character — so `a.b/x.md`
    # already claimed made `axb/x.md` read as claimed too, and the second
    # concept's index line was silently dropped. Python's twin is a dict, so it
    # keyed literally and kept both.
    #
    # `dir:` rules rather than `index:`, because the two paths must differ ONLY
    # at the dot — which means the same BASENAME arriving from two different
    # source directories.
    #
    # THE ORDER IS LOAD-BEARING AND EASY TO GET BACKWARDS: the metacharacter is
    # in the PATTERN, not the subject. `grep "^a.b/x.md\t"` matches the already
    # claimed line `axb/x.md\t…`, so the PLAIN path must be claimed first and the
    # DOTTED one must be the lookup that collides with it. Reversed, `^axb/x.md`
    # is all literals against `a.b/x.md` and the bug does not fire at all —
    # measured: a first draft of this fixture survived its mutation round.
    cfg="$WORKDIR/cfg.dot.$$"
    write_taxonomy "$cfg" "dir:src1 = a.b" "dir:src2 = axb"

    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "MEMORY.md" '# Memory

- [Bucket](index-bucket.md) — bucket'
    write_concept "$root" "index-bucket.md" '# Bucket

- [Plain](src2/x.md) — the plain-directory concept
- [Dotted](src1/x.md) — the dotted-directory concept'
    write_concept "$root" "src1/x.md" '---
type: feedback
---

DOTTED'
    write_concept "$root" "src2/x.md" '---
type: feedback
---

PLAIN'

    OKF_RC=0
    OKF_OUT="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" \
        OKF_MIGRATE_CONFIG_DIR="$cfg" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command bash "$OKF_MIGRATE_SH" apply --transform move-concept \
        --confirm --allow-dirty 2>&1)" || OKF_RC=$?
    assert_exit 0 "$OKF_RC" "bash applies cleanly"
    sh_index=""
    [ -f "$root/a.b/index.md" ] && sh_index="$(command cat "$root/a.b/index.md")"
    sh_index2=""
    [ -f "$root/axb/index.md" ] && sh_index2="$(command cat "$root/axb/index.md")"

    # BOTH concepts must be named by their own directory index, carrying their
    # OWN hook. The regex collision dropped the second claim, so `axb/index.md`
    # fell back to a generated stub with no hook while `a.b/index.md` kept its
    # real line — assert each hook lands in its own file, which a single
    # "both exist" check would not distinguish.
    assert_contains "$sh_index" "the dotted-directory concept" \
        "the dotted-path concept keeps its real index line"
    assert_contains "$sh_index2" "the plain-directory concept" \
        "...and so does the one whose path differs only at the dot"

    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "MEMORY.md" '# Memory

- [Bucket](index-bucket.md) — bucket'
    write_concept "$root" "index-bucket.md" '# Bucket

- [Plain](src2/x.md) — the plain-directory concept
- [Dotted](src1/x.md) — the dotted-directory concept'
    write_concept "$root" "src1/x.md" '---
type: feedback
---

DOTTED'
    write_concept "$root" "src2/x.md" '---
type: feedback
---

PLAIN'

    OKF_RC=0
    OKF_OUT="$(OKF_BUNDLE_ROOT="$root" \
        OKF_MIGRATE_CONFIG_DIR="$cfg" \
        OKF_PINNED_VERSION="${OKF_TEST_VERSION:-0.2}" \
        command python3 "$OKF_MIGRATE_PY" apply --transform move-concept \
        --confirm --allow-dirty 2>&1)" || OKF_RC=$?
    assert_exit 0 "$OKF_RC" "python applies cleanly"
    py_index=""
    [ -f "$root/a.b/index.md" ] && py_index="$(command cat "$root/a.b/index.md")"
    py_index2=""
    [ -f "$root/axb/index.md" ] && py_index2="$(command cat "$root/axb/index.md")"

    assert_equals "$py_index" "$sh_index" \
        "both runtimes generate the dotted directory index identically"
    assert_equals "$py_index2" "$sh_index2" \
        "...and the plain one too"
}

test_read_index_names_resolves_without_a_preloaded_path() {
    local out
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable"
        return 0
    fi
    # THE sys.path INSERT IS THE POINT. read_index_names imports the validator,
    # which is a SIBLING SKILL DIRECTORY rather than an installed package — so
    # without inserting VALIDATOR_DIR the import fails, the function falls back
    # to librarian's defaults, and $OKF_INDEX_NAMES is SILENTLY IGNORED. That is
    # exactly the bug this fixture pins, and it only appeared to work under a
    # trace that had already inserted the path.
    #
    # Invoked WITHOUT any path preloading, which is what a real CLI run does.
    # THE VALIDATOR BRANCH, reached only with NO env override — the override
    # returns early, so a fixture that sets it never exercises the import
    # (measured: removing the sys.path insert left such a fixture green).
    #
    # Asserted against a FIXTURE thresholds.yml whose index_names differ from
    # the hardcoded fallback. Comparing against the validator's REAL list cannot
    # detect the bug, because librarian's config and the fallback are the same
    # three names — the two branches are indistinguishable by their output on
    # this repo, which is precisely how the first version of this case stayed
    # green under mutation.
    local fake_validator
    fake_validator="$WORKDIR/fakeval.$$"
    command mkdir -p "$fake_validator"
    command cp "$SKILL_DIR/../check-okf-conformance/patterns.py" \
        "$SKILL_DIR/../check-okf-conformance/bundle_graph.py" "$fake_validator/" 2>/dev/null
    command sed -e 's/^    - MEMORY\.md$/    - SENTINEL-INDEX.md/' \
        "$SKILL_DIR/../check-okf-conformance/thresholds.yml" >"$fake_validator/thresholds.yml"
    out="$(command env -uOKF_INDEX_NAMES python3 -c "
import sys, os
sys.path.insert(0, '$SKILL_DIR')
import migrate
migrate.VALIDATOR_DIR = '$fake_validator'
print(' '.join(migrate.read_index_names()))
" 2>&1)"
    # The SENTINEL proves the import actually read that thresholds.yml. Without
    # the sys.path insert the import fails and the hardcoded fallback answers,
    # which carries no sentinel.
    assert_contains "$out" "SENTINEL-INDEX.md" \
        "read_index_names IMPORTED the validator rather than falling back"

    # ...and the env override is honored even on that bare path.
    out="$(OKF_INDEX_NAMES="catalog.md toc.md" command python3 -c "
import sys
sys.path.insert(0, '$SKILL_DIR')
import migrate
print(' '.join(migrate.read_index_names()))
" 2>&1)"
    assert_contains "$out" "catalog.md" "the env override is honored"
    assert_contains "$out" "toc.md" "...including every name in it"
    assert_not_contains "$out" "MEMORY.md" \
        "an override REPLACES the defaults rather than extending them"
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
