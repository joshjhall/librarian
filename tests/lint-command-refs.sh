#!/usr/bin/env bash
# Namespaced slash-command reference gate (issue #498).
#
# These plugins ship as a Claude Code plugin MARKETPLACE, so every invocable
# command is `/<plugin>:<skill>` — `/workflow:ship-issue`, never `/ship-issue`.
# Skill and agent markdown, however, used to refer to sibling commands by their
# bare name in 313 lines across 33 files. That matters because an agent reading a
# skill body echoes the form it saw: it tells the reader to type a command that
# does not resolve as installed. #498 swept the corpus; this gate is what stops
# the drift recurring on the next skill edit.
#
# WHITELIST, not blacklist. The gate discovers real skill names from
# plugins/<plugin>/skills/<name>/ and flags bare refs only for those names. A
# broad `/[a-z-]+` pattern would false-positive on ~20 legitimate prose slashes
# that exist in these files today (`/the`, `*/models.`, `>/journal.`,
# `+/critical)`, `/legacy`). Keying off the filesystem also exempts `/clear` (a
# built-in Claude Code command, 35 occurrences) for free, and — because only
# `skills/` is walked, never `agents/` — never treats an agent name (`checker`,
# `ci-fixer`, `audit-security`) as a slash command.
#
# The per-name regex is
#
#   (^|[^A-Za-z0-9_.-])/<name>([^A-Za-z0-9_/-]|$)
#
# Every member of both classes was checked by hand against the corpus; only
# these earn their place:
#   leading alphanumerics — exempt the common path fragment
#                           (`skills/ship-issue/workflow.js`): the `s` of
#                           `skills` is what makes it a non-match.
#   trailing `/`          — exempts a ref that opens a path (`/ship-issue/…`),
#                           which no leading-class member can catch.
#   trailing `-`          — exempts `/next-issue-queue.json` and
#                           `/next-issue-{N}.json`, the state files that must
#                           NEVER be rewritten to a namespaced form.
# A leading `/` exclusion is deliberately absent: it looks like what exempts
# path fragments, but the preceding alphanumeric already does that, and no
# `//<skill>` form exists in the corpus. Claiming it as load-bearing would be
# a comment that hides an unnecessary dependency.
#
# `:` is likewise NOT excluded in either class. An already-namespaced
# `/workflow:next-issue` is exempt because the `w` before the `/` is
# alphanumeric — the leading class alone handles it — so excluding `:` would buy
# nothing and would blind the gate to `see:/next-issue` and `/golem: it works`.
#
# LINE MODE, PER NAME — never a single alternation with `grep -o`. On
# `Chain /next-issue,/ship-issue in order.` the alternation+`-o` form returns
# only `/next-issue,`: the shared `,` boundary is consumed and the second ref
# vanishes. That collapse looks like a harmless optimization, so
# test_negative_case_fires plants a line specifically to catch it.
#
# Corpus: plugins/**/*.md plus the top-level README.md. Two exclusions, each
# asserted below rather than left to the `find` root:
#   CHANGELOG.md         — generated from conventional commits by git-cliff; its
#                          bare refs are historical release notes.
#   docs/verification/** — dated end-to-end transcripts. Gating them would force
#                          a report to disagree with its own session log: a
#                          VERIFIED-live block records the exact text a command
#                          printed at the time, and rewriting that falsifies the
#                          evidence. Exempt rather than enforced — which does NOT
#                          mean frozen: a DEFERRED AC's recipe is a command
#                          someone will run in the future and is kept current by
#                          hand. Enforcement can't tell those apart, which is
#                          precisely why this is a human call, not a gate.
#
# Judgment calls worth knowing about:
#   - Fenced code blocks are NOT exempt. The pipeline diagram and the `/golem`
#     usage block are instructional text that should carry the installed form.
#     The repo has no lint-ignore convention and this adds none.
#   - A markdown link target `[x](/next-issue)` IS flagged. None exist; in
#     plugin docs such a link is far likelier a mis-authored command ref than a
#     real root-relative URL.
#   - A ref with no leading slash ("run `next-issue` then `ship-issue`") is out
#     of scope by design: without the slash it is a name, not an invocation, and
#     gating it would collide with legitimate prose about the skills.
#   - The plugin half of the suggested fix comes from the DIRECTORY name, not
#     plugin.json's `name`. They agree today; validate-manifests.mjs is the
#     natural owner if that ever needs enforcing.
#
# Pure bash + coreutils; no node, no jq, no network. bash-3.2 clean (flat
# tab-separated index, no assoc arrays; `find` without GNU -printf).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This file's own path — test_unknown_name_degrades_not_aborts slices a real
# function body out of it, so the slice tracks edits instead of drifting.
SELF_PATH="$SCRIPT_DIR/$(command basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

