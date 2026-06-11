//! Package validation — the `OpenXmlValidator` layer.
//!
//! The SDK validator checks a document against the full ECMA-376 schema
//! (6000 generated classes carry their own particle constraints). nanoxml
//! validates the structural layer those classes sit on: package shape,
//! content types, relationship integrity, XML well-formedness of every
//! part, expected root elements for known part types, and r:id-style
//! reference resolution. Diagnostics mirror `ValidationErrorInfo`
//! (description + part + severity).

const std = @import("std");
const dom = @import("dom.zig");
const opc = @import("opc.zig");
const xml = @import("xml.zig");

pub const Severity = enum { @"error", warning };

/// SDK `ValidationErrorInfo`.
pub const Diagnostic = struct {
    severity: Severity,
    /// Part the problem was found in; null for package-level issues.
    part: ?[]const u8,
    message: []const u8,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: []const Diagnostic,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn errorCount(self: *const Result) usize {
        var n: usize = 0;
        for (self.diagnostics) |d| {
            if (d.severity == .@"error") n += 1;
        }
        return n;
    }

    pub fn ok(self: *const Result) bool {
        return self.errorCount() == 0;
    }
};

const Ctx = struct {
    arena: std.mem.Allocator,
    diags: std.ArrayList(Diagnostic) = .empty,

    fn add(self: *Ctx, severity: Severity, part: ?[]const u8, comptime fmt: []const u8, args: anytype) !void {
        try self.diags.append(self.arena, .{
            .severity = severity,
            .part = if (part) |p| try self.arena.dupe(u8, p) else null,
            .message = try std.fmt.allocPrint(self.arena, fmt, args),
        });
    }
};

