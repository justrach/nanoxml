//! Zero-copy XML pull parser, SIMD-accelerated.
//!
//! The streaming analogue of Open-XML-SDK's `OpenXmlReader`: a StAX-style
//! cursor that yields events over a `[]const u8` without building a DOM and
//! without copying — every name, attribute and text slice points into the
//! input buffer. Entity decoding is deferred until a caller actually wants
//! the text (`decodeAppend`), and is skipped entirely when no `&` is present.
//!
//! Scanning uses 16-lane `@Vector` compares with `@ctz` mask extraction
//! (the codedb idiom), with scalar tails. Hot scans: `<` for markup, and a
//! quote-aware `>`/`"`/`'` scan for tag ends.
//!
//! Not a validator: well-formedness is checked only as far as needed to
//! never mis-slice. OOXML producers emit clean XML; malformed input fails
//! with `error.MalformedXml` rather than UB.

const std = @import("std");

pub const Error = error{MalformedXml};

pub const StartTag = struct {
    name: []const u8,
    /// Raw bytes between the name and the closing `>` (minus any `/`).
    attr_block: []const u8,
    self_closing: bool,

    pub fn attrs(self: *const StartTag) AttrIterator {
        return .{ .rest = self.attr_block };
    }

    /// Raw (undecoded) value of a named attribute.
    pub fn attr(self: *const StartTag, name: []const u8) ?[]const u8 {
        var it = self.attrs();
        while (it.next()) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }
};

pub const Attr = struct {
    name: []const u8,
    /// Raw value (entities not decoded).
    value: []const u8,
};

pub const AttrIterator = struct {
    rest: []const u8,

    pub fn next(self: *AttrIterator) ?Attr {
        var s = self.rest;
        var i: usize = 0;
        while (i < s.len and isSpace(s[i])) i += 1;
        s = s[i..];
        if (s.len == 0) {
            self.rest = s;
            return null;
        }
        // name up to '=' or whitespace
        var ne: usize = 0;
        while (ne < s.len and s[ne] != '=' and !isSpace(s[ne])) ne += 1;
        const name = s[0..ne];
        var p: usize = ne;
        while (p < s.len and isSpace(s[p])) p += 1;
        if (p >= s.len or s[p] != '=') {
            // Attribute without value (invalid XML, tolerated): stop.
            self.rest = "";
            return null;
        }
        p += 1;
        while (p < s.len and isSpace(s[p])) p += 1;
        if (p >= s.len or (s[p] != '"' and s[p] != '\'')) {
            self.rest = "";
            return null;
        }
        const q = s[p];
        p += 1;
        const close = indexOfBytePos(s, p, q) orelse {
            self.rest = "";
            return null;
        };
        self.rest = s[close + 1 ..];
        return .{ .name = name, .value = s[p..close] };
    }
};

pub const Event = union(enum) {
    start: StartTag,
    /// Qualified name of the closing tag.
    end: []const u8,
    /// Raw character data (entities not decoded).
    text: []const u8,
    cdata: []const u8,
    comment: []const u8,
    /// Processing instruction body (includes the XML declaration).
    pi: []const u8,
    doctype: []const u8,
    eof,
};

