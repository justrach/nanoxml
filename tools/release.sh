#!/bin/sh
# Local release builder for nanoxml (the codedb release flow, run locally).
#
#   tools/release.sh v0.0.1
#
# Builds ReleaseFast binaries for darwin-arm64 / darwin-x86_64 /
# linux-x86_64 / linux-arm64, signs the macOS ones with the Developer ID
# certificate, notarizes them with `xcrun notarytool` using the
# `codedb-local` keychain profile when it exists (skips with a warning when
# it doesn't), writes checksums, and uploads everything to the GitHub
# release for the given tag (creating the tag + release if needed).
set -eu

TAG=${1:?usage: tools/release.sh vX.Y.Z}
IDENTITY=${CODESIGN_IDENTITY:-"Developer ID Application: Rachit Pradhan (WWP9DLJ27P)"}
NOTARY_PROFILE=${NOTARY_PROFILE:-codedb-local}

cd "$(dirname "$0")/.."
DIST=zig-out/release
rm -rf "$DIST"
mkdir -p "$DIST"

for target in aarch64-macos x86_64-macos x86_64-linux aarch64-linux; do
    case "$target" in
        aarch64-macos) asset=nanoxml-darwin-arm64 ;;
        x86_64-macos)  asset=nanoxml-darwin-x86_64 ;;
        x86_64-linux)  asset=nanoxml-linux-x86_64 ;;
        aarch64-linux) asset=nanoxml-linux-arm64 ;;
    esac
    echo "== build $asset ($target) =="
    zig build -Doptimize=ReleaseFast -Dtarget="$target"
    cp zig-out/bin/nanoxml "$DIST/$asset"
done

echo "== sign macOS binaries =="
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    for asset in nanoxml-darwin-arm64 nanoxml-darwin-x86_64; do
        codesign --force --sign "$IDENTITY" --options runtime --timestamp "$DIST/$asset"
        codesign --verify --strict "$DIST/$asset" && echo "signed $asset"
    done
else
    echo "WARNING: no Developer ID certificate found; shipping unsigned macOS binaries"
fi

echo "== notarize (profile: $NOTARY_PROFILE) =="
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    for asset in nanoxml-darwin-arm64 nanoxml-darwin-x86_64; do
        ditto -c -k "$DIST/$asset" "$DIST/$asset.zip"
        xcrun notarytool submit "$DIST/$asset.zip" --keychain-profile "$NOTARY_PROFILE" --wait
        rm "$DIST/$asset.zip"
        echo "notarized $asset"
    done
else
    echo "WARNING: notary profile '$NOTARY_PROFILE' not in keychain — skipping notarization."
    echo "         restore it with: xcrun notarytool store-credentials $NOTARY_PROFILE \\"
    echo "             --apple-id <id> --team-id WWP9DLJ27P --password <app-specific>"
    echo "         then re-run this script to notarize + re-upload."
fi

echo "== checksums =="
(cd "$DIST" && shasum -a 256 nanoxml-* | sort > checksums.sha256 && cat checksums.sha256)

echo "== github release $TAG =="
git tag -f "$TAG"
git push -f origin "$TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DIST"/nanoxml-* "$DIST"/checksums.sha256 install.sh --clobber
else
    gh release create "$TAG" "$DIST"/nanoxml-* "$DIST"/checksums.sha256 install.sh \
        --title "nanoxml $TAG" --notes-file tools/release_notes.md
fi
echo "DONE: https://github.com/justrach/nanoxml/releases/tag/$TAG"
