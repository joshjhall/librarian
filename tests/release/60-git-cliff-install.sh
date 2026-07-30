# shellcheck shell=bash
# Groups G and G2 — git-cliff.sh — release toolchain tests (issue #564 split).
#
# Covers checksum verification (#221) and the ensure_git_cliff install orchestration (#252). Kept as one fragment because both drive the shared gc_sandbox fixture.
#
# Sourced by tests/validate-release.sh, which defines REPO_ROOT and sources
# tests/lib/release-sandbox.sh for the shared sandbox constructors BEFORE this
# file. This fragment only DEFINES test functions; the entry point dispatches
# them from its explicit ordered run_test list.

# --- Group G: git-cliff.sh install + checksum verification (issue #221) ------
#
# git-cliff.sh exports ensure_git_cliff() (cargo/binary install dispatch) and
# _git_cliff_verify_sha512() (the supply-chain checksum gate). Group E sources
# git-cliff.sh only to satisfy changelog.sh and OVERRIDES ensure_git_cliff to a
# stub, so neither function was ever exercised directly — a silent regression
# (an inverted return code, a curl flag that no-ops the sha512 check) would ship
# the broken control unnoticed. These source git-cliff.sh directly and drive
# both functions with stubbed curl / a PATH-controlled digest tool — no network,
# no sudo, no real install. _git_cliff_verify_sha512 takes three positional args
# (<temp_dir> <asset> <asset_url>), so its four documented outcomes (download
# fail, tampered payload, matched payload, no digest tool) can be driven in
# isolation without touching ensure_git_cliff's install machinery.

# shellcheck source=bin/lib/release/git-cliff.sh
source "$REPO_ROOT/bin/lib/release/git-cliff.sh"

# gc_sandbox <varname>
# A fresh sandbox subdir holding a stubbin/ (prepended to PATH by the runners
# below) plus an empty payload dir. Assigns the sandbox path to the caller's
# named variable.
gc_sandbox() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/gc.XXXXXX")" || return 1
    command mkdir -p "$dir/stubbin" "$dir/payload"
    printf -v "$__out" '%s' "$dir"
}

# gc_stub_curl <sandbox> <mode>
# Writes a `curl` stub into <sandbox>/stubbin. ensure_git_cliff / verify call it
# as `curl -sfL <url> -o <outfile>`; the stub writes to the `-o` target so the
# caller sees a downloaded file. Modes:
#   ok       — write the sentinel checksum-file body (from <sandbox>/expected_sha)
#              to the -o target and exit 0. Used for the matched/tampered digest
#              cases, whose difference is only what expected_sha contains.
#   fail     — exit 1 without writing (the undownloadable-checksum path).
gc_stub_curl() {
    local sb="$1" mode="$2"
    command cat >"$sb/stubbin/curl" <<EOF
#!/bin/sh
# Parse out the -o target (the last arg after -o).
out=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
case "$mode" in
    fail) exit 1 ;;
    ok)
        [ -n "\$out" ] || exit 1
        command cat "$sb/expected_sha" >"\$out"
        exit 0 ;;
esac
EOF
    command chmod +x "$sb/stubbin/curl"
}

# run_verify_sha512 <sandbox> <hermetic>
# Sources git-cliff.sh in a subshell and runs
# _git_cliff_verify_sha512 "$sb/payload" "$asset" "$url" with the stubbin on
# PATH. The payload dir already holds the tarball named <asset>; the stub curl
# writes <asset>.sha512 next to it. Echoes combined stdout+stderr, preserves the
# exit code.
#   hermetic="hermetic" → PATH = stubbin only (NO sha512sum/shasum anywhere), to
#     drive the no-digest-tool fail-closed arm. The stub curl's /bin/sh shebang
#     keeps it runnable; the function reaches coreutils via `command` builtins.
#   otherwise           → stubbin prepended to a full PATH so real sha512sum runs.
GC_ASSET="git-cliff-9.9.9-x86_64-unknown-linux-gnu.tar.gz"
GC_URL="https://example.invalid/${GC_ASSET}"
run_verify_sha512() {
    local sb="$1" hermetic="${2:-}" run_path
    if [ "$hermetic" = "hermetic" ]; then
        run_path="$sb/stubbin"
    else
        run_path="$sb/stubbin:$PATH"
    fi
    (
        PATH="$run_path"
        export PATH
        # shellcheck source=bin/lib/release/git-cliff.sh
        source "$REPO_ROOT/bin/lib/release/git-cliff.sh"
        _git_cliff_verify_sha512 "$sb/payload" "$GC_ASSET" "$GC_URL"
    ) 2>&1
}

