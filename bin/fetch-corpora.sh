#!/usr/bin/env bash
# fetch-corpora.sh — materialize the pinned test corpora named in
# tests/corpora.manifest (issue #1075).
#
# Usage:
#   bin/fetch-corpora.sh                 # fetch every corpus in the manifest
#   bin/fetch-corpora.sh axe-core radix  # fetch only these
#   bin/fetch-corpora.sh --list          # print the manifest, resolved
#   bin/fetch-corpora.sh --dir           # print the resolved corpora dir
#
# Environment:
#   CORPORA_DIR        where to materialize (default: /cache/corpora, falling
#                      back to /tmp/corpora when that is not writable)
#   CORPORA_MANIFEST   manifest path (default: <repo>/tests/corpora.manifest)
#   FETCH_TIMEOUT      per-corpus wall-clock bound in seconds (default 600)
#
# Exit codes:
#   0  success (every requested corpus present at its pinned SHA)
#   1  a fetch, a checkout, or a SHA verification failed
#   2  usage error, or a required runtime is absent (fail loud, never silent)
#
# ---------------------------------------------------------------------------
# WHY THE VERIFICATION STEP IS THE POINT OF THIS SCRIPT.
#
# `git fetch --depth 1 <sha>` can succeed and still leave you somewhere other
# than the pin — a server that does not honor SHA-in-want, a fallback path, a
# refspec that resolved to a branch tip. The result is a checkout of a MOVING
# codebase that looks exactly like a correct one: same directory, same files,
# same exit 0. Every measurement taken against it is then wrong in a way nothing
# reports.
#
# So `verify_head` is not a defensive afterthought; it is the acceptance
# criterion (#1075 AC4). Nothing here trusts the fetch. The checkout is compared
# to the manifest SHA and the script fails loud on disagreement.
#
# TWO FAILURE MODES, DISTINGUISHED DELIBERATELY (#1075's design note):
#
#   1. The server refuses to serve an arbitrary SHA. Fetching a non-tip commit
#      needs `uploadpack.allowReachableSHA1InWant`; GitHub allows it (measured),
#      a self-hosted mirror may not. The wrong response is to degrade to a full
#      clone of a moving branch, which silently discards the pin. This script
#      fails with the reason instead.
#
#   2. The pin is gone — force-push, history rewrite, repo deletion. Measured
#      signature: `upload-pack: not our ref <sha>`. That is matched explicitly so
#      the error can name WHICH pin died and print the manifest's own fallback
#      field, rather than reporting a generic clone failure that sends the reader
#      to the network layer.
#
# NEVER RUN BY THE TEST SUITE. `just test` and the pre-push hook must not touch
# the network (#1075 AC8); corpora are materialized deliberately by an operator.
# tests/validate-fetch-corpora.sh exercises this script's behavior against a
# LOCAL bare repo, which is why that suite is offline too.
#
# bash-3.2 clean and BSD clean per CLAUDE.md § Runtime policy: no `declare -A`,
# no `mapfile`, no namerefs, no GNU-only regex, no `realpath -m`, no
# `mktemp --suffix=`, no `date -d`, no `env --unset=`. Bounded with
# bin/bounded-run.sh rather than GNU `timeout` — a network fetch is exactly where
# an unbounded wait hides, and macOS ships no `timeout` at all.
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MANIFEST="${CORPORA_MANIFEST:-$REPO_ROOT/tests/corpora.manifest}"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-600}"

# The unreachable-pin signature, measured against GitHub in-session. Kept as a
# named constant because it is a fact about a remote's wire protocol, not a
# spelling choice — if it ever stops matching, the symptom is a generic error
# message rather than a wrong result, and this comment is the trail back.
NOT_OUR_REF='upload-pack: not our ref'

# shellcheck source=bin/bounded-run.sh
. "$SCRIPT_DIR/bounded-run.sh"

