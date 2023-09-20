const std = @import("std");
const thierd = @import("thierd");
const log = std.log.scoped(.echo_server);

const Message = @import("message.zig").Message;

const Protocol = thierd.CodedProtocol;
const EchoServer = thierd.Server(Protocol, Message, Message, 256, 32);
const Handle = EchoServer.Handle;

fn handleOpen(_: *EchoServer, handle: Handle, _: EchoServer.Result) void {
    log.info("connection {} opened", .{ handle });
}

fn handleClose(_: *EchoServer, handle: Handle) void {
    log.info("connection {} closed", .{ handle });
}

fn handleMessage(server: *EchoServer, handle: Handle, msg: Message) void {
    log.info("connection {} sent: {s}", .{ handle, msg.asSlice() });
    server.send(handle, msg) catch |err| {
        log.err("connection {} error: {}", .{ handle, err });
    };
}

pub fn main() !void {
    const code = [_]u8{0xf, 0x0, 0x0, 0xd, 0xb, 0xe, 0xe, 0xf} ** 2;
    var server = EchoServer.new();
    try server.listen(8081, 32, null, &code);
    errdefer { server.halt(); server.deinit(); }

    while (true) {
        _ = server.poll(
            &server, handleOpen, handleMessage, handleClose, 32, 1000, 5000
        );
    }
}
