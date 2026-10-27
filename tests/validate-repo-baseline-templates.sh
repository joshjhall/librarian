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
    assert_true "[ ! -e \"$WORKDIR/bm2\" ] && [ ! -e \"$WORKDIR/escape.txt\" ]" "...and writes nothing, in or out of the output dir"

    command cp "$MANIFEST" "$m/manifest.tsv"
    command printf '/tmp/abs.txt\tcore\talways\tcore/tools.versions\n' >>"$m/manifest.tsv"
    rc=0
    RENDER_MANIFEST="$m/manifest.tsv" "$RENDER" --out "$WORKDIR/bm5" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "An absolute target exits 2"
    assert_true "[ ! -e \"$WORKDIR/bm5\" ]" "...and writes nothing"

    command cp "$MANIFEST" "$m/manifest.tsv"
    command printf 'x.txt\tcore\talways\n' >>"$m/manifest.tsv"
    rc=0
    RENDER_MANIFEST="$m/manifest.tsv" "$RENDER" --out "$WORKDIR/bm6" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "A row with fewer than 4 columns exits 2"
    assert_true "[ ! -e \"$WORKDIR/bm6\" ]" "...and writes nothing"

    # The bad row is LAST, after every good row: render.sh must validate the
    # whole manifest before writing, not write rows as it goes.
    command cp "$MANIFEST" "$m/manifest.tsv"
    command printf 'x.txt\tcore\talways\tcore/nope\n' >>"$m/manifest.tsv"
    rc=0
    RENDER_MANIFEST="$m/manifest.tsv" "$RENDER" --out "$WORKDIR/bm3" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "A missing source exits 2"
    assert_true "[ ! -e \"$WORKDIR/bm3\" ]" "...and writes nothing, though every earlier row was valid"

    command printf '# only a comment\n' >"$m/manifest.tsv"
    rc=0
    RENDER_MANIFEST="$m/manifest.tsv" "$RENDER" --out "$WORKDIR/bm4" >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "An empty manifest exits 2 rather than rendering nothing"
    assert_true "[ ! -e \"$WORKDIR/bm4\" ]" "...and writes nothing"
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
    else
        skip_test "taplo not installed"
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
    else
        skip_test "actionlint not installed"
    fi
    if command -v just >/dev/null 2>&1; then
        assert_equals "default install-hooks lint test" "$(cd "$out" && just --summary)" \
            "The rendered justfile parses, with lint and test recipes"
    else
        skip_test "just not installed"
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

test_rendered_gitlab_tool_cache() {
    # The cache must be keyed on BOTH pin files (a bump to either starts a fresh
    # cache), live under the project dir (GitLab caches nothing outside it), and
    # be the directory install-tools.sh is pointed at.
    local out="$WORKDIR/full" y="$WORKDIR/full/.gitlab-ci.yml"
    if ! command -v yq >/dev/null 2>&1; then
        skip_test "yq not installed"
        return
    fi
    assert_equals "tools.versions tools.sha256" "$(yq '.default.cache.key.files | join(" ")' "$y")" \
        "The GitLab cache key hashes tools.versions and tools.sha256"
    assert_equals ".tools-cache/" "$(yq '.default.cache.paths | join(" ")' "$y")" "...and caches .tools-cache/"
    assert_equals '$CI_PROJECT_DIR/.tools-cache' "$(yq '.variables.TOOLS_CACHE' "$y")" \
        "...which is the TOOLS_CACHE install-tools.sh reads"
    assert_true "command grep -qx '.tools-cache/' \"$out/.gitignore\"" "The rendered .gitignore keeps the cache out of the tree"
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

# --- install-tools.sh integrity ------------------------------------------------

test_every_download_has_a_hash() {
    # Derive the hash keys from the RENDERED script, never from a list kept
    # here: a list would let a newly added download pass this test and abort CI.
    # `from_tar <url> <tool>` keys as <tool>-<arch>; `fetch <url> "<key>"` names
    # its key directly, with `$ARCH` standing for each arch.
    local out="$WORKDIR/full" keys a key missing="" n
    keys="$(command awk '
        /^[[:space:]]*from_tar / { print $NF "-$ARCH"; next }
        /fetch "/ { k = $NF; gsub(/[")]/, "", k); print k }
    ' "$out/bin/install-tools.sh" | command grep -v '^\$' | command sort -u)"
    n="$(command printf '%s\n' "$keys" | command grep -c .)"
    assert_true "[ \"$n\" -ge 14 ]" "The rendered install-tools.sh yields every download's hash key (got $n)"
    for key in $keys; do
        case "$key" in
            *'$ARCH')
                for a in x86_64 aarch64; do
                    command grep -q "^${key%\$ARCH}$a " "$out/tools.sha256" ||
                        missing="$missing ${key%\$ARCH}$a"
                done
                ;;
            *) command grep -q "^$key " "$out/tools.sha256" || missing="$missing $key" ;;
        esac
    done
    assert_equals "" "$missing" "tools.sha256 has a sha256 for every key the rendered install-tools.sh fetches, both arches"
    assert_equals "" "$(command awk '!/^#/ && NF && $2 !~ /^[0-9a-f]{64}$/' "$out/tools.sha256")" \
        "Every tools.sha256 entry is a 64-hex digest"
}

