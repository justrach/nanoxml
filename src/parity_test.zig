//! Parity spec — written FIRST, before the implementation exists.
//!
//! Each test pins a behavior Open-XML-SDK provides that nanoxml must match
//! to claim read+write parity on the core workflows:
//!
//!   WordprocessingDocument.Create / SpreadsheetDocument.Create /
//!   PresentationDocument.Create        -> ooxml.*Builder
//!   Package round-trip (open->edit->save), untouched parts preserved
//!                                       -> opc.Package.setPart / .save
//!   OpenXmlElement tree (navigate, mutate, serialize)
//!                                       -> dom.Element
//!   PackageProperties (docProps/core)   -> opc.coreProperties
//!   System.IO.Packaging zip writing     -> zip.Writer
//!
//! Red = compile errors / failures here. Green = parity reached.

const std = @import("std");
const zip = @import("zip.zig");
const xml = @import("xml.zig");
const dom = @import("dom.zig");
const opc = @import("opc.zig");
const ooxml = @import("ooxml.zig");

const testing = std.testing;

// ── 1. Creation: WordprocessingDocument.Create equivalent ─────────────────

test "parity: create docx from scratch, reopen, extract identical text" {
    const gpa = testing.allocator;

    var b = ooxml.DocumentBuilder.init(gpa);
    defer b.deinit();
    try b.addParagraph("Hello from nanoxml");
    try b.addParagraph("Entities survive: < & > \" '");
    try b.addParagraph(""); // empty paragraph
    const bytes = try b.save(gpa);
    defer gpa.free(bytes);

    var pkg = try opc.Package.open(gpa, bytes);
    defer pkg.deinit();
    const d = try ooxml.detect(&pkg);
    try testing.expectEqual(ooxml.Kind.docx, d.kind);

    var doc = try ooxml.WordDocument.open(&pkg);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try doc.text(gpa, &out);
    try testing.expectEqualStrings(
        "Hello from nanoxml\nEntities survive: < & > \" '\n\n",
        out.items,
    );
}

// ── 2. Creation: SpreadsheetDocument.Create equivalent ────────────────────

test "parity: create xlsx with typed cells, shared strings dedup, reopen" {
    const gpa = testing.allocator;

    var b = ooxml.WorkbookBuilder.init(gpa);
    defer b.deinit();
    const s0 = try b.addSheet("Data");
    try b.setCell(s0, 0, 0, .{ .string = "dup" });
    try b.setCell(s0, 0, 1, .{ .number = 42 });
    try b.setCell(s0, 0, 2, .{ .boolean = true });
    try b.setCell(s0, 1, 0, .{ .string = "dup" });
    try b.setCell(s0, 1, 1, .{ .number = 0.125 });
    try b.setCell(s0, 1, 3, .{ .string = "comma, \"quoted\"" }); // sparse: skips col 2
    const s1 = try b.addSheet("Second");
    try b.setCell(s1, 0, 0, .{ .string = "other" });
    const bytes = try b.save(gpa);
    defer gpa.free(bytes);

    var pkg = try opc.Package.open(gpa, bytes);
    defer pkg.deinit();
    var wb = try ooxml.Workbook.open(&pkg);

    // Dedup: "dup" stored once -> 3 unique shared strings.
    try testing.expectEqual(@as(usize, 3), wb.shared.len);
    try testing.expectEqual(@as(usize, 2), wb.sheets.len);
    try testing.expectEqualStrings("Data", wb.sheets[0].name);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try wb.sheetToCsv(gpa, 0, &out);
    try testing.expectEqualStrings(
        "dup,42,TRUE\ndup,0.125,,\"comma, \"\"quoted\"\"\"\n",
        out.items,
    );

    out.clearRetainingCapacity();
    try wb.sheetToCsv(gpa, 1, &out);
    try testing.expectEqualStrings("other\n", out.items);
}

// ── 3. Creation: PresentationDocument.Create equivalent ───────────────────

