//! Typed OOXML layer — the read-path equivalent of Open-XML-SDK's
//! `WordprocessingDocument` / `SpreadsheetDocument` / `PresentationDocument`.
//!
//! Open-XML-SDK ships ~6000 generated element classes; in practice the vast
//! majority of read workloads touch a handful of them (w:t, w:p, sst, row,
//! c, v, a:t). This layer implements those hot paths directly over the pull
//! parser, matching on *local* element names so producer prefix choices
//! don't matter. Relationship-id attributes (`r:id`) are recognized as
//! "prefixed attr with local name `id`" to survive prefix renaming too.
//!
//! All returned strings live in the package arena: free the Package, free
//! everything.

const std = @import("std");
const opc = @import("opc.zig");
const xml = @import("xml.zig");

pub const Error = opc.Error || error{ NotOfficeDocument, NoSuchSheet };

pub const Kind = enum { docx, xlsx, pptx, unknown };

pub const ct_docx_main = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml";
pub const ct_xlsx_main = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml";
pub const ct_pptx_main = "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml";

/// Locate the main part via the officeDocument relationship and classify
/// the package — the `WordprocessingDocument.Open` entry decision.
pub fn detect(pkg: *opc.Package) Error!struct { kind: Kind, main_part: ?[]const u8 } {
    const main = try pkg.partByRelType(null, opc.RelType.office_document) orelse {
        // Fall back to conventional names (rels missing/odd producer).
        if (pkg.hasPart("word/document.xml"))
            return .{ .kind = .docx, .main_part = "word/document.xml" };
        if (pkg.hasPart("xl/workbook.xml"))
            return .{ .kind = .xlsx, .main_part = "xl/workbook.xml" };
        if (pkg.hasPart("ppt/presentation.xml"))
            return .{ .kind = .pptx, .main_part = "ppt/presentation.xml" };
        return .{ .kind = .unknown, .main_part = null };
    };
    const content_type = pkg.contentTypeOf(main) orelse "";
    // Transitional OOXML uses *processingml/spreadsheetml/presentationml;
    // macro-enabled variants (.docm/.xlsm/.pptm) use vnd.ms-word/excel/
    // powerpoint content types instead — Open-XML-SDK opens both.
    if (std.mem.indexOf(u8, content_type, "wordprocessingml") != null or
        std.mem.indexOf(u8, content_type, "ms-word") != null)
        return .{ .kind = .docx, .main_part = main };
    if (std.mem.indexOf(u8, content_type, "spreadsheetml") != null or
        std.mem.indexOf(u8, content_type, "ms-excel") != null)
        return .{ .kind = .xlsx, .main_part = main };
    if (std.mem.indexOf(u8, content_type, "presentationml") != null or
        std.mem.indexOf(u8, content_type, "ms-powerpoint") != null)
        return .{ .kind = .pptx, .main_part = main };
    // Unrecognized content type: classify by the main part's location.
    if (std.mem.startsWith(u8, main, "word/"))
        return .{ .kind = .docx, .main_part = main };
    if (std.mem.startsWith(u8, main, "xl/"))
        return .{ .kind = .xlsx, .main_part = main };
    if (std.mem.startsWith(u8, main, "ppt/"))
        return .{ .kind = .pptx, .main_part = main };
    return .{ .kind = .unknown, .main_part = main };
}

/// The prefixed `r:id`-style attribute: local name "id" *with* a prefix —
/// distinguishes `r:id="rId2"` from plain `id="256"` on the same element.
fn relIdOf(st: *const xml.StartTag) ?[]const u8 {
    var it = st.attrs();
    while (it.next()) |a| {
        if (std.mem.endsWith(u8, a.name, ":id")) return a.value;
    }
    return null;
}

// ── Text extraction (docx body / pptx slides / any *ML markup) ────────────

/// Walk markup and collect human text: contents of any `t` element, with
/// `tab`→\t, `br`/`cr`→\n, and a newline at every paragraph (`p`) end.
pub fn extractTextXml(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    out: *std.ArrayList(u8),
) Error!void {
    try out.ensureUnusedCapacity(gpa, bytes.len / 4);
    var p = xml.Parser.init(bytes);
    var in_t: bool = false;
    while (true) {
        const ev = p.next() catch return Error.MalformedXml;
        switch (ev) {
            .start => |st| {
                const local = xml.localName(st.name);
                if (std.mem.eql(u8, local, "t")) {
                    in_t = !st.self_closing;
                } else if (std.mem.eql(u8, local, "tab")) {
                    try out.append(gpa, '\t');
                } else if (std.mem.eql(u8, local, "br") or std.mem.eql(u8, local, "cr")) {
                    try out.append(gpa, '\n');
                } else if (std.mem.eql(u8, local, "Fallback")) {
                    // mc:AlternateContent ships Choice + Fallback renderings
                    // of the same content; extract the Choice only, like
                    // Open-XML-SDK consumers do, or the text appears twice.
                    if (!st.self_closing)
                        p.skipElement() catch return Error.MalformedXml;
                }
            },
            .end => |name| {
                const local = xml.localName(name);
                if (std.mem.eql(u8, local, "t")) {
                    in_t = false;
                } else if (std.mem.eql(u8, local, "p")) {
                    try out.append(gpa, '\n');
                }
            },
            .text => |raw| if (in_t) try xml.decodeAppend(out, gpa, raw),
            .cdata => |raw| if (in_t) try out.appendSlice(gpa, raw),
            .eof => return,
            else => {},
        }
    }
}

// ── WordprocessingDocument ────────────────────────────────────────────────

pub const WordDocument = struct {
    pkg: *opc.Package,
    main_part: []const u8,

    pub fn open(pkg: *opc.Package) Error!WordDocument {
        const d = try detect(pkg);
        if (d.kind != .docx or d.main_part == null) return Error.NotOfficeDocument;
        return .{ .pkg = pkg, .main_part = d.main_part.? };
    }

    pub fn text(self: *WordDocument, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
        const bytes = try self.pkg.getPart(self.main_part);
        try extractTextXml(gpa, bytes, out);
    }
};

// ── SpreadsheetDocument ───────────────────────────────────────────────────

pub const Sheet = struct {
    name: []const u8,
    /// Resolved part name; null when the rel is missing (defensive).
    part: ?[]const u8,
};

