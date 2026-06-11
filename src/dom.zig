//! Mutable XML element tree — the `OpenXmlElement` layer.
//!
//! Open-XML-SDK's typed DOM is ~6000 generated classes over exactly this
//! shape: a named element with attributes and ordered children that can be
//! navigated, mutated, and serialized back out. nanoxml provides the shape
//! generically: matching is by local name (like the rest of the library),
//! text and attribute values are stored *decoded*, and `serialize`
//! re-escapes on the way out.
//!
//! SDK ↔ nanoxml mapping:
//!   Parent / Ancestors()            → parent / ancestors()
//!   Elements() / Descendants()      → elements() / descendants()
//!   NextSibling() / PreviousSibling → nextSiblingElement() / previousSiblingElement()
//!   AppendChild / PrependChild      → appendChild() / prependChild()
//!   InsertBefore / InsertAfter      → insertBefore() / insertAfter()
//!   RemoveChild / ReplaceChild      → removeChild() / replaceChild()
//!   RemoveAllChildren / Remove      → removeAllChildren() / remove()
//!   CloneNode(deep)                 → cloneNode(arena, deep)
//!   InnerText                       → text() / innerText()
//!   OuterXml / InnerXml             → outerXml() / innerXml() / setInnerXml()
//!   GetAttribute / SetAttribute     → attr() / setAttr()
//!   RemoveAttribute / ClearAllAttributes → removeAttr() / clearAttrs()
//!   LookupNamespace / LookupPrefix  → lookupNamespace() / lookupPrefix()
//!   AddNamespaceDeclaration         → addNamespaceDeclaration()
//!
//! All nodes live in the caller's arena; there is no per-node free.

const std = @import("std");
const xml = @import("xml.zig");

