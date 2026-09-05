# shellcheck shell=bash
# Shared plumbing for the split validate-pre-review-gates.sh suite (#895).
#
# Sourced by tests/validate-pre-review-gates.sh BEFORE its area fragments, so
# every fragment sees these drivers. Extracted verbatim from the monolith's
# `# --- Helpers ---` block — behavior is unchanged; only the file it lives in
# moved.
#
# The consts these read (GATE, REAL_BASH, GIT_SCRUB, WORKDIR) are defined by the
# entry point. shellcheck analyses one file at a time and cannot see that, hence
# the directives there rather than here.
#
# A helper used by exactly ONE area stays in that area's fragment — this library
# must not accrete single-use code (CLAUDE.md § split suites). That is why
# gate_streams, write_discovery_sandbox, write_bsd_sandbox, eval_read_yaml_list,
# gate_with_numstat and make_big_sh are NOT here: each has a single consumer.

# run_gate <file-list> — invoke the real gate with the git environment scrubbed,
# capturing stdout (the TSV findings). The file list holds one path per line.
# Exit code is captured in GATE_RC; the gate exits 0 on findings, so a non-zero
# here is a genuine failure worth surfacing.
# shellcheck disable=SC2034  # read by the area fragments that source this file
GATE_RC=0
# shellcheck disable=SC2034  # read by the area fragments that source this file
GATE_OUT=""
run_gate() {
    GATE_RC=0
    GATE_OUT="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$GATE" "$1" 2>/dev/null)" || GATE_RC=$?
}

# category_rows <output> <category> — emit only the rows whose 3rd
# tab-separated column equals <category>. Filtering on column 3 implicitly
# asserts the file\tline\tcategory\t... layout, not a loose substring.
category_rows() {
    command printf '%s\n' "$1" |
        command awk -F '\t' -v cat="$2" '$3 == cat'
}

# field <row> <n> — the n-th tab-separated column of a single TSV row.
field() {
    command printf '%s\n' "$1" | command awk -F '\t' -v n="$2" '{print $n}'
}

# make_list <dir> <file...> — write a newline-delimited file list of the given
# paths (relative to <dir>) into <dir>/files.txt and echo its path.
make_list() {
    local dir="$1"
    shift
    local list="$dir/files.txt"
    : >"$list"
    local f
    for f in "$@"; do
        command printf '%s\n' "$dir/$f" >>"$list"
    done
    command printf '%s' "$list"
}

# fresh_dir — a unique per-case scratch dir under WORKDIR.
fresh_dir() {
    command mktemp -d "$WORKDIR/case.XXXXXX"
}

# new_git_sandbox <varname> — a fresh `git init` sandbox with one seed commit so
# HEAD exists and `git rev-parse --show-toplevel` resolves to the sandbox. All
# git calls run with the hook environment scrubbed so the sandbox is hermetic.
new_git_sandbox() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" config user.name "Test"
    command printf 'seed\n' >"$dir/seed.txt"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" add seed.txt 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" -c commit.gpgsign=false commit -qm seed 2>/dev/null || return 1
    printf -v "$__out" '%s' "$dir"
}

# run_gate_in <sandbox-dir> <file-list> — like run_gate, but cd'd into the
# sandbox first so _PROJECT_ROOT resolves to the sandbox (for the skip-policy
# case). File list is an absolute path.
run_gate_in() {
    local dir="$1" list="$2"
    GATE_RC=0
    GATE_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" "$GATE" "$list" 2>/dev/null)" || GATE_RC=$?
}

# run_gate_in_err <sandbox-dir> <file-list> — like run_gate_in, but captures the
# gate's STDERR into GATE_ERR (stdout still goes to GATE_OUT). Needed because the
# config diagnostics (#601) are deliberately written to stderr: stdout carries
# the TSV contract, so a warning there would parse as a finding. Keeping the two
# streams separate here is also what lets a case assert the warning fired AND
# that it did not contaminate the rows.
GATE_ERR=""
run_gate_in_err() {
    local dir="$1" list="$2" errfile
    errfile="$(command mktemp "$WORKDIR/stderr.XXXXXX")"
    GATE_RC=0
    GATE_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" "$GATE" "$list" 2>"$errfile")" || GATE_RC=$?
    GATE_ERR="$(command cat "$errfile")"
    command rm -f "$errfile"
}
