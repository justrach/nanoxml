//! Markup Compatibility and Extensibility (ECMA-376 Part 3) — the
//! `MarkupCompatibilityProcessSettings` layer.
//!
//! Office files embed forward-compatibility markup: `mc:AlternateContent`
//! blocks (pick the richest understood representation), `mc:Ignorable`
//! attributes (strip markup from namespaces you don't know), and
//! `mc:ProcessContent` (keep the children of stripped elements). The SDK
//! applies these on load when MCSettings says to; nanoxml applies them to
//! a parsed DOM via `process`.

const std = @import("std");
const dom = @import("dom.zig");
const xml = @import("xml.zig");

pub const mc_ns = "http://schemas.openxmlformats.org/markup-compatibility/2006";

pub const Error = error{ OutOfMemory, MustUnderstandFailed };

pub const Options = struct {
    /// Namespace URIs the consumer understands. Markup from any other
    /// namespace is subject to Ignorable/AlternateContent processing.
    understood: []const []const u8,
};

/// Apply MC processing to the tree rooted at `root`, in place:
///  - `mc:AlternateContent` collapses to the first `mc:Choice` whose
///    `Requires` namespaces are all understood, else to `mc:Fallback`,
///    else disappears.
///  - Elements/attributes whose prefix is declared `mc:Ignorable` and whose
///    namespace is not understood are removed; elements listed in
///    `mc:ProcessContent` are replaced by their children instead.
///  - `mc:MustUnderstand` naming a namespace that is not understood fails
///    (SDK throws NotSupportedException).
/// Mirrors SDK `MarkupCompatibilityProcessMode.ProcessAllParts`.
pub fn process(arena: std.mem.Allocator, root: *dom.Element, opts: Options) Error!void {
    var scope: Scope = .{};
    try processElement(arena, root, &scope, opts);
}

const Scope = struct {
    /// Prefixes declared ignorable, innermost last. Entries borrowed from
    /// attribute values (arena-owned).
    ignorable: std.ArrayList([]const u8) = .empty,
    /// "pfx:local" (or "pfx:*") entries from mc:ProcessContent.
    process_content: std.ArrayList([]const u8) = .empty,
};

fn understands(el: *const dom.Element, pfx: []const u8, opts: Options) bool {
    const uri = el.lookupNamespace(pfx) orelse return false;
    for (opts.understood) |u| {
        if (std.mem.eql(u8, u, uri)) return true;
    }
    return false;
}

fn inList(list: []const []const u8, item: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, item)) return true;
    }
    return false;
}

fn isMcAttr(el: *const dom.Element, attr_name: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, attr_name, ':') orelse return false;
    const pfx = attr_name[0..colon];
    const uri = el.lookupNamespace(pfx) orelse return false;
    return std.mem.eql(u8, uri, mc_ns);
}

fn processElement(arena: std.mem.Allocator, el: *dom.Element, scope: *Scope, opts: Options) Error!void {
    const ign_mark = scope.ignorable.items.len;
    const pc_mark = scope.process_content.items.len;
    defer scope.ignorable.shrinkRetainingCapacity(ign_mark);
    defer scope.process_content.shrinkRetainingCapacity(pc_mark);

    // Read this element's MC declarations, then drop the mc:* attributes.
    var i: usize = 0;
    while (i < el.attrs.items.len) {
        const a = el.attrs.items[i];
        if (isMcAttr(el, a.name)) {
            const local = xml.localName(a.name);
            if (std.mem.eql(u8, local, "Ignorable")) {
                var it = std.mem.tokenizeAny(u8, a.value, " \t\r\n");
                while (it.next()) |pfx| try scope.ignorable.append(arena, pfx);
            } else if (std.mem.eql(u8, local, "ProcessContent")) {
                var it = std.mem.tokenizeAny(u8, a.value, " \t\r\n");
                while (it.next()) |qn| try scope.process_content.append(arena, qn);
            } else if (std.mem.eql(u8, local, "MustUnderstand")) {
                var it = std.mem.tokenizeAny(u8, a.value, " \t\r\n");
                while (it.next()) |pfx| {
                    if (!understands(el, pfx, opts)) return Error.MustUnderstandFailed;
                }
            }
            _ = el.attrs.orderedRemove(i);
            continue;
        }
        i += 1;
    }

    // Drop attributes from ignorable, not-understood namespaces.
    i = 0;
    while (i < el.attrs.items.len) {
        const a = el.attrs.items[i];
        if (std.mem.indexOfScalar(u8, a.name, ':')) |colon| {
            const pfx = a.name[0..colon];
            if (!std.mem.eql(u8, pfx, "xmlns") and
                inList(scope.ignorable.items, pfx) and
                !understands(el, pfx, opts))
            {
                _ = el.attrs.orderedRemove(i);
                continue;
            }
        }
        i += 1;
    }

    // Rebuild the child list with AlternateContent/Ignorable resolution.
    var out: std.ArrayList(dom.Node) = .empty;
    try appendProcessedChildren(arena, el, el.children.items, &out, scope, opts);
    el.children = out;
}

