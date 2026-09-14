#!/usr/bin/env bash
# harness-stage.sh unit gate (issue #973).
#
# The script under test is the single place a `workflow.js` path is spelled. It
# resolves a harness through three probes and, when the resolved file is not
# reachable from the session's cwd, stages a copy under it — because the
# `Workflow` tool refuses a `scriptPath` outside cwd, and the installed plugin
# root always is one.
#
# WHAT THIS GATE IS REALLY GUARDING. The failure #973 documents was not a crash;
# it was a SKIP. An unreachable harness read as "harness not available", the
# adversarial review was silently replaced by a status line, and every golem
# shipped unreviewed. So the assertions below weight the REFUSAL PATHS at least
# as heavily as the happy path: what matters most is that this script can never
# exit 0 without a usable path, and that its two non-zero codes stay
# distinguishable (3 = broken environment, do not deliver; 4 = plugin absent,
# the caller's documented skip applies). Collapsing those two back into one
# code, or into an exit 0, re-opens the bug.
#
# FIXTURE STRATEGY. Every probe is exercised against a SYNTHETIC tree built in a
# temp dir, not against this repo — because this repo can only ever demonstrate
# probe 2 (dev checkout). The installed-cache layouts, the multi-version
# selection, and the absent-plugin refusal have no representative here, and a
# gate that could only test the one shape the repo happens to have would leave
# the interesting three untested. The script is COPIED into each fixture tree so
# its own SCRIPT_DIR-relative walks resolve against the fixture.
#
# Pure bash + coreutils; no node, no jq, no network. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

STAGER="$REPO_ROOT/plugins/workflow/scripts/harness-stage.sh"

test_suite "harness-stage.sh (#973)"

SKIP_EXIT_CODE=77

if [ ! -f "$STAGER" ]; then
    skip_test "GATE DID NOT RUN — harness-stage.sh not found at $STAGER"
    generate_report
    return "$SKIP_EXIT_CODE" 2>/dev/null || exit "$SKIP_EXIT_CODE"
fi

# --- Fixture helpers ----------------------------------------------------------

# new_tree — mktemp -d, or empty on failure (callers skip rather than false-pass).
new_tree() { command mktemp -d 2>/dev/null || true; }

# install_stager <root> <plugin-dir-rel> — drop a copy of the real script at
# <root>/<plugin-dir-rel>/scripts/harness-stage.sh so its relative walks resolve
# against the fixture. Testing the real bytes, never a re-implementation.
install_stager() {
    command mkdir -p "$1/$2/scripts"
    command cp "$STAGER" "$1/$2/scripts/harness-stage.sh"
    command chmod +x "$1/$2/scripts/harness-stage.sh"
}

# make_harness <path> <marker> — create a stand-in workflow.js with identifiable
# content, so a selection assertion can prove WHICH copy was chosen rather than
# only that something was found.
make_harness() {
    command mkdir -p "$(command dirname "$1")"
    command printf '// %s\n' "$2" >"$1"
}

# run_stager <script> <args…> — capture stdout+stderr and the exit code.
# Deliberately NOT a pipeline: a pipeline reports its last command's status and
# would discard the exit code (#854), which is the single most important thing
# these tests assert.
LAST_OUT=""
LAST_RC=0
run_stager() {
    local s="$1"
    shift
    LAST_OUT="$("$s" "$@" 2>&1)" && LAST_RC=0 || LAST_RC=$?
}

# value_of <key> — read one key from the last key=value output.
value_of() {
    command printf '%s\n' "$LAST_OUT" | command sed -n "s/^$1=//p"
}

# --- Tests --------------------------------------------------------------------

test_list_advertises_ids() {
    run_stager "$STAGER" list
    assert_equals "0" "$LAST_RC" "list exits 0"
    assert_contains "$LAST_OUT" "ship-issue" "list advertises ship-issue"
    assert_contains "$LAST_OUT" "orchestrate" "list advertises orchestrate"
    assert_contains "$LAST_OUT" "codebase-audit" "list advertises codebase-audit"
    assert_contains "$LAST_OUT" "ci-fixer" "list advertises ci-fixer"
    assert_contains "$LAST_OUT" "code-reviewer" "list advertises code-reviewer"
    assert_contains "$LAST_OUT" "rebase-agent" "list advertises rebase-agent"
}

