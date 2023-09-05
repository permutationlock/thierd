const std = @import("std");
const Builder = std.build.Builder;

const Example = struct {
    name: []const u8,
    path: []const u8,
};

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

    const examples = [_]Example{
        .{ .name = "echo_server", .path = "examples/echo/server.zig" },
        .{ .name = "echo_client", .path = "examples/echo/client.zig" },
        .{ .name = "echo_ae_server", .path = "examples/echo_ae/server.zig" },
        .{ .name = "echo_ae_client", .path = "examples/echo_ae/client.zig" },
    };

    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = .{ .path = example.path },
            .target = target,
            .optimize = optimize
        });
        exe.addModule("thierd", thierd);
        b.installArtifact(exe);
    }
}
