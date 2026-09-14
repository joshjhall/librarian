#!/usr/bin/env bash
# harness-stage.sh — resolve a bundled `workflow.js` harness and make it
# reachable by the `Workflow` tool from the CURRENT session's cwd (issue #973).
#
# ---------------------------------------------------------------------------
# THE PROBLEM, which is two problems that stack.
#
#   1. The `Workflow` tool only accepts a `scriptPath` under the session's
#      working directory (or a directory the session has added). The plugin
#      installs OUTSIDE that: /opt/librarian/... in the devcontainer image, or
#      ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/... on a host.
#      A golem's cwd is its worktree. So the real, present harness is REFUSED:
#
#        Error: scriptPath must be a script path this tool returned, or a file
#        you can already read (the working directory or a directory you have
#        added): /opt/librarian/plugins/workflow/skills/ship-issue/workflow.js
#
#   2. Eleven prose sites named `~/.claude/skills/<name>/workflow.js`, a path
#      that exists on NO tree — neither the dev checkout
#      (plugins/<plugin>/skills/<skill>/workflow.js) nor an installed one
#      (which carries plugins/cache/<mkt>/<plugin>/<version>/ segments).
#
# Fixing (2) alone does not help, and this is the load-bearing observation:
# NO LITERAL PATH CAN SATISFY BOTH. A path correct for the installed layout is
# by construction outside cwd, and a path under cwd does not exist until
# something puts it there. The fix has to RESOLVE and then STAGE, which is a
# script, not a string. That is also why this file exists rather than a
# corrected literal in each of the eleven sites: the path is now spelled ONCE.
#
# The cost of getting this wrong was not a broken run but a SILENT one. The
# documented degradation clause skipped the adversarial pre-PR review when the
# harness path was "absent from disk" — permanently true — so every golem
# replaced a five-dimension review plus a judge with
# `Review status: skipped (harness not available)`. Silence-reads-as-a-pass
# (#538/#571) at the most expensive site in the repo.
#
# ---------------------------------------------------------------------------
# WHY key=value ON STDOUT, and not a bare path.
#
# Callers run this from inside an `EnterWorktree`-isolated session, where the
# Bash tool REFUSES any command substitution (#815, next-issue/worktree-safe-recipes.md).
# `eval "$(harness-stage.sh …)"` does not merely fail there — a refused
# substitution yields the EMPTY STRING, so the variable silently stays unset and
# the caller proceeds on a default. So the contract is Pattern 1: run bare, READ
# the printed lines. Three keys, always all three:
#
#   path=    what to hand the `Workflow` tool as scriptPath
#   source=  where it was resolved from (for the record; may equal path)
#   staged=  true if a copy was made, false if source was already reachable
#
# ---------------------------------------------------------------------------
# RESOLUTION — three probes, lifted from _resolve_review_audit_scanner in
# ship-issue/pre-review-gates.sh (#708/#699) rather than re-derived. The two
# non-override shapes genuinely differ and neither subsumes the other:
#
#   1. LIBRARIAN_HARNESS_<ID>  explicit override. Also the seam the
#                              absent-harness tests drive, so the refusal path
#                              is exercised by FORCING absence rather than by
#                              skipping when nothing is missing.
#   2. dev checkout            plugins/<plugin>/<rel> is a fixed relative walk
#                              from this script's own directory.
#   3. installed cache         ONE further level up, because an installed plugin
#                              root carries a <version> segment the source tree
#                              does not. Selection PREFERS the version equal to
#                              this plugin's own — bin/release.sh stamps every
#                              plugin in lockstep (CLAUDE.md § Releases), so that
#                              match is exact and needs no arithmetic — and only
#                              then falls back to a field-by-field NUMERIC
#                              compare. Never `sort`, which ranks "10.0.0" below
#                              "9.9.9", and never `sort -V`, which is GNU-only
#                              and banned repo-wide.
#
# ---------------------------------------------------------------------------
# STAGING — copy ONLY when the source is not already under cwd.
#
# In librarian's own checkout the harness IS under cwd, and copying it there
# anyway would put a second, stale copy beside the real one — so an edit to
# `workflow.src/` + `just gen-workflow-js` would regenerate the artifact while
# the review kept running yesterday's bytes. That is a worse failure than the
# one this script fixes, because it is invisible. Hence: reachable => print it,
# do not copy.
#
# The staging directory is `.claude/tmp/harness/` under cwd, which .gitignore
# already covers via its bare `tmp/` rule (verified with `git check-ignore`) —
# no .gitignore change, and no chance of committing a copied harness.
#
# ---------------------------------------------------------------------------
# ABSENCE FAILS LOUD (#973 AC5). Exit 3 with every probe listed, never exit 0
# with no path. An unreachable harness is a BROKEN ENVIRONMENT, not a missing
# optional tool — the same call CLAUDE.md makes for the prose-budget gate
# ("fail loud on a missing runtime rather than returning the 77 sentinel").
# The distinction the caller needs, and the whole point of AC5, is between:
#
#   exit 3  unresolvable/unstageable  -> the environment is broken. Do NOT
#                                        deliver. This must never read as a
#                                        review that ran and found nothing.
#   exit 4  plugin genuinely absent   -> the harness ships with a plugin that is
#                                        not installed. The caller's documented
#                                        skip-and-park applies.
#
# Both are non-zero and both name what to do. What must never happen is a
# zero exit with an empty `path=`.
#
# Usage:
#   harness-stage.sh stage <harness-id> [--dir <cwd>]
#   harness-stage.sh path <harness-id>      # resolve only, never copy
#   harness-stage.sh list                   # known ids, one per line
#
# Exit codes:
#   0  resolved (and staged, for `stage`)
#   2  usage error (missing/unknown subcommand or id)
#   3  resolved nowhere, or the copy failed — BROKEN ENVIRONMENT, fail loud
#   4  the owning plugin is not installed — caller's skip-and-park applies
#
# Runtime: pure bash + coreutils. bash-3.2 clean (stock macOS): no `declare -A`,
# no `mapfile`, no namerefs, no `${v,,}`. BSD-safe: no `realpath -m`, no
# `mktemp --suffix=`, no GNU-only regex, no `env --unset=`.
# See CLAUDE.md § Key conventions (runtime policy).