test_ensure_git_cliff_short_circuits_when_present() {
    local sb rc=0 out
    gc_sandbox sb
    # A stub `git-cliff` already on PATH: ensure_git_cliff must return 0 at the
    # `command -v git-cliff` guard WITHOUT attempting any install. A marker file
    # proves the install machinery (cargo/curl) was never reached — the stub
    # git-cliff is inert (exit 0) and touches nothing.
    command cat >"$sb/stubbin/git-cliff" <<'EOF'
#!/bin/sh
exit 0
EOF
    command chmod +x "$sb/stubbin/git-cliff"
    out="$(
        run_path="$sb/stubbin:$PATH"
        PATH="$run_path"
        export PATH
        # shellcheck source=bin/lib/release/git-cliff.sh
        source "$REPO_ROOT/bin/lib/release/git-cliff.sh"
        ensure_git_cliff 2>&1
    )" || rc=$?
    assert_exit 0 "$rc" "ensure_git_cliff returns 0 when git-cliff is already on PATH"
    assert_not_contains "$out" "installing" "the short-circuit does not attempt an install"
}

test_verify_sha512_download_failure_refuses() {
    local sb rc=0 out
    gc_sandbox sb
    command printf 'payload-bytes\n' >"$sb/payload/$GC_ASSET"
    gc_stub_curl "$sb" fail
    out="$(run_verify_sha512 "$sb")" || rc=$?
    assert_exit 1 "$rc" "verify returns non-zero when the .sha512 cannot be downloaded"
    assert_contains "$out" "Failed to download checksum" "reports the undownloadable checksum"
}

test_verify_sha512_tampered_payload_refuses() {
    local sb rc=0
    gc_sandbox sb
    local real bogus
    command printf 'the-real-payload\n' >"$sb/payload/$GC_ASSET"
    # The published checksum names a WELL-FORMED but WRONG digest (a
    # swapped/tampered asset). Derive it from the payload's REAL 128-hex digest
    # with its first nibble flipped: this stays a valid 128-char SHA-512 line, so
    # `sha512sum -c` reaches its DIGEST-COMPARISON path and reports a mismatch
    # (`FAILED`) — NOT the "no properly formatted checksum lines found" PARSE
    # rejection a wrong-length placeholder (e.g. 130 chars) would trip instead,
    # which would leave the real mismatch path of this supply-chain gate untested.
    real="$(cd "$sb/payload" && command sha512sum "$GC_ASSET" | command cut -c1-128)"
    case "$real" in
        0*) bogus="1${real#?}" ;;
        *) bogus="0${real#?}" ;;
    esac
    command printf '%s  %s\n' "$bogus" "$GC_ASSET" >"$sb/expected_sha"
    gc_stub_curl "$sb" ok
    run_verify_sha512 "$sb" >/dev/null 2>&1 && rc=0 || rc=$?
    assert_exit 1 "$rc" "verify returns non-zero when the digest does not match the payload"
}

test_verify_sha512_matching_payload_succeeds() {
    local sb rc=0
    gc_sandbox sb
    command printf 'the-real-payload\n' >"$sb/payload/$GC_ASSET"
    # The published checksum is the REAL digest of the payload — verify must pass.
    # Compute `<hexdigest>  <asset>` exactly as sha512sum -c consumes it.
    (
        cd "$sb/payload" || exit 1
        command sha512sum "$GC_ASSET"
    ) >"$sb/expected_sha"
    gc_stub_curl "$sb" ok
    run_verify_sha512 "$sb" >/dev/null 2>&1 && rc=0 || rc=$?
    assert_exit 0 "$rc" "verify returns 0 when the published digest matches the payload"
}

test_verify_sha512_no_digest_tool_fails_closed() {
    local sb rc=0 out
    gc_sandbox sb
    command printf 'the-real-payload\n' >"$sb/payload/$GC_ASSET"
    # A valid matching checksum, so the ONLY reason to fail is the absent digest
    # tool — proving the else-arm fails closed rather than skipping verification.
    (
        cd "$sb/payload" || exit 1
        command sha512sum "$GC_ASSET"
    ) >"$sb/expected_sha"
    gc_stub_curl "$sb" ok
    # hermetic PATH = stubbin only → no sha512sum / shasum resolvable.
    out="$(run_verify_sha512 "$sb" hermetic)" || rc=$?
    assert_exit 1 "$rc" "verify fails closed (non-zero) when no SHA-512 tool is available"
    assert_contains "$out" "No SHA-512 tool" "explains the missing digest tool"
}