pub const Parser = struct {
    buf: []const u8,
    pos: usize = 0,
    /// Set when a self-closing tag was returned: the synthetic end event.
    pending_end: ?[]const u8 = null,

    pub fn init(buf: []const u8) Parser {
        var p = Parser{ .buf = buf };
        // UTF-8 BOM
        if (std.mem.startsWith(u8, buf, "\xEF\xBB\xBF")) p.pos = 3;
        return p;
    }

    pub fn next(self: *Parser) Error!Event {
        if (self.pending_end) |name| {
            self.pending_end = null;
            return .{ .end = name };
        }
        const buf = self.buf;
        if (self.pos >= buf.len) return .eof;

        if (buf[self.pos] != '<') {
            const start = self.pos;
            const lt = indexOfBytePos(buf, start, '<') orelse buf.len;
            self.pos = lt;
            return .{ .text = buf[start..lt] };
        }

        const tag_start = self.pos;
        if (tag_start + 1 >= buf.len) return Error.MalformedXml;

        switch (buf[tag_start + 1]) {
            '/' => {
                const gt = indexOfBytePos(buf, tag_start + 2, '>') orelse
                    return Error.MalformedXml;
                var name = buf[tag_start + 2 .. gt];
                name = std.mem.trimEnd(u8, name, " \t\r\n");
                self.pos = gt + 1;
                return .{ .end = name };
            },
            '!' => {
                if (std.mem.startsWith(u8, buf[tag_start..], "<!--")) {
                    const close = std.mem.indexOfPos(u8, buf, tag_start + 4, "-->") orelse
                        return Error.MalformedXml;
                    self.pos = close + 3;
                    return .{ .comment = buf[tag_start + 4 .. close] };
                }
                if (std.mem.startsWith(u8, buf[tag_start..], "<![CDATA[")) {
                    const close = std.mem.indexOfPos(u8, buf, tag_start + 9, "]]>") orelse
                        return Error.MalformedXml;
                    self.pos = close + 3;
                    return .{ .cdata = buf[tag_start + 9 .. close] };
                }
                // <!DOCTYPE ...> — may contain an internal subset in [ ].
                var p = tag_start + 2;
                var depth: usize = 0;
                while (p < buf.len) : (p += 1) {
                    switch (buf[p]) {
                        '[' => depth += 1,
                        ']' => depth -|= 1,
                        '>' => if (depth == 0) {
                            const body = buf[tag_start + 2 .. p];
                            self.pos = p + 1;
                            return .{ .doctype = body };
                        },
                        else => {},
                    }
                }
                return Error.MalformedXml;
            },
            '?' => {
                const close = std.mem.indexOfPos(u8, buf, tag_start + 2, "?>") orelse
                    return Error.MalformedXml;
                self.pos = close + 2;
                return .{ .pi = buf[tag_start + 2 .. close] };
            },
            else => {
                // Start tag: <name attr="v" ... > or <name ... />
                var ne = tag_start + 1;
                while (ne < buf.len) : (ne += 1) {
                    const c = buf[ne];
                    if (isSpace(c) or c == '>' or c == '/') break;
                }
                if (ne >= buf.len) return Error.MalformedXml;
                const name = buf[tag_start + 1 .. ne];
                if (name.len == 0) return Error.MalformedXml;

                const gt = findTagEnd(buf, ne) orelse return Error.MalformedXml;
                const self_closing = buf[gt - 1] == '/';
                const block_end = if (self_closing) gt - 1 else gt;
                const attr_block = if (ne < block_end) buf[ne..block_end] else "";

                self.pos = gt + 1;
                if (self_closing) self.pending_end = name;
                return .{ .start = .{
                    .name = name,
                    .attr_block = attr_block,
                    .self_closing = self_closing,
                } };
            },
        }
    }

    /// After a non-self-closing `start` event: skip everything up to and
    /// including the matching end tag.
    pub fn skipElement(self: *Parser) Error!void {
        var depth: usize = 1;
        while (depth > 0) {
            switch (try self.next()) {
                // Self-closing starts also count: their synthetic end event
                // arrives next and decrements symmetrically.
                .start => depth += 1,
                .end => depth -= 1,
                .eof => return Error.MalformedXml,
                else => {},
            }
        }
    }
};

pub inline fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// "w:t" -> "t". OOXML matching is done on local names; real-world parts use
/// stable prefixes but producers may choose different ones.
pub fn localName(qname: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, qname, ':')) |i| return qname[i + 1 ..];
    return qname;
}

// ── SIMD scanning ──────────────────────────────────────────────────────────

/// Target-aware lane count: 32 with AVX2, 16 otherwise (NEON/SSE).
const VW: comptime_int = blk: {
    const builtin = @import("builtin");
    if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) {
        if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) break :blk 32;
    }
    break :blk 16;
};
const Vec = @Vector(VW, u8);
const Mask = std.meta.Int(.unsigned, VW);

