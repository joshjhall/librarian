#!/usr/bin/env bash
# git-cliff installation helper for bin/release.sh.
#
# Description:
#   Ensures git-cliff is available for CHANGELOG generation. Tries cargo, then
#   falls back to the pre-built release binary for the host OS/arch.
#
# Usage:
#   . "${BIN_DIR}/lib/release/git-cliff.sh"
#   ensure_git_cliff || echo "git-cliff not available"

# Pin the version for both install paths (cargo and the fallback binary).
GIT_CLIFF_VERSION="${GIT_CLIFF_VERSION:-2.13.1}"

ensure_git_cliff() {
    if command -v git-cliff >/dev/null 2>&1; then
        return 0
    fi

    command echo "git-cliff not found, installing..."

    # Prefer cargo when present. Pin to the same version as the binary fallback
    # and pass --locked so the build uses git-cliff's committed Cargo.lock — this
    # makes installs reproducible and avoids silently pulling whatever is latest
    # (or maliciously published) on crates.io.
    if command -v cargo >/dev/null 2>&1; then
        cargo install git-cliff --version "$GIT_CLIFF_VERSION" --locked
        return $?
    fi

    # Otherwise download the pre-built binary.
    local os_type arch version download_url temp_dir
    os_type="$(command uname -s | command tr '[:upper:]' '[:lower:]')"
    arch="$(command uname -m)"
    version="$GIT_CLIFF_VERSION"

    case "$arch" in
        x86_64) arch="x86_64" ;;
        aarch64 | arm64) arch="aarch64" ;;
        *)
            command echo "Unsupported architecture: $arch" >&2
            return 1
            ;;
    esac

    case "$os_type" in
        linux) os_type="unknown-linux-gnu" ;;
        darwin) os_type="apple-darwin" ;;
        *)
            command echo "Unsupported OS: $os_type" >&2
            return 1
            ;;
    esac

    local asset
    asset="git-cliff-${version}-${arch}-${os_type}.tar.gz"
    download_url="https://github.com/orhun/git-cliff/releases/download/v${version}/${asset}"
    temp_dir="$(command mktemp -d)"

    # Download the tarball to a file (NOT piped straight into tar) so its
    # integrity can be checked before anything is extracted or installed with
    # sudo. The fix for the curl-pipe-tar supply-chain risk: download → verify
    # → extract → install, instead of streaming an unverified payload into tar.
    command echo "Downloading git-cliff from $download_url..."
    if ! command curl -sfL "$download_url" -o "$temp_dir/$asset"; then
        command rm -rf "$temp_dir"
        command echo "Failed to download git-cliff" >&2
        return 1
    fi

    # Verify the tarball against the per-asset SHA-512 checksum published in the
    # same release before installing. git-cliff ships a `<asset>.tar.gz.sha512`
    # for every release artifact; verifying it catches a corrupted/truncated
    # download or an asset swapped without updating its checksum. Fail closed if
    # the checksum can't be fetched or no digest tool is available.
    if ! _git_cliff_verify_sha512 "$temp_dir" "$asset" "$download_url"; then
        command rm -rf "$temp_dir"
        command echo "git-cliff checksum verification failed — refusing to install" >&2
        return 1
    fi

    if command tar xz -f "$temp_dir/$asset" -C "$temp_dir"; then
        sudo command mv "$temp_dir/git-cliff-${version}/git-cliff" /usr/local/bin/
        sudo command chmod +x /usr/local/bin/git-cliff
        command rm -rf "$temp_dir"
        command echo "✓ git-cliff installed successfully"
        return 0
    else
        command rm -rf "$temp_dir"
        command echo "Failed to install git-cliff" >&2
        return 1
    fi
}

# Verify a downloaded git-cliff tarball against the SHA-512 checksum file
# published alongside it. Args: <temp_dir> <asset_filename> <asset_url>.
# Returns 0 only when the checksum file is fetched AND the digest matches;
# fails closed (non-zero) on a missing checksum file or absent digest tool.
_git_cliff_verify_sha512() {
    local temp_dir="$1" asset="$2" asset_url="$3"
    local sums_file="$temp_dir/${asset}.sha512"

    if ! command curl -sfL "${asset_url}.sha512" -o "$sums_file"; then
        command echo "Failed to download checksum (${asset}.sha512)" >&2
        return 1
    fi

    # The .sha512 file is `<hexdigest>  <asset>` — the same format `sha512sum -c`
    # / `shasum -a 512 -c` consume. Check from inside temp_dir so the relative
    # filename in the checksum file resolves to the downloaded tarball.
    (
        command cd "$temp_dir" || exit 1
        if command -v sha512sum >/dev/null 2>&1; then
            command sha512sum -c "${asset}.sha512" >/dev/null 2>&1
        elif command -v shasum >/dev/null 2>&1; then
            command shasum -a 512 -c "${asset}.sha512" >/dev/null 2>&1
        else
            command echo "No SHA-512 tool (sha512sum/shasum) available for verification" >&2
            exit 1
        fi
    )
}
