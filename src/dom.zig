//! Mutable XML element tree — the `OpenXmlElement` layer.
//!
//! Open-XML-SDK's typed DOM is ~6000 generated classes over exactly this
//! shape: a named element with attributes and ordered children that can be
//! navigated, mutated, and serialized back out. nanoxml provides the shape
//! generically: matching is by local name (like the rest of the library),
//! text and attribute values are stored *decoded*, and `serialize`
//! re-escapes on the way out.
//!
//! All nodes live in the caller's arena; there is no per-node free.

const std = @import("std");
const xml = @import("xml.zig");

pub const Error = error{ MalformedXml, OutOfMemory };

pub const Node = union(enum) {
    element: *Element,
    /// Decoded character data (CDATA is folded in here).
    text: []const u8,
    comment: []const u8,
};

pub const Attr = struct {
    name: []const u8,
    /// Decoded value.
    value: []const u8,
};

pub const Element = struct {
    /// Qualified name ("w:p").
    name: []const u8,
    attrs: std.ArrayList(Attr) = .empty,
    children: std.ArrayList(Node) = .empty,

    /// Attribute by exact qualified name, falling back to local-name match.
    pub fn attr(self: *const Element, name: []const u8) ?[]const u8 {
        for (self.attrs.items) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        for (self.attrs.items) |a| {
            if (std.mem.eql(u8, xml.localName(a.name), name)) return a.value;
        }
        return null;
    }

    /// Replace an existing attribute's value or append a new one.
    pub fn setAttr(self: *Element, arena: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        const value_d = try arena.dupe(u8, value);
        for (self.attrs.items) |*a| {
            if (std.mem.eql(u8, a.name, name)) {
                a.value = value_d;
                return;
            }
        }
        try self.attrs.append(arena, .{ .name = try arena.dupe(u8, name), .value = value_d });
    }

    /// First child element whose local name matches.
    pub fn child(self: *const Element, local: []const u8) ?*Element {
        return self.childAt(local, 0);
    }

    /// N-th (0-based) child element whose local name matches.
    pub fn childAt(self: *const Element, local: []const u8, index: usize) ?*Element {
        var seen: usize = 0;
        for (self.children.items) |node| {
            switch (node) {
                .element => |el| {
                    if (std.mem.eql(u8, xml.localName(el.name), local)) {
                        if (seen == index) return el;
                        seen += 1;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    /// Concatenated decoded text of all descendants, in document order.
    pub fn text(self: *const Element, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        for (self.children.items) |node| {
            switch (node) {
                .text => |t| try out.appendSlice(gpa, t),
                .element => |el| try el.text(gpa, out),
                .comment => {},
            }
        }
    }

    /// Replace all children with a single text node.
    pub fn setText(self: *Element, arena: std.mem.Allocator, t: []const u8) !void {
        self.children.clearRetainingCapacity();
        try self.children.append(arena, .{ .text = try arena.dupe(u8, t) });
    }

    /// Append a new empty child element and return it.
    pub fn appendElement(self: *Element, arena: std.mem.Allocator, name: []const u8) !*Element {
        const el = try arena.create(Element);
        el.* = .{ .name = try arena.dupe(u8, name) };
        try self.children.append(arena, .{ .element = el });
        return el;
    }

    pub fn appendText(self: *Element, arena: std.mem.Allocator, t: []const u8) !void {
        try self.children.append(arena, .{ .text = try arena.dupe(u8, t) });
    }
};

/// Parse a document into a tree rooted at its root element. Everything is
/// duplicated into `arena`; the source buffer may be freed afterwards.
pub fn parse(arena: std.mem.Allocator, src: []const u8) Error!*Element {
    var p = xml.Parser.init(src);

    // Skip prolog (declaration, comments, doctype, whitespace).
    const root_tag: xml.StartTag = while (true) {
        const ev = p.next() catch return Error.MalformedXml;
        switch (ev) {
            .start => |st| break st,
            .eof => return Error.MalformedXml,
            else => {},
        }
    };

    const root = try arena.create(Element);
    root.* = .{ .name = try arena.dupe(u8, root_tag.name) };
    try copyAttrs(arena, &root_tag, root);
    if (root_tag.self_closing) {
        _ = p.next() catch return Error.MalformedXml; // synthetic end
        return root;
    }

    var stack: std.ArrayList(*Element) = .empty;
    defer stack.deinit(arena);
    try stack.append(arena, root);

    while (stack.items.len > 0) {
        const ev = p.next() catch return Error.MalformedXml;
        const top = stack.items[stack.items.len - 1];
        switch (ev) {
            .start => |st| {
                const el = try arena.create(Element);
                el.* = .{ .name = try arena.dupe(u8, st.name) };
                try copyAttrs(arena, &st, el);
                try top.children.append(arena, .{ .element = el });
                if (st.self_closing) {
                    // The parser's synthetic end event follows immediately.
                    const e2 = p.next() catch return Error.MalformedXml;
                    if (e2 != .end) return Error.MalformedXml;
                } else {
                    try stack.append(arena, el);
                }
            },
            .end => |name| {
                if (!std.mem.eql(u8, name, top.name)) return Error.MalformedXml;
                _ = stack.pop();
            },
            .text => |raw| {
                var buf: std.ArrayList(u8) = .empty;
                try xml.decodeAppend(&buf, arena, raw);
                try top.children.append(arena, .{ .text = try buf.toOwnedSlice(arena) });
            },
            .cdata => |raw| {
                try top.children.append(arena, .{ .text = try arena.dupe(u8, raw) });
            },
            .comment => |c| {
                try top.children.append(arena, .{ .comment = try arena.dupe(u8, c) });
            },
            .eof => return Error.MalformedXml,
            else => {},
        }
    }
    return root;
}

fn copyAttrs(arena: std.mem.Allocator, st: *const xml.StartTag, el: *Element) !void {
    var it = st.attrs();
    while (it.next()) |a| {
        var buf: std.ArrayList(u8) = .empty;
        try xml.decodeAppend(&buf, arena, a.value);
        try el.attrs.append(arena, .{
            .name = try arena.dupe(u8, a.name),
            .value = try buf.toOwnedSlice(arena),
        });
    }
}

pub const SerializeOptions = struct {
    /// Emit `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>`.
    declaration: bool = true,
};

pub fn serialize(
    root: *const Element,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    opts: SerializeOptions,
) error{OutOfMemory}!void {
    if (opts.declaration)
        try out.appendSlice(gpa, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
    try writeElement(root, gpa, out);
}

fn writeElement(
    el: *const Element,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
) error{OutOfMemory}!void {
    try out.append(gpa, '<');
    try out.appendSlice(gpa, el.name);
    for (el.attrs.items) |a| {
        try out.append(gpa, ' ');
        try out.appendSlice(gpa, a.name);
        try out.appendSlice(gpa, "=\"");
        try xml.escapeAppend(out, gpa, a.value, .attr);
        try out.append(gpa, '"');
    }
    if (el.children.items.len == 0) {
        try out.appendSlice(gpa, "/>");
        return;
    }
    try out.append(gpa, '>');
    for (el.children.items) |node| {
        switch (node) {
            .element => |c| try writeElement(c, gpa, out),
            .text => |t| try xml.escapeAppend(out, gpa, t, .text),
            .comment => |c| {
                try out.appendSlice(gpa, "<!--");
                try out.appendSlice(gpa, c);
                try out.appendSlice(gpa, "-->");
            },
        }
    }
    try out.appendSlice(gpa, "</");
    try out.appendSlice(gpa, el.name);
    try out.append(gpa, '>');
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parse and serialize empty self-closing root" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = try parse(arena, "<?xml version=\"1.0\"?><a x=\"1\"/>");
    try testing.expectEqualStrings("a", root.name);
    try testing.expectEqual(@as(usize, 0), root.children.items.len);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try serialize(root, testing.allocator, &out, .{ .declaration = false });
    try testing.expectEqualStrings("<a x=\"1\"/>", out.items);
}

test "whitespace between elements survives round-trip" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const src = "<a>\n  <b/>\n</a>";
    const root = try parse(arena, src);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try serialize(root, testing.allocator, &out, .{ .declaration = false });
    try testing.expectEqualStrings(src, out.items);
}

test "mismatched end tag is malformed" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    try testing.expectError(Error.MalformedXml, parse(arena_inst.allocator(), "<a><b></a></b>"));
}
