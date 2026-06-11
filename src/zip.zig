//! In-memory ZIP (PKZIP) reader — the container layer of OPC packages.
//!
//! Office Open XML files (.docx/.xlsx/.pptx) are ZIP archives. This reader
//! works over a single `[]const u8` of the whole file (read or mmap'd by the
//! caller), parses the central directory once, and extracts entries on
//! demand. Entry names are zero-copy slices into the archive bytes.
//!
//! Supports: store (0) and deflate (8) methods, zip64 sizes/offsets.
//! Rejects: encrypted entries, other compression methods.

const std = @import("std");
const flate = std.compress.flate;

pub const Error = error{
    NotZip,
    BadZip,
    TruncatedZip,
    Encrypted,
    UnsupportedCompression,
    CrcMismatch,
    OutOfMemory,
};

const eocd_sig: u32 = 0x06054b50;
const eocd64_locator_sig: u32 = 0x07064b50;
const eocd64_sig: u32 = 0x06064b50;
const central_sig: u32 = 0x02014b50;
const local_sig: u32 = 0x04034b50;

pub const Entry = struct {
    /// Zero-copy slice into the archive bytes.
    name: []const u8,
    method: u16,
    crc32: u32,
    compressed_size: u64,
    uncompressed_size: u64,
    local_header_offset: u64,
    flags: u16,
};

pub const ExtractOptions = struct {
    /// CRC32-check the decompressed bytes. Off in the hot path, on in tests.
    verify_crc: bool = false,
};

fn readU16(data: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, data[off..][0..2], .little);
}
fn readU32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}
fn readU64(data: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, data[off..][0..8], .little);
}

