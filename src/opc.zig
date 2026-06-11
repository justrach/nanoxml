//! OPC (Open Packaging Conventions, ECMA-376 Part 2) — the package layer.
//!
//! This is the Zig equivalent of .NET's `System.IO.Packaging`: a ZIP archive
//! plus `[Content_Types].xml` (part content types) and `_rels/*.rels`
//! (typed relationships between parts). Open-XML-SDK sits on top of exactly
//! this model; so does `ooxml.zig`.
//!
//! Memory model: one arena owns every decompressed part and parsed string.
//! Parts are extracted lazily and cached, so repeated `getPart` is a hash
//! lookup. Relationship/content-type strings are zero-copy slices into the
//! cached part bytes whenever they contain no XML entities.

const std = @import("std");
const zip = @import("zip.zig");
const xml = @import("xml.zig");

pub const Error = error{
    PartNotFound,
    MalformedXml,
    OutOfMemory,
} || zip.Error || zip.WriteError;

pub const Relationship = struct {
    id: []const u8,
    type: []const u8,
    target: []const u8,
    external: bool,
};

pub const rel_ns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
pub const pkg_rel_ns = "http://schemas.openxmlformats.org/package/2006/relationships";

/// Well-known relationship types (the ones the typed layer needs).
pub const RelType = struct {
    pub const office_document = rel_ns ++ "/officeDocument";
    pub const worksheet = rel_ns ++ "/worksheet";
    pub const shared_strings = rel_ns ++ "/sharedStrings";
    pub const slide = rel_ns ++ "/slide";
    pub const styles = rel_ns ++ "/styles";
    pub const core_properties = pkg_rel_ns ++ "/metadata/core-properties";
};

/// docProps/core.xml — Open-XML-SDK's `PackageProperties`. All fields are
/// arena-owned decoded strings, null when absent.
pub const CoreProperties = struct {
    title: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    description: ?[]const u8 = null,
    last_modified_by: ?[]const u8 = null,
};