pub const Workbook = struct {
    pkg: *opc.Package,
    main_part: []const u8,
    sheets: []Sheet,
    shared: []const []const u8,

    pub fn open(pkg: *opc.Package) Error!Workbook {
        const d = try detect(pkg);
        if (d.kind != .xlsx or d.main_part == null) return Error.NotOfficeDocument;
        const main_part = d.main_part.?;
        const arena = pkg.arena.allocator();

        // Sheet list in workbook (tab) order.
        var sheets: std.ArrayList(Sheet) = .empty;
        {
            const bytes = try pkg.getPart(main_part);
            var p = xml.Parser.init(bytes);
            while (true) {
                const ev = p.next() catch return Error.MalformedXml;
                switch (ev) {
                    .start => |st| {
                        if (std.mem.eql(u8, xml.localName(st.name), "sheet")) {
                            const name_raw = st.attr("name") orelse "";
                            var name_list: std.ArrayList(u8) = .empty;
                            try xml.decodeAppend(&name_list, arena, name_raw);
                            const part = if (relIdOf(&st)) |rid|
                                try pkg.partByRelId(main_part, rid)
                            else
                                null;
                            try sheets.append(arena, .{
                                .name = try name_list.toOwnedSlice(arena),
                                .part = part,
                            });
                        }
                    },
                    .eof => break,
                    else => {},
                }
            }
        }

        // Shared strings (one string per <si>, rich runs concatenated,
        // phonetic runs skipped).
        var shared: std.ArrayList([]const u8) = .empty;
        if (try pkg.partByRelType(main_part, opc.RelType.shared_strings)) |ss_part| {
            const bytes = try pkg.getPart(ss_part);
            var p = xml.Parser.init(bytes);
            var in_si = false;
            var in_t = false;
            var acc: std.ArrayList(u8) = .empty;
            while (true) {
                const ev = p.next() catch return Error.MalformedXml;
                switch (ev) {
                    .start => |st| {
                        const local = xml.localName(st.name);
                        if (std.mem.eql(u8, local, "si")) {
                            in_si = true;
                            acc.clearRetainingCapacity();
                        } else if (in_si and std.mem.eql(u8, local, "t")) {
                            in_t = !st.self_closing;
                        } else if (in_si and !st.self_closing and
                            (std.mem.eql(u8, local, "rPh") or
                                std.mem.eql(u8, local, "phoneticPr")))
                        {
                            p.skipElement() catch return Error.MalformedXml;
                        }
                    },
                    .end => |name| {
                        const local = xml.localName(name);
                        if (std.mem.eql(u8, local, "si")) {
                            in_si = false;
                            try shared.append(arena, try arena.dupe(u8, acc.items));
                        } else if (std.mem.eql(u8, local, "t")) {
                            in_t = false;
                        }
                    },
                    .text => |raw| if (in_si and in_t) try xml.decodeAppend(&acc, arena, raw),
                    .cdata => |raw| if (in_si and in_t) try acc.appendSlice(arena, raw),
                    .eof => break,
                    else => {},
                }
            }
            acc.deinit(arena);
        }

        return .{
            .pkg = pkg,
            .main_part = main_part,
            .sheets = try sheets.toOwnedSlice(arena),
            .shared = try shared.toOwnedSlice(arena),
        };
    }

    /// Stream one worksheet as CSV. Resolves shared strings, booleans and
    /// inline strings; preserves blank-cell gaps within a row.
    pub fn sheetToCsv(
        self: *Workbook,
        gpa: std.mem.Allocator,
        sheet_index: usize,
        out: *std.ArrayList(u8),
    ) Error!void {
        if (sheet_index >= self.sheets.len) return Error.NoSuchSheet;
        const part = self.sheets[sheet_index].part orelse return Error.NoSuchSheet;
        const bytes = try self.pkg.getPart(part);
        // CSV output runs ~1/3 the size of the sheet XML; one upfront
        // reserve avoids repeated grow+copy of a multi-MB list.
        try out.ensureUnusedCapacity(gpa, bytes.len / 2);

        var p = xml.Parser.init(bytes);
        // Cells of the current row live as (offset,len) views into one
        // reusable blob — steady-state zero allocations per row instead of
        // a dupe+free per cell (zig-optimizer §4: no allocation in the hot
        // per-item loop).
        var row = RowBuf{};
        defer row.deinit(gpa);
        var val: std.ArrayList(u8) = .empty;
        defer val.deinit(gpa);

        var in_row = false;
        var in_v = false;
        var in_is_t = false;
        var cur_col: usize = 0;
        var cell_type: CellType = .n;
        var have_cell = false;

        while (true) {
            const ev = p.next() catch return Error.MalformedXml;
            switch (ev) {
                .start => |st| {
                    const local = xml.localName(st.name);
                    if (std.mem.eql(u8, local, "row")) {
                        in_row = true;
                        row.clear();
                    } else if (in_row and std.mem.eql(u8, local, "c")) {
                        // One pass over the attr block for both r and t —
                        // this runs once per cell.
                        cell_type = .n;
                        var ait = st.attrs();
                        while (ait.next()) |a| {
                            if (a.name.len == 1 and a.name[0] == 'r') {
                                // Cell ref ("B7") fixes the column;
                                // otherwise sequential.
                                cur_col = colFromRef(a.value);
                            } else if (a.name.len == 1 and a.name[0] == 't') {
                                const t = a.value;
                                if (std.mem.eql(u8, t, "s")) {
                                    cell_type = .s;
                                } else if (std.mem.eql(u8, t, "str")) {
                                    cell_type = .str;
                                } else if (std.mem.eql(u8, t, "inlineStr")) {
                                    cell_type = .inline_str;
                                } else if (std.mem.eql(u8, t, "b")) {
                                    cell_type = .b;
                                } else if (std.mem.eql(u8, t, "e")) {
                                    cell_type = .e;
                                }
                            }
                        }
                        val.clearRetainingCapacity();
                        have_cell = true;
                        if (st.self_closing) {
                            try self.pushCell(gpa, &row, cur_col, "", .n);
                            cur_col += 1;
                            have_cell = false;
                        }
                    } else if (have_cell and std.mem.eql(u8, local, "v")) {
                        in_v = !st.self_closing;
                    } else if (have_cell and cell_type == .inline_str and
                        std.mem.eql(u8, local, "t"))
                    {
                        in_is_t = !st.self_closing;
                    }
                },
                .end => |name| {
                    const local = xml.localName(name);
                    if (std.mem.eql(u8, local, "v")) {
                        in_v = false;
                    } else if (std.mem.eql(u8, local, "t")) {
                        in_is_t = false;
                    } else if (std.mem.eql(u8, local, "c") and have_cell) {
                        try self.pushCell(gpa, &row, cur_col, val.items, cell_type);
                        cur_col += 1;
                        have_cell = false;
                    } else if (std.mem.eql(u8, local, "row") and in_row) {
                        try row.writeCsv(gpa, out);
                        in_row = false;
                        cur_col = 0;
                    }
                },
                .text => |raw| if (in_v or in_is_t)
                    try xml.decodeAppend(&val, gpa, raw),
                .cdata => |raw| if (in_v or in_is_t)
                    try val.appendSlice(gpa, raw),
                .eof => return,
                else => {},
            }
        }
    }

    fn pushCell(
        self: *Workbook,
        gpa: std.mem.Allocator,
        row: *RowBuf,
        col: usize,
        raw: []const u8,
        cell_type: CellType,
    ) Error!void {
        const resolved: []const u8 = switch (cell_type) {
            .s => blk: {
                const idx = std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch
                    break :blk raw;
                if (idx < self.shared.len) break :blk self.shared[idx];
                break :blk raw;
            },
            .b => if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "1")) "TRUE" else "FALSE",
            else => raw,
        };
        try row.set(gpa, col, resolved);
    }
};

const CellType = enum { n, s, str, inline_str, b, e };