pub const Archive = struct {
    /// Borrowed; must outlive the Archive.
    data: []const u8,
    entries: []Entry,
    by_name: std.StringHashMap(u32),

    pub fn open(gpa: std.mem.Allocator, data: []const u8) Error!Archive {
        if (data.len < 22) return Error.NotZip;

        const eocd = findEocd(data) orelse return Error.NotZip;
        var entry_count: u64 = readU16(data, eocd + 10);
        var cd_offset: u64 = readU32(data, eocd + 16);
        const cd_size: u64 = readU32(data, eocd + 12);

        // zip64: sentinel values redirect to the zip64 EOCD record.
        if (entry_count == 0xFFFF or cd_offset == 0xFFFF_FFFF or cd_size == 0xFFFF_FFFF) {
            if (eocd >= 20 and readU32(data, eocd - 20) == eocd64_locator_sig) {
                const rec64 = readU64(data, eocd - 20 + 8);
                if (rec64 + 56 > data.len or readU32(data, @intCast(rec64)) != eocd64_sig)
                    return Error.BadZip;
                const r: usize = @intCast(rec64);
                entry_count = readU64(data, r + 32);
                cd_offset = readU64(data, r + 48);
            }
        }
        if (cd_offset >= data.len) return Error.BadZip;

        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(gpa);
        var by_name = std.StringHashMap(u32).init(gpa);
        errdefer by_name.deinit();

        var pos: usize = @intCast(cd_offset);
        var i: u64 = 0;
        while (i < entry_count) : (i += 1) {
            if (pos + 46 > data.len) return Error.TruncatedZip;
            if (readU32(data, pos) != central_sig) return Error.BadZip;

            const name_len: usize = readU16(data, pos + 28);
            const extra_len: usize = readU16(data, pos + 30);
            const comment_len: usize = readU16(data, pos + 32);
            if (pos + 46 + name_len + extra_len + comment_len > data.len)
                return Error.TruncatedZip;

            var e: Entry = .{
                .name = data[pos + 46 ..][0..name_len],
                .method = readU16(data, pos + 10),
                .crc32 = readU32(data, pos + 16),
                .compressed_size = readU32(data, pos + 20),
                .uncompressed_size = readU32(data, pos + 24),
                .local_header_offset = readU32(data, pos + 42),
                .flags = readU16(data, pos + 8),
            };

            // zip64 extra field (id 0x0001): u64 values for any 0xFFFFFFFF field,
            // in spec order: uncompressed, compressed, local offset.
            if (e.uncompressed_size == 0xFFFF_FFFF or
                e.compressed_size == 0xFFFF_FFFF or
                e.local_header_offset == 0xFFFF_FFFF)
            {
                const extra = data[pos + 46 + name_len ..][0..extra_len];
                var xp: usize = 0;
                while (xp + 4 <= extra.len) {
                    const id = readU16(extra, xp);
                    const sz: usize = readU16(extra, xp + 2);
                    if (xp + 4 + sz > extra.len) break;
                    if (id == 0x0001) {
                        var fp: usize = xp + 4;
                        if (e.uncompressed_size == 0xFFFF_FFFF and fp + 8 <= xp + 4 + sz) {
                            e.uncompressed_size = readU64(extra, fp);
                            fp += 8;
                        }
                        if (e.compressed_size == 0xFFFF_FFFF and fp + 8 <= xp + 4 + sz) {
                            e.compressed_size = readU64(extra, fp);
                            fp += 8;
                        }
                        if (e.local_header_offset == 0xFFFF_FFFF and fp + 8 <= xp + 4 + sz) {
                            e.local_header_offset = readU64(extra, fp);
                            fp += 8;
                        }
                        break;
                    }
                    xp += 4 + sz;
                }
            }

            const idx: u32 = @intCast(entries.items.len);
            try entries.append(gpa, e);
            try by_name.put(e.name, idx);
            pos += 46 + name_len + extra_len + comment_len;
        }

        return .{
            .data = data,
            .entries = try entries.toOwnedSlice(gpa),
            .by_name = by_name,
        };
    }

    pub fn deinit(self: *Archive, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
        self.by_name.deinit();
        self.* = undefined;
    }

    pub fn find(self: *const Archive, name: []const u8) ?*const Entry {
        const idx = self.by_name.get(name) orelse return null;
        return &self.entries[idx];
    }

    /// Slice of the raw (still compressed) entry payload.
    pub fn compressedData(self: *const Archive, e: *const Entry) Error![]const u8 {
        const lo: usize = std.math.cast(usize, e.local_header_offset) orelse return Error.BadZip;
        if (lo + 30 > self.data.len) return Error.TruncatedZip;
        if (readU32(self.data, lo) != local_sig) return Error.BadZip;
        // Sizes come from the central directory (the local copies may be zeroed
        // when bit 3 / data descriptor is set), but name/extra lengths must come
        // from the local header — they can differ from the central record.
        const name_len: usize = readU16(self.data, lo + 26);
        const extra_len: usize = readU16(self.data, lo + 28);
        const start = lo + 30 + name_len + extra_len;
        const csize = std.math.cast(usize, e.compressed_size) orelse return Error.BadZip;
        if (start + csize > self.data.len) return Error.TruncatedZip;
        return self.data[start..][0..csize];
    }

    /// Decompress an entry into a caller-owned buffer of exactly
    /// `uncompressed_size` bytes.
    pub fn extractAlloc(
        self: *const Archive,
        gpa: std.mem.Allocator,
        e: *const Entry,
        opts: ExtractOptions,
    ) Error![]u8 {
        if (e.flags & 0x1 != 0) return Error.Encrypted;
        const comp = try self.compressedData(e);
        const usize_len = std.math.cast(usize, e.uncompressed_size) orelse return Error.BadZip;
        const out = try gpa.alloc(u8, usize_len);
        errdefer gpa.free(out);

        switch (e.method) {
            0 => {
                if (comp.len != out.len) return Error.BadZip;
                @memcpy(out, comp);
            },
            8 => {
                var in: std.Io.Reader = .fixed(comp);
                var window: [flate.max_window_len]u8 = undefined;
                var dec: flate.Decompress = .init(&in, .raw, &window);
                var w: std.Io.Writer = .fixed(out);
                dec.reader.streamExact64(&w, e.uncompressed_size) catch
                    return Error.BadZip;
            },
            else => return Error.UnsupportedCompression,
        }

        if (opts.verify_crc and std.hash.Crc32.hash(out) != e.crc32)
            return Error.CrcMismatch;
        return out;
    }
};

