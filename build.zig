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
    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("advapi32", .{});
    }

    const test_step = b.step("test", "Run unit tests");
    const mod_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/serialport.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    if (target.result.os.tag == .windows) {
        mod_unit_tests.root_module.linkSystemLibrary("advapi32", .{});
    }
    const run_mod_unit_tests = b.addRunArtifact(mod_unit_tests);
    test_step.dependOn(&run_mod_unit_tests.step);

    if (lib) |l| {
        // Library Artifact
        {
            const library = b.addLibrary(.{
                .name = "serialport",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/lib.zig"),
                    .target = target,
                    .optimize = optimize,
                }),
                .linkage = l,
            });
            library.root_module.addImport("serialport", mod);
            b.installArtifact(library);
        }
        // Library Tests
        {
            const lib_unit_tests = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/lib.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            lib_unit_tests.root_module.addImport("serialport", mod);
            const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
            test_step.dependOn(&run_lib_unit_tests.step);
        }
    }
}