# Cap on violation detail lines per file so a large regression stays readable.
MAX_DETAIL=40

test_suite "Namespaced slash-command refs (#498)"

# --- Discovery --------------------------------------------------------------

# collect_skills <plugins_dir> — emit one "<plugin>\t<skill>" line per skill.
# Two nested globs rather than `find -printf` (GNU-only; this must run on macOS,
# which is the whole point of lint-shell-portability.sh). A skills/<d>/ without a
# SKILL.md is skipped as a guard — every skill has one today, and
# test_corpus_non_empty pins the resulting count.
collect_skills() {
    local plugins_dir="$1"
    local pdir sdir plugin skill
    shopt -s nullglob
    for pdir in "$plugins_dir"/*/; do
        plugin="$(command basename "$pdir")"
        for sdir in "$pdir"skills/*/; do
            [ -f "${sdir}SKILL.md" ] || continue
            skill="$(command basename "$sdir")"
            command printf '%s\t%s\n' "$plugin" "$skill"
        done
    done
    shopt -u nullglob
}

SKILL_INDEX="$(collect_skills "$PLUGINS_DIR")"
SKILL_NAMES="$(command printf '%s\n' "$SKILL_INDEX" | command cut -f2 | command sort -u)"

# plugin_for_skill <name> — the plugin owning <name>, or empty. Used only to
# render the suggested fix, so a lookup miss must degrade the MESSAGE and never
# the detection.
#
# The trailing `|| true` is load-bearing, not defensive noise. On a miss `grep`
# exits 1, and under this file's `set -euo pipefail` that becomes the pipeline's
# status (head/cut both succeed, so grep is the rightmost non-zero). The call
# site is a bare `plugin="$(plugin_for_skill "$name")"` assignment — not an `if`
# condition and not part of `&&`/`||`, so `set -e` is NOT suspended there and a
# non-zero pipeline would kill the whole gate mid-scan, silently skipping every
# remaining per-file test. That is the opposite of degrading. Dormant today
# (callers only pass names drawn from SKILL_INDEX), but `scan_file` deliberately
# accepts an arbitrary `names` list, so a future fixture would trip it.
plugin_for_skill() {
    command printf '%s\n' "$SKILL_INDEX" |
        command grep -E "	$1\$" |
        command head -1 |
        command cut -f1 || true
}

# --- Scan -------------------------------------------------------------------

# scan_file <path> [names]
# Populates CUR_VIOLATIONS with one "<path>:<line>: /<name> -> /<plugin>:<name>"
# entry per bare ref (empty when the file is clean). `names` is a
# newline-separated list, defaulting to every discovered skill — parameterizing
# it lets the negative fixture drive this exact function without materializing a
# fake plugins/ tree.
CUR_FILE=""
CUR_VIOLATIONS=""
scan_file() {
    local file="$1"
    local names="${2:-$SKILL_NAMES}"
    CUR_VIOLATIONS=""
    local name re entry lineno plugin rel suggest
    rel="${file#"$REPO_ROOT"/}"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        # Skill names come from the filesystem and are [a-z0-9-] in practice.
        # Refuse anything else so a stray directory name can never inject ERE
        # metacharacters into the pattern below.
        case "$name" in
            *[!a-z0-9-]*) continue ;;
        esac
        re="(^|[^A-Za-z0-9_.-])/${name}([^A-Za-z0-9_/-]|\$)"
        plugin="$(plugin_for_skill "$name")"
        suggest="/${plugin}:${name}"
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            lineno="${entry%%:*}"
            CUR_VIOLATIONS+="${rel}:${lineno}: /${name} -> ${suggest}"$'\n'
        done < <(command grep -nE "$re" "$file" 2>/dev/null || true)
    done <<EOF
$names
EOF
}

# --- Corpus -----------------------------------------------------------------

# Every markdown file under plugins/, plus the top-level README. CHANGELOG.md and
# docs/verification/** are excluded on purpose (see the header).
# README.md is REQUIRED, not best-effort. The issue's AC covers README prose, so
# silently skipping a missing one would narrow the gate's corpus without saying
# so — the same false-green class as a discovery typo. Fail loudly instead.
collect_corpus() {
    command find "$PLUGINS_DIR" -type f -name '*.md' | command sort
    if [ ! -f "$REPO_ROOT/README.md" ]; then
        command printf 'lint-command-refs: README.md not found at %s\n' \
            "$REPO_ROOT/README.md" >&2
        return 1
    fi
    command printf '%s\n' "$REPO_ROOT/README.md"
}

CORPUS="$(collect_corpus)"

corpus_count() {
    command printf '%s\n' "$CORPUS" | command grep -c . || true
}

skill_count() {
    command printf '%s\n' "$SKILL_NAMES" | command grep -c . || true
}

# --- Tests ------------------------------------------------------------------

# build_detail <violations> — cap the reported lines at MAX_DETAIL and append a
# "… and N more" summary when truncating. Populates DETAIL_LINES (the array
# handed to _fail) and DETAIL_TOTAL.
#
# Split out of test_file_refs so the truncation branch can be driven directly. It
# fires on the real corpus today (one swept file carries 44 refs), so leaving the
# arithmetic untested would mean the number a reader sees has never been checked.
DETAIL_LINES=()
DETAIL_TOTAL=0
build_detail() {
    local violations="$1" line shown=0
    DETAIL_LINES=()
    DETAIL_TOTAL=0
    [ -n "$violations" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        DETAIL_TOTAL=$((DETAIL_TOTAL + 1))
        if [ "$shown" -lt "$MAX_DETAIL" ]; then
            DETAIL_LINES+=("$line")
            shown=$((shown + 1))
        fi
    done <<<"$violations"
    [ "$DETAIL_TOTAL" -gt "$shown" ] &&
        DETAIL_LINES+=("… and $((DETAIL_TOTAL - shown)) more")
    return 0
}

# Per-file body (reads CUR_FILE). One run_test per file keeps a failure
# attributable to the file that caused it.
test_file_refs() {
    scan_file "$CUR_FILE"
    if [ -n "$CUR_VIOLATIONS" ]; then
        build_detail "$CUR_VIOLATIONS"
        _fail "Bare slash-command ref(s) in $(command basename "$CUR_FILE") — use the /<plugin>:<skill> form" \
            "${DETAIL_LINES[@]}"
    fi
}

# Drives build_detail's truncation branch, which no fixture reaches otherwise
# (the negative fixture plants 16 lines against a MAX_DETAIL of 40).
test_detail_truncation() {
    local many="" i=1
    while [ "$i" -le 45 ]; do
        many="${many}f.md:${i}: /next-issue -> /workflow:next-issue"$'\n'
        i=$((i + 1))
    done

    build_detail "$many"
    assert_equals "45" "$DETAIL_TOTAL" "All 45 violations are counted"
    # MAX_DETAIL capped lines + 1 summary line.
    assert_equals "$((MAX_DETAIL + 1))" "${#DETAIL_LINES[@]}" \
        "Detail is capped at MAX_DETAIL plus one summary line"
    assert_equals "… and $((45 - MAX_DETAIL)) more" "${DETAIL_LINES[$MAX_DETAIL]}" \
        "The summary line reports the correct remainder"
    # The kept lines must be the FIRST MAX_DETAIL, in order.
    assert_equals "f.md:1: /next-issue -> /workflow:next-issue" "${DETAIL_LINES[0]}" \
        "Truncation keeps the first violation"
    assert_equals "f.md:${MAX_DETAIL}: /next-issue -> /workflow:next-issue" \
        "${DETAIL_LINES[$((MAX_DETAIL - 1))]}" \
        "Truncation keeps through the MAX_DETAIL'th violation"

    # Boundary: exactly MAX_DETAIL violations must NOT append a summary line.
    local exact="" j=1
    while [ "$j" -le "$MAX_DETAIL" ]; do
        exact="${exact}f.md:${j}: /golem -> /workflow:golem"$'\n'
        j=$((j + 1))
    done
    build_detail "$exact"
    assert_equals "$MAX_DETAIL" "${#DETAIL_LINES[@]}" \
        "Exactly MAX_DETAIL violations produce no summary line (off-by-one guard)"

    # And the empty case yields nothing at all.
    build_detail ""
    assert_equals "0" "${#DETAIL_LINES[@]}" "No violations produce no detail lines"
    assert_equals "0" "$DETAIL_TOTAL" "No violations produce a zero total"
}

# Pins plugin_for_skill's `|| true`. `scan_file` deliberately accepts an
# arbitrary `names` list, so it can be handed a name with no SKILL_INDEX entry.
# Without the guard, grep's exit-1 on the miss propagates through `pipefail` into
# the bare `plugin="$(...)"` assignment — which `set -e` does not exempt — and
# kills the whole gate mid-scan, silently skipping every remaining per-file test.
# The observable difference is that scan_file RETURNS and still reports the
# violation (with a degraded `/:<name>` suggestion) instead of aborting, so this
# test asserts both: that we got here at all, and that detection survived.
test_unknown_name_degrades_not_aborts() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command printf 'Run /not-a-real-skill and then /ship-issue.\n' >"$tmp/unknown.md"

    # A name absent from SKILL_INDEX, plus a real one AFTER it: if the miss
    # aborted, the real name would never be scanned and the run would die here.
    scan_file "$tmp/unknown.md" "not-a-real-skill
ship-issue"

    assert_not_empty "$CUR_VIOLATIONS" \
        "scan_file survives a name with no SKILL_INDEX entry (no set -e abort)"
    assert_contains "$CUR_VIOLATIONS" "/not-a-real-skill" \
        "The unknown name is still reported (detection did not degrade)"
    assert_contains "$CUR_VIOLATIONS" "/ship-issue -> /workflow:ship-issue" \
        "A name scanned AFTER the miss still resolves (the loop was not aborted)"

    # The assertions above CANNOT fail if the `|| true` is removed: run_test
    # invokes each body as `if "$test_func"`, and `set -e` is suspended inside an
    # `if` condition, so the abort is masked here. The real per-file scan runs at
    # TOP LEVEL, where it is not suspended.
    #
    # So reproduce that context: SLICE the real plugin_for_skill out of this file
    # and drive it in a fresh `bash` at top level. Slicing (rather than restating
    # the function) is what makes this non-vacuous — a re-typed copy would keep
    # passing after the guard was removed from the real definition, which is the
    # textual-test trap. Same idiom the repo uses to exercise pure helpers.
    local sliced="$tmp/sliced.sh"
    {
        command printf 'set -euo pipefail\n'
        command printf 'SKILL_INDEX="$(command printf %s)"\n' "'workflow\\tship-issue\\n'"
        command sed -n '/^plugin_for_skill() {$/,/^}$/p' "$SELF_PATH"
        command printf 'plugin="$(plugin_for_skill absent-name)"\n'
        command printf 'command printf "SURVIVED:[%%s]\\n" "$plugin"\n'
    } >"$sliced"

    # Guard the slice itself: an empty/failed extraction would make the probe
    # below pass for the wrong reason.
    assert_contains "$(command cat "$sliced")" "plugin_for_skill() {" \
        "The real plugin_for_skill was sliced out (probe is not vacuous)"

    local probe_out probe_rc=0
    probe_out="$(command bash "$sliced" 2>/dev/null)" || probe_rc=$?
    assert_equals "0" "$probe_rc" \
        "At top level (set -e live), a lookup miss must not abort the script"
    assert_contains "$probe_out" "SURVIVED:[]" \
        "The miss yields an empty plugin and execution continues past the assignment"
}