/// First index of `b` at or after `start`.
pub fn indexOfBytePos(buf: []const u8, start: usize, b: u8) ?usize {
    var pos = start;
    const splat: Vec = @splat(b);
    while (pos + VW <= buf.len) {
        const chunk: Vec = buf[pos..][0..VW].*;
        const eq: @Vector(VW, u1) = @bitCast(chunk == splat);
        const mask: Mask = @bitCast(eq);
        if (mask != 0) return pos + @ctz(mask);
        pos += VW;
    }
    while (pos < buf.len) : (pos += 1) {
        if (buf[pos] == b) return pos;
    }
    return null;
}

/// Index of the tag-closing `>`, skipping over quoted attribute values.
/// SIMD scans for '>' | '"' | '\'' simultaneously; on a quote, jumps to its
/// closing twin and resumes.
fn findTagEnd(buf: []const u8, start: usize) ?usize {
    var pos = start;
    const splat_gt: Vec = @splat('>');
    const splat_dq: Vec = @splat('"');
    const splat_sq: Vec = @splat('\'');

    outer: while (pos < buf.len) {
        while (pos + VW <= buf.len) {
            const chunk: Vec = buf[pos..][0..VW].*;
            const m_gt: @Vector(VW, u1) = @bitCast(chunk == splat_gt);
            const m_dq: @Vector(VW, u1) = @bitCast(chunk == splat_dq);
            const m_sq: @Vector(VW, u1) = @bitCast(chunk == splat_sq);
            const mask: Mask = @bitCast(m_gt | m_dq | m_sq);
            if (mask == 0) {
                pos += VW;
                continue;
            }
            const hit = pos + @ctz(mask);
            switch (buf[hit]) {
                '>' => return hit,
                else => |q| {
                    pos = (indexOfBytePos(buf, hit + 1, q) orelse return null) + 1;
                    continue :outer;
                },
            }
        }
        // Scalar tail
        while (pos < buf.len) : (pos += 1) {
            switch (buf[pos]) {
                '>' => return pos,
                '"', '\'' => |q| {
                    pos = indexOfBytePos(buf, pos + 1, q) orelse return null;
                },
                else => {},
            }
        }
    }
    return null;
}

// ── Entity decoding (lazy) ─────────────────────────────────────────────────