/// Cells of one CSV row as (offset,len) spans into a reusable blob.
/// `clear` keeps capacity, so steady-state row processing never allocates.
const RowBuf = struct {
    blob: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,

    const Span = struct { off: u32, len: u32 };

    fn deinit(self: *RowBuf, gpa: std.mem.Allocator) void {
        self.blob.deinit(gpa);
        self.spans.deinit(gpa);
    }

    fn clear(self: *RowBuf) void {
        self.blob.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
    }

    fn set(self: *RowBuf, gpa: std.mem.Allocator, col: usize, value: []const u8) !void {
        while (self.spans.items.len < col)
            try self.spans.append(gpa, .{ .off = 0, .len = 0 });
        const off: u32 = @intCast(self.blob.items.len);
        try self.blob.appendSlice(gpa, value);
        try self.spans.append(gpa, .{ .off = off, .len = @intCast(value.len) });
    }

    fn writeCsv(self: *RowBuf, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        for (self.spans.items, 0..) |span, i| {
            if (i > 0) try out.append(gpa, ',');
            const cell = self.blob.items[span.off..][0..span.len];
            const needs_quote = std.mem.indexOfAny(u8, cell, ",\"\n\r") != null;
            if (!needs_quote) {
                try out.appendSlice(gpa, cell);
            } else {
                try out.append(gpa, '"');
                for (cell) |c| {
                    if (c == '"') try out.append(gpa, '"');
                    try out.append(gpa, c);
                }
                try out.append(gpa, '"');
            }
        }
        try out.append(gpa, '\n');
        self.clear();
    }
};

/// "BC23" -> 54 (0-based column).
fn colFromRef(ref: []const u8) usize {
    var col: usize = 0;
    for (ref) |c| {
        if (c >= 'A' and c <= 'Z') {
            col = col * 26 + (c - 'A' + 1);
        } else if (c >= 'a' and c <= 'z') {
            col = col * 26 + (c - 'a' + 1);
        } else break;
    }
    return if (col == 0) 0 else col - 1;
}

// ── PresentationDocument ──────────────────────────────────────────────────

pub const Presentation = struct {
    pkg: *opc.Package,
    main_part: []const u8,
    /// Slide part names in presentation order.
    slides: []const []const u8,

    pub fn open(pkg: *opc.Package) Error!Presentation {
        const d = try detect(pkg);
        if (d.kind != .pptx or d.main_part == null) return Error.NotOfficeDocument;
        const main_part = d.main_part.?;
        const arena = pkg.arena.allocator();

        var slides: std.ArrayList([]const u8) = .empty;
        const bytes = try pkg.getPart(main_part);
        var p = xml.Parser.init(bytes);
        var in_list = false;
        while (true) {
            const ev = p.next() catch return Error.MalformedXml;
            switch (ev) {
                .start => |st| {
                    const local = xml.localName(st.name);
                    if (std.mem.eql(u8, local, "sldIdLst")) {
                        in_list = true;
                    } else if (in_list and std.mem.eql(u8, local, "sldId")) {
                        if (relIdOf(&st)) |rid| {
                            if (try pkg.partByRelId(main_part, rid)) |part|
                                try slides.append(arena, part);
                        }
                    }
                },
                .end => |name| {
                    if (std.mem.eql(u8, xml.localName(name), "sldIdLst")) in_list = false;
                },
                .eof => break,
                else => {},
            }
        }

        return .{
            .pkg = pkg,
            .main_part = main_part,
            .slides = try slides.toOwnedSlice(arena),
        };
    }

    pub fn slideText(
        self: *Presentation,
        gpa: std.mem.Allocator,
        slide_index: usize,
        out: *std.ArrayList(u8),
    ) Error!void {
        const bytes = try self.pkg.getPart(self.slides[slide_index]);
        try extractTextXml(gpa, bytes, out);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

const zip = @import("zip.zig");
const testing = std.testing;

fn ctXml(comptime overrides: []const u8) []const u8 {
    return "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" ++
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" ++
        "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" ++
        overrides ++ "</Types>";
}

fn rootRels(comptime target: []const u8) []const u8 {
    return "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" ++
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"" ++
        target ++ "\"/></Relationships>";
}

test "docx text extraction: runs, tabs, breaks, entities" {
    const gpa = testing.allocator;

    const doc_xml =
        "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>" ++
        "<w:p><w:r><w:t>Hello</w:t></w:r><w:r><w:tab/><w:t xml:space=\"preserve\">cruel &amp; kind</w:t></w:r></w:p>" ++
        "<w:p><w:r><w:t>line1</w:t><w:br/><w:t>line2</w:t></w:r></w:p>" ++
        "<w:p/>" ++
        "</w:body></w:document>";

    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = ctXml("<Override PartName=\"/word/document.xml\" ContentType=\"" ++ ct_docx_main ++ "\"/>") },
        .{ .name = "_rels/.rels", .data = rootRels("word/document.xml") },
        .{ .name = "word/document.xml", .data = doc_xml },
    });
    defer gpa.free(data);

    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    var doc = try WordDocument.open(&pkg);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try doc.text(gpa, &out);
    try testing.expectEqualStrings("Hello\tcruel & kind\nline1\nline2\n\n", out.items);
}

test "xlsx: shared strings, types, gaps, csv quoting" {
    const gpa = testing.allocator;

    const wb_xml =
        "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" " ++
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">" ++
        "<sheets><sheet name=\"Data &amp; More\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>";
    const wb_rels =
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" ++
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>" ++
        "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>" ++
        "</Relationships>";
    const sst =
        "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"3\" uniqueCount=\"3\">" ++
        "<si><t>alpha</t></si>" ++
        "<si><r><t>ri</t></r><r><t>ch</t></r></si>" ++
        "<si><t>has, comma \"q\"</t></si>" ++
        "</sst>";
    const sheet =
        "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>" ++
        "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"C1\"><v>42</v></c></row>" ++
        "<row r=\"2\"><c r=\"A2\" t=\"s\"><v>1</v></c><c r=\"B2\" t=\"b\"><v>1</v></c>" ++
        "<c r=\"C2\" t=\"inlineStr\"><is><t>inline!</t></is></c>" ++
        "<c r=\"D2\" t=\"s\"><v>2</v></c></row>" ++
        "</sheetData></worksheet>";

    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = ctXml("<Override PartName=\"/xl/workbook.xml\" ContentType=\"" ++ ct_xlsx_main ++ "\"/>") },
        .{ .name = "_rels/.rels", .data = rootRels("xl/workbook.xml") },
        .{ .name = "xl/workbook.xml", .data = wb_xml },
        .{ .name = "xl/_rels/workbook.xml.rels", .data = wb_rels },
        .{ .name = "xl/sharedStrings.xml", .data = sst },
        .{ .name = "xl/worksheets/sheet1.xml", .data = sheet },
    });
    defer gpa.free(data);

    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    var wb = try Workbook.open(&pkg);

    try testing.expectEqual(@as(usize, 1), wb.sheets.len);
    try testing.expectEqualStrings("Data & More", wb.sheets[0].name);
    try testing.expectEqual(@as(usize, 3), wb.shared.len);
    try testing.expectEqualStrings("rich", wb.shared[1]);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try wb.sheetToCsv(gpa, 0, &out);
    try testing.expectEqualStrings(
        "alpha,,42\nrich,TRUE,inline!,\"has, comma \"\"q\"\"\"\n",
        out.items,
    );
}