# The gate must actually inspect something. A bare non-empty check would pass if
# a path typo left exactly one skill discovered, so both counts are asserted
# against a floor with the real number in the message.
test_corpus_non_empty() {
    local skills files ge_skills=0 ge_files=0
    skills="$(skill_count)"
    files="$(corpus_count)"

    assert_not_empty "$SKILL_INDEX" "Skill discovery must find at least one skill"
    [ "$skills" -ge 30 ] && ge_skills=1
    assert_equals "1" "$ge_skills" \
        "At least 30 skills must be discovered (found $skills)"
    [ "$files" -ge 50 ] && ge_files=1
    assert_equals "1" "$ge_files" \
        "At least 50 markdown files must be in the corpus (found $files)"

    # Canaries from two different plugins: proves the per-plugin walk is not
    # collapsing to a single plugin.
    assert_contains "$SKILL_NAMES" "next-issue" "Discovery finds workflow's next-issue"
    assert_contains "$SKILL_NAMES" "codebase-audit" "Discovery finds review-audit's codebase-audit"
    # The plugin field must be populated, or the suggested fix would degrade to
    # `-> /:<name>` while still reporting a violation.
    assert_contains "$SKILL_INDEX" "workflow	ship-issue" \
        "SKILL_INDEX carries the plugin field (suggestion cannot degrade to /:<name>)"

    # plugin_for_skill is first-match-wins (`head -1`). Nothing in the repo
    # forbids two plugins shipping a same-named skill dir, and if that happened
    # the suggested fix would silently name the wrong plugin for the collided
    # skill. Assert the uniqueness the resolution depends on, so a future
    # collision is a loud failure here rather than a quietly wrong suggestion.
    # Read from SKILL_INDEX, NOT SKILL_NAMES: the latter is built with `sort -u`,
    # so a collision is already collapsed there and the check could never fire.
    local dupes
    dupes="$(command printf '%s\n' "$SKILL_INDEX" | command cut -f2 |
        command sort | command uniq -d)"
    assert_equals "" "$dupes" \
        "Skill names must be unique across plugins (plugin_for_skill is first-match-wins)"
}

