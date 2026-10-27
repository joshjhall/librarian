#!/usr/bin/env bash
# Gate for the repo-baseline scaffold templates (#1219).
#
# dev-core's repo-baseline/templates/ ships the baseline as plain fragments plus
# manifest.tsv, rendered by concatenation (templates/README.md). This gate pins:
#
#   - the manifest is well-formed and covers every fragment on disk, both ways;
#   - every fragment that restates a slice doc's fence is byte-identical to it,
#     so the spec and the scaffold cannot drift apart;
#   - render.sh selects rows by slice and CI platform, is deterministic, and
#     refuses bad input without writing anything;
#   - every rendered file parses, and the rendered CI and scripts lint clean;
#   - AC1: a shell+python render, committed in a scratch repo, passes its own
#     pre-commit, commit-msg, and pre-push hooks and `just lint` / `just test`,
#     and a seeded lint error makes the hook FAIL (so the green is not vacuous).
#
# Fails closed on a vacuous corpus: an empty manifest or a render that writes
# nothing is a FAILURE. A case whose tool is absent is a per-case skip.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

SKILL_DIR="$REPO_ROOT/plugins/dev-core/skills/repo-baseline"
TEMPLATES="$SKILL_DIR/templates"
MANIFEST="$TEMPLATES/manifest.tsv"
RENDER="$TEMPLATES/render.sh"
SLICES_DIR="$SKILL_DIR/languages"

test_suite "repo-baseline scaffold templates"

WORKDIR="$(command mktemp -d)"
WORKDIR="$(cd "$WORKDIR" && command pwd -P)"
trap 'command rm -rf "$WORKDIR"' EXIT

# A sandbox git must never see the outer repo's state (the worktree's GIT_DIR,
# a hook-exported index), so every git call below runs through this scrub.
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES)
sgit() { /usr/bin/env "${GIT_SCRUB[@]/#/-u}" git "$@"; }

# manifest_rows — the manifest's data rows (no blanks, no comments).
manifest_rows() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in '' | '#'*) continue ;; esac
        command printf '%s\n' "$line"
    done <"$MANIFEST"
}

# fence_after_label <label> <slice-file>
# Prints, verbatim, the first fenced block after the line that starts with
# `<label>` (backticked) — the block the slice says IS that file.
fence_after_label() {
    local label="$1" line armed=0 in=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$in" -eq 1 ]; then
            case "$line" in '```'*) return 0 ;; esac
            command printf '%s\n' "$line"
            continue
        fi
        case "$line" in
            '```'*) [ "$armed" -eq 1 ] && in=1 ;;
            '`'"$label"'` '*) armed=1 ;;
        esac
    done <"$2"
}

# yaml_fence_entries <heading-stage> <slice-file>
# Prints the command entries of the first ```yaml fence under `## Hook entries`
# whose first line is `<stage>:` — minus that line and the `  commands:` line,
# which is exactly the shape a composable slice fragment carries.
yaml_fence_entries() {
    local stage="$1" line in_section=0 in=0 skip=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '## Hook entries') in_section=1 ;;
            '## '*) [ "$in" -eq 0 ] && in_section=0 ;;
        esac
        [ "$in_section" -eq 1 ] || continue
        if [ "$in" -eq 1 ]; then
            case "$line" in '```') return 0 ;; esac
            if [ "$skip" -gt 0 ]; then
                skip=$((skip - 1))
                continue
            fi
            command printf '%s\n' "$line"
            continue
        fi
        if [ "$in" -eq 2 ]; then
            # Saw the opener; this is the fence's first line.
            if [ "$line" = "$stage:" ]; then
                in=1
                skip=1 # the `  commands:` line
            else
                in=0
            fi
            continue
        fi
        case "$line" in '```yaml') in=2 ;; esac
    done <"$2"
}

# render_to <dir> <args...> — run render.sh, capturing its stdout target list.
render_to() {
    local dir="$1"
    shift
    "$RENDER" "$@" --out "$dir"
}

# --- Manifest -----------------------------------------------------------------

test_manifest_nonempty() {
    local n
    n="$(manifest_rows | command wc -l | command tr -d ' ')"
    assert_true "[ \"$n\" -gt 0 ]" "manifest.tsv has data rows (got $n)"
}