# Probe 2 against the REAL repo — the one layout this tree can demonstrate.
test_dev_checkout_resolves() {
    run_stager "$STAGER" path ship-issue
    assert_equals "0" "$LAST_RC" "path ship-issue exits 0 in a dev checkout"
    local p
    p="$(value_of path)"
    assert_not_empty "$p" "path= is populated"
    assert_file_exists "$p" "the resolved path names a file that exists"
    assert_contains "$LAST_OUT" "staged=false" "path never stages"
}

# The contract callers depend on: all three keys, every time. A caller reads
# `path=` by line-matching, so a missing key is a silently empty variable.
test_output_contract_is_complete() {
    run_stager "$STAGER" path ship-issue
    assert_contains "$LAST_OUT" "path=" "output carries path="
    assert_contains "$LAST_OUT" "source=" "output carries source="
    assert_contains "$LAST_OUT" "staged=" "output carries staged="
}

# THE NO-COPY RULE. In librarian's own checkout the harness is already under cwd.
# Copying it anyway would leave a second, stale copy shadowing the real file —
# so an edit to workflow.src/ plus `just gen-workflow-js` would regenerate the
# artifact while the review kept running yesterday's bytes. Worse than the bug
# being fixed, because it is invisible.
test_already_reachable_is_not_copied() {
    run_stager "$STAGER" stage ship-issue --dir "$REPO_ROOT"
    assert_equals "0" "$LAST_RC" "stage exits 0 when the harness is already under cwd"
    assert_contains "$LAST_OUT" "staged=false" "an already-reachable harness is NOT copied"
    local p
    p="$(value_of path)"
    assert_not_contains "$p" "/.claude/tmp/harness/" \
        "the returned path is the real harness, not a staged copy"
    assert_equals "$(value_of source)" "$p" "path equals source when nothing was staged"
}

# THE COPY RULE, and the reason the script exists: from an unrelated cwd the
# resolved harness is unreachable by the Workflow tool, so it must be staged
# UNDER that cwd and the staged path returned.
test_unreachable_is_staged_under_cwd() {
    local dest
    dest="$(new_tree)"
    [ -n "$dest" ] || {
        skip_test "mktemp unavailable"
        return 0
    }

    run_stager "$STAGER" stage orchestrate --dir "$dest"
    assert_equals "0" "$LAST_RC" "stage exits 0 from an unrelated cwd"
    assert_contains "$LAST_OUT" "staged=true" "an unreachable harness IS copied"

    local p
    p="$(value_of path)"
    assert_file_exists "$p" "the staged copy exists"
    assert_contains "$p" "$dest" "the staged copy is under the requested cwd"
    assert_contains "$p" "orchestrate.workflow.js" "the staged copy is named for its id"

    # Byte-identical, not merely present: a truncated copy would still satisfy
    # an existence check and would then fail deep inside the Workflow tool.
    local src
    src="$(value_of source)"
    local same=0
    command cmp -s "$src" "$p" && same=1
    assert_equals "1" "$same" "the staged copy is byte-identical to its source"

    command rm -rf "$dest"
}

# Staging must be idempotent: a second ship in the same worktree re-stages over
# the first. A "file exists" bail-out would pin a stale harness after an update.
test_staging_is_idempotent() {
    local dest
    dest="$(new_tree)"
    [ -n "$dest" ] || {
        skip_test "mktemp unavailable"
        return 0
    }

    run_stager "$STAGER" stage orchestrate --dir "$dest"
    local first="$LAST_RC"
    run_stager "$STAGER" stage orchestrate --dir "$dest"
    assert_equals "0" "$first" "first stage succeeds"
    assert_equals "0" "$LAST_RC" "re-staging over an existing copy succeeds"
    assert_contains "$LAST_OUT" "staged=true" "the second stage re-copies rather than bailing out"

    command rm -rf "$dest"
}