fn appendProcessedChildren(
    arena: std.mem.Allocator,
    parent: *dom.Element,
    nodes: []const dom.Node,
    out: *std.ArrayList(dom.Node),
    scope: *Scope,
    opts: Options,
) Error!void {
    for (nodes) |node| {
        switch (node) {
            .element => |child| {
                if (isMcElement(child, "AlternateContent")) {
                    if (try chooseBranch(child, opts)) |branch| {
                        // Splice the branch's children in place, processed
                        // under the same scope. Keep parents correct.
                        try appendProcessedChildren(arena, parent, branch.children.items, out, scope, opts);
                    }
                    continue;
                }
                const pfx = child.prefix();
                if (pfx.len > 0 and inList(scope.ignorable.items, pfx) and !understands(child, pfx, opts)) {
                    if (inProcessContent(scope.process_content.items, child)) {
                        try appendProcessedChildren(arena, parent, child.children.items, out, scope, opts);
                    }
                    // else: dropped entirely.
                    continue;
                }
                try processElement(arena, child, scope, opts);
                child.parent = parent;
                try out.append(arena, .{ .element = child });
            },
            else => try out.append(arena, node),
        }
    }
}

fn isMcElement(el: *const dom.Element, local: []const u8) bool {
    if (!std.mem.eql(u8, el.localName(), local)) return false;
    const pfx = el.prefix();
    const uri = el.lookupNamespace(pfx) orelse return false;
    return std.mem.eql(u8, uri, mc_ns);
}

/// First mc:Choice whose every Requires prefix is understood, else
/// mc:Fallback, else null.
fn chooseBranch(ac: *dom.Element, opts: Options) Error!?*dom.Element {
    var choices = ac.elements("Choice");
    while (choices.next()) |choice| {
        const requires = choice.attr("Requires") orelse continue;
        var ok = true;
        var it = std.mem.tokenizeAny(u8, requires, " \t\r\n");
        while (it.next()) |pfx| {
            if (!understands(choice, pfx, opts)) {
                ok = false;
                break;
            }
        }
        if (ok) return choice;
    }
    return ac.child("Fallback");
}

fn inProcessContent(entries: []const []const u8, el: *const dom.Element) bool {
    const pfx = el.prefix();
    const local = el.localName();
    for (entries) |qn| {
        const colon = std.mem.indexOfScalar(u8, qn, ':') orelse continue;
        if (!std.mem.eql(u8, qn[0..colon], pfx)) continue;
        const want = qn[colon + 1 ..];
        if (std.mem.eql(u8, want, "*") or std.mem.eql(u8, want, local)) return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const w_ns = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";

fn processAndSerialize(src: []const u8, understood: []const []const u8, out: *std.ArrayList(u8)) !void {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const root = try dom.parse(arena, src);
    try process(arena, root, .{ .understood = understood });
    try dom.serialize(root, testing.allocator, out, .{ .declaration = false });
}

test "AlternateContent picks first understood Choice" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try processAndSerialize(
        \\<w:doc xmlns:w="http://w" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:v2="http://v2" xmlns:v1="http://v1"><mc:AlternateContent><mc:Choice Requires="v2"><v2:new/></mc:Choice><mc:Choice Requires="v1"><v1:old/></mc:Choice><mc:Fallback><w:plain/></mc:Fallback></mc:AlternateContent></w:doc>
    , &.{ "http://w", "http://v1" }, &out);
    // v2 not understood, v1 is → second Choice wins.
    try testing.expectEqualStrings(
        \\<w:doc xmlns:w="http://w" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:v2="http://v2" xmlns:v1="http://v1"><v1:old/></w:doc>
    , out.items);
}

test "AlternateContent falls back, and vanishes without Fallback" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try processAndSerialize(
        \\<d xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:x="http://x"><mc:AlternateContent><mc:Choice Requires="x"><x:a/></mc:Choice><mc:Fallback><plain/></mc:Fallback></mc:AlternateContent><mc:AlternateContent><mc:Choice Requires="x"><x:b/></mc:Choice></mc:AlternateContent></d>
    , &.{}, &out);
    try testing.expectEqualStrings(
        \\<d xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:x="http://x"><plain/></d>
    , out.items);
}