test "pptx: slide order and text" {
    const gpa = testing.allocator;

    const pres =
        "<p:presentation xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" " ++
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">" ++
        "<p:sldIdLst><p:sldId id=\"257\" r:id=\"rId3\"/><p:sldId id=\"256\" r:id=\"rId2\"/></p:sldIdLst>" ++
        "</p:presentation>";
    const pres_rels =
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" ++
        "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide1.xml\"/>" ++
        "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide2.xml\"/>" ++
        "</Relationships>";
    const slide1 =
        "<p:sld xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:p=\"x\">" ++
        "<a:p><a:r><a:t>First slide</a:t></a:r></a:p></p:sld>";
    const slide2 =
        "<p:sld xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:p=\"x\">" ++
        "<a:p><a:r><a:t>Second slide</a:t></a:r></a:p></p:sld>";

    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = ctXml("<Override PartName=\"/ppt/presentation.xml\" ContentType=\"" ++ ct_pptx_main ++ "\"/>") },
        .{ .name = "_rels/.rels", .data = rootRels("ppt/presentation.xml") },
        .{ .name = "ppt/presentation.xml", .data = pres },
        .{ .name = "ppt/_rels/presentation.xml.rels", .data = pres_rels },
        .{ .name = "ppt/slides/slide1.xml", .data = slide1 },
        .{ .name = "ppt/slides/slide2.xml", .data = slide2 },
    });
    defer gpa.free(data);

    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    var pres_doc = try Presentation.open(&pkg);

    // sldIdLst order: rId3 (slide2) first.
    try testing.expectEqual(@as(usize, 2), pres_doc.slides.len);
    try testing.expectEqualStrings("ppt/slides/slide2.xml", pres_doc.slides[0]);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try pres_doc.slideText(gpa, 0, &out);
    try testing.expectEqualStrings("Second slide\n", out.items);
}

test "colFromRef" {
    try testing.expectEqual(@as(usize, 0), colFromRef("A1"));
    try testing.expectEqual(@as(usize, 2), colFromRef("C7"));
    try testing.expectEqual(@as(usize, 25), colFromRef("Z99"));
    try testing.expectEqual(@as(usize, 26), colFromRef("AA1"));
    try testing.expectEqual(@as(usize, 54), colFromRef("BC23"));
}

// ── Spec edge cases ────────────────────────────────────────────────────────

test "docx excludes deleted text, field instructions, and Fallback branches" {
    const gpa = testing.allocator;
    const doc_xml =
        "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" " ++
        "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\"><w:body>" ++
        // Tracked deletion: w:delText must not surface.
        "<w:p><w:r><w:t>kept</w:t></w:r><w:r><w:delText>deleted</w:delText></w:r></w:p>" ++
        // Field instruction text (TOC codes etc.) must not surface.
        "<w:p><w:r><w:instrText>PAGEREF _Toc1</w:instrText><w:t>visible</w:t></w:r></w:p>" ++
        // AlternateContent: Choice wins, Fallback skipped.
        "<w:p><mc:AlternateContent>" ++
        "<mc:Choice Requires=\"wps\"><w:r><w:t>choice</w:t></w:r></mc:Choice>" ++
        "<mc:Fallback><w:r><w:t>fallback</w:t></w:r></mc:Fallback>" ++
        "</mc:AlternateContent></w:p>" ++
        "</w:body></w:document>";

    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = ctXml("<Override PartName=\"/word/document.xml\" ContentType=\"" ++ ct_docx_main ++ "\"/>") },
        .{ .name = "_rels/.rels", .data = rootRels("word/document.xml") },
        .{ .name = "word/document.xml", .data = doc_xml },
    });
    defer gpa.free(data);

    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    var doc = try WordDocument.open(&pkg);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try doc.text(gpa, &out);
    try testing.expectEqualStrings("kept\nvisible\nchoice\n", out.items);
}

fn xlsxPackage(gpa: std.mem.Allocator, sheet_xml: []const u8, sst_xml: ?[]const u8) ![]u8 {
    const wb_xml =
        "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" " ++
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">" ++
        "<sheets><sheet name=\"S1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>";
    const wb_rels_with_sst =
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" ++
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>" ++
        "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>" ++
        "</Relationships>";
    const wb_rels_plain =
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" ++
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>" ++
        "</Relationships>";

    var files: std.ArrayList(zip.TestFile) = .empty;
    defer files.deinit(gpa);
    try files.append(gpa, .{ .name = "[Content_Types].xml", .data = ctXml("<Override PartName=\"/xl/workbook.xml\" ContentType=\"" ++ ct_xlsx_main ++ "\"/>") });
    try files.append(gpa, .{ .name = "_rels/.rels", .data = rootRels("xl/workbook.xml") });
    try files.append(gpa, .{ .name = "xl/workbook.xml", .data = wb_xml });
    try files.append(gpa, .{
        .name = "xl/_rels/workbook.xml.rels",
        .data = if (sst_xml != null) wb_rels_with_sst else wb_rels_plain,
    });
    if (sst_xml) |sst| try files.append(gpa, .{ .name = "xl/sharedStrings.xml", .data = sst });
    try files.append(gpa, .{ .name = "xl/worksheets/sheet1.xml", .data = sheet_xml });
    return zip.writeStoredZip(gpa, files.items);
}

fn expectCsv(gpa: std.mem.Allocator, data: []const u8, expected: []const u8) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    var wb = try Workbook.open(&pkg);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try wb.sheetToCsv(gpa, 0, &out);
    try testing.expectEqualStrings(expected, out.items);
}

test "xlsx sequential cells without refs use document order" {
    const gpa = testing.allocator;
    const sheet =
        "<worksheet xmlns=\"x\"><sheetData>" ++
        "<row><c><v>1</v></c><c><v>2</v></c><c><v>3</v></c></row>" ++
        "</sheetData></worksheet>";
    const data = try xlsxPackage(gpa, sheet, null);
    defer gpa.free(data);
    try expectCsv(gpa, data, "1,2,3\n");
}

test "xlsx self-closing empty cells and sparse refs keep gaps" {
    const gpa = testing.allocator;
    const sheet =
        "<worksheet xmlns=\"x\"><sheetData>" ++
        "<row r=\"1\"><c r=\"A1\"/><c r=\"C1\"><v>7</v></c></row>" ++
        "<row r=\"2\"><c r=\"D2\"><v>9</v></c></row>" ++
        "</sheetData></worksheet>";
    const data = try xlsxPackage(gpa, sheet, null);
    defer gpa.free(data);
    try expectCsv(gpa, data, ",,7\n,,,9\n");
}