# SOURCED_MODE — true when this file was `.`-sourced rather than executed.
#
# Used for ONE thing: deciding whether the tail dispatch runs `main`. A consuming
# gate (#1069/#1071/#1072/#1074) sources this file for `corpora_present`, and
# must get functions rather than a fetch.
#
# It is deliberately NOT consulted by `die` any more. Making `die` return when
# sourced looked like the way to keep a consumer's shell alive, and instead made
# all ~17 of its call sites places where execution continues past a failure —
# invisibly, and only in the mode consumers actually use. The sourced-mode safety
# lives in the subshell entry points (`corpora_present`, `fetch_corpora`)
# instead: one place, and a new `die` call site cannot get it wrong.
#
# Detected once here, at load, because $0 and BASH_SOURCE are only reliably
# comparable before any function reassigns them.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    SOURCED_MODE=0
else
    SOURCED_MODE=1
fi

# die <message> — fail loud. ALWAYS exits; never returns.
#
# THE RETURNING VARIANT WAS A TRAP, AND IT COST FIVE DEFECTS' WORTH OF LESSON.
# `die` previously returned when sourced so a consumer's shell would survive.
# That made every one of its ~17 call sites a place where execution CONTINUES
# past a failure — silently, and only in sourced mode, which is the mode
# consuming gates use and the one no executed-mode test can observe. Three sites
# were fixed by hand with an explicit `return 1`; an exhaustive sweep then found
# eight more, including `checkout failed` falling through to the SHA
# verification and a timed-out fetch falling through to checkout.
#
# Patching each site is the method that had already failed four times on the
# trust invariant. So the dual nature is removed instead: `die` exits,
# unconditionally, and the SOURCED-MODE SAFETY MOVES TO THE ENTRY POINTS —
# `corpora_present` and `fetch_corpora` run their work in a SUBSHELL, where an
# exit ends the subshell and returns a status to the consumer rather than
# killing their shell. One place to get right, and a new call site cannot
# reintroduce the fallthrough.
die() {
    command printf 'fetch-corpora: %s\n' "$*" >&2
    exit 1
}

usage_die() {
    command printf 'fetch-corpora: %s\n' "$*" >&2
    command printf 'Usage: fetch-corpora.sh [--list|--dir] [name...]\n' >&2
    exit 2
}

# require_runtime — the preconditions a FETCH needs. Deliberately NOT run at
# load: `corpora_present` needs neither git-for-fetching nor a bound, so a
# consumer asking "is the corpus here?" must not be refused for lacking tools it
# will never use. main() calls this; sourcing does not.
require_runtime() {
    command -v git >/dev/null 2>&1 || {
        command printf 'fetch-corpora: git not found — cannot materialize corpora.\n' >&2
        return 2
    }
    bounded_run_available || {
        command printf 'fetch-corpora: bounded_run unavailable (no sleep/mktemp) — refusing to run an unbounded network fetch.\n' >&2
        return 2
    }
    return 0
}