set -uo pipefail

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"

USAGE='Usage:
  harness-stage.sh stage <harness-id> [--dir <cwd>]
  harness-stage.sh path  <harness-id>
  harness-stage.sh list

Harness ids: see `harness-stage.sh list`.
Override any id with LIBRARIAN_HARNESS_<ID>, e.g. LIBRARIAN_HARNESS_SHIP_ISSUE.'

die_usage() {
    command printf '%s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

# --- The harness table ------------------------------------------------------
#
# Two parallel lookups keyed by id, as functions rather than an associative
# array (bash 3.2 has none). Each id maps to:
#   _harness_plugin <id>  the plugin directory name that owns it
#   _harness_rel    <id>  the path under that plugin root
#
# Keeping the table here is the point of the whole file — this is the "spelled
# once" that #973 AC2 asks for. A caller names an ID; nobody outside this file
# writes a harness path.
_harness_plugin() {
    case "$1" in
        ship-issue | orchestrate) command printf 'workflow' ;;
        ci-fixer | rebase-agent) command printf 'workflow' ;;
        codebase-audit) command printf 'review-audit' ;;
        code-reviewer) command printf 'dev-core' ;;
        *) return 1 ;;
    esac
}

_harness_rel() {
    case "$1" in
        ship-issue) command printf 'skills/ship-issue/workflow.js' ;;
        orchestrate) command printf 'skills/orchestrate/workflow.js' ;;
        codebase-audit) command printf 'skills/codebase-audit/workflow.js' ;;
        ci-fixer) command printf 'agents/ci-fixer/workflow.js' ;;
        rebase-agent) command printf 'agents/rebase-agent/workflow.js' ;;
        code-reviewer) command printf 'agents/code-reviewer/workflow.js' ;;
        *) return 1 ;;
    esac
}