fn findEocd(data: []const u8) ?usize {
    // EOCD is 22 bytes + a comment of up to 65535 bytes at the very end.
    const max_back = @min(data.len, 22 + 65535);
    var i: usize = data.len - 22;
    const stop = data.len - max_back;
    while (true) {
        if (readU32(data, i) == eocd_sig) {
            const comment_len: usize = readU16(data, i + 20);
            if (i + 22 + comment_len == data.len) return i;
        }
        if (i == stop) return null;
        i -= 1;
    }
}

// ── Test helpers: build a stored-method zip in memory ─────────────────────

pub const TestFile = struct { name: []const u8, data: []const u8 };

/// Compose a valid stored (method 0) zip — used by tests across modules.
pub fn writeStoredZip(gpa: std.mem.Allocator, files: []const TestFile) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var offsets: std.ArrayList(u64) = .empty;
    defer offsets.deinit(gpa);

    for (files) |f| {
        try offsets.append(gpa, buf.items.len);
        var hdr: [30]u8 = [_]u8{0} ** 30;
        std.mem.writeInt(u32, hdr[0..4], local_sig, .little);
        std.mem.writeInt(u16, hdr[4..6], 20, .little);
        std.mem.writeInt(u32, hdr[14..18], std.hash.Crc32.hash(f.data), .little);
        std.mem.writeInt(u32, hdr[18..22], @intCast(f.data.len), .little);
        std.mem.writeInt(u32, hdr[22..26], @intCast(f.data.len), .little);
        std.mem.writeInt(u16, hdr[26..28], @intCast(f.name.len), .little);
        try buf.appendSlice(gpa, &hdr);
        try buf.appendSlice(gpa, f.name);
        try buf.appendSlice(gpa, f.data);
    }

    const cd_start = buf.items.len;
    for (files, offsets.items) |f, off| {
        var hdr: [46]u8 = [_]u8{0} ** 46;
        std.mem.writeInt(u32, hdr[0..4], central_sig, .little);
        std.mem.writeInt(u16, hdr[4..6], 20, .little);
        std.mem.writeInt(u16, hdr[6..8], 20, .little);
        std.mem.writeInt(u32, hdr[16..20], std.hash.Crc32.hash(f.data), .little);
        std.mem.writeInt(u32, hdr[20..24], @intCast(f.data.len), .little);
        std.mem.writeInt(u32, hdr[24..28], @intCast(f.data.len), .little);
        std.mem.writeInt(u16, hdr[28..30], @intCast(f.name.len), .little);
        std.mem.writeInt(u32, hdr[42..46], @intCast(off), .little);
        try buf.appendSlice(gpa, &hdr);
        try buf.appendSlice(gpa, f.name);
    }
    const cd_size = buf.items.len - cd_start;

    var eocd: [22]u8 = [_]u8{0} ** 22;
    std.mem.writeInt(u32, eocd[0..4], eocd_sig, .little);
    std.mem.writeInt(u16, eocd[8..10], @intCast(files.len), .little);
    std.mem.writeInt(u16, eocd[10..12], @intCast(files.len), .little);
    std.mem.writeInt(u32, eocd[12..16], @intCast(cd_size), .little);
    std.mem.writeInt(u32, eocd[16..20], @intCast(cd_start), .little);
    try buf.appendSlice(gpa, &eocd);

    return buf.toOwnedSlice(gpa);
}

const testing = std.testing;

test "stored zip roundtrip" {
    const gpa = testing.allocator;
    const zip_bytes = try writeStoredZip(gpa, &.{
        .{ .name = "hello.txt", .data = "hello zip world" },
        .{ .name = "dir/nested.xml", .data = "<a b=\"c\">text</a>" },
    });
    defer gpa.free(zip_bytes);

    var ar = try Archive.open(gpa, zip_bytes);
    defer ar.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), ar.entries.len);
    const e = ar.find("dir/nested.xml").?;
    const out = try ar.extractAlloc(gpa, e, .{ .verify_crc = true });
    defer gpa.free(out);
    try testing.expectEqualStrings("<a b=\"c\">text</a>", out);

    try testing.expect(ar.find("missing") == null);
}