test "parity: create pptx with ordered slides, reopen" {
    const gpa = testing.allocator;

    var b = ooxml.PresentationBuilder.init(gpa);
    defer b.deinit();
    try b.addSlide(&.{ "Title one", "Bullet A" });
    try b.addSlide(&.{"Title two"});
    const bytes = try b.save(gpa);
    defer gpa.free(bytes);

    var pkg = try opc.Package.open(gpa, bytes);
    defer pkg.deinit();
    var pres = try ooxml.Presentation.open(&pkg);
    try testing.expectEqual(@as(usize, 2), pres.slides.len);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try pres.slideText(gpa, 0, &out);
    try testing.expectEqualStrings("Title one\nBullet A\n", out.items);
    out.clearRetainingCapacity();
    try pres.slideText(gpa, 1, &out);
    try testing.expectEqualStrings("Title two\n", out.items);
}

// ── 4. Round-trip: open -> edit one part -> save, rest preserved ──────────

test "parity: package round-trip preserves untouched parts" {
    const gpa = testing.allocator;

    const doc_xml =
        "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" ++
        "<w:body><w:p><w:r><w:t>before</w:t></w:r></w:p></w:body></w:document>";
    const binary_blob = "\x89PNG\x00\x01\x02\x03 not really a png \xFF\xFE";
    const src = try zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = "<Types xmlns=\"ct\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"" ++ ooxml.ct_docx_main ++ "\"/></Types>" },
        .{ .name = "_rels/.rels", .data = "<Relationships xmlns=\"r\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>" },
        .{ .name = "word/document.xml", .data = doc_xml },
        .{ .name = "media/blob.bin", .data = binary_blob },
    });
    defer gpa.free(src);

    var pkg = try opc.Package.open(gpa, src);
    defer pkg.deinit();

    // Edit document.xml through the DOM (OpenXmlElement-style).
    const arena = pkg.arena.allocator();
    const root = try dom.parse(arena, try pkg.getPart("word/document.xml"));
    const t = root.child("body").?.child("p").?.child("r").?.child("t").?;
    try t.setText(arena, "after & improved");
    var ser: std.ArrayList(u8) = .empty;
    defer ser.deinit(gpa);
    try dom.serialize(root, gpa, &ser, .{});
    try pkg.setPart("word/document.xml", ser.items);

    const saved = try pkg.save(gpa);
    defer gpa.free(saved);

    var pkg2 = try opc.Package.open(gpa, saved);
    defer pkg2.deinit();

    // Edited part reflects the change end-to-end.
    var doc = try ooxml.WordDocument.open(&pkg2);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try doc.text(gpa, &out);
    try testing.expectEqualStrings("after & improved\n", out.items);

    // Untouched binary part byte-identical; content types intact.
    try testing.expectEqualStrings(binary_blob, try pkg2.getPart("media/blob.bin"));
    try testing.expectEqualStrings(
        ooxml.ct_docx_main,
        pkg2.contentTypeOf("word/document.xml").?,
    );
}

test "parity: setPart can add a brand-new part" {
    const gpa = testing.allocator;
    const src = try zip.writeStoredZip(gpa, &.{
        .{ .name = "a.xml", .data = "<a/>" },
    });
    defer gpa.free(src);

    var pkg = try opc.Package.open(gpa, src);
    defer pkg.deinit();
    try pkg.setPart("dir/new.xml", "<fresh/>");

    const saved = try pkg.save(gpa);
    defer gpa.free(saved);

    var pkg2 = try opc.Package.open(gpa, saved);
    defer pkg2.deinit();
    try testing.expectEqualStrings("<a/>", try pkg2.getPart("a.xml"));
    try testing.expectEqualStrings("<fresh/>", try pkg2.getPart("dir/new.xml"));
}

// ── 5. DOM: OpenXmlElement equivalent ──────────────────────────────────────

