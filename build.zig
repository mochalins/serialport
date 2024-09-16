const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.option(
        std.builtin.LinkMode,
        "lib",
        "Build an exportable C library.",
    );

    const mod = b.addModule("serialport", .{
        .root_source_file = b.path("src/serialport.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");

    const mod_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/serialport.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_unit_tests.root_module.link_libc = true;
    const run_mod_unit_tests = b.addRunArtifact(mod_unit_tests);
    test_step.dependOn(&run_mod_unit_tests.step);

    if (lib) |l| {
        // Library Artifact
        {
            const library = if (l == .static) b.addStaticLibrary(.{
                .name = "serialport",
                .root_source_file = b.path("src/lib.zig"),
                .target = target,
                .optimize = optimize,
            }) else b.addSharedLibrary(.{
                .name = "serialport",
                .root_source_file = b.path("src/lib.zig"),
                .target = target,
                .optimize = optimize,
            });
            library.root_module.addImport("serialport", mod);
            b.installArtifact(library);
        }
        // Library Tests
        {
            const lib_unit_tests = b.addTest(.{
                .root_source_file = b.path("src/lib.zig"),
                .target = target,
                .optimize = optimize,
            });
            lib_unit_tests.root_module.addImport("serialport", mod);
            const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
            test_step.dependOn(&run_lib_unit_tests.step);
        }
    }
}