test "deflate roundtrip via flate.Compress" {
    const gpa = testing.allocator;

    // Compress a payload with std's deflate, wrap it in a zip by hand, read back.
    const payload =
        "<root>" ++ ("<item attr=\"value\">repetitive text for deflate</item>" ** 50) ++ "</root>";

    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer compressed.deinit();
    var cbuf: [flate.max_window_len]u8 = undefined;
    var comp: flate.Compress = try .init(&compressed.writer, &cbuf, .raw, .default);
    try comp.writer.writeAll(payload);
    try comp.finish();
    const cdata = compressed.written();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var hdr: [30]u8 = [_]u8{0} ** 30;
    std.mem.writeInt(u32, hdr[0..4], local_sig, .little);
    std.mem.writeInt(u16, hdr[8..10], 8, .little); // deflate
    std.mem.writeInt(u32, hdr[14..18], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, hdr[18..22], @intCast(cdata.len), .little);
    std.mem.writeInt(u32, hdr[22..26], @intCast(payload.len), .little);
    std.mem.writeInt(u16, hdr[26..28], 5, .little);
    try buf.appendSlice(gpa, &hdr);
    try buf.appendSlice(gpa, "a.xml");
    try buf.appendSlice(gpa, cdata);

    const cd_start = buf.items.len;
    var chdr: [46]u8 = [_]u8{0} ** 46;
    std.mem.writeInt(u32, chdr[0..4], central_sig, .little);
    std.mem.writeInt(u16, chdr[10..12], 8, .little); // deflate
    std.mem.writeInt(u32, chdr[16..20], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, chdr[20..24], @intCast(cdata.len), .little);
    std.mem.writeInt(u32, chdr[24..28], @intCast(payload.len), .little);
    std.mem.writeInt(u16, chdr[28..30], 5, .little);
    try buf.appendSlice(gpa, &chdr);
    try buf.appendSlice(gpa, "a.xml");
    const cd_size = buf.items.len - cd_start;

    var eocd: [22]u8 = [_]u8{0} ** 22;
    std.mem.writeInt(u32, eocd[0..4], eocd_sig, .little);
    std.mem.writeInt(u16, eocd[8..10], 1, .little);
    std.mem.writeInt(u16, eocd[10..12], 1, .little);
    std.mem.writeInt(u32, eocd[12..16], @intCast(cd_size), .little);
    std.mem.writeInt(u32, eocd[16..20], @intCast(cd_start), .little);
    try buf.appendSlice(gpa, &eocd);

    var ar = try Archive.open(gpa, buf.items);
    defer ar.deinit(gpa);
    const e = ar.find("a.xml").?;
    try testing.expectEqual(@as(u16, 8), e.method);
    const out = try ar.extractAlloc(gpa, e, .{ .verify_crc = true });
    defer gpa.free(out);
    try testing.expectEqualStrings(payload, out);
}

// ── Spec edge cases ────────────────────────────────────────────────────────