# install_sandbox <dir> <curl-payload-file> — render the scaffold into <dir>,
# stub curl to serve <payload> for every URL (the gate never fetches), and split
# the rendered install-tools.sh into its helpers and its tail, so a case can run
# `helpers; <one fetch/put or from_tar>; tail` — the same stage -> check -> move
# path the real script takes, minus the 14 real downloads.
install_sandbox() {
    local d="$1"
    render_to "$d" --ci github >/dev/null
    command mkdir -p "$d/stub"
    command printf '#!/usr/bin/env sh\nwhile [ "$#" -gt 0 ]; do [ "$1" = -o ] && { cat "%s" >"$2"; exit 0; }; shift; done\nexit 1\n' \
        "$2" >"$d/stub/curl"
    command chmod +x "$d/stub/curl"
    command awk '/^v=\$\(pin typos\)/ { exit } { print }' "$d/bin/install-tools.sh" >"$d/bin/helpers.sh"
    command awk '/^# Fail, never skip/ { on = 1 } on' "$d/bin/install-tools.sh" >"$d/bin/tail.sh"
}

# run_install <dir> <tools.sha256 contents> <REQUIRED> <body> — run helpers, then
# <body>, then the real tail, with TOOLS_BIN=<dir>/tb. Output in <dir>/run.log.
run_install() {
    command printf '%s\n' "$2" >"$1/tools.sha256"
    (cd "$1" && PATH="$1/stub:/usr/bin:/bin" TOOLS_BIN="$1/tb" TOOLS_HOME="$1/th" HOME="$1" \
        /usr/bin/env -uBASH_ENV bash -c ". bin/helpers.sh
            $4
            REQUIRED='$3'
            . bin/tail.sh" >"$1/run.log" 2>&1)
}

sha256_file() {
    local s
    s="$({ command -v sha256sum >/dev/null 2>&1 && sha256sum "$1"; } || shasum -a 256 "$1")"
    command printf '%s\n' "${s%% *}"
}

test_install_tools_verifies_before_install() {
    # A download whose bytes match tools.sha256 installs; a mismatch or a
    # missing entry aborts BEFORE anything reaches TOOLS_BIN.
    local d="$WORKDIR/integrity" good rc body
    command mkdir -p "$d"
    command printf payload >"$WORKDIR/integrity.payload"
    install_sandbox "$d" "$WORKDIR/integrity.payload"
    good="$(sha256_file "$WORKDIR/integrity.payload")"
    body='f=$(fetch https://example.invalid/conform conform-x)
            put "$f" conform'
    rc=0
    run_install "$d" "conform-x $good" conform "$body" || rc=$?
    assert_equals "0" "$rc" "Bytes matching tools.sha256 install"
    assert_true "[ -x \"$d/tb/conform\" ]" "...and land executable in TOOLS_BIN"
    command rm -rf "$d/tb"
    rc=0
    run_install "$d" "conform-x $(command printf '%064d' 0)" conform "$body" || rc=$?
    assert_equals "1" "$rc" "A sha256 mismatch aborts the install"
    assert_contains "$(command cat "$d/run.log")" "sha256 mismatch for conform-x" "...naming the tool"
    assert_true "[ ! -e \"$d/tb/conform\" ]" "...and installs NOTHING"
    rc=0
    run_install "$d" "other-x $good" conform "$body" || rc=$?
    assert_equals "1" "$rc" "A download with no tools.sha256 entry aborts"
    # Named, not inferred: with no entry the digest comparison ALSO fails, so
    # the exit code alone cannot show the missing-entry guard fired.
    assert_contains "$(command cat "$d/run.log")" "no sha256 for conform-x in tools.sha256" \
        "...with the missing-entry error, before any download"
    assert_true "[ ! -e \"$d/tb/conform\" ]" "...and installs nothing"
}

test_install_tools_cache_is_reverified() {
    # TOOLS_CACHE (set by the GitLab template) holds verified downloads. A hit
    # skips the network; a tampered entry is re-downloaded and replaced; bytes
    # that fail tools.sha256 never reach the cache.
    local d="$WORKDIR/cache" c good rc body
    c="$d/tc"
    command mkdir -p "$d"
    command printf payload >"$WORKDIR/cache.payload"
    install_sandbox "$d" "$WORKDIR/cache.payload"
    good="$(sha256_file "$WORKDIR/cache.payload")"
    body="TOOLS_CACHE='$c'
            f=\$(fetch https://example.invalid/conform conform-x)
            put \"\$f\" conform"
    rc=0
    run_install "$d" "conform-x $good" conform "$body" || rc=$?
    assert_equals "0" "$rc" "A cache miss downloads and installs"
    assert_equals "$good" "$(sha256_file "$c/conform-x")" "...and stores the verified bytes under the hash key"
    assert_true "[ -z \"\$(command ls -A \"$c\" | command grep '^\.partial-')\" ]" "...leaving no .partial-* behind"

    # Hit: curl now fails for every URL, so success proves no download ran.
    command cp "$d/stub/curl" "$d/stub/curl.real"
    command printf '#!/usr/bin/env sh\nexit 1\n' >"$d/stub/curl"
    command rm -rf "$d/tb"
    rc=0
    run_install "$d" "conform-x $good" conform "$body" || rc=$?
    assert_equals "0" "$rc" "A cache hit installs with the network unreachable"
    assert_true "[ -x \"$d/tb/conform\" ]" "...from the cached bytes"

    # Tampered entry, network down: the cached bytes must NOT be installed.
    command printf tampered >"$c/conform-x"
    command rm -rf "$d/tb"
    rc=0
    run_install "$d" "conform-x $good" conform "$body" || rc=$?
    assert_equals "1" "$rc" "A cache entry failing its sha256 is not trusted"
    assert_contains "$(command cat "$d/run.log")" "cached conform-x fails its sha256" "...and says so"
    assert_true "[ ! -e \"$d/tb/conform\" ]" "...and installs nothing from it"
    assert_true "[ ! -e \"$c/conform-x\" ]" "...and drops the bad entry"

    # Tampered entry, network up: re-download, install, and repair the cache.
    command mv "$d/stub/curl.real" "$d/stub/curl"
    command printf tampered >"$c/conform-x"
    rc=0
    run_install "$d" "conform-x $good" conform "$body" || rc=$?
    assert_equals "0" "$rc" "A tampered cache entry is downloaded again"
    assert_equals "$good" "$(sha256_file "$d/tb/conform")" "...installing the verified bytes"
    assert_equals "$good" "$(sha256_file "$c/conform-x")" "...and replacing the bad entry"

    # A download that fails its check never enters the cache.
    command rm -rf "$c" "$d/tb"
    rc=0
    run_install "$d" "conform-x $(command printf '%064d' 0)" conform "$body" || rc=$?
    assert_equals "1" "$rc" "A mismatched download still aborts with a cache set"
    assert_true "[ ! -e \"$c/conform-x\" ]" "...and is NOT cached"
}

test_install_tools_fails_when_nothing_lands() {
    # Three ways an install can "succeed" without this run landing a pinned
    # binary, each found in review: from_tar's `find -exec` exits 0 on no match;
    # a `command -v` check is satisfied by a preinstalled copy on PATH; and a
    # destination check is satisfied by a STALE binary already in TOOLS_BIN.
    # Staging into a fresh dir closes all three. Each case has a positive control.
    local d="$WORKDIR/lands" sum rc body
    command mkdir -p "$d/arch/good" "$d/arch/bad"
    command printf '#!/usr/bin/env sh\necho typos-fresh\n' >"$d/arch/good/typos"
    command chmod +x "$d/arch/good/typos"
    command printf 'not the tool\n' >"$d/arch/bad/README"
    (cd "$d/arch" && command tar -czf "$WORKDIR/good.tgz" good && command tar -czf "$WORKDIR/bad.tgz" bad)
    body='ARCH=x86_64; from_tar https://example.invalid/typos.tgz typos'

    install_sandbox "$d" "$WORKDIR/good.tgz"
    sum="$(sha256_file "$WORKDIR/good.tgz")"
    rc=0
    run_install "$d" "typos-x86_64 $sum" typos "$body" || rc=$?
    assert_equals "0" "$rc" "Control: from_tar + tail install a tarball that holds the binary"
    assert_equals "typos-fresh" "$("$d/tb/typos" 2>/dev/null)" "...and TOOLS_BIN runs THIS run's binary"

    # Stale: TOOLS_BIN already holds an executable `typos`; the new archive has none.
    install_sandbox "$d" "$WORKDIR/bad.tgz"
    command rm -rf "$d/tb"
    command mkdir -p "$d/tb"
    command printf '#!/usr/bin/env sh\necho typos-stale\n' >"$d/tb/typos"
    command chmod +x "$d/tb/typos"
    sum="$(sha256_file "$WORKDIR/bad.tgz")"
    rc=0
    run_install "$d" "typos-x86_64 $sum" typos "$body" || rc=$?
    assert_equals "1" "$rc" "from_tar fails on an archive with no such binary, even with a stale copy in TOOLS_BIN"
    assert_contains "$(command cat "$d/run.log")" "no file named typos" "...naming the missing binary"
    assert_equals "typos-stale" "$("$d/tb/typos" 2>/dev/null)" "...and leaves TOOLS_BIN exactly as it was"

    # The tail alone: `faketool` is preinstalled on PATH AND stale in TOOLS_BIN,
    # but this run staged nothing.
    command printf '#!/usr/bin/env sh\nexit 0\n' >"$d/stub/faketool"
    command chmod +x "$d/stub/faketool"
    command cp "$d/stub/faketool" "$d/tb/faketool"
    rc=0
    run_install "$d" "" faketool ":" || rc=$?
    assert_equals "1" "$rc" "The post-install check ignores a tool on PATH or stale in TOOLS_BIN"
    assert_contains "$(command cat "$d/run.log")" "did not install: faketool" "...naming it"
}

test_install_tools_multi_file_tool_is_atomic() {
    # A multi-file tool (bats-core) stages its whole prefix and is moved into
    # TOOLS_HOME, then linked into TOOLS_BIN, only after every tool landed. Two
    # properties: the link works and survives a re-run; and a run that FAILS on
    # a later tool leaves the previous prefix and link untouched (cycle-4 review
    # found the prefix being replaced before the check).
    local d="$WORKDIR/multi" rc body
    command printf payload >"$WORKDIR/multi.payload"
    install_sandbox "$d" "$WORKDIR/multi.payload"
    # A fake multi-file tool: launcher + a sibling file it needs, so a broken
    # move (launcher without its tree) cannot pass.
    body='mkdir -p "$STAGE_HOME/mft-1/bin" "$STAGE_HOME/mft-1/lib"
            echo VERSION >"$STAGE_HOME/mft-1/lib/data"
            printf "#!/usr/bin/env sh\nd=\$(dirname \"\$(readlink \"\$0\" || echo \"\$0\")\")\ncat \"\$d/../lib/data\"\n" >"$STAGE_HOME/mft-1/bin/mft"
            chmod +x "$STAGE_HOME/mft-1/bin/mft"
            HOME_TOOLS="$HOME_TOOLS mft:mft-1/bin/mft"'
    rc=0
    run_install "$d" "" "" "${body//VERSION/v1}" || rc=$?
    assert_equals "0" "$rc" "A staged multi-file tool installs"
    assert_true "[ -L \"$d/tb/mft\" ]" "...linked into TOOLS_BIN (a symlink, not a copy)"
    assert_equals "v1" "$("$d/tb/mft" 2>/dev/null)" "...and runs from TOOLS_HOME with its sibling files"
    rc=0
    run_install "$d" "" "" "${body//VERSION/v1b}" || rc=$?
    assert_equals "0" "$rc" "Re-running over an installed multi-file tool succeeds"
    assert_equals "v1b" "$("$d/tb/mft" 2>/dev/null)" "...and TOOLS_BIN runs THIS run's copy"

    # Same tool staged fine, but a REQUIRED single-file tool never lands.
    rc=0
    run_install "$d" "" "nevertool" "${body//VERSION/v2}" || rc=$?
    assert_equals "1" "$rc" "A run with a missing tool fails"
    assert_equals "v1b" "$("$d/tb/mft" 2>/dev/null)" "...and leaves the earlier multi-file install working, untouched"

    # The multi-file tool itself fails to stage its launcher.
    rc=0
    run_install "$d" "" "" 'HOME_TOOLS="$HOME_TOOLS mft:mft-9/bin/mft"' || rc=$?
    assert_equals "1" "$rc" "A multi-file tool whose launcher did not stage fails"
    assert_contains "$(command cat "$d/run.log")" "did not install: mft" "...naming it"
    assert_equals "v1b" "$("$d/tb/mft" 2>/dev/null)" "...and leaves the earlier install working"
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
run_test test_rendered_gitlab_tool_cache "Rendered GitLab CI caches tool downloads keyed on the pin files"
run_test test_run_sh_reports_skip_and_none "The rendered tests/run.sh reports SKIP, none, and FAIL honestly"
run_test test_every_download_has_a_hash "Every tool install-tools.sh fetches has a pinned sha256"
run_test test_install_tools_verifies_before_install "install-tools.sh verifies each download before installing it"
run_test test_install_tools_cache_is_reverified "install-tools.sh re-verifies every TOOLS_CACHE hit and caches only verified bytes"
run_test test_install_tools_fails_when_nothing_lands "install-tools.sh fails when a pinned binary did not land in TOOLS_BIN"
run_test test_install_tools_multi_file_tool_is_atomic "install-tools.sh moves a multi-file tool only after every tool landed"
run_test test_live_hooks_pass "AC1: a rendered shell+python repo passes its own hooks and CI recipes"

generate_report