# --- corpora dir resolution -------------------------------------------------
# Primary /cache/corpora (the named volume; the /cache prefix is load-bearing —
# fix_cache_permissions aligns paths under it to the runtime user). Falls back to
# /tmp/corpora when that is not writable, so this works on a bare Mac or bare
# Linux host with no container at all (#1075 AC2).
#
# Writability is decided by ATTEMPTING A WRITE, not by testing -w on the path. A
# `-w` test answers a question about permission bits that root, an overlay, a
# read-only bind mount, and a full filesystem can each make wrong in a different
# direction. Creating and removing a probe file answers the question actually
# being asked.
#
# WRITABLE IS NOT THE SAME AS TRUSTWORTHY (review finding, CWE-377). The fallback
# path is FIXED and PREDICTABLE, which is what makes it useful on a bare host and
# also what makes it pre-plantable on a shared one: an attacker who creates
# /tmp/corpora first — as a directory they own, or as a symlink to one — passes
# both `mkdir -p` (the target already resolves) and the write probe (it really is
# writable). The script would then run `git init` / `fetch` / `checkout` inside a
# tree of unknown provenance, and git runs `.git/hooks/*` automatically on
# checkout. That escalates an ordinary temp-dir weakness into local code
# execution as the invoking user, because the operation being performed on the
# directory is a git checkout.
#
# So an EXISTING directory must also be ours: not a symlink, and owned by the
# current uid. A path we just created ourselves is fine by construction. This is
# fail-loud rather than fall-back-elsewhere — a hostile pre-plant is a fact about
# the host worth surfacing, not something to quietly route around.
dir_is_trustworthy() {
    local d="$1" owner
    # A symlink is refused outright: its target can be swapped after this check,
    # so no amount of inspecting the target makes it safe to write through.
    [ -L "$d" ] && return 1
    [ -d "$d" ] || return 1

    # BSD and GNU stat spell this differently and neither accepts the other's
    # flags, so try both rather than assuming a platform (CLAUDE.md § Runtime
    # policy). If NEITHER yields a uid, the check is INDETERMINATE — and a guard
    # that could not run has learned nothing, so it refuses rather than passes.
    #
    # THE RESULT IS VALIDATED, NOT INFERRED FROM THE EXIT CODE. GNU `stat -f`
    # does not mean what BSD `stat -f` means: handed `%u` it reads it as a FILE
    # and prints a filesystem dump. It happens to exit 1 here, but the near miss
    # is the point — an exit status is the wrong thing to trust when the two
    # tools disagree about what the flag means. Requiring all-digits makes a
    # wrong-platform answer unusable rather than merely unlikely, which is what
    # keeps this from comparing a uid against a block-size table.
    owner="$(command stat -c %u "$d" 2>/dev/null)"
    case "${owner:-x}" in
        *[!0-9]*) owner="$(command stat -f %u "$d" 2>/dev/null)" ;;
    esac
    case "${owner:-x}" in
        *[!0-9]*) return 1 ;;
    esac
    [ "$owner" = "$(command id -u)" ]
}

# ensure_trusted_dir <path> [mkdir-mode] — create <path> if needed and return
# only when it is ours; die otherwise.
#
# WHY THIS EXISTS RATHER THAN MORE CALL-SITE CHECKS. The trust invariant was
# fixed four times, at four sites, in three review cycles — root pre-check,
# per-corpus, the shared predicate, and root post-mkdir — and each correct fix
# left a sibling exposed. That is the signal to stop patching knobs and make the
# unsafe operation unreachable instead: a caller cannot obtain a directory from
# this function without both checks having run, so a NEW call site inherits them
# rather than having to remember them.
#
# BOTH checks are required and neither is redundant:
#   - BEFORE creation, because `mkdir -p` against a pre-planted symlink succeeds
#     silently and afterwards "we made it" and "it was already there" are
#     indistinguishable.
#   - AFTER creation, because the pre-check fires only when the path already
#     exists; on a first-ever run it does not, leaving a check-then-act window
#     (CWE-367) an attacker can win.
# EVERY `die` HERE IS FOLLOWED BY `return 1`, and that is not belt-and-braces.
# `die` EXITS when the script is executed but RETURNS when it is sourced — which
# is exactly how consuming gates use this file. Without the explicit return, a
# sourced call prints the refusal and then falls through to `return 0`: the guard
# announces that it refuses the directory and approves it in the same breath,
# which is worse than having no guard, because the message reads as evidence that
# the check worked. Caught by test_ensure_trusted_dir_runs_both_checks.
ensure_trusted_dir() {
    local path="$1" mode="${2:-}"

    if [ -e "$path" ] || [ -L "$path" ]; then
        dir_is_trustworthy "$path" ||
            die "refusing to use $path — it is a symlink or is not owned by uid $(command id -u)"
    fi

    if [ -n "$mode" ]; then
        command mkdir -m "$mode" -p "$path" 2>/dev/null || return 1
    else
        command mkdir -p "$path" 2>/dev/null || return 1
    fi

    dir_is_trustworthy "$path" ||
        die "$path became untrustworthy after creation — refusing to use it"
    return 0
}