/// Append `raw` to `out` with XML entities decoded. The fast path (no `&`)
/// is a single SIMD scan + memcpy.
pub fn decodeAppend(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8) !void {
    var rest = raw;
    while (true) {
        const amp = indexOfBytePos(rest, 0, '&') orelse {
            try out.appendSlice(gpa, rest);
            return;
        };
        try out.appendSlice(gpa, rest[0..amp]);
        rest = rest[amp..];

        const semi = indexOfBytePos(rest, 1, ';') orelse {
            // Bare '&' (invalid); pass through.
            try out.appendSlice(gpa, rest);
            return;
        };
        const ent = rest[1..semi];
        if (std.mem.eql(u8, ent, "lt")) {
            try out.append(gpa, '<');
        } else if (std.mem.eql(u8, ent, "gt")) {
            try out.append(gpa, '>');
        } else if (std.mem.eql(u8, ent, "amp")) {
            try out.append(gpa, '&');
        } else if (std.mem.eql(u8, ent, "quot")) {
            try out.append(gpa, '"');
        } else if (std.mem.eql(u8, ent, "apos")) {
            try out.append(gpa, '\'');
        } else if (ent.len > 1 and ent[0] == '#') {
            const cp = blk: {
                if (ent[1] == 'x' or ent[1] == 'X') {
                    break :blk std.fmt.parseInt(u21, ent[2..], 16) catch null;
                }
                break :blk std.fmt.parseInt(u21, ent[1..], 10) catch null;
            };
            if (cp) |c| {
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &tmp) catch 0;
                if (n > 0) {
                    try out.appendSlice(gpa, tmp[0..n]);
                } else {
                    try out.appendSlice(gpa, rest[0 .. semi + 1]);
                }
            } else {
                try out.appendSlice(gpa, rest[0 .. semi + 1]);
            }
        } else {
            // Unknown entity: pass through verbatim.
            try out.appendSlice(gpa, rest[0 .. semi + 1]);
        }
        rest = rest[semi + 1 ..];
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "pull events over a small document" {
    const doc =
        "\xEF\xBB\xBF<?xml version=\"1.0\" encoding=\"UTF-8\"?>" ++
        "<w:document xmlns:w=\"http://x\">" ++
        "<!-- note -->" ++
        "<w:p id=\"p1\" w:val='a&amp;b'>" ++
        "Hello <w:b/>World" ++
        "<![CDATA[<raw>]]>" ++
        "</w:p>" ++
        "</w:document>";

    var p = Parser.init(doc);

    try testing.expect(try p.next() == .pi);

    const root = (try p.next()).start;
    try testing.expectEqualStrings("w:document", root.name);
    try testing.expectEqualStrings("document", localName(root.name));
    try testing.expect(!root.self_closing);

    const comment = (try p.next()).comment;
    try testing.expectEqualStrings(" note ", comment);

    const para = (try p.next()).start;
    try testing.expectEqualStrings("w:p", para.name);
    try testing.expectEqualStrings("p1", para.attr("id").?);
    try testing.expectEqualStrings("a&amp;b", para.attr("w:val").?);
    var it = para.attrs();
    try testing.expectEqualStrings("id", it.next().?.name);
    try testing.expectEqualStrings("w:val", it.next().?.name);
    try testing.expect(it.next() == null);

    try testing.expectEqualStrings("Hello ", (try p.next()).text);

    const b = (try p.next()).start;
    try testing.expect(b.self_closing);
    try testing.expectEqualStrings("w:b", (try p.next()).end); // synthetic

    try testing.expectEqualStrings("World", (try p.next()).text);
    try testing.expectEqualStrings("<raw>", (try p.next()).cdata);
    try testing.expectEqualStrings("w:p", (try p.next()).end);
    try testing.expectEqualStrings("w:document", (try p.next()).end);
    try testing.expect(try p.next() == .eof);
}

test "attribute values may contain '>'" {
    const doc = "<a cond=\"x > 1\" other='2 > 1'><b/></a>";
    var p = Parser.init(doc);
    const a = (try p.next()).start;
    try testing.expectEqualStrings("x > 1", a.attr("cond").?);
    try testing.expectEqualStrings("2 > 1", a.attr("other").?);
    const b = (try p.next()).start;
    try testing.expectEqualStrings("b", b.name);
}

test "skipElement balances depth" {
    const doc = "<r><skip><x><y/></x>text</skip><keep/></r>";
    var p = Parser.init(doc);
    _ = try p.next(); // <r>
    const skip = (try p.next()).start;
    try testing.expectEqualStrings("skip", skip.name);
    try p.skipElement();
    const keep = (try p.next()).start;
    try testing.expectEqualStrings("keep", keep.name);
}

test "entity decoding" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try decodeAppend(&out, gpa, "a&amp;b &lt;tag&gt; &quot;q&quot; &apos;s&apos; &#65;&#x42; &unknown; plain");
    try testing.expectEqualStrings("a&b <tag> \"q\" 's' AB &unknown; plain", out.items);

    // Fast path: no allocation growth beyond the slice append itself.
    out.clearRetainingCapacity();
    try decodeAppend(&out, gpa, "no entities at all, just a fairly long run of text");
    try testing.expectEqualStrings("no entities at all, just a fairly long run of text", out.items);
}

test "SIMD scans match scalar behavior across boundaries" {
    const gpa = testing.allocator;
    // Place targets at every offset around the 16-byte lane edge.
    var buf: [64]u8 = [_]u8{'a'} ** 64;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        buf = [_]u8{'a'} ** 64;
        buf[i] = '<';
        const found = indexOfBytePos(&buf, 0, '<');
        try testing.expectEqual(@as(?usize, i), found);
    }
    _ = gpa;
}

