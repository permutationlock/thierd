const std = @import("std");
const thierd = @import("thierd");
const log = std.log.scoped(.echo_server);

const Protocol = thierd.CodedProtocol(&[_]u8{0xf, 0x0, 0x0, 0xd});
const EchoServer = thierd.Server(Protocol, Message, 256);
const Handle = EchoServer.Handle;

const Message = struct {
    len: u32,
    bytes: [64]u8,
    placholder: u8 = 0x77,

    fn asSlice(msg: *const Message) []const u8 {
        return msg.bytes[0..@min(msg.len, 64)];
    }
};

fn handleOpen(_: *EchoServer, handle: Handle, _: *Protocol) void {
    log.info("connection {} opened", .{ handle });
}

fn handleClose(_: *EchoServer, handle: Handle, _: *Protocol) void {
    log.info("connection {} closed", .{ handle });
}

fn handleMessage(server: *EchoServer, handle: Handle, msg: *Message) void {
    log.info("connection {} sent: {s}", .{ handle, msg.asSlice() });
    server.send(handle, msg.*) catch |err| {
        log.err("connection {} error: {}", .{ handle, err });
    };
}

pub fn main() !void {
    var server = EchoServer.new();
    std.debug.print("size of connection: {}b\n", .{@sizeOf(thierd.Connection(Protocol, Message))});
    std.debug.print("size of server: {}b\n", .{@sizeOf(EchoServer)});
    try server.listen(8081, 32, {});
    errdefer { server.halt(); server.deinit(); }

    while (true) {
        try server.poll(
            &server, handleOpen, handleMessage, handleClose, 32, 1000
        );
    }
}