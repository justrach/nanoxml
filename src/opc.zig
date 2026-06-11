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
const dom = @import("dom.zig");

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
pub const dc_ns = "http://purl.org/dc/elements/1.1/";
pub const cp_ns = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties";

/// Well-known relationship types (the ones the typed layer needs).
pub const RelType = struct {
    pub const office_document = rel_ns ++ "/officeDocument";
    pub const worksheet = rel_ns ++ "/worksheet";
    pub const shared_strings = rel_ns ++ "/sharedStrings";
    pub const slide = rel_ns ++ "/slide";
    pub const styles = rel_ns ++ "/styles";
    pub const hyperlink = rel_ns ++ "/hyperlink";
    pub const image = rel_ns ++ "/image";
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
    /// Parts removed via `deletePart`; consulted by getPart/hasPart/save.
    deleted_parts: std.StringHashMap(void),
    /// .rels part names whose relationship lists were mutated and need
    /// re-serialization on save.
    dirty_rels: std.StringHashMap(void),
    /// Content-type tables mutated (addPart/deletePart/setContentType).
    ct_dirty: bool = false,
    /// Set by `clone`: package bytes owned by this Package, freed in deinit.
    owned_data: ?[]const u8 = null,

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
            .deleted_parts = std.StringHashMap(void).init(gpa),
            .dirty_rels = std.StringHashMap(void).init(gpa),
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
        self.deleted_parts.deinit();
        self.dirty_rels.deinit();
        if (self.archive.entries.len > 0 or self.archive.by_name.count() > 0)
            self.archive.deinit(gpa);
        if (self.owned_data) |d| gpa.free(d);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Decompressed bytes of a part. `name` has no leading slash
    /// (e.g. "word/document.xml"). Cached after first extraction.
    pub fn getPart(self: *Package, name: []const u8) Error![]const u8 {
        if (self.deleted_parts.contains(name)) return Error.PartNotFound;
        if (self.part_cache.get(name)) |bytes| return bytes;
        const entry = self.archive.find(name) orelse return Error.PartNotFound;
        const bytes = try self.archive.extractAlloc(self.arena.allocator(), entry, .{});
        try self.part_cache.put(entry.name, bytes);
        return bytes;
    }

    pub fn hasPart(self: *const Package, name: []const u8) bool {
        if (self.deleted_parts.contains(name)) return false;
        return self.archive.find(name) != null or self.part_overrides.contains(name);
    }

    /// Replace a part's content, or add a brand-new part. Reads through
    /// `getPart` see the new bytes immediately; `save` persists them.
    pub fn setPart(self: *Package, name: []const u8, bytes: []const u8) Error!void {
        try self.setPartInternal(name, bytes);
        // Hand-written .rels content invalidates any parsed/mutated list.
        if (std.mem.endsWith(u8, name, ".rels")) {
            _ = self.rels_cache.remove(name);
            _ = self.dirty_rels.remove(name);
        }
    }

    /// setPart without the .rels-cache invalidation (used by the flushers,
    /// whose caches are the source of truth).
    fn setPartInternal(self: *Package, name: []const u8, bytes: []const u8) Error!void {
        const arena = self.arena.allocator();
        const name_d = try arena.dupe(u8, name);
        const bytes_d = try arena.dupe(u8, bytes);
        if (self.archive.find(name) == null and !self.part_overrides.contains(name)) {
            try self.added_parts.append(arena, name_d);
        }
        try self.part_overrides.put(name_d, bytes_d);
        try self.part_cache.put(name_d, bytes_d);
        _ = self.deleted_parts.remove(name);
    }

    /// SDK `DeletePart`: removes the part, its own .rels part, its
    /// content-type override, and every relationship in the package that
    /// targets it.
    pub fn deletePart(self: *Package, name: []const u8) Error!void {
        if (!self.hasPart(name)) return Error.PartNotFound;
        const arena = self.arena.allocator();

        const own_rels = try relsPartName(arena, name);
        if (self.hasPart(own_rels)) {
            try self.deleted_parts.put(own_rels, {});
            _ = self.rels_cache.remove(own_rels);
            _ = self.dirty_rels.remove(own_rels);
        }
        try self.deleted_parts.put(try arena.dupe(u8, name), {});

        const ct_key = try std.mem.concat(arena, u8, &.{ "/", name });
        if (self.ct_override.remove(ct_key)) self.ct_dirty = true;

        try self.removeRelationshipsTo(name);
    }

    /// All live part names: archive order, then added parts. Arena-owned.
    pub fn partNames(self: *const Package, gpa: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(gpa);
        for (self.archive.entries) |*e| {
            if (e.name.len > 0 and e.name[e.name.len - 1] == '/') continue;
            if (self.deleted_parts.contains(e.name)) continue;
            try list.append(gpa, e.name);
        }
        for (self.added_parts.items) |name| {
            if (self.deleted_parts.contains(name)) continue;
            try list.append(gpa, name);
        }
        return list.toOwnedSlice(gpa);
    }

    /// Serialize pending relationship/content-type mutations into their
    /// backing parts without producing a zip (the in-memory half of SDK
    /// `Save()`). Idempotent; `save` calls this automatically.
    pub fn flush(self: *Package) Error!void {
        try self.flushRels();
        try self.flushContentTypes();
    }

    /// Serialize the package back to a zip. Untouched entries are copied in
    /// their already-compressed form (no re-deflate); overridden and added
    /// parts are deflated fresh. Caller owns the returned bytes.
    pub fn save(self: *Package, gpa: std.mem.Allocator) Error![]u8 {
        try self.flush();

        var w = zip.Writer{};
        defer w.deinit(gpa);

        for (self.archive.entries) |*e| {
            // Directory placeholder entries carry no data; drop them.
            if (e.name.len > 0 and e.name[e.name.len - 1] == '/') continue;
            if (self.deleted_parts.contains(e.name)) continue;
            if (self.part_overrides.get(e.name)) |new_bytes| {
                try w.addFile(gpa, e.name, new_bytes, .deflate);
            } else {
                const comp = try self.archive.compressedData(e);
                try w.addRaw(gpa, e.name, e.method, e.crc32, e.uncompressed_size, comp);
            }
        }
        for (self.added_parts.items) |name| {
            if (self.deleted_parts.contains(name)) continue;
            try w.addFile(gpa, name, self.part_overrides.get(name).?, .deflate);
        }
        return w.finish(gpa);
    }

    /// SDK `Clone`: an independent in-memory copy reflecting all pending
    /// mutations. The clone owns its own backing bytes.
    pub fn clone(self: *Package, gpa: std.mem.Allocator) Error!Package {
        const bytes = try self.save(gpa);
        errdefer gpa.free(bytes);
        var pkg = try Package.open(gpa, bytes);
        pkg.owned_data = bytes;
        return pkg;
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

    /// SDK `PackageProperties` setter: write non-null fields into
    /// docProps/core.xml, preserving any properties we don't model. Creates
    /// the part (plus content type and package relationship) when missing.
    pub fn setCoreProperties(self: *Package, props: CoreProperties) Error!void {
        const arena = self.arena.allocator();
        const existing = (try self.partByRelType(null, RelType.core_properties)) orelse
            (if (self.hasPart("docProps/core.xml")) @as(?[]const u8, "docProps/core.xml") else null);

        const part_name = existing orelse "docProps/core.xml";
        var root: *dom.Element = undefined;
        if (existing != null) {
            root = dom.parse(arena, try self.getPart(part_name)) catch return Error.MalformedXml;
        } else {
            root = try dom.Element.create(arena, "cp:coreProperties");
            try root.addNamespaceDeclaration(arena, "cp", cp_ns);
            try root.addNamespaceDeclaration(arena, "dc", dc_ns);
            try root.addNamespaceDeclaration(arena, "dcterms", "http://purl.org/dc/terms/");
        }

        if (props.title) |v| try setProp(arena, root, "title", dc_ns, "dc", v);
        if (props.subject) |v| try setProp(arena, root, "subject", dc_ns, "dc", v);
        if (props.creator) |v| try setProp(arena, root, "creator", dc_ns, "dc", v);
        if (props.description) |v| try setProp(arena, root, "description", dc_ns, "dc", v);
        if (props.last_modified_by) |v| try setProp(arena, root, "lastModifiedBy", cp_ns, "cp", v);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(arena);
        try dom.serialize(root, arena, &out, .{});
        try self.setPart(part_name, out.items);

        if (existing == null) {
            try self.setContentTypeOverride(part_name, "application/vnd.openxmlformats-package.core-properties+xml");
            _ = try self.addRelationship(null, .{
                .type = RelType.core_properties,
                .target = part_name,
            });
        }
    }

    // ── Relationships ──────────────────────────────────────────────────

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

    pub const AddRelOptions = struct {
        type: []const u8,
        /// Internal: part name (resolved against the package root, written
        /// as an absolute "/name" target). External: URI, kept verbatim.
        target: []const u8,
        external: bool = false,
        /// Explicit id; default allocates the next free "rIdN".
        id: ?[]const u8 = null,
    };

    /// SDK `AddNewPart`/`AddExternalRelationship` relationship half: append
    /// a relationship from `source` (null = package root) and return its id.
    /// The .rels part is re-serialized on save.
    pub fn addRelationship(self: *Package, source: ?[]const u8, opts: AddRelOptions) Error![]const u8 {
        const arena = self.arena.allocator();
        const existing = try self.relationships(source);

        const id = if (opts.id) |i| try arena.dupe(u8, i) else try self.nextRelId(arena, existing);
        const target = if (opts.external)
            try arena.dupe(u8, opts.target)
        else
            try std.mem.concat(arena, u8, &.{ "/", std.mem.trimStart(u8, opts.target, "/") });

        var list = try arena.alloc(Relationship, existing.len + 1);
        @memcpy(list[0..existing.len], existing);
        list[existing.len] = .{
            .id = id,
            .type = try arena.dupe(u8, opts.type),
            .target = target,
            .external = opts.external,
        };

        const rels_name = try relsPartName(arena, source);
        try self.rels_cache.put(rels_name, list);
        try self.dirty_rels.put(rels_name, {});
        return id;
    }

    /// SDK `AddExternalRelationship`.
    pub fn addExternalRelationship(self: *Package, source: ?[]const u8, rel_type: []const u8, uri: []const u8) Error![]const u8 {
        return self.addRelationship(source, .{ .type = rel_type, .target = uri, .external = true });
    }

    /// SDK `AddHyperlinkRelationship` (always external).
    pub fn addHyperlinkRelationship(self: *Package, source: ?[]const u8, uri: []const u8) Error![]const u8 {
        return self.addRelationship(source, .{ .type = RelType.hyperlink, .target = uri, .external = true });
    }

    /// SDK `DeleteReferenceRelationship`/`DeleteExternalRelationship`.
    /// Returns NotFound error when no relationship has `id`.
    pub fn removeRelationship(self: *Package, source: ?[]const u8, id: []const u8) Error!void {
        const arena = self.arena.allocator();
        const existing = try self.relationships(source);
        const idx = for (existing, 0..) |rel, i| {
            if (std.mem.eql(u8, rel.id, id)) break i;
        } else return Error.PartNotFound;

        var list = try arena.alloc(Relationship, existing.len - 1);
        @memcpy(list[0..idx], existing[0..idx]);
        @memcpy(list[idx..], existing[idx + 1 ..]);

        const rels_name = try relsPartName(arena, source);
        try self.rels_cache.put(rels_name, list);
        try self.dirty_rels.put(rels_name, {});
    }

    /// Drop every internal relationship (from any source) resolving to
    /// `target_part`.
    fn removeRelationshipsTo(self: *Package, target_part: []const u8) Error!void {
        const arena = self.arena.allocator();
        const names = try self.partNames(arena);

        // Package root first, then every part that could own relationships.
        var si: usize = 0;
        while (si <= names.len) : (si += 1) {
            const source: ?[]const u8 = if (si == 0) null else names[si - 1];
            if (source) |s| {
                if (std.mem.endsWith(u8, s, ".rels")) continue;
            }
            const rels = self.relationships(source) catch continue;
            if (rels.len == 0) continue;

            var keep: std.ArrayList(Relationship) = .empty;
            var changed = false;
            for (rels) |rel| {
                const matches = !rel.external and blk: {
                    const resolved = self.resolveTarget(source, rel) catch break :blk false;
                    break :blk std.mem.eql(u8, resolved, target_part);
                };
                if (matches) {
                    changed = true;
                } else {
                    try keep.append(arena, rel);
                }
            }
            if (changed) {
                const rels_name = try relsPartName(arena, source);
                try self.rels_cache.put(rels_name, try keep.toOwnedSlice(arena));
                try self.dirty_rels.put(rels_name, {});
            } else {
                keep.deinit(arena);
            }
        }
    }

    fn nextRelId(self: *Package, arena: std.mem.Allocator, rels: []const Relationship) Error![]const u8 {
        _ = self;
        var max: usize = 0;
        for (rels) |rel| {
            if (std.mem.startsWith(u8, rel.id, "rId")) {
                const n = std.fmt.parseInt(usize, rel.id[3..], 10) catch continue;
                if (n > max) max = n;
            }
        }
        return std.fmt.allocPrint(arena, "rId{d}", .{max + 1});
    }

    /// Re-serialize every mutated .rels part into the part tables.
    fn flushRels(self: *Package) Error!void {
        if (self.dirty_rels.count() == 0) return;
        const arena = self.arena.allocator();

        // Collect keys first: setPartInternal mutates unrelated tables only,
        // but iterating while inserting into dirty_rels' sibling maps is
        // safest done off a snapshot.
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(arena);
        var it = self.dirty_rels.keyIterator();
        while (it.next()) |k| try names.append(arena, k.*);

        for (names.items) |rels_name| {
            const rels = self.rels_cache.get(rels_name) orelse continue;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(arena);
            var w = xml.Writer.init(arena, &out);
            defer w.deinit();
            try w.writeDeclaration();
            try w.startElement("Relationships");
            try wattr(&w, "xmlns", pkg_rel_ns);
            for (rels) |rel| {
                try w.startElement("Relationship");
                try wattr(&w, "Id", rel.id);
                try wattr(&w, "Type", rel.type);
                try wattr(&w, "Target", rel.target);
                if (rel.external) try wattr(&w, "TargetMode", "External");
                try wend(&w);
            }
            try wend(&w);
            w.end() catch unreachable;
            try self.setPartInternal(rels_name, out.items);
        }
        self.dirty_rels.clearRetainingCapacity();
    }

    // ── Content types ──────────────────────────────────────────────────

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

    /// Register an Override content type for a part ([Content_Types].xml is
    /// regenerated on save). SDK: the content-type half of `AddNewPart` /
    /// `ChangeDocumentType`.
    pub fn setContentTypeOverride(self: *Package, part_name: []const u8, content_type: []const u8) Error!void {
        const arena = self.arena.allocator();
        const key = try std.mem.concat(arena, u8, &.{ "/", part_name });
        try self.ct_override.put(key, try arena.dupe(u8, content_type));
        self.ct_dirty = true;
    }

    /// Register a Default (by-extension) content type.
    pub fn setContentTypeDefault(self: *Package, extension: []const u8, content_type: []const u8) Error!void {
        const arena = self.arena.allocator();
        const ext_lower = try std.ascii.allocLowerString(arena, extension);
        try self.ct_default.put(ext_lower, try arena.dupe(u8, content_type));
        self.ct_dirty = true;
    }

    pub const AddPartOptions = struct {
        content_type: ?[]const u8 = null,
        /// When set, also add a relationship of this type pointing at the
        /// new part.
        rel_type: ?[]const u8 = null,
        /// Source part for that relationship (null = package root).
        rel_source: ?[]const u8 = null,
    };

    /// SDK `AddNewPart` + `FeedData` in one call: store bytes, register the
    /// content type, and optionally wire up a relationship. Returns the
    /// relationship id when one was created.
    pub fn addPart(self: *Package, name: []const u8, bytes: []const u8, opts: AddPartOptions) Error!?[]const u8 {
        try self.setPart(name, bytes);
        if (opts.content_type) |ct| {
            // Media types conventionally use Defaults; keep it simple and
            // always write an exact Override, which takes precedence.
            try self.setContentTypeOverride(name, ct);
        }
        if (opts.rel_type) |rt| {
            return try self.addRelationship(opts.rel_source, .{ .type = rt, .target = name });
        }
        return null;
    }

    /// Regenerate [Content_Types].xml from the live tables (sorted, so
    /// output is deterministic).
    fn flushContentTypes(self: *Package) Error!void {
        if (!self.ct_dirty) return;
        const arena = self.arena.allocator();

        var exts: std.ArrayList([]const u8) = .empty;
        defer exts.deinit(arena);
        var dit = self.ct_default.keyIterator();
        while (dit.next()) |k| try exts.append(arena, k.*);
        std.mem.sort([]const u8, exts.items, {}, strLess);

        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(arena);
        var oit = self.ct_override.keyIterator();
        while (oit.next()) |k| try parts.append(arena, k.*);
        std.mem.sort([]const u8, parts.items, {}, strLess);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(arena);
        var w = xml.Writer.init(arena, &out);
        defer w.deinit();
        try w.writeDeclaration();
        try w.startElement("Types");
        try wattr(&w, "xmlns", "http://schemas.openxmlformats.org/package/2006/content-types");
        for (exts.items) |ext| {
            try w.startElement("Default");
            try wattr(&w, "Extension", ext);
            try wattr(&w, "ContentType", self.ct_default.get(ext).?);
            try wend(&w);
        }
        for (parts.items) |part| {
            try w.startElement("Override");
            try wattr(&w, "PartName", part);
            try wattr(&w, "ContentType", self.ct_override.get(part).?);
            try wend(&w);
        }
        try wend(&w);
        w.end() catch unreachable;

        try self.setPartInternal("[Content_Types].xml", out.items);
        self.ct_dirty = false;
    }

    // ── Resolution ─────────────────────────────────────────────────────

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

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// xml.Writer calls in straight-line generator code can only fail on OOM;
/// the state errors are statically impossible. Narrow the error set.
fn wattr(w: *xml.Writer, name: []const u8, value: []const u8) error{OutOfMemory}!void {
    w.attribute(name, value) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidState, error.Unbalanced => unreachable,
    };
}

fn wend(w: *xml.Writer) error{OutOfMemory}!void {
    w.endElement() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidState, error.Unbalanced => unreachable,
    };
}

