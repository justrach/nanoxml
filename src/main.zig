//! nanoxml CLI — open and read .docx/.xlsx/.pptx fast.
//!
//!   nanoxml parts  <file>             list package parts + content types
//!   nanoxml info   <file>             kind, main part, sheet/slide summary
//!   nanoxml text   <file>             extract document text (docx/pptx)
//!   nanoxml sheets <file>             list worksheet names (xlsx)
//!   nanoxml csv    <file> [sheet#]    worksheet as CSV (xlsx)
//!   nanoxml dump   <file> <part>      raw bytes of one part
//!   nanoxml bench  <file> [iters] [full|parse|unzip]
//!   nanoxml new    docx|xlsx|pptx <out-file>   create a document

const std = @import("std");
const nanoxml = @import("nanoxml");
const zip = nanoxml.zip;
const xml = nanoxml.xml;
const opc = nanoxml.opc;
const dom = nanoxml.dom;
const ooxml = nanoxml.ooxml;

pub fn main(init: std.process.Init.Minimal) void {
    mainImpl(init.args.vector) catch |err| switch (err) {
        // stdout pipe closed early (e.g. `nanoxml csv big.xlsx | head`).
        error.WriteFailed => {},
        else => {
            std.debug.print("nanoxml: error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };
}

fn usage() void {
    std.debug.print(
        \\nanoxml — Office Open XML for humans and agents (Zig port of Open-XML-SDK)
        \\
        \\read:
        \\  nanoxml parts     <file> [--json]      parts + content types
        \\  nanoxml info      <file> [--json]      kind, main part, sheets/slides
        \\  nanoxml text      <file>               extract text (docx/pptx)
        \\  nanoxml sheets    <file> [--json]      worksheets (xlsx)
        \\  nanoxml csv       <file> [sheet#]      worksheet as CSV (xlsx)
        \\  nanoxml dump      <file> <part>        raw bytes of one part
        \\  nanoxml validate  <file> [--json]      diagnostics; exit 1 if invalid
        \\
        \\write (read <file>, save to --out PATH, default: in place):
        \\  nanoxml set-cell  <file> <sheet#> <A1> <value> [--string|--number]
        \\  nanoxml set-props <file> [--title T] [--creator C] [--subject S] [--description D]
        \\  nanoxml set-part  <file> <part> [content-file|-]   (- or omitted = stdin)
        \\  nanoxml rm-part   <file> <part>
        \\  nanoxml roundtrip <file> <out>         re-serialize main part via DOM
        \\
        \\create:
        \\  nanoxml new       docx|xlsx|pptx <out>
        \\  nanoxml from-csv  <csv-file|-> <out.xlsx> [--sheet NAME]
        \\  nanoxml from-text <text-file|-> <out.docx> [--title T]   line = paragraph
        \\
        \\other:
        \\  nanoxml bench     <file> [iters] [full|parse|unzip]
        \\
        \\exit codes: 0 ok · 1 error or failed validation
        \\
    , .{});
}

const Opts = struct {
    json: bool = false,
    force_number: bool = false,
    force_string: bool = false,
    out: ?[]const u8 = null,
    title: ?[]const u8 = null,
    creator: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    description: ?[]const u8 = null,
    sheet: ?[]const u8 = null,
};

fn mainImpl(argv: []const [*:0]const u8) !void {
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Flags may appear anywhere; everything else is positional.
    var pos: std.ArrayList([]const u8) = .empty;
    var o: Opts = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (!std.mem.startsWith(u8, a, "--")) {
            try pos.append(arena, a);
        } else if (std.mem.eql(u8, a, "--json")) {
            o.json = true;
        } else if (std.mem.eql(u8, a, "--number")) {
            o.force_number = true;
        } else if (std.mem.eql(u8, a, "--string")) {
            o.force_string = true;
        } else {
            const slot: *?[]const u8 = if (std.mem.eql(u8, a, "--out"))
                &o.out
            else if (std.mem.eql(u8, a, "--title"))
                &o.title
            else if (std.mem.eql(u8, a, "--creator"))
                &o.creator
            else if (std.mem.eql(u8, a, "--subject"))
                &o.subject
            else if (std.mem.eql(u8, a, "--description"))
                &o.description
            else if (std.mem.eql(u8, a, "--sheet"))
                &o.sheet
            else {
                std.debug.print("unknown flag: {s}\n\n", .{a});
                usage();
                return error.Usage;
            };
            i += 1;
            if (i >= argv.len) {
                usage();
                return error.Usage;
            }
            slot.* = std.mem.span(argv[i]);
        }
    }
    if (pos.items.len < 2) {
        usage();
        return;
    }
    const args = pos.items;
    const cmd = args[0];
    const path = args[1];

    // Commands that create output without opening an existing package.
    if (std.mem.eql(u8, cmd, "new")) {
        if (args.len < 3) return usage();
        try cmdNew(arena, io, path, args[2]);
        return;
    }
    if (std.mem.eql(u8, cmd, "from-csv")) {
        if (args.len < 3) return usage();
        try cmdFromCsv(arena, io, path, args[2], o);
        return;
    }
    if (std.mem.eql(u8, cmd, "from-text")) {
        if (args.len < 3) return usage();
        try cmdFromText(arena, io, path, args[2], o);
        return;
    }

    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(2 << 30));

    // Format into memory, emit with one raw write loop at the end. The
    // threaded std.Io stdout writer reorders/drops tail bytes across quick
    // process exits; direct write(2) is boring and correct (codedb's cio
    // does the same).
    var aw: std.Io.Writer.Allocating = try .initCapacity(arena, 64 * 1024);
    const w = &aw.writer;
    defer writeAllRaw(aw.written());

    if (std.mem.eql(u8, cmd, "parts")) {
        try cmdParts(arena, data, o.json, w);
    } else if (std.mem.eql(u8, cmd, "info")) {
        try cmdInfo(arena, data, o.json, w);
    } else if (std.mem.eql(u8, cmd, "text")) {
        try cmdText(arena, data, w);
    } else if (std.mem.eql(u8, cmd, "sheets")) {
        try cmdSheets(arena, data, o.json, w);
    } else if (std.mem.eql(u8, cmd, "csv")) {
        const sheet_idx: usize = if (args.len > 2)
            try std.fmt.parseInt(usize, args[2], 10)
        else
            0;
        try cmdCsv(arena, data, sheet_idx, w);
    } else if (std.mem.eql(u8, cmd, "dump")) {
        if (args.len < 3) return usage();
        try cmdDump(arena, data, args[2], w);
    } else if (std.mem.eql(u8, cmd, "validate")) {
        try cmdValidate(arena, data, o.json, w);
    } else if (std.mem.eql(u8, cmd, "roundtrip")) {
        if (args.len < 3) return usage();
        try cmdRoundtrip(arena, io, data, args[2]);
    } else if (std.mem.eql(u8, cmd, "set-cell")) {
        if (args.len < 5) return usage();
        try cmdSetCell(arena, io, data, args[2], args[3], args[4], o, o.out orelse path);
    } else if (std.mem.eql(u8, cmd, "set-props")) {
        try cmdSetProps(arena, io, data, o, o.out orelse path);
    } else if (std.mem.eql(u8, cmd, "set-part")) {
        if (args.len < 3) return usage();
        const content = try readContentArg(arena, io, if (args.len > 3) args[3] else "-");
        try cmdSetPart(arena, io, data, args[2], content, o.out orelse path);
    } else if (std.mem.eql(u8, cmd, "rm-part")) {
        if (args.len < 3) return usage();
        try cmdRmPart(arena, io, data, args[2], o.out orelse path);
    } else if (std.mem.eql(u8, cmd, "bench")) {
        const iters: usize = if (args.len > 2)
            try std.fmt.parseInt(usize, args[2], 10)
        else
            10;
        const mode = if (args.len > 3) args[3] else "full";
        try cmdBench(io, data, path, iters, mode, w);
    } else {
        usage();
    }
}

/// Direct, ordered, EPIPE-tolerant stdout.
fn writeAllRaw(bytes: []const u8) void {
    var rem = bytes;
    while (rem.len > 0) {
        const n = std.c.write(1, rem.ptr, rem.len);
        if (n <= 0) return; // EPIPE (e.g. `| head`) or hard error: stop.
        rem = rem[@intCast(n)..];
    }
}

fn methodName(method: u16) []const u8 {
    return switch (method) {
        0 => "store",
        8 => "deflate",
        else => "other",
    };
}

/// JSON string literal (quotes + escapes) appended to `w`.
fn jsonEsc(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (c < 0x20)
                try w.print("\\u{x:0>4}", .{c})
            else
                try w.writeAll(&.{c}),
        }
    }
    try w.writeAll("\"");
}

