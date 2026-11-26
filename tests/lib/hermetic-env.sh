# shellcheck shell=bash
# Unexport the developer-shell environment that makes local runs diverge from CI.
#
# Sourced at load by tests/lib/harness.sh (so a suite run on its own gets it)
# and by tests/run-all.sh (so the few gates that skip the harness get it too).
# CI sets none of these, so scrubbing them makes a local run behave like CI
# rather than changing what CI does.
#
# BASH_ENV. The devcontainer points it at /etc/bash_env, which every
# NON-interactive bash sources before running, including each `bash -c` a test
# spawns. It sources /etc/bashrc.d/*, so anything installed there runs inside
# the test. That has bitten in three ways: it restores a sabotaged PATH/TMPDIR,
# so a test passes without exercising its branch (#962); a credential hook
# (drumknott) re-exports its own GIT_CONFIG_* pairs over a test's injected
# value (PR #1273); and the same hook, given `HOME=relative`, ran its setup and
# wrote ./relative/ into the repo root (#1274). Per-call-site `-uBASH_ENV` is the
# existing idiom, and roughly 95 sites missed it, so it is enforced here once.
#
# GIT_CONFIG_COUNT / GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n> /
# GIT_CONFIG_PARAMETERS. Config injected through the environment overrides
# every config file, so an exported user.name, commit.gpgsign or include.path
# reaches every sandbox repo a test builds. Tests that exercise injection on
# purpose set these per command, after this has run, so they are unaffected.
#
# Unset, never blank: an empty BASH_ENV is harmless, but an empty
# GIT_CONFIG_COUNT makes git die with "bogus count". bash-3.2 clean.
_hermetic_env_scrub() {
    local _n
    unset BASH_ENV GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS 2>/dev/null || true
    for _n in $(compgen -e); do
        case "$_n" in
            GIT_CONFIG_KEY_* | GIT_CONFIG_VALUE_*) unset "$_n" 2>/dev/null || true ;;
        esac
    done
}
_hermetic_env_scrub
unset -f _hermetic_env_scrub
