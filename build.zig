const std = @import("std");

const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Filter the tests to be executed");

    const hzzp = b.dependency("hzzp", .{});
    const module = b.addModule("wz", .{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &.{
            .{
                .name = "hzzp",
                .module = hzzp.module("hzzp"),
            },
        },
    });

    const test_compile_step = b.addTest(.{
        .root_source_file = module.source_file,
        .target = target,
        .optimize = optimize,
    });
    for (module.dependencies.keys(), module.dependencies.values()) |dep_name, dep_module| {
        test_compile_step.addModule(dep_name, dep_module);
    }
    test_compile_step.setFilter(test_filter);

    const test_run_step = b.addRunArtifact(test_compile_step);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&test_run_step.step);
}