fn cmdParts(gpa: std.mem.Allocator, data: []const u8, json: bool, w: *std.Io.Writer) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();

    if (json) {
        try w.writeAll("{\"parts\":[");
        for (pkg.archive.entries, 0..) |e, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"name\":");
            try jsonEsc(w, e.name);
            try w.print(",\"size\":{d},\"method\":\"{s}\",\"content_type\":", .{ e.uncompressed_size, methodName(e.method) });
            if (pkg.contentTypeOf(e.name)) |ct| try jsonEsc(w, ct) else try w.writeAll("null");
            try w.writeAll("}");
        }
        try w.print("],\"count\":{d}}}\n", .{pkg.archive.entries.len});
        return;
    }

    var total_comp: u64 = 0;
    var total_uncomp: u64 = 0;
    for (pkg.archive.entries) |e| {
        total_comp += e.compressed_size;
        total_uncomp += e.uncompressed_size;
        try w.print("{d:>10}  {s:<7}  {s}", .{ e.uncompressed_size, methodName(e.method), e.name });
        if (pkg.contentTypeOf(e.name)) |content_type| {
            try w.print("  [{s}]", .{content_type});
        }
        try w.writeAll("\n");
    }
    try w.print("\n{d} parts, {d} bytes compressed -> {d} bytes uncompressed\n", .{
        pkg.archive.entries.len, total_comp, total_uncomp,
    });
}

