//! Flat OPC — the single-XML package form (`FlatOpcExtensions` in the SDK:
//! `ToFlatOpcString` / `FromFlatOpcDocument`).
//!
//! A Flat OPC document is one XML file holding every part of a package:
//!
//!   <pkg:package xmlns:pkg="http://schemas.microsoft.com/office/2006/xmlPackage">
//!     <pkg:part pkg:name="/word/document.xml" pkg:contentType="...">
//!       <pkg:xmlData>…the part's root element…</pkg:xmlData>
//!     </pkg:part>
//!     <pkg:part pkg:name="/media/img.png" pkg:contentType="image/png">
//!       <pkg:binaryData>BASE64…</pkg:binaryData>
//!     </pkg:part>
//!   </pkg:package>
//!
//! [Content_Types].xml is not emitted as a part; each part carries its
//! content type inline, and `fromFlatOpc` reconstructs the table.

const std = @import("std");
const dom = @import("dom.zig");
const opc = @import("opc.zig");
const xml = @import("xml.zig");
const zip = @import("zip.zig");

pub const pkg_ns = "http://schemas.microsoft.com/office/2006/xmlPackage";

pub const Error = opc.Error || error{ MalformedFlatOpc, InvalidBase64 };

pub const ToFlatOpcOptions = struct {
    /// Emits `<?mso-application progid="…"?>` so Windows shell/Office
    /// recognize the file (SDK uses e.g. "Word.Document").
    progid: ?[]const u8 = null,
};