test "parity: dom parse, navigate, mutate, serialize, reparse" {
    const gpa = testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const src =
        "<?xml version=\"1.0\"?><w:doc xmlns:w=\"ns\" version=\"1\">" ++
        "<!-- ignored -->" ++
        "<w:p id=\"p1\"><w:t>a &amp; b</w:t><w:b/></w:p>" ++
        "<w:p id=\"p2\"><w:t><![CDATA[raw <stuff>]]></w:t></w:p>" ++
        "</w:doc>";

    const root = try dom.parse(arena, src);
    try testing.expectEqualStrings("w:doc", root.name);
    try testing.expectEqualStrings("1", root.attr("version").?);

    // Navigation by local name; attr values come back decoded.
    const p1 = root.child("p").?;
    try testing.expectEqualStrings("p1", p1.attr("id").?);
    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(gpa);
    try p1.text(gpa, &text_buf);
    try testing.expectEqualStrings("a & b", text_buf.items); // decoded

    // CDATA folded into text.
    text_buf.clearRetainingCapacity();
    const p2 = root.childAt("p", 1).?;
    try p2.text(gpa, &text_buf);
    try testing.expectEqualStrings("raw <stuff>", text_buf.items);

    // Mutate: attribute + text + new child element.
    try p1.setAttr(arena, "id", "p1-edited");
    try p1.child("t").?.setText(arena, "x < y & z");
    const extra = try root.appendElement(arena, "w:new");
    try extra.setAttr(arena, "k", "v\"q");

    var ser: std.ArrayList(u8) = .empty;
    defer ser.deinit(gpa);
    try dom.serialize(root, gpa, &ser, .{ .declaration = false });

    // Escaping is correct in the serialized output.
    try testing.expect(std.mem.indexOf(u8, ser.items, "x &lt; y &amp; z") != null);
    try testing.expect(std.mem.indexOf(u8, ser.items, "id=\"p1-edited\"") != null);
    try testing.expect(std.mem.indexOf(u8, ser.items, "k=\"v&quot;q\"") != null);

    // Reparse: structure and decoded values survive the round-trip.
    const root2 = try dom.parse(arena, ser.items);
    try testing.expectEqualStrings("p1-edited", root2.child("p").?.attr("id").?);
    text_buf.clearRetainingCapacity();
    try root2.child("p").?.text(gpa, &text_buf);
    try testing.expectEqualStrings("x < y & z", text_buf.items);
    try testing.expect(root2.child("new") != null);
    try testing.expectEqualStrings("v\"q", root2.child("new").?.attr("k").?);
}

// ── 6. ZIP writer ──────────────────────────────────────────────────────────

test "parity: zip writer deflates, auto-stores incompressible, crc-verifies" {
    const gpa = testing.allocator;

    const compressible = "the same sentence repeated. " ** 200;
    const incompressible = "\x01\x7F\x3B\xC8\x99\x42\xEE\x10\xA5\x6D"; // short: deflate can't win

    var w = zip.Writer{};
    defer w.deinit(gpa);
    try w.addFile(gpa, "big.xml", compressible, .deflate);
    try w.addFile(gpa, "tiny.bin", incompressible, .deflate);
    try w.addFile(gpa, "stored.txt", "keep me raw", .store);
    const bytes = try w.finish(gpa);
    defer gpa.free(bytes);

    var ar = try zip.Archive.open(gpa, bytes);
    defer ar.deinit(gpa);

    const big = ar.find("big.xml").?;
    try testing.expectEqual(@as(u16, 8), big.method);
    try testing.expect(big.compressed_size < big.uncompressed_size);
    const got = try ar.extractAlloc(gpa, big, .{ .verify_crc = true });
    defer gpa.free(got);
    try testing.expectEqualStrings(compressible, got);

    // Deflate would grow this entry; writer must fall back to store.
    const tiny = ar.find("tiny.bin").?;
    try testing.expectEqual(@as(u16, 0), tiny.method);
    const got2 = try ar.extractAlloc(gpa, tiny, .{ .verify_crc = true });
    defer gpa.free(got2);
    try testing.expectEqualStrings(incompressible, got2);

    try testing.expectEqual(@as(u16, 0), ar.find("stored.txt").?.method);
}