pub const Error = error{ MalformedXml, OutOfMemory };
pub const MutateError = error{NotFound};

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
    /// Containing element; null for a root or a detached node. Text and
    /// comment nodes carry no identity, so only elements track parents.
    parent: ?*Element = null,

    /// New detached element (SDK `new T()`), ready for appendChild/insertBefore.
    pub fn create(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}!*Element {
        const el = try arena.create(Element);
        el.* = .{ .name = try arena.dupe(u8, name) };
        return el;
    }

    pub fn localName(self: *const Element) []const u8 {
        return xml.localName(self.name);
    }

    /// "w" for "w:p", "" for unprefixed names.
    pub fn prefix(self: *const Element) []const u8 {
        const colon = std.mem.indexOfScalar(u8, self.name, ':') orelse return "";
        return self.name[0..colon];
    }

    // ── Attributes ─────────────────────────────────────────────────────

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

    /// Remove by exact qualified name, falling back to local-name match.
    /// Returns true if an attribute was removed.
    pub fn removeAttr(self: *Element, name: []const u8) bool {
        for (self.attrs.items, 0..) |a, i| {
            if (std.mem.eql(u8, a.name, name)) {
                _ = self.attrs.orderedRemove(i);
                return true;
            }
        }
        for (self.attrs.items, 0..) |a, i| {
            if (std.mem.eql(u8, xml.localName(a.name), name)) {
                _ = self.attrs.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn clearAttrs(self: *Element) void {
        self.attrs.clearRetainingCapacity();
    }

    // ── Namespaces ─────────────────────────────────────────────────────

    /// Resolve a prefix ("" = default namespace) to a URI, walking ancestors.
    pub fn lookupNamespace(self: *const Element, pfx: []const u8) ?[]const u8 {
        var cur: ?*const Element = self;
        while (cur) |el| : (cur = el.parent) {
            for (el.attrs.items) |a| {
                if (pfx.len == 0) {
                    if (std.mem.eql(u8, a.name, "xmlns")) return a.value;
                } else if (a.name.len == 6 + pfx.len and
                    std.mem.startsWith(u8, a.name, "xmlns:") and
                    std.mem.eql(u8, a.name[6..], pfx))
                {
                    return a.value;
                }
            }
        }
        return null;
    }

    /// Find a prefix declared for a URI, walking ancestors. Default
    /// namespace declarations resolve to "".
    pub fn lookupPrefix(self: *const Element, uri: []const u8) ?[]const u8 {
        var cur: ?*const Element = self;
        while (cur) |el| : (cur = el.parent) {
            for (el.attrs.items) |a| {
                if (!std.mem.eql(u8, a.value, uri)) continue;
                if (std.mem.eql(u8, a.name, "xmlns")) return "";
                if (std.mem.startsWith(u8, a.name, "xmlns:")) return a.name[6..];
            }
        }
        return null;
    }

    /// Declare `xmlns:prefix="uri"` (or default `xmlns` for empty prefix).
    pub fn addNamespaceDeclaration(self: *Element, arena: std.mem.Allocator, pfx: []const u8, uri: []const u8) !void {
        if (pfx.len == 0) return self.setAttr(arena, "xmlns", uri);
        const name = try std.mem.concat(arena, u8, &.{ "xmlns:", pfx });
        try self.setAttr(arena, name, uri);
    }

    // ── Navigation ─────────────────────────────────────────────────────

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

    pub const ChildElementIterator = struct {
        items: []const Node,
        idx: usize = 0,
        local: ?[]const u8,

        pub fn next(self: *ChildElementIterator) ?*Element {
            while (self.idx < self.items.len) {
                const node = self.items[self.idx];
                self.idx += 1;
                switch (node) {
                    .element => |el| {
                        if (self.local == null or
                            std.mem.eql(u8, xml.localName(el.name), self.local.?))
                            return el;
                    },
                    else => {},
                }
            }
            return null;
        }
    };

    /// Iterate child elements, optionally filtered by local name (SDK
    /// `Elements()` / `Elements<T>()`). Allocation-free.
    pub fn elements(self: *const Element, local: ?[]const u8) ChildElementIterator {
        return .{ .items = self.children.items, .local = local };
    }

    pub const DescendantIterator = struct {
        gpa: std.mem.Allocator,
        local: ?[]const u8,
        pending_root: ?*const Element,
        stack: std.ArrayList(Frame) = .empty,

        const Frame = struct { el: *const Element, idx: usize };

        pub fn deinit(self: *DescendantIterator) void {
            self.stack.deinit(self.gpa);
        }

        /// Pre-order document-order walk; excludes the start element itself.
        pub fn next(self: *DescendantIterator) error{OutOfMemory}!?*Element {
            if (self.pending_root) |r| {
                self.pending_root = null;
                try self.stack.append(self.gpa, .{ .el = r, .idx = 0 });
            }
            outer: while (self.stack.items.len > 0) {
                const top = &self.stack.items[self.stack.items.len - 1];
                const kids = top.el.children.items;
                while (top.idx < kids.len) {
                    const node = kids[top.idx];
                    top.idx += 1;
                    switch (node) {
                        .element => |el| {
                            try self.stack.append(self.gpa, .{ .el = el, .idx = 0 });
                            if (self.local == null or
                                std.mem.eql(u8, xml.localName(el.name), self.local.?))
                                return el;
                            continue :outer;
                        },
                        else => {},
                    }
                }
                _ = self.stack.pop();
            }
            return null;
        }
    };

    /// Iterate all descendant elements depth-first, optionally filtered by
    /// local name (SDK `Descendants()` / `Descendants<T>()`). The iterator
    /// allocates its walk stack from `gpa`; call `deinit()` when done.
    /// Do not mutate the tree while iterating.
    pub fn descendants(self: *const Element, gpa: std.mem.Allocator, local: ?[]const u8) DescendantIterator {
        return .{ .gpa = gpa, .local = local, .pending_root = self };
    }

    pub const AncestorIterator = struct {
        current: ?*Element,
        pub fn next(self: *AncestorIterator) ?*Element {
            const el = self.current orelse return null;
            self.current = el.parent;
            return el;
        }
    };

    /// Walk up the parent chain, nearest first (SDK `Ancestors()`).
    pub fn ancestors(self: *const Element) AncestorIterator {
        return .{ .current = self.parent };
    }

    fn indexOfChild(self: *const Element, el: *const Element) ?usize {
        for (self.children.items, 0..) |node, i| {
            switch (node) {
                .element => |e| if (e == el) return i,
                else => {},
            }
        }
        return null;
    }

    /// Next sibling element in the parent's child list (SDK `NextSibling()`).
    pub fn nextSiblingElement(self: *const Element) ?*Element {
        const p = self.parent orelse return null;
        var i = (p.indexOfChild(self) orelse return null) + 1;
        while (i < p.children.items.len) : (i += 1) {
            switch (p.children.items[i]) {
                .element => |el| return el,
                else => {},
            }
        }
        return null;
    }

    pub fn previousSiblingElement(self: *const Element) ?*Element {
        const p = self.parent orelse return null;
        var i = p.indexOfChild(self) orelse return null;
        while (i > 0) {
            i -= 1;
            switch (p.children.items[i]) {
                .element => |el| return el,
                else => {},
            }
        }
        return null;
    }

    // ── Text ───────────────────────────────────────────────────────────

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

    /// SDK `InnerText` (allocating convenience over `text`).
    pub fn innerText(self: *const Element, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try self.text(gpa, &out);
        return out.toOwnedSlice(gpa);
    }

    /// Replace all children with a single text node.
    pub fn setText(self: *Element, arena: std.mem.Allocator, t: []const u8) !void {
        self.removeAllChildren();
        try self.children.append(arena, .{ .text = try arena.dupe(u8, t) });
    }

    // ── Mutation ───────────────────────────────────────────────────────

    /// Append a new empty child element and return it.
    pub fn appendElement(self: *Element, arena: std.mem.Allocator, name: []const u8) !*Element {
        const el = try Element.create(arena, name);
        try self.appendChild(arena, el);
        return el;
    }

    pub fn appendText(self: *Element, arena: std.mem.Allocator, t: []const u8) !void {
        try self.children.append(arena, .{ .text = try arena.dupe(u8, t) });
    }

    /// SDK `AppendChild`: attach an existing (detached or re-homed) element.
    pub fn appendChild(self: *Element, arena: std.mem.Allocator, el: *Element) error{OutOfMemory}!void {
        el.parent = self;
        try self.children.append(arena, .{ .element = el });
    }

    /// SDK `PrependChild`.
    pub fn prependChild(self: *Element, arena: std.mem.Allocator, el: *Element) error{OutOfMemory}!void {
        el.parent = self;
        try self.children.insert(arena, 0, .{ .element = el });
    }

    /// SDK `InsertBefore(new, ref)` — `ref` must be a child element of self.
    pub fn insertBefore(self: *Element, arena: std.mem.Allocator, new_el: *Element, ref: *const Element) (MutateError || error{OutOfMemory})!void {
        const i = self.indexOfChild(ref) orelse return MutateError.NotFound;
        new_el.parent = self;
        try self.children.insert(arena, i, .{ .element = new_el });
    }

    /// SDK `InsertAfter(new, ref)`.
    pub fn insertAfter(self: *Element, arena: std.mem.Allocator, new_el: *Element, ref: *const Element) (MutateError || error{OutOfMemory})!void {
        const i = self.indexOfChild(ref) orelse return MutateError.NotFound;
        new_el.parent = self;
        try self.children.insert(arena, i + 1, .{ .element = new_el });
    }

    /// SDK `RemoveChild`: detach `el`; it can be re-inserted elsewhere.
    pub fn removeChild(self: *Element, el: *Element) MutateError!void {
        const i = self.indexOfChild(el) orelse return MutateError.NotFound;
        _ = self.children.orderedRemove(i);
        el.parent = null;
    }

    /// SDK `ReplaceChild`: swap `old` for `new` in place.
    pub fn replaceChild(self: *Element, new_el: *Element, old: *Element) MutateError!void {
        const i = self.indexOfChild(old) orelse return MutateError.NotFound;
        self.children.items[i] = .{ .element = new_el };
        new_el.parent = self;
        old.parent = null;
    }

    /// SDK `RemoveAllChildren` (text and comment nodes included).
    pub fn removeAllChildren(self: *Element) void {
        for (self.children.items) |node| {
            switch (node) {
                .element => |el| el.parent = null,
                else => {},
            }
        }
        self.children.clearRetainingCapacity();
    }

    /// SDK `Remove`: detach self from its parent. NotFound when detached.
    pub fn remove(self: *Element) MutateError!void {
        const p = self.parent orelse return MutateError.NotFound;
        try p.removeChild(self);
    }

    /// SDK `CloneNode(deep)`. The clone is detached (parent == null) and
    /// fully duplicated into `arena`, so it may outlive the original tree.
    pub fn cloneNode(self: *const Element, arena: std.mem.Allocator, deep: bool) error{OutOfMemory}!*Element {
        const el = try Element.create(arena, self.name);
        try el.attrs.ensureTotalCapacity(arena, self.attrs.items.len);
        for (self.attrs.items) |a| {
            el.attrs.appendAssumeCapacity(.{
                .name = try arena.dupe(u8, a.name),
                .value = try arena.dupe(u8, a.value),
            });
        }
        if (deep) {
            try el.children.ensureTotalCapacity(arena, self.children.items.len);
            for (self.children.items) |node| {
                switch (node) {
                    .element => |c| {
                        const cc = try c.cloneNode(arena, true);
                        cc.parent = el;
                        el.children.appendAssumeCapacity(.{ .element = cc });
                    },
                    .text => |t| el.children.appendAssumeCapacity(.{ .text = try arena.dupe(u8, t) }),
                    .comment => |c| el.children.appendAssumeCapacity(.{ .comment = try arena.dupe(u8, c) }),
                }
            }
        }
        return el;
    }

    // ── Markup access ──────────────────────────────────────────────────

    /// SDK `OuterXml`: this element and everything below it, no declaration.
    pub fn outerXml(self: *const Element, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
        try writeElement(self, gpa, out);
    }

    /// SDK `InnerXml` (getter): children only.
    pub fn innerXml(self: *const Element, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
        try writeChildren(self, gpa, out);
    }

    /// SDK `InnerXml` (setter): replace children with a parsed fragment.
    /// The fragment may contain multiple top-level elements and text.
    pub fn setInnerXml(self: *Element, arena: std.mem.Allocator, fragment: []const u8) Error!void {
        const wrapped = try std.mem.concat(arena, u8, &.{ "<__nanoxml_wrap__>", fragment, "</__nanoxml_wrap__>" });
        const wrap_root = try parse(arena, wrapped);
        self.removeAllChildren();
        for (wrap_root.children.items) |node| {
            switch (node) {
                .element => |el| el.parent = self,
                else => {},
            }
        }
        self.children = wrap_root.children;
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
                el.* = .{ .name = try arena.dupe(u8, st.name), .parent = top };
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
    try writeChildren(el, gpa, out);
    try out.appendSlice(gpa, "</");
    try out.appendSlice(gpa, el.name);
    try out.append(gpa, '>');
}

fn writeChildren(
    el: *const Element,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
) error{OutOfMemory}!void {
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

test "parse sets parent pointers; ancestors walks to root" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = try parse(arena, "<w:document><w:body><w:p><w:r/></w:p></w:body></w:document>");
    const r = root.child("body").?.child("p").?.child("r").?;
    try testing.expectEqual(@as(?*Element, null), root.parent);

    var it = r.ancestors();
    try testing.expectEqualStrings("w:p", it.next().?.name);
    try testing.expectEqualStrings("w:body", it.next().?.name);
    try testing.expectEqualStrings("w:document", it.next().?.name);
    try testing.expectEqual(@as(?*Element, null), it.next());
}

test "elements iterator filters by local name" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = try parse(arena, "<b><w:p i=\"0\"/>x<w:tbl/><w:p i=\"1\"/></b>");
    var it = root.elements("p");
    try testing.expectEqualStrings("0", it.next().?.attr("i").?);
    try testing.expectEqualStrings("1", it.next().?.attr("i").?);
    try testing.expectEqual(@as(?*Element, null), it.next());

    var all = root.elements(null);
    var n: usize = 0;
    while (all.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 3), n);
}

test "descendants yields document order and honors filter" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = try parse(arena,
        \\<doc><p><r><t>a</t></r></p><tbl><tr><tc><p><r><t>b</t></r></p></tc></tr></tbl></doc>
    );

    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(testing.allocator);
    var it = root.descendants(testing.allocator, null);
    defer it.deinit();
    while (try it.next()) |el| {
        try names.appendSlice(testing.allocator, el.name);
        try names.append(testing.allocator, ' ');
    }
    try testing.expectEqualStrings("p r t tbl tr tc p r t ", names.items);

    var ts = root.descendants(testing.allocator, "t");
    defer ts.deinit();
    const t1 = (try ts.next()).?;
    const t2 = (try ts.next()).?;
    try testing.expectEqual(@as(?*Element, null), try ts.next());
    const a = try t1.innerText(testing.allocator);
    defer testing.allocator.free(a);
    const b = try t2.innerText(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("a", a);
    try testing.expectEqualStrings("b", b);
}

test "sibling navigation skips text nodes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = try parse(arena, "<a><x/>mid<y/>tail<z/></a>");
    const x = root.child("x").?;
    const y = x.nextSiblingElement().?;
    try testing.expectEqualStrings("y", y.name);
    try testing.expectEqualStrings("z", y.nextSiblingElement().?.name);
    try testing.expectEqual(@as(?*Element, null), root.child("z").?.nextSiblingElement());
    try testing.expectEqualStrings("x", y.previousSiblingElement().?.name);
    try testing.expectEqual(@as(?*Element, null), x.previousSiblingElement());
}

