const std = @import("std");

const executables = .{
    .{
        .name = "server",
        .description = "Run the server",
        .path = "src/server.zig",
    },
    //.{
    //    .name = "client",
    //    .description = "Run the client",
    //    .path = "src/client.zig",
    //},
    .{
        .name = "dst",
        .description = "Run the deterministic simulation test",
        .path = "src/dst.zig",
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tests = b.addTest(.{
        .root_source_file = b.path("src/dst.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&tests.step);

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
