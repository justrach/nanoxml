First release. Fast, zero-dependency Office Open XML (`.docx` / `.xlsx` / `.pptx`) reading **and writing** for Zig 0.16 — a lean port of [dotnet/Open-XML-SDK](https://github.com/dotnet/Open-XML-SDK) at feature parity.

## Verified against the real Microsoft SDK

Cross-validated both directions against `DocumentFormat.OpenXml` 3.3.0 (`tools/interop_test.sh`):

- nanoxml-created docx / xlsx / pptx all pass Microsoft's own `OpenXmlValidator` with **0 errors** (the SDK's own minimal pptx `Create()` output does not)
- SDK-created files read correctly by nanoxml; round-trips through nanoxml's DOM add **zero** validation errors

## Speed

Identical workload (200k-row xlsx → shared-string-resolved, gap-preserving quoted CSV; outputs character-identical), Apple Silicon, single thread:

| Implementation | best |
|---|---|
| **nanoxml** (ReleaseFast) | **179 ms** |
| Microsoft `DocumentFormat.OpenXml` 3.3.0, `OpenXmlReader` streaming (.NET 10 Release, post-JIT) | 833 ms — 4.7× slower |
| Python stdlib | 2258 ms — 12.6× slower |

## What's in the box

- OPC packaging: open / create / save / clone, add & delete parts, internal + external + hyperlink relationships, content-type maintenance, core properties read **and** write
- Full `OpenXmlElement`-style DOM (Descendants/Ancestors, Insert*/Remove*/ReplaceChild, CloneNode, Inner/OuterXml, namespaces)
- Streaming pull parser (SIMD) + streaming writer
- `OpenXmlValidator`-style package validation, markup-compatibility processing (`mc:AlternateContent`/`Ignorable`), Flat OPC in both directions, zip64 read+write
- CLI: `parts · info · text · sheets · csv · dump · validate · roundtrip · bench · new`

See [FEATURE_PARITY.md](https://github.com/justrach/nanoxml/blob/main/FEATURE_PARITY.md) for the full SDK→nanoxml matrix. 500+ test executions across 9 suites.

macOS binaries are signed (Developer ID). `checksums.sha256` covers all assets.