/// Update-or-create a core-property element, reusing the document's
/// declared prefix for `ns_uri` (falling back to declaring `fallback_pfx`).
fn setProp(
    arena: std.mem.Allocator,
    root: *dom.Element,
    local: []const u8,
    ns_uri: []const u8,
    fallback_pfx: []const u8,
    value: []const u8,
) !void {
    if (root.child(local)) |el| {
        try el.setText(arena, value);
        return;
    }
    var pfx = root.lookupPrefix(ns_uri);
    if (pfx == null) {
        try root.addNamespaceDeclaration(arena, fallback_pfx, ns_uri);
        pfx = fallback_pfx;
    }
    const name = if (pfx.?.len == 0)
        try arena.dupe(u8, local)
    else
        try std.mem.concat(arena, u8, &.{ pfx.?, ":", local });
    const el = try root.appendElement(arena, name);
    try el.setText(arena, value);
}

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

test "deletePart removes part, its rels, CT override, and inbound rels" {
    const gpa = testing.allocator;
    const data = try testPackage(gpa);
    defer gpa.free(data);
    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    try pkg.deletePart("word/document.xml");
    try testing.expect(!pkg.hasPart("word/document.xml"));
    try testing.expect(!pkg.hasPart("word/_rels/document.xml.rels"));
    try testing.expectError(Error.PartNotFound, pkg.getPart("word/document.xml"));
    try testing.expectError(Error.PartNotFound, pkg.deletePart("word/document.xml"));

    const saved = try pkg.save(gpa);
    defer gpa.free(saved);
    var pkg2 = try Package.open(gpa, saved);
    defer pkg2.deinit();

    try testing.expect(!pkg2.hasPart("word/document.xml"));
    try testing.expect(pkg2.hasPart("media/image1.png"));
    // The package-level officeDocument relationship pointed at it: gone.
    try testing.expectEqual(@as(?[]const u8, null), try pkg2.partByRelType(null, RelType.office_document));
    // Its CT override is gone: name-based lookup falls back to the
    // .xml extension default rather than the wordprocessing main type.
    try testing.expectEqualStrings("application/xml", pkg2.contentTypeOf("word/document.xml").?);
    // Defaults survive.
    try testing.expectEqualStrings("image/png", pkg2.contentTypeOf("media/image1.png").?);
}