test "parity: save raw-copies deflated entries without recompressing" {
    const gpa = testing.allocator;

    // Build a deflated source package with the writer...
    var w = zip.Writer{};
    defer w.deinit(gpa);
    const payload = "<x>" ++ ("deflate me, repeatedly! " ** 100) ++ "</x>";
    try w.addFile(gpa, "part.xml", payload, .deflate);
    const src = try w.finish(gpa);
    defer gpa.free(src);

    // ...open and save untouched: contents must survive, method stays deflate.
    var pkg = try opc.Package.open(gpa, src);
    defer pkg.deinit();
    const saved = try pkg.save(gpa);
    defer gpa.free(saved);

    var pkg2 = try opc.Package.open(gpa, saved);
    defer pkg2.deinit();
    try testing.expectEqualStrings(payload, try pkg2.getPart("part.xml"));
    try testing.expectEqual(@as(u16, 8), pkg2.archive.find("part.xml").?.method);
}

// ── 7. XML escaping is the exact inverse of decoding ──────────────────────

test "parity: escapeAppend/decodeAppend round-trip" {
    const gpa = testing.allocator;
    const nasty = "a<b>&c\"d'e\n\twith unicode \xE6\xBC\xA2 and emoji \xF0\x9F\x98\x80";

    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(gpa);
    try xml.escapeAppend(&escaped, gpa, nasty, .text);
    try testing.expect(std.mem.indexOfScalar(u8, escaped.items, '<') == null);

    var back: std.ArrayList(u8) = .empty;
    defer back.deinit(gpa);
    try xml.decodeAppend(&back, gpa, escaped.items);
    try testing.expectEqualStrings(nasty, back.items);

    // Attribute mode also escapes quotes.
    escaped.clearRetainingCapacity();
    try xml.escapeAppend(&escaped, gpa, "he said \"hi\"", .attr);
    try testing.expect(std.mem.indexOfScalar(u8, escaped.items, '"') == null);
    back.clearRetainingCapacity();
    try xml.decodeAppend(&back, gpa, escaped.items);
    try testing.expectEqualStrings("he said \"hi\"", back.items);
}

// ── 8. PackageProperties (docProps/core.xml) ───────────────────────────────

test "parity: core properties readable from packages" {
    const gpa = testing.allocator;
    const core =
        "<?xml version=\"1.0\"?>" ++
        "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" " ++
        "xmlns:dc=\"http://purl.org/dc/elements/1.1/\">" ++
        "<dc:title>My Report</dc:title>" ++
        "<dc:creator>rach &amp; claude</dc:creator>" ++
        "<cp:lastModifiedBy>someone</cp:lastModifiedBy>" ++
        "</cp:coreProperties>";
    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "docProps/core.xml", .data = core },
        .{ .name = "word/document.xml", .data = "<w:document/>" },
    });
    defer gpa.free(data);

    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    const props = try pkg.coreProperties();
    try testing.expectEqualStrings("My Report", props.title.?);
    try testing.expectEqualStrings("rach & claude", props.creator.?);
    try testing.expectEqualStrings("someone", props.last_modified_by.?);
    try testing.expect(props.subject == null);
}

test "parity: builders stamp core properties" {
    const gpa = testing.allocator;

    var b = ooxml.DocumentBuilder.init(gpa);
    defer b.deinit();
    b.title = "Built by tests";
    b.creator = "nanoxml";
    try b.addParagraph("body");
    const bytes = try b.save(gpa);
    defer gpa.free(bytes);

    var pkg = try opc.Package.open(gpa, bytes);
    defer pkg.deinit();
    const props = try pkg.coreProperties();
    try testing.expectEqualStrings("Built by tests", props.title.?);
    try testing.expectEqualStrings("nanoxml", props.creator.?);
}