test_manifest_rows_well_formed() {
    local target slice when source bad=""
    while IFS="$(command printf '\t')" read -r target slice when source; do
        [ -n "$source" ] || bad="$bad [$target: fewer than 4 columns]"
        case "$when" in always | ci=github | ci=gitlab) ;; *) bad="$bad [$target: when=$when]" ;; esac
        [ -f "$TEMPLATES/$source" ] || bad="$bad [$target: missing $source]"
        case "$slice" in
            core) ;;
            *) [ -f "$SLICES_DIR/$slice.md" ] || bad="$bad [$target: slice $slice has no languages/$slice.md]" ;;
        esac
    done < <(manifest_rows)
    assert_equals "" "$bad" "Every manifest row has 4 columns, a known when, an existing source and slice"
}

test_manifest_covers_every_fragment() {
    # Both directions: a fragment on disk no row renders is dead weight that
    # looks shipped; the reverse is caught by the row check above.
    local f rel orphans="" sources
    sources="$(manifest_rows | command cut -f4)"
    while IFS= read -r f; do
        rel="${f#"$TEMPLATES"/}"
        case "$rel" in README.md | manifest.tsv | render.sh) continue ;; esac
        command grep -qxF "$rel" <<<"$sources" || orphans="$orphans $rel"
    done < <(command find "$TEMPLATES" -type f | LC_ALL=C command sort)
    assert_equals "" "$orphans" "Every fragment under templates/ is named by a manifest row"
}

test_core_fragments_are_inert() {
    # A config a tool auto-discovers (`_typos.toml`, `ruff.toml`, …) must not
    # sit under templates/ by its real name, or it reconfigures that tool for
    # librarian's own tree. Stored as *.tmpl; the manifest maps the name.
    local found
    found="$(command find "$TEMPLATES" -type f \( -name '_typos.toml' -o -name 'typos.toml' \
        -o -name 'ruff.toml' -o -name '.ruff.toml' -o -name '.shellcheckrc' -o -name 'dprint.json' \
        -o -name '.rumdl.toml' -o -name '.taplo.toml' -o -name 'taplo.toml' -o -name '.gitignore' \
        -o -name '.gitleaks.toml' -o -name '.conform.yaml' -o -name 'uv.toml' -o -name '.python-version' \) \
        -print)"
    assert_equals "" "$found" "No template uses a name its tool would auto-discover"
    # A partial-script fragment named *.sh / *.py is picked up by the repo's
    # lint, executable-bit, and coverage gates as a shipped script, and fails
    # them for being partial. Only complete scripts keep the extension.
    found="$(command find "$TEMPLATES" -type f \( -name '*.sh' -o -name '*.py' \) \
        ! -name render.sh ! -name ruff-version.sh -print)"
    assert_equals "" "$found" "Partial-script fragments are stored as *.tmpl, not *.sh/*.py"
    # Same for YAML: librarian's own dprint pre-commit hook reformats any staged
    # *.yml and re-stages it, which dedents a composable fragment out of the
    # block it must land in (measured: 6 fragments rewritten on the first commit).
    found="$(command find "$TEMPLATES" -type f \( -name '*.yml' -o -name '*.yaml' \) -print)"
    assert_equals "" "$found" "YAML fragments are stored as *.yml.tmpl, out of reach of the repo's formatter"
}

# --- Parity with the slice docs ------------------------------------------------

test_parity_plain_files() {
    local pair label source expect got
    for pair in \
        "shell .shellcheckrc shell/shellcheckrc.tmpl" \
        "python ruff.toml python/ruff.toml.tmpl" \
        "python uv.toml python/uv.toml.tmpl" \
        "python .python-version python/python-version.tmpl" \
        "python tests/requirements.txt python/requirements.txt" \
        "python tests/conftest.py python/conftest.py.tmpl"; do
        set -- $pair
        label="$2"
        source="$3"
        expect="$(fence_after_label "$label" "$SLICES_DIR/$1.md")"
        got="$(command cat "$TEMPLATES/$source")"
        assert_not_empty "$expect" "$1.md carries a fence for \`$label\`"
        assert_equals "$expect" "$got" "$source is byte-identical to $1.md's \`$label\` fence"
    done
}