_HARNESS_IDS='ship-issue orchestrate codebase-audit ci-fixer rebase-agent code-reviewer'

# _override_var <id> — the env var name for an id: ship-issue ->
# LIBRARIAN_HARNESS_SHIP_ISSUE. `tr` rather than ${v^^}, which is bash 4.
_override_var() {
    command printf 'LIBRARIAN_HARNESS_%s' \
        "$(command printf '%s' "$1" | command tr 'a-z-' 'A-Z_')"
}

# _ver_gt A B — true when semver A is numerically greater than B. Field-by-field
# integer compare, the same idiom and the same reason as _prescan_ver_gt in
# pre-review-gates.sh and agnix_ver_lt in tests/lint-agnix-clean.sh: `sort -V` is
# GNU-only and banned, and a string compare is wrong in the one case that
# matters ("10.0.0" < "9.9.9" lexically). A non-integer field compares as 0, so a
# stray directory name can never outrank a real version.
_ver_gt() {
    _vg_i=1
    while [ "$_vg_i" -le 3 ]; do
        _vg_x="$(command printf '%s' "$1" | command cut -d. -f"$_vg_i")"
        _vg_y="$(command printf '%s' "$2" | command cut -d. -f"$_vg_i")"
        case "$_vg_x" in '' | *[!0-9]*) _vg_x=0 ;; esac
        case "$_vg_y" in '' | *[!0-9]*) _vg_y=0 ;; esac
        [ "$_vg_x" -gt "$_vg_y" ] && return 0
        [ "$_vg_x" -lt "$_vg_y" ] && return 1
        _vg_i=$((_vg_i + 1))
    done
    return 1
}

# _own_version — this plugin's own version segment, when running from an
# installed tree. SCRIPT_DIR is <root>/workflow/<version>/scripts, so the version
# is one level up from `scripts`. Empty in a dev checkout, which is correct:
# there is no version segment there and probe 2 already answered.
_own_version() {
    case "$SCRIPT_DIR" in
        */scripts)
            _ov="${SCRIPT_DIR%/scripts}"
            _ov="${_ov##*/}"
            # Must LOOK like a version. In a dev checkout the directory above
            # `scripts` is the plugin name ("workflow"), and accepting it would
            # print a nonsense probe line ("lockstep vworkflow") pointing at a
            # path that can never exist. Leading digit is the whole test — enough
            # to separate `0.14.0` from `workflow`, and it costs nothing when
            # probe 2 has already answered.
            case "$_ov" in
                [0-9]*) command printf '%s' "$_ov" ;;
            esac
            ;;
    esac
}

# A refusal that says only "not found" sends the reader hunting; one that lists
# every path it tried is usually self-diagnosing. So `_resolve` reports its
# probes as well as its answer — and it reports them THROUGH ITS OUTPUT, in a
# tagged two-column stream, rather than by assigning a global:
#
#     probe<TAB><human-readable line>
#     result<TAB><resolved path>
#
# The global was the first draft and it was silently broken. `_resolve` is always
# called in a command substitution, which is a SUBSHELL, so every append to the
# global was discarded on return and the refusal printed a "probed, in order:"
# header with nothing under it — the uninformative message this exists to
# prevent, in the one code path that needed it. Tagging the stream keeps the
# data on the only channel that survives a subshell.
PROBES_TRIED=''
_note_probe() { command printf 'probe\t%s\n' "$1"; }

