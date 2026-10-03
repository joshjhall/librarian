# shellcheck shell=bash
# Group H — bin/check-archive-modes.sh + the release.yml archive mask (#1101).
#
# Before #1101, release.yml ran `git archive` with no `tar.umask`, so entry modes
# followed the runner's 0002 process umask and every entry of the signed tarball
# shipped group-writable. The fix pins `-c tar.umask=0022` and runs the guard
# before signing. release.yml only runs on a pushed tag, so the guard is driven
# here against real `git archive` output at BOTH masks: the 0002 archive is the
# live control proving the guard can fire, the 0022 one that the fix is clean.
#
# Sourced by tests/validate-release.sh, which defines REPO_ROOT and sources
# tests/lib/release-sandbox.sh (for WORKDIR) BEFORE this file. This fragment only
# DEFINES test functions; the entry point dispatches them.

ARCHIVE_GUARD="$REPO_ROOT/bin/check-archive-modes.sh"

# am_archive <umask> <out.tar.gz>
# Builds a throwaway repo holding a plain file, an executable, a subdir and a
# symlink, then archives it with the given tar.umask. Runs in a subshell with
# git's hook-exported variables unset: under the pre-push hook an inherited
# GIT_DIR would point every call here at the OUTER repo.
am_archive() {
    local mask="$1" out="$2" repo
    repo="$(command mktemp -d "$WORKDIR/am.XXXXXX")" || return 1
    (
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
            GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
        cd "$repo" || exit 1
        command mkdir -p scripts
        command printf 'x\n' >README
        command printf 'run\n' >scripts/run.sh
        command chmod +x scripts/run.sh
        command ln -s README link
        git init -q &&
            git add -A &&
            git -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
                commit -q -m init &&
            git -c tar.umask="$mask" archive --format=tar.gz --prefix=p/ \
                -o "$out" HEAD
    )
}

test_archive_modes_flags_group_writable() {
    local tgz="$WORKDIR/am-0002.tar.gz" out rc=0
    am_archive 0002 "$tgz" || {
        assert_true "false" "fixture archive (0002) built"
        return 0
    }
    out="$(command bash "$ARCHIVE_GUARD" "$tgz" 2>&1)" || rc=$?
    assert_exit 1 "$rc" "a 0002-masked archive is rejected"
    assert_contains "$out" "scripts/run.sh" "the offending executable is named"
    # `p/scripts/` alone is also a substring of the run.sh line, so match the
    # directory's OWN line: it ends at the trailing slash.
    local dir_lines
    dir_lines="$(printf '%s\n' "$out" | command awk '/^  d/ && / p\/scripts\/$/')"
    assert_not_empty "$dir_lines" "the offending directory entry itself is named"
    # 4 of 5: p/, p/README, p/scripts/, p/scripts/run.sh — the symlink excluded.
    assert_contains "$out" "4 of 5 entries" "every non-symlink offender is counted, dirs included"
    assert_not_contains "$out" "p/link" "the symlink (always lrwxrwxrwx) is not flagged"
}

test_archive_modes_accepts_pinned_mask() {
    local tgz="$WORKDIR/am-0022.tar.gz" out rc=0
    am_archive 0022 "$tgz" || {
        assert_true "false" "fixture archive (0022) built"
        return 0
    }
    out="$(command bash "$ARCHIVE_GUARD" "$tgz" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "a 0022-masked archive passes"
    # 5 entries: p/, p/README, p/link, p/scripts/, p/scripts/run.sh. Pinning the
    # count proves the scan read the listing, not an empty one.
    assert_contains "$out" "5 entries" "every entry was scanned, symlink included"
}

test_archive_modes_world_writable_only() {
    # Other-write alone (group bit clear) must fire too: 0020 clears group-write
    # but leaves other-write on.
    local tgz="$WORKDIR/am-0020.tar.gz" rc=0
    am_archive 0020 "$tgz" || {
        assert_true "false" "fixture archive (0020) built"
        return 0
    }
    command bash "$ARCHIVE_GUARD" "$tgz" >/dev/null 2>&1 || rc=$?
    assert_exit 1 "$rc" "a world-writable (group-clean) archive is rejected"
}