// ── Spec edge cases ────────────────────────────────────────────────────────

test "doctype with internal subset" {
    const doc = "<!DOCTYPE root [ <!ENTITY foo \"bar\"> ]><root/>";
    var p = Parser.init(doc);
    const dt = (try p.next()).doctype;
    try testing.expect(std.mem.indexOf(u8, dt, "ENTITY") != null);
    const r = (try p.next()).start;
    try testing.expectEqualStrings("root", r.name);
}

test "comment containing angle brackets and dashes" {
    const doc = "<a><!-- < > - -- not done yet -->.</a>";
    var p = Parser.init(doc);
    _ = try p.next();
    const c = (try p.next()).comment;
    try testing.expectEqualStrings(" < > - -- not done yet ", c);
    try testing.expectEqualStrings(".", (try p.next()).text);
}

test "single-quoted attributes and whitespace around equals" {
    const doc = "<a x = 'v1' y= \"v2\" z ='v3'/>";
    var p = Parser.init(doc);
    const a = (try p.next()).start;
    try testing.expectEqualStrings("v1", a.attr("x").?);
    try testing.expectEqualStrings("v2", a.attr("y").?);
    try testing.expectEqualStrings("v3", a.attr("z").?);
}

test "valueless attribute stops iteration without crashing" {
    const doc = "<a checked x=\"1\"/>";
    var p = Parser.init(doc);
    const a = (try p.next()).start;
    // Invalid XML tolerated: iteration ends at the bare attribute.
    try testing.expect(a.attr("x") == null);
    var it = a.attrs();
    try testing.expect(it.next() == null);
}

test "end tag with trailing whitespace" {
    const doc = "<a>t</a  >";
    var p = Parser.init(doc);
    _ = try p.next();
    _ = try p.next();
    try testing.expectEqualStrings("a", (try p.next()).end);
}

test "entity decoding edge cases" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    // Truncated entity at end of input: passes through verbatim.
    try decodeAppend(&out, gpa, "x&amp");
    try testing.expectEqualStrings("x&amp", out.items);

    // Codepoint above U+10FFFF: verbatim.
    out.clearRetainingCapacity();
    try decodeAppend(&out, gpa, "&#x110000;");
    try testing.expectEqualStrings("&#x110000;", out.items);

    // Surrogate half: verbatim.
    out.clearRetainingCapacity();
    try decodeAppend(&out, gpa, "&#xD800;");
    try testing.expectEqualStrings("&#xD800;", out.items);

    // Astral-plane emoji: 4-byte UTF-8.
    out.clearRetainingCapacity();
    try decodeAppend(&out, gpa, "&#x1F600;");
    try testing.expectEqualStrings("\xF0\x9F\x98\x80", out.items);

    // Decimal form.
    out.clearRetainingCapacity();
    try decodeAppend(&out, gpa, "&#65;&#66;");
    try testing.expectEqualStrings("AB", out.items);
}

test "empty and whitespace-only documents" {
    var p1 = Parser.init("");
    try testing.expect(try p1.next() == .eof);

    var p2 = Parser.init("   \n ");
    try testing.expectEqualStrings("   \n ", (try p2.next()).text);
    try testing.expect(try p2.next() == .eof);

    var p3 = Parser.init("\xEF\xBB\xBF");
    try testing.expect(try p3.next() == .eof);
}

test "trailing text after root element" {
    var p = Parser.init("<a>x</a>tail");
    _ = try p.next();
    _ = try p.next();
    _ = try p.next();
    try testing.expectEqualStrings("tail", (try p.next()).text);
    try testing.expect(try p.next() == .eof);
}