# The exclusions are a tested decision, not an accident of the find root. If
# someone later widens the corpus they get a failure pointing at the header's
# reasoning instead of a pile of mystery violations.
test_exclusions_are_deliberate() {
    assert_not_contains "$CORPUS" "/docs/verification/" \
        "docs/verification/** is out of scope (dated e2e transcripts)"
    assert_not_contains "$CORPUS" "/CHANGELOG.md" \
        "CHANGELOG.md is out of scope (git-cliff-generated release notes)"
}

# Positive control. Every per-file test goes green on an EMPTY corpus, and would
# also go green if someone deleted the refs outright rather than namespacing
# them. This asserts the namespaced form is genuinely present in the real tree.
test_namespaced_form_present() {
    local hits
    hits="$(command grep -rl '/workflow:' "$PLUGINS_DIR" "$REPO_ROOT/README.md" \
        --include='*.md' 2>/dev/null || true)"
    assert_not_empty "$hits" \
        "The namespaced /workflow: form must appear in the corpus (refs namespaced, not deleted)"
}

# scan_namespaced <files> — the other drift direction: a ref that is correctly
# SHAPED but names the wrong plugin (`/dev-core:ship-issue`). The bare-ref scan
# is structurally blind to it, because such a ref is not bare.
#
# Extracted as its own function rather than inlined in the test so a fixture can
# drive its FAILURE branch. Left inline, the mismatch detection would only ever
# run against the real (clean) corpus, and a regression in the grep pattern or
# the plugin/skill split would keep the suite green while detecting nothing.
# Sets NS_DANGLING (one line per mismatch) and NS_CHECKED (refs examined).
NS_DANGLING=""
NS_CHECKED=0
scan_namespaced() {
    local files="$1"
    NS_DANGLING=""
    NS_CHECKED=0
    local ref plugin skill file
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        plugin="${ref%%:*}"
        plugin="${plugin#/}"
        skill="${ref##*:}"
        NS_CHECKED=$((NS_CHECKED + 1))
        [ -d "$PLUGINS_DIR/$plugin/skills/$skill" ] && continue
        NS_DANGLING="${NS_DANGLING}${ref} -> no plugins/${plugin}/skills/${skill}/"$'\n'
    done < <(while IFS= read -r file; do
        [ -n "$file" ] || continue
        command grep -ohE '/(dev-core|review-audit|workflow):[a-z0-9-]+' "$file" 2>/dev/null || true
    done <<<"$files" | command sort -u)
}

