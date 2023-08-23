const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const thierd = b.addModule("thierd", .{
        .source_file = .{ .path = "thierd.zig" },
    });

    const server = b.addExecutable(.{
        .name = "echo_server",
        .root_source_file = .{ .path = "examples/echo/server.zig" },
        .target = target,
        .optimize = optimize
    });
    server.addModule("thierd", thierd);
    b.installArtifact(server);

    const client = b.addExecutable(.{
        .name = "echo_client",
        .root_source_file = .{ .path = "examples/echo/client.zig" },
        .target = target,
        .optimize = optimize
    });
    client.addModule("thierd", thierd);
    b.installArtifact(client);
}
