# shellcheck shell=bash
# Shared sandbox plumbing for the split status/* label vocabulary reconciler
# suite (issue #938, split per #564 while landing #999).
#
# Sourced, not executed. The entry point tests/validate-label-vocab-reconcile.sh
# sources this before its fragments, so every fragment sees make_sandbox /
# stub_gh / run_reconcile without re-declaring them. A helper used by exactly one
# area stays in that area's fragment — this file carries only what more than one
# fragment needs.
#
# SANDBOXES and the EXIT trap live here with the constructors that append to
# them: a trap armed in one file over a variable written in another is exactly
# the split-brain the split is supposed to avoid.

SANDBOXES=""
cleanup() {
    local box
    for box in $SANDBOXES; do
        [ -n "$box" ] || continue
        command rm -rf "$box"
    done
}
trap cleanup EXIT

# --- fixture construction ----------------------------------------------------

# make_sandbox <declared-labels...> — build a throwaway tree whose plugins/
# declares exactly the given status/* labels, plus a `gh` shim directory.
# Echoes the sandbox path.
#
# The metadata.yml carries a second, NON-status block and a non-status label so
# the parser's own scoping is exercised by every case rather than only by a
# dedicated one: a parser that ignored the `labels:` boundary, or that matched
# any `status/` substring, would pick up extra entries here and skew the
# comparison in a direction the assertions notice.
make_sandbox() {
    local box meta lbl
    box="$(command mktemp -d)" || return 1
    SANDBOXES="$SANDBOXES $box"

    command mkdir -p "$box/plugins/testplug/skills/thing" "$box/bin"
    meta="$box/plugins/testplug/skills/thing/metadata.yml"

    {
        command printf 'name: thing\n'
        command printf 'description: a fixture skill\n'
        command printf 'labels:\n'
        for lbl in "$@"; do
            command printf '  - name: %s\n' "$lbl"
            command printf '    description: fixture label\n'
        done
        command printf '  - name: type/fixture\n'
        command printf '    description: a non-status label in the same block\n'
        command printf 'other:\n'
        command printf '  - name: status/not-a-label-decl\n'
    } >"$meta"

    command printf '%s\n' "$box"
}

# stub_gh <box> <mode> [labels...] — install a `gh` shim in <box>/ghbin.
#
# modes:
#   ok      print the given labels, exit 0
#   fail    print an auth error to stderr, exit 1
#   empty   print nothing, exit 0
#   many    print N synthetic labels, exit 0 (drives the truncation guard)
stub_gh() {
    local box="$1" mode="$2"
    shift 2
    local shim="$box/ghbin/gh" lbl

    command mkdir -p "$box/ghbin"
    case "$mode" in
        ok)
            {
                command printf '#!/usr/bin/env bash\n'
                for lbl in "$@"; do
                    # SINGLE-QUOTED in the generated shim. Unquoted, a label name
                    # containing shell metacharacters — which a markdown-injection
                    # fixture needs — is a syntax error in the stub itself, so the
                    # case fails for a fixture reason while looking like a subject
                    # failure.
                    command printf "printf '%%s\\n' '%s'\n" "$lbl"
                done
                command printf 'exit 0\n'
            } >"$shim"
            ;;
        fail)
            {
                command printf '#!/usr/bin/env bash\n'
                command printf 'printf "gh: authentication required\\n" >&2\n'
                command printf 'exit 1\n'
            } >"$shim"
            ;;
        empty)
            {
                command printf '#!/usr/bin/env bash\n'
                command printf 'exit 0\n'
            } >"$shim"
            ;;
        many)
            # $1 = how many labels to emit. The shim reads its own --limit so the
            # fixture cannot drift out of step with the script's page size.
            {
                command printf '#!/usr/bin/env bash\n'
                command printf 'n=%s\n' "$1"
                command printf 'i=1\n'
                command printf 'while [ "$i" -le "$n" ]; do printf "pad/%%s\\n" "$i"; i=$((i + 1)); done\n'
                command printf 'exit 0\n'
            } >"$shim"
            ;;
        *)
            command printf 'stub_gh: unknown mode %s\n' "$mode" >&2
            return 1
            ;;
    esac
    command chmod +x "$shim"
}

# run_reconcile <box> — run the script against the sandbox with the stubbed gh
# first on PATH. Sets RC_OUT and RC_CODE.
#
# `-uBASH_ENV` IS LOAD-BEARING, NOT TIDINESS. This devcontainer sets
# BASH_ENV=/etc/bash_env, which every non-interactive bash sources — and it
# REBUILDS PATH, dropping the shim prefix entirely. Measured while writing this
# suite: without the scrub every case ran the REAL `gh` against the real repo, so
# the stub was inert and ten assertions failed against live label data. It would
# have been invisible in CI, which sets no BASH_ENV (the
# env-scrub-absence-hides-a-path-stub shape). The ATTACHED `-uVAR` spelling is
# required: BSD env has no long options and reads `--unset=VAR` as `-u nset=VAR`
# (CLAUDE.md § Runtime policy (4)).
#
# RC_OUT/RC_CODE are the out-params: every caller is a FRAGMENT, so shellcheck
# sees the writes here and none of the reads. Deliberately not `local` — that is
# the whole mechanism — hence the directive rather than a rename.
# shellcheck disable=SC2034
run_reconcile() {
    local box="$1"
    RC_OUT=""
    RC_CODE=0
    RC_OUT="$(/usr/bin/env -uBASH_ENV PATH="$box/ghbin:$PATH" LABEL_VOCAB_ROOT="$box" \
        "$REAL_BASH" --noprofile --norc "$RECONCILE_SH" 2>&1)" || RC_CODE=$?
}
