#!/usr/bin/env bash
# okf-author / okf-librarian authoring-loop gate (issue #696, OKF slice F).
#
# Slice F is the only slice that changes what gets WRITTEN NEXT; every other
# slice reads or repairs. So the thing under test is an INSTRUCTION SURFACE, and
# the failure this gate exists to catch is drift between what the skill teaches
# and what the validator accepts -- which is silent by construction, because OKF
# §11/§12 forbid rejecting a bundle for a nested key or a broken link. Nothing
# goes red when the authoring path regresses; the corpus just drifts.
#
# THREE KINDS OF CHECK LIVE HERE, and they fail for different reasons:
#
#   1. CONTENT -- the skill states the floor (top-level `type`, markdown links)
#      and states it FIRST. Prose assertions, same posture as
#      tests/validate-memory-semantics.sh: they catch DELETION and DRIFT, not
#      whether a model obeys the text.
#   2. PARITY -- okf-author/thresholds.yml and check-okf-conformance's copy
#      agree on the keys they share. This duplication is FORCED (dev-core and
#      review-audit install independently), so it gets a gate instead of
#      silence. Skips on the 77 sentinel when review-audit is absent.
#   3. THE LOOP, EXERCISED -- author a memory in the shape the skill teaches and
#      run the real validator over it, asserting ZERO findings. AC5 says this
#      "must be exercised, not asserted", and it is the only check here that
#      would catch the skill teaching a shape the validator rejects.
#
# TWO TRAPS MEASURED WHILE WRITING THIS, both of which would make a green run
# meaningless:
#
#   patterns.sh TAKES A FILE LIST, NOT A BUNDLE PATH. Handed a path it warns
#   "scanning nothing" and still exits 0 -- so the loop-closing case would pass
#   against an empty scan, which is the #538/#571 silence-reads-as-a-pass shape.
#   assert_loop_scan_was_not_empty is the vacuity guard for exactly that.
#
#   THE CORPUS LEGITIMATELY STILL HAS THE OLD SHAPE. 248 of 253 live memories
#   nest `type` under `metadata:` and the bundle holds 502 wikilinks; migrating
#   them is #631/#671, deliberately NOT this issue. So the "no surviving
#   instruction" check reads INSTRUCTION SITES ONLY, never the bundle.
#
# CONTAINERS/ IS EXCLUDED EXPLICITLY, NOT INCIDENTALLY. The pinned submodule
# (update = none) ships its own copy of the old guidance in
# containers/docs/claude-code/skills-and-agents.md. It is out of scope by the
# submodule rule, and it is usually not even checked out -- which is a reason to
# name the exclusion rather than rely on it: a future `git submodule update`
# would otherwise turn this gate red for a file the repo must not edit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

SKILL="$REPO_ROOT/plugins/dev-core/skills/okf-author/SKILL.md"
CONFIG="$REPO_ROOT/plugins/dev-core/skills/okf-author/thresholds.yml"
METADATA="$REPO_ROOT/plugins/dev-core/skills/okf-author/metadata.yml"
AGENT="$REPO_ROOT/plugins/dev-core/agents/okf-librarian.md"
OKF_CONFIG="$REPO_ROOT/plugins/review-audit/skills/check-okf-conformance/thresholds.yml"
OKF_SCANNER="$REPO_ROOT/plugins/review-audit/skills/check-okf-conformance/patterns.sh"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

test_suite "okf-author + okf-librarian authoring loop (#696)"

# --- Helpers ----------------------------------------------------------------

# yaml_list KEY FILE -- the `- item` entries under a top-level or nested KEY,
# one per line, comments and blanks dropped.
#
# Parsed by field index with POSIX classes rather than a GNU-only shorthand
# class, which BSD awk/grep read as a LITERAL: the parser would return nothing,
# every comparison below would compare "" to "" and pass green. (The vacuity
# guards catch that anyway -- belt and braces, since a parity gate whose parser
# silently returns nothing is the exact shape this suite exists to prevent.)
yaml_list() {
    command awk -v want="$1" '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line == "" || substr(line, 1, 1) == "#") next
            if (line == want ":") { found = 1; next }
            if (found && substr(line, 1, 2) == "- ") {
                item = substr(line, 3)
                # STRIP AN INLINE COMMENT, THEN ONE LAYER OF QUOTES, mirroring
                # bundle_graph.read_config_list exactly. Without this the parser
                # returned `"*.md"` WITH its quote characters -- a value the real
                # consumer never sees -- so a parity comparison would be comparing
                # strings neither runtime uses, and a glob would never match.
                # Caught by the tier-routing test, which RUNS the globs.
                h = index(item, " #")
                if (h > 0) item = substr(item, 1, h - 1)
                sub(/^[[:space:]]+/, "", item)
                sub(/[[:space:]]+$/, "", item)
                q = sprintf("%c%c", 34, 39)
                while (length(item) > 0 && index(q, substr(item, 1, 1)) > 0)
                    item = substr(item, 2)
                while (length(item) > 0 && index(q, substr(item, length(item), 1)) > 0)
                    item = substr(item, 1, length(item) - 1)
                sub(/^[[:space:]]+/, "", item)
                sub(/[[:space:]]+$/, "", item)
                print item
                next
            }
            # Any other non-blank, non-comment line ends the list.
            if (found) found = 0
        }
    ' "$2"
}

# yaml_scalar KEY FILE -- the value of `KEY: value`, comment stripped.
yaml_scalar() {
    command awk -v want="$1" '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line == "" || substr(line, 1, 1) == "#") next
            c = index(line, ":")
            if (c > 1 && substr(line, 1, c - 1) == want) {
                v = substr(line, c + 1)
                sub(/[[:space:]]*#.*$/, "", v)
                sub(/^[[:space:]]+/, "", v)
                sub(/[[:space:]]+$/, "", v)
                print v
                exit
            }
        }
    ' "$2"
}

# skill_section NAME -- the body of a `## NAME` section, up to the next `## `.
# Section scope is what makes a placement assertion mean anything: a token three
# screens away satisfies a whole-file grep while telling the reader nothing.
skill_section() {
    command awk -v want="## $1" '
        $0 == want { inside = 1; next }
        inside && substr($0, 1, 3) == "## " { inside = 0 }
        inside { print }
    ' "$SKILL"
}

