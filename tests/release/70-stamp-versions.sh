# shellcheck shell=bash
# Group H — stamp-versions.mjs — release toolchain tests (issue #564 split).
#
# Covers its error paths.
#
# Sourced by tests/validate-release.sh, which defines REPO_ROOT and sources
# tests/lib/release-sandbox.sh for the shared sandbox constructors BEFORE this
# file. This fragment only DEFINES test functions; the entry point dispatches
# them from its explicit ordered run_test list.

# make_stamp_sandbox lives here rather than in tests/lib/release-sandbox.sh:
# it is used by this group ONLY (its two siblings are shared, this one is not),
# so keeping it local stops the shared library accreting single-use helpers.
# make_stamp_sandbox <varname>
# Creates a fresh sandbox subdir holding only what bin/stamp-versions.mjs reads:
# a copy of the script, a synthetic .claude-plugin/marketplace.json with a single
# plugin entry, and that plugin's plugins/demo/.claude-plugin/plugin.json (both at
# version 0.0.0). The real manifests are never touched — the script mutates files
# in place, so it must run entirely inside the sandbox. Individual tests mutate
# the copied manifests (empty plugins[], strip a version field) before invoking.
make_stamp_sandbox() {
    local __out="$1"
    local dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    command mkdir -p "$dir/bin" "$dir/.claude-plugin" \
        "$dir/plugins/demo/.claude-plugin"
    command cp "$REPO_ROOT/bin/stamp-versions.mjs" "$dir/bin/"
    command cat >"$dir/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "demo-marketplace",
  "plugins": [
    { "name": "demo", "source": "./plugins/demo", "version": "0.0.0" }
  ]
}
EOF
    command cat >"$dir/plugins/demo/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "demo",
  "version": "0.0.0",
  "description": "demo plugin"
}
EOF
    printf -v "$__out" '%s' "$dir"
}

# --- Group H: stamp-versions.mjs error paths --------------------------------
#
# stamp-versions.mjs is otherwise exercised only indirectly through release.sh's
# happy path (test_release_happy_path), which never trips its own guards. These
# invoke it directly in a hermetic sandbox and assert exit code + stderr for each
# reachable error path, plus one positive case proving the sandbox is otherwise
# valid so a guard firing for the wrong reason would surface (issue #217).

test_stamp_happy_path() {
    if ! command -v node >/dev/null 2>&1; then
        skip_test "node not available — cannot run stamp-versions.mjs"
        return
    fi
    local sb rc=0
    make_stamp_sandbox sb
    (cd "$sb" && node bin/stamp-versions.mjs 1.2.4) >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "stamp-versions.mjs succeeds on a valid version + manifests"
    assert_file_contains "$sb/plugins/demo/.claude-plugin/plugin.json" \
        '"version": "1.2.4"' "demo plugin.json is stamped to 1.2.4"
    assert_file_contains "$sb/.claude-plugin/marketplace.json" \
        '"version": "1.2.4"' "marketplace.json plugin entry is stamped to 1.2.4"
}

test_stamp_no_arg() {
    if ! command -v node >/dev/null 2>&1; then
        skip_test "node not available — cannot run stamp-versions.mjs"
        return
    fi
    local sb rc=0 err
    make_stamp_sandbox sb
    err="$(cd "$sb" && node bin/stamp-versions.mjs 2>&1 >/dev/null)" || rc=$?
    assert_exit 1 "$rc" "stamp-versions.mjs exits 1 with no version argument"
    assert_contains "$err" "expected a semver argument" \
        "stamp-versions.mjs reports the missing semver argument"
}

test_stamp_bad_semver() {
    if ! command -v node >/dev/null 2>&1; then
        skip_test "node not available — cannot run stamp-versions.mjs"
        return
    fi
    local sb rc=0 err
    make_stamp_sandbox sb
    err="$(cd "$sb" && node bin/stamp-versions.mjs 1.2 2>&1 >/dev/null)" || rc=$?
    assert_exit 1 "$rc" "stamp-versions.mjs exits 1 on a malformed version (second guard leg)"
    assert_contains "$err" "expected a semver argument" \
        "stamp-versions.mjs reports the malformed semver argument"
}

test_stamp_empty_plugins() {
    if ! command -v node >/dev/null 2>&1; then
        skip_test "node not available — cannot run stamp-versions.mjs"
        return
    fi
    local sb rc=0 err
    make_stamp_sandbox sb
    # Valid version, but marketplace.json carries an empty plugins[] array.
    command cat >"$sb/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "demo-marketplace",
  "plugins": []
}
EOF
    err="$(cd "$sb" && node bin/stamp-versions.mjs 1.2.4 2>&1 >/dev/null)" || rc=$?
    assert_exit 1 "$rc" "stamp-versions.mjs exits 1 when marketplace.json has an empty plugins[]"
    assert_contains "$err" "has no plugins[]" \
        "stamp-versions.mjs reports the empty plugins[] array"
}

test_stamp_missing_version_field() {
    if ! command -v node >/dev/null 2>&1; then
        skip_test "node not available — cannot run stamp-versions.mjs"
        return
    fi
    local sb rc=0 err
    make_stamp_sandbox sb
    # Valid version + plugins[], but the referenced plugin.json has no version key.
    command cat >"$sb/plugins/demo/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "demo",
  "description": "demo plugin"
}
EOF
    err="$(cd "$sb" && node bin/stamp-versions.mjs 1.2.4 2>&1 >/dev/null)" || rc=$?
    assert_true "[ $rc -ne 0 ]" "stamp-versions.mjs exits non-zero on a version-less plugin.json"
    assert_contains "$err" "no \`version\` field found" \
        "stamp-versions.mjs reports the missing version field"
}