# --- Group G2: ensure_git_cliff install orchestration (issue #252) -----------
#
# Group G above drives _git_cliff_verify_sha512 in isolation plus the one
# ensure_git_cliff branch reachable without an install (the already-on-PATH
# short-circuit). The install machinery itself — the cargo branch, the arch/OS
# case mappings (both "unsupported" return-1 arms), and the full curl → verify →
# tar → sudo-mv pipeline (including the tar-failure branch) — was unexercised, so
# an inverted return code or a no-op'd install step would ship unnoticed. These
# drive ensure_git_cliff end-to-end with stubbed cargo/uname/curl/tar/sudo on a
# CONTROLLED PATH (stubbin:/usr/bin:/bin) — the real cargo/git-cliff are never
# resolvable, so each branch is selected by which stubs are present, and no
# network, sudo, or real /usr/local/bin write ever happens.

# run_ensure_git_cliff <sandbox>
# Sources git-cliff.sh in a subshell with PATH = <sandbox>/stubbin:/usr/bin:/bin
# and GIT_CLIFF_VERSION pinned to 9.9.9 (so asset names and the extracted
# git-cliff-<version>/ dir are deterministic), runs ensure_git_cliff, echoes
# combined stdout+stderr, and preserves the exit code. Which branch runs is
# decided entirely by the stubs the caller wrote into <sandbox>/stubbin.
GC_INSTALL_VERSION="9.9.9"
run_ensure_git_cliff() {
    local sb="$1"
    (
        PATH="$sb/stubbin:/usr/bin:/bin"
        export PATH
        GIT_CLIFF_VERSION="$GC_INSTALL_VERSION"
        export GIT_CLIFF_VERSION
        # shellcheck source=bin/lib/release/git-cliff.sh
        source "$REPO_ROOT/bin/lib/release/git-cliff.sh"
        ensure_git_cliff
    ) 2>&1
}

# gc_stub_cargo <sandbox> <ok|fail>
# A `cargo` stub that records its full argument line to <sandbox>/cargo_args (so a
# test can assert the version pin and --locked survived) and exits 0 (ok) or 1
# (fail), to drive the cargo branch and its `return $?`.
gc_stub_cargo() {
    local sb="$1" mode="$2"
    command cat >"$sb/stubbin/cargo" <<EOF
#!/bin/sh
echo "\$*" >"$sb/cargo_args"
case "$mode" in
    ok) exit 0 ;;
    *) exit 1 ;;
esac
EOF
    command chmod +x "$sb/stubbin/cargo"
}

# gc_stub_uname <sandbox> <arch> <os>
# A `uname` stub returning <arch> for -m and <os> for -s, so the arch/OS case
# arms — including the "unsupported" return-1 arms — are hit deterministically
# regardless of the real host. os is lowercased by the function (via `tr`).
gc_stub_uname() {
    local sb="$1" arch="$2" os="$3"
    command cat >"$sb/stubbin/uname" <<EOF
#!/bin/sh
case "\$1" in
    -m) echo "$arch" ;;
    *) echo "$os" ;;
esac
EOF
    command chmod +x "$sb/stubbin/uname"
}

# gc_stub_curl_install <sandbox> <ok|badsum|dlfail>
# A `curl` stub for the binary-download path. ensure_git_cliff / verify call it as
# `curl -sfL <url> -o <outfile>`. The stub is asset-agnostic: it records every
# requested URL (one per line) to <sandbox>/curl_urls, and derives the tarball
# name from the .sha512 -o target's basename, so the same stub serves any
# arch/OS mapping (x86_64-unknown-linux-gnu, aarch64-apple-darwin, …). Modes:
#   ok     — write fixed payload bytes to the tarball -o target, and the REAL
#            matching SHA-512 line (`<digest>  <asset>`) to the .sha512 -o target,
#            so _git_cliff_verify_sha512 passes and the pipeline proceeds.
#   badsum — payload written correctly, but the .sha512 line carries a well-formed
#            WRONG digest (first nibble flipped) → sha512sum -c mismatch → refusal.
#   dlfail — exit 1 without writing (the first, tarball download fails).
gc_stub_curl_install() {
    local sb="$1" mode="$2"
    local payload="git-cliff-fake-tarball-payload"
    local digest
    digest="$(printf '%s' "$payload" | command sha512sum | command cut -c1-128)"
    if [ "$mode" = "badsum" ]; then
        case "$digest" in
            0*) digest="1${digest#?}" ;;
            *) digest="0${digest#?}" ;;
        esac
    fi
    command cat >"$sb/stubbin/curl" <<EOF
#!/bin/sh
url=""; out=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        -*) shift ;;
        *) url="\$1"; shift ;;
    esac