resolve_corpora_dir() {
    local want probe
    want="${CORPORA_DIR:-/cache/corpora}"

    # Both trust checks live in ensure_trusted_dir, so this function cannot
    # obtain an unvetted path — see that function's header for why the invariant
    # moved there instead of being repeated here.
    if ensure_trusted_dir "$want"; then
        probe="$want/.write-probe.$$"
        if : >"$probe" 2>/dev/null; then
            command rm -f "$probe" 2>/dev/null
            command printf '%s\n' "$want"
            return 0
        fi
    fi

    # An explicit CORPORA_DIR that is not writable is an operator error, not an
    # invitation to silently put the data somewhere else: a caller that set the
    # variable is telling us where its measurements live, and writing elsewhere
    # would strand them.
    # `return 1` for the same reason as ensure_trusted_dir's: sourced, `die`
    # returns, and without this the function would fall through and print
    # /tmp/corpora as the resolved directory after refusing the requested one.
    if [ -n "${CORPORA_DIR:-}" ]; then
        die "CORPORA_DIR is not writable: $CORPORA_DIR"
    fi

    # 0700 on the fallback: a mode that lets another user write into our corpora
    # tree reintroduces the tampering these checks exist to prevent, one step
    # later. Harmless on the container path, load-bearing on a shared host — and
    # this is the predictable path, so the one most worth pre-planting.
    ensure_trusted_dir /tmp/corpora 0700 ||
        die "neither /cache/corpora nor /tmp/corpora is writable"
    command printf '%s\n' "/tmp/corpora"
}

# --- manifest parsing -------------------------------------------------------
# Pure-bash TAB splitting rather than sed/awk. The format is simple enough that a
# `read` loop is clearer, and it sidesteps the BSD-vs-GNU sed differences that
# CLAUDE.md § Runtime policy warns are SILENT — a pattern that stops matching
# yields zero rows and still exits 0, so macOS would see an empty manifest and a
# clean run. `read_yaml_list` in ship-issue/pre-review-gates.sh is the worked
# example of the same preference.
#
# IFS is set on the `read` itself so only fields split on TAB; `-r` keeps
# backslashes literal. The trailing `|| [ -n "$name" ]` is what makes a final
# line with no newline still parse, which is the single most common way a
# hand-edited manifest loses its last entry.

# manifest_field <name> <field-index> — echo one field of one entry, empty if
# the entry is absent. Field indices are 1-based in manifest order:
# 1=name 2=url 3=sha 4=license 5=fallback 6=why
manifest_field() {
    local want="$1" idx="$2"
    local name url sha license fallback why
    while IFS=$'\t' read -r name url sha license fallback why || [ -n "$name" ]; do
        case "$name" in
            '' | '#'*) continue ;;
        esac
        [ "$name" = "$want" ] || continue
        case "$idx" in
            1) command printf '%s\n' "$name" ;;
            2) command printf '%s\n' "$url" ;;
            3) command printf '%s\n' "$sha" ;;
            4) command printf '%s\n' "$license" ;;
            5) command printf '%s\n' "$fallback" ;;
            6) command printf '%s\n' "$why" ;;
        esac
        return 0
    done <"$MANIFEST"
    return 1
}

# manifest_names — every corpus name, in manifest order.
manifest_names() {
    local name rest
    while IFS=$'\t' read -r name rest || [ -n "$name" ]; do
        case "$name" in
            '' | '#'*) continue ;;
        esac
        command printf '%s\n' "$name"
    done <"$MANIFEST"
}