pub const Package = struct {
    arena: std.heap.ArenaAllocator,
    archive: zip.Archive,
    part_cache: std.StringHashMap([]const u8),
    rels_cache: std.StringHashMap([]Relationship),
    ct_default: std.StringHashMap([]const u8),
    ct_override: std.StringHashMap([]const u8),
    /// Parts replaced or added via `setPart`; `save` consults this.
    part_overrides: std.StringHashMap([]const u8),
    /// Names from `setPart` that don't exist in the source archive, in
    /// insertion order (so `save` output is deterministic).
    added_parts: std.ArrayList([]const u8),

    /// `data` is the whole package file; borrowed, must outlive the Package.
    pub fn open(gpa: std.mem.Allocator, data: []const u8) Error!Package {
        var self: Package = .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .archive = undefined,
            .part_cache = std.StringHashMap([]const u8).init(gpa),
            .rels_cache = std.StringHashMap([]Relationship).init(gpa),
            .ct_default = std.StringHashMap([]const u8).init(gpa),
            .ct_override = std.StringHashMap([]const u8).init(gpa),
            .part_overrides = std.StringHashMap([]const u8).init(gpa),
            .added_parts = .empty,
        };
        errdefer self.deinit();
        self.archive = try zip.Archive.open(gpa, data);
        try self.parseContentTypes();
        return self;
    }

    pub fn deinit(self: *Package) void {
        const gpa = self.part_cache.allocator;
        self.part_cache.deinit();
        self.rels_cache.deinit();
        self.ct_default.deinit();
        self.ct_override.deinit();
        self.part_overrides.deinit();
        if (self.archive.entries.len > 0 or self.archive.by_name.count() > 0)
            self.archive.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Decompressed bytes of a part. `name` has no leading slash
    /// (e.g. "word/document.xml"). Cached after first extraction.
    pub fn getPart(self: *Package, name: []const u8) Error![]const u8 {
        if (self.part_cache.get(name)) |bytes| return bytes;
        const entry = self.archive.find(name) orelse return Error.PartNotFound;
        const bytes = try self.archive.extractAlloc(self.arena.allocator(), entry, .{});
        try self.part_cache.put(entry.name, bytes);
        return bytes;
    }

    pub fn hasPart(self: *const Package, name: []const u8) bool {
        return self.archive.find(name) != null;
    }

    /// Replace a part's content, or add a brand-new part. Reads through
    /// `getPart` see the new bytes immediately; `save` persists them.
    pub fn setPart(self: *Package, name: []const u8, bytes: []const u8) Error!void {
        const arena = self.arena.allocator();
        const name_d = try arena.dupe(u8, name);
        const bytes_d = try arena.dupe(u8, bytes);
        if (self.archive.find(name) == null and !self.part_overrides.contains(name)) {
            try self.added_parts.append(arena, name_d);
        }
        try self.part_overrides.put(name_d, bytes_d);
        try self.part_cache.put(name_d, bytes_d);
    }

    /// Serialize the package back to a zip. Untouched entries are copied in
    /// their already-compressed form (no re-deflate); overridden and added
    /// parts are deflated fresh. Caller owns the returned bytes.
    pub fn save(self: *Package, gpa: std.mem.Allocator) Error![]u8 {
        var w = zip.Writer{};
        defer w.deinit(gpa);

        for (self.archive.entries) |*e| {
            // Directory placeholder entries carry no data; drop them.
            if (e.name.len > 0 and e.name[e.name.len - 1] == '/') continue;
            if (self.part_overrides.get(e.name)) |new_bytes| {
                try w.addFile(gpa, e.name, new_bytes, .deflate);
            } else {
                const comp = try self.archive.compressedData(e);
                try w.addRaw(gpa, e.name, e.method, e.crc32, e.uncompressed_size, comp);
            }
        }
        for (self.added_parts.items) |name| {
            try w.addFile(gpa, name, self.part_overrides.get(name).?, .deflate);
        }
        return w.finish(gpa);
    }

    /// Read docProps/core.xml (via its package relationship, else the
    /// conventional name). Missing part yields all-null properties.
    pub fn coreProperties(self: *Package) Error!CoreProperties {
        const part = (try self.partByRelType(null, RelType.core_properties)) orelse blk: {
            if (self.hasPart("docProps/core.xml")) break :blk "docProps/core.xml";
            return .{};
        };
        const bytes = try self.getPart(part);
        const arena = self.arena.allocator();

        var props: CoreProperties = .{};
        var p = xml.Parser.init(bytes);
        var current: ?*?[]const u8 = null;
        var acc: std.ArrayList(u8) = .empty;
        while (true) {
            const ev = p.next() catch return Error.MalformedXml;
            switch (ev) {
                .start => |st| {
                    const local = xml.localName(st.name);
                    current = if (std.mem.eql(u8, local, "title"))
                        &props.title
                    else if (std.mem.eql(u8, local, "subject"))
                        &props.subject
                    else if (std.mem.eql(u8, local, "creator"))
                        &props.creator
                    else if (std.mem.eql(u8, local, "description"))
                        &props.description
                    else if (std.mem.eql(u8, local, "lastModifiedBy"))
                        &props.last_modified_by
                    else
                        null;
                    acc.clearRetainingCapacity();
                    if (st.self_closing) current = null;
                },
                .end => {
                    if (current) |slot| {
                        slot.* = try arena.dupe(u8, acc.items);
                        current = null;
                    }
                },
                .text => |raw| if (current != null)
                    try xml.decodeAppend(&acc, arena, raw),
                .cdata => |raw| if (current != null)
                    try acc.appendSlice(arena, raw),
                .eof => break,
                else => {},
            }
        }
        acc.deinit(arena);
        return props;
    }

    /// Relationships of a part, or of the package itself when `source` is
    /// null. Returns an empty slice when the .rels part doesn't exist.
    pub fn relationships(self: *Package, source: ?[]const u8) Error![]const Relationship {
        const arena = self.arena.allocator();
        const rels_name = try relsPartName(arena, source);
        if (self.rels_cache.get(rels_name)) |cached| return cached;

        if (!self.hasPart(rels_name)) {
            const empty: []Relationship = &.{};
            try self.rels_cache.put(rels_name, empty);
            return empty;
        }
        const bytes = try self.getPart(rels_name);

        var list: std.ArrayList(Relationship) = .empty;
        var p = xml.Parser.init(bytes);
        while (true) {
            const ev = p.next() catch return Error.MalformedXml;
            switch (ev) {
                .start => |st| {
                    if (std.mem.eql(u8, xml.localName(st.name), "Relationship")) {
                        const id = st.attr("Id") orelse continue;
                        const ty = st.attr("Type") orelse continue;
                        const target = st.attr("Target") orelse continue;
                        const mode = st.attr("TargetMode");
                        try list.append(arena, .{
                            .id = try decodedDupe(arena, id),
                            .type = try decodedDupe(arena, ty),
                            .target = try decodedDupe(arena, target),
                            .external = mode != null and
                                std.ascii.eqlIgnoreCase(mode.?, "External"),
                        });
                    }
                },
                .eof => break,
                else => {},
            }
        }
        const rels = try list.toOwnedSlice(arena);
        try self.rels_cache.put(rels_name, rels);
        return rels;
    }

    /// Resolve a relationship target against its source part into a part
    /// name ("word/media/image1.png"). Asserts `rel.external == false`.
    pub fn resolveTarget(
        self: *Package,
        source: ?[]const u8,
        rel: Relationship,
    ) Error![]const u8 {
        std.debug.assert(!rel.external);
        const arena = self.arena.allocator();
        const base_dir = if (source) |s| dirOf(s) else "";
        return normalizePath(arena, base_dir, rel.target);
    }

    /// First relationship of `rel_type` from `source`, resolved to a part
    /// name. The Open-XML-SDK idiom `package.GetRelationshipsByType(...)`.
    pub fn partByRelType(
        self: *Package,
        source: ?[]const u8,
        rel_type: []const u8,
    ) Error!?[]const u8 {
        const rels = try self.relationships(source);
        for (rels) |rel| {
            if (rel.external) continue;
            if (std.mem.eql(u8, rel.type, rel_type))
                return try self.resolveTarget(source, rel);
        }
        return null;
    }

    /// Relationship by Id from `source`, resolved to a part name.
    pub fn partByRelId(
        self: *Package,
        source: ?[]const u8,
        rel_id: []const u8,
    ) Error!?[]const u8 {
        const rels = try self.relationships(source);
        for (rels) |rel| {
            if (rel.external) continue;
            if (std.mem.eql(u8, rel.id, rel_id))
                return try self.resolveTarget(source, rel);
        }
        return null;
    }

    /// Content type of a part: override first, then default-by-extension.
    pub fn contentTypeOf(self: *Package, name: []const u8) ?[]const u8 {
        // Overrides are keyed by "/name" per spec.
        var key_buf: [512]u8 = undefined;
        if (name.len + 1 <= key_buf.len) {
            key_buf[0] = '/';
            @memcpy(key_buf[1..][0..name.len], name);
            if (self.ct_override.get(key_buf[0 .. name.len + 1])) |ct| return ct;
        }
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
        var ext_buf: [64]u8 = undefined;
        const ext = name[dot + 1 ..];
        if (ext.len > ext_buf.len) return null;
        const ext_lower = std.ascii.lowerString(&ext_buf, ext);
        return self.ct_default.get(ext_lower);
    }

    fn parseContentTypes(self: *Package) Error!void {
        if (!self.hasPart("[Content_Types].xml")) return; // tolerated: plain zips
        const bytes = try self.getPart("[Content_Types].xml");
        const arena = self.arena.allocator();

        var p = xml.Parser.init(bytes);
        while (true) {
            const ev = p.next() catch return Error.MalformedXml;
            switch (ev) {
                .start => |st| {
                    const local = xml.localName(st.name);
                    if (std.mem.eql(u8, local, "Default")) {
                        const ext = st.attr("Extension") orelse continue;
                        const ct = st.attr("ContentType") orelse continue;
                        const ext_lower = try std.ascii.allocLowerString(arena, ext);
                        try self.ct_default.put(ext_lower, try decodedDupe(arena, ct));
                    } else if (std.mem.eql(u8, local, "Override")) {
                        const part = st.attr("PartName") orelse continue;
                        const ct = st.attr("ContentType") orelse continue;
                        try self.ct_override.put(
                            try decodedDupe(arena, part),
                            try decodedDupe(arena, ct),
                        );
                    }
                },
                .eof => break,
                else => {},
            }
        }
    }
};