test "zip64 extra field overrides sentinel sizes and offset" {
    const gpa = testing.allocator;
    const payload = "0123456789";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // Local header: plain (zip64 only in the central record).
    var lh: [30]u8 = [_]u8{0} ** 30;
    std.mem.writeInt(u32, lh[0..4], local_sig, .little);
    std.mem.writeInt(u32, lh[14..18], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, lh[18..22], payload.len, .little);
    std.mem.writeInt(u32, lh[22..26], payload.len, .little);
    std.mem.writeInt(u16, lh[26..28], 7, .little);
    try buf.appendSlice(gpa, &lh);
    try buf.appendSlice(gpa, "big.bin");
    try buf.appendSlice(gpa, payload);

    // Central record: all three fields sentineled, real values in extra 0x0001.
    const cd_start = buf.items.len;
    var ch: [46]u8 = [_]u8{0} ** 46;
    std.mem.writeInt(u32, ch[0..4], central_sig, .little);
    std.mem.writeInt(u32, ch[16..20], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, ch[20..24], 0xFFFF_FFFF, .little);
    std.mem.writeInt(u32, ch[24..28], 0xFFFF_FFFF, .little);
    std.mem.writeInt(u16, ch[28..30], 7, .little);
    std.mem.writeInt(u16, ch[30..32], 28, .little); // extra len
    std.mem.writeInt(u32, ch[42..46], 0xFFFF_FFFF, .little);
    try buf.appendSlice(gpa, &ch);
    try buf.appendSlice(gpa, "big.bin");
    var extra: [28]u8 = [_]u8{0} ** 28;
    std.mem.writeInt(u16, extra[0..2], 0x0001, .little);
    std.mem.writeInt(u16, extra[2..4], 24, .little);
    std.mem.writeInt(u64, extra[4..12], payload.len, .little); // uncompressed
    std.mem.writeInt(u64, extra[12..20], payload.len, .little); // compressed
    std.mem.writeInt(u64, extra[20..28], 0, .little); // local offset
    try buf.appendSlice(gpa, &extra);
    const cd_size = buf.items.len - cd_start;

    var eocd: [22]u8 = [_]u8{0} ** 22;
    std.mem.writeInt(u32, eocd[0..4], eocd_sig, .little);
    std.mem.writeInt(u16, eocd[8..10], 1, .little);
    std.mem.writeInt(u16, eocd[10..12], 1, .little);
    std.mem.writeInt(u32, eocd[12..16], @intCast(cd_size), .little);
    std.mem.writeInt(u32, eocd[16..20], @intCast(cd_start), .little);
    try buf.appendSlice(gpa, &eocd);

    var ar = try Archive.open(gpa, buf.items);
    defer ar.deinit(gpa);
    const e = ar.find("big.bin").?;
    try testing.expectEqual(@as(u64, payload.len), e.uncompressed_size);
    try testing.expectEqual(@as(u64, 0), e.local_header_offset);
    const out = try ar.extractAlloc(gpa, e, .{ .verify_crc = true });
    defer gpa.free(out);
    try testing.expectEqualStrings(payload, out);
}

/// Offset of the first central-directory record, straight from the EOCD.
fn cdStart(data: []const u8) usize {
    return readU32(data, data.len - 22 + 16);
}

test "encrypted entries are rejected" {
    const gpa = testing.allocator;
    const base = try writeStoredZip(gpa, &.{.{ .name = "a.txt", .data = "secret" }});
    defer gpa.free(base);
    const data = try gpa.dupe(u8, base);
    defer gpa.free(data);
    // Central record flags live at +8.
    std.mem.writeInt(u16, data[cdStart(data) + 8 ..][0..2], 0x0001, .little);

    var ar = try Archive.open(gpa, data);
    defer ar.deinit(gpa);
    try testing.expectError(
        Error.Encrypted,
        ar.extractAlloc(gpa, ar.find("a.txt").?, .{}),
    );
}

test "unsupported compression method is rejected" {
    const gpa = testing.allocator;
    const base = try writeStoredZip(gpa, &.{.{ .name = "a.txt", .data = "x" }});
    defer gpa.free(base);
    const data = try gpa.dupe(u8, base);
    defer gpa.free(data);
    // Central record method lives at +10. 99 = AES marker.
    std.mem.writeInt(u16, data[cdStart(data) + 10 ..][0..2], 99, .little);

    var ar = try Archive.open(gpa, data);
    defer ar.deinit(gpa);
    try testing.expectError(
        Error.UnsupportedCompression,
        ar.extractAlloc(gpa, ar.find("a.txt").?, .{}),
    );
}

test "crc mismatch detected only when verification is on" {
    const gpa = testing.allocator;
    const base = try writeStoredZip(gpa, &.{.{ .name = "a.txt", .data = "payload" }});
    defer gpa.free(base);
    const data = try gpa.dupe(u8, base);
    defer gpa.free(data);
    // Corrupt the central-record CRC at +16.
    data[cdStart(data) + 16] ^= 0xFF;

    var ar = try Archive.open(gpa, data);
    defer ar.deinit(gpa);
    const e = ar.find("a.txt").?;

    const ok = try ar.extractAlloc(gpa, e, .{});
    defer gpa.free(ok);
    try testing.expectEqualStrings("payload", ok);

    try testing.expectError(
        Error.CrcMismatch,
        ar.extractAlloc(gpa, e, .{ .verify_crc = true }),
    );
}

