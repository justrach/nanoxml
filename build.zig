const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Importable as @import("nanoxml")
    const mod = b.addModule("nanoxml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Strip in fast/small builds (codedb pattern: smaller __TEXT, fewer
    // resident pages).
    const strip_debug = optimize == .ReleaseFast or optimize == .ReleaseSmall;
    const exe = b.addExecutable(.{
        .name = "nanoxml",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip_debug,
        }),
    });
    exe.root_module.addImport("nanoxml", mod);

    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the nanoxml CLI");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const test_files = [_][]const u8{
        "src/zip.zig",
        "src/xml.zig",
        "src/dom.zig",
        "src/opc.zig",
        "src/ooxml.zig",
        "src/parity_test.zig",
    };
    for (test_files) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
