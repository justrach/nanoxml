#!/bin/sh
# Smoke-test the agent-facing CLI surface end to end.
set -eu
cd "$(dirname "$0")/.."
zig build -Doptimize=ReleaseFast >/dev/null
NX=zig-out/bin/nanoxml
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

echo "== csv -> xlsx -> csv round-trip =="
printf 'name,qty,price\n"widget, large",2,0.5\ngizmo,,3\n' > "$DIR/in.csv"
$NX from-csv "$DIR/in.csv" "$DIR/t.xlsx" --sheet Data
$NX csv "$DIR/t.xlsx" > "$DIR/out.csv"
diff "$DIR/in.csv" "$DIR/out.csv" && echo "csv round-trip identical"

echo "== set-cell: edit + add, types =="
$NX set-cell "$DIR/t.xlsx" 0 B2 7
$NX set-cell "$DIR/t.xlsx" 0 D1 "note, quoted" --out "$DIR/t2.xlsx"
$NX csv "$DIR/t2.xlsx" | head -2
$NX csv "$DIR/t2.xlsx" | head -1 | grep -q '"note, quoted"' || { echo FAIL; exit 1; }
$NX csv "$DIR/t2.xlsx" | head -2 | tail -1 | grep -q ',7,' || { echo FAIL; exit 1; }

echo "== from-text + stdin =="
printf 'first paragraph\nsecond paragraph\n' | $NX from-text - "$DIR/t.docx" --title "Agent Doc"
$NX text "$DIR/t.docx"

echo "== set-props + json info =="
$NX set-props "$DIR/t.docx" --creator agent-smoke
$NX info "$DIR/t.docx" --json
$NX validate "$DIR/t.docx" --json

echo "== set-part via stdin + rm-part =="
$NX dump "$DIR/t.docx" word/document.xml | $NX set-part "$DIR/t.docx" word/copy.xml -
$NX parts "$DIR/t.docx" --json | grep -q 'word/copy.xml' || { echo FAIL; exit 1; }
$NX rm-part "$DIR/t.docx" word/copy.xml
$NX parts "$DIR/t.docx" --json | grep -q 'word/copy.xml' && { echo FAIL; exit 1; }

echo "== json outputs parse (python) =="
$NX info "$DIR/t.docx" --json | python3 -c "import json,sys; json.load(sys.stdin)"
$NX parts "$DIR/t.docx" --json | python3 -c "import json,sys; json.load(sys.stdin)"
$NX sheets "$DIR/t2.xlsx" --json | python3 -c "import json,sys; json.load(sys.stdin)"
$NX validate "$DIR/t.docx" --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['ok'] is True"

echo "== validate exit codes =="
$NX validate "$DIR/t2.xlsx" >/dev/null && echo "valid: exit 0"
printf 'PK' > "$DIR/garbage.docx"
if $NX validate "$DIR/garbage.docx" 2>/dev/null; then echo FAIL; exit 1; else echo "garbage: nonzero exit"; fi

echo
echo "ALL CLI CHECKS PASSED"
