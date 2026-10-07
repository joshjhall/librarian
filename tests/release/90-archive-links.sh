# shellcheck shell=bash
# Group I — bin/check-archive-links.sh + the release.yml link guard (#1105).
#
# The repo tracked `.codegraph -> /cache/codegraph`, so every signed tarball
# carried a link escaping the install tree. The fix untracks it, makes
# .gitignore match a symlink, and runs this guard before signing. release.yml
# only runs on a pushed tag, so the guard is driven here against real
# `git archive` output: escaping fixtures are the live control proving the guard
# can fire, in-tree ones that it does not over-reject, and an archive of THIS
# repo's HEAD that the shipped tree is clean today.
#
# Sourced by tests/validate-release.sh, which defines REPO_ROOT and sources
# tests/lib/release-sandbox.sh (for WORKDIR) BEFORE this file. This fragment only
# DEFINES test functions; the entry point dispatches them.

LINK_GUARD="$REPO_ROOT/bin/check-archive-links.sh"

# al_archive <out.tar.gz> <link>=<target>...
# Builds a throwaway repo holding README, sub/file and the given symlinks, then
# archives it under `p/` (or under $AL_PREFIX, which may be empty). Runs in a subshell with git's hook-exported variables
# unset: under the pre-push hook an inherited GIT_DIR would point every call
# here at the OUTER repo.
al_archive() {
    local out="$1" repo prefix="${AL_PREFIX-p/}"
    shift
    repo="$(command mktemp -d "$WORKDIR/al.XXXXXX")" || return 1
    (
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
            GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
        cd "$repo" || exit 1
        command mkdir -p sub/deep
        command printf 'x\n' >README
        command printf 'y\n' >sub/file
        local spec
        for spec in "$@"; do
            command ln -s "${spec#*=}" "${spec%%=*}" || exit 1
        done
        git init -q &&
            git add -A &&
            git -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
                commit -q -m init &&
            git -c tar.umask=0022 archive --format=tar.gz --prefix="$prefix" \
                -o "$out" HEAD
    )
}

test_archive_links_rejects_absolute() {
    local tgz="$WORKDIR/al-abs.tar.gz" out rc=0
    al_archive "$tgz" "AGENTS.md=README" ".codegraph=/cache/codegraph" || {
        assert_true "false" "fixture archive (absolute link) built"
        return 0
    }
    out="$(command bash "$LINK_GUARD" "$tgz" 2>&1)" || rc=$?
    assert_exit 1 "$rc" "an absolute symlink target is rejected"
    assert_contains "$out" "p/.codegraph -> /cache/codegraph" "the offending link and its target are named"
    assert_contains "$out" "1 of 2 symlinks" "only the escaping link is counted, of every link scanned"
    assert_not_contains "$out" "AGENTS.md" "the in-tree sibling link is not flagged"
}

test_archive_links_rejects_escaping_relative() {
    local tgz="$WORKDIR/al-up.tar.gz" out rc=0
    # sub/out -> ../../etc climbs one level above p/; top -> ../x leaves p/ from
    # the top. sub/deep/ok dips to p/ and back down, which stays inside.
    al_archive "$tgz" "sub/out=../../etc" "top=../x" "sub/deep/ok=../../README" || {
        assert_true "false" "fixture archive (relative escape) built"
        return 0
    }
    out="$(command bash "$LINK_GUARD" "$tgz" 2>&1)" || rc=$?
    assert_exit 1 "$rc" "a ..-escaping relative target is rejected"
    assert_contains "$out" "p/sub/out -> ../../etc" "the nested escaping link is named"
    assert_contains "$out" "p/top -> ../x" "the top-level escaping link is named"
    assert_contains "$out" "2 of 3 symlinks" "both escapes counted, the in-tree link not"
    assert_not_contains "$out" "sub/deep/ok" "a link that dips and returns inside the tree is not flagged"
}

test_archive_links_rejects_transient_escape() {
    # ../../p/README lands back inside p/, but only by climbing out first; a
    # consumer that strips p/ on extract resolves that through the parent dir.
    local tgz="$WORKDIR/al-transient.tar.gz" rc=0
    al_archive "$tgz" "sub/round=../../p/README" || {
        assert_true "false" "fixture archive (transient escape) built"
        return 0
    }
    command bash "$LINK_GUARD" "$tgz" >/dev/null 2>&1 || rc=$?
    assert_exit 1 "$rc" "a target that leaves the tree before re-entering it is rejected"
}