# --- 1. The skill states the floor, and states it first ---------------------

test_skill_exists_and_is_discoverable() {
    assert_file_exists "$SKILL" "okf-author/SKILL.md exists"
    assert_file_exists "$METADATA" "okf-author/metadata.yml exists"
    assert_file_exists "$CONFIG" "okf-author/thresholds.yml exists"
    assert_file_contains "$METADATA" "^name: okf-author$" \
        "metadata.yml name matches the skill directory"
    assert_file_contains "$SKILL" "^description: " \
        "SKILL.md carries the required description frontmatter"
    # A SKILL.md with no structural heading becomes a NEW check-ai-config
    # finding, which fails the scheduled ai-config-prescan job.
    # POSIX -E alternation via a direct grep: assert_file_contains uses a BRE
    # grep with no -E, where `\|` is a LITERAL on BSD and the assertion would
    # silently never match. Mirrors check-ai-config/patterns.sh's own heading set.
    local heads
    heads="$(command grep -cE \
        '^## (Workflow|Step|Phase|Categories|Conventions|Rules|Patterns|When to)' \
        "$SKILL" 2>/dev/null || true)"
    assert_true "[ \"${heads:-0}\" -gt 0 ]" \
        "SKILL.md has a structural heading (else ai-config-prescan reports a new finding)"
}

# AC1: the minimal floor is stated BEFORE any optional field. Order is the
# claim, not mere presence -- a skill that lists `title`/`description` first
# teaches an author to treat them as required, which is how a "floor" stops
# being one.
test_floor_is_stated_before_optional_fields() {
    local floor_line optional_line
    floor_line="$(command grep -n '^## The floor' "$SKILL" | command head -1 | command cut -d: -f1)"
    optional_line="$(command grep -n '^## Optional frontmatter' "$SKILL" | command head -1 | command cut -d: -f1)"

    assert_true "[ -n '$floor_line' ]" "SKILL.md has a '## The floor' section"
    assert_true "[ -n '$optional_line' ]" "SKILL.md has an optional-frontmatter section"
    assert_true "[ '$floor_line' -lt '$optional_line' ]" \
        "the floor is stated BEFORE any optional field (AC1)"

    local floor
    floor="$(skill_section "The floor")"
    assert_contains "$floor" "sole" \
        "the floor names \`type\` as the sole always-required key"
    assert_contains "$floor" "top-level" \
        "the floor says \`type\` is top-level"
}

# The skill must show the WRONG shape too. A skill that only shows the right
# frontmatter leaves a reader carrying the old directive with nothing to
# recognize -- the contradiction is the thing that has to be made visible.
test_skill_names_the_wrong_shape_explicitly() {
    local floor
    floor="$(skill_section "The floor")"
    assert_contains "$floor" "metadata:" \
        "the floor shows the WRONG nested-under-metadata shape as a counterexample"
    assert_contains "$floor" "WRONG" \
        "the counterexample is labelled, not left for the reader to infer"
}

# AC: link syntax. OKF §6.1 is markdown links; the skill must say so and must
# say `[[name]]` is not an OKF form.
test_skill_teaches_markdown_links() {
    local floor
    floor="$(skill_section "The floor")"
    assert_contains "$floor" "markdown link" \
        "the floor teaches standard markdown links (§6.1)"
    assert_contains "$floor" "bundle-relative" \
        "the floor names the recommended bundle-relative form"
    assert_contains "$floor" "not an OKF link form" \
        "the floor states plainly that [[name]] is not an OKF link form"
}

# The precedence rule. Without it a reader holding a contradicting
# harness-injected directive has no way to know which wins, and the directive --
# being in the system prompt -- wins by proximity.
test_skill_states_precedence_over_a_conflicting_directive() {
    assert_file_contains "$SKILL" "this skill wins" \
        "SKILL.md states it overrides a conflicting directive received elsewhere"
    local prec
    prec="$(skill_section "Precedence — read this first")"
    assert_contains "$prec" "Do not migrate" \
        "precedence section scopes the fix to the NEW file, not the existing corpus"
}

# AC7/AC8 routing must be taught, not only judged by the agent: an author who
# never calls the agent still needs the tier and index rules.
test_skill_teaches_pointer_and_tier() {
    local pointer tiers
    pointer="$(skill_section "The pointer — without it, nobody recalls this")"
    tiers="$(skill_section "Tiers — durable vs session state")"
    assert_contains "$pointer" "one index" \
        "the pointer section states one entry, one index"
    assert_contains "$tiers" "log.md" \
        "the tier section routes a dated record to log.md"
    assert_contains "$tiers" "session state" \
        "the tier section distinguishes durable lessons from session state"
}

# --- 2. Config, not convention (AC8) ---------------------------------------

# Every convention the skill applies must be a key an overriding repo can set.
# A hardcoded vocabulary would make the skill wrong everywhere but here.
test_conventions_are_configurable() {
    local key
    for key in type_vocabulary index_names body_requirements link_syntax \
        link_form naming_policy tiers; do
        # Two literal greps rather than BRE alternation: a key may sit at the
        # top level or nested one level, and `\|` would be a literal on BSD.
        local found=0
        command grep -q "^${key}:" "$CONFIG" 2>/dev/null && found=1
        command grep -q "^  ${key}:" "$CONFIG" 2>/dev/null && found=1
        assert_true "[ $found -eq 1 ]" \
            "thresholds.yml declares \`${key}\` as config"
    done

    # The skill must actually DEFER to the config rather than restating values.
    assert_file_contains "$SKILL" "configured" \
        "SKILL.md marks config-driven rules as configured"
    assert_file_contains "$SKILL" "thresholds.yml" \
        "SKILL.md points a reader at its config companion"
}