# is_full_sha <string> — 40 lowercase hex characters, exactly.
#
# Anchored at BOTH ends on purpose: without the trailing anchor a 41-character
# string passes, and without the leading one a 40-hex substring of a longer token
# does. A short SHA is rejected rather than resolved because an abbreviation is
# not a stable identifier — git resolves a 7-char prefix to whatever object
# currently matches, which is a different object as the repo grows.
is_full_sha() {
    case "$1" in
        *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#1}" -eq 40 ]
}

# valid_corpus_url <string> — https (or file:// for tests), no credentials.
#
# The manifest header states this policy; this is what ENFORCES it. A documented
# rule with no code behind it is the doc-claims-what-the-code-lacks shape: it
# reads as a constraint while permitting the opposite.
#
# Two things are refused. An `ssh://` / `git@` remote, because corpora are
# fetched on CI-less developer machines where an ssh remote either prompts or
# fails in a way that has nothing to do with the pin. And credentials embedded in
# the URL (`https://user:token@host/…`), because fetch_one ECHOES the url — on
# the fetch line and on both error paths — so a credential in the manifest
# becomes a credential in every log and CI transcript. The rejection therefore
# happens BEFORE the url is echoed anywhere.
#
# `file://` IS ALLOWED, and that is not a loophole in the policy — it is what
# makes the policy testable. tests/validate-fetch-corpora.sh must exercise the
# real fetch, checkout and SHA-verification paths WITHOUT network access
# (#1075 AC8), which means a local remote. Refusing file:// would leave the
# fetch path either untested or tested only against the network — and the
# committed manifest is covered separately by the https assertion in
# lint-measurement-citations.sh's sibling checks, so a file:// URL cannot reach
# a real corpus entry unnoticed.
#
# The `@` test is scoped to the AUTHORITY component (before the first `/` after
# the scheme): a `@` later in a path is legitimate and must not be refused.
valid_corpus_url() {
    local url="$1" rest authority
    case "$url" in
        https://*) rest="${url#https://}" ;;
        file://*) return 0 ;;
        *) return 1 ;;
    esac
    authority="${rest%%/*}"
    case "$authority" in
        *@*) return 1 ;;
    esac
    [ -n "$authority" ]
}

# --- the verification step (AC4) --------------------------------------------
# verify_head <dir> <expected-sha> — true when the checkout is exactly the pin.
verify_head() {
    local dir="$1" want="$2" got
    got="$(command git -C "$dir" rev-parse HEAD 2>/dev/null)" || return 1
    [ "$got" = "$want" ]
}

# corpora_present <name> [dir] — true when that corpus is materialized at its
# pinned SHA.
#
# EXPORTED FOR THE CONSUMING SLICES (#1069/#1071/#1072/#1074), which need to
# decide whether to run at all. Those gates exit the reserved sentinel 77 when
# their corpus is absent, so run-all.sh renders `[SKIP] ... did not run` instead
# of a green `[ok]` — a corpus gate that passes because nothing was mounted is
# worse than no gate, since it reads as evidence (#1075 AC7, #538/#571).
#
# Note this function answers "present AT THE PIN", not "directory exists". A
# corpus left at the wrong commit by an interrupted fetch must read as absent, or
# the consumer measures against an unpinned tree while believing otherwise —
# which is the whole failure this slice exists to prevent.
# It answers FALSE rather than dying on every "cannot tell" path — an absent
# manifest, an unresolvable corpora dir, an unknown name. A predicate a consumer
# calls to decide whether to skip must be safe to call in any state; if it could
# abort, the consumer would die at the exact moment it was trying to report a
# clean skip.
#
# AN UNTRUSTWORTHY TREE READS AS ABSENT, and that belongs HERE rather than only
# at the fetch call site. This predicate is the one thing consuming gates import,
# and `--list` calls it too — so without the check, a pre-planted symlink whose
# HEAD happens to equal the public pin is reported `present`, and a consumer
# measures against an attacker's tree while believing it holds the pin. That is
# the same wrong-answer-reads-as-evidence failure the whole slice exists to
# prevent, arriving through the predicate instead of the fetch.
#
# It also keeps `verify_head`'s `git rev-parse` out of a foreign repository,
# which reads that repo's config.
#
# FALSE, not fatal: this is a predicate, and "I will not vouch for this tree" is
# an answer, not a crash. fetch_one still fails LOUD on the same condition — a
# refusal there is actionable, where a silent skip here is correct.
# THE SUBSHELL IS THE SOURCED-MODE SAFETY, and it is why `die` can exit
# unconditionally. Everything below runs inside ( ), so a `die` anywhere in the
# call tree — including resolve_corpora_dir's — ends the SUBSHELL and yields a
# non-zero status here, rather than killing the consumer's shell. The consumer
# gets a clean false and lives to report its own 77.
#
# `2>/dev/null` because a refusal is diagnostics, not this predicate's answer:
# the answer is the status. A consumer deciding whether to skip should not have
# a warning about a hostile /tmp printed into the middle of its test output.
corpora_present() (
    name="$1"
    dir="${2:-}"
    [ -f "$MANIFEST" ] || exit 1
    if [ -z "$dir" ]; then
        dir="$(resolve_corpora_dir 2>/dev/null)" || exit 1
        [ -n "$dir" ] || exit 1
    fi
    sha="$(manifest_field "$name" 3)" || exit 1
    [ -n "$sha" ] || exit 1
    [ -d "$dir/$name/.git" ] || exit 1
    dir_is_trustworthy "$dir/$name" || exit 1
    verify_head "$dir/$name" "$sha"
) 2>/dev/null