/// "word/document.xml" -> "word/_rels/document.xml.rels"; null -> "_rels/.rels"
fn relsPartName(arena: std.mem.Allocator, source: ?[]const u8) ![]const u8 {
    const s = source orelse return "_rels/.rels";
    const dir = dirOf(s);
    const base = s[dir.len + @intFromBool(dir.len > 0) ..];
    if (dir.len == 0)
        return std.fmt.allocPrint(arena, "_rels/{s}.rels", .{base});
    return std.fmt.allocPrint(arena, "{s}/_rels/{s}.rels", .{ dir, base });
}

fn dirOf(name: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return "";
    return name[0..slash];
}

/// Join + normalize an OPC target against a base directory; output has no
/// leading slash. Handles absolute targets ("/word/x.xml"), "." and "..".
fn normalizePath(
    arena: std.mem.Allocator,
    base_dir: []const u8,
    target: []const u8,
) ![]const u8 {
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(arena);

    const absolute = target.len > 0 and target[0] == '/';
    if (!absolute and base_dir.len > 0) {
        var it = std.mem.splitScalar(u8, base_dir, '/');
        while (it.next()) |seg| {
            if (seg.len > 0) try segs.append(arena, seg);
        }
    }
    var it = std.mem.splitScalar(u8, target, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            _ = segs.pop();
            continue;
        }
        try segs.append(arena, seg);
    }

    var total: usize = 0;
    for (segs.items) |seg| total += seg.len + 1;
    if (total == 0) return "";
    var out = try arena.alloc(u8, total - 1);
    var pos: usize = 0;
    for (segs.items, 0..) |seg, i| {
        if (i > 0) {
            out[pos] = '/';
            pos += 1;
        }
        @memcpy(out[pos..][0..seg.len], seg);
        pos += seg.len;
    }
    return out;
}

