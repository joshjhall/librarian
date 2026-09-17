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

die() {
    command printf 'fetch-corpora: %s\n' "$*" >&2
    exit 1
}

usage_die() {
    command printf 'fetch-corpora: %s\n' "$*" >&2
    command printf 'Usage: fetch-corpora.sh [--list|--dir] [name...]\n' >&2
    exit 2
}

command -v git >/dev/null 2>&1 || {
    command printf 'fetch-corpora: git not found — cannot materialize corpora.\n' >&2
    exit 2
}

bounded_run_available || {
    command printf 'fetch-corpora: bounded_run unavailable (no sleep/mktemp) — refusing to run an unbounded network fetch.\n' >&2
    exit 2
}

[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

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
resolve_corpora_dir() {
    local want probe
    want="${CORPORA_DIR:-/cache/corpora}"

    if command mkdir -p "$want" 2>/dev/null; then
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
    if [ -n "${CORPORA_DIR:-}" ]; then
        die "CORPORA_DIR is not writable: $CORPORA_DIR"
    fi

    command mkdir -p /tmp/corpora 2>/dev/null ||
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
corpora_present() {
    local name="$1" dir="${2:-}" sha
    [ -n "$dir" ] || dir="$(resolve_corpora_dir)"
    sha="$(manifest_field "$name" 3)" || return 1
    [ -d "$dir/$name/.git" ] || return 1
    verify_head "$dir/$name" "$sha"
}

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

    dir="$root/$name"

    # IDEMPOTENCE (AC2), decided by the SHA rather than by the directory. An
    # existence test would call a half-fetched or wrongly-checked-out tree
    # "present" and skip the repair.
    if corpora_present "$name" "$root"; then
        command printf '  %-14s ok       %s (already at pin)\n' "$name" "${sha%"${sha#???????}"}"
        return 0
    fi

    command mkdir -p "$dir" 2>/dev/null || die "$name: cannot create $dir"

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

    root="$(resolve_corpora_dir)"

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

# Sourced (to reuse corpora_present) vs executed. When sourced, define the
# functions and stop — a consuming gate wants the predicate, not a fetch.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