# --- fetch ------------------------------------------------------------------
# fetch_one <name> <dir>
fetch_one() {
    local name="$1" root="$2"
    local url sha fallback dir out rc

    url="$(manifest_field "$name" 2)" || die "unknown corpus: $name (not in $MANIFEST)"
    sha="$(manifest_field "$name" 3)"
    fallback="$(manifest_field "$name" 5)"

    is_full_sha "$sha" ||
        die "$name: manifest SHA is not a full 40-char hex SHA: '$sha'"

    # Checked BEFORE the url is echoed anywhere below — a credential-bearing URL
    # must not reach a log on its way to being rejected.
    valid_corpus_url "$url" ||
        die "$name: manifest URL must be https with no embedded credentials"

    dir="$root/$name"

    # THE SAME TRUST CHECK, ONE LEVEL DOWN — AND IT MUST PRECEDE EVERY OTHER USE
    # OF $dir, INCLUDING THE FAST PATH BELOW.
    #
    # resolve_corpora_dir vets the corpora ROOT, but this is the directory git
    # inits, fetches and checks out in — and `git checkout` runs .git/hooks/*.
    # Vetting only the parent is sufficient when the parent is 0700 and ours (the
    # /tmp fallback) and NOT sufficient on a shared /cache volume whose mode this
    # script does not control.
    #
    # THE ORDER IS THE WHOLE FIX. Placed after the corpora_present early return —
    # where it first landed — this check never runs on the common re-run case,
    # because corpora_present asks only "is there a .git here whose HEAD equals
    # the pin". The manifest's URL+SHA pairs are public, so an attacker clones the
    # real commit into a tree they own and symlinks $root/$name at it: the SHA
    # matches, the fast path returns 0, and the guard is skipped entirely.
    # Measured before this move — `ok  1cc54b9 (already at pin)`, exit 0, no
    # refusal. Every path that treats $dir as ours must validate it first.
    if [ -e "$dir" ] || [ -L "$dir" ]; then
        dir_is_trustworthy "$dir" ||
            die "$name: refusing to use $dir — it is a symlink or is not owned by uid $(command id -u)"
    fi

    # IDEMPOTENCE (AC2), decided by the SHA rather than by the directory. An
    # existence test would call a half-fetched or wrongly-checked-out tree
    # "present" and skip the repair.
    if corpora_present "$name" "$root"; then
        command printf '  %-14s ok       %s (already at pin)\n' "$name" "${sha%"${sha#???????}"}"
        return 0
    fi

    # Creation + both trust checks, via the one helper — so the tree git is about
    # to init, fetch and checkout in (which runs .git/hooks/*) cannot be reached
    # unvetted.
    ensure_trusted_dir "$dir" || die "$name: cannot create $dir"

    if [ ! -d "$dir/.git" ]; then
        command git -C "$dir" init -q 2>/dev/null || die "$name: git init failed in $dir"
    fi

    # Re-point origin every time: a manifest URL that changed must not be
    # shadowed by a stale remote left in an existing directory.
    command git -C "$dir" remote remove origin 2>/dev/null || :
    command git -C "$dir" remote add origin "$url" ||
        die "$name: cannot set remote to $url"

    command printf '  %-14s fetch    %s\n' "$name" "$url"

    # Shallow + blobless: measured at 22 MB for axe-core against 115 MB for a
    # full clone. Bounded, because a network fetch with no bound is a hang.
    set +e
    out="$(bounded_run "$FETCH_TIMEOUT" \
        git -C "$dir" fetch --depth 1 --filter=blob:none origin "$sha" 2>&1)"
    rc=$?
    set -e

    if [ "$rc" -eq 124 ]; then
        die "$name: fetch exceeded ${FETCH_TIMEOUT}s — network stalled or remote unresponsive"
    fi

    if [ "$rc" -ne 0 ]; then
        # Failure mode 2: the pin itself is gone. Name it, and hand the reader
        # the manifest's own fallback rather than a generic network error.
        case "$out" in
            *"$NOT_OUR_REF"*)
                command printf 'fetch-corpora: %s: PIN UNREACHABLE — %s no longer serves %s\n' \
                    "$name" "$url" "$sha" >&2
                command printf '  The commit was force-pushed away, rewritten, or the repo was removed.\n' >&2
                command printf '  Manifest fallback for this entry: %s\n' "$fallback" >&2
                command printf '  Update tests/corpora.manifest deliberately; do NOT re-pin to a branch tip.\n' >&2
                exit 1
                ;;
        esac

        # Failure mode 1: the server will not serve an arbitrary SHA. The wrong
        # response is a full clone of a moving branch, which discards the pin
        # while looking like success.
        command printf 'fetch-corpora: %s: fetch of %s failed\n' "$name" "$sha" >&2
        command printf '  If this remote is a self-hosted mirror, it may not allow fetching an\n' >&2
        command printf '  arbitrary commit (uploadpack.allowReachableSHA1InWant). Not falling back\n' >&2
        command printf '  to a full clone: that would silently discard the pin.\n' >&2
        command printf '  git said: %s\n' "$out" >&2
        exit 1
    fi

    command git -C "$dir" checkout -q FETCH_HEAD 2>/dev/null ||
        die "$name: checkout of FETCH_HEAD failed"

    # AC4. Never trust the fetch — a checkout that landed on a branch tip looks
    # identical to success until a measurement is taken against it.
    if ! verify_head "$dir" "$sha"; then
        command printf 'fetch-corpora: %s: CHECKOUT VERIFICATION FAILED\n' "$name" >&2
        command printf '  expected %s\n' "$sha" >&2
        command printf '  actual   %s\n' "$(command git -C "$dir" rev-parse HEAD 2>/dev/null)" >&2
        command printf '  The fetch reported success but landed elsewhere — refusing to leave a\n' >&2
        command printf '  tree that would be measured as if it were the pin.\n' >&2
        exit 1
    fi

    command printf '  %-14s verified %s\n' "$name" "$sha"
}