test_namespaced_refs_resolve() {
    scan_namespaced "$CORPUS"
    if [ -n "$NS_DANGLING" ]; then
        local detail=() line
        while IFS= read -r line; do
            [ -n "$line" ] && detail+=("$line")
        done <<<"$NS_DANGLING"
        _fail "Namespaced ref(s) naming a plugin that does not own the skill" "${detail[@]}"
    fi
    # A zero-ref result would make this vacuously green; the positive control
    # above already proves refs exist, so assert this pass saw some too.
    local saw=0
    [ "$NS_CHECKED" -gt 0 ] && saw=1
    assert_equals "1" "$saw" \
        "Namespaced refs were found to resolve (check is not vacuous; examined $NS_CHECKED)"
}

# Proves scan_namespaced's mismatch branch actually fires. Without this the
# wrong-plugin detection is happy-path-only — exactly the gap
# test_negative_case_fires closes for the bare-ref branch.
test_namespaced_mismatch_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/mismatch.md" <<'EOF'
Correct: /workflow:ship-issue delivers the work.
Wrong plugin: /dev-core:ship-issue does not exist.
Also wrong: /workflow:codebase-audit lives in review-audit.
EOF

    scan_namespaced "$tmp/mismatch.md"

    assert_not_empty "$NS_DANGLING" "scan_namespaced flags a wrong-plugin ref (mismatch branch fires)"
    assert_contains "$NS_DANGLING" "/dev-core:ship-issue" \
        "A skill attributed to the wrong plugin is flagged"
    assert_contains "$NS_DANGLING" "/workflow:codebase-audit" \
        "A review-audit skill attributed to workflow is flagged"
    assert_not_contains "$NS_DANGLING" "/workflow:ship-issue " \
        "The correctly-attributed ref is NOT flagged"
    local saw=0
    [ "$NS_CHECKED" -ge 3 ] && saw=1
    assert_equals "1" "$saw" "All three planted refs were examined (found $NS_CHECKED)"
}

