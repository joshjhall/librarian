#!/usr/bin/env bash
# worktree-new.sh — create a push-ready golem worktree for issue N (idempotent).
#
# Replaces the containers `worktree-new` just recipe so the golem/worktree
# flow runs WITHOUT `just`, on host / bare Linux / inside a devcontainer.
#
# Creates <GOLEM_WORKTREE_DIR>/issue-N on branch <GOLEM_BRANCH_PREFIX>N from
# <GOLEM_BASE_REF> and copies in the gitignored, machine-local files a push
# needs (GOLEM_WORKTREE_LOCAL_FILES — e.g. .env, .claude/settings.local.json).
#
# Config (env-overridable; defaults in config.sh):
#   GOLEM_WORKTREE_DIR  (.worktrees)  GOLEM_BRANCH_PREFIX (feature/issue-)
#   GOLEM_BASE_REF      (origin/main) GOLEM_WORKTREE_LOCAL_FILES
#   GOLEM_CARGO_CACHE_DIR (/cache/target)
#
# Usage: worktree-new.sh <issue-number>
set -euo pipefail

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

# Scrub git's hook-exported environment process-wide (#328). repo_root()
# (config.sh) already scrubs its OWN rev-parse subshell (#279), but this script
# then runs its own git MUTATIONS below (worktree add / branch --list / fetch /
# submodule update); a tainted GIT_DIR/GIT_COMMON_DIR forwarded from a git hook
# would redirect those to an OUTER repo — the worktree dir lands here but the new
# branch ref lands there, a split-brain state (dynamically reproduced in #328's
# review). `cd "$root"` does not re-anchor git while GIT_DIR is set, so unset the
# whole set here, before repo_root() and every other git call. Deliberately NO
# `|| true`: a readonly GIT_DIR makes `unset` fail, which under `set -e` aborts
# LOUDLY before any mutation — the fail-loud outcome, never a silent wrong-repo
# write. Uses config.sh's shared _git_env_scrub_names (#356 / #355) so the scrub
# set — static vars PLUS the dynamic GIT_CONFIG_KEY_<n>/VALUE_<n> pairs — stays in
# lockstep with repo_root()'s and worktree-rm.sh's, one source of truth.
# shellcheck disable=SC2046  # intentional word-split: unset each scrub var by name
unset $(_git_env_scrub_names)

N="${1:-}"
if ! [[ "$N" =~ ^[0-9]+$ ]]; then
    command echo "worktree-new: N must be an issue number, got '$N'" >&2
    exit 2
fi

root="$(repo_root)"
cd "$root"
wt="$GOLEM_WORKTREE_DIR/issue-$N"
br="${GOLEM_BRANCH_PREFIX}${N}"

# Both properties at once, rather than trading one for the other (#928 review).
# `git worktree list` failing must NOT read as "no such worktree" — that would
# let this create a second worktree over a broken repo. But keeping the PIPE to
# preserve git's exit status also keeps the #928 SIGPIPE inversion this very PR
# is about: a genuine match makes `grep -q` exit first, git dies 141, and
# pipefail turns "worktree EXISTS" into "absent". Capture first: the here-string
# leaves no writer to signal.
#
# The `set -e` half is MEASURED, not assumed (git 2.55.0, corrupted .git/HEAD):
# the capture form exits 128, while the old piped form exits 0 and reports the
# worktree ABSENT — silently absorbing the failure and proceeding. It carries no
# regression test: every cheap way to break `git worktree list` also breaks the
# earlier `repo_root` call, so such a test passes for the wrong reason. Recorded
# as measured-but-unguarded rather than asserted-and-untested.
wt_list="$(command git worktree list --porcelain)"
if command grep -qx "worktree $root/$wt" <<<"$wt_list"; then
    command echo "worktree-new: $wt already exists — remove it first (worktree-rm.sh $N)" >&2
    exit 1
fi
if [ -n "$(command git branch --list "$br")" ]; then
    command echo "worktree-new: branch $br already exists — delete it or pick another issue" >&2
    exit 1
fi

# Fetch the base ref's remote (if any) so the worktree forks from up-to-date
# state. GOLEM_BASE_REF is typically "origin/main"; derive the remote + branch.
case "$GOLEM_BASE_REF" in
    */*)
        base_remote="${GOLEM_BASE_REF%%/*}"
        base_branch="${GOLEM_BASE_REF#*/}"
        command git fetch "$base_remote" "$base_branch" --quiet || true
        ;;