/// Zero-copy when no entities; otherwise decode into the arena.
fn decodedDupe(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (xml.indexOfBytePos(raw, 0, '&') == null) return raw;
    var list: std.ArrayList(u8) = .empty;
    try xml.decodeAppend(&list, arena, raw);
    return list.toOwnedSlice(arena);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const ct_xml =
    \\<?xml version="1.0"?>
    \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    \\<Default Extension="xml" ContentType="application/xml"/>
    \\<Default Extension="PNG" ContentType="image/png"/>
    \\<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    \\<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    \\</Types>
;

const root_rels =
    \\<?xml version="1.0"?>
    \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \\<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    \\</Relationships>
;

const doc_rels =
    \\<?xml version="1.0"?>
    \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    \\<Relationship Id="rId7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/>
    \\<Relationship Id="rId8" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com/?a=1&amp;b=2" TargetMode="External"/>
    \\</Relationships>
;

fn testPackage(gpa: std.mem.Allocator) ![]u8 {
    return zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = ct_xml },
        .{ .name = "_rels/.rels", .data = root_rels },
        .{ .name = "word/document.xml", .data = "<w:document><w:body/></w:document>" },
        .{ .name = "word/_rels/document.xml.rels", .data = doc_rels },
        .{ .name = "media/image1.png", .data = "\x89PNG fake" },
    });
}

test "content types: overrides and case-insensitive default extensions" {
    const gpa = testing.allocator;
    const data = try testPackage(gpa);
    defer gpa.free(data);

    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    try testing.expectEqualStrings(
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
        pkg.contentTypeOf("word/document.xml").?,
    );
    try testing.expectEqualStrings(
        "application/vnd.openxmlformats-package.relationships+xml",
        pkg.contentTypeOf("_rels/.rels").?,
    );
    try testing.expectEqualStrings("image/png", pkg.contentTypeOf("media/image1.png").?);
    try testing.expect(pkg.contentTypeOf("no-extension") == null);
}