# Negative case: the violation branch must fire on every bare form, and every
# exemption must NOT fire. Without this, a regression in the regex or the
# per-name loop would report PASS while enforcing nothing.
#
# Needles are `:<line>: ` prefixes rather than `/next-issue`, because that token
# appears on three planted lines and a bare-token needle would be satisfied by
# any of them — the same collision discipline as lint-action-pins.sh's unique
# `# v9.9.9`.
test_negative_case_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/fixture.md" <<'EOF'
Run /next-issue then stop.
Use `/ship-issue` to deliver.
see:/golem starts it
Invoke /next-issue: it plans.
Then /ship-issue
/golem is the entry point.
Chain /next-issue,/ship-issue in order.
Run /workflow:next-issue then stop.
Read `.claude/memory/tmp/next-issue-queue.json` for the queue.
Read next-issue-{N}.json for phase.
Harness at ~/.claude/skills/ship-issue/workflow.js runs it.
A bare `/clear` resets context.
Prose slashes: `/the and */models. and +/critical) stay put.
See state-format.md for the schema.
Agent audit-security and the /next-issue-{N}.json state file.
Sources live under /ship-issue/workflow.js in the bundle.
EOF

    scan_file "$tmp/fixture.md" "next-issue
ship-issue
golem"

    assert_not_empty "$CUR_VIOLATIONS" "scan_file flags bare refs (violation branch fires)"

    # Positive branch — one assertion per markdown shape.
    assert_contains "$CUR_VIOLATIONS" ":1: /next-issue" "Plain prose ref is flagged"
    assert_contains "$CUR_VIOLATIONS" ":2: /ship-issue" "Backtick-wrapped ref is flagged"
    assert_contains "$CUR_VIOLATIONS" ":3: /golem" "Ref after a colon is flagged (leading class)"
    assert_contains "$CUR_VIOLATIONS" ":4: /next-issue" "Ref followed by a colon is flagged (trailing class)"
    assert_contains "$CUR_VIOLATIONS" ":5: /ship-issue" "Ref at end-of-line is flagged (\$ anchor)"
    assert_contains "$CUR_VIOLATIONS" ":6: /golem" "Ref at start-of-line is flagged (^ anchor)"
    # BOTH refs on the shared-boundary line must surface. This is the assertion
    # that fails if the per-name loop is ever collapsed into one alternation
    # with `grep -o`, which silently drops the second ref.
    assert_contains "$CUR_VIOLATIONS" ":7: /next-issue" "First of two refs sharing a boundary char is flagged"
    assert_contains "$CUR_VIOLATIONS" ":7: /ship-issue" "Second of two refs sharing a boundary char is flagged"
    # The suggested fix is rendered, and plugin resolution works.
    assert_contains "$CUR_VIOLATIONS" "-> /workflow:next-issue" "Violation names the namespaced replacement"

    # Negative branch — one per exemption, keyed on the line-number prefix.
    assert_not_contains "$CUR_VIOLATIONS" ":8: " "An already-namespaced ref is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" ":9: " "The -queue.json state file is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" ":10: " "A ref with no leading slash is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" ":11: " "A filesystem path fragment is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" ":12: " "The built-in /clear command is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" ":13: " "Prose slashes are NOT flagged (whitelist, not blacklist)"
    assert_not_contains "$CUR_VIOLATIONS" ":14: " "An intra-plugin doc pointer is NOT flagged"
    assert_not_contains "$CUR_VIOLATIONS" ":15: " "The next-issue-{N}.json state file is NOT flagged"
    # Only the TRAILING `/` can exempt this shape — the char before the slash is
    # a space, so no leading-class member applies.
    assert_not_contains "$CUR_VIOLATIONS" ":16: " "A ref that opens a path is NOT flagged (trailing / class)"
    # Belt-and-braces on the whitelist property itself, independent of line
    # numbering: /clear can never be reported because it is not a skill name.
    assert_not_contains "$CUR_VIOLATIONS" "/clear" "/clear is structurally unreportable (not a skill name)"
}

run_test test_corpus_non_empty "Corpus + skill discovery are non-empty (gate is not a no-op)"
run_test test_exclusions_are_deliberate "CHANGELOG.md and docs/verification are excluded on purpose"
run_test test_negative_case_fires "scan_file flags bare refs and honors every exemption"
run_test test_namespaced_form_present "The namespaced form is present in the real corpus"
run_test test_namespaced_refs_resolve "Every namespaced ref names the plugin that owns the skill"
run_test test_namespaced_mismatch_fires "scan_namespaced flags a ref naming the wrong plugin (mismatch path)"
run_test test_unknown_name_degrades_not_aborts "An unknown skill name degrades the suggestion, never aborts the gate"
run_test test_detail_truncation "Violation detail truncates at MAX_DETAIL with an accurate remainder"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    CUR_FILE="$f"
    run_test test_file_refs "${f#"$REPO_ROOT"/}: command refs are namespaced"
done <<<"$CORPUS"

generate_report