test "addPart registers content type and relationship; round-trips" {
    const gpa = testing.allocator;
    const data = try testPackage(gpa);
    defer gpa.free(data);
    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    const rid = (try pkg.addPart("word/styles.xml", "<w:styles/>", .{
        .content_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml",
        .rel_type = RelType.styles,
        .rel_source = "word/document.xml",
    })).?;
    try testing.expect(std.mem.startsWith(u8, rid, "rId"));

    const saved = try pkg.save(gpa);
    defer gpa.free(saved);
    var pkg2 = try Package.open(gpa, saved);
    defer pkg2.deinit();

    try testing.expectEqualStrings("<w:styles/>", try pkg2.getPart("word/styles.xml"));
    try testing.expectEqualStrings(
        "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml",
        pkg2.contentTypeOf("word/styles.xml").?,
    );
    const styles_part = (try pkg2.partByRelType("word/document.xml", RelType.styles)).?;
    try testing.expectEqualStrings("word/styles.xml", styles_part);
    // Pre-existing rels on the same source survived the regeneration.
    const img = (try pkg2.partByRelType("word/document.xml", RelType.image)).?;
    try testing.expectEqualStrings("media/image1.png", img);
}

test "external + hyperlink relationships round-trip with TargetMode" {
    const gpa = testing.allocator;
    const data = try testPackage(gpa);
    defer gpa.free(data);
    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    const hl_id = try pkg.addHyperlinkRelationship("word/document.xml", "https://ziglang.org/?q=a&b=c");
    _ = try pkg.addExternalRelationship(null, "http://example.com/custom", "file:///tmp/x");

    const saved = try pkg.save(gpa);
    defer gpa.free(saved);
    var pkg2 = try Package.open(gpa, saved);
    defer pkg2.deinit();

    const rels = try pkg2.relationships("word/document.xml");
    var found = false;
    for (rels) |rel| {
        if (std.mem.eql(u8, rel.id, hl_id)) {
            try testing.expect(rel.external);
            try testing.expectEqualStrings(RelType.hyperlink, rel.type);
            try testing.expectEqualStrings("https://ziglang.org/?q=a&b=c", rel.target);
            found = true;
        }
    }
    try testing.expect(found);

    const root = try pkg2.relationships(null);
    var ext_count: usize = 0;
    for (root) |rel| {
        if (rel.external) ext_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), ext_count);
}