# The DEFAULT invocation — `stage <id>` with no `--dir`, which is what every
# call site in the skills actually writes. Every other staging case here passes
# `--dir` for isolation, so without this one the defaulting of the stage root to
# $PWD is never exercised at all: a regression that broke it (defaulting to the
# script's own directory, say) would leave this suite green while every real
# caller staged into the wrong tree.
test_default_dir_is_cwd() {
    local dest
    dest="$(new_tree)"
    [ -n "$dest" ] || {
        skip_test "mktemp unavailable"
        return 0
    }

    # Run with cwd INSIDE the temp tree and no --dir. A subshell so the suite's
    # own cwd is untouched.
    LAST_OUT="$(cd "$dest" && "$STAGER" stage orchestrate 2>&1)" && LAST_RC=0 || LAST_RC=$?

    assert_equals "0" "$LAST_RC" "stage with no --dir exits 0"
    assert_contains "$LAST_OUT" "staged=true" "an unreachable harness stages by default too"
    local p
    p="$(value_of path)"
    assert_contains "$p" "$dest" "the default stage root is the process's cwd"
    assert_file_exists "$p" "the default-root copy exists"

    command rm -rf "$dest"
}

# The permission hardening (#973 review): the staging directory and the final
# harness must not depend on the caller's umask. The destination name is
# deterministic and its contents are executed as a scriptPath, so a
# group/world-writable staging dir is a local code-injection seam.
test_staged_paths_are_not_world_readable() {
    local dest
    dest="$(new_tree)"
    [ -n "$dest" ] || {
        skip_test "mktemp unavailable"
        return 0
    }

    # A deliberately permissive umask — the condition the chmod exists to defeat.
    LAST_OUT="$(umask 000 && "$STAGER" stage orchestrate --dir "$dest" 2>&1)" && LAST_RC=0 || LAST_RC=$?
    assert_equals "0" "$LAST_RC" "stage succeeds under a permissive umask"

    local p dirmode filemode
    p="$(value_of path)"
    # `ls`-parsed mode rather than `stat`, whose format flags differ between BSD
    # and GNU (`stat -f %Lp` vs `stat -c %a`) — the portability trap this repo
    # keeps re-learning.
    dirmode="$(command ls -ld "$dest/.claude/tmp/harness" | command cut -c1-10)"
    filemode="$(command ls -l "$p" | command cut -c1-10)"

    assert_equals "drwx------" "$dirmode" \
        "the staging directory is 0700 regardless of umask"
    assert_equals "-rw-------" "$filemode" \
        "the staged harness is 0600 regardless of umask"

    command rm -rf "$dest"
}

# _is_under resolves BOTH sides with `cd`+`pwd -P` rather than comparing string
# prefixes, so a worktree reached through a symlink compares correctly. That is
# the documented #21 rationale (`realpath -m`'s `|| echo` fallback returned the
# path UNRESOLVED and defeated a guard of exactly this shape), and without a test
# the reasoning is only a comment.
test_symlinked_root_resolves() {
    local real link
    real="$(new_tree)"
    [ -n "$real" ] || {
        skip_test "mktemp unavailable"
        return 0
    }
    link="${real}-link"
    command ln -s "$real" "$link" 2>/dev/null || {
        command rm -rf "$real"
        skip_test "cannot create a symlink here"
        return 0
    }

    # Stage through the SYMLINK path. A prefix-comparing _is_under would see the
    # link path and the resolved source as unrelated and behave inconsistently.
    run_stager "$STAGER" stage orchestrate --dir "$link"
    assert_equals "0" "$LAST_RC" "staging through a symlinked root succeeds"
    assert_contains "$LAST_OUT" "staged=true" "the harness is staged via the link"
    local p
    p="$(value_of path)"
    assert_file_exists "$p" "the staged copy exists through the link"
    # It must land in the REAL directory, which is what proves both sides were
    # resolved rather than string-matched.
    assert_file_exists "$real/.claude/tmp/harness/orchestrate.workflow.js" \
        "the copy lands in the resolved real directory, not a second tree"

    command rm -f "$link"
    command rm -rf "$real"
}

