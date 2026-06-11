# nanoxml

Fast Office Open XML (`.docx` / `.xlsx` / `.pptx`) reading **and writing** for Zig 0.16. Zero dependencies.

A from-scratch Zig take on [dotnet/Open-XML-SDK](https://github.com/dotnet/Open-XML-SDK): same layering, none of the weight. Open-XML-SDK ships ~6000 generated element classes; real workloads touch a dozen of them. nanoxml implements the full *feature surface* — packaging, parts/relationships, DOM, streaming read+write, validation, markup compatibility, Flat OPC — over a zero-copy SIMD pull parser, using the techniques from [justrach/codedb](https://github.com/justrach/codedb) (explicit `@Vector` scanning, arena-per-job allocation, slice-don't-copy).

**[FEATURE_PARITY.md](FEATURE_PARITY.md) maps every SDK feature area to the nanoxml API**, with the two deliberate exclusions documented.

Parity is **test-first**: [src/parity_test.zig](src/parity_test.zig) pins the Open-XML-SDK behaviors (create, round-trip, DOM editing, Clone, Flat OPC, validation, MC processing, streaming writes, package properties). Created files are additionally validated by Info-ZIP (`unzip -t`) and Python's `zipfile`+`ElementTree`. 504 test executions across 9 suites.

## Layer map

| Open-XML-SDK (.NET)                          | nanoxml (Zig)        |
|----------------------------------------------|----------------------|
| `System.IO.Packaging` ZIP container (+zip64 r/w) | `src/zip.zig` (Archive + Writer) |
| `System.IO.Packaging` content types + rels   | `src/opc.zig` (open/getPart/setPart/save) |
| `OpenXmlPartContainer` (AddNewPart/DeletePart/AddExternalRelationship/AddHyperlinkRelationship) | `opc.Package.addPart/deletePart/add*Relationship` |
| `PackageProperties` (read **and write**)     | `opc.coreProperties` / `opc.setCoreProperties` |
| `CloneableExtensions.Clone`                  | `opc.Package.clone`  |
| `FlatOpcExtensions` (To/FromFlatOpc)         | `src/flatopc.zig`    |
| `OpenXmlReader` (streaming reader)           | `src/xml.zig` (`Parser`) |
| `OpenXmlWriter` (streaming writer)           | `src/xml.zig` (`Writer`) |
| `OpenXmlElement` tree (Descendants/Ancestors/Insert*/CloneNode/InnerXml/namespaces) | `src/dom.zig` |
| `MarkupCompatibilityProcessSettings` (mc:AlternateContent/Ignorable/ProcessContent) | `src/mc.zig` |
| `OpenXmlValidator`                           | `src/validate.zig`   |
| `WordprocessingDocument` / `SpreadsheetDocument` / `PresentationDocument` (read) | `src/ooxml.zig` |
| `*.Create()` (write)                         | `ooxml.DocumentBuilder` / `WorkbookBuilder` / `PresentationBuilder` |

## Build & run

```bash
zig build -Doptimize=ReleaseFast

# read
./zig-out/bin/nanoxml text   report.docx          # extract text
./zig-out/bin/nanoxml csv    data.xlsx 0          # worksheet 0 as CSV
./zig-out/bin/nanoxml sheets data.xlsx            # list worksheets
./zig-out/bin/nanoxml parts  any.docx             # parts + content types
./zig-out/bin/nanoxml dump   any.docx word/document.xml

# write
./zig-out/bin/nanoxml new docx out.docx           # create from scratch
./zig-out/bin/nanoxml new xlsx out.xlsx
./zig-out/bin/nanoxml new pptx out.pptx

# measure
./zig-out/bin/nanoxml bench data.xlsx 10 full     # full | parse | unzip
```

As a library — read:

```zig
const nanoxml = @import("nanoxml");

var pkg = try nanoxml.opc.Package.open(gpa, file_bytes);
defer pkg.deinit();
var wb = try nanoxml.ooxml.Workbook.open(&pkg);
var csv: std.ArrayList(u8) = .empty;
try wb.sheetToCsv(gpa, 0, &csv);
```

Create:

```zig
var b = nanoxml.ooxml.DocumentBuilder.init(gpa);
defer b.deinit();
b.title = "Report";
try b.addParagraph("Hello from Zig");
const docx_bytes = try b.save(gpa); // a complete .docx
```

Round-trip edit (open → mutate via DOM → save):

```zig
var pkg = try nanoxml.opc.Package.open(gpa, file_bytes);
defer pkg.deinit();
const arena = pkg.arena.allocator();

const root = try nanoxml.dom.parse(arena, try pkg.getPart("word/document.xml"));
try root.child("body").?.child("p").?.child("r").?.child("t").?.setText(arena, "edited");
var ser: std.ArrayList(u8) = .empty;
try nanoxml.dom.serialize(root, gpa, &ser, .{});
try pkg.setPart("word/document.xml", ser.items);

const new_file = try pkg.save(gpa); // untouched parts copied raw, no re-deflate
```

Parts, relationships, properties, clone (the `OpenXmlPartContainer` surface):

```zig
// AddImagePart + FeedData + GetIdOfPart, in one call:
const rid = (try pkg.addPart("word/media/image1.png", png_bytes, .{
    .content_type = "image/png",
    .rel_type = nanoxml.opc.RelType.image,
    .rel_source = "word/document.xml",
})).?;
_ = try pkg.addHyperlinkRelationship("word/document.xml", "https://ziglang.org");
try pkg.setCoreProperties(.{ .title = "Edited", .creator = "nanoxml" });
try pkg.deletePart("word/media/old.png");   // part + CT + inbound rels
var snapshot = try pkg.clone(gpa);          // independent in-memory copy
```

Validate, Flat OPC, markup compatibility:

```zig
var result = try nanoxml.validate.validatePackage(gpa, &pkg);
defer result.deinit();
for (result.diagnostics) |d| std.debug.print("[{s}] {s}: {s}\n", .{ @tagName(d.severity), d.part orelse "-", d.message });

var flat: std.ArrayList(u8) = .empty;
try nanoxml.flatopc.toFlatOpc(&pkg, gpa, &flat, .{ .progid = "Word.Document" });
const zip_bytes = try nanoxml.flatopc.fromFlatOpc(gpa, flat.items);

const w_ns = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
try nanoxml.mc.process(arena, root, .{ .understood = &.{w_ns} });
```

Streaming writes (`OpenXmlPartWriter`):

```zig
var out: std.ArrayList(u8) = .empty;
var w = nanoxml.xml.Writer.init(gpa, &out);
defer w.deinit();
try w.writeDeclaration();
try w.startElement("w:document");
try w.attribute("xmlns:w", w_ns);
try w.textElement("w:t", "a < b & c");   // escaped automatically
try w.endElement();
try w.end();                              // enforces balance
```

## Numbers

Apple Silicon, ReleaseFast, single thread. Corpus: synthetic 200k-row xlsx
(6.75 MiB zip → 46 MiB XML, 1.2M cells), generated by `tools/gen_corpus.py`.

| Stage (`bench` mode)                  | time   | throughput (uncompressed) |
|---------------------------------------|--------|---------------------------|
| `unzip` — inflate all parts           |  61 ms | 756 MiB/s                 |
| `parse` — + pull-parse all XML (6.8M events) | 151 ms | 305 MiB/s          |
| `full` — + typed layer → 14.5 MB CSV  | 179 ms | 257 MiB/s                 |

Same workload, Python stdlib (`zipfile` + C-accelerated `ElementTree` + `csv`,
`tools/py_baseline.py`): **2258 ms — nanoxml is ~12.6× faster.**

Other corpora: 50k-paragraph docx → text in 16.7 ms (638 MiB/s); a real
12-page Word doc parses end-to-end in 0.19 ms (~5300 docs/s).

## Design notes

- **Zero-copy reads.** ZIP entry names, XML names/attributes/text are slices
  into the source buffer; entity decoding is lazy (skipped when no `&`).
- **SIMD scans.** `@Vector(VW, u8)` compares + `@ctz` mask walks; `VW` is
  target-aware (32 lanes with AVX2, 16 with NEON/SSE).
- **Arena per package / per job.** Freeing the Package frees everything.
  Measured cautionary tale: small allocations through `page_allocator` cost
  14× (one mmap syscall each).
- **Cheap round-trips.** `Package.save` copies untouched entries in their
  already-compressed form; only modified parts are re-deflated. Mutated
  relationship lists and content types are re-serialized automatically
  (sorted, deterministic). The zip writer falls back to store when deflate
  doesn't shrink an entry, and emits zip64 records when limits are exceeded.
- **Local-name matching** (`w:t`/`x:t`/`a:t` → `t`), and `r:id`-style
  attributes matched as "prefixed attr with local name `id`" — robust to
  producer prefix choices without namespace tables.

## What's covered

See [FEATURE_PARITY.md](FEATURE_PARITY.md) for the full SDK-to-nanoxml
matrix. Headlines —

Read: OPC (content types, rels, target resolution), zip64, store+deflate,
docx text (tracked deletions and field codes excluded, `mc:AlternateContent`
Choice-only), xlsx (tab order, shared strings incl. rich runs, phonetic-run
skipping, cell types `n/s/str/inlineStr/b/e`, gap preservation, CSV quoting),
pptx slide order + text, transitional/strict/macro-enabled detection, core
properties.

Write: document/workbook/presentation creation (typed cells, shared-string
dedup, ordered slides, core properties), generic DOM editing with the full
`OpenXmlElement` mutation surface, part add/delete with relationship and
content-type maintenance, external/hyperlink relationships, core-properties
write-back, package clone, Flat OPC in both directions, streaming XML
writer, zip64, RFC-conformant escaping (inverse-of-decode, property-tested).

Analysis: package validator (structure, well-formedness, relationship
integrity, expected roots, `r:id` reference resolution), markup
compatibility processor (AlternateContent/Ignorable/ProcessContent/
MustUnderstand).

Not covered (deliberately): the ~6000 generated typed classes (generic DOM
instead), full ECMA-376 particle validation, encrypted packages (the SDK
doesn't support those either).

## Tests & corpus

```bash
zig build test       # 504 test executions across 9 suites, incl. the parity spec
python3 tools/gen_corpus.py xlsx corpus/big.xlsx 200000
python3 tools/py_baseline.py corpus/big.xlsx 5
```