esac

command git worktree add "$wt" -b "$br" "$GOLEM_BASE_REF"

# Populate submodules the worktree's checkout references (e.g. a `containers`
# submodule whose bin/fix-*.sh the root lefthook pre-commit hook calls). Plain
# `git worktree add` never populates submodules, so in a consuming repo where a
# submodule ships the pre-commit fixers, every commit in the worktree fails the
# hook non-deterministically depending on the submodule's checkout state at
# `worktree add` time (issue #325, migrated from containers#638). `--init
# --recursive` respects each submodule's `.gitmodules` `update = none` pin (it
# prints "Skipping submodule"), so librarian's own pinned `containers` submodule
# is a no-op here while a live submodule in a consuming repo gets populated; a
# repo with no submodules is a clean no-op. Best-effort with a LOUD warning: a
# populate failure (offline/auth) must not abort an otherwise-good worktree, but
# it must never be silent — the silent missing-hook-script mystery (a golem spent
# ~20 min on it) is exactly the bug this fixes.
# GIT_TERMINAL_PROMPT=0 so a submodule with an HTTPS remote and no cached
# credentials fails fast instead of hanging on an interactive username/password
# prompt — an indefinite hang would defeat the best-effort intent (this can be
# run from a real terminal, not only a headless golem). Mirrors the fail-fast
# posture of golem-launch.sh's bounded auth read.
if ! GIT_TERMINAL_PROMPT=0 command git -C "$wt" submodule update --init --recursive; then
    command echo "worktree-new: WARNING — submodule init failed in $wt;" \
        "pre-commit hooks that call submodule scripts may fail there" >&2
fi

for f in $GOLEM_WORKTREE_LOCAL_FILES; do
    if [ -e "$f" ]; then
        command mkdir -p "$wt/$(command dirname "$f")"
        command cp "$f" "$wt/$f"
        command echo "  copied $f"
    else
        command echo "  skipped $f (not present in main checkout)"
    fi
done