test_archive_links_rejects_escape_without_prefix() {
    # With no top directory every top-level link sits at the archive root, so the
    # floor is the root itself: one `..` already escapes. Every other fixture
    # uses a prefix, which leaves this floor=0 branch unexercised.
    local tgz="$WORKDIR/al-noprefix.tar.gz" out rc=0
    AL_PREFIX="" al_archive "$tgz" "esc=../x" "ok=README" || {
        assert_true "false" "fixture archive (no prefix) built"
        return 0
    }
    out="$(command bash "$LINK_GUARD" "$tgz" 2>&1)" || rc=$?
    assert_exit 1 "$rc" "a root-level ..-link in an unprefixed archive is rejected"
    assert_contains "$out" "esc -> ../x" "the root-level escaping link is named"
    assert_contains "$out" "1 of 2 symlinks" "the in-tree root-level link is not counted"
}

test_archive_links_rejects_link_chain() {
    # Each link alone stays in-tree, but sub/t resolves `s` first, and s -> ..
    # already sits at p/, so the following `../..` leaves the archive. A lexical
    # walk counts `s` as a plain directory and passes it; the guard must refuse
    # any target that routes THROUGH a symlink. sub/u -> s ends on the link,
    # which is judged on its own (s itself stays in-tree), so it passes.
    local tgz="$WORKDIR/al-chain.tar.gz" out rc=0
    al_archive "$tgz" "sub/s=.." "sub/t=s/../.." "sub/u=s" || {
        assert_true "false" "fixture archive (link chain) built"
        return 0
    }
    out="$(command bash "$LINK_GUARD" "$tgz" 2>&1)" || rc=$?
    assert_exit 1 "$rc" "a link-to-link chain that escapes is rejected"
    assert_contains "$out" "p/sub/t -> s/../..  (routes through symlink p/sub/s)" \
        "the chained link is named with the link it routes through"
    assert_contains "$out" "1 of 3 symlinks" "the chain's in-tree links are not flagged"
}

test_archive_links_rejects_benign_route_through_link() {
    # Deliberately conservative: sub/x -> l/file resolves in-tree (l -> deep),
    # but it still routes through a link, so it is refused. Pinned so the policy
    # is a decision rather than an accident a later "fix" could loosen.
    local tgz="$WORKDIR/al-benign.tar.gz" out rc=0
    al_archive "$tgz" "sub/l=deep" "sub/x=l/file" || {
        assert_true "false" "fixture archive (benign route-through) built"
        return 0
    }
    out="$(command bash "$LINK_GUARD" "$tgz" 2>&1)" || rc=$?
    assert_exit 1 "$rc" "an in-tree target routed through a link is still refused"
    assert_contains "$out" "p/sub/x -> l/file  (routes through symlink p/sub/l)" \
        "the refusal names the intermediate link"
}

test_archive_links_fails_loud_when_find_fails() {
    # A failed scan must not read as "0 symlinks, clean". Stub find on PATH to
    # fail; BASH_ENV is unset so no profile can restore the real PATH.
    local tgz="$WORKDIR/al-findfail.tar.gz" stub="$WORKDIR/al-stub-bin" out rc=0
    al_archive "$tgz" "AGENTS.md=README" || {
        assert_true "false" "fixture archive (find failure) built"
        return 0
    }
    command mkdir -p "$stub"
    command printf '#!/bin/sh\nexit 1\n' >"$stub/find"
    command chmod +x "$stub/find"
    out="$(/usr/bin/env -uBASH_ENV PATH="$stub:$PATH" bash "$LINK_GUARD" "$tgz" 2>&1)" || rc=$?
    assert_exit 2 "$rc" "a failing find is an error, not a clean scan"
    assert_contains "$out" "could not scan the extracted tree" "the find-failure branch is the one that refused"
}

test_archive_links_newline_in_name() {
    # find output used to be newline-split, so a link named `a<NL>b` became two
    # paths and readlink died under set -e with no message. NUL-delimited, the
    # whole name is read and its escaping target reported.
    local tgz="$WORKDIR/al-nl.tar.gz" out rc=0 nl='
'
    al_archive "$tgz" "sub/a${nl}b=/etc" || {
        assert_true "false" "fixture archive (newline name) built"
        return 0
    }
    out="$(command bash "$LINK_GUARD" "$tgz" 2>&1)" || rc=$?
    assert_exit 1 "$rc" "an escaping link with a newline in its name is rejected"
    assert_contains "$out" "1 of 1 symlinks" "the newline name is counted once, not split in two"
    assert_contains "$out" "(absolute)" "the offender is reported with its reason"
}

