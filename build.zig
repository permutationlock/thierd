const std = @import("std");
const Builder = std.build.Builder;

const Example = struct {
    name: []const u8,
    path: []const u8,
};

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const thierd = b.addModule("thierd", .{
        .source_file = .{ .path = "thierd.zig" },
    });

    const examples = [_]Example{
        .{ .name = "echo_ws_server", .path = "examples/echo_ws/server.zig" },
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