test "malformed inputs error instead of mis-slicing" {
    const cases = [_][]const u8{
        "<a attr=\"x", // unterminated tag
        "<a", // EOF inside name
        "</a", // unterminated end tag
        "<!-- foo", // unterminated comment
        "<![CDATA[ foo", // unterminated cdata
        "<?pi foo", // unterminated PI
        "<!DOCTYPE r [", // unterminated doctype subset
    };
    for (cases) |doc| {
        var p = Parser.init(doc);
        // Drain until error; reaching clean eof means we failed to detect.
        const failed = while (true) {
            const ev = p.next() catch break true;
            if (ev == .eof) break false;
        };
        try testing.expect(failed);
    }
}

test "PRNG structural stress: balanced events across SIMD boundaries" {
    const gpa = testing.allocator;

    for ([_]u64{ 0x5eed, 42, 7777 }) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        var doc: std.ArrayList(u8) = .empty;
        defer doc.deinit(gpa);
        try doc.appendSlice(gpa, "<root>");
        var expected: usize = 1;
        for (0..6) |_| expected += try genElem(gpa, rand, 0, &doc);
        try doc.appendSlice(gpa, "</root>");

        var p = Parser.init(doc.items);
        var stack: std.ArrayList([]const u8) = .empty;
        defer stack.deinit(gpa);
        var starts: usize = 0;
        while (true) {
            switch (try p.next()) {
                .start => |st| {
                    starts += 1;
                    try stack.append(gpa, st.name);
                },
                .end => |name| {
                    const open = stack.pop().?;
                    try testing.expectEqualStrings(open, name);
                },
                .eof => break,
                else => {},
            }
        }
        try testing.expectEqual(expected, starts);
        try testing.expectEqual(@as(usize, 0), stack.items.len);
    }
}

/// Random well-formed element with name/text/attr lengths chosen to cross
/// the 16/32-byte vector lanes. Returns how many elements were emitted.
fn genElem(
    gpa: std.mem.Allocator,
    rand: std.Random,
    depth: usize,
    out: *std.ArrayList(u8),
) !usize {
    var name_buf: [12]u8 = undefined;
    const nl = rand.intRangeAtMost(usize, 1, name_buf.len);
    for (name_buf[0..nl]) |*c| c.* = 'a' + rand.uintLessThan(u8, 26);
    const name = name_buf[0..nl];

    try out.append(gpa, '<');
    try out.appendSlice(gpa, name);
    if (rand.boolean()) {
        try out.appendSlice(gpa, " attr=\"");
        for (0..rand.uintLessThan(usize, 40)) |_| try out.append(gpa, 'v');
        try out.append(gpa, '"');
    }

    var count: usize = 1;
    if (depth >= 4 or rand.uintLessThan(u8, 4) == 0) {
        try out.appendSlice(gpa, "/>");
        return count;
    }
    try out.append(gpa, '>');
    for (0..rand.uintLessThan(usize, 4)) |_| {
        if (rand.boolean()) {
            for (0..rand.uintLessThan(usize, 50)) |_| try out.append(gpa, 't');
        }
        count += try genElem(gpa, rand, depth + 1, out);
    }
    try out.appendSlice(gpa, "</");
    try out.appendSlice(gpa, name);
    try out.append(gpa, '>');
    return count;
}

// ── Escaping (the writer-side inverse of decodeAppend) ─────────────────────

pub const EscapeMode = enum { text, attr };

/// Append `raw` with XML special characters replaced by entities.
/// `.text` escapes `< > &`; `.attr` additionally escapes both quote kinds,
/// so values are safe inside either quoting style.
pub fn escapeAppend(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    raw: []const u8,
    mode: EscapeMode,
) !void {
    var start: usize = 0;
    for (raw, 0..) |c, i| {
        const rep: ?[]const u8 = switch (c) {
            '<' => "&lt;",
            '>' => "&gt;",
            '&' => "&amp;",
            '"' => if (mode == .attr) "&quot;" else null,
            '\'' => if (mode == .attr) "&apos;" else null,
            else => null,
        };
        if (rep) |r| {
            try out.appendSlice(gpa, raw[start..i]);
            try out.appendSlice(gpa, r);
            start = i + 1;
        }
    }
    try out.appendSlice(gpa, raw[start..]);
}
