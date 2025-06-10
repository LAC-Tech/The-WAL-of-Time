const std = @import("std");

const executables = .{
    .{
        .name = "server",
        .description = "Run the server",
        .path = "src/server.zig",
    },
    .{
        .name = "dst",
        .description = "Run the deterministic simulation test",
        .path = "src/dst.zig",
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all tests");

    const tests = b.addTest(.{
        .root_source_file = b.path("src/dst.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    inline for (executables) |e| {
        const exe = b.addExecutable(.{
            .name = e.name,
            .root_source_file = b.path(e.path),
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run-" ++ e.name, e.description);
        run_step.dependOn(&run_cmd.step);
    }
}