test_archive_links_accepts_in_tree() {
    local tgz="$WORKDIR/al-ok.tar.gz" out rc=0
    al_archive "$tgz" "AGENTS.md=README" "sub/up=../README" "./sub/dot=./file" || {
        assert_true "false" "fixture archive (in-tree links) built"
        return 0
    }
    out="$(command bash "$LINK_GUARD" "$tgz" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "relative in-tree links pass"
    # Pinning the count proves the scan found the links, not an empty set.
    assert_contains "$out" "3 symlinks" "every link was scanned"
}

test_archive_links_fails_loud_on_bad_input() {
    local rc=0 out
    command bash "$LINK_GUARD" "$WORKDIR/does-not-exist.tar.gz" >/dev/null 2>&1 || rc=$?
    assert_exit 2 "$rc" "a missing tarball is a usage error, not a clean pass"
    rc=0
    command printf 'not a tarball' >"$WORKDIR/al-junk.tar.gz"
    command bash "$LINK_GUARD" "$WORKDIR/al-junk.tar.gz" >/dev/null 2>&1 || rc=$?
    assert_exit 2 "$rc" "an unlistable tarball fails loud"
    rc=0
    # 1024 zero bytes is a bare end-of-archive marker: valid, but zero entries.
    command head -c 1024 /dev/zero | command gzip >"$WORKDIR/al-empty.tar.gz"
    out="$(command bash "$LINK_GUARD" "$WORKDIR/al-empty.tar.gz" 2>&1)" || rc=$?
    assert_exit 2 "$rc" "an empty tarball is refused, not reported clean"
    assert_contains "$out" "lists no entries" "the empty-listing branch is the one that refused"
    rc=0
    command bash "$LINK_GUARD" >/dev/null 2>&1 || rc=$?
    assert_exit 2 "$rc" "no argument prints usage"
}

# The shipped tree itself: archive this repo's HEAD exactly as release.yml does
# and run the guard. This is what catches the next committed escaping link at
# pre-push instead of at tag time.
test_archive_links_repo_head_is_clean() {
    local tgz="$WORKDIR/al-head.tar.gz" out rc=0
    (
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
            GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
        git -C "$REPO_ROOT" -c tar.umask=0022 archive --format=tar.gz \
            --prefix=librarian-test/ -o "$tgz" HEAD
    ) || {
        assert_true "false" "archive of the repo HEAD built"
        return 0
    }
    out="$(command bash "$LINK_GUARD" "$tgz" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "the repo's own HEAD archive ships no absolute or escaping symlink"
    assert_not_contains "$out" ".codegraph" "the .codegraph cache link is no longer in the tree"
}

test_gitignore_matches_codegraph_symlink() {
    # `.codegraph/` (trailing slash) matches only a directory, which is how the
    # symlink got committed. Probe with a real symlink, not the pattern text.
    local repo rc=0
    repo="$(command mktemp -d "$WORKDIR/al-ign.XXXXXX")" || return 1
    command cp "$REPO_ROOT/.gitignore" "$repo/.gitignore"
    (
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
            GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
        cd "$repo" || exit 1
        git init -q && command ln -s /cache/codegraph .codegraph &&
            git check-ignore -q .codegraph
    ) || rc=$?
    assert_exit 0 "$rc" ".gitignore ignores a .codegraph symlink"
}

test_release_yml_runs_link_guard() {
    local rel="$REPO_ROOT/.github/workflows/release.yml"
    assert_file_contains "$rel" '^ *bash bin/check-archive-links.sh "[$]tarball" || exit 1$' \
        "release.yml runs the link guard with an explicit failure check"
    # Presence alone survives a reordering: the guard must sit AFTER the archive
    # is built and BEFORE it is signed. Comment lines are skipped so prose naming
    # a command cannot shift the order.
    local order
    order="$(command awk '
        /^[[:space:]]*#/ { next }
        !a && index($0, "git -c tar.umask=0022 archive") { a = NR }
        !g && index($0, "bash bin/check-archive-links.sh") { g = NR }
        !s && index($0, "cosign sign-blob") { s = NR }
        END { printf "%d %d %d", a, g, s }' "$rel")"
    local a_ln g_ln s_ln
    read -r a_ln g_ln s_ln <<EOF
$order
EOF
    assert_true "[ \"$a_ln\" -gt 0 ] && [ \"$a_ln\" -lt \"$g_ln\" ] && [ \"$g_ln\" -lt \"$s_ln\" ]" \
        "release.yml runs the link guard after archiving and before signing (archive=$a_ln guard=$g_ln sign=$s_ln)"
}