test "insertBefore/insertAfter/prependChild order and parents" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = try parse(arena, "<a><m/></a>");
    const m = root.child("m").?;

    const before = try Element.create(arena, "before");
    try root.insertBefore(arena, before, m);
    const after = try Element.create(arena, "after");
    try root.insertAfter(arena, after, m);
    const first = try Element.create(arena, "first");
    try root.prependChild(arena, first);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try serialize(root, testing.allocator, &out, .{ .declaration = false });
    try testing.expectEqualStrings("<a><first/><before/><m/><after/></a>", out.items);
    try testing.expectEqual(root, before.parent.?);

    const stranger = try Element.create(arena, "s");
    try testing.expectError(MutateError.NotFound, root.insertBefore(arena, stranger, stranger));
}

test "removeChild/replaceChild/remove maintain parent pointers" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = try parse(arena, "<a><x/><y/><z/></a>");
    const x = root.child("x").?;
    const y = root.child("y").?;

    try y.remove();
    try testing.expectEqual(@as(?*Element, null), y.parent);
    try testing.expectError(MutateError.NotFound, y.remove());

    const r = try Element.create(arena, "r");
    try root.replaceChild(r, x);
    try testing.expectEqual(@as(?*Element, null), x.parent);
    try testing.expectEqual(root, r.parent.?);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try serialize(root, testing.allocator, &out, .{ .declaration = false });
    try testing.expectEqualStrings("<a><r/><z/></a>", out.items);

    root.removeAllChildren();
    try testing.expectEqual(@as(usize, 0), root.children.items.len);
    try testing.expectEqual(@as(?*Element, null), r.parent);
}

test "re-homing an element via appendChild moves it between parents" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = try parse(arena, "<a><src><kid/></src><dst/></a>");
    const src = root.child("src").?;
    const dst = root.child("dst").?;
    const kid = src.child("kid").?;

    try src.removeChild(kid);
    try dst.appendChild(arena, kid);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try serialize(root, testing.allocator, &out, .{ .declaration = false });
    try testing.expectEqualStrings("<a><src/><dst><kid/></dst></a>", out.items);
}

test "cloneNode deep and shallow" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = try parse(arena, "<p style=\"H1\"><r><t>hi</t></r></p>");

    const deep = try root.cloneNode(arena, true);
    try testing.expectEqual(@as(?*Element, null), deep.parent);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try serialize(deep, testing.allocator, &out, .{ .declaration = false });
    try testing.expectEqualStrings("<p style=\"H1\"><r><t>hi</t></r></p>", out.items);

    // Mutating the clone leaves the original untouched.
    try deep.child("r").?.child("t").?.setText(arena, "bye");
    const orig_t = try root.child("r").?.child("t").?.innerText(testing.allocator);
    defer testing.allocator.free(orig_t);
    try testing.expectEqualStrings("hi", orig_t);

    const shallow = try root.cloneNode(arena, false);
    try testing.expectEqualStrings("H1", shallow.attr("style").?);
    try testing.expectEqual(@as(usize, 0), shallow.children.items.len);
}