done
echo "\$url" >>"$sb/curl_urls"
EOF
    if [ "$mode" = "dlfail" ]; then
        command cat >>"$sb/stubbin/curl" <<'EOF'
exit 1
EOF
    else
        command cat >>"$sb/stubbin/curl" <<EOF
[ -n "\$out" ] || exit 1
case "\$url" in
    *.sha512)
        asset="\$(basename "\$out" .sha512)"
        printf '%s  %s\n' "$digest" "\$asset" >"\$out" ;;
    *) printf '%s' "$payload" >"\$out" ;;
esac
exit 0
EOF
    fi
    command chmod +x "$sb/stubbin/curl"
}

# gc_stub_tar <sandbox> <ok|fail>
# A `tar` stub invoked as `tar xz -f <file> -C <dir>`. On ok it creates the
# git-cliff-<version>/git-cliff layout under -C that the sudo-mv expects; on fail
# it exits 1 to drive the tar-extraction-failure branch.
gc_stub_tar() {
    local sb="$1" mode="$2"
    command cat >"$sb/stubbin/tar" <<EOF
#!/bin/sh
mode="$mode"
cdir=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -C) cdir="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [ "\$mode" = "fail" ]; then
    exit 1
fi
command mkdir -p "\$cdir/git-cliff-${GC_INSTALL_VERSION}"
: >"\$cdir/git-cliff-${GC_INSTALL_VERSION}/git-cliff"
exit 0
EOF
    command chmod +x "$sb/stubbin/tar"
}

# gc_stub_sudo <sandbox>
# A no-op `sudo` that records it was reached (touches <sandbox>/sudo_called) and
# appends each invocation's argument line to <sandbox>/sudo_args — ensure_git_cliff
# calls it twice (`sudo command mv …` then `sudo command chmod +x …`), so a test
# can assert both the /usr/local/bin destination and the chmod +x. Always exits 0,
# so the mv/chmod into /usr/local/bin never touch the real filesystem while the
# happy path still completes and returns 0.
gc_stub_sudo() {
    local sb="$1"
    command cat >"$sb/stubbin/sudo" <<EOF
#!/bin/sh
: >"$sb/sudo_called"
echo "\$*" >>"$sb/sudo_args"
exit 0
EOF
    command chmod +x "$sb/stubbin/sudo"
}

test_ensure_git_cliff_cargo_success() {
    local sb rc=0 out
    gc_sandbox sb
    gc_stub_cargo "$sb" ok
    out="$(run_ensure_git_cliff "$sb")" || rc=$?
    assert_exit 0 "$rc" "ensure_git_cliff returns 0 when cargo installs successfully"
    assert_file_contains "$sb/cargo_args" "install git-cliff" "the cargo branch was taken (cargo install invoked)"
    # The pinned version + --locked are the supply-chain guard on the cargo path
    # (reproducible build, no silently-latest crate) — assert they survived.
    assert_file_contains "$sb/cargo_args" "--version $GC_INSTALL_VERSION" "cargo install pins the version"
    assert_file_contains "$sb/cargo_args" "--locked" "cargo install passes --locked"
    assert_not_contains "$out" "Downloading" "cargo success never reaches the binary-download path"
}

test_ensure_git_cliff_cargo_failure_propagates() {
    local sb rc=0 out
    gc_sandbox sb
    gc_stub_cargo "$sb" fail
    out="$(run_ensure_git_cliff "$sb")" || rc=$?
    assert_exit 1 "$rc" "ensure_git_cliff propagates cargo's non-zero exit (return \$?)"
    assert_true "[ -f '$sb/cargo_args' ]" "the cargo branch was taken before failing"
    assert_not_contains "$out" "Downloading" "a cargo failure does not fall through to the binary path"
}

test_ensure_git_cliff_unsupported_arch() {
    local sb rc=0 out
    gc_sandbox sb
    # cargo absent (no stub) → binary path; uname -m reports an unsupported arch.
    gc_stub_uname "$sb" "mips" "linux"
    out="$(run_ensure_git_cliff "$sb")" || rc=$?
    assert_exit 1 "$rc" "ensure_git_cliff returns 1 on an unsupported architecture"
    assert_contains "$out" "Unsupported architecture: mips" "names the unsupported arch"
}

test_ensure_git_cliff_unsupported_os() {
    local sb rc=0 out
    gc_sandbox sb
    # Supported arch, but an unsupported OS trips the second case's return-1 arm.
    gc_stub_uname "$sb" "x86_64" "Plan9"
    out="$(run_ensure_git_cliff "$sb")" || rc=$?
    assert_exit 1 "$rc" "ensure_git_cliff returns 1 on an unsupported OS"
    assert_contains "$out" "Unsupported OS: plan9" "names the (lowercased) unsupported OS"
}