test "EOCD found behind a trailing archive comment" {
    const gpa = testing.allocator;
    const base = try writeStoredZip(gpa, &.{.{ .name = "a.txt", .data = "hi" }});
    defer gpa.free(base);

    const comment = "made by nanoxml tests";
    var data = try gpa.alloc(u8, base.len + comment.len);
    defer gpa.free(data);
    @memcpy(data[0..base.len], base);
    @memcpy(data[base.len..], comment);
    // comment_len is the last EOCD field (offset +20 = base.len - 2).
    std.mem.writeInt(u16, data[base.len - 2 ..][0..2], comment.len, .little);

    var ar = try Archive.open(gpa, data);
    defer ar.deinit(gpa);
    const out = try ar.extractAlloc(gpa, ar.find("a.txt").?, .{ .verify_crc = true });
    defer gpa.free(out);
    try testing.expectEqualStrings("hi", out);
}

test "data descriptor: zeroed local sizes, central directory authoritative" {
    const gpa = testing.allocator;
    const payload = "streamed data";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // Local header with flag bit 3: sizes/crc all zero.
    var lh: [30]u8 = [_]u8{0} ** 30;
    std.mem.writeInt(u32, lh[0..4], local_sig, .little);
    std.mem.writeInt(u16, lh[6..8], 0x0008, .little);
    std.mem.writeInt(u16, lh[26..28], 5, .little);
    try buf.appendSlice(gpa, &lh);
    try buf.appendSlice(gpa, "s.bin");
    try buf.appendSlice(gpa, payload);
    // Data descriptor (with signature form).
    var dd: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, dd[0..4], 0x08074b50, .little);
    std.mem.writeInt(u32, dd[4..8], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, dd[8..12], payload.len, .little);
    std.mem.writeInt(u32, dd[12..16], payload.len, .little);
    try buf.appendSlice(gpa, &dd);

    const cd_start_pos = buf.items.len;
    var ch: [46]u8 = [_]u8{0} ** 46;
    std.mem.writeInt(u32, ch[0..4], central_sig, .little);
    std.mem.writeInt(u16, ch[8..10], 0x0008, .little);
    std.mem.writeInt(u32, ch[16..20], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, ch[20..24], payload.len, .little);
    std.mem.writeInt(u32, ch[24..28], payload.len, .little);
    std.mem.writeInt(u16, ch[28..30], 5, .little);
    try buf.appendSlice(gpa, &ch);
    try buf.appendSlice(gpa, "s.bin");
    const cd_size = buf.items.len - cd_start_pos;

    var eocd: [22]u8 = [_]u8{0} ** 22;
    std.mem.writeInt(u32, eocd[0..4], eocd_sig, .little);
    std.mem.writeInt(u16, eocd[8..10], 1, .little);
    std.mem.writeInt(u16, eocd[10..12], 1, .little);
    std.mem.writeInt(u32, eocd[12..16], @intCast(cd_size), .little);
    std.mem.writeInt(u32, eocd[16..20], @intCast(cd_start_pos), .little);
    try buf.appendSlice(gpa, &eocd);

    var ar = try Archive.open(gpa, buf.items);
    defer ar.deinit(gpa);
    const out = try ar.extractAlloc(gpa, ar.find("s.bin").?, .{ .verify_crc = true });
    defer gpa.free(out);
    try testing.expectEqualStrings(payload, out);
}

test "empty archive opens with zero entries" {
    const gpa = testing.allocator;
    var eocd: [22]u8 = [_]u8{0} ** 22;
    std.mem.writeInt(u32, eocd[0..4], eocd_sig, .little);

    var ar = try Archive.open(gpa, &eocd);
    defer ar.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), ar.entries.len);
}