# A repo with a FOREIGN vocabulary must get correct guidance unchanged. The
# behavioral claim is that an unlisted type is still conformant -- so the skill
# has to say that, or an author with a foreign vocabulary reads the shortlist as
# a whitelist and picks a wrong-but-listed value.
test_foreign_vocabulary_still_gets_correct_guidance() {
    assert_file_contains "$SKILL" "still conformant" \
        "SKILL.md says a type outside the configured vocabulary is still conformant"
    assert_file_contains "$CONFIG" "EMPTY list means" \
        "thresholds.yml documents the empty-vocabulary (foreign bundle) behavior"
    assert_file_contains "$CONFIG" "registers NO types centrally" \
        "thresholds.yml grounds the no-central-vocabulary rule in §4.1"

    # The floor must NOT be configurable -- a repo that could configure away
    # top-level `type` would author non-conformant memories with this skill's
    # blessing.
    assert_file_contains "$CONFIG" "THE FLOOR IS NOT CONFIGURABLE" \
        "thresholds.yml states that the spec floor is not a config knob"
}

# --- 3. Parity with check-okf-conformance ----------------------------------

# The duplication is forced (independent plugins), so it is gated. Skips on the
# 77 sentinel when review-audit is absent rather than passing green -- a silent
# skip is indistinguishable from a pass (#538/#571).
test_config_parity_with_validator() {
    if [ ! -f "$OKF_CONFIG" ]; then
        skip_test "review-audit not installed — no validator config to hold parity with"
        return 0
    fi

    local mine theirs
    mine="$(yaml_list index_names "$CONFIG")"
    theirs="$(yaml_list index_names "$OKF_CONFIG")"
    # Vacuity guard: an empty parse would compare "" to "" and pass.
    assert_true "[ -n '$mine' ]" \
        "parity: okf-author index_names parses non-empty (vacuity guard)"
    assert_true "[ -n '$theirs' ]" \
        "parity: validator index_names parses non-empty (vacuity guard)"
    assert_equals "$theirs" "$mine" \
        "parity: index_names agrees with check-okf-conformance"

    mine="$(yaml_list body_requirements "$CONFIG")"
    theirs="$(yaml_list body_requirements "$OKF_CONFIG")"
    assert_true "[ -n '$mine' ]" \
        "parity: okf-author body_requirements parses non-empty (vacuity guard)"
    assert_true "[ -n '$theirs' ]" \
        "parity: validator body_requirements parses non-empty (vacuity guard)"
    assert_equals "$theirs" "$mine" \
        "parity: body_requirements agrees with check-okf-conformance"

    # The version the guidance targets must be the version the validator pins,
    # or the skill teaches a shape the scanner does not check.
    mine="$(yaml_scalar pinned_version "$CONFIG")"
    theirs="$(yaml_scalar pinned_version "$OKF_CONFIG")"
    assert_true "[ -n '$theirs' ]" \
        "parity: validator pinned_version parses non-empty (vacuity guard)"
    assert_equals "$theirs" "$mine" \
        "parity: okf.pinned_version agrees with check-okf-conformance"

    # naming_policy and the tier lists are duplicated TOO, and were omitted from
    # this gate's first version -- which made check-okf-conformance's own comment
    # ("tests/validate-okf-authoring.sh holds the two copies in parity") only half
    # true for `tiers`. Every key that exists on both sides is compared, or the
    # gate's promise is narrower than its prose.
    mine="$(yaml_scalar naming_policy "$CONFIG")"
    theirs="$(yaml_scalar naming_policy "$OKF_CONFIG")"
    assert_true "[ -n '$mine' ]" \
        "parity: okf-author naming_policy parses non-empty (vacuity guard)"
    assert_true "[ -n '$theirs' ]" \
        "parity: validator naming_policy parses non-empty (vacuity guard)"
    assert_equals "$theirs" "$mine" \
        "parity: naming_policy agrees with check-okf-conformance"

    mine="$(yaml_list long_term "$CONFIG")"
    theirs="$(yaml_list long_term "$OKF_CONFIG")"
    assert_true "[ -n '$mine' ]" \
        "parity: okf-author tiers.long_term parses non-empty (vacuity guard)"
    assert_true "[ -n '$theirs' ]" \
        "parity: validator tiers.long_term parses non-empty (vacuity guard)"
    assert_equals "$theirs" "$mine" \
        "parity: tiers.long_term agrees with check-okf-conformance"

    mine="$(yaml_list short_term "$CONFIG")"
    theirs="$(yaml_list short_term "$OKF_CONFIG")"
    assert_true "[ -n '$mine' ]" \
        "parity: okf-author tiers.short_term parses non-empty (vacuity guard)"
    assert_true "[ -n '$theirs' ]" \
        "parity: validator tiers.short_term parses non-empty (vacuity guard)"
    assert_equals "$theirs" "$mine" \
        "parity: tiers.short_term agrees with check-okf-conformance"
}

# The parity parser must FIRE on a divergence, not merely agree today. Without
# this, a parser that returned the same wrong thing for both files would pass.
test_parity_check_detects_divergence() {
    local fake="$WORKDIR/divergent.yml"
    {
        echo "index_names:"
        echo "  - toc.md"
    } >"$fake"

    local mine theirs
    mine="$(yaml_list index_names "$fake")"
    theirs="$(yaml_list index_names "$CONFIG")"
    assert_true "[ -n '$mine' ]" "negative fixture parses non-empty"
    assert_true "[ \"$mine\" != \"$theirs\" ]" \
        "the parity comparison distinguishes a divergent index_names list"
}

# --- 4. No surviving old instruction (AC3) --------------------------------