# Wire the platform CLI's token into git so HTTPS pushes work from this
# worktree (#810). `gh`/`glab` is the authenticated identity everywhere in this
# pipeline, but git has no way to reach it on its own and dies at ship time with
#
#     fatal: could not read Username for 'https://github.com'
#
# — after the full pre-push suite has already run. An interactive operator fixes
# that in one line; a DETACHED tmux/container golem has nobody to answer and
# dead-end parks with the work complete and only delivery failed. Same
# make-this-worktree-usable intent as the local-file copy above.
#
# SCOPE (measured, #810): `git config --local` from inside a linked worktree
# writes the SHARED .git/config unless `extensions.worktreeConfig` is enabled
# (it is not, by default). That is deliberate here — the seed is durable across
# teardown and fixes every later worktree of this repo, which is exactly what
# the hand-applied workaround did. worktree-rm.sh correspondingly does NOT
# unset it.
#
# Best-effort, and quiet on the paths where doing nothing is correct: no
# remote, a non-HTTPS remote (ssh uses keys and needs no helper), an
# unrecognized host, or the platform CLI absent all no-op rather than writing
# spurious config or hard-failing an otherwise-good worktree.
#
# Reuses the remote already derived for the base-ref fetch above so there is
# only one notion of "which remote"; GOLEM_BASE_REF may carry no remote
# component (e.g. a bare `HEAD`), hence the `origin` fallback.
cred_remote="${base_remote:-origin}"
cred_url="$(command git remote get-url "$cred_remote" 2>/dev/null || true)"
case "$cred_url" in
    https://*)
        # Split the AUTHORITY off first (everything before the first `/`), then
        # strip `userinfo@` inside it. Order matters both ways:
        #   * up to the LAST `@`, since a URL-embedded password may contain one
        #     (`bot:p@ss@host`);
        #   * but only WITHIN the authority, because a greedy `##*@` over the
        #     whole post-scheme string also eats the host whenever the PATH
        #     contains an `@` — `https://ghe.example.com/org/repo@release.git`
        #     derives the host `release.git` (verified).
        # Splitting first makes both cases fall out at once.
        cred_authority="${cred_url#https://}"
        cred_authority="${cred_authority%%/*}"
        cred_authority="${cred_authority##*@}"
        # The config KEY keeps the port: git's credential lookup matches on the
        # full URL, so a remote at host:8443 must be keyed as host:8443.
        cred_host="https://$cred_authority"
        # Same platform table the workflow skills use (next-issue § Platform
        # Detection): github.com/ghe. -> gh, gitlab.com/gitlab. -> glab.
        #
        # Matched on the BARE host and ANCHORED ON A DOT BOUNDARY. A bare
        # `*github.com` suffix glob is the classic unanchored-hostname
        # anti-pattern: it also matches `evil-github.com` and
        # `notarealgithub.com` (verified — both selected `gh`), and `*ghe.*`
        # matches that 4-char sequence anywhere in the string. Nothing leaks a
        # credential, because gh/glab each gate on hosts they recognize — but
        # this would still write a `credential.<lookalike-host>.helper` entry
        # into the SHARED .git/config, keyed off attacker-influenceable URL
        # text, from inside a credential-wiring path. Anchoring costs nothing
        # and keeps every legitimate host: github.com, any *.github.com,
        # ghe.example.com and its subdomains, gitlab.com, gitlab.acme.io.
        #
        # The MATCH strips a `:port`; the config KEY above keeps it, because
        # that is what git looks up. The strip matters only for the ANCHORED
        # arms — `github.com:8443` matches nothing until the port is gone,
        # whereas a prefix arm like `ghe.*` matches a ported host either way
        # (measured; the port-strip mutation survived a `ghe.` fixture, which is
        # why the test uses `github.com:8443`).
        #
        # The two self-hosted arms (`ghe.*`, `gitlab.*`) are PREFIX matches, not
        # full anchors, and deliberately so: a self-hosted deployment has no
        # fixed suffix to anchor against, so supporting `gitlab.acme.io` at all
        # means accepting any `gitlab.`-prefixed host. That is a weaker
        # guarantee than the `github.com`/`gitlab.com` arms above give — noted
        # here so a later reader does not mistake it for full anchoring.
        cred_bare_host="${cred_authority%%:*}"
        cred_cli=""
        case "$cred_bare_host" in
            github.com | *.github.com) cred_cli="gh" ;;
            ghe.* | *.ghe.*) cred_cli="gh" ;;
            gitlab.com | *.gitlab.com) cred_cli="glab" ;;
            gitlab.* | *.gitlab.*) cred_cli="glab" ;;
        esac
        if [ -n "$cred_cli" ] && command -v "$cred_cli" >/dev/null 2>&1; then
            cred_helper="!$cred_cli auth git-credential"
            # Read before writing (#877). `git config <key> <value>` REPLACES a
            # single-valued key outright, so an unconditional write silently
            # destroys whatever the operator deliberately chose for this host —
            # a keychain helper, credential-cache, a smartcard-backed helper.
            # Two properties of the SCOPE block above make that worse than a
            # local mistake: the write lands in the SHARED .git/config, so it
            # changes credential behavior for the main checkout and every other
            # worktree; and worktree-rm.sh deliberately never unsets it, so
            # teardown does not restore the original choice. A DIFFERENT
            # existing value is therefore treated as the operator's decision,
            # not as something to correct.
            #
            # --get-all, not --get: on a multi-valued key `--get` returns only
            # the LAST value (measured, git 2.55), which would read a
            # multi-valued helper as if it were a single one. Comparing the FULL
            # output against the one helper we would write also means a
            # multi-valued key that merely CONTAINS our helper alongside another
            # still reads as configured and is left alone — presence of any
            # value is enough. `|| true` because --get-all exits 1 on an absent
            # key and this script runs under `set -e`.
            #
            # --local on the READ, matching the scope of the write below. A bare
            # `git config --get-all` returns the MERGED view across system,
            # global, local and worktree scopes, so a host-scoped helper in the
            # operator's ~/.gitconfig would read as "already configured" and
            # suppress a local seed that had never been written (measured: a
            # `--global credential.https://github.com.helper` makes the bare read
            # return it while `--local` returns empty). That is the wrong call in
            # both directions: this guard exists to protect what is IN the shared
            # .git/config that the seed would overwrite, and a global helper is
            # not overwritten by a --local write, so skipping on account of one
            # suppresses the seed while destroying nothing — reintroducing #810's
            # `could not read Username` whenever that global helper does not
            # actually serve this host. Read and write must name the same scope.
            #
            # An IDENTICAL existing value falls to the else branch and rewrites
            # the same bytes: that is the overwhelmingly common case (every
            # later worktree of this repo) and must stay a clean no-op with no
            # new output. This narrows the seed's blast radius only; it does not
            # weaken the durability the SCOPE block above describes.
            cred_existing="$(command git -C "$wt" config --local --get-all \
                "credential.${cred_host}.helper" 2>/dev/null || true)"
            if [ -n "$cred_existing" ] && [ "$cred_existing" != "$cred_helper" ]; then
                command echo "  keeping the existing git credential helper for $cred_host"
            else
                command git -C "$wt" config --local \
                    "credential.${cred_host}.helper" "$cred_helper" || true
                # Verify rather than assume: a silent failure to set this
                # resurfaces much later as the original `fatal:`, at ship time,
                # with no clue pointing back here. Same fail-loud posture as the
                # submodule warning above.
                # --local here too: the write above is --local, so a bare
                # (merged) read could confirm success from an operator's GLOBAL
                # helper when the local write silently failed — precisely the
                # false "seeded" report this verify block exists to prevent.
                if [ "$(command git -C "$wt" config --local --get \
                    "credential.${cred_host}.helper" 2>/dev/null)" = "$cred_helper" ]; then
                    command echo "  seeded git credential helper ($cred_cli) for $cred_host"
                else
                    command echo "worktree-new: WARNING — could not seed the git credential" \
                        "helper for $cred_host; pushes from $wt may fail with" \
                        "'could not read Username'" >&2
                fi
            fi
        fi
        ;;