# _resolve <id> — emit the tagged probe/result stream described above. Never
# exits; a resolution failure is simply a stream with no `result` line.
_resolve() {
    _r_id="$1"
    _r_plugin="$(_harness_plugin "$_r_id")"
    _r_rel="$(_harness_rel "$_r_id")"
    _r_var="$(_override_var "$_r_id")"

    # Probe 1 — explicit override. Printed even when it does not exist, so the
    # caller reports the CONFIGURED path in its refusal. "Your override points
    # nowhere" is a far more useful message than "not found".
    eval "_r_override=\${$_r_var:-}"
    if [ -n "$_r_override" ]; then
        _note_probe "$_r_var=$_r_override (explicit override)"
        command printf 'result\t%s\n' "$_r_override"
        return 0
    fi
    _note_probe "$_r_var (unset)"

    # Probe 2 — dev checkout. SCRIPT_DIR is plugins/workflow/scripts, so two
    # levels up reaches plugins/ and the sibling plugin is a fixed walk.
    _r_cand="${SCRIPT_DIR}/../../${_r_plugin}/${_r_rel}"
    if [ -f "$_r_cand" ]; then
        _note_probe "$_r_cand (dev checkout) — FOUND"
        command printf 'result\t%s\n' "$_r_cand"
        return 0
    fi
    _note_probe "$_r_cand (dev checkout)"

    # Probe 3a — installed cache, lockstep version. One level further up than
    # the dev walk: an installed plugin root carries a <version> segment.
    _r_own="$(_own_version)"
    if [ -n "$_r_own" ]; then
        _r_cand="${SCRIPT_DIR}/../../../${_r_plugin}/${_r_own}/${_r_rel}"
        if [ -f "$_r_cand" ]; then
            _note_probe "$_r_cand (installed, lockstep v$_r_own) — FOUND"
            command printf 'result\t%s\n' "$_r_cand"
            return 0
        fi
        _note_probe "$_r_cand (installed, lockstep v$_r_own)"
    fi

    # Probe 3b — installed cache, numerically greatest version. Reached only on a
    # hand-installed or partially-updated tree where the lockstep match is
    # absent. `for` over a literal glob, not an array: bash 3.2 is the floor, and
    # without nullglob an unmatched glob is returned verbatim — hence the -f test.
    _r_best=''
    _r_best_ver=''
    for _r_cand in "${SCRIPT_DIR}"/../../../"${_r_plugin}"/*/"${_r_rel}"; do
        [ -f "$_r_cand" ] || continue
        _r_ver="${_r_cand%/"${_r_rel}"}"
        _r_ver="${_r_ver##*/}"
        if [ -z "$_r_best" ] || _ver_gt "$_r_ver" "$_r_best_ver"; then
            _r_best="$_r_cand"
            _r_best_ver="$_r_ver"
        fi
    done
    if [ -n "$_r_best" ]; then
        _note_probe "$_r_best (installed, v$_r_best_ver) — FOUND"
        command printf 'result\t%s\n' "$_r_best"
        return 0
    fi
    _note_probe "${SCRIPT_DIR}/../../../${_r_plugin}/*/${_r_rel} (installed, any version)"

    return 0
}

# _normalize <path> — collapse `../` segments to an absolute real path. The
# probes build paths like `<dir>/../../workflow/skills/...`, which WORK but read
# badly in a refusal message and compare badly against a cwd prefix. Done with
# `cd`+`pwd -P` on the directory part: `realpath -m` is GNU-only, and BSD has no
# equivalent (CLAUDE.md § runtime policy). Falls back to the input unchanged if
# the directory cannot be entered — the caller's -f test is what decides
# validity, so this must never turn a real path into an empty one.
_normalize() {
    _nz_d="$(cd "$(command dirname "$1")" 2>/dev/null && pwd -P)" ||
        {
            command printf '%s' "$1"
            return 0
        }
    command printf '%s/%s' "$_nz_d" "$(command basename "$1")"
}

# _refuse <exit-code> <headline> [remedy…] — the loud path. Everything goes to
# stderr and the exit is non-zero, so neither a `2>/dev/null` nor a pipeline
# (#854) can turn this into a silent success.
_refuse() {
    _rf_code="$1"
    _rf_head="$2"
    shift 2
    {
        echo "Error: harness-stage.sh: $_rf_head"
        echo "  probed, in order:"
        command printf '%s' "$PROBES_TRIED"
        for _rf_line in "$@"; do echo "  $_rf_line"; done
    } >&2
    exit "$_rf_code"
}