# INSTRUCTION SITES ONLY. The live bundle legitimately still carries the old
# shape (248 metadata.type files, 502 wikilinks) -- migrating it is #631/#671.
# Grepping the corpus here would assert the opposite of the truth.
#
# containers/ is excluded EXPLICITLY: the pinned submodule ships its own copy of
# the old guidance, is out of scope by the submodule rule, and is often not even
# checked out. Naming the exclusion means a future submodule bump cannot
# silently turn this red.
test_no_surviving_authoring_instruction() {
    assert_true "[ ! -d '$REPO_ROOT/plugins/dev-core/skills/memory-conventions' ]" \
        "the superseded memory-conventions skill is gone from the discovery path"

    local hits
    # ANY INSTRUCTION TO NEST `type` UNDER `metadata:`, matched in the shape it
    # ACTUALLY TAKES -- a `metadata:` line followed by an indented `type:` line.
    #
    # THIS USED TO GREP THE DOTTED TOKEN `metadata.type`, AND WAS VACUOUS. Real
    # YAML never writes that token: the shape is two lines, `metadata:` then
    # `  type: <value>`. Measured on the tree at the time: `grep -rn
    # 'metadata\.type' plugins README.md CLAUDE.md` returned ZERO hits -- including
    # inside this skill's own counterexample, which the old pattern was supposedly
    # tolerating. So the assertion could only ever fire on someone writing the
    # unusual dotted spelling by hand, never on the regression it claims to guard.
    #
    # It also passed a mutation test deceptively: mutating the skill to say
    # "metadata.type" fired it, because that mutation used the dotted spelling the
    # grep looks for. Mutating in the REAL yaml shape did NOT fire. The fixture has
    # to be the shape the defect actually takes, or the mutation proves nothing.
    #
    # `awk` over each candidate file rather than grep: the condition spans two
    # lines, which a per-line grep cannot express. The bundle itself is NOT walked
    # (248 memories legitimately carry the old shape until #631/#671 migrate them),
    # and containers/ is out of scope per the header note.
    hits="$(command find "$REPO_ROOT/plugins" -name '*.md' -type f 2>/dev/null |
        command grep -v '/docs/verification/' |
        while IFS= read -r f; do
            command awk -v F="$f" '
                # A `# WRONG`-marked block is a deliberate counterexample: the
                # skill must be able to SHOW the bad shape in order to reject it.
                #
                # THE WORD BOUNDARY IS LOAD-BEARING, AND ITS CLASS IS NARROW ON
                # PURPOSE. Without any boundary the marker matched by PREFIX, so
                # `# WRONGDOING` silenced a real block. A blanket `[^A-Za-z]` then
                # fixed the letter case but still admitted `# WRONG-ish` and
                # `# WRONG2`, because a hyphen or digit CONTINUES a compound word
                # just as well as a letter does (measured: both exempted). So the
                # class is whitespace, end-of-line, or the punctuation the real
                # marker actually uses -- note the em dash is covered by the
                # whitespace that precedes it in `# WRONG — ...`. Measured in a sandbox: the
                # unboundaried pattern emitted nothing for a genuine regression
                # sitting under `# WRONGDOING: unrelated topic`. Both awk copies
                # below carry the boundary; a fixture pins it.
                # Keyed to the MARKER, not to the filename -- exempting the whole
                # file would let the skill itself regress into teaching the shape
                # while the gate stayed green (measured: it did).
                /^[[:space:]]*#[[:space:]]*WRONG([[:space:]]|$|:|\.|,)/ { wrong = NR }
                /^[[:space:]]*metadata:[[:space:]]*$/ { seen = NR; next }
                seen && NR <= seen + 3 &&
                    /^[[:space:]]+(type|status|stale_after|stale_check):/ {
                        if (!(wrong && seen <= wrong + 4))
                            print F ":" NR ": " $0
                        seen = 0
                    }
            ' "$f"
        done || true)"
    assert_equals "" "$hits" \
        "no instruction surface teaches the nested metadata: type: shape (AC3)"

    # THE SKILL'S OWN COUNTEREXAMPLE IS THE LEAK FIXTURE, and it must be the ONLY
    # exempted site. Asserting merely that `hits` is empty would also pass if the
    # detector matched nothing at all, so prove the detector SEES the one instance
    # that legitimately exists -- the labelled WRONG block in okf-author/SKILL.md.
    local self
    self="$(command awk '
        /^[[:space:]]*metadata:[[:space:]]*$/ { seen = NR; next }
        seen && NR <= seen + 3 && /^[[:space:]]+type:/ { print NR; seen = 0 }
    ' "$SKILL")"
    assert_true "[ -n '$self' ]" \
        "AC3 detector is live: it finds the skill's own labelled counterexample (vacuity guard)"

    # ...and the MARKER is what exempts it, not the filename. The same block with
    # the marker stripped must be REPORTED -- otherwise the exemption is a blanket
    # mute and a regression INSIDE the skill passes, which is measurably what a
    # filename-scoped `grep -v` did.
    local unmarked probe
    probe="$WORKDIR/unmarked.md"
    {
        command printf -- '---\n'
        command printf -- 'metadata:\n'
        command printf -- '  type: feedback\n'
        command printf -- '---\n'
    } >"$probe"
    unmarked="$(command awk -v F="$probe" '
        /^[[:space:]]*#[[:space:]]*WRONG([[:space:]]|$|:|\.|,)/ { wrong = NR }
        /^[[:space:]]*metadata:[[:space:]]*$/ { seen = NR; next }
        seen && NR <= seen + 3 &&
            /^[[:space:]]+(type|status|stale_after|stale_check):/ {
                if (!(wrong && seen <= wrong + 4)) print F ":" NR ": " $0
                seen = 0
            }
    ' "$probe")"
    assert_true "[ -n '$unmarked' ]" \
        "AC3 detector fires on an UNMARKED nested block (the exemption is the marker, not the file)"

    # A FALSE MARKER MUST NOT SILENCE A REAL BLOCK. `# WRONGDOING` merely STARTS
    # with the marker's letters; without a word boundary the exemption matched it
    # by prefix and muted a genuine regression 4 lines below (measured). This is
    # the leak fixture for the boundary.
    local falsemarker
    probe="$WORKDIR/false-marker.md"
    {
        command printf -- '# WRONGDOING: an unrelated comment, not a counterexample\n'
        command printf -- 'Some prose.\n'
        command printf -- 'metadata:\n'
        command printf -- '  type: feedback\n'
    } >"$probe"
    falsemarker="$(command awk -v F="$probe" '
        /^[[:space:]]*#[[:space:]]*WRONG([[:space:]]|$|:|\.|,)/ { wrong = NR }
        /^[[:space:]]*metadata:[[:space:]]*$/ { seen = NR; next }
        seen && NR <= seen + 3 &&
            /^[[:space:]]+(type|status|stale_after|stale_check):/ {
                if (!(wrong && seen <= wrong + 4)) print F ":" NR ": " $0
                seen = 0
            }
    ' "$probe")"
    assert_true "[ -n '$falsemarker' ]" \
        "AC3 exemption is word-bounded: '# WRONGDOING' does NOT silence a real nested block"

    # A HYPHEN OR A DIGIT CONTINUES A COMPOUND WORD too, so a blanket
    # `[^A-Za-z]` boundary was still evadable (measured: `# WRONG-ish` and
    # `# WRONG2` both exempted). Table-driven so each spelling fails on its own
    # row rather than collapsing into one pass/fail.
    local fake
    for fake in '# WRONG-ish: an unrelated note' '# WRONG2 numbered note' \
        '# WRONGLY documented elsewhere'; do
        probe="$WORKDIR/false-marker-variant.md"
        {
            command printf -- '%s\n' "$fake"
            command printf -- 'Some prose.\n'
            command printf -- 'metadata:\n'
            command printf -- '  type: feedback\n'
        } >"$probe"
        falsemarker="$(command awk -v F="$probe" '
            /^[[:space:]]*#[[:space:]]*WRONG([[:space:]]|$|:|\.|,)/ { wrong = NR }
            /^[[:space:]]*metadata:[[:space:]]*$/ { seen = NR; next }
            seen && NR <= seen + 3 &&
                /^[[:space:]]+(type|status|stale_after|stale_check):/ {
                    if (!(wrong && seen <= wrong + 4)) print F ":" NR ": " $0
                    seen = 0
                }
        ' "$probe")"
        assert_true "[ -n '$falsemarker' ]" \
            "AC3 boundary rejects a compound continuation: '$fake' does not exempt"
    done

    # ...and the GENUINE marker still exempts, or the boundary would have broken
    # the counterexample the skill legitimately needs to show.
    local realmarker
    probe="$WORKDIR/real-marker.md"
    {
        command printf -- '# WRONG — the concept reads as having no type at all\n'
        command printf -- 'metadata:\n'
        command printf -- '  type: feedback\n'
    } >"$probe"
    realmarker="$(command awk -v F="$probe" '
        /^[[:space:]]*#[[:space:]]*WRONG([[:space:]]|$|:|\.|,)/ { wrong = NR }
        /^[[:space:]]*metadata:[[:space:]]*$/ { seen = NR; next }
        seen && NR <= seen + 3 &&
            /^[[:space:]]+(type|status|stale_after|stale_check):/ {
                if (!(wrong && seen <= wrong + 4)) print F ":" NR ": " $0
                seen = 0
            }
    ' "$probe")"
    assert_equals "" "$realmarker" \
        "AC3 exemption still honors a GENUINE '# WRONG' marker (boundary did not over-tighten)"

    # The plugins tree must not INSTRUCT wikilink authoring. A mention is fine
    # where the text REJECTS the form, DOCUMENTS it as an opt-in config value, or
    # (in the validator) notes that a dangling one is tolerated -- all three are
    # descriptions, and the whole point of slice F is that the skill must be able
    # to name the wrong shape in order to reject it.
    #
    # Exemptions are keyed to a REASON PHRASE on the matching line, so a NEW bare
    # instruction elsewhere still fires. The alternative -- exempting whole files
    # -- would let the skill itself regress into teaching wikilinks.
    hits="$(command grep -rnE '\[\[name\]\]|\[\[slug\]\]|\[\[wiki' "$REPO_ROOT/plugins" 2>/dev/null |
        command grep -v 'not an OKF link form' |
        command grep -v 'non-conformant' |
        command grep -v 'tolerated' |
        command grep -v 'requires it' |
        command grep -v 'keeping every' |
        command grep -v 'link_syntax' || true)"
    assert_equals "" "$hits" \
        "no instruction surface tells an author to write [[wikilinks]]"
}