test "xlsx error and formula-string cell types pass through" {
    const gpa = testing.allocator;
    const sheet =
        "<worksheet xmlns=\"x\"><sheetData>" ++
        "<row><c t=\"e\"><v>#DIV/0!</v></c><c t=\"str\"><v>computed</v></c><c t=\"b\"><v>0</v></c></row>" ++
        "</sheetData></worksheet>";
    const data = try xlsxPackage(gpa, sheet, null);
    defer gpa.free(data);
    try expectCsv(gpa, data, "#DIV/0!,computed,FALSE\n");
}

test "xlsx shared-string index out of range falls back to raw" {
    const gpa = testing.allocator;
    const sst = "<sst xmlns=\"x\"><si><t>only</t></si></sst>";
    const sheet =
        "<worksheet xmlns=\"x\"><sheetData>" ++
        "<row><c t=\"s\"><v>0</v></c><c t=\"s\"><v>99</v></c></row>" ++
        "</sheetData></worksheet>";
    const data = try xlsxPackage(gpa, sheet, sst);
    defer gpa.free(data);
    try expectCsv(gpa, data, "only,99\n");
}

test "xlsx phonetic runs are excluded from shared strings" {
    const gpa = testing.allocator;
    const sst =
        "<sst xmlns=\"x\"><si><t>\xE6\xBC\xA2\xE5\xAD\x97</t>" ++
        "<rPh sb=\"0\" eb=\"2\"><t>\xE3\x81\x8B\xE3\x82\x93\xE3\x81\x98</t></rPh>" ++
        "<phoneticPr fontId=\"1\"/></si></sst>";
    const sheet =
        "<worksheet xmlns=\"x\"><sheetData>" ++
        "<row><c t=\"s\"><v>0</v></c></row>" ++
        "</sheetData></worksheet>";
    const data = try xlsxPackage(gpa, sheet, sst);
    defer gpa.free(data);
    // 漢字 only — phonetic かんじ must not leak in.
    try expectCsv(gpa, data, "\xE6\xBC\xA2\xE5\xAD\x97\n");
}

test "detect falls back to conventional part names without rels" {
    const gpa = testing.allocator;
    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "word/document.xml", .data = "<w:document><w:body><w:p><w:r><w:t>hi</w:t></w:r></w:p></w:body></w:document>" },
    });
    defer gpa.free(data);

    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    const d = try detect(&pkg);
    try testing.expectEqual(Kind.docx, d.kind);

    var doc = try WordDocument.open(&pkg);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try doc.text(gpa, &out);
    try testing.expectEqualStrings("hi\n", out.items);
}

test "macro-enabled main content types still classify" {
    const gpa = testing.allocator;
    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = ctXml("<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.ms-excel.sheet.macroEnabled.main+xml\"/>") },
        .{ .name = "_rels/.rels", .data = rootRels("xl/workbook.xml") },
        .{ .name = "xl/workbook.xml", .data = "<workbook xmlns=\"x\"><sheets/></workbook>" },
    });
    defer gpa.free(data);

    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    const d = try detect(&pkg);
    // .xlsm content type says "ms-excel" but conventional parts say xlsx.
    try testing.expectEqual(Kind.xlsx, d.kind);
}

// ── Builders: the *.Create() write path ────────────────────────────────────
//
// Open-XML-SDK creates documents by assembling parts into an OPC package;
// these builders do the same with handwritten minimal parts. Strings passed
// in are duped into the builder's arena except the public `title`/`creator`
// fields, which are borrowed until `save`.

const w_ns = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
const x_ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
const p_ns = "http://schemas.openxmlformats.org/presentationml/2006/main";
const a_ns = "http://schemas.openxmlformats.org/drawingml/2006/main";
const cp_ns = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties";
const dc_ns = "http://purl.org/dc/elements/1.1/";
const pkg_rels_xmlns = "http://schemas.openxmlformats.org/package/2006/relationships";
const ct_xmlns = "http://schemas.openxmlformats.org/package/2006/content-types";

const xml_decl = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>";
const ct_core_props = "application/vnd.openxmlformats-package.core-properties+xml";
pub const ct_xlsx_sheet = "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml";
pub const ct_xlsx_sst = "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml";
pub const ct_pptx_slide = "application/vnd.openxmlformats-officedocument.presentationml.slide+xml";

fn appendFmt(
    list: *std.ArrayList(u8),
    a: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try list.appendSlice(a, try std.fmt.allocPrint(a, fmt, args));
}

fn zipParts(gpa: std.mem.Allocator, files: []const zip.TestFile) zip.WriteError![]u8 {
    var w = zip.Writer{};
    defer w.deinit(gpa);
    for (files) |f| try w.addFile(gpa, f.name, f.data, .deflate);
    return w.finish(gpa);
}

/// Append `<cp:coreProperties>` part + its content-type override + root rel
/// when the builder has properties set.
fn appendCoreProps(
    a: std.mem.Allocator,
    files: *std.ArrayList(zip.TestFile),
    ct_overrides: *std.ArrayList(u8),
    root_rels: *std.ArrayList(u8),
    title: ?[]const u8,
    creator: ?[]const u8,
    next_rel_id: usize,
) !void {
    if (title == null and creator == null) return;
    var core: std.ArrayList(u8) = .empty;
    try appendFmt(&core, a, "{s}<cp:coreProperties xmlns:cp=\"{s}\" xmlns:dc=\"{s}\">", .{ xml_decl, cp_ns, dc_ns });
    if (title) |t| {
        try core.appendSlice(a, "<dc:title>");
        try xml.escapeAppend(&core, a, t, .text);
        try core.appendSlice(a, "</dc:title>");
    }
    if (creator) |c| {
        try core.appendSlice(a, "<dc:creator>");
        try xml.escapeAppend(&core, a, c, .text);
        try core.appendSlice(a, "</dc:creator>");
    }
    try core.appendSlice(a, "</cp:coreProperties>");
    try files.append(a, .{ .name = "docProps/core.xml", .data = core.items });
    try appendFmt(ct_overrides, a, "<Override PartName=\"/docProps/core.xml\" ContentType=\"{s}\"/>", .{ct_core_props});
    try appendFmt(root_rels, a, "<Relationship Id=\"rId{d}\" Type=\"{s}\" Target=\"docProps/core.xml\"/>", .{ next_rel_id, opc.RelType.core_properties });
}