test "local header name length differing from central record" {
    const gpa = testing.allocator;
    const payload = "DATA";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // Local header claims a 9-char name; central says 5. Data offset must
    // honor the local lengths.
    var lh: [30]u8 = [_]u8{0} ** 30;
    std.mem.writeInt(u32, lh[0..4], local_sig, .little);
    std.mem.writeInt(u32, lh[14..18], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, lh[18..22], payload.len, .little);
    std.mem.writeInt(u32, lh[22..26], payload.len, .little);
    std.mem.writeInt(u16, lh[26..28], 9, .little);
    try buf.appendSlice(gpa, &lh);
    try buf.appendSlice(gpa, "abcdefghi");
    try buf.appendSlice(gpa, payload);

    const cd_start_pos = buf.items.len;
    var ch: [46]u8 = [_]u8{0} ** 46;
    std.mem.writeInt(u32, ch[0..4], central_sig, .little);
    std.mem.writeInt(u32, ch[16..20], std.hash.Crc32.hash(payload), .little);
    std.mem.writeInt(u32, ch[20..24], payload.len, .little);
    std.mem.writeInt(u32, ch[24..28], payload.len, .little);
    std.mem.writeInt(u16, ch[28..30], 5, .little);
    try buf.appendSlice(gpa, &ch);
    try buf.appendSlice(gpa, "x.bin");
    const cd_size = buf.items.len - cd_start_pos;

    var eocd: [22]u8 = [_]u8{0} ** 22;
    std.mem.writeInt(u32, eocd[0..4], eocd_sig, .little);
    std.mem.writeInt(u16, eocd[8..10], 1, .little);
    std.mem.writeInt(u16, eocd[10..12], 1, .little);
    std.mem.writeInt(u32, eocd[12..16], @intCast(cd_size), .little);
    std.mem.writeInt(u32, eocd[16..20], @intCast(cd_start_pos), .little);
    try buf.appendSlice(gpa, &eocd);

    var ar = try Archive.open(gpa, buf.items);
    defer ar.deinit(gpa);
    const out = try ar.extractAlloc(gpa, ar.find("x.bin").?, .{ .verify_crc = true });
    defer gpa.free(out);
    try testing.expectEqualStrings(payload, out);
}

test "non-zip and truncated inputs error cleanly" {
    const gpa = testing.allocator;
    try testing.expectError(Error.NotZip, Archive.open(gpa, "not a zip at all......"));
    try testing.expectError(Error.NotZip, Archive.open(gpa, "tiny"));
}

// ── Writer ─────────────────────────────────────────────────────────────────

pub const WriteError = error{ OutOfMemory, TooLarge, WriteFailed };

pub const CompressMethod = enum { store, deflate };