# The exclusion is a DELIBERATE, NAMED boundary -- pin it, so a future reader
# cannot mistake it for an oversight and a submodule bump cannot quietly change
# what this gate covers.
test_submodule_exclusion_is_explicit() {
    assert_file_contains "$SCRIPT_DIR/validate-okf-authoring.sh" \
        "CONTAINERS/ IS EXCLUDED EXPLICITLY" \
        "the gate states that containers/ is excluded on purpose"
    # The submodule is pinned `update = none`, which is what makes it out of
    # scope. If that ever changes, this gate's scope claim needs re-deciding.
    assert_file_contains "$REPO_ROOT/.gitmodules" "update = none" \
        "containers/ is still pinned (the reason the exclusion is legitimate)"
}

# --- 4b. Tier routing is EXERCISED, not asserted (AC: session-state -> log.md)

# tier_of PATH -- the tier the configured globs assign to a bundle-relative path,
# applying the documented precedence (short_term FIRST, first match wins).
#
# THIS IS THE MECHANICAL HALF OF THE ROUTING AC. Where a fact lands is a glob
# match on a path, with a stated precedence -- decidable without a model. So it is
# tested by RUNNING the decision over inputs and asserting the destination, not by
# grepping the skill for the word "log.md". The judgment half (is THIS fact
# durable or session state?) is inference-time and is NOT claimed here; see the
# residual note at the run_test line.
tier_of() {
    local rel="$1" pat
    while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        # shellcheck disable=SC2254 # intentional: a configured glob.
        case "$rel" in
            $pat)
                command printf 'short_term'
                return 0
                ;;
        esac
    done <<EOF
$(yaml_list short_term "$CONFIG")
EOF
    while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        # shellcheck disable=SC2254 # intentional: a configured glob.
        case "$rel" in
            $pat)
                command printf 'long_term'
                return 0
                ;;
        esac
    done <<EOF
$(yaml_list long_term "$CONFIG")
EOF
    command printf 'unmatched'
}