test "relationship traversal and target resolution" {
    const gpa = testing.allocator;
    const data = try testPackage(gpa);
    defer gpa.free(data);

    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    // Package root -> main document part (the WordprocessingDocument.Open path).
    const main_part = (try pkg.partByRelType(null, RelType.office_document)).?;
    try testing.expectEqualStrings("word/document.xml", main_part);

    // Part-level rels: "../media/image1.png" relative to word/ -> media/image1.png
    const rels = try pkg.relationships(main_part);
    try testing.expectEqual(@as(usize, 2), rels.len);
    const img = try pkg.resolveTarget(main_part, rels[0]);
    try testing.expectEqualStrings("media/image1.png", img);
    try testing.expect(pkg.hasPart(img));

    // External rel: never resolved, entity decoded.
    try testing.expect(rels[1].external);
    try testing.expectEqualStrings("https://example.com/?a=1&b=2", rels[1].target);

    // Cached: same slice identity on second call.
    const rels2 = try pkg.relationships(main_part);
    try testing.expectEqual(rels.ptr, rels2.ptr);
}

test "part cache returns identical slices" {
    const gpa = testing.allocator;
    const data = try testPackage(gpa);
    defer gpa.free(data);

    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    const a = try pkg.getPart("word/document.xml");
    const b = try pkg.getPart("word/document.xml");
    try testing.expectEqual(a.ptr, b.ptr);
    try testing.expectError(Error.PartNotFound, pkg.getPart("nope.xml"));
}

// ── Spec edge cases ────────────────────────────────────────────────────────

test "plain zip without content types still opens" {
    const gpa = testing.allocator;
    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "a.xml", .data = "<a/>" },
    });
    defer gpa.free(data);

    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();
    try testing.expect(pkg.contentTypeOf("a.xml") == null);
    try testing.expectEqualStrings("<a/>", try pkg.getPart("a.xml"));
}

test "missing .rels yields empty relationships (and is cached)" {
    const gpa = testing.allocator;
    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "word/document.xml", .data = "<w:document/>" },
    });
    defer gpa.free(data);

    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();
    const rels = try pkg.relationships("word/document.xml");
    try testing.expectEqual(@as(usize, 0), rels.len);
    const again = try pkg.relationships("word/document.xml");
    try testing.expectEqual(@as(usize, 0), again.len);
    try testing.expect(try pkg.partByRelType(null, RelType.office_document) == null);
}

test "target resolution: absolute, dot, and over-popped dotdot" {
    const gpa = testing.allocator;
    const data = try testPackage(gpa);
    defer gpa.free(data);
    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    const src: ?[]const u8 = "word/document.xml";
    const abs = try pkg.resolveTarget(src, .{
        .id = "r1",
        .type = "t",
        .target = "/media/x.png",
        .external = false,
    });
    try testing.expectEqualStrings("media/x.png", abs);

    const dotted = try pkg.resolveTarget(src, .{
        .id = "r2",
        .type = "t",
        .target = "./media/y.png",
        .external = false,
    });
    try testing.expectEqualStrings("word/media/y.png", dotted);

    // ".." past the package root clamps at the root rather than erroring —
    // matches lenient consumer behavior.
    const over = try pkg.resolveTarget(src, .{
        .id = "r3",
        .type = "t",
        .target = "../../a.xml",
        .external = false,
    });
    try testing.expectEqualStrings("a.xml", over);
}

test "override takes precedence over default extension type" {
    const gpa = testing.allocator;
    const ct_both =
        \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        \\<Default Extension="xml" ContentType="application/xml"/>
        \\<Override PartName="/special.xml" ContentType="application/x-special"/>
        \\</Types>
    ;
    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = ct_both },
        .{ .name = "special.xml", .data = "<s/>" },
        .{ .name = "plain.xml", .data = "<p/>" },
    });
    defer gpa.free(data);

    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();
    try testing.expectEqualStrings("application/x-special", pkg.contentTypeOf("special.xml").?);
    try testing.expectEqualStrings("application/xml", pkg.contentTypeOf("plain.xml").?);
}

test "partByRelId resolves and missing id is null" {
    const gpa = testing.allocator;
    const data = try testPackage(gpa);
    defer gpa.free(data);
    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    const part = (try pkg.partByRelId(null, "rId1")).?;
    try testing.expectEqualStrings("word/document.xml", part);
    try testing.expect(try pkg.partByRelId(null, "rId99") == null);
}