# The copy/install failure branches. Both end in `_refuse 3`, and both are
# reachable in practice (a full disk, a read-only mount, a clobbered staging
# dir). Driven by making the staging directory unwritable AFTER it exists, which
# is the only way to fail the cp rather than the mkdir.
test_copy_failure_refuses_loudly() {
    local dest
    dest="$(new_tree)"
    [ -n "$dest" ] || {
        skip_test "mktemp unavailable"
        return 0
    }
    if [ "$(command id -u)" = "0" ]; then
        command rm -rf "$dest"
        skip_test "running as root — permission bits do not apply"
        return 0
    fi

    command mkdir -p "$dest/.claude/tmp/harness"
    command chmod 500 "$dest/.claude/tmp/harness" 2>/dev/null || {
        command rm -rf "$dest"
        skip_test "cannot make the staging directory unwritable here"
        return 0
    }

    run_stager "$STAGER" stage orchestrate --dir "$dest"
    assert_equals "3" "$LAST_RC" "an unwritable staging directory exits 3"
    assert_not_contains "$LAST_OUT" "path=" "a failed copy emits no path="
    # No half-written temp file is left behind for the next run to trip over.
    local leftovers
    leftovers="$(command find "$dest/.claude/tmp/harness" -name '.orchestrate.*' 2>/dev/null || true)"
    assert_equals "" "$leftovers" "a failed copy leaves no temp file behind"

    command chmod 700 "$dest/.claude/tmp/harness" 2>/dev/null || true
    command rm -rf "$dest"
}

# Probe 1, happy path.
test_override_takes_precedence() {
    local tree
    tree="$(new_tree)"
    [ -n "$tree" ] || {
        skip_test "mktemp unavailable"
        return 0
    }
    make_harness "$tree/custom/mine.js" "OVERRIDE"

    LAST_OUT="$(LIBRARIAN_HARNESS_SHIP_ISSUE="$tree/custom/mine.js" \
        "$STAGER" path ship-issue 2>&1)" && LAST_RC=0 || LAST_RC=$?

    assert_equals "0" "$LAST_RC" "an override resolves"
    assert_contains "$LAST_OUT" "$tree/custom/mine.js" \
        "the override wins over the dev-checkout probe"

    command rm -rf "$tree"
}

# Probe 1, refusal. An override that points nowhere SHORT-CIRCUITS the other
# probes, so blaming the plugin would be a false diagnosis of the operator's own
# typo. The message must name the variable.
test_override_pointing_nowhere_refuses_loudly() {
    LAST_OUT="$(LIBRARIAN_HARNESS_SHIP_ISSUE=/nonexistent/nope.js \
        "$STAGER" path ship-issue 2>&1)" && LAST_RC=0 || LAST_RC=$?

    assert_equals "3" "$LAST_RC" "a dead override exits 3 (broken environment)"
    assert_contains "$LAST_OUT" "LIBRARIAN_HARNESS_SHIP_ISSUE" \
        "the refusal names the override variable, not the plugin"
    assert_contains "$LAST_OUT" "/nonexistent/nope.js" \
        "the refusal quotes the configured path"
    assert_not_contains "$LAST_OUT" "path=" \
        "a refusal must not also emit a path= line"
}

# Probe 3a — installed layout, lockstep version. bin/release.sh stamps every
# plugin in lockstep, so the sibling whose version equals ours is by construction
# the right one; that match is exact and needs no version arithmetic.
test_installed_prefers_lockstep_version() {
    local root
    root="$(new_tree)"
    [ -n "$root" ] || {
        skip_test "mktemp unavailable"
        return 0
    }

    install_stager "$root" "workflow/0.14.0"
    make_harness "$root/review-audit/0.14.0/skills/codebase-audit/workflow.js" "LOCKSTEP"
    make_harness "$root/review-audit/0.9.0/skills/codebase-audit/workflow.js" "OLD"
    make_harness "$root/review-audit/99.0.0/skills/codebase-audit/workflow.js" "NEWER"

    run_stager "$root/workflow/0.14.0/scripts/harness-stage.sh" path codebase-audit
    assert_equals "0" "$LAST_RC" "the installed layout resolves"
    assert_contains "$LAST_OUT" "/0.14.0/" \
        "the lockstep version wins even when a numerically greater one exists"

    command rm -rf "$root"
}