esac

# Seed a per-worktree Rust build-artifact directory OFF the repo mount (#944).
#
# WHY: on the macOS Docker stack the repo lives on virtiofs, whose host-side
# daemon loses inode mappings and leaves stale dentries that return EBADF from
# `unlink`/`stat` while still appearing in `readdir` — an undeletable worktree
# (#936 corrected #834's attribution to this layer; NO in-container call repairs
# it). Every wedged entry in the two live remnants was a
# `target/debug/incremental/*.o`. #936 landed the QUARANTINE, which makes the
# wedge recoverable; this is the PREVENTION half, so it forms less often.
#
# WHY THE SETTINGS FILE AND NOT `.cargo/config.toml` — measured, git 2.55.0.
# The obvious durable spelling is `build.target-dir` in a worktree
# `.cargo/config.toml`. It cannot be used, because that file is UNTRACKED and
# nothing available can hide it from `git status`:
#
#   exclude file                                  | honored?
#   ----------------------------------------------|---------
#   .git/worktrees/<wt>/info/exclude (per-worktree)| NO  — `?? .cargo/`
#   .git/info/exclude (shared)                     | yes — but see below
#
# So the worktree reads DIRTY and worktree-rm.sh refuses teardown on every
# golem — trading a rare wedge for a guaranteed teardown refusal. The shared
# exclude does work, but it is repo-wide and outlives the worktree: it equally
# suppresses `.cargo/` in the MAIN checkout, a far larger blast radius than this
# change appears to have. (`git config --worktree` is not an escape either:
# `extensions.worktreeConfig` is unset by default, so git refuses it.)
#
# Nor can this be an `export`, which is what #936 originally proposed: this is a
# one-shot script whose environment dies with it, while `cargo` runs minutes or
# hours later in some other process.
#
# The settings file clears all three traps at once: in a repo whose TRACKED
# .gitignore covers `.claude/settings.local.json` (librarian's does), writing it
# cannot dirty the worktree, so teardown is unaffected; Claude Code sets `env`
# for every session AND ITS SUBPROCESSES, so a later `cargo` invocation actually
# sees it; and it is scoped to this worktree alone.
#
# The file is USUALLY already present, copied by the GOLEM_WORKTREE_LOCAL_FILES
# loop above — but that list is operator-overridable, so this block does not
# depend on it: an absent file is created here holding only the env key. Said
# explicitly because the reverse claim ("it is already copied in") would be a
# comment asserting something the code does not guarantee.
#
# That ignore property is VERIFIED per-repo below rather than assumed — it holds
# for librarian but is not universal, and getting it wrong reproduces the very
# dirty-worktree failure this paragraph rules out.
#
# SCOPE, stated plainly: this reaches `cargo` when the build is invoked from a
# Claude Code session in this worktree — the golem case, which is what forms the
# wedge, since a golem's builds all run through that machinery. A human who opens
# their own terminal in the worktree and types `cargo build` gets the default
# ./target and can still wedge it; nothing here writes a shell profile, and the
# repo-file alternative that WOULD cover them is the `.cargo/config.toml` ruled
# out above. That is a deliberate coverage limit, not an oversight: #936's
# quarantine already makes the resulting wedge recoverable.
#
# PER-WORKTREE, never shared: one target dir across parallel golems would
# serialise them on cargo's file lock.
#
# Best-effort and SILENT when unsuitable — an absent, unwritable, or
# still-wedging cache location leaves behaviour byte-identical (no write, no
# output). The location is a runtime PROBE, not an assumption: measured in the
# devcontainer, both /cache and /workspace report overlayfs, so "/cache is
# obviously off virtiofs" is exactly the belief that had to be checked.
cargo_cache_fstype() {
    # Echo the filesystem type backing $1 by longest-prefix match over
    # /proc/mounts, or nothing when it cannot be determined. Linux-only by
    # design; a host without /proc/mounts (macOS) yields nothing and the caller
    # skips, which is the safe direction — see the caller's comment.
    local target="$1" mp fstype prefix best_mp="" best_fs=""
    [ -r /proc/mounts ] || return 0
    while read -r _dev mp fstype _rest; do
        # Strip a trailing slash before building the prefix, so the ROOT
        # mountpoint `/` compares as `` + `/…` rather than `//…` — the latter
        # matches nothing, which made every path outside a deeper mount probe
        # as UNKNOWN and silently refuse the seed on every host (caught by the
        # positive-case test, invisible to the no-op ones).
        prefix="${mp%/}"
        case "$target" in
            "$mp" | "$prefix"/*)
                if [ "${#mp}" -ge "${#best_mp}" ]; then
                    best_mp="$mp"
                    best_fs="$fstype"
                fi
                ;;
        esac
    done </proc/mounts
    command echo "$best_fs"
}

cargo_seed_target="$GOLEM_CARGO_CACHE_DIR/issue-$N"
# The CONFIGURED directory must itself already exist. Deliberately NOT an
# ancestor walk: climbing to the deepest existing parent makes an absent cache
# location probe as PRESENT (every path has an existing ancestor, ultimately
# `/`), and the mkdir below then CREATES the location that was supposed to be
# missing — so "absent leaves behaviour unchanged" (AC4) silently becomes
# "absent gets provisioned anywhere the operator happened to point". Requiring
# the dir up front also makes the override a real off switch: pointing
# GOLEM_CARGO_CACHE_DIR at a nonexistent path disables the seed, which is what
# the test sandboxes rely on.
if [ -d "$GOLEM_CARGO_CACHE_DIR" ] && [ -w "$GOLEM_CARGO_CACHE_DIR" ] &&
    command -v jq >/dev/null 2>&1; then
    # CANONICALIZE before probing. /proc/mounts lists RESOLVED mountpoints, so a
    # literal-path prefix match classifies the mount that happens to contain the
    # path STRING rather than the one that will actually hold the writes. With a
    # symlinked cache dir (or a symlinked ancestor) the two differ — measured:
    # the same directory reads `overlay` through /tmp/link and `tmpfs` at its
    # real /dev/shm path. The dangerous direction is a FALSE NEGATIVE: a benign
    # fstype reported for a target whose real backing store is virtiofs, which
    # is precisely what this probe exists to refuse.
    #
    # Fall back to the raw path when readlink is absent or fails, so the
    # behaviour degrades to the previous (still fail-safe-on-unknown) reading
    # rather than erroring. `readlink -f` is not among the GNU-only flags this
    # repo bans; BSD readlink has supported -f since macOS 12.3, and the
    # fallback covers anything older.
    cargo_probe_dir="$(command readlink -f "$GOLEM_CARGO_CACHE_DIR" 2>/dev/null)" ||
        cargo_probe_dir=""
    [ -n "$cargo_probe_dir" ] || cargo_probe_dir="$GOLEM_CARGO_CACHE_DIR"
    # Refuse the filesystems that produce the wedge. virtiofs is the measured
    # culprit; fuse.* covers the bindfs overlay layered on it, and 9p is the
    # same class of host-passthrough mount on other Docker backends. An
    # UNKNOWN type (no /proc/mounts — e.g. a bare macOS host) also refuses:
    # skipping costs only the optimisation, while seeding onto a wedging mount
    # would relocate the very failure this prevents.
    cargo_fs="$(cargo_cache_fstype "$cargo_probe_dir")"
    cargo_fs_ok=""
    case "$cargo_fs" in
        "" | virtiofs | fuse | fuse.* | 9p) ;;
        *) cargo_fs_ok="yes" ;;
    esac
    # The write is only safe while the target is IGNORED by the repo. That is
    # true of librarian (.claude/settings.local.json is in the TRACKED
    # .gitignore) but is not a property of every consuming repo, and the whole
    # reason this mechanism was chosen over `.cargo/config.toml` is that an
    # untracked file makes the worktree read DIRTY — whereupon worktree-rm.sh
    # refuses teardown on every golem. So ASK GIT rather than assume: if the
    # path is not ignored, skip silently and leave the worktree pristine. Found
    # the hard way — the first implementation skipped this check and turned 18
    # unrelated worktree-rm tests red with `?? .claude/`.
    cargo_ignored=""
    if [ -n "$cargo_fs_ok" ] && command git -C "$wt" check-ignore -q \
        ".claude/settings.local.json" 2>/dev/null; then
        cargo_ignored="yes"
    fi
    if [ -n "$cargo_ignored" ] && command mkdir -p "$cargo_seed_target" 2>/dev/null; then
        cargo_settings="$wt/.claude/settings.local.json"
        command mkdir -p "$wt/.claude"
        [ -f "$cargo_settings" ] || command printf '{}\n' >"$cargo_settings"
        # Temp file ADJACENT to the target, committed with an atomic `mv` —
        # never a `cat >` truncate, which on an interrupted write would leave
        # the worktree's settings corrupt and its permission gates unloadable.
        # Same discipline seed-worktree-trust.sh documents for ~/.claude.json.
        cargo_tmp="$cargo_settings.944.$$"
        if command jq --arg t "$cargo_seed_target" \
            '.env = ((.env // {}) + {CARGO_TARGET_DIR: $t})' \
            "$cargo_settings" >"$cargo_tmp" 2>/dev/null &&
            command mv "$cargo_tmp" "$cargo_settings"; then
            command echo "  seeded CARGO_TARGET_DIR=$cargo_seed_target ($cargo_fs)"
        else
            # Leave the original settings untouched on any failure: a malformed
            # existing file, a jq error, or a failed rename all land here.
            command rm -f "$cargo_tmp"
        fi
    fi
fi

# Seed a workspace-trust entry for the new worktree path so the copied
# settings.local.json (defaultMode "auto" + push/PR `ask` gates) actually
# loads — Claude Code does not load project settings for an UNTRUSTED folder,
# and a non-interactive tmux launch can't show the trust dialog. Complements
# the explicit `--permission-mode auto` in the launch hint below (which works
# even if this step is unavailable). Best-effort; always exits 0.
if [ -x "$SCRIPT_DIR/seed-worktree-trust.sh" ]; then
    "$SCRIPT_DIR/seed-worktree-trust.sh" "$root/$wt"
fi

command echo ""
command echo "Worktree ready: $wt (branch $br)"
command echo "Launch a golem there with:"
# $(golem_model_flag) splices ` --model "…"` after each `claude` when GOLEM_MODEL
# is set (so the copy-paste hint already carries the operator's chosen model),
# and expands to nothing — byte-identical hint — when unset.
MODEL_FLAG="$(golem_model_flag)"
command echo "  tmux new-session -d -s golem-$N -c \"$root/$wt\" -e GOLEM_ID=golem-$N \"claude$MODEL_FLAG --permission-mode auto '/workflow:next-issue $N --level 4' ; claude$MODEL_FLAG --permission-mode auto '/workflow:ship-issue'\""
