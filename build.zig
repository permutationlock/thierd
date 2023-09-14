const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;

const Example = struct {
    name: []const u8,
    path: []const u8,
};

const emccOutputDir = "zig-out"
    ++ std.fs.path.sep_str
    ++ "htmlout"
    ++ std.fs.path.sep_str;
const emccOutputFile = "index.html";

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const thierd = b.addModule("thierd", .{
        .source_file = .{ .path = "thierd.zig" },
    });

    const examples = [_]Example{
        .{ .name = "echo_server", .path = "examples/echo/server.zig" },
        .{ .name = "echo_client", .path = "examples/echo/client.zig" },
        .{ .name = "echo_ae_server", .path = "examples/echo_ae/server.zig" },
        .{ .name = "echo_ae_client", .path = "examples/echo_ae/client.zig" },
        .{ .name = "echo_ws_server", .path = "examples/echo_ws/server.zig" },
        .{ .name = "echo_ws_client", .path = "examples/echo_ws/client.zig" },
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

    const ws_examples = [_]Example{
        .{ .name = "echo_ws_client", .path = "examples/echo_ws/client.zig" },
    };

    for (ws_examples) |example| {
        if (b.sysroot == null) {
            @panic("pass '--sysroot \"[path to emsdk]/upstream/emscripten\"'");
        }

        const obj = b.addObject(.{
            .name = example.name,
            .root_source_file = .{ .path = example.path },
            .target = .{ .cpu_arch = .wasm32, .os_tag = .emscripten, },
            .optimize = optimize,
            .link_libc = true
        });
        obj.addModule("thierd", thierd);

        const emccExe = switch (builtin.os.tag) {
            .windows => "emcc.bat",
            else => "emcc",
        };
        var emcc_run_arg = try b.allocator.alloc(
            u8,
            b.sysroot.?.len + emccExe.len + 1
        );
        defer b.allocator.free(emcc_run_arg);

        emcc_run_arg = try std.fmt.bufPrint(
            emcc_run_arg,
            "{s}" ++ std.fs.path.sep_str ++ "{s}",
            .{ b.sysroot.?, emccExe }
        );

        const mkdir_command = b.addSystemCommand(
            &[_][]const u8{ "mkdir", "-p", emccOutputDir }
        );
        const emcc_command = b.addSystemCommand(&[_][]const u8{emcc_run_arg});
        emcc_command.addFileArg(obj.getEmittedBin());
        emcc_command.step.dependOn(&obj.step);
        emcc_command.step.dependOn(&mkdir_command.step);
        emcc_command.addArgs(&[_][]const u8{
            "-o", emccOutputDir ++ emccOutputFile, "-Oz", "-sASYNCIFY"
        });
        if (optimize == .Debug or optimize == .ReleaseSafe) {
            emcc_command.addArgs(&[_][]const u8{
                "-sUSE_OFFSET_CONVERTER"
            });
        }
        b.getInstallStep().dependOn(&emcc_command.step);
    }
}