test_parity_ruff_version_accessor() {
    assert_true "command cmp -s \"$REPO_ROOT/bin/ruff-version.sh\" \"$TEMPLATES/python/ruff-version.sh\"" \
        "python/ruff-version.sh is librarian's bin/ruff-version.sh verbatim (python.md says copy it)"
}

test_parity_hook_fragments() {
    local spec expect got
    for spec in "shell pre-commit shell/lefthook-pre-commit.yml" \
        "python pre-commit python/lefthook-pre-commit.yml" \
        "python pre-push python/lefthook-pre-push.yml"; do
        set -- $spec
        expect="$(yaml_fence_entries "$2" "$SLICES_DIR/$1.md")"
        got="$(command cat "$TEMPLATES/$3")"
        assert_not_empty "$expect" "$1.md has a $2 hook fence"
        # The python pre-push fence also carries a `tests:` entry: the composed
        # lefthook.yml takes that from core (one entry point), so compare the
        # fragment against the fence's leading entries only.
        assert_equals "$got" "$(command printf '\n%s\n' "$expect" | command head -n "$(command printf '%s\n' "$got" | command wc -l)")" \
            "$3 equals the leading entries of $1.md's $2 hook fence"
    done
}

# --- Render --------------------------------------------------------------------

test_render_full_set() {
    local out="$WORKDIR/full" list expect
    list="$(render_to "$out" --slices shell,python --ci github,gitlab)"
    expect="$(manifest_rows | command cut -f1 | command awk '!seen[$0]++')"
    assert_equals "$expect" "$list" "A full render writes every manifest target, in first-appearance order"
    assert_true "[ -x \"$out/tests/run.sh\" ] && [ -x \"$out/bin/install-tools.sh\" ] && [ -x \"$out/bin/ruff-version.sh\" ]" \
        "Rendered *.sh targets are executable"
}

test_render_core_only() {
    local out="$WORKDIR/core" list
    list="$(render_to "$out" --ci github)"
    assert_contains "$list" "lefthook.yml" "A core-only render writes lefthook.yml"
    assert_not_contains "$list" "ruff.toml" "A core-only render writes no python files"
    assert_not_contains "$list" ".shellcheckrc" "A core-only render writes no shell files"
    assert_not_contains "$list" ".gitlab-ci.yml" "A github-only render writes no GitLab CI"
    assert_not_contains "$(command cat "$out/lefthook.yml")" "ruff" "A core-only lefthook.yml has no slice entries"
    assert_not_contains "$(command cat "$out/lefthook.yml")" "gitlab-ci-lint" "A github-only lefthook.yml has no GitLab CI lint"
}

test_render_shell_only() {
    local out="$WORKDIR/shell"
    render_to "$out" --slices shell --ci gitlab >/dev/null
    assert_contains "$(command cat "$out/lefthook.yml")" "shellcheck --severity=warning" "A shell render's hooks run shellcheck"
    assert_not_contains "$(command cat "$out/lefthook.yml")" "ruff" "A shell-only render has no python hook rows"
    assert_not_contains "$(command cat "$out/tests/run.sh")" "pytest" "A shell-only tests/run.sh has no pytest stage"
    assert_not_contains "$(command cat "$out/justfile")" "actionlint" "A gitlab-only justfile does not run actionlint"
    assert_true "[ ! -e \"$out/.github\" ]" "A gitlab-only render writes no .github/"
}

test_render_deterministic() {
    local a="$WORKDIR/det-a" b="$WORKDIR/det-b"
    render_to "$a" --slices python,shell --ci gitlab,github >/dev/null
    render_to "$b" --slices shell,python --ci github,gitlab >/dev/null
    assert_true "command diff -r \"$a\" \"$b\" >/dev/null" \
        "Two renders of the same selection are byte-identical, whatever the flag order"
}

test_render_refuses_bad_input() {
    local out="$WORKDIR/bad" rc
    rc=0
    "$RENDER" --slices cobol --out "$out" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "An unknown slice exits 2"
    rc=0
    "$RENDER" --ci jenkins --out "$out" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "An unknown CI platform exits 2"
    assert_true "[ ! -e \"$out\" ]" "A refused render writes nothing"
    render_to "$out" --slices shell >/dev/null
    rc=0
    "$RENDER" --slices shell --out "$out" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "Rendering over existing files without --force exits 2"
    rc=0
    "$RENDER" --slices shell --out "$out" --force >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "--force overwrites"
}

test_render_refuses_bad_manifest() {
    local m="$WORKDIR/manifests" rc
    command mkdir -p "$m"
    command cp -R "$TEMPLATES/." "$m/"
    command printf 'x.txt\tcore\tsometimes\tcore/tools.versions\n' >>"$m/manifest.tsv"
    rc=0
    RENDER_MANIFEST="$m/manifest.tsv" "$RENDER" --out "$WORKDIR/bm1" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "A manifest row with an unknown when exits 2"
    assert_true "[ ! -e \"$WORKDIR/bm1\" ]" "...and writes nothing"

    command cp "$MANIFEST" "$m/manifest.tsv"
    command printf '../escape.txt\tcore\talways\tcore/tools.versions\n' >>"$m/manifest.tsv"
    rc=0
    RENDER_MANIFEST="$m/manifest.tsv" "$RENDER" --out "$WORKDIR/bm2" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "A target escaping the output dir exits 2"

    command cp "$MANIFEST" "$m/manifest.tsv"
    command printf 'x.txt\tcore\talways\tcore/nope\n' >>"$m/manifest.tsv"
    rc=0
    RENDER_MANIFEST="$m/manifest.tsv" "$RENDER" --out "$WORKDIR/bm3" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "A missing source exits 2"

    command printf '# only a comment\n' >"$m/manifest.tsv"
    rc=0
    RENDER_MANIFEST="$m/manifest.tsv" "$RENDER" --out "$WORKDIR/bm4" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "An empty manifest exits 2 rather than rendering nothing"
}

# --- Validity of the rendered files --------------------------------------------

test_rendered_files_parse() {
    local out="$WORKDIR/full" f
    for f in tests/run.sh bin/install-tools.sh bin/ruff-version.sh; do
        assert_true "bash -n \"$out/$f\"" "$f parses as bash"
    done
    if command -v yq >/dev/null 2>&1; then
        for f in lefthook.yml .github/workflows/ci.yml .gitlab-ci.yml .conform.yaml; do
            assert_true "yq '.' \"$out/$f\" >/dev/null 2>&1" "$f parses as YAML"
        done
        assert_equals "$(command printf '%s\n' check-merge-conflict large-file gitleaks dprint taplo rumdl \
            actionlint gitlab-ci-lint shellcheck shfmt ruff-format ruff-check)" \
            "$(yq '.pre-commit.commands | keys | .[]' "$out/lefthook.yml")" \
            "Slice pre-commit fragments compose INTO pre-commit.commands"
        assert_equals "$(command printf '%s\n' dprint-check taplo-check typos tests ruff)" \
            "$(yq '.pre-push.commands | keys | .[]' "$out/lefthook.yml")" \
            "The python pre-push fragment composes INTO pre-push.commands"
        # Measured on a live instance (#1219 AC3): a guard on `glab auth status`
        # skipped the hook whenever ANY configured host lacked a login, and no
        # guard on a remote blocked a fresh scaffold's first commit.
        local guards
        guards="$(yq '.pre-commit.commands.gitlab-ci-lint.skip[].run' "$out/lefthook.yml")"
        assert_not_contains "$guards" "auth status" \
            "gitlab-ci-lint does not skip on glab auth status (it checks every host)"
        assert_contains "$guards" 'git remote' \
            "gitlab-ci-lint skips when the repo has no remote yet"
    else
        skip_test "yq not installed"
    fi
    if command -v taplo >/dev/null 2>&1; then
        for f in _typos.toml .rumdl.toml .taplo.toml .gitleaks.toml ruff.toml uv.toml; do
            assert_true "taplo check \"$out/$f\" >/dev/null 2>&1" "$f parses as TOML"
        done
    fi
    assert_true "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \"$out/dprint.json\"" "dprint.json parses as JSON"
}