# Probe 3b — no lockstep match, so selection falls back to the numerically
# greatest version. THE CASE THAT MATTERS: 10.0.0 vs 9.9.9. A plain `sort` ranks
# "10.0.0" BELOW "9.9.9" as strings and would silently select the stale copy,
# and `sort -V` is GNU-only and banned repo-wide — so this is a field-by-field
# integer compare, and this test is what proves it.
test_installed_version_fallback_is_numeric() {
    local root
    root="$(new_tree)"
    [ -n "$root" ] || {
        skip_test "mktemp unavailable"
        return 0
    }

    install_stager "$root" "workflow/0.14.0"
    make_harness "$root/review-audit/9.9.9/skills/codebase-audit/workflow.js" "NINE"
    make_harness "$root/review-audit/10.0.0/skills/codebase-audit/workflow.js" "TEN"

    run_stager "$root/workflow/0.14.0/scripts/harness-stage.sh" path codebase-audit
    assert_equals "0" "$LAST_RC" "the fallback resolves"
    assert_contains "$LAST_OUT" "/10.0.0/" \
        "10.0.0 outranks 9.9.9 (a lexicographic sort would pick 9.9.9)"

    command rm -rf "$root"
}

# A malformed directory name must never outrank a real version.
test_malformed_version_cannot_win() {
    local root
    root="$(new_tree)"
    [ -n "$root" ] || {
        skip_test "mktemp unavailable"
        return 0
    }

    install_stager "$root" "workflow/0.14.0"
    make_harness "$root/review-audit/zzz-not-a-version/skills/codebase-audit/workflow.js" "JUNK"
    make_harness "$root/review-audit/1.0.0/skills/codebase-audit/workflow.js" "REAL"

    run_stager "$root/workflow/0.14.0/scripts/harness-stage.sh" path codebase-audit
    assert_equals "0" "$LAST_RC" "resolution succeeds alongside a junk directory"
    assert_contains "$LAST_OUT" "/1.0.0/" "a non-numeric directory name cannot win"

    command rm -rf "$root"
}

# THE TWO REFUSAL CODES MUST STAY DISTINCT — this is AC5's whole content.
# Exit 4 says "the plugin is not installed", which is the ONLY case where the
# caller's documented skip-and-park is correct.
test_absent_plugin_exits_4() {
    local root
    root="$(new_tree)"
    [ -n "$root" ] || {
        skip_test "mktemp unavailable"
        return 0
    }

    install_stager "$root" "plugins/workflow"

    run_stager "$root/plugins/workflow/scripts/harness-stage.sh" path codebase-audit
    assert_equals "4" "$LAST_RC" "an uninstalled owning plugin exits 4"
    assert_contains "$LAST_OUT" "not installed" "the refusal says the plugin is not installed"
    assert_contains "$LAST_OUT" "claude plugin install" "the refusal names the remedy"
    assert_contains "$LAST_OUT" "probed" "the refusal lists the probes it tried"

    command rm -rf "$root"
}

# Exit 3 says "the plugin is here but its harness is not" — corruption, not an
# absent optional dependency. Delivery must stop.
test_present_plugin_missing_harness_exits_3() {
    local root
    root="$(new_tree)"
    [ -n "$root" ] || {
        skip_test "mktemp unavailable"
        return 0
    }

    install_stager "$root" "plugins/workflow"
    command mkdir -p "$root/plugins/review-audit/skills"

    run_stager "$root/plugins/workflow/scripts/harness-stage.sh" path codebase-audit
    assert_equals "3" "$LAST_RC" "a present plugin missing its harness exits 3"
    assert_contains "$LAST_OUT" "broken install" "the refusal calls it a broken install"
    assert_contains "$LAST_OUT" "Refusing to exit 0" \
        "the refusal states why silence is not an option"

    command rm -rf "$root"
}