test "outerXml/innerXml/setInnerXml round-trip with escaping" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = try parse(arena, "<a><b k=\"&lt;q&gt;\">x &amp; y</b></a>");

    var outer: std.ArrayList(u8) = .empty;
    defer outer.deinit(testing.allocator);
    try root.outerXml(testing.allocator, &outer);
    try testing.expectEqualStrings("<a><b k=\"&lt;q&gt;\">x &amp; y</b></a>", outer.items);

    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(testing.allocator);
    try root.innerXml(testing.allocator, &inner);
    try testing.expectEqualStrings("<b k=\"&lt;q&gt;\">x &amp; y</b>", inner.items);

    try root.setInnerXml(arena, "<c/>plain<d v=\"1\"><e/></d>");
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(testing.allocator);
    try root.outerXml(testing.allocator, &after);
    try testing.expectEqualStrings("<a><c/>plain<d v=\"1\"><e/></d></a>", after.items);
    try testing.expectEqual(root, root.child("d").?.parent.?);

    try testing.expectError(Error.MalformedXml, root.setInnerXml(arena, "<unclosed>"));
}

test "attribute removal and clearing" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = try parse(arena, "<a w:val=\"1\" other=\"2\"/>");
    try testing.expect(root.removeAttr("w:val"));
    try testing.expect(!root.removeAttr("w:val"));
    try testing.expect(root.removeAttr("other"));

    try root.setAttr(arena, "r:id", "rId1");
    try testing.expect(root.removeAttr("id")); // local-name fallback
    root.clearAttrs();
    try testing.expectEqual(@as(usize, 0), root.attrs.items.len);
}

test "namespace lookup walks ancestors; declarations" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const root = try parse(arena,
        \\<w:document xmlns:w="http://w" xmlns="http://default"><w:body><w:p/></w:body></w:document>
    );
    const p = root.child("body").?.child("p").?;
    try testing.expectEqualStrings("http://w", p.lookupNamespace("w").?);
    try testing.expectEqualStrings("http://default", p.lookupNamespace("").?);
    try testing.expectEqual(@as(?[]const u8, null), p.lookupNamespace("nope"));

    try testing.expectEqualStrings("w", p.lookupPrefix("http://w").?);
    try testing.expectEqualStrings("", p.lookupPrefix("http://default").?);

    try root.addNamespaceDeclaration(arena, "r", "http://r");
    try testing.expectEqualStrings("http://r", p.lookupNamespace("r").?);
    try testing.expectEqualStrings("w:document", root.name);
    try testing.expectEqualStrings("document", root.localName());
    try testing.expectEqualStrings("w", root.prefix());
}
