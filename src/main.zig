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
        \\nanoxml — fast Office Open XML reader (Zig port of Open-XML-SDK ideas)
        \\
        \\usage:
        \\  nanoxml parts  <file>             list package parts + content types
        \\  nanoxml info   <file>             kind, main part, sheets/slides
        \\  nanoxml text   <file>             extract text (docx/pptx)
        \\  nanoxml sheets <file>             list worksheets (xlsx)
        \\  nanoxml csv    <file> [sheet#]    worksheet as CSV (xlsx)
        \\  nanoxml dump   <file> <part>      raw bytes of one part
        \\  nanoxml validate <file>           OpenXmlValidator-style diagnostics
        \\  nanoxml roundtrip <file> <out>    re-serialize main part via DOM, save
        \\  nanoxml bench  <file> [iters] [full|parse|unzip]
        \\  nanoxml new    docx|xlsx|pptx <out-file>   create a document
        \\
    , .{});
}

fn mainImpl(argv: []const [*:0]const u8) !void {
    if (argv.len < 3) {
        usage();
        return;
    }
    const cmd = std.mem.span(argv[1]);
    const path = std.mem.span(argv[2]);

    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // `new` creates a file instead of reading one: dispatch before the read.
    if (std.mem.eql(u8, cmd, "new")) {
        if (argv.len < 4) {
            usage();
            return;
        }
        try cmdNew(arena, io, path, std.mem.span(argv[3]));
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
        try cmdParts(arena, data, w);
    } else if (std.mem.eql(u8, cmd, "info")) {
        try cmdInfo(arena, data, w);
    } else if (std.mem.eql(u8, cmd, "text")) {
        try cmdText(arena, data, w);
    } else if (std.mem.eql(u8, cmd, "sheets")) {
        try cmdSheets(arena, data, w);
    } else if (std.mem.eql(u8, cmd, "csv")) {
        const sheet_idx: usize = if (argv.len > 3)
            try std.fmt.parseInt(usize, std.mem.span(argv[3]), 10)
        else
            0;
        try cmdCsv(arena, data, sheet_idx, w);
    } else if (std.mem.eql(u8, cmd, "dump")) {
        if (argv.len < 4) {
            usage();
            return;
        }
        try cmdDump(arena, data, std.mem.span(argv[3]), w);
    } else if (std.mem.eql(u8, cmd, "validate")) {
        try cmdValidate(arena, data, w);
    } else if (std.mem.eql(u8, cmd, "roundtrip")) {
        if (argv.len < 4) {
            usage();
            return;
        }
        try cmdRoundtrip(arena, io, data, std.mem.span(argv[3]));
    } else if (std.mem.eql(u8, cmd, "bench")) {
        const iters: usize = if (argv.len > 3)
            try std.fmt.parseInt(usize, std.mem.span(argv[3]), 10)
        else
            10;
        const mode = if (argv.len > 4) std.mem.span(argv[4]) else "full";
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

fn cmdParts(gpa: std.mem.Allocator, data: []const u8, w: *std.Io.Writer) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();

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

fn cmdInfo(gpa: std.mem.Allocator, data: []const u8, w: *std.Io.Writer) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    const d = try ooxml.detect(&pkg);

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

fn cmdSheets(gpa: std.mem.Allocator, data: []const u8, w: *std.Io.Writer) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    const wb = try ooxml.Workbook.open(&pkg);
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

fn cmdValidate(gpa: std.mem.Allocator, data: []const u8, w: *std.Io.Writer) !void {
    var pkg = try opc.Package.open(gpa, data);
    defer pkg.deinit();
    var result = try nanoxml.validate.validatePackage(gpa, &pkg);
    defer result.deinit();

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
