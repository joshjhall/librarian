#!/usr/bin/env bash
# Is this pre-push invocation a PURE branch deletion? (#1054)
#
# Reads git's pre-push ref lines on stdin and exits 0 when every ref being
# pushed is a deletion, i.e. the push transfers no objects and changes no file.
# Callers use that to skip work that only makes sense for content:
#
#   quality-gates (lefthook pre-push)   bash tests/run-all.sh  (~700s)
#
# WHY THIS EXISTS. `git push origin --delete <branch>` ran the entire test
# suite before git transferred anything. lefthook's `glob:` is evaluated from
# `PushFiles()`, which is `git diff --name-only HEAD @{push}` — it compares HEAD
# to its upstream and never looks at the ref being pushed, so on a delete the
# file list is non-empty anyway, the glob matches, and the gate runs. Measured
# ~700s to delete a ref whose commits had already passed that same suite at push
# time. The cost is not just the wait: a 12-minute no-op on a routine teardown
# is what tempts someone into `--no-verify`, which this repo forbids.
#
# WHY STDIN, AND NOT ANY OF THE CHEAPER SIGNALS. Each of these was measured and
# rejected, so they are recorded here rather than re-tried:
#
#   - Working-tree state is IDENTICAL on a delete and a normal push. HEAD,
#     current branch, upstream and ahead-count all read the same, so no
#     `git rev-parse` predicate can tell them apart.
#   - lefthook's `{0}`/`{1}`/`{2}` carry only the remote NAME and URL
#     (`origin https://...`) — git passes the refs on stdin, never in argv, so
#     these are identical on both too.
#   - There is no `LEFTHOOK_*` env var carrying the refs.
#   - Walking the process tree to the parent `git push` argv DOES reveal
#     `--delete`, but it is both fragile and INCOMPLETE: `git push origin :br`
#     deletes the same branch with no `--delete` anywhere in argv.
#
# Only the stdin ref lines are authoritative, which is why the caller must pass
# `use_stdin: true` (lefthook buffers a copy per consumer, so several commands
# can each read them).
#
# The format git writes is `<local-ref> <local-sha> <remote-ref> <remote-sha>`,
# and a deletion is unambiguous: the local ref is the literal `(delete)` and the
# local sha is all zeros.
#
# FAILS CLOSED. Empty stdin, an unreadable stream, or any line that is not a
# deletion exits non-zero — "run the gate". Refusing to decide must never mean
# skipping the suite, or this guard becomes a silent way to push unchecked work.
#
# Exit: 0 = pure delete (caller may skip), 1 = not a pure delete / unknown.

set -uo pipefail

refs=$(cat)

# No ref lines at all: cannot prove a deletion, so run the gate. This also
# covers a caller that forgot `use_stdin`, where stdin is empty rather than
# wrong — the failure is a needless suite run, never a skipped one.
[ -n "$refs" ] || exit 1

saw_ref=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    saw_ref=1
    # Split off the first two fields; a deletion is `(delete)` + 40 (or 64,
    # under sha256) zeros. Both are checked: either alone would accept a
    # malformed line that the other rejects.
    local_ref=${line%% *}
    rest=${line#* }
    local_sha=${rest%% *}

    [ "$local_ref" = "(delete)" ] || exit 1
    case "$local_sha" in
        *[!0]* | "") exit 1 ;;
    esac
done <<EOF
$refs
EOF

[ "$saw_ref" = "1" ] || exit 1
exit 0