/// SDK `ToFlatOpcString`: serialize the whole package (including pending
/// mutations) into one XML document appended to `out`.
pub fn toFlatOpc(
    pkg: *opc.Package,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    opts: ToFlatOpcOptions,
) Error!void {
    try pkg.flush();

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    try out.appendSlice(gpa, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
    if (opts.progid) |id| {
        try out.appendSlice(gpa, "<?mso-application progid=\"");
        try xml.escapeAppend(out, gpa, id, .attr);
        try out.appendSlice(gpa, "\"?>");
    }
    try out.appendSlice(gpa, "<pkg:package xmlns:pkg=\"" ++ pkg_ns ++ "\">");

    const names = try pkg.partNames(arena);
    for (names) |name| {
        if (std.mem.eql(u8, name, "[Content_Types].xml")) continue;
        const bytes = try pkg.getPart(name);
        const ct = pkg.contentTypeOf(name) orelse "";

        try out.appendSlice(gpa, "<pkg:part pkg:name=\"/");
        try xml.escapeAppend(out, gpa, name, .attr);
        try out.appendSlice(gpa, "\" pkg:contentType=\"");
        try xml.escapeAppend(out, gpa, ct, .attr);
        try out.appendSlice(gpa, "\">");

        if (isXmlContentType(ct)) {
            try out.appendSlice(gpa, "<pkg:xmlData>");
            try out.appendSlice(gpa, stripDeclaration(bytes));
            try out.appendSlice(gpa, "</pkg:xmlData>");
        } else {
            try out.appendSlice(gpa, "<pkg:binaryData>");
            const enc = std.base64.standard.Encoder;
            const start = out.items.len;
            try out.resize(gpa, start + enc.calcSize(bytes.len));
            _ = enc.encode(out.items[start..], bytes);
            try out.appendSlice(gpa, "</pkg:binaryData>");
        }
        try out.appendSlice(gpa, "</pkg:part>");
    }
    try out.appendSlice(gpa, "</pkg:package>");
}

/// SDK `FromFlatOpcDocument`: parse a Flat OPC document back into standard
/// OPC zip bytes (open them with `opc.Package.open`). Caller owns the
/// returned bytes.
pub fn fromFlatOpc(gpa: std.mem.Allocator, flat: []const u8) Error![]u8 {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = dom.parse(arena, flat) catch return Error.MalformedFlatOpc;
    if (!std.mem.eql(u8, root.localName(), "package")) return Error.MalformedFlatOpc;

    const Part = struct { name: []const u8, ct: []const u8, bytes: []const u8 };
    var parts: std.ArrayList(Part) = .empty;

    var it = root.elements("part");
    while (it.next()) |part_el| {
        const raw_name = part_el.attr("name") orelse return Error.MalformedFlatOpc;
        const name = std.mem.trimStart(u8, raw_name, "/");
        const ct = part_el.attr("contentType") orelse "";

        var bytes: []const u8 = undefined;
        if (part_el.child("xmlData")) |xd| {
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(arena, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
            try xd.innerXml(arena, &buf);
            bytes = try buf.toOwnedSlice(arena);
        } else if (part_el.child("binaryData")) |bd| {
            var b64: std.ArrayList(u8) = .empty;
            try bd.text(arena, &b64);
            // Producers wrap base64 in whitespace; strip before decoding.
            var compact = try arena.alloc(u8, b64.items.len);
            var n: usize = 0;
            for (b64.items) |c| {
                if (!std.ascii.isWhitespace(c)) {
                    compact[n] = c;
                    n += 1;
                }
            }
            const dec = std.base64.standard.Decoder;
            const size = dec.calcSizeForSlice(compact[0..n]) catch return Error.InvalidBase64;
            const decoded = try arena.alloc(u8, size);
            dec.decode(decoded, compact[0..n]) catch return Error.InvalidBase64;
            bytes = decoded;
        } else {
            // Empty part.
            bytes = "";
        }
        try parts.append(arena, .{ .name = name, .ct = ct, .bytes = bytes });
    }
    if (parts.items.len == 0) return Error.MalformedFlatOpc;

    // Reconstruct [Content_Types].xml: conventional defaults for rels/xml,
    // an Override for anything the defaults don't explain.
    const rels_ct = "application/vnd.openxmlformats-package.relationships+xml";
    var ct_out: std.ArrayList(u8) = .empty;
    var w = xml.Writer.init(arena, &ct_out);
    defer w.deinit();
    try w.writeDeclaration();
    try w.startElement("Types");
    w.attribute("xmlns", "http://schemas.openxmlformats.org/package/2006/content-types") catch return Error.MalformedFlatOpc;
    try w.startElement("Default");
    w.attribute("Extension", "rels") catch unreachable;
    w.attribute("ContentType", rels_ct) catch unreachable;
    w.endElement() catch unreachable;
    try w.startElement("Default");
    w.attribute("Extension", "xml") catch unreachable;
    w.attribute("ContentType", "application/xml") catch unreachable;
    w.endElement() catch unreachable;
    for (parts.items) |p| {
        if (p.ct.len == 0) continue;
        const ext = extensionOf(p.name);
        const covered = (std.ascii.eqlIgnoreCase(ext, "rels") and std.mem.eql(u8, p.ct, rels_ct)) or
            (std.ascii.eqlIgnoreCase(ext, "xml") and std.mem.eql(u8, p.ct, "application/xml"));
        if (covered) continue;
        try w.startElement("Override");
        const abs = try std.mem.concat(arena, u8, &.{ "/", p.name });
        w.attribute("PartName", abs) catch unreachable;
        w.attribute("ContentType", p.ct) catch unreachable;
        w.endElement() catch unreachable;
    }
    w.endElement() catch unreachable;
    w.end() catch unreachable;

    var zw = zip.Writer{};
    defer zw.deinit(gpa);
    try zw.addFile(gpa, "[Content_Types].xml", ct_out.items, .deflate);
    for (parts.items) |p| {
        try zw.addFile(gpa, p.name, p.bytes, .deflate);
    }
    return zw.finish(gpa);
}

fn isXmlContentType(ct: []const u8) bool {
    return std.mem.endsWith(u8, ct, "+xml") or
        std.mem.eql(u8, ct, "application/xml") or
        std.mem.eql(u8, ct, "text/xml");
}

fn stripDeclaration(bytes: []const u8) []const u8 {
    if (std.mem.startsWith(u8, bytes, "<?xml")) {
        if (std.mem.indexOf(u8, bytes, "?>")) |end| {
            return std.mem.trimStart(u8, bytes[end + 2 ..], " \t\r\n");
        }
    }
    return bytes;
}

fn extensionOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    return name[dot + 1 ..];
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const ct_xml =
    \\<?xml version="1.0"?>
    \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    \\<Default Extension="xml" ContentType="application/xml"/>
    \\<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    \\<Default Extension="png" ContentType="image/png"/>
    \\<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    \\</Types>
;

const root_rels =
    \\<?xml version="1.0"?>
    \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \\<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    \\</Relationships>
;

const doc_body =
    \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    \\<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>flat &amp; round</w:t></w:r></w:p></w:body></w:document>
;

fn flatTestPackage(gpa: std.mem.Allocator) ![]u8 {
    return zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = ct_xml },
        .{ .name = "_rels/.rels", .data = root_rels },
        .{ .name = "word/document.xml", .data = doc_body },
        .{ .name = "media/blob.png", .data = "\x89PNG\x00\x01\x02binary\xffdata" },
    });
}

