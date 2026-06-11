# Feature parity with dotnet/Open-XML-SDK

This file maps the public feature surface of
[dotnet/Open-XML-SDK](https://github.com/dotnet/Open-XML-SDK) (and the
`System.IO.Packaging` layer it sits on) to the nanoxml API. Every "✅" is
backed by tests — see [src/parity_test.zig](src/parity_test.zig) for the
cross-cutting parity spec and each module's own test block for unit-level
pins. 504 test executions across 9 suites.

## 0. The 1:1 proof — refereed by Microsoft's own code

[tools/interop_test.sh](tools/interop_test.sh) runs both libraries against
each other using the real `DocumentFormat.OpenXml` 3.3.0 package (the
published artifact of dotnet/Open-XML-SDK) on .NET 10:

| Check | Result |
|---|---|
| SDK-created docx/xlsx/pptx → read by nanoxml (text, CSV with gaps+quoting, slides) | ✅ correct content |
| SDK-created files → `nanoxml validate` | ✅ 0 errors |
| nanoxml-created docx → Microsoft `OpenXmlValidator` | ✅ **0 errors** |
| nanoxml-created xlsx → Microsoft `OpenXmlValidator` | ✅ **0 errors** |
| nanoxml-created pptx → Microsoft `OpenXmlValidator` | ✅ **0 errors** (the SDK's own minimal `PresentationDocument.Create` output fails with 2 — nanoxml emits the full master/layout/theme/notesSz skeleton) |
| SDK docx/xlsx → re-serialized through nanoxml's DOM (`nanoxml roundtrip`) → Microsoft validator | ✅ 0 errors |
| SDK pptx → nanoxml round-trip | ✅ error count unchanged (2 pre-existing SDK errors in, 2 out — none added) |

Head-to-head speed, identical workload (200k-row xlsx → shared-string-resolved,
gap-preserving, quoted CSV; outputs character-identical), Apple Silicon,
single thread:

| Implementation | best | relative |
|---|---|---|
| **nanoxml** ReleaseFast | **179 ms** | 1× |
| `DocumentFormat.OpenXml` 3.3.0 `OpenXmlReader` streaming, .NET 10 Release, post-JIT | 833 ms | **4.7× slower** |
| Python stdlib | 2258 ms | 12.6× slower |

## 1. Package operations (`OpenXmlPackage`)

| SDK | nanoxml | Status |
|---|---|---|
| `WordprocessingDocument.Open` / `SpreadsheetDocument.Open` / `PresentationDocument.Open` | `opc.Package.open` + `ooxml.WordDocument/Workbook/Presentation.open` | ✅ |
| `*.Create()` | `ooxml.DocumentBuilder` / `WorkbookBuilder` / `PresentationBuilder` | ✅ |
| `Save()` | `Package.save` (untouched parts copied raw, no re-deflate) | ✅ |
| in-memory flush of pending changes | `Package.flush` | ✅ |
| `Clone()` (CloneableExtensions) | `Package.clone` — independent copy incl. pending mutations | ✅ |
| `ToFlatOpcString()` / `FromFlatOpcDocument()` | `flatopc.toFlatOpc` / `flatopc.fromFlatOpc` (incl. `mso-application` PI, base64 binary parts) | ✅ |
| `PackageProperties` (read) | `Package.coreProperties` | ✅ title/subject/creator/description/lastModifiedBy |
| `PackageProperties` (write) | `Package.setCoreProperties` — updates in place, preserves unmodeled properties, creates part+CT+rel when missing | ✅ |
| `AutoSave` / `OpenSettings.MaxCharactersInPart` | n/a — explicit `save()`; no truncation limits | — by design |
| `ChangeDocumentType` | `Package.setContentTypeOverride` on the main part (the primitive it reduces to) | ◐ primitive |

## 2. Parts & relationships (`OpenXmlPartContainer`)

| SDK | nanoxml | Status |
|---|---|---|
| `GetPartById` / typed part access | `Package.getPart`, `partByRelId`, `partByRelType` | ✅ |
| `AddNewPart<T>` + `FeedData` | `Package.addPart(name, bytes, .{content_type, rel_type, rel_source})` → rel id | ✅ |
| `DeletePart` | `Package.deletePart` — removes part, its .rels, CT override, and all inbound relationships | ✅ |
| `Parts` enumeration | `Package.partNames` | ✅ |
| `AddExternalRelationship` / `DeleteExternalRelationship` | `Package.addExternalRelationship` / `removeRelationship` | ✅ |
| `AddHyperlinkRelationship` | `Package.addHyperlinkRelationship` | ✅ |
| `Relationships` / `GetRelationshipsByType` | `Package.relationships` / `partByRelType` | ✅ |
| relationship id allocation (`rIdN`) | `addRelationship` skips past the existing maximum | ✅ |
| `.rels` re-serialization on save | automatic (`flush`) | ✅ |
| `[Content_Types].xml` maintenance | automatic, sorted/deterministic output | ✅ |
| `DataPart` / media parts | `addPart` with media content type + `RelType.image` etc. | ✅ |
| typed part classes (`MainDocumentPart`, …) | part-name + rel-type conventions (`ooxml` resolves them) | ◐ untyped |

## 3. DOM (`OpenXmlElement`)

| SDK | nanoxml (`dom.Element`) | Status |
|---|---|---|
| `Parent` / `Ancestors()` | `.parent` / `ancestors()` | ✅ |
| `Elements()` / `Elements<T>()` | `elements(null)` / `elements("p")` (local-name filter) | ✅ |
| `Descendants()` / `Descendants<T>()` | `descendants(gpa, filter)` — pre-order, document order | ✅ |
| `NextSibling()` / `PreviousSibling()` | `nextSiblingElement()` / `previousSiblingElement()` | ✅ |
| `AppendChild` / `PrependChild` | `appendChild` / `prependChild` (+ `appendElement` to create) | ✅ |
| `InsertBefore` / `InsertAfter` | `insertBefore` / `insertAfter` | ✅ |
| `RemoveChild` / `ReplaceChild` / `RemoveAllChildren` / `Remove` | same names | ✅ |
| `CloneNode(deep)` | `cloneNode(arena, deep)` — detached, arena-independent | ✅ |
| `InnerText` | `text()` / `innerText()` | ✅ |
| `OuterXml` / `InnerXml` get | `outerXml()` / `innerXml()` | ✅ |
| `InnerXml` set | `setInnerXml(fragment)` (multi-root fragments OK) | ✅ |
| `GetAttribute` / `SetAttribute` | `attr()` / `setAttr()` | ✅ |
| `RemoveAttribute` / `ClearAllAttributes` | `removeAttr()` / `clearAttrs()` | ✅ |
| `LookupNamespace` / `LookupPrefix` | same names, ancestor-walking | ✅ |
| `AddNamespaceDeclaration` | same name | ✅ |
| `LocalName` / `Prefix` | `localName()` / `prefix()` | ✅ |
| 6000 generated strongly-typed classes | one generic `Element`, local-name matching | — by design (see below) |

## 4. Streaming (`OpenXmlReader` / `OpenXmlWriter`)

| SDK | nanoxml | Status |
|---|---|---|
| `OpenXmlPartReader` (`Read`, `Skip`, `GetText`, attributes) | `xml.Parser` zero-copy SIMD pull parser (start/end/text/cdata/comment/pi events, `skipElement`) | ✅ |
| `OpenXmlPartWriter` (`WriteStartDocument/StartElement/String/EndElement`) | `xml.Writer` (`writeDeclaration`, `startElement`, `attribute`, `text`, `raw`, `textElement`, `endElement`, `end`) — auto-escaping, self-closing collapse, balance enforcement | ✅ |

## 5. Validation (`OpenXmlValidator`)

| SDK | nanoxml (`validate.validatePackage`) | Status |
|---|---|---|
| `Validate(package)` → `ValidationErrorInfo` list | `Result.diagnostics` (severity, part, message) | ✅ |
| package structure | `[Content_Types].xml` present, every part typed, officeDocument rel exists | ✅ |
| XML well-formedness of every part | ✅ (every `+xml` part parsed) | ✅ |
| relationship integrity | targets resolve & exist, ids unique per source | ✅ |
| root element ↔ content-type agreement | 13 well-known part types pinned | ✅ |
| semantic reference checks | `r:id` / `r:embed` / `r:link` must resolve in the owning part's rels | ✅ |
| full ECMA-376 particle/schema validation | not implemented — needs the schema corpus the SDK generates from | ✗ out of scope |

## 6. Markup compatibility (`MarkupCompatibilityProcessSettings`)

| SDK | nanoxml (`mc.process`) | Status |
|---|---|---|
| `mc:AlternateContent` → first satisfiable `Choice` else `Fallback` | ✅ recursive, splice-in-place | ✅ |
| `mc:Ignorable` (scope-aware, prefix-based) | ✅ elements + attributes, understood namespaces kept | ✅ |
| `mc:ProcessContent` (incl. `pfx:*`) | ✅ children spliced through | ✅ |
| `mc:MustUnderstand` | error `MustUnderstandFailed` (SDK throws) | ✅ |
| read-side `AlternateContent` in text extraction | `ooxml.extractTextXml` Choice/Fallback handling | ✅ |

## 7. Container (`System.IO.Packaging` zip layer)

| SDK | nanoxml (`zip`) | Status |
|---|---|---|
| read store/deflate, data descriptors, archive comments | `zip.Archive` | ✅ |
| zip64 read (extra fields + EOCD64) | ✅ | ✅ |
| zip64 write (sizes/offsets/count overflow → automatic; `force_zip64` for testing) | `zip.Writer` | ✅ |
| raw-copy round-trip (no recompression of untouched entries) | `addRaw` | ✅ |
| CRC verification | `ExtractOptions.verify_crc` | ✅ |
| encrypted packages | rejected cleanly (`error.Encrypted`) — the SDK does not support them either (they are CFB containers, not zips) | — parity via shared exclusion |

## 8. Typed documents

| SDK | nanoxml (`ooxml`) | Status |
|---|---|---|
| `WordprocessingDocument` text model | `WordDocument` (tracked deletions excluded, field codes excluded, AlternateContent handled) | ✅ |
| `SpreadsheetDocument` cell model | `Workbook` (shared strings incl. rich runs, all cell types, gap preservation, CSV) | ✅ |
| `PresentationDocument` slides | `Presentation` (slide order via sldIdLst, text) | ✅ |
| document kind detection (incl. macro-enabled, strict) | `ooxml.detect` | ✅ |
| `Create()` equivalents | the three builders (typed cells, shared-string dedup, ordered slides, core properties) | ✅ |

## Deliberate non-goals

- **The ~6000 generated element classes.** They are codegen over the ECMA
  schema; the shape underneath is exactly `dom.Element`. nanoxml gives you
  the shape, local-name matching, and the full traversal/mutation surface —
  in ~5k lines instead of ~500k generated ones. Typed wrappers can be
  layered on top without touching the core.
- **Full schema (particle) validation.** Requires shipping the ECMA-376
  schema corpus. The validator covers the structural and referential layers
  the SDK checks first.
- **Encrypted/IRM packages.** Same exclusion as the SDK itself.

## Performance (same workloads, see README)

ReleaseFast, Apple Silicon, single thread: 200k-row xlsx (46 MiB XML) →
unzip 61 ms / +parse 151 ms / +typed CSV 179 ms ≈ **12.6× Python stdlib**.
A real 12-page docx parses end-to-end in 0.19 ms.