# The exit-3-vs-exit-4 discriminator on the INSTALLED layout, which is the shape
# that matters and the one the two cases above cannot reach: both of those use
# `install_stager <root> plugins/workflow` — a dev-shaped tree with no <version>
# segment, which happens to match the two-levels-up test the code performed.
#
# So a discriminator that only knew the dev depth passed both of them while
# being wrong on every real install: on an installed tree, two levels up from
# .../workflow/<version>/scripts lands INSIDE the workflow plugin's own version
# directory, where a sibling plugin name never appears. An installed-but-
# corrupted sibling therefore reported exit 4 "not installed", telling the caller
# its skip-and-park was correct for what is actually a broken environment —
# inverting AC5 precisely. This fixture is what makes that depth checkable.
test_installed_layout_distinguishes_broken_from_absent() {
    local root
    root="$(new_tree)"
    [ -n "$root" ] || {
        skip_test "mktemp unavailable"
        return 0
    }

    # A real installed shape: <cache>/<marketplace>/<plugin>/<version>/...
    install_stager "$root" "librarian/workflow/0.14.0"
    local stager="$root/librarian/workflow/0.14.0/scripts/harness-stage.sh"

    # (a) sibling plugin entirely absent -> exit 4, the skip-and-park case.
    run_stager "$stager" path codebase-audit
    assert_equals "4" "$LAST_RC" \
        "installed layout: a genuinely absent sibling plugin still exits 4"

    # (b) sibling plugin PRESENT (its version dir exists) but its harness file is
    #     missing -> exit 3. This is the assertion the dev-only depth got wrong.
    command mkdir -p "$root/librarian/review-audit/0.14.0/skills/codebase-audit"
    run_stager "$stager" path codebase-audit
    assert_equals "3" "$LAST_RC" \
        "installed layout: a present-but-corrupted sibling plugin exits 3, not 4"
    assert_contains "$LAST_OUT" "broken install" \
        "installed layout: the refusal names it a broken install"

    command rm -rf "$root"
}

# A pre-existing symlink at the staging path is refused, not followed. `-d`
# follows links, so the "already existed, skip hardening" branch would otherwise
# stage the harness into whatever directory the link points at — and that file is
# then handed to the `Workflow` tool as a trusted scriptPath.
#
# Note this is a DIFFERENT case from test_symlinked_root_resolves: there the
# link is the stage ROOT the caller passed (legitimate — a worktree reached
# through a link), and resolving it is correct. Here the link is the staging
# directory the script itself creates, which it must own outright.
test_symlinked_staging_dir_refuses() {
    local dest elsewhere
    dest="$(new_tree)"
    elsewhere="$(new_tree)"
    [ -n "$dest" ] && [ -n "$elsewhere" ] || {
        skip_test "mktemp unavailable"
        return 0
    }

    command mkdir -p "$dest/.claude/tmp"
    command ln -s "$elsewhere" "$dest/.claude/tmp/harness" 2>/dev/null || {
        command rm -rf "$dest" "$elsewhere"
        skip_test "cannot create a symlink here"
        return 0
    }

    run_stager "$STAGER" stage orchestrate --dir "$dest"
    assert_equals "3" "$LAST_RC" "a symlinked staging directory exits 3"
    assert_contains "$LAST_OUT" "symlink" "the refusal says the path is a symlink"
    assert_not_contains "$LAST_OUT" "path=" "a refused stage emits no path="

    # The decisive assertion: nothing was written through the link.
    local leaked
    leaked="$(command find "$elsewhere" -name '*.workflow.js' 2>/dev/null || true)"
    assert_equals "" "$leaked" \
        "no harness is staged into the symlink's target directory"

    command rm -rf "$dest" "$elsewhere"
}