test_rendered_files_lint() {
    local out="$WORKDIR/full" f
    if command -v shellcheck >/dev/null 2>&1; then
        for f in tests/run.sh bin/install-tools.sh bin/ruff-version.sh; do
            assert_true "shellcheck --severity=warning \"$out/$f\" >/dev/null" "$f is shellcheck-clean"
        done
    else
        skip_test "shellcheck not installed"
    fi
    if command -v actionlint >/dev/null 2>&1; then
        assert_true "(cd \"$out\" && actionlint .github/workflows/ci.yml >/dev/null)" "The rendered GitHub workflow is actionlint-clean"
    fi
    if command -v just >/dev/null 2>&1; then
        assert_equals "default install-hooks lint test" "$(cd "$out" && just --summary)" \
            "The rendered justfile parses, with lint and test recipes"
    fi
}

test_rendered_ci_pins() {
    local out="$WORKDIR/full"
    local images
    images="$(command grep -E '^[[:space:]]*image:' "$out/.gitlab-ci.yml")"
    assert_not_empty "$images" "GitLab CI names an image"
    assert_not_contains "$images" ":latest" "GitLab CI's image is not :latest"
    assert_true "command printf '%s\n' \"$images\" | command grep -E 'image: [^ ]+:[^ ]*[0-9]{8}|image: [^ ]+:[0-9]+\.[0-9]+\.[0-9]+' >/dev/null" \
        "GitLab CI's image carries a dated or exact-version tag"
    assert_true "command grep -E 'uses: [^@]+@[0-9a-f]{40} # v[0-9]' \"$out/.github/workflows/ci.yml\" >/dev/null" \
        "GitHub CI pins actions to a 40-char SHA with a version comment"
    assert_not_contains "$(command grep 'uses:' "$out/.github/workflows/ci.yml" | command grep -vE '@[0-9a-f]{40} # v')" \
        "uses:" "No GitHub action is left unpinned"
    assert_contains "$(command cat "$out/.github/workflows/ci.yml")" "if: always()" "The merge gate runs if: always()"
}

test_run_sh_reports_skip_and_none() {
    # The rendered runner's contract, exercised: a missing runner is [SKIP]
    # (exit 0 locally, 1 under CI=true); a slice with no test files is [none].
    # The stub PATH holds ONLY the fake runners. BASH_ENV is unset because a
    # profile sourced through it restores the real PATH (and the real uv),
    # which would make every "runner absent" case below test nothing.
    local out="$WORKDIR/runner" rc o stub="$WORKDIR/runner-bin"
    render_to "$out" --slices shell,python --ci github >/dev/null
    command mkdir -p "$stub"
    run_runner() { (cd "$out" && PATH="$stub:/usr/bin:/bin" CI="$1" /usr/bin/env -uBASH_ENV bash tests/run.sh 2>&1); }
    o="$(run_runner "")" && rc=0 || rc=$?
    assert_equals "0" "$rc" "With no runners installed, tests/run.sh exits 0 locally"
    assert_contains "$o" "[SKIP] shell (bats)" "A missing bats is reported [SKIP]"
    assert_contains "$o" "[SKIP] python (pytest)" "A missing uv is reported [SKIP]"
    o="$(run_runner true)" && rc=0 || rc=$?
    assert_equals "1" "$rc" "Under CI=true, a skipped stage fails the run"
    command printf '#!/usr/bin/env sh\nexit 0\n' >"$stub/bats"
    command printf '#!/usr/bin/env sh\nexit 0\n' >"$stub/uv"
    command chmod +x "$stub/bats" "$stub/uv"
    o="$(run_runner true)" && rc=0 || rc=$?
    assert_contains "$o" "[none] shell (bats)" "A slice with no test files is reported [none], not [ok]"
    assert_contains "$o" "[none] python (pytest)" "...for every slice"
    assert_equals "0" "$rc" "[none] is not a failure"
    command printf '#!/usr/bin/env sh\nexit 3\n' >"$stub/uv"
    : >"$out/tests/test_x.py"
    o="$(run_runner "")" && rc=0 || rc=$?
    assert_contains "$o" "[FAIL] python (pytest) (exit 3)" "A failing stage is reported [FAIL]"
    assert_equals "1" "$rc" "A failing stage fails the run"
}

# --- AC1: the rendered hooks pass on a clean checkout --------------------------