test "removeRelationship drops exactly the given id" {
    const gpa = testing.allocator;
    const data = try testPackage(gpa);
    defer gpa.free(data);
    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    try pkg.removeRelationship("word/document.xml", "rId8");
    try testing.expectError(Error.PartNotFound, pkg.removeRelationship("word/document.xml", "rId8"));

    const saved = try pkg.save(gpa);
    defer gpa.free(saved);
    var pkg2 = try Package.open(gpa, saved);
    defer pkg2.deinit();

    const rels = try pkg2.relationships("word/document.xml");
    try testing.expectEqual(@as(usize, 1), rels.len);
    try testing.expectEqualStrings("rId7", rels[0].id);
}

test "nextRelId skips past the existing maximum" {
    const gpa = testing.allocator;
    const data = try testPackage(gpa);
    defer gpa.free(data);
    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    // doc rels already hold rId7/rId8 — a fresh id must not collide.
    const id = try pkg.addRelationship("word/document.xml", .{
        .type = RelType.styles,
        .target = "word/styles.xml",
    });
    try testing.expectEqualStrings("rId9", id);
}

test "setCoreProperties updates existing part and preserves unknown props" {
    const gpa = testing.allocator;
    const core =
        \\<?xml version="1.0"?>
        \\<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>old</dc:title><dcterms:created xsi:type="dcterms:W3CDTF">2024-01-01T00:00:00Z</dcterms:created></cp:coreProperties>
    ;
    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = ct_xml },
        .{ .name = "_rels/.rels", .data = root_rels },
        .{ .name = "word/document.xml", .data = "<w:document/>" },
        .{ .name = "docProps/core.xml", .data = core },
    });
    defer gpa.free(data);
    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    try pkg.setCoreProperties(.{ .title = "new title", .creator = "nanoxml" });

    const saved = try pkg.save(gpa);
    defer gpa.free(saved);
    var pkg2 = try Package.open(gpa, saved);
    defer pkg2.deinit();

    const props = try pkg2.coreProperties();
    try testing.expectEqualStrings("new title", props.title.?);
    try testing.expectEqualStrings("nanoxml", props.creator.?);
    // The dcterms:created element we don't model survived.
    const bytes = try pkg2.getPart("docProps/core.xml");
    try testing.expect(std.mem.indexOf(u8, bytes, "2024-01-01T00:00:00Z") != null);
}