# A regular FILE squatting on the staging path. Not a symlink and not a
# directory, so neither the `-L` guard nor the `-d` check catches it: `mkdir -p`
# fails with EEXIST-not-a-directory. The requirement is only that it refuse
# loudly rather than proceed, which is what this pins.
test_regular_file_at_staging_path_refuses() {
    local dest
    dest="$(new_tree)"
    [ -n "$dest" ] || {
        skip_test "mktemp unavailable"
        return 0
    }

    command mkdir -p "$dest/.claude/tmp"
    command printf 'not a directory\n' >"$dest/.claude/tmp/harness"

    run_stager "$STAGER" stage orchestrate --dir "$dest"
    assert_equals "3" "$LAST_RC" "a regular file at the staging path exits 3"
    assert_not_contains "$LAST_OUT" "path=" "a refused stage emits no path="

    command rm -rf "$dest"
}

# THE PROBE LOG MUST SURVIVE. This is a regression test for a real bug in the
# first draft: the probe list was accumulated into a global from inside a command
# substitution — a subshell — so every append was discarded and the refusal
# printed a "probed, in order:" header with nothing under it. Loud but useless,
# in the one code path whose entire job is to be informative.
test_refusal_lists_every_probe() {
    local root
    root="$(new_tree)"
    [ -n "$root" ] || {
        skip_test "mktemp unavailable"
        return 0
    }

    install_stager "$root" "plugins/workflow"
    run_stager "$root/plugins/workflow/scripts/harness-stage.sh" path codebase-audit

    assert_contains "$LAST_OUT" "LIBRARIAN_HARNESS_CODEBASE_AUDIT" \
        "the probe log names the override variable it checked"
    assert_contains "$LAST_OUT" "dev checkout" "the probe log names the dev-checkout probe"
    assert_contains "$LAST_OUT" "installed" "the probe log names the installed-cache probe"

    # Count the indented probe lines: the subshell bug produced a header with
    # ZERO lines under it, which every `contains` above would still have caught
    # only by accident. This asserts the log is actually populated.
    local probes
    # `-E` with a real alternation, not BRE `\|`: BSD grep reads `\|` as a
    # LITERAL, so on macOS this would match nothing and the count would read 0 —
    # silently inverting an assertion whose whole point is that the log is
    # populated (CLAUDE.md § runtime policy, #679).
    probes="$(command printf '%s\n' "$LAST_OUT" | command grep -cE 'unset|dev checkout|installed' || true)"
    local ge=0
    [ "${probes:-0}" -ge 3 ] && ge=1
    assert_equals "1" "$ge" \
        "at least 3 probe lines are logged (found ${probes:-0}; the subshell bug produced 0)"

    command rm -rf "$root"
}

# An unwritable cwd is a staging failure, which is exit 3 — not a skip. Skipping
# here would mean an unwritable worktree silently shipped unreviewed.
test_unwritable_cwd_refuses() {
    local dest
    dest="$(new_tree)"
    [ -n "$dest" ] || {
        skip_test "mktemp unavailable"
        return 0
    }
    command chmod 500 "$dest" 2>/dev/null || {
        command rm -rf "$dest"
        skip_test "cannot make a directory unwritable here"
        return 0
    }
    # Running as root defeats the permission bit entirely, so the case would
    # false-pass. Detect and skip rather than assert something untrue.
    if [ "$(command id -u)" = "0" ]; then
        command chmod 700 "$dest"
        command rm -rf "$dest"
        skip_test "running as root — permission bits do not apply"
        return 0
    fi

    run_stager "$STAGER" stage orchestrate --dir "$dest"
    assert_equals "3" "$LAST_RC" "an unwritable cwd exits 3, never a skip"
    assert_not_contains "$LAST_OUT" "path=" "a staging failure emits no path="

    command chmod 700 "$dest" 2>/dev/null || true
    command rm -rf "$dest"
}