/// Root local names required for well-known content types.
const expected_roots = [_]struct { ct: []const u8, root: []const u8 }{
    .{ .ct = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml", .root = "document" },
    .{ .ct = "application/vnd.ms-word.document.macroEnabled.main+xml", .root = "document" },
    .{ .ct = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml", .root = "workbook" },
    .{ .ct = "application/vnd.ms-excel.sheet.macroEnabled.main+xml", .root = "workbook" },
    .{ .ct = "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml", .root = "worksheet" },
    .{ .ct = "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml", .root = "sst" },
    .{ .ct = "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml", .root = "styleSheet" },
    .{ .ct = "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml", .root = "presentation" },
    .{ .ct = "application/vnd.openxmlformats-officedocument.presentationml.slide+xml", .root = "sld" },
    .{ .ct = "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml", .root = "styles" },
    .{ .ct = "application/vnd.openxmlformats-officedocument.theme+xml", .root = "theme" },
    .{ .ct = "application/vnd.openxmlformats-package.core-properties+xml", .root = "coreProperties" },
    .{ .ct = "application/vnd.openxmlformats-package.relationships+xml", .root = "Relationships" },
};

/// SDK `OpenXmlValidator.Validate(package)`. Never mutates the package
/// beyond lazily extracting parts. Caller must `deinit` the Result.
pub fn validatePackage(gpa: std.mem.Allocator, pkg: *opc.Package) error{OutOfMemory}!Result {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var ctx: Ctx = .{ .arena = arena };

    const names = try pkg.partNames(arena);

    // ── Package shape ──────────────────────────────────────────────────
    if (!pkg.hasPart("[Content_Types].xml")) {
        try ctx.add(.@"error", null, "missing [Content_Types].xml", .{});
    }
    const main_part = pkg.partByRelType(null, opc.RelType.office_document) catch null;
    if (main_part == null) {
        try ctx.add(.@"error", "_rels/.rels", "package has no officeDocument relationship (no main part)", .{});
    }

    // ── Per-part checks ────────────────────────────────────────────────
    for (names) |name| {
        if (std.mem.eql(u8, name, "[Content_Types].xml")) continue;

        const ct = pkg.contentTypeOf(name);
        if (ct == null and !std.mem.endsWith(u8, name, ".rels")) {
            try ctx.add(.@"error", name, "part has no content type (no Default for its extension, no Override)", .{});
        }

        const effective_ct = ct orelse
            (if (std.mem.endsWith(u8, name, ".rels")) @as(?[]const u8, "application/vnd.openxmlformats-package.relationships+xml") else null) orelse
            continue;
        if (!isXmlContentType(effective_ct)) continue;

        const bytes = pkg.getPart(name) catch {
            try ctx.add(.@"error", name, "part cannot be extracted", .{});
            continue;
        };
        const root = dom.parse(arena, bytes) catch {
            try ctx.add(.@"error", name, "part is not well-formed XML", .{});
            continue;
        };

        for (expected_roots) |exp| {
            if (std.mem.eql(u8, effective_ct, exp.ct)) {
                if (!std.mem.eql(u8, root.localName(), exp.root)) {
                    try ctx.add(.@"error", name, "root element is <{s}>, expected <{s}> for content type {s}", .{ root.localName(), exp.root, exp.ct });
                }
                break;
            }
        }
    }

    // ── Relationship integrity ─────────────────────────────────────────
    var si: usize = 0;
    while (si <= names.len) : (si += 1) {
        const source: ?[]const u8 = if (si == 0) null else names[si - 1];
        if (source) |s| {
            if (std.mem.endsWith(u8, s, ".rels")) continue;
        }
        const rels = pkg.relationships(source) catch {
            try ctx.add(.@"error", source orelse "_rels/.rels", "relationships part is unreadable", .{});
            continue;
        };
        if (rels.len == 0) continue;

        const label = source orelse "(package root)";
        var seen = std.StringHashMap(void).init(gpa);
        defer seen.deinit();
        for (rels) |rel| {
            const gop = try seen.getOrPut(rel.id);
            if (gop.found_existing) {
                try ctx.add(.@"error", label, "duplicate relationship id \"{s}\"", .{rel.id});
            }
            if (rel.external) continue;
            const target = pkg.resolveTarget(source, rel) catch {
                try ctx.add(.@"error", label, "relationship \"{s}\" target cannot be resolved: {s}", .{ rel.id, rel.target });
                continue;
            };
            if (!pkg.hasPart(target)) {
                try ctx.add(.@"error", label, "relationship \"{s}\" points at missing part \"{s}\"", .{ rel.id, target });
            }
        }
    }

    // ── r:id reference resolution (semantic layer) ─────────────────────
    for (names) |name| {
        if (std.mem.endsWith(u8, name, ".rels")) continue;
        const ct = pkg.contentTypeOf(name) orelse continue;
        if (!isXmlContentType(ct)) continue;

        const rels = pkg.relationships(name) catch continue;
        var ids = std.StringHashMap(void).init(gpa);
        defer ids.deinit();
        for (rels) |rel| try ids.put(rel.id, {});

        const bytes = pkg.getPart(name) catch continue;
        const root = dom.parse(arena, bytes) catch continue;
        try checkRelRefs(&ctx, gpa, name, root, &ids);
    }

    const diags = try ctx.diags.toOwnedSlice(arena);
    return .{ .arena = arena_inst, .diagnostics = diags };
}

/// Attributes like r:id / r:embed / r:link hold relationship references.
fn checkRelRefs(
    ctx: *Ctx,
    gpa: std.mem.Allocator,
    part: []const u8,
    root: *dom.Element,
    ids: *std.StringHashMap(void),
) error{OutOfMemory}!void {
    var it = root.descendants(gpa, null);
    defer it.deinit();
    try checkElementRefs(ctx, part, root, ids);
    while (try it.next()) |el| {
        try checkElementRefs(ctx, part, el, ids);
    }
}

fn checkElementRefs(
    ctx: *Ctx,
    part: []const u8,
    el: *dom.Element,
    ids: *std.StringHashMap(void),
) error{OutOfMemory}!void {
    for (el.attrs.items) |a| {
        const colon = std.mem.indexOfScalar(u8, a.name, ':') orelse continue;
        if (!std.mem.eql(u8, a.name[0..colon], "r")) continue;
        const local = a.name[colon + 1 ..];
        const is_ref = std.mem.eql(u8, local, "id") or
            std.mem.eql(u8, local, "embed") or
            std.mem.eql(u8, local, "link");
        if (!is_ref) continue;
        if (!ids.contains(a.value)) {
            try ctx.add(.@"error", part, "<{s} {s}=\"{s}\"> references a relationship that does not exist", .{ el.name, a.name, a.value });
        }
    }
}

fn isXmlContentType(ct: []const u8) bool {
    return std.mem.endsWith(u8, ct, "+xml") or
        std.mem.eql(u8, ct, "application/xml") or
        std.mem.eql(u8, ct, "text/xml");
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const zip = @import("zip.zig");

const good_ct =
    \\<?xml version="1.0"?>
    \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    \\<Default Extension="xml" ContentType="application/xml"/>
    \\<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    \\<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    \\</Types>
;

const good_root_rels =
    \\<?xml version="1.0"?>
    \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \\<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    \\</Relationships>
;

test "valid minimal package produces zero errors" {
    const gpa = testing.allocator;
    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = good_ct },
        .{ .name = "_rels/.rels", .data = good_root_rels },
        .{ .name = "word/document.xml", .data = "<w:document><w:body/></w:document>" },
    });
    defer gpa.free(data);
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();

    var result = try validatePackage(gpa, &pkg);
    defer result.deinit();
    try testing.expect(result.ok());
}