pub const DocumentBuilder = struct {
    arena: std.heap.ArenaAllocator,
    paras: std.ArrayList([]const u8) = .empty,
    /// Borrowed; must outlive `save`.
    title: ?[]const u8 = null,
    creator: ?[]const u8 = null,

    pub fn init(backing: std.mem.Allocator) DocumentBuilder {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *DocumentBuilder) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn addParagraph(self: *DocumentBuilder, text: []const u8) !void {
        const a = self.arena.allocator();
        try self.paras.append(a, try a.dupe(u8, text));
    }

    /// Assemble a complete .docx; caller owns the returned bytes.
    pub fn save(self: *DocumentBuilder, gpa: std.mem.Allocator) ![]u8 {
        const a = self.arena.allocator();

        var doc: std.ArrayList(u8) = .empty;
        try appendFmt(&doc, a, "{s}<w:document xmlns:w=\"{s}\"><w:body>", .{ xml_decl, w_ns });
        for (self.paras.items) |para| {
            if (para.len == 0) {
                try doc.appendSlice(a, "<w:p/>");
                continue;
            }
            try doc.appendSlice(a, "<w:p><w:r><w:t xml:space=\"preserve\">");
            try xml.escapeAppend(&doc, a, para, .text);
            try doc.appendSlice(a, "</w:t></w:r></w:p>");
        }
        try doc.appendSlice(a, "</w:body></w:document>");

        var ct: std.ArrayList(u8) = .empty;
        try appendFmt(&ct, a, "{s}<Types xmlns=\"{s}\">" ++
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" ++
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" ++
            "<Override PartName=\"/word/document.xml\" ContentType=\"{s}\"/>", .{ xml_decl, ct_xmlns, ct_docx_main });

        var rels: std.ArrayList(u8) = .empty;
        try appendFmt(&rels, a, "{s}<Relationships xmlns=\"{s}\">" ++
            "<Relationship Id=\"rId1\" Type=\"{s}\" Target=\"word/document.xml\"/>", .{ xml_decl, pkg_rels_xmlns, opc.RelType.office_document });

        var files: std.ArrayList(zip.TestFile) = .empty;
        try files.append(a, .{ .name = "word/document.xml", .data = doc.items });
        try appendCoreProps(a, &files, &ct, &rels, self.title, self.creator, 2);

        try ct.appendSlice(a, "</Types>");
        try rels.appendSlice(a, "</Relationships>");

        var all: std.ArrayList(zip.TestFile) = .empty;
        try all.append(a, .{ .name = "[Content_Types].xml", .data = ct.items });
        try all.append(a, .{ .name = "_rels/.rels", .data = rels.items });
        try all.appendSlice(a, files.items);
        return zipParts(gpa, all.items);
    }
};

pub const CellValue = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
};

const BuilderCell = struct { row: u32, col: u32, value: CellValue };
const BuilderSheet = struct {
    name: []const u8,
    cells: std.ArrayList(BuilderCell) = .empty,
};

pub const WorkbookBuilder = struct {
    arena: std.heap.ArenaAllocator,
    sheets: std.ArrayList(BuilderSheet) = .empty,
    title: ?[]const u8 = null,
    creator: ?[]const u8 = null,

    pub fn init(backing: std.mem.Allocator) WorkbookBuilder {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *WorkbookBuilder) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn addSheet(self: *WorkbookBuilder, name: []const u8) !usize {
        const a = self.arena.allocator();
        try self.sheets.append(a, .{ .name = try a.dupe(u8, name) });
        return self.sheets.items.len - 1;
    }

    /// `row` and `col` are 0-based; (0,0) is A1.
    pub fn setCell(self: *WorkbookBuilder, sheet: usize, row: u32, col: u32, value: CellValue) !void {
        const a = self.arena.allocator();
        const v: CellValue = switch (value) {
            .string => |s| .{ .string = try a.dupe(u8, s) },
            else => value,
        };
        try self.sheets.items[sheet].cells.append(a, .{ .row = row, .col = col, .value = v });
    }

    pub fn save(self: *WorkbookBuilder, gpa: std.mem.Allocator) ![]u8 {
        const a = self.arena.allocator();

        var sst_index = std.StringHashMap(u32).init(a);
        var sst_list: std.ArrayList([]const u8) = .empty;
        var sst_refs: usize = 0;

        var files: std.ArrayList(zip.TestFile) = .empty;
        var ct: std.ArrayList(u8) = .empty;
        try appendFmt(&ct, a, "{s}<Types xmlns=\"{s}\">" ++
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" ++
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" ++
            "<Override PartName=\"/xl/workbook.xml\" ContentType=\"{s}\"/>", .{ xml_decl, ct_xmlns, ct_xlsx_main });

        var wb: std.ArrayList(u8) = .empty;
        try appendFmt(&wb, a, "{s}<workbook xmlns=\"{s}\" xmlns:r=\"{s}\"><sheets>", .{ xml_decl, x_ns, opc.rel_ns });
        var wb_rels: std.ArrayList(u8) = .empty;
        try appendFmt(&wb_rels, a, "{s}<Relationships xmlns=\"{s}\">", .{ xml_decl, pkg_rels_xmlns });

        for (self.sheets.items, 0..) |*sheet, i| {
            std.mem.sort(BuilderCell, sheet.cells.items, {}, cellLess);

            var sx: std.ArrayList(u8) = .empty;
            try appendFmt(&sx, a, "{s}<worksheet xmlns=\"{s}\"><sheetData>", .{ xml_decl, x_ns });
            var open_row: ?u32 = null;
            for (sheet.cells.items) |cell| {
                if (open_row == null or open_row.? != cell.row) {
                    if (open_row != null) try sx.appendSlice(a, "</row>");
                    try appendFmt(&sx, a, "<row r=\"{d}\">", .{cell.row + 1});
                    open_row = cell.row;
                }
                var ref_buf: [12]u8 = undefined;
                const col_ref = colToRef(cell.col, &ref_buf);
                switch (cell.value) {
                    .string => |s| {
                        const gop = try sst_index.getOrPut(s);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = @intCast(sst_list.items.len);
                            try sst_list.append(a, s);
                        }
                        sst_refs += 1;
                        try appendFmt(&sx, a, "<c r=\"{s}{d}\" t=\"s\"><v>{d}</v></c>", .{ col_ref, cell.row + 1, gop.value_ptr.* });
                    },
                    .number => |n| {
                        var nbuf: [40]u8 = undefined;
                        try appendFmt(&sx, a, "<c r=\"{s}{d}\"><v>{s}</v></c>", .{ col_ref, cell.row + 1, fmtNumber(&nbuf, n) });
                    },
                    .boolean => |b| {
                        try appendFmt(&sx, a, "<c r=\"{s}{d}\" t=\"b\"><v>{d}</v></c>", .{ col_ref, cell.row + 1, @intFromBool(b) });
                    },
                }
            }
            if (open_row != null) try sx.appendSlice(a, "</row>");
            try sx.appendSlice(a, "</sheetData></worksheet>");

            const part_name = try std.fmt.allocPrint(a, "xl/worksheets/sheet{d}.xml", .{i + 1});
            try files.append(a, .{ .name = part_name, .data = sx.items });
            try appendFmt(&ct, a, "<Override PartName=\"/{s}\" ContentType=\"{s}\"/>", .{ part_name, ct_xlsx_sheet });
            try appendFmt(&wb_rels, a, "<Relationship Id=\"rId{d}\" Type=\"{s}\" Target=\"worksheets/sheet{d}.xml\"/>", .{ i + 1, opc.RelType.worksheet, i + 1 });

            try wb.appendSlice(a, "<sheet name=\"");
            try xml.escapeAppend(&wb, a, sheet.name, .attr);
            try appendFmt(&wb, a, "\" sheetId=\"{d}\" r:id=\"rId{d}\"/>", .{ i + 1, i + 1 });
        }
        try wb.appendSlice(a, "</sheets></workbook>");

        if (sst_list.items.len > 0) {
            var sst: std.ArrayList(u8) = .empty;
            try appendFmt(&sst, a, "{s}<sst xmlns=\"{s}\" count=\"{d}\" uniqueCount=\"{d}\">", .{ xml_decl, x_ns, sst_refs, sst_list.items.len });
            for (sst_list.items) |s| {
                try sst.appendSlice(a, "<si><t xml:space=\"preserve\">");
                try xml.escapeAppend(&sst, a, s, .text);
                try sst.appendSlice(a, "</t></si>");
            }
            try sst.appendSlice(a, "</sst>");
            try files.append(a, .{ .name = "xl/sharedStrings.xml", .data = sst.items });
            try appendFmt(&ct, a, "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"{s}\"/>", .{ct_xlsx_sst});
            try appendFmt(&wb_rels, a, "<Relationship Id=\"rId{d}\" Type=\"{s}\" Target=\"sharedStrings.xml\"/>", .{ self.sheets.items.len + 1, opc.RelType.shared_strings });
        }
        try wb_rels.appendSlice(a, "</Relationships>");

        var root_rels: std.ArrayList(u8) = .empty;
        try appendFmt(&root_rels, a, "{s}<Relationships xmlns=\"{s}\">" ++
            "<Relationship Id=\"rId1\" Type=\"{s}\" Target=\"xl/workbook.xml\"/>", .{ xml_decl, pkg_rels_xmlns, opc.RelType.office_document });
        try appendCoreProps(a, &files, &ct, &root_rels, self.title, self.creator, 2);
        try ct.appendSlice(a, "</Types>");
        try root_rels.appendSlice(a, "</Relationships>");

        var all: std.ArrayList(zip.TestFile) = .empty;
        try all.append(a, .{ .name = "[Content_Types].xml", .data = ct.items });
        try all.append(a, .{ .name = "_rels/.rels", .data = root_rels.items });
        try all.append(a, .{ .name = "xl/workbook.xml", .data = wb.items });
        try all.append(a, .{ .name = "xl/_rels/workbook.xml.rels", .data = wb_rels.items });
        try all.appendSlice(a, files.items);
        return zipParts(gpa, all.items);
    }
};