# Usage errors are exit 2 and must stay distinct from the two absence codes: a
# typo'd id is a caller bug, not an environment verdict.
test_usage_errors_exit_2() {
    run_stager "$STAGER" path no-such-harness
    assert_equals "2" "$LAST_RC" "an unknown id exits 2"
    assert_contains "$LAST_OUT" "unknown harness id" "the error names the problem"

    run_stager "$STAGER" frobnicate
    assert_equals "2" "$LAST_RC" "an unknown subcommand exits 2"

    run_stager "$STAGER"
    assert_equals "2" "$LAST_RC" "no subcommand exits 2"

    run_stager "$STAGER" stage
    assert_equals "2" "$LAST_RC" "stage with no id exits 2"

    run_stager "$STAGER" stage ship-issue --dir /no/such/dir
    assert_equals "2" "$LAST_RC" "--dir naming a missing directory exits 2"

    run_stager "$STAGER" stage ship-issue --bogus
    assert_equals "2" "$LAST_RC" "an unrecognized flag exits 2"
    assert_contains "$LAST_OUT" "unknown flag" "the error names the unknown flag"

    run_stager "$STAGER" stage ship-issue --dir
    assert_equals "2" "$LAST_RC" "--dir with no value exits 2"
}

# THE INVARIANT, asserted directly over every id: never exit 0 without a usable
# path. Everything else in this file is a specific instance of this rule.
test_never_exits_zero_without_a_path() {
    local ids id bad=""
    ids="$("$STAGER" list 2>/dev/null || true)"
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        run_stager "$STAGER" path "$id"
        if [ "$LAST_RC" -eq 0 ]; then
            local p
            p="$(value_of path)"
            if [ -z "$p" ] || [ ! -f "$p" ]; then
                bad="${bad}${id}: exit 0 with unusable path '${p}'"$'\n'
            fi
        fi
    done <<<"$ids"
    assert_equals "" "$bad" \
        "no id may exit 0 without naming an existing file (the #973 failure shape)"
}

# --- Dispatch ------------------------------------------------------------------

run_test test_list_advertises_ids "list advertises every harness id"
run_test test_dev_checkout_resolves "probe 2: dev checkout resolves"
run_test test_output_contract_is_complete "output carries all three keys"
run_test test_already_reachable_is_not_copied "an already-reachable harness is not copied"
run_test test_unreachable_is_staged_under_cwd "an unreachable harness is staged under cwd"
run_test test_default_dir_is_cwd "stage with no --dir defaults to cwd"
run_test test_staged_paths_are_not_world_readable "staged dir/file are 0700/0600 regardless of umask"
run_test test_symlinked_root_resolves "a symlinked stage root resolves to the real directory"
run_test test_copy_failure_refuses_loudly "a failed copy exits 3 and leaves no temp file"
run_test test_staging_is_idempotent "staging is idempotent (re-stages, never bails)"
run_test test_override_takes_precedence "probe 1: override takes precedence"
run_test test_override_pointing_nowhere_refuses_loudly "probe 1: a dead override refuses loudly (exit 3)"
run_test test_installed_prefers_lockstep_version "probe 3a: lockstep version preferred"
run_test test_installed_version_fallback_is_numeric "probe 3b: version fallback is numeric (10.0.0 > 9.9.9)"
run_test test_malformed_version_cannot_win "a malformed version directory cannot win"
run_test test_absent_plugin_exits_4 "an absent owning plugin exits 4 (skip applies)"
run_test test_present_plugin_missing_harness_exits_3 "a broken install exits 3 (delivery stops)"
run_test test_installed_layout_distinguishes_broken_from_absent "installed layout: broken (3) vs absent (4) stay distinct"
run_test test_symlinked_staging_dir_refuses "a symlinked staging directory refuses rather than staging through it"
run_test test_regular_file_at_staging_path_refuses "a regular file at the staging path refuses"
run_test test_refusal_lists_every_probe "a refusal lists every probe it tried"
run_test test_unwritable_cwd_refuses "an unwritable cwd exits 3, never a skip"
run_test test_usage_errors_exit_2 "usage errors exit 2, distinct from absence"
run_test test_never_exits_zero_without_a_path "never exits 0 without a usable path"

generate_report
