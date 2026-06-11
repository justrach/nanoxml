#!/bin/sh
# nanoxml installer: detects platform, downloads the latest release binary,
# installs to /usr/local/bin (or ~/.local/bin when not writable).
#
#   curl -fsSL https://raw.githubusercontent.com/justrach/nanoxml/main/install.sh | sh
set -eu

REPO=justrach/nanoxml

case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=x86_64 ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

asset="nanoxml-$os-$arch"
url="https://github.com/$REPO/releases/latest/download/$asset"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "downloading $url"
curl -fsSL -o "$tmp/nanoxml" "$url"
chmod +x "$tmp/nanoxml"

# Sanity: run it.
"$tmp/nanoxml" >/dev/null 2>&1 || true

dest=/usr/local/bin
if [ ! -w "$dest" ]; then
    if [ "$(id -u)" = 0 ]; then
        mkdir -p "$dest"
    else
        dest="$HOME/.local/bin"
        mkdir -p "$dest"
    fi
fi
mv "$tmp/nanoxml" "$dest/nanoxml"
echo "installed $dest/nanoxml"

case ":$PATH:" in
    *":$dest:"*) ;;
    *) echo "NOTE: add $dest to PATH" ;;
esac
"$dest/nanoxml" 2>&1 | head -2