test "flat opc round-trip preserves xml parts, binary parts, and rels" {
    const gpa = testing.allocator;
    const data = try flatTestPackage(gpa);
    defer gpa.free(data);
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();

    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(gpa);
    try toFlatOpc(&pkg, gpa, &flat, .{ .progid = "Word.Document" });

    // The flat form is a single well-formed XML document.
    try testing.expect(std.mem.indexOf(u8, flat.items, "mso-application progid=\"Word.Document\"") != null);
    try testing.expect(std.mem.indexOf(u8, flat.items, "pkg:name=\"/word/document.xml\"") != null);
    try testing.expect(std.mem.indexOf(u8, flat.items, "<pkg:binaryData>") != null);
    // No nested XML declarations survive inside part data.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, flat.items, "<?xml "));

    const rebuilt = try fromFlatOpc(gpa, flat.items);
    defer gpa.free(rebuilt);
    var pkg2 = try opc.Package.open(gpa, rebuilt);
    defer pkg2.deinit();

    // Binary part: byte-exact.
    try testing.expectEqualSlices(u8, "\x89PNG\x00\x01\x02binary\xffdata", try pkg2.getPart("media/blob.png"));
    // Content types preserved.
    try testing.expectEqualStrings(
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
        pkg2.contentTypeOf("word/document.xml").?,
    );
    try testing.expectEqualStrings("image/png", pkg2.contentTypeOf("media/blob.png").?);
    // Relationships still resolve.
    const main_part = (try pkg2.partByRelType(null, opc.RelType.office_document)).?;
    try testing.expectEqualStrings("word/document.xml", main_part);
    // Document text survives (entity decoded the same way).
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const doc = try dom.parse(arena_inst.allocator(), try pkg2.getPart("word/document.xml"));
    const t = doc.child("body").?.child("p").?.child("r").?.child("t").?;
    const text = try t.innerText(gpa);
    defer gpa.free(text);
    try testing.expectEqualStrings("flat & round", text);
}

test "toFlatOpc reflects pending in-memory mutations" {
    const gpa = testing.allocator;
    const data = try flatTestPackage(gpa);
    defer gpa.free(data);
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();

    _ = try pkg.addPart("word/styles.xml", "<w:styles/>", .{
        .content_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml",
        .rel_type = opc.RelType.styles,
        .rel_source = "word/document.xml",
    });

    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(gpa);
    try toFlatOpc(&pkg, gpa, &flat, .{});

    const rebuilt = try fromFlatOpc(gpa, flat.items);
    defer gpa.free(rebuilt);
    var pkg2 = try opc.Package.open(gpa, rebuilt);
    defer pkg2.deinit();

    const styles = (try pkg2.partByRelType("word/document.xml", opc.RelType.styles)).?;
    try testing.expectEqualStrings("word/styles.xml", styles);
    try testing.expectEqualStrings("<w:styles/>", stripDeclaration(try pkg2.getPart("word/styles.xml")));
}

test "fromFlatOpc rejects non-package roots and bad base64" {
    const gpa = testing.allocator;
    try testing.expectError(Error.MalformedFlatOpc, fromFlatOpc(gpa, "<not-a-package/>"));
    try testing.expectError(Error.MalformedFlatOpc, fromFlatOpc(gpa, "garbage"));

    const bad_b64 =
        \\<pkg:package xmlns:pkg="http://schemas.microsoft.com/office/2006/xmlPackage">
        \\<pkg:part pkg:name="/x.bin" pkg:contentType="application/octet-stream"><pkg:binaryData>!!!not-base64!!!</pkg:binaryData></pkg:part>
        \\</pkg:package>
    ;
    try testing.expectError(Error.InvalidBase64, fromFlatOpc(gpa, bad_b64));
}
