# nanoxml for agents

`nanoxml` is a single static binary for reading, editing, creating, and validating Office files (`.docx`, `.xlsx`, `.pptx`). No runtime, no Office, no Python. Outputs are plain text or JSON; exit codes are reliable. Files it writes pass Microsoft's own `OpenXmlValidator` with zero errors.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/justrach/nanoxml/main/install.sh | sh
```

or grab a binary directly from [releases](https://github.com/justrach/nanoxml/releases) (`nanoxml-darwin-arm64`, `nanoxml-darwin-x86_64`, `nanoxml-linux-x86_64`, `nanoxml-linux-arm64`).

## Contract

- Exit `0` = success. Nonzero = failure (including `validate` on an invalid file). Errors print `nanoxml: error: <Name>` to stderr.
- `--json` on `info` / `parts` / `sheets` / `validate` prints a single JSON document to stdout. `csv`, `text`, `dump` are already machine-readable.
- Write commands edit **in place** by default; pass `--out PATH` to write elsewhere. Status messages go to stderr, so stdout stays clean for piping.
- `-` means stdin wherever a content file is accepted.
- Flags may appear anywhere in the argument list.

## Read

```bash
nanoxml info report.docx --json
# {"kind":"docx","main_part":"word/document.xml","parts":4,"main_part_bytes":307}

nanoxml text report.docx              # plain text, one paragraph per line
nanoxml csv data.xlsx 0               # sheet 0 as RFC-4180 CSV (gaps + quoting preserved)
nanoxml sheets data.xlsx --json       # [{"index":0,"name":"Data","part":"xl/worksheets/sheet1.xml"}]
nanoxml parts any.docx --json         # every part with size + content type
nanoxml dump any.docx word/document.xml   # raw XML of one part
```

## Edit

```bash
nanoxml set-cell budget.xlsx 0 B7 1250          # number (auto-detected)
nanoxml set-cell budget.xlsx 0 A1 "Q3 total"    # string -> inline string
nanoxml set-cell budget.xlsx 0 C2 007 --string  # force type when needed
nanoxml set-props report.docx --title "Final" --creator "agent"
nanoxml dump f.docx word/document.xml | edit-somehow | nanoxml set-part f.docx word/document.xml -
nanoxml rm-part f.docx word/media/image3.png    # also removes its relationships
```

## Create

```bash
nanoxml from-csv data.csv report.xlsx --sheet Results   # CSV -> real xlsx
some-tool | nanoxml from-csv - report.xlsx              # stdin works
nanoxml from-text notes.txt memo.docx --title "Memo"    # line = paragraph
nanoxml new pptx deck.pptx                              # valid deck skeleton
```

`from-csv` round-trips: `nanoxml csv` of the output reproduces the input CSV byte-for-byte (numbers stay numbers, quoted fields stay quoted, empty fields stay gaps).

## Verify your work

```bash
nanoxml validate edited.xlsx --json
# {"ok":true,"errors":0,"diagnostics":[]}     exit 0
# {"ok":false,"errors":2,"diagnostics":[{"severity":"error","part":"...","message":"..."}]}   exit 1
```

Run `validate` after `set-part` edits — it checks XML well-formedness of every part, relationship integrity, content types, expected root elements, and `r:id` reference resolution.

## Recipes

Extract spreadsheet data for analysis:
```bash
nanoxml sheets book.xlsx --json          # discover sheets
nanoxml csv book.xlsx 2 > sheet2.csv     # pull the one you need
```

Patch one cell in place, safely:
```bash
nanoxml set-cell book.xlsx 0 D9 42 --out /tmp/edited.xlsx
nanoxml validate /tmp/edited.xlsx && mv /tmp/edited.xlsx book.xlsx
```

Surgical XML edit on any part:
```bash
nanoxml parts f.docx --json              # find the part
nanoxml dump f.docx word/styles.xml > s.xml
# ... edit s.xml ...
nanoxml set-part f.docx word/styles.xml s.xml
nanoxml validate f.docx
```

Generate a report file from program output:
```bash
my-analysis --csv | nanoxml from-csv - results.xlsx --sheet Analysis
```

## Performance

200k-row xlsx → CSV in 179 ms single-threaded (4.7× faster than Microsoft's own SDK, 12.6× faster than Python stdlib). Safe to call in tight loops.