/// Streaming zip composer. `addFile` deflates (falling back to store when
/// deflate doesn't shrink the payload); `addRaw` copies an already-
/// compressed entry verbatim — that's what makes package round-trips cheap.
/// No zip64: entries and the directory must stay under 4 GiB / 65535 files,
/// which holds for any real OOXML package this library writes.
pub const Writer = struct {
    buf: std.ArrayList(u8) = .empty,
    central: std.ArrayList(u8) = .empty,
    count: u64 = 0,

    pub fn deinit(self: *Writer, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
        self.central.deinit(gpa);
        self.* = undefined;
    }

    pub fn addFile(
        self: *Writer,
        gpa: std.mem.Allocator,
        name: []const u8,
        data: []const u8,
        method: CompressMethod,
    ) WriteError!void {
        const crc = std.hash.Crc32.hash(data);
        switch (method) {
            .store => try self.addEntry(gpa, name, 0, crc, data.len, data),
            .deflate => {
                var compressed: std.Io.Writer.Allocating =
                    try .initCapacity(gpa, @max(64, data.len / 2));
                defer compressed.deinit();
                var window: [flate.max_window_len]u8 = undefined;
                var comp: flate.Compress =
                    flate.Compress.init(&compressed.writer, &window, .raw, .default) catch
                        return WriteError.WriteFailed;
                comp.writer.writeAll(data) catch return WriteError.WriteFailed;
                comp.finish() catch return WriteError.WriteFailed;
                const cdata = compressed.written();
                if (cdata.len < data.len) {
                    try self.addEntry(gpa, name, 8, crc, data.len, cdata);
                } else {
                    // Deflate would grow it (already-compressed or tiny data).
                    try self.addEntry(gpa, name, 0, crc, data.len, data);
                }
            },
        }
    }

    /// Copy an entry that is already in its on-disk form (e.g. straight out
    /// of another archive) without recompressing.
    pub fn addRaw(
        self: *Writer,
        gpa: std.mem.Allocator,
        name: []const u8,
        method: u16,
        crc: u32,
        uncompressed_size: u64,
        compressed: []const u8,
    ) WriteError!void {
        const usz = std.math.cast(usize, uncompressed_size) orelse return WriteError.TooLarge;
        try self.addEntry(gpa, name, method, crc, usz, compressed);
    }

    fn addEntry(
        self: *Writer,
        gpa: std.mem.Allocator,
        name: []const u8,
        method: u16,
        crc: u32,
        uncompressed_size: usize,
        payload: []const u8,
    ) WriteError!void {
        if (uncompressed_size > 0xFFFF_FFFE or payload.len > 0xFFFF_FFFE or
            name.len > 0xFFFF or self.buf.items.len > 0xFFFF_FFFE or
            self.count >= 0xFFFF)
            return WriteError.TooLarge;
        const offset: u32 = @intCast(self.buf.items.len);

        var lh: [30]u8 = [_]u8{0} ** 30;
        std.mem.writeInt(u32, lh[0..4], local_sig, .little);
        std.mem.writeInt(u16, lh[4..6], 20, .little); // version needed
        std.mem.writeInt(u16, lh[8..10], method, .little);
        std.mem.writeInt(u32, lh[14..18], crc, .little);
        std.mem.writeInt(u32, lh[18..22], @intCast(payload.len), .little);
        std.mem.writeInt(u32, lh[22..26], @intCast(uncompressed_size), .little);
        std.mem.writeInt(u16, lh[26..28], @intCast(name.len), .little);
        try self.buf.appendSlice(gpa, &lh);
        try self.buf.appendSlice(gpa, name);
        try self.buf.appendSlice(gpa, payload);

        var ch: [46]u8 = [_]u8{0} ** 46;
        std.mem.writeInt(u32, ch[0..4], central_sig, .little);
        std.mem.writeInt(u16, ch[4..6], 20, .little); // version made by
        std.mem.writeInt(u16, ch[6..8], 20, .little); // version needed
        std.mem.writeInt(u16, ch[10..12], method, .little);
        std.mem.writeInt(u32, ch[16..20], crc, .little);
        std.mem.writeInt(u32, ch[20..24], @intCast(payload.len), .little);
        std.mem.writeInt(u32, ch[24..28], @intCast(uncompressed_size), .little);
        std.mem.writeInt(u16, ch[28..30], @intCast(name.len), .little);
        std.mem.writeInt(u32, ch[42..46], offset, .little);
        try self.central.appendSlice(gpa, &ch);
        try self.central.appendSlice(gpa, name);

        self.count += 1;
    }

    /// Append the central directory + EOCD and return the finished archive.
    /// The Writer remains deinit-able but cannot accept further entries.
    pub fn finish(self: *Writer, gpa: std.mem.Allocator) WriteError![]u8 {
        const cd_start = self.buf.items.len;
        if (cd_start > 0xFFFF_FFFE) return WriteError.TooLarge;
        try self.buf.appendSlice(gpa, self.central.items);
        const cd_size = self.buf.items.len - cd_start;

        var eocd: [22]u8 = [_]u8{0} ** 22;
        std.mem.writeInt(u32, eocd[0..4], eocd_sig, .little);
        std.mem.writeInt(u16, eocd[8..10], @intCast(self.count), .little);
        std.mem.writeInt(u16, eocd[10..12], @intCast(self.count), .little);
        std.mem.writeInt(u32, eocd[12..16], @intCast(cd_size), .little);
        std.mem.writeInt(u32, eocd[16..20], @intCast(cd_start), .little);
        try self.buf.appendSlice(gpa, &eocd);

        return self.buf.toOwnedSlice(gpa);
    }
};

test "writer: empty archive is a valid zip" {
    const gpa = testing.allocator;
    var w = Writer{};
    defer w.deinit(gpa);
    const bytes = try w.finish(gpa);
    defer gpa.free(bytes);
    var ar = try Archive.open(gpa, bytes);
    defer ar.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), ar.entries.len);
}