fn cmdInfo(gpa: std.mem.Allocator, data: []const u8, json: bool, w: *std.Io.Writer) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    const d = try ooxml.detect(&pkg);

    if (json) {
        try w.print("{{\"kind\":\"{s}\",\"main_part\":", .{@tagName(d.kind)});
        if (d.main_part) |mp| try jsonEsc(w, mp) else try w.writeAll("null");
        try w.print(",\"parts\":{d}", .{pkg.archive.entries.len});
        switch (d.kind) {
            .xlsx => {
                const wb = try ooxml.Workbook.open(&pkg);
                try w.print(",\"shared_strings\":{d},\"sheets\":[", .{wb.shared.len});
                for (wb.sheets, 0..) |s, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("{{\"index\":{d},\"name\":", .{i});
                    try jsonEsc(w, s.name);
                    try w.writeAll(",\"part\":");
                    if (s.part) |p| try jsonEsc(w, p) else try w.writeAll("null");
                    try w.writeAll("}");
                }
                try w.writeAll("]");
            },
            .pptx => {
                const pres = try ooxml.Presentation.open(&pkg);
                try w.print(",\"slides\":{d}", .{pres.slides.len});
            },
            .docx => {
                const bytes = try pkg.getPart(d.main_part.?);
                try w.print(",\"main_part_bytes\":{d}", .{bytes.len});
            },
            .unknown => {},
        }
        try w.writeAll("}\n");
        return;
    }

    try w.print("kind: {s}\n", .{@tagName(d.kind)});
    if (d.main_part) |mp| try w.print("main part: {s}\n", .{mp});
    try w.print("parts: {d}\n", .{pkg.archive.entries.len});

    switch (d.kind) {
        .xlsx => {
            const wb = try ooxml.Workbook.open(&pkg);
            try w.print("shared strings: {d}\nsheets: {d}\n", .{ wb.shared.len, wb.sheets.len });
            for (wb.sheets, 0..) |s, i| {
                try w.print("  {d}: {s} ({s})\n", .{ i, s.name, s.part orelse "?" });
            }
        },
        .pptx => {
            const pres = try ooxml.Presentation.open(&pkg);
            try w.print("slides: {d}\n", .{pres.slides.len});
        },
        .docx => {
            const bytes = try pkg.getPart(d.main_part.?);
            try w.print("document.xml: {d} bytes\n", .{bytes.len});
        },
        .unknown => {},
    }
}

fn cmdText(gpa: std.mem.Allocator, data: []const u8, w: *std.Io.Writer) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    const d = try ooxml.detect(&pkg);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    switch (d.kind) {
        .docx => {
            var doc = try ooxml.WordDocument.open(&pkg);
            try doc.text(gpa, &out);
            try w.writeAll(out.items);
        },
        .pptx => {
            var pres = try ooxml.Presentation.open(&pkg);
            for (0..pres.slides.len) |i| {
                out.clearRetainingCapacity();
                try pres.slideText(gpa, i, &out);
                try w.print("── slide {d} ──\n", .{i + 1});
                try w.writeAll(out.items);
            }
        },
        .xlsx => {
            std.debug.print("this is a spreadsheet; use: nanoxml csv <file> [sheet#]\n", .{});
        },
        .unknown => std.debug.print("not an OOXML document\n", .{}),
    }
}