test "detects malformed XML, dangling rels, duplicate ids, wrong root" {
    const gpa = testing.allocator;
    const bad_doc_rels =
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\<Relationship Id="rId1" Type="t" Target="missing/part.xml"/>
        \\<Relationship Id="rId1" Type="t" Target="also/missing.xml"/>
        \\</Relationships>
    ;
    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = good_ct },
        .{ .name = "_rels/.rels", .data = good_root_rels },
        // Wrong root for the declared wordprocessing content type.
        .{ .name = "word/document.xml", .data = "<w:wrongRoot/>" },
        .{ .name = "word/_rels/document.xml.rels", .data = bad_doc_rels },
        .{ .name = "broken.xml", .data = "<a><b></a>" },
    });
    defer gpa.free(data);
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();

    var result = try validatePackage(gpa, &pkg);
    defer result.deinit();

    var saw_malformed = false;
    var saw_dangling = false;
    var saw_duplicate = false;
    var saw_wrong_root = false;
    for (result.diagnostics) |d| {
        if (d.part != null and std.mem.eql(u8, d.part.?, "broken.xml")) saw_malformed = true;
        if (std.mem.indexOf(u8, d.message, "missing part") != null) saw_dangling = true;
        if (std.mem.indexOf(u8, d.message, "duplicate relationship id") != null) saw_duplicate = true;
        if (std.mem.indexOf(u8, d.message, "expected <document>") != null) saw_wrong_root = true;
    }
    try testing.expect(saw_malformed);
    try testing.expect(saw_dangling);
    try testing.expect(saw_duplicate);
    try testing.expect(saw_wrong_root);
    try testing.expect(!result.ok());
}

test "detects unresolved r:id references and missing main part" {
    const gpa = testing.allocator;
    const doc =
        \\<w:document xmlns:w="http://w" xmlns:r="http://r"><w:body><w:p><w:hyperlink r:id="rId99"/><a:blip r:embed="rId98"/></w:p></w:body></w:document>
    ;
    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = good_ct },
        // No officeDocument rel at all.
        .{ .name = "_rels/.rels", .data = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"/>" },
        .{ .name = "word/document.xml", .data = doc },
    });
    defer gpa.free(data);
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();

    var result = try validatePackage(gpa, &pkg);
    defer result.deinit();

    var unresolved: usize = 0;
    var no_main = false;
    for (result.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "references a relationship") != null) unresolved += 1;
        if (std.mem.indexOf(u8, d.message, "no officeDocument relationship") != null) no_main = true;
    }
    // rId99 (r:id) and rId98 (r:embed) both unresolved... but document.xml
    // has no .rels at all, so both flag.
    try testing.expectEqual(@as(usize, 2), unresolved);
    try testing.expect(no_main);
}

test "missing content type for an opaque part is flagged" {
    const gpa = testing.allocator;
    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = good_ct },
        .{ .name = "_rels/.rels", .data = good_root_rels },
        .{ .name = "word/document.xml", .data = "<w:document/>" },
        .{ .name = "media/odd.zzz", .data = "??" },
    });
    defer gpa.free(data);
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();

    var result = try validatePackage(gpa, &pkg);
    defer result.deinit();

    var saw = false;
    for (result.diagnostics) |d| {
        if (d.part != null and std.mem.eql(u8, d.part.?, "media/odd.zzz")) saw = true;
    }
    try testing.expect(saw);
}

test "builder output validates clean" {
    const gpa = testing.allocator;
    const ooxml = @import("ooxml.zig");

    var b = ooxml.DocumentBuilder.init(gpa);
    defer b.deinit();
    b.title = "validated";
    try b.addParagraph("hello validator");
    const bytes = try b.save(gpa);
    defer gpa.free(bytes);

    var pkg = try opc.Package.open(gpa, bytes);
    defer pkg.deinit();
    var result = try validatePackage(gpa, &pkg);
    defer result.deinit();

    for (result.diagnostics) |d| {
        std.debug.print("unexpected diagnostic: [{s}] {s}: {s}\n", .{ @tagName(d.severity), d.part orelse "-", d.message });
    }
    try testing.expect(result.ok());
}
