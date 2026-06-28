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

# Pin the fallback binary version (cargo install tracks latest).
GIT_CLIFF_VERSION="${GIT_CLIFF_VERSION:-2.8.0}"

ensure_git_cliff() {
    if command -v git-cliff >/dev/null 2>&1; then
        return 0
    fi

    command echo "git-cliff not found, installing..."

    # Prefer cargo when present.
    if command -v cargo >/dev/null 2>&1; then
        cargo install git-cliff
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

    download_url="https://github.com/orhun/git-cliff/releases/download/v${version}/git-cliff-${version}-${arch}-${os_type}.tar.gz"
    temp_dir="$(command mktemp -d)"

    command echo "Downloading git-cliff from $download_url..."
    if command curl -sfL "$download_url" | command tar xz -C "$temp_dir"; then
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