fn cmdSheets(gpa: std.mem.Allocator, data: []const u8, json: bool, w: *std.Io.Writer) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    const wb = try ooxml.Workbook.open(&pkg);
    if (json) {
        try w.writeAll("[");
        for (wb.sheets, 0..) |s, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"index\":{d},\"name\":", .{i});
            try jsonEsc(w, s.name);
            try w.writeAll(",\"part\":");
            if (s.part) |p| try jsonEsc(w, p) else try w.writeAll("null");
            try w.writeAll("}");
        }
        try w.writeAll("]\n");
        return;
    }
    for (wb.sheets, 0..) |s, i| {
        try w.print("{d}: {s}\n", .{ i, s.name });
    }
}

fn cmdCsv(gpa: std.mem.Allocator, data: []const u8, sheet_idx: usize, w: *std.Io.Writer) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    var wb = try ooxml.Workbook.open(&pkg);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try wb.sheetToCsv(gpa, sheet_idx, &out);
    try w.writeAll(out.items);
}

fn cmdDump(gpa: std.mem.Allocator, data: []const u8, part: []const u8, w: *std.Io.Writer) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    const bytes = try pkg.getPart(part);
    try w.writeAll(bytes);
}

// ── bench ──────────────────────────────────────────────────────────────────

fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

/// One full read of the document; returns (uncompressed xml bytes touched,
/// output bytes produced).
///
/// Arena per iteration (codedb pattern): the typed layer makes millions of
/// small allocations per document — through page_allocator each would be a
/// syscall (14x slowdown, measured); through a bump arena they're free.
fn benchIterFull(backing: std.mem.Allocator, data: []const u8) !struct { u64, u64 } {
    var iter_arena = std.heap.ArenaAllocator.init(backing);
    defer iter_arena.deinit();
    const gpa = iter_arena.allocator();

    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    const d = try ooxml.detect(&pkg);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    switch (d.kind) {
        .docx => {
            var doc = try ooxml.WordDocument.open(&pkg);
            try doc.text(gpa, &out);
        },
        .xlsx => {
            var wb = try ooxml.Workbook.open(&pkg);
            for (0..wb.sheets.len) |i| {
                if (wb.sheets[i].part == null) continue;
                try wb.sheetToCsv(gpa, i, &out);
            }
        },
        .pptx => {
            var pres = try ooxml.Presentation.open(&pkg);
            for (0..pres.slides.len) |i| {
                try pres.slideText(gpa, i, &out);
            }
        },
        .unknown => return error.NotOfficeDocument,
    }

    var touched: u64 = 0;
    var it = pkg.part_cache.valueIterator();
    while (it.next()) |bytes| touched += bytes.len;
    std.mem.doNotOptimizeAway(out.items);
    return .{ touched, out.items.len };
}

/// Decompress every part; no XML work. Isolates the flate cost.
fn benchIterUnzip(backing: std.mem.Allocator, data: []const u8) !struct { u64, u64 } {
    var iter_arena = std.heap.ArenaAllocator.init(backing);
    defer iter_arena.deinit();
    const gpa = iter_arena.allocator();

    var ar = try zip.Archive.open(gpa, data);
    defer ar.deinit(gpa);
    var touched: u64 = 0;
    for (ar.entries) |*e| {
        const bytes = try ar.extractAlloc(gpa, e, .{});
        defer gpa.free(bytes);
        std.mem.doNotOptimizeAway(bytes);
        touched += bytes.len;
    }
    return .{ touched, 0 };
}

/// Decompress + pump every XML part through the pull parser (count events).
/// Isolates container+parser cost without the typed layer.
fn benchIterParse(backing: std.mem.Allocator, data: []const u8) !struct { u64, u64 } {
    var iter_arena = std.heap.ArenaAllocator.init(backing);
    defer iter_arena.deinit();
    const gpa = iter_arena.allocator();

    var ar = try zip.Archive.open(gpa, data);
    defer ar.deinit(gpa);
    var touched: u64 = 0;
    var events: u64 = 0;
    for (ar.entries) |*e| {
        const is_xml = std.mem.endsWith(u8, e.name, ".xml") or
            std.mem.endsWith(u8, e.name, ".rels");
        if (!is_xml) continue;
        const bytes = try ar.extractAlloc(gpa, e, .{});
        defer gpa.free(bytes);
        touched += bytes.len;
        var p = xml.Parser.init(bytes);
        while (true) {
            const ev = try p.next();
            if (ev == .eof) break;
            events += 1;
        }
    }
    std.mem.doNotOptimizeAway(events);
    return .{ touched, events };
}