test_live_hooks_pass() {
    local t
    for t in lefthook just uv; do
        if ! command -v "$t" >/dev/null 2>&1; then
            skip_test "$t not installed"
            return 0
        fi
    done
    local repo="$WORKDIR/live" rc
    command mkdir -p "$repo"
    sgit init -q -b main "$repo"
    sgit -C "$repo" config user.email t@example.com
    sgit -C "$repo" config user.name t
    sgit -C "$repo" config commit.gpgsign false
    render_to "$repo" --slices shell,python --ci github,gitlab >/dev/null
    command mkdir -p "$repo/bin" "$repo/tests"
    command printf '#!/usr/bin/env bash\nset -euo pipefail\necho "hello ${1:-world}"\n' >"$repo/bin/hello.sh"
    command chmod +x "$repo/bin/hello.sh"
    command printf '"""Greet."""\n\n\ndef greet(name):\n    return f"hello {name}"\n' >"$repo/bin/greet.py"
    command printf 'def test_greet(load_script):\n    assert load_script("greet").greet("x") == "hello x"\n' \
        >"$repo/tests/test_greet.py"
    command printf '# Sample\n\nA sample repo.\n' >"$repo/README.md"

    (cd "$repo" && /usr/bin/env "${GIT_SCRUB[@]/#/-u}" lefthook install >/dev/null 2>&1)
    sgit -C "$repo" add -A
    rc=0
    (cd "$repo" && sgit commit -q -m "feat: initial scaffold" >"$WORKDIR/live-commit.log" 2>&1) || rc=$?
    assert_equals "0" "$rc" "A clean shell+python render commits through its pre-commit and commit-msg hooks"
    assert_equals "" "$(sgit -C "$repo" status --porcelain)" "The commit hooks leave the tree clean (no formatter rewrites)"
    rc=0
    (cd "$repo" && /usr/bin/env "${GIT_SCRUB[@]/#/-u}" lefthook run pre-push >"$WORKDIR/live-push.log" 2>&1) || rc=$?
    assert_equals "0" "$rc" "The rendered pre-push hook passes"
    assert_contains "$(command cat "$WORKDIR/live-push.log")" "[ok]   python (pytest)" \
        "pre-push really ran the sample test (not a vacuous [none])"
    rc=0
    (cd "$repo" && just lint >"$WORKDIR/live-lint.log" 2>&1) || rc=$?
    assert_equals "0" "$rc" "just lint (the CI lint stage) passes"
    rc=0
    (cd "$repo" && just test >"$WORKDIR/live-test.log" 2>&1) || rc=$?
    assert_equals "0" "$rc" "just test (the CI test stage) passes"

    # Negative control: the same hooks must REJECT a lint error, or the green
    # above proves only that nothing ran.
    command printf 'import os\n' >"$repo/bin/bad.py"
    sgit -C "$repo" add bin/bad.py
    rc=0
    (cd "$repo" && sgit commit -q -m "feat: add unused import" >/dev/null 2>&1) || rc=$?
    assert_true "[ \"$rc\" -ne 0 ]" "The rendered pre-commit hook rejects a ruff finding"
}

run_test test_manifest_nonempty "The manifest has data rows"
run_test test_manifest_rows_well_formed "Every manifest row is well-formed"
run_test test_manifest_covers_every_fragment "Every fragment on disk is rendered by some row"
run_test test_core_fragments_are_inert "No template is auto-discovered as live config"
run_test test_parity_plain_files "Slice-owned config templates equal the slice docs' fences"
run_test test_parity_ruff_version_accessor "The ruff accessor template is librarian's own"
run_test test_parity_hook_fragments "Slice hook fragments equal the slice docs' hook fences"
run_test test_render_full_set "A full render writes every target"
run_test test_render_core_only "A core-only render selects no slice rows"
run_test test_render_shell_only "A shell-only gitlab render selects only its rows"
run_test test_render_deterministic "Rendering is deterministic"
run_test test_render_refuses_bad_input "render.sh refuses bad flags and existing files"
run_test test_render_refuses_bad_manifest "render.sh refuses a bad manifest without writing"
run_test test_rendered_files_parse "Every rendered file parses"
run_test test_rendered_files_lint "Rendered scripts, workflow, and justfile lint clean"
run_test test_rendered_ci_pins "Rendered CI pins images and actions"
run_test test_run_sh_reports_skip_and_none "The rendered tests/run.sh reports SKIP, none, and FAIL honestly"
run_test test_live_hooks_pass "AC1: a rendered shell+python repo passes its own hooks and CI recipes"

generate_report