test_archive_modes_fails_loud_on_bad_input() {
    local rc=0
    command bash "$ARCHIVE_GUARD" "$WORKDIR/does-not-exist.tar.gz" >/dev/null 2>&1 || rc=$?
    assert_exit 2 "$rc" "a missing tarball is a usage error, not a clean pass"
    rc=0
    command printf 'not a tarball' >"$WORKDIR/am-junk.tar.gz"
    command bash "$ARCHIVE_GUARD" "$WORKDIR/am-junk.tar.gz" >/dev/null 2>&1 || rc=$?
    assert_exit 2 "$rc" "an unlistable tarball fails loud"
    rc=0
    # A valid but EMPTY tarball lists cleanly and finds nothing, so it must be
    # refused explicitly: zero entries scanned is not a clean verdict.
    # Built as 1024 zero bytes (a bare end-of-archive marker), not `tar -T
    # /dev/null`, which bsdtar may refuse. The message is pinned so a fixture
    # that failed to build cannot pass via the missing-file branch.
    local out
    command head -c 1024 /dev/zero | command gzip >"$WORKDIR/am-empty.tar.gz"
    out="$(command bash "$ARCHIVE_GUARD" "$WORKDIR/am-empty.tar.gz" 2>&1)" || rc=$?
    assert_exit 2 "$rc" "an empty tarball is refused, not reported clean"
    assert_contains "$out" "lists no entries" "the empty-listing branch is the one that refused"
    rc=0
    command bash "$ARCHIVE_GUARD" >/dev/null 2>&1 || rc=$?
    assert_exit 2 "$rc" "no argument prints usage"
}

# release.yml only runs on a tag push, so its archive command cannot be executed
# here; what is checkable is that the shipped command carries the mask and the
# guard, and that the README's reproduce command matches it.
test_release_yml_pins_archive_mask() {
    local rel="$REPO_ROOT/.github/workflows/release.yml"
    assert_file_defines "$rel" 'git -c tar.umask=0022 archive --format=tar.gz' \
        "release.yml archives with tar.umask pinned to 0022"
    assert_file_not_contains "$rel" '^[[:space:]]*git archive' \
        "release.yml has no unmasked git archive call left"
    # Not assert_file_defines: that helper pins `NAME=` definitions, and this
    # line has no `=`. `[$]` keeps the dollar literal in BRE on GNU and BSD.
    assert_file_contains "$rel" '^ *bash bin/check-archive-modes.sh "[$]tarball" || exit 1$' \
        "release.yml runs the mode guard with an explicit failure check"
    # Presence alone survives a reordering: the guard must sit AFTER the
    # archive is built and BEFORE it is signed, or a bad tarball still ships
    # signed. Compare the first line number of each, by fixed-string index(),
    # skipping comment lines so prose naming a command cannot shift the order.
    local order
    order="$(command awk '
        /^[[:space:]]*#/ { next }
        !a && index($0, "git -c tar.umask=0022 archive") { a = NR }
        !g && index($0, "bash bin/check-archive-modes.sh") { g = NR }
        !s && index($0, "cosign sign-blob") { s = NR }
        END { printf "%d %d %d", a, g, s }' "$rel")"
    local a_ln g_ln s_ln
    read -r a_ln g_ln s_ln <<EOF
$order
EOF
    assert_true "[ \"$a_ln\" -gt 0 ] && [ \"$a_ln\" -lt \"$g_ln\" ] && [ \"$g_ln\" -lt \"$s_ln\" ]" \
        "release.yml runs the guard after archiving and before signing (archive=$a_ln guard=$g_ln sign=$s_ln)"
    assert_file_contains "$REPO_ROOT/README.md" \
        'git -c tar.umask=0022 archive --format=tar.gz --prefix=librarian-<version>/ v<version>' \
        "README's reproduce command carries the same mask"
}