fn cellLess(_: void, lhs: BuilderCell, rhs: BuilderCell) bool {
    if (lhs.row != rhs.row) return lhs.row < rhs.row;
    return lhs.col < rhs.col;
}

/// 0-based column -> "A".."Z","AA".. into `buf`; returns the used slice.
fn colToRef(col0: u32, buf: []u8) []const u8 {
    var col = col0 + 1;
    var i = buf.len;
    while (col > 0) {
        i -= 1;
        buf[i] = 'A' + @as(u8, @intCast((col - 1) % 26));
        col = (col - 1) / 26;
    }
    return buf[i..];
}

/// Whole numbers print as integers (Excel-style), everything else as
/// shortest decimal.
fn fmtNumber(buf: []u8, v: f64) []const u8 {
    if (std.math.isFinite(v) and @floor(v) == v and @abs(v) < 1e15) {
        const i: i64 = @intFromFloat(v);
        return std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable;
}

pub const PresentationBuilder = struct {
    arena: std.heap.ArenaAllocator,
    slides: std.ArrayList([]const []const u8) = .empty,
    title: ?[]const u8 = null,
    creator: ?[]const u8 = null,

    pub fn init(backing: std.mem.Allocator) PresentationBuilder {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *PresentationBuilder) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Each line becomes one paragraph (`<a:p>`) on the slide.
    pub fn addSlide(self: *PresentationBuilder, lines: []const []const u8) !void {
        const a = self.arena.allocator();
        const copy = try a.alloc([]const u8, lines.len);
        for (lines, copy) |src, *dst| dst.* = try a.dupe(u8, src);
        try self.slides.append(a, copy);
    }

    /// Emits the full minimal-valid deck skeleton: slide master, slide
    /// layout, theme, sldSz/notesSz, and per-slide shape trees. Microsoft's
    /// own OpenXmlValidator passes the output with zero errors (its own
    /// `PresentationDocument.Create` minimal output does not — it omits the
    /// master and notesSz).
    pub fn save(self: *PresentationBuilder, gpa: std.mem.Allocator) ![]u8 {
        const a = self.arena.allocator();

        const ct_master = "application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml";
        const ct_layout = "application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml";
        const ct_theme = "application/vnd.openxmlformats-officedocument.theme+xml";

        const sp_tree_header =
            "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>";

        var files: std.ArrayList(zip.TestFile) = .empty;
        var ct: std.ArrayList(u8) = .empty;
        try appendFmt(&ct, a, "{s}<Types xmlns=\"{s}\">" ++
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" ++
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" ++
            "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"{s}\"/>" ++
            "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"{s}\"/>" ++
            "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"{s}\"/>" ++
            "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"{s}\"/>", .{ xml_decl, ct_xmlns, ct_pptx_main, ct_master, ct_layout, ct_theme });

        var pres: std.ArrayList(u8) = .empty;
        const master_rid = self.slides.items.len + 1;
        try appendFmt(&pres, a, "{s}<p:presentation xmlns:p=\"{s}\" xmlns:r=\"{s}\">" ++
            "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId{d}\"/></p:sldMasterIdLst><p:sldIdLst>", .{ xml_decl, p_ns, opc.rel_ns, master_rid });
        var pres_rels: std.ArrayList(u8) = .empty;
        try appendFmt(&pres_rels, a, "{s}<Relationships xmlns=\"{s}\">", .{ xml_decl, pkg_rels_xmlns });

        for (self.slides.items, 0..) |lines, i| {
            var sx: std.ArrayList(u8) = .empty;
            try appendFmt(&sx, a, "{s}<p:sld xmlns:p=\"{s}\" xmlns:a=\"{s}\"><p:cSld><p:spTree>{s}" ++
                "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Content\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/>" ++
                "<p:txBody><a:bodyPr/><a:lstStyle/>", .{ xml_decl, p_ns, a_ns, sp_tree_header });
            if (lines.len == 0) {
                try sx.appendSlice(a, "<a:p/>");
            } else for (lines) |line| {
                try sx.appendSlice(a, "<a:p><a:r><a:t>");
                try xml.escapeAppend(&sx, a, line, .text);
                try sx.appendSlice(a, "</a:t></a:r></a:p>");
            }
            try sx.appendSlice(a, "</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>");

            const part_name = try std.fmt.allocPrint(a, "ppt/slides/slide{d}.xml", .{i + 1});
            try files.append(a, .{ .name = part_name, .data = sx.items });

            var slide_rels: std.ArrayList(u8) = .empty;
            try appendFmt(&slide_rels, a, "{s}<Relationships xmlns=\"{s}\">" ++
                "<Relationship Id=\"rId1\" Type=\"{s}/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>" ++
                "</Relationships>", .{ xml_decl, pkg_rels_xmlns, opc.rel_ns });
            try files.append(a, .{
                .name = try std.fmt.allocPrint(a, "ppt/slides/_rels/slide{d}.xml.rels", .{i + 1}),
                .data = slide_rels.items,
            });

            try appendFmt(&ct, a, "<Override PartName=\"/{s}\" ContentType=\"{s}\"/>", .{ part_name, ct_pptx_slide });
            try appendFmt(&pres, a, "<p:sldId id=\"{d}\" r:id=\"rId{d}\"/>", .{ 256 + i, i + 1 });
            try appendFmt(&pres_rels, a, "<Relationship Id=\"rId{d}\" Type=\"{s}\" Target=\"slides/slide{d}.xml\"/>", .{ i + 1, opc.RelType.slide, i + 1 });
        }
        try pres.appendSlice(a, "</p:sldIdLst><p:sldSz cx=\"9144000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>");
        try appendFmt(&pres_rels, a, "<Relationship Id=\"rId{d}\" Type=\"{s}/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/></Relationships>", .{ master_rid, opc.rel_ns });

        // Slide master (links the layout and the theme).
        var master: std.ArrayList(u8) = .empty;
        try appendFmt(&master, a, "{s}<p:sldMaster xmlns:p=\"{s}\" xmlns:a=\"{s}\" xmlns:r=\"{s}\">" ++
            "<p:cSld><p:spTree>{s}</p:spTree></p:cSld>" ++
            "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>" ++
            "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst>" ++
            "</p:sldMaster>", .{ xml_decl, p_ns, a_ns, opc.rel_ns, sp_tree_header });
        var master_rels: std.ArrayList(u8) = .empty;
        try appendFmt(&master_rels, a, "{s}<Relationships xmlns=\"{s}\">" ++
            "<Relationship Id=\"rId1\" Type=\"{s}/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>" ++
            "<Relationship Id=\"rId2\" Type=\"{s}/theme\" Target=\"../theme/theme1.xml\"/>" ++
            "</Relationships>", .{ xml_decl, pkg_rels_xmlns, opc.rel_ns, opc.rel_ns });

        // Slide layout (back-links the master).
        var layout: std.ArrayList(u8) = .empty;
        try appendFmt(&layout, a, "{s}<p:sldLayout xmlns:p=\"{s}\" xmlns:a=\"{s}\" xmlns:r=\"{s}\">" ++
            "<p:cSld><p:spTree>{s}</p:spTree></p:cSld>" ++
            "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>" ++
            "</p:sldLayout>", .{ xml_decl, p_ns, a_ns, opc.rel_ns, sp_tree_header });
        var layout_rels: std.ArrayList(u8) = .empty;
        try appendFmt(&layout_rels, a, "{s}<Relationships xmlns=\"{s}\">" ++
            "<Relationship Id=\"rId1\" Type=\"{s}/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/>" ++
            "</Relationships>", .{ xml_decl, pkg_rels_xmlns, opc.rel_ns });

        // Minimal valid theme: clrScheme + fontScheme + fmtScheme with the
        // schema-required triples.
        var theme: std.ArrayList(u8) = .empty;
        try appendFmt(&theme, a, "{s}<a:theme xmlns:a=\"{s}\" name=\"nanoxml\"><a:themeElements>" ++
            "<a:clrScheme name=\"nanoxml\">" ++
            "<a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1>" ++
            "<a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>" ++
            "<a:dk2><a:srgbClr val=\"44546A\"/></a:dk2>" ++
            "<a:lt2><a:srgbClr val=\"E7E6E6\"/></a:lt2>" ++
            "<a:accent1><a:srgbClr val=\"4472C4\"/></a:accent1>" ++
            "<a:accent2><a:srgbClr val=\"ED7D31\"/></a:accent2>" ++
            "<a:accent3><a:srgbClr val=\"A5A5A5\"/></a:accent3>" ++
            "<a:accent4><a:srgbClr val=\"FFC000\"/></a:accent4>" ++
            "<a:accent5><a:srgbClr val=\"5B9BD5\"/></a:accent5>" ++
            "<a:accent6><a:srgbClr val=\"70AD47\"/></a:accent6>" ++
            "<a:hlink><a:srgbClr val=\"0563C1\"/></a:hlink>" ++
            "<a:folHlink><a:srgbClr val=\"954F72\"/></a:folHlink>" ++
            "</a:clrScheme>" ++
            "<a:fontScheme name=\"nanoxml\">" ++
            "<a:majorFont><a:latin typeface=\"Calibri Light\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>" ++
            "<a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont>" ++
            "</a:fontScheme>" ++
            "<a:fmtScheme name=\"nanoxml\">" ++
            "<a:fillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:fillStyleLst>" ++
            "<a:lnStyleLst><a:ln><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln></a:lnStyleLst>" ++
            "<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>" ++
            "<a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:bgFillStyleLst>" ++
            "</a:fmtScheme>" ++
            "</a:themeElements></a:theme>", .{ xml_decl, a_ns });

        var root_rels: std.ArrayList(u8) = .empty;
        try appendFmt(&root_rels, a, "{s}<Relationships xmlns=\"{s}\">" ++
            "<Relationship Id=\"rId1\" Type=\"{s}\" Target=\"ppt/presentation.xml\"/>", .{ xml_decl, pkg_rels_xmlns, opc.RelType.office_document });
        try appendCoreProps(a, &files, &ct, &root_rels, self.title, self.creator, 2);
        try ct.appendSlice(a, "</Types>");
        try root_rels.appendSlice(a, "</Relationships>");

        var all: std.ArrayList(zip.TestFile) = .empty;
        try all.append(a, .{ .name = "[Content_Types].xml", .data = ct.items });
        try all.append(a, .{ .name = "_rels/.rels", .data = root_rels.items });
        try all.append(a, .{ .name = "ppt/presentation.xml", .data = pres.items });
        try all.append(a, .{ .name = "ppt/_rels/presentation.xml.rels", .data = pres_rels.items });
        try all.append(a, .{ .name = "ppt/slideMasters/slideMaster1.xml", .data = master.items });
        try all.append(a, .{ .name = "ppt/slideMasters/_rels/slideMaster1.xml.rels", .data = master_rels.items });
        try all.append(a, .{ .name = "ppt/slideLayouts/slideLayout1.xml", .data = layout.items });
        try all.append(a, .{ .name = "ppt/slideLayouts/_rels/slideLayout1.xml.rels", .data = layout_rels.items });
        try all.append(a, .{ .name = "ppt/theme/theme1.xml", .data = theme.items });
        try all.appendSlice(a, files.items);
        return zipParts(gpa, all.items);
    }
};

test "colToRef" {
    var buf: [12]u8 = undefined;
    try testing.expectEqualStrings("A", colToRef(0, &buf));
    try testing.expectEqualStrings("Z", colToRef(25, &buf));
    try testing.expectEqualStrings("AA", colToRef(26, &buf));
    try testing.expectEqualStrings("BC", colToRef(54, &buf));
}

test "fmtNumber: integers stay integers" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("42", fmtNumber(&buf, 42.0));
    try testing.expectEqualStrings("-7", fmtNumber(&buf, -7.0));
    try testing.expectEqualStrings("0.125", fmtNumber(&buf, 0.125));
}