fn cmdBench(
    io: std.Io,
    data: []const u8,
    path: []const u8,
    iters: usize,
    mode: []const u8,
    w: *std.Io.Writer,
) !void {
    const gpa = std.heap.page_allocator;

    const runIter = if (std.mem.eql(u8, mode, "unzip"))
        &benchIterUnzip
    else if (std.mem.eql(u8, mode, "parse"))
        &benchIterParse
    else
        &benchIterFull;

    // Warmup (and grab the workload stats once).
    const stats = try runIter(gpa, data);

    var min_ns: u64 = std.math.maxInt(u64);
    var total_ns: u64 = 0;
    for (0..iters) |_| {
        const t0 = nowNs(io);
        _ = try runIter(gpa, data);
        const dt: u64 = @intCast(nowNs(io) - t0);
        min_ns = @min(min_ns, dt);
        total_ns += dt;
    }

    const avg_ns = total_ns / @max(iters, 1);
    const mib = 1024.0 * 1024.0;
    const touched_f: f64 = @floatFromInt(stats[0]);
    const zip_f: f64 = @floatFromInt(data.len);

    try w.print("nanoxml bench: {s}\n", .{path});
    try w.print("  mode={s} iters={d}\n", .{ mode, iters });
    try w.print("  zip {d:.2} MiB -> xml touched {d:.2} MiB", .{ zip_f / mib, touched_f / mib });
    if (std.mem.eql(u8, mode, "parse")) {
        try w.print("  ({d} xml events)", .{stats[1]});
    } else if (stats[1] > 0) {
        try w.print("  (output {d} bytes)", .{stats[1]});
    }
    try w.writeAll("\n");
    try w.print("  min {d:.3} ms   avg {d:.3} ms\n", .{
        @as(f64, @floatFromInt(min_ns)) / 1e6,
        @as(f64, @floatFromInt(avg_ns)) / 1e6,
    });
    try w.print("  throughput {d:.1} MiB/s uncompressed   {d:.1} MiB/s of zip   {d:.1} docs/s\n", .{
        touched_f / mib / (@as(f64, @floatFromInt(min_ns)) / 1e9),
        zip_f / mib / (@as(f64, @floatFromInt(min_ns)) / 1e9),
        1e9 / @as(f64, @floatFromInt(min_ns)),
    });
}

// ── new: create demo documents with the builders ───────────────────────────

fn cmdNew(gpa: std.mem.Allocator, io: std.Io, kind: []const u8, out_path: []const u8) !void {
    const bytes: []u8 = blk: {
        if (std.mem.eql(u8, kind, "docx")) {
            var b = ooxml.DocumentBuilder.init(gpa);
            defer b.deinit();
            b.title = "nanoxml demo";
            b.creator = "nanoxml";
            try b.addParagraph("Hello from nanoxml.");
            try b.addParagraph("This document was created in Zig — no Office, no .NET.");
            try b.addParagraph("Entities work too: < & > \" '");
            break :blk try b.save(gpa);
        } else if (std.mem.eql(u8, kind, "xlsx")) {
            var b = ooxml.WorkbookBuilder.init(gpa);
            defer b.deinit();
            const s = try b.addSheet("Demo");
            try b.setCell(s, 0, 0, .{ .string = "item" });
            try b.setCell(s, 0, 1, .{ .string = "count" });
            try b.setCell(s, 0, 2, .{ .string = "active" });
            try b.setCell(s, 1, 0, .{ .string = "widgets, large" });
            try b.setCell(s, 1, 1, .{ .number = 42 });
            try b.setCell(s, 1, 2, .{ .boolean = true });
            try b.setCell(s, 2, 0, .{ .string = "gizmos" });
            try b.setCell(s, 2, 1, .{ .number = 0.125 });
            try b.setCell(s, 2, 2, .{ .boolean = false });
            break :blk try b.save(gpa);
        } else if (std.mem.eql(u8, kind, "pptx")) {
            var b = ooxml.PresentationBuilder.init(gpa);
            defer b.deinit();
            try b.addSlide(&.{ "nanoxml", "OOXML in Zig" });
            try b.addSlide(&.{ "Second slide", "with a bullet" });
            break :blk try b.save(gpa);
        } else {
            std.debug.print("unknown kind '{s}' (want docx|xlsx|pptx)\n", .{kind});
            return;
        }
    };
    defer gpa.free(bytes);

    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    var fw_buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &fw_buf);
    try file_writer.interface.writeAll(bytes);
    try file_writer.end();

    std.debug.print("wrote {s} ({d} bytes)\n", .{ out_path, bytes.len });
}

