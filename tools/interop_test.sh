#!/bin/sh
# 1:1 interop test against the real Microsoft Open XML SDK
# (DocumentFormat.OpenXml, the published package of dotnet/Open-XML-SDK).
#
#   Direction A: the SDK creates docx/xlsx/pptx -> nanoxml reads + validates.
#   Direction B: nanoxml creates docx/xlsx/pptx -> Microsoft's OpenXmlValidator
#                must report zero errors.
#   Round-trip:  SDK files re-serialized through nanoxml's DOM must not gain
#                a single validation error.
#
# Requires: zig, dotnet (brew install dotnet). Exits nonzero on any failure.
set -eu

cd "$(dirname "$0")/.."
ROOT=$(pwd)
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

if [ -d /opt/homebrew/opt/dotnet/libexec ]; then
    export DOTNET_ROOT=/opt/homebrew/opt/dotnet/libexec
    export PATH="/opt/homebrew/opt/dotnet/bin:$PATH"
fi
export DOTNET_CLI_TELEMETRY_OPTOUT=1

echo "== build =="
zig build -Doptimize=ReleaseFast
(cd tools/interop && dotnet build -c Release -v quiet)
NX="$ROOT/zig-out/bin/nanoxml"
MS="$ROOT/tools/interop/bin/Release/net10.0/interop"

echo
echo "== A: Microsoft SDK creates -> nanoxml reads + validates =="
"$MS" create "$DIR"
"$NX" text "$DIR/sdk.docx"
"$NX" csv "$DIR/sdk.xlsx"
"$NX" text "$DIR/sdk.pptx"
"$NX" validate "$DIR/sdk.docx"
"$NX" validate "$DIR/sdk.xlsx"
"$NX" validate "$DIR/sdk.pptx"

echo
echo "== B: nanoxml creates -> Microsoft OpenXmlValidator judges =="
"$NX" new docx "$DIR/nx.docx"
"$NX" new xlsx "$DIR/nx.xlsx"
"$NX" new pptx "$DIR/nx.pptx"
"$MS" verify "$DIR/nx.docx"
"$MS" verify "$DIR/nx.xlsx"
"$MS" verify "$DIR/nx.pptx"

echo
echo "== round-trip: SDK file -> nanoxml DOM -> Microsoft validator =="
"$NX" roundtrip "$DIR/sdk.docx" "$DIR/rt.docx"
"$MS" verify "$DIR/rt.docx"
"$NX" roundtrip "$DIR/sdk.xlsx" "$DIR/rt.xlsx"
"$MS" verify "$DIR/rt.xlsx"
# The SDK's own minimal pptx fails its own validator (missing slideMaster +
# notesSz) BEFORE we touch it; assert the round-trip adds no NEW errors.
"$NX" roundtrip "$DIR/sdk.pptx" "$DIR/rt.pptx"
before=$("$MS" verify "$DIR/sdk.pptx" | tail -1 || true)
after=$("$MS" verify "$DIR/rt.pptx" | tail -1 || true)
echo "sdk.pptx $before / rt.pptx $after"
[ "$before" = "$after" ] || { echo "FAIL: round-trip changed the error count"; exit 1; }

echo
echo "ALL INTEROP CHECKS PASSED"