test "setCoreProperties creates part, content type, and rel when missing" {
    const gpa = testing.allocator;
    const data = try zip.writeStoredZip(gpa, &.{
        .{ .name = "[Content_Types].xml", .data = ct_xml },
        .{ .name = "_rels/.rels", .data = root_rels },
        .{ .name = "word/document.xml", .data = "<w:document/>" },
    });
    defer gpa.free(data);
    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    try pkg.setCoreProperties(.{ .title = "fresh", .last_modified_by = "z" });

    const saved = try pkg.save(gpa);
    defer gpa.free(saved);
    var pkg2 = try Package.open(gpa, saved);
    defer pkg2.deinit();

    const props = try pkg2.coreProperties();
    try testing.expectEqualStrings("fresh", props.title.?);
    try testing.expectEqualStrings("z", props.last_modified_by.?);
    const resolved = (try pkg2.partByRelType(null, RelType.core_properties)).?;
    try testing.expectEqualStrings("docProps/core.xml", resolved);
    try testing.expectEqualStrings(
        "application/vnd.openxmlformats-package.core-properties+xml",
        pkg2.contentTypeOf("docProps/core.xml").?,
    );
}

test "clone is independent of later mutations to the original" {
    const gpa = testing.allocator;
    const data = try testPackage(gpa);
    defer gpa.free(data);
    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    try pkg.setPart("word/document.xml", "<w:document><w:body>v1</w:body></w:document>");
    var snapshot = try pkg.clone(gpa);
    defer snapshot.deinit();

    try pkg.setPart("word/document.xml", "<w:document><w:body>v2</w:body></w:document>");
    try pkg.deletePart("media/image1.png");

    const snap_doc = try snapshot.getPart("word/document.xml");
    try testing.expect(std.mem.indexOf(u8, snap_doc, "v1") != null);
    try testing.expect(snapshot.hasPart("media/image1.png"));

    // And the clone can itself save.
    const out = try snapshot.save(gpa);
    defer gpa.free(out);
    try testing.expect(out.len > 4);
}

test "partNames lists live parts, skipping deleted and including added" {
    const gpa = testing.allocator;
    const data = try testPackage(gpa);
    defer gpa.free(data);
    var pkg = try Package.open(gpa, data);
    defer pkg.deinit();

    try pkg.setPart("word/new.xml", "<n/>");
    try pkg.deletePart("media/image1.png");

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const names = try pkg.partNames(arena_inst.allocator());

    var has_new = false;
    var has_img = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "word/new.xml")) has_new = true;
        if (std.mem.eql(u8, n, "media/image1.png")) has_img = true;
    }
    try testing.expect(has_new);
    try testing.expect(!has_img);
}