test_tier_routing_is_exercised() {
    # Vacuity guard first: an empty config would make every case "unmatched" and
    # the assertions below would pin nothing.
    local st lt
    st="$(yaml_list short_term "$CONFIG")"
    lt="$(yaml_list long_term "$CONFIG")"
    assert_true "[ -n '$st' ]" "tiers: short_term globs parse non-empty (vacuity guard)"
    assert_true "[ -n '$lt' ]" "tiers: long_term globs parse non-empty (vacuity guard)"

    # A session-state artifact BY PATH lands short-term -- the destination the AC
    # names, decided by running the rule rather than by quoting it.
    assert_equals "short_term" "$(tier_of 'tmp/next-issue-101.json')" \
        "tier: a session-state artifact under tmp/ routes short-term"
    # NOTE which glob actually decides this. In both `case` and fnmatch, `*` is
    # NOT path-segment-aware, so `tmp/*` ALREADY matches `tmp/scratch/x.md` and
    # the `tmp/**/*` entry is redundant for this input. Measured, both engines
    # agreeing on all six combinations. The assertion is still worth making --
    # nested session state must route short-term -- but the comment records that
    # `tmp/*` carries it, so nobody later "fixes" a redundant-looking glob and
    # assumes this case proved it.
    assert_equals "short_term" "$(tier_of 'tmp/scratch/measurement.md')" \
        "tier: a nested tmp/ path routes short-term (carried by tmp/*, not tmp/**/*)"

    # ISOLATE WHICH GLOB CARRIES IT, or the row above pins nothing: it passes
    # identically with `tmp/**/*` deleted, since `*` is not path-segment-aware in
    # either `case` or fnmatch (measured, both engines agreeing on all six
    # combinations). These two run the match against ONE pattern at a time.
    # Via a variable, not a literal subject: shellcheck SC2194 flags a constant
    # `case` word, and the fixture path is genuinely fixed here.
    local one probe_path
    probe_path='tmp/scratch/measurement.md'
    case "$probe_path" in
        tmp/*) one=yes ;;
        *) one=no ;;
    esac
    assert_equals "yes" "$one" \
        "tier: tmp/* ALONE already matches a nested path (so tmp/**/* is redundant here)"
    probe_path='tmp/notes.md'
    case "$probe_path" in
        tmp/**/*) one=yes ;;
        *) one=no ;;
    esac
    assert_equals "no" "$one" \
        "tier: tmp/**/* ALONE does NOT match a top-level tmp/ file (the two are not interchangeable)"

    # THE UNMATCHED BRANCH IS REACHABLE, and must never read as a pass. A path
    # matching no configured glob returns a third value, not a tier -- a caller
    # that treated `unmatched` as long-term would file session state as durable
    # knowledge. Exercised so the branch is not dead code.
    assert_equals "unmatched" "$(tier_of 'notes.txt')" \
        "tier: a path matching NO configured glob is 'unmatched', not a defaulted tier"

    # A durable lesson lands long-term.
    assert_equals "long_term" "$(tier_of 'grep-q-under-pipefail-inverts-a-match.md')" \
        "tier: a lesson-named concept at the root routes long-term"

    # PRECEDENCE IS LOAD-BEARING, and this is the case that proves it. The shipped
    # globs OVERLAP by construction (`*.md` long-term vs `tmp/*` short-term), so
    # `tmp/notes.md` matches BOTH. Without the documented short_term-first order
    # the answer flips, which is exactly the ambiguity the config comment calls
    # out. Asserting the overlapping input is what makes the order testable.
    assert_equals "short_term" "$(tier_of 'tmp/notes.md')" \
        "tier: an OVERLAPPING path resolves short-term (short_term is checked FIRST)"
}