# valid_corpus_name <string> — a manifest slug: [a-z0-9-], non-empty.
#
# Validated at the BOUNDARY rather than relied on downstream. A name reaches
# `fetch_one` and becomes a path component ("$root/$name"), so a value carrying
# `/` or `..` would write outside the corpora dir, and one carrying shell
# metacharacters depends on every later expansion staying quoted to remain inert.
# Both are true today; neither should be the thing standing between a CLI
# argument and the filesystem. Rejecting the shape up front means the rest of the
# script handles only names the manifest could contain.
valid_corpus_name() {
    [ -n "$1" ] || return 1
    case "$1" in
        # A leading hyphen is rejected so this validator and the CLI describe the
        # SAME reachable set. main()'s option loop matches `-*` first, so a
        # hyphen-initial name could never reach here anyway — accepting it would
        # mean the manifest could hold a slug that is permanently unselectable,
        # and the contributor who added one would get "unknown option" rather
        # than a naming-convention error.
        -*) return 1 ;;
        *[!a-z0-9-]*) return 1 ;;
    esac
    return 0
}

main() {
    local root want_list=0 want_dir=0
    local args=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --list) want_list=1 ;;
            --dir) want_dir=1 ;;
            -h | --help)
                command printf 'Usage: fetch-corpora.sh [--list|--dir] [name...]\n'
                exit 0
                ;;
            -*) usage_die "unknown option: $1" ;;
            *)
                valid_corpus_name "$1" ||
                    usage_die "invalid corpus name: '$1' (expected [a-z0-9-])"
                args="$args $1"
                ;;
        esac
        shift
    done

    # Preconditions belong to the FETCH, so they are checked here rather than at
    # load — see require_runtime.
    require_runtime || return $?
    [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

    # A COMMAND SUBSTITUTION SWALLOWS THE DIE. `$( )` runs its body in a
    # subshell, so `resolve_corpora_dir`'s exit ends THAT subshell and the
    # assignment simply gets an empty string — `set -e` does not fire, because the
    # assignment itself succeeded. Without these two guards `main` continued with
    # root="" and went on to build paths like "/axe-core", i.e. operating at the
    # filesystem root. Observed directly while probing the sourced-mode entry
    # points; the emptiness is the whole signal, so it is checked explicitly.
    root="$(resolve_corpora_dir)" ||
        die "could not resolve a corpora directory"
    [ -n "$root" ] ||
        die "could not resolve a corpora directory (empty result)"

    if [ "$want_dir" -eq 1 ]; then
        command printf '%s\n' "$root"
        return 0
    fi

    if [ "$want_list" -eq 1 ]; then
        local n
        for n in $(manifest_names); do
            if corpora_present "$n" "$root"; then
                command printf '%-14s %-8s %s\n' "$n" "present" "$(manifest_field "$n" 3)"
            else
                command printf '%-14s %-8s %s\n' "$n" "absent" "$(manifest_field "$n" 3)"
            fi
        done
        return 0
    fi

    # No names given => every corpus in the manifest.
    if [ -z "$args" ]; then
        args="$(manifest_names | command tr '\n' ' ')"
    fi

    [ -n "$(command printf '%s' "$args" | command tr -d ' ')" ] ||
        die "manifest has no entries: $MANIFEST"

    command printf 'fetch-corpora: materializing into %s\n' "$root"

    local n
    for n in $args; do
        fetch_one "$n" "$root"
    done

    command printf 'fetch-corpora: done\n'
}

# fetch_corpora <args...> — the SOURCED entry point for a fetch.
#
# Same subshell contract as corpora_present: a `die` anywhere inside ends the
# subshell and returns a status, so a consumer that wants to materialize a corpus
# can do so without risking its own shell. Executed runs go through `main`
# directly, where die's exit IS the intended behavior.
#
# Diagnostics are NOT suppressed here (unlike the predicate): a caller asking for
# a fetch wants to know why it failed.
fetch_corpora() (
    main "$@"
)

# Sourced (to reuse corpora_present) vs executed. When sourced, define the
# functions and stop — a consuming gate wants the predicate, not a fetch.
# SOURCED_MODE is computed from this same comparison at load; reused rather than
# re-derived so the two can never disagree.
if [ "$SOURCED_MODE" -eq 0 ]; then
    main "$@"
fi