# _is_under <path> <dir> — true when <path> lies inside <dir>. Both sides are
# resolved with `cd`+pwd on the DIRECTORY part only, which works on BSD and GNU
# alike; `realpath -m` is GNU-only (and its `|| echo` fallback returns the path
# UNRESOLVED, which is exactly how the symlink guard in seed-worktree-trust.sh
# was defeated — issue #21). Resolving both sides is what makes a symlinked
# worktree compare correctly instead of by string prefix.
_is_under() {
    _iu_dir="$(cd "$(command dirname "$1")" 2>/dev/null && pwd -P)" || return 1
    _iu_root="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
    case "$_iu_dir/" in
        "$_iu_root"/*) return 0 ;;
    esac
    return 1
}

cmd_list() {
    for _cl_id in $_HARNESS_IDS; do echo "$_cl_id"; done
}

# cmd_resolve <id> — shared by `path` and `stage`. Prints the source path on
# stdout; refuses loudly rather than returning empty.
cmd_resolve() {
    _cr_id="$1"
    _harness_plugin "$_cr_id" >/dev/null 2>&1 ||
        die_usage "unknown harness id: $_cr_id"

    # Split the tagged stream into the probe log and the answer. A `while read`
    # over a pipeline would run in a subshell and lose both again (the very bug
    # the tagging fixed), so the stream goes through a temp-free here-string.
    _cr_stream="$(_resolve "$_cr_id")"
    _cr_src=''
    PROBES_TRIED=''
    while IFS="$(command printf '\t')" read -r _cr_tag _cr_val; do
        case "$_cr_tag" in
            probe) PROBES_TRIED="${PROBES_TRIED}    ${_cr_val}
" ;;
            result) _cr_src="$_cr_val" ;;
        esac
    done <<EOF
$_cr_stream
EOF

    if [ -z "$_cr_src" ] || [ ! -f "$_cr_src" ]; then
        _cr_plugin="$(_harness_plugin "$_cr_id")"
        _cr_var="$(_override_var "$_cr_id")"

        # An override that points nowhere is checked FIRST, because probe 1
        # short-circuits the other two: nothing else was tried, so blaming the
        # plugin would be a false diagnosis of the operator's own typo. Exit 3 —
        # a misconfigured override is a broken environment, not an absent plugin.
        eval "_cr_ov=\${$_cr_var:-}"
        if [ -n "$_cr_ov" ]; then
            _refuse 3 \
                "$_cr_var points at a file that does not exist: $_cr_ov" \
                "The override short-circuits the dev-checkout and installed-cache probes," \
                "so nothing else was tried. Fix the path, or unset $_cr_var to fall back" \
                "to normal resolution."
        fi

        # Distinguish "the plugin is not installed" (exit 4, the caller's
        # documented skip applies) from "the plugin is here but the harness is
        # not" (exit 3, a broken environment). The discriminator is whether the
        # plugin ROOT resolved at all — a present plugin missing its own bundled
        # harness is corruption, not an uninstalled optional dependency.
        if [ -d "${SCRIPT_DIR}/../../${_cr_plugin}" ]; then
            _refuse 3 \
                "harness '$_cr_id' is missing from the '$_cr_plugin' plugin, which IS present" \
                "This is a broken install, not an absent optional plugin." \
                "Re-install the plugin, or point $(_override_var "$_cr_id") at the harness." \
                "Refusing to exit 0: a review that never ran must not read as a review that found nothing."
        fi
        _refuse 4 \
            "harness '$_cr_id' ships with the '$_cr_plugin' plugin, which is not installed" \
            "Install it with:  claude plugin install ${_cr_plugin}@librarian" \
            "or point $(_override_var "$_cr_id") at the harness explicitly."
    fi

    _normalize "$_cr_src"
}

cmd_path() {
    _cp_src="$(cmd_resolve "$1")" || exit $?
    command printf 'path=%s\nsource=%s\nstaged=false\n' "$_cp_src" "$_cp_src"
}

cmd_stage() {
    _cs_id="$1"
    _cs_root="$2"

    _cs_src="$(cmd_resolve "$_cs_id")" || exit $?

    # Already reachable => print it and stop. Copying anyway would leave a
    # second, stale copy shadowing the real file — see the header. This is the
    # common case in librarian's own checkout.
    if _is_under "$_cs_src" "$_cs_root"; then
        command printf 'path=%s\nsource=%s\nstaged=false\n' "$_cs_src" "$_cs_src"
        return 0
    fi

    _cs_dir="$_cs_root/.claude/tmp/harness"
    _cs_dir_existed=true
    [ -d "$_cs_dir" ] || _cs_dir_existed=false
    command mkdir -p "$_cs_dir" 2>/dev/null ||
        _refuse 3 "cannot create the staging directory: $_cs_dir" \
            "The session's working directory must be writable to stage a harness."

    # Tighten to 0700 regardless of umask, but ONLY on a directory this run just
    # created. The destination filename is DETERMINISTIC (`<id>.workflow.js`) and
    # its contents are handed straight to the `Workflow` tool as a scriptPath —
    # so on a shared host a permissive umask would let another local process
    # pre-create or replace that file and get its own code executed under the
    # harness's authority. `mktemp` already gives the temp file 0600; this closes
    # the directory and the final name.
    #
    # The `-d` test before `mkdir` is what makes this narrow, and it is not a
    # nicety: an unconditional chmod RE-GRANTS write on a directory the operator
    # (or a prior failure) deliberately locked to 0500, converting a refusal into
    # a silent success. Caught by test_copy_failure_refuses_loudly, which went
    # from exit 3 to exit 0 the moment the unconditional form landed.
    if [ "$_cs_dir_existed" = "false" ]; then
        command chmod 700 "$_cs_dir" 2>/dev/null || true
    fi

    _cs_dst="$_cs_dir/${_cs_id}.workflow.js"

    # Copy to a temp name in the SAME directory and rename, so a concurrent
    # reader never sees a half-written harness. Same discipline as
    # seed-worktree-trust.sh's atomic config write. `mktemp` with a template
    # rather than --suffix=, which BSD rejects.
    _cs_tmp="$(command mktemp "${_cs_dir}/.${_cs_id}.XXXXXX" 2>/dev/null)" ||
        _refuse 3 "cannot create a temp file in $_cs_dir"
    if ! command cp "$_cs_src" "$_cs_tmp" 2>/dev/null; then
        command rm -f "$_cs_tmp" 2>/dev/null
        _refuse 3 "cannot copy the harness into $_cs_dir" \
            "source: $_cs_src"
    fi
    if ! command mv "$_cs_tmp" "$_cs_dst" 2>/dev/null; then
        command rm -f "$_cs_tmp" 2>/dev/null
        _refuse 3 "cannot install the staged harness at $_cs_dst"
    fi
    command chmod 600 "$_cs_dst" 2>/dev/null || true

    command printf 'path=%s\nsource=%s\nstaged=true\n' "$_cs_dst" "$_cs_src"
}

# --- Dispatch ---------------------------------------------------------------

[ $# -ge 1 ] || die_usage 'missing subcommand'
SUBCMD="$1"
shift

case "$SUBCMD" in
    list)
        cmd_list
        ;;
    path)
        [ $# -ge 1 ] || die_usage 'path: missing <harness-id>'
        cmd_path "$1"
        ;;
    stage)
        [ $# -ge 1 ] || die_usage 'stage: missing <harness-id>'
        STAGE_ID="$1"
        shift
        STAGE_ROOT="$PWD"
        while [ $# -gt 0 ]; do
            case "$1" in
                --dir)
                    [ $# -ge 2 ] || die_usage '--dir: missing value'
                    STAGE_ROOT="$2"
                    shift 2
                    ;;
                *) die_usage "unknown flag: $1" ;;
            esac
        done
        [ -d "$STAGE_ROOT" ] || die_usage "--dir is not a directory: $STAGE_ROOT"
        cmd_stage "$STAGE_ID" "$STAGE_ROOT"
        ;;
    *)
        die_usage "unknown subcommand: $SUBCMD"
        ;;
esac