test_ensure_git_cliff_download_failure() {
    local sb rc=0 out
    gc_sandbox sb
    gc_stub_uname "$sb" "x86_64" "linux"
    gc_stub_curl_install "$sb" dlfail
    out="$(run_ensure_git_cliff "$sb")" || rc=$?
    assert_exit 1 "$rc" "ensure_git_cliff returns 1 when the tarball download fails"
    assert_contains "$out" "Failed to download git-cliff" "reports the failed download"
}

test_ensure_git_cliff_checksum_failure() {
    local sb rc=0 out
    gc_sandbox sb
    gc_stub_uname "$sb" "x86_64" "linux"
    # Tarball downloads fine, but its published .sha512 does not match → refuse.
    gc_stub_curl_install "$sb" badsum
    out="$(run_ensure_git_cliff "$sb")" || rc=$?
    assert_exit 1 "$rc" "ensure_git_cliff returns 1 when checksum verification fails"
    assert_contains "$out" "checksum verification failed" "refuses to install on a digest mismatch"
}

test_ensure_git_cliff_tar_failure() {
    local sb rc=0 out
    gc_sandbox sb
    gc_stub_uname "$sb" "x86_64" "linux"
    gc_stub_curl_install "$sb" ok
    gc_stub_tar "$sb" fail
    # Stub sudo even though the failing-tar branch must NOT reach it: this both
    # keeps the test hermetic (no fall-through to a real /usr/bin/sudo if the
    # `if command tar …` condition were ever inverted) and lets the sudo_called
    # marker positively prove the else-arm was taken.
    gc_stub_sudo "$sb"
    out="$(run_ensure_git_cliff "$sb")" || rc=$?
    assert_exit 1 "$rc" "ensure_git_cliff returns 1 when tar extraction fails"
    assert_contains "$out" "Failed to install git-cliff" "reports the failed extraction"
    assert_true "[ ! -f '$sb/sudo_called' ]" "a tar-extraction failure never reaches the sudo install step"
}

test_ensure_git_cliff_happy_path() {
    local sb rc=0 out
    gc_sandbox sb
    # Full binary-install pipeline: download → verify → extract → sudo mv, all
    # stubbed. cargo absent forces the binary path; sudo is a no-op so nothing
    # touches a real /usr/local/bin, yet ensure_git_cliff runs to completion.
    gc_stub_uname "$sb" "x86_64" "linux"
    gc_stub_curl_install "$sb" ok
    gc_stub_tar "$sb" ok
    gc_stub_sudo "$sb"
    out="$(run_ensure_git_cliff "$sb")" || rc=$?
    assert_exit 0 "$rc" "ensure_git_cliff returns 0 on a full successful binary install"
    assert_contains "$out" "installed successfully" "reports a successful install"
    assert_true "[ -f '$sb/sudo_called' ]" "the install step ran (sudo mv/chmod reached the sandbox stub)"
    # The recorded sudo argument lines pin the install destination + the +x bit,
    # so a regression that mv'd to the wrong path or dropped the chmod is caught.
    assert_file_contains "$sb/sudo_args" "/usr/local/bin" "sudo mv installs into /usr/local/bin"
    assert_file_contains "$sb/sudo_args" "chmod +x" "sudo chmod marks the binary executable"
    # The download URL reflects the x86_64/linux mapping (identity arch, linux →
    # unknown-linux-gnu), pinning the supported-arm asset-name construction.
    assert_file_contains "$sb/curl_urls" "x86_64-unknown-linux-gnu" "the x86_64/linux asset name is built correctly"
}

test_ensure_git_cliff_arm64_darwin_mapping() {
    local sb rc=0 out
    gc_sandbox sb
    # Drive the OTHER supported arch/OS arms: arm64 → aarch64 and darwin →
    # apple-darwin. A typo in either mapping (or a dropped arm64 alias) would
    # surface here as a wrong asset name in the recorded download URL.
    gc_stub_uname "$sb" "arm64" "Darwin"
    gc_stub_curl_install "$sb" ok
    gc_stub_tar "$sb" ok
    gc_stub_sudo "$sb"
    out="$(run_ensure_git_cliff "$sb")" || rc=$?
    assert_exit 0 "$rc" "ensure_git_cliff returns 0 for arm64/darwin"
    assert_contains "$out" "installed successfully" "arm64/darwin completes the install"
    assert_file_contains "$sb/curl_urls" "aarch64-apple-darwin" \
        "arm64 → aarch64 and darwin → apple-darwin are mapped into the asset name"
}