# THE log.md DESTINATION ITSELF, exercised against the real validator.
#
# The AC says a session-state fact routes to `log.md`, "not to a new concept".
# WHICH fact is session state is the agent's judgment and is not testable here
# (see the residual note at the run_test line). But the DESTINATION half is
# mechanical and worth pinning: a dated record written to `log.md` must be
# accepted as a reserved file (OKF §9) and must NOT be demanded to carry a
# concept's `type`. If that were false, following the skill would produce a
# finding the author could not avoid, and the routing advice would be unusable.
test_log_md_destination_is_exercised() {
    if [ ! -f "$OKF_SCANNER" ]; then
        skip_test "review-audit not installed — no validator to route against"
        return 0
    fi
    local bundle list rows rc=0 f
    bundle="$WORKDIR/logdest"
    command mkdir -p "$bundle"
    command printf -- '---\ntype: reference\n---\n\nBody.\n' >"$bundle/kept.md"
    command printf -- '# Index\n\n- [Kept](kept.md) — x\n' >"$bundle/MEMORY.md"
    command printf -- '# Directory Update Log\n\n## 2026-09-11\n* **Update**: session state, recorded here rather than as a concept.\n' >"$bundle/log.md"
    list="$WORKDIR/logdest-files.txt"
    : >"$list"
    for f in "$bundle"/*.md; do command printf '%s\n' "$f" >>"$list"; done

    rows="$(OKF_BUNDLE_ROOT="$bundle" OKF_TODAY="2026-09-11" command bash "$OKF_SCANNER" "$list" 2>/dev/null)" || rc=$?
    assert_equals "0" "$rc" "log.md: the scanner ran cleanly"
    assert_equals "" "$rows" \
        "log.md: a dated session-state record is a RESERVED file, not an untyped concept"

    # COUNTER-FIXTURE: the same content as an ordinary concept file DOES fire.
    # Without it, the silence above could equally mean the scanner read nothing.
    local bad badlist badrows
    bad="$WORKDIR/logdest-bad"
    command mkdir -p "$bad"
    command printf -- '# Index\n\n- [Notes](session-notes.md) — x\n' >"$bad/MEMORY.md"
    command printf -- '# Session notes\n\n## 2026-09-11\n* **Update**: same content, wrong destination.\n' >"$bad/session-notes.md"
    badlist="$WORKDIR/logdest-bad-files.txt"
    : >"$badlist"
    for f in "$bad"/*.md; do command printf '%s\n' "$f" >>"$badlist"; done
    badrows="$(OKF_BUNDLE_ROOT="$bad" OKF_TODAY="2026-09-11" command bash "$OKF_SCANNER" "$badlist" 2>/dev/null || true)"
    assert_contains "$badrows" "okf-unparseable-frontmatter" \
        "log.md counter: the SAME record as a concept file DOES fire (the check can fail)"
}



# AC6 -- WHAT THIS DOES AND DOES NOT ASSERT. Read this before strengthening it.
#
# The AC asks for "a fixture where the fact is already covered, and the agent
# updates rather than creating a near-duplicate". That is an INFERENCE-TIME
# judgment: the rule turns on whether two memories state "the same lesson with the
# same trigger", which no shell fixture can decide. Slice C hit the identical wall
# and resolved it the same way -- tests/validate-memory-semantics.sh gates
# audit-memory's CONTRACT and says outright it "cannot verify that the LLM obeys
# them".
#
# So this asserts a WEAKER BUT REAL property, not a dressed-up presence check: the
# decision rule is TOTAL. Every case an author can be in -- trigger matches,
# trigger differs, genuinely ambiguous -- has a stated verdict, so the agent is
# never left to improvise. An incomplete rule is a live defect class (the
# ambiguous branch is the one most often missing, and it is where duplicates come
# from); a missing branch would pass any grep for "Update, or create".
#
# WHAT IS NOT COVERED: that the agent, given two real near-duplicates, actually
# returns `update`. That residual is stated in the PR body rather than implied to
# be fixed.
test_update_vs_create_rule_is_total() {
    local sec
    sec="$(command awk '
        $0 == "## 2. Update, or create?" { inside = 1; next }
        inside && substr($0, 1, 3) == "## " { inside = 0 }
        inside { print }
    ' "$AGENT")"
    local sec_lines
    sec_lines="$(command printf '%s\n' "$sec" | command wc -l | command tr -d ' ')"
    assert_true "[ \"$sec_lines\" -gt 5 ]" \
        "AC6: the update-vs-create section parses non-empty (vacuity guard)"

    # Branch 1 -- same trigger => update.
    assert_contains "$sec" "same trigger" \
        "AC6: the UPDATE branch is keyed to the trigger matching"
    # Branch 2 -- trigger differs => create, stated as its own verdict.
    assert_contains "$sec" "trigger differs" \
        "AC6: the CREATE branch is keyed to the trigger differing"
    # Branch 3 -- the one most often missing. Without a stated tie-break the agent
    # improvises on exactly the inputs where duplicates are born.
    assert_contains "$sec" "prefer update" \
        "AC6: the AMBIGUOUS case has a stated tie-break (no uncovered input)"
    # And the rule must say a decline is still reported, or a rejected candidate
    # vanishes and the next session repeats the search.
    assert_contains "$sec" "still a deliverable" \
        "AC6: a declined candidate must be reported, not dropped"
}

# --- 5. The loop closes, exercised (AC5) ----------------------------------

LOOP_ROWS=""
LOOP_RC=0
LOOP_SCANNED=""

# Author a memory by FOLLOWING the skill, then run the real validator over it.
# This is the only check here that catches the skill teaching a shape the
# validator rejects.
run_loop_scan() {
    local bundle="$WORKDIR/bundle"
    command mkdir -p "$bundle"

    # Written to the skill's rules: top-level `type` from the configured
    # vocabulary, a bundle-relative markdown link, and the `**Why:**` /
    # `**How to apply:**` body sections body_requirements asks of `feedback`.
    command cat >"$bundle/example-lesson.md" <<'MEM'
---
type: feedback
title: Example lesson
description: One-line summary used by index generators.
status: stable
---

The fact, stated once.

**Why:** the reason it matters.

**How to apply:** the action to take next time.

Related: [another lesson](/other-lesson.md).
MEM

    # The index carries the pointer, and carries NO frontmatter (§8).
    command cat >"$bundle/MEMORY.md" <<'IDX'
# Memory index

- [Example lesson](example-lesson.md) — the hook a future session reads
IDX

    # THE FILE LIST IS THE INPUT, not the bundle path. Handed a path, the
    # scanner warns "scanning nothing" and still exits 0 -- which would make a
    # zero-findings assertion meaningless.
    local list="$WORKDIR/loop-files.txt"
    : >"$list"
    local f
    for f in "$bundle"/*.md; do printf '%s\n' "$f" >>"$list"; done
    LOOP_SCANNED="$(command wc -l <"$list" | command tr -d ' ')"

    LOOP_RC=0
    LOOP_ROWS="$(OKF_BUNDLE_ROOT="$bundle" OKF_TODAY="2026-09-10" \
        command bash "$OKF_SCANNER" "$list" 2>/dev/null)" || LOOP_RC=$?
}

test_authored_memory_passes_the_validator() {
    if [ ! -x "$OKF_SCANNER" ] && [ ! -f "$OKF_SCANNER" ]; then
        skip_test "review-audit not installed — no validator to close the loop against"
        return 0
    fi
    run_loop_scan

    # Vacuity guard FIRST: a scan that read nothing reports nothing, and
    # "nothing" would otherwise read as conformant.
    assert_equals "2" "$LOOP_SCANNED" \
        "loop: the scanner was handed both bundle files (vacuity guard)"
    assert_equals "0" "$LOOP_RC" "loop: the validator ran cleanly (exit 0)"
    assert_equals "" "$LOOP_ROWS" \
        "loop: a memory authored per the skill yields ZERO findings (AC5)"
}

# The loop-closing check must be able to FAIL. Same fixture, authored the OLD
# way -- if this does not produce findings, the check above proves nothing.
test_loop_check_fires_on_the_old_shape() {
    if [ ! -f "$OKF_SCANNER" ]; then
        skip_test "review-audit not installed — cannot exercise the counter-fixture"
        return 0
    fi
    local bundle="$WORKDIR/old-bundle"
    command mkdir -p "$bundle"
    command cat >"$bundle/old-lesson.md" <<'MEM'
---
name: old-lesson
description: Authored the pre-OKF way.
metadata:
  type: feedback
---

The fact, stated once.
MEM
    local list="$WORKDIR/old-files.txt"
    printf '%s\n' "$bundle/old-lesson.md" >"$list"

    local rows rc=0
    rows="$(OKF_BUNDLE_ROOT="$bundle" OKF_TODAY="2026-09-10" \
        command bash "$OKF_SCANNER" "$list" 2>/dev/null)" || rc=$?
    assert_equals "0" "$rc" "counter-fixture: the scanner reports rather than rejects (§11)"
    assert_contains "$rows" "okf-missing-type" \
        "counter-fixture: the OLD nested shape DOES produce a finding (the check can fail)"
}

# --- 6. The agent: judgment half, packaging, and its restrictions ---------

test_agent_is_flat_and_named() {
    assert_file_exists "$AGENT" "flat agents/okf-librarian.md exists"
    assert_true "[ ! -d '$REPO_ROOT/plugins/dev-core/agents/okf-librarian' ]" \
        "no nested agents/okf-librarian/ dir (silently undiscovered)"
    assert_file_contains "$AGENT" "^name: okf-librarian$" \
        "agent name matches its filename"
    assert_file_contains "$AGENT" "^model: " "agent declares a model"
    assert_file_contains "$AGENT" "^tools: " "agent declares its tools"
}

# AC6/AC7: the four judgment calls the issue names must each be present.
test_agent_makes_the_four_calls() {
    assert_file_contains "$AGENT" "Durable, or session state" \
        "agent decides durable vs session state (AC7)"
    assert_file_contains "$AGENT" "Update, or create" \
        "agent makes the update-vs-create call (AC6)"
    assert_file_contains "$AGENT" "Which index" \
        "agent picks the index and the hook"
    assert_file_contains "$AGENT" "What should it link to" \
        "agent decides what to link"
    assert_file_contains "$AGENT" "prefer update" \
        "agent resolves the ambiguous case toward update rather than duplicating"
}

# AC9: never emit memory content into an issue body. The bundle holds
# operator-specific notes and, in a consuming repo, material never seen here.
test_agent_never_emits_memory_content_to_an_issue() {
    assert_file_contains "$AGENT" "issue" \
        "agent's restrictions mention issue output"
    local restrictions
    restrictions="$(command awk '
        $0 == "## Restrictions" { inside = 1; next }
        inside && substr($0, 1, 3) == "## " { inside = 0 }
        inside { print }
    ' "$AGENT")"
    assert_contains "$restrictions" "PR body" \
        "restrictions cover PR bodies and comments, not just issues (AC9)"
    assert_contains "$restrictions" "never seen" \
        "restrictions state WHY: a consuming repo's bundle is unseen material"
}

# The advisory posture is held by TOOL GRANT, not by prose -- prose that says
# "recommends only" while holding Write is a promise, not a constraint.
test_agent_cannot_apply() {
    local tools
    tools="$(command sed -n 's/^tools:[[:space:]]*//p' "$AGENT" | command head -1)"
    assert_true "[ -n '$tools' ]" "agent tools line parses (vacuity guard)"
    assert_not_contains "$tools" "Write" \
        "advisory: agent holds no Write — a mutation stays the session's act"
    assert_not_contains "$tools" "Edit" \
        "advisory: agent holds no Edit"
    # Bash is the side channel that would make the two denials above prose again:
    # `> file`, `cp`, `git commit` all mutate without Write/Edit. Withholding it is
    # what lets the agent claim the posture is structural. Especially load-bearing
    # here because this agent reads bundle content, which in a consuming repo is
    # text this project has never seen — a prompt-injection payload must find no
    # shell to reach for.
    assert_not_contains "$tools" "Bash" \
        "advisory: agent holds no Bash — otherwise the Write/Edit denial is prose, not structure"
}