test "Ignorable strips unknown-namespace elements and attributes; understood ones stay" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try processAndSerialize(
        \\<w:document xmlns:w="WNS" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:w14="W14NS" mc:Ignorable="w14"><w:body><w:p w14:paraId="ABC" w:x="keep"><w14:glow/><w:r/></w:p></w:body></w:document>
    , &.{"WNS"}, &out);
    try testing.expectEqualStrings(
        \\<w:document xmlns:w="WNS" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:w14="W14NS"><w:body><w:p w:x="keep"><w:r/></w:p></w:body></w:document>
    , out.items);
}

test "Ignorable namespace that IS understood is kept" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try processAndSerialize(
        \\<d xmlns:e="ENS" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="e"><e:kept v="1"/></d>
    , &.{"ENS"}, &out);
    try testing.expectEqualStrings(
        \\<d xmlns:e="ENS" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><e:kept v="1"/></d>
    , out.items);
}

test "ProcessContent splices children of stripped elements" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try processAndSerialize(
        \\<d xmlns:ext="X" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="ext" mc:ProcessContent="ext:wrap"><ext:wrap><inner/></ext:wrap><ext:other><gone/></ext:other></d>
    , &.{}, &out);
    try testing.expectEqualStrings(
        \\<d xmlns:ext="X" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><inner/></d>
    , out.items);
}

test "MustUnderstand fails on unknown namespace" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const root = try dom.parse(arena,
        \\<d xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:v="V" mc:MustUnderstand="v"/>
    );
    try testing.expectError(Error.MustUnderstandFailed, process(arena, root, .{ .understood = &.{} }));
}

test "nested AlternateContent inside chosen branch resolves recursively" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try processAndSerialize(
        \\<d xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:a="A"><mc:AlternateContent><mc:Choice Requires="a"><a:x><mc:AlternateContent><mc:Fallback><deep/></mc:Fallback></mc:AlternateContent></a:x></mc:Choice></mc:AlternateContent></d>
    , &.{"A"}, &out);
    try testing.expectEqualStrings(
        \\<d xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:a="A"><a:x><deep/></a:x></d>
    , out.items);
}

test "real-world shape: w14 glow Ignorable + AlternateContent textbox" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const src =
        "<w:document xmlns:w=\"" ++ w_ns ++ "\" " ++
        "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" " ++
        "xmlns:wps=\"http://schemas.microsoft.com/office/word/2010/wordprocessingShape\" " ++
        "mc:Ignorable=\"wps\">" ++
        "<w:body><mc:AlternateContent>" ++
        "<mc:Choice Requires=\"wps\"><wps:txbx><w:p><w:r><w:t>rich</w:t></w:r></w:p></wps:txbx></mc:Choice>" ++
        "<mc:Fallback><w:p><w:r><w:t>plain</w:t></w:r></w:p></mc:Fallback>" ++
        "</mc:AlternateContent></w:body></w:document>";
    try processAndSerialize(src, &.{w_ns}, &out);
    try testing.expect(std.mem.indexOf(u8, out.items, "plain") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "wps:txbx") == null);
}