// ── validate: OpenXmlValidator-style diagnostics ────────────────────────────

fn cmdValidate(gpa: std.mem.Allocator, data: []const u8, json: bool, w: *std.Io.Writer) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    var result = try nanoxml.validate.validatePackage(gpa, &pkg);
    defer result.deinit();

    if (json) {
        try w.print("{{\"ok\":{},\"errors\":{d},\"diagnostics\":[", .{ result.ok(), result.errorCount() });
        for (result.diagnostics, 0..) |d, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"severity\":\"{s}\",\"part\":", .{@tagName(d.severity)});
            if (d.part) |p| try jsonEsc(w, p) else try w.writeAll("null");
            try w.writeAll(",\"message\":");
            try jsonEsc(w, d.message);
            try w.writeAll("}");
        }
        try w.writeAll("]}\n");
    } else {
        for (result.diagnostics) |d| {
            try w.print("[{s}] {s}: {s}\n", .{
                @tagName(d.severity),
                d.part orelse "(package)",
                d.message,
            });
        }
        try w.print("{d} error(s), {d} diagnostic(s)\n", .{
            result.errorCount(),
            result.diagnostics.len,
        });
    }
    // Diagnostics flush on unwind; the error makes the exit code nonzero.
    if (!result.ok()) return error.ValidationFailed;
}

// ── roundtrip: open → DOM-reserialize main part → save ─────────────────────

fn cmdRoundtrip(gpa: std.mem.Allocator, io: std.Io, data: []const u8, out_path: []const u8) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    const arena = pkg.arena.allocator();

    const main_part = (try pkg.partByRelType(null, opc.RelType.office_document)) orelse
        return error.PartNotFound;
    const root = try nanoxml.dom.parse(arena, try pkg.getPart(main_part));
    var ser: std.ArrayList(u8) = .empty;
    defer ser.deinit(gpa);
    try nanoxml.dom.serialize(root, gpa, &ser, .{});
    try pkg.setPart(main_part, ser.items);

    const out = try pkg.save(gpa);
    defer gpa.free(out);

    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    var fw_buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &fw_buf);
    try file_writer.interface.writeAll(out);
    try file_writer.end();

    std.debug.print("roundtripped -> {s} ({d} bytes; {s} re-serialized through dom)\n", .{ out_path, out.len, main_part });
}

// ── agent-facing write commands ─────────────────────────────────────────────

/// "-" reads stdin to EOF, anything else is a file path.
fn readContentArg(gpa: std.mem.Allocator, io: std.Io, spec: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, spec, "-"))
        return std.Io.Dir.cwd().readFileAlloc(io, spec, gpa, .limited(2 << 30));
    var buf: std.ArrayList(u8) = .empty;
    var tmp: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &tmp, tmp.len);
        if (n <= 0) break;
        try buf.appendSlice(gpa, tmp[0..@intCast(n)]);
    }
    return buf.toOwnedSlice(gpa);
}

fn writeFileBytes(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var fw_buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &fw_buf);
    try file_writer.interface.writeAll(bytes);
    try file_writer.end();
}

fn savePackageTo(gpa: std.mem.Allocator, io: std.Io, pkg: *opc.Package, out_path: []const u8) !usize {
    const out = try pkg.save(gpa);
    defer gpa.free(out);
    try writeFileBytes(io, out_path, out);
    return out.len;
}

const CellRef = struct { row: u32, col: u32 };

/// "B3" -> row 3 (1-based), col 1 (0-based).
fn parseCellRef(ref: []const u8) !CellRef {
    var col: u32 = 0;
    var i: usize = 0;
    while (i < ref.len) : (i += 1) {
        const up = std.ascii.toUpper(ref[i]);
        if (up < 'A' or up > 'Z') break;
        col = col * 26 + (up - 'A' + 1);
    }
    if (i == 0 or i >= ref.len or col == 0) return error.BadCellRef;
    const row = try std.fmt.parseInt(u32, ref[i..], 10);
    if (row == 0) return error.BadCellRef;
    return .{ .row = row, .col = col - 1 };
}

/// Strict decimal shape (optional sign, digits, optional .digits) so cell
/// values round-trip verbatim; anything else is stored as a string.
fn looksNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '-') i = 1;
    var digits: usize = 0;
    var dot = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '.') {
            if (dot) return false;
            dot = true;
        } else if (c < '0' or c > '9') {
            return false;
        } else digits += 1;
    }
    return digits > 0;
}