# Config-driven, same rule as the skill: a disabled judgment is disabled, never
# defaulted to this repo's taste.
test_agent_is_config_driven() {
    assert_file_contains "$AGENT" "thresholds.yml" \
        "agent reads its conventions from config"
    assert_file_contains "$AGENT" "disabled, not defaulted" \
        "agent disables a judgment whose config is absent rather than assuming"
    assert_file_contains "$AGENT" "okf-author" \
        "agent defers the SHAPE to the skill rather than restating it"
}

run_test test_skill_exists_and_is_discoverable "skill: exists, named, and structurally discoverable"
run_test test_floor_is_stated_before_optional_fields "skill: the floor is stated before any optional field (AC1)"
run_test test_skill_names_the_wrong_shape_explicitly "skill: the nested-metadata counterexample is labelled WRONG"
run_test test_skill_teaches_markdown_links "skill: markdown links per §6.1, and [[name]] named as non-OKF"
run_test test_skill_states_precedence_over_a_conflicting_directive "skill: it wins over a conflicting injected directive"
run_test test_skill_teaches_pointer_and_tier "skill: pointer-in-one-index and the tier split"
# The MECHANICAL half of the session-state routing AC. The judgment half -- whether
# a given FACT is durable or session state -- is decided at inference time by the
# agent and is NOT asserted here; see the PR body's stated residual.
run_test test_tier_routing_is_exercised "tier: glob precedence + the unmatched branch are RUN (not the log.md destination — see below)"
# AC6's update-vs-create decision is NOT behaviorally tested, and this is stated
# rather than papered over -- see the function's own comment for why, and the PR
# body for the residual.
# The MECHANICAL half of the log.md routing AC. Which FACT is session state stays
# the agent's inference-time judgment; see the PR body's stated residual.
run_test test_log_md_destination_is_exercised "log.md: a dated record is a reserved destination, not a concept"
run_test test_update_vs_create_rule_is_total "AC6 (partial): the update-vs-create rule is TOTAL — no uncovered case"
run_test test_conventions_are_configurable "config: every convention is an overridable key (AC8)"
run_test test_foreign_vocabulary_still_gets_correct_guidance "config: a foreign vocabulary gets correct guidance; the floor is not a knob"
run_test test_config_parity_with_validator "parity: shared keys agree with check-okf-conformance"
run_test test_parity_check_detects_divergence "parity: the comparison fires on a divergent list"
run_test test_no_surviving_authoring_instruction "AC3: no surviving instruction to write metadata.type or [[wikilinks]]"
run_test test_submodule_exclusion_is_explicit "AC3: the containers/ exclusion is deliberate and named"
run_test test_authored_memory_passes_the_validator "AC5: a memory authored per the skill scans with ZERO findings"
run_test test_loop_check_fires_on_the_old_shape "AC5 counter: the OLD shape does produce a finding"
run_test test_agent_is_flat_and_named "agent: flat packaging with a matching name"
run_test test_agent_makes_the_four_calls "agent: all four judgment calls present (AC6/AC7)"
run_test test_agent_never_emits_memory_content_to_an_issue "agent: never emits bundle content to an issue or PR (AC9)"
run_test test_agent_cannot_apply "agent: advisory by tool grant, not by prose"
run_test test_agent_is_config_driven "agent: conventions are config; absent config disables"

generate_report