fn prefixedName(arena: std.mem.Allocator, pfx: []const u8, local: []const u8) ![]const u8 {
    if (pfx.len == 0) return arena.dupe(u8, local);
    return std.mem.concat(arena, u8, &.{ pfx, ":", local });
}

fn cmdSetCell(
    gpa: std.mem.Allocator,
    io: std.Io,
    data: []const u8,
    sheet_str: []const u8,
    ref: []const u8,
    value: []const u8,
    o: Opts,
    out_path: []const u8,
) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    const arena = pkg.arena.allocator();

    const wb = try ooxml.Workbook.open(&pkg);
    const idx = try std.fmt.parseInt(usize, sheet_str, 10);
    if (idx >= wb.sheets.len) return error.SheetNotFound;
    const part = wb.sheets[idx].part orelse return error.PartNotFound;

    const root = try dom.parse(arena, try pkg.getPart(part));
    const pfx = root.prefix();
    const sheet_data = root.child("sheetData") orelse
        try root.appendElement(arena, try prefixedName(arena, pfx, "sheetData"));
    const target = try parseCellRef(ref);

    // Row: exact match, else create at the sorted position.
    var row_el: ?*dom.Element = null;
    var row_before: ?*dom.Element = null;
    var rit = sheet_data.elements("row");
    while (rit.next()) |r_el| {
        const r_attr = r_el.attr("r") orelse continue;
        const rnum = std.fmt.parseInt(u32, r_attr, 10) catch continue;
        if (rnum == target.row) {
            row_el = r_el;
            break;
        }
        if (rnum > target.row) {
            row_before = r_el;
            break;
        }
    }
    const row = row_el orelse blk: {
        const nr = try dom.Element.create(arena, try prefixedName(arena, pfx, "row"));
        try nr.setAttr(arena, "r", try std.fmt.allocPrint(arena, "{d}", .{target.row}));
        if (row_before) |rb| try sheet_data.insertBefore(arena, nr, rb) else try sheet_data.appendChild(arena, nr);
        break :blk nr;
    };

    // Cell within the row, same strategy.
    var cell_el: ?*dom.Element = null;
    var cell_before: ?*dom.Element = null;
    var cit = row.elements("c");
    while (cit.next()) |c_el| {
        const cr = c_el.attr("r") orelse continue;
        const cref = parseCellRef(cr) catch continue;
        if (cref.col == target.col) {
            cell_el = c_el;
            break;
        }
        if (cref.col > target.col) {
            cell_before = c_el;
            break;
        }
    }
    const cell = cell_el orelse blk: {
        const nc = try dom.Element.create(arena, try prefixedName(arena, pfx, "c"));
        try nc.setAttr(arena, "r", ref);
        if (cell_before) |cb| try row.insertBefore(arena, nc, cb) else try row.appendChild(arena, nc);
        break :blk nc;
    };

    const numeric = !o.force_string and (o.force_number or looksNumeric(value));
    cell.removeAllChildren();
    if (numeric) {
        _ = cell.removeAttr("t");
        const v = try cell.appendElement(arena, try prefixedName(arena, pfx, "v"));
        try v.setText(arena, value);
    } else {
        try cell.setAttr(arena, "t", "inlineStr");
        const is = try cell.appendElement(arena, try prefixedName(arena, pfx, "is"));
        const t = try is.appendElement(arena, try prefixedName(arena, pfx, "t"));
        try t.setText(arena, value);
    }

    var ser: std.ArrayList(u8) = .empty;
    defer ser.deinit(gpa);
    try dom.serialize(root, gpa, &ser, .{});
    try pkg.setPart(part, ser.items);
    const n = try savePackageTo(gpa, io, &pkg, out_path);
    std.debug.print("set {s} = {s} ({s}) -> {s} ({d} bytes)\n", .{ ref, value, if (numeric) "number" else "string", out_path, n });
}

fn cmdSetProps(gpa: std.mem.Allocator, io: std.Io, data: []const u8, o: Opts, out_path: []const u8) !void {
    if (o.title == null and o.creator == null and o.subject == null and o.description == null) {
        std.debug.print("set-props: nothing to set (use --title/--creator/--subject/--description)\n", .{});
        return error.Usage;
    }
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    try pkg.setCoreProperties(.{
        .title = o.title,
        .creator = o.creator,
        .subject = o.subject,
        .description = o.description,
    });
    const n = try savePackageTo(gpa, io, &pkg, out_path);
    std.debug.print("properties updated -> {s} ({d} bytes)\n", .{ out_path, n });
}

fn cmdSetPart(gpa: std.mem.Allocator, io: std.Io, data: []const u8, part: []const u8, content: []const u8, out_path: []const u8) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    try pkg.setPart(part, content);
    const n = try savePackageTo(gpa, io, &pkg, out_path);
    std.debug.print("set part {s} ({d} bytes) -> {s} ({d} bytes)\n", .{ part, content.len, out_path, n });
}

fn cmdRmPart(gpa: std.mem.Allocator, io: std.Io, data: []const u8, part: []const u8, out_path: []const u8) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    try pkg.deletePart(part);
    const n = try savePackageTo(gpa, io, &pkg, out_path);
    std.debug.print("removed part {s} -> {s} ({d} bytes)\n", .{ part, out_path, n });
}

// ── agent-facing create commands ────────────────────────────────────────────

/// RFC 4180-ish CSV: quoted fields, "" escapes, embedded newlines, CRLF.
fn parseCsv(arena: std.mem.Allocator, src: []const u8) ![]const []const []const u8 {
    var rows: std.ArrayList([]const []const u8) = .empty;
    var fields: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_quotes = false;
    var field_started = false;

    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_quotes) {
            if (c == '"') {
                if (i + 1 < src.len and src[i + 1] == '"') {
                    try cur.append(arena, '"');
                    i += 1;
                } else {
                    in_quotes = false;
                }
            } else {
                try cur.append(arena, c);
            }
        } else if (c == '"' and cur.items.len == 0) {
            in_quotes = true;
            field_started = true;
        } else if (c == ',') {
            try fields.append(arena, try cur.toOwnedSlice(arena));
            field_started = false;
        } else if (c == '\n' or c == '\r') {
            if (c == '\r' and i + 1 < src.len and src[i + 1] == '\n') i += 1;
            try fields.append(arena, try cur.toOwnedSlice(arena));
            try rows.append(arena, try fields.toOwnedSlice(arena));
            fields = .empty;
            field_started = false;
        } else {
            try cur.append(arena, c);
        }
    }
    if (cur.items.len > 0 or fields.items.len > 0 or field_started) {
        try fields.append(arena, try cur.toOwnedSlice(arena));
        try rows.append(arena, try fields.toOwnedSlice(arena));
    }
    return rows.toOwnedSlice(arena);
}

fn cmdFromCsv(gpa: std.mem.Allocator, io: std.Io, in_spec: []const u8, out_path: []const u8, o: Opts) !void {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const src = try readContentArg(arena, io, in_spec);
    const rows = try parseCsv(arena, src);

    var b = ooxml.WorkbookBuilder.init(gpa);
    defer b.deinit();
    b.creator = "nanoxml";
    b.title = o.title;
    const sheet = try b.addSheet(o.sheet orelse "Sheet1");
    var cells: usize = 0;
    for (rows, 0..) |row, r| {
        for (row, 0..) |field, c| {
            if (field.len == 0) continue; // gap
            if (!o.force_string and (o.force_number or looksNumeric(field))) {
                try b.setCell(sheet, @intCast(r), @intCast(c), .{ .number = try std.fmt.parseFloat(f64, field) });
            } else {
                try b.setCell(sheet, @intCast(r), @intCast(c), .{ .string = field });
            }
            cells += 1;
        }
    }
    const bytes = try b.save(gpa);
    defer gpa.free(bytes);
    try writeFileBytes(io, out_path, bytes);
    std.debug.print("wrote {s} ({d} bytes, {d} rows, {d} cells)\n", .{ out_path, bytes.len, rows.len, cells });
}

fn cmdFromText(gpa: std.mem.Allocator, io: std.Io, in_spec: []const u8, out_path: []const u8, o: Opts) !void {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const src = try readContentArg(arena, io, in_spec);

    var b = ooxml.DocumentBuilder.init(gpa);
    defer b.deinit();
    b.title = o.title;
    b.creator = "nanoxml";

    var paras: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        // A text file's trailing newline is not an extra empty paragraph.
        if (line.len == 0 and it.peek() == null) break;
        try b.addParagraph(line);
        paras += 1;
    }
    const bytes = try b.save(gpa);
    defer gpa.free(bytes);
    try writeFileBytes(io, out_path, bytes);
    std.debug.print("wrote {s} ({d} bytes, {d} paragraphs)\n", .{ out_path, bytes.len, paras });
}
