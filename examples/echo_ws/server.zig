const std = @import("std");
const thierd = @import("thierd");
const log = std.log.scoped(.echo_server);

const Protocol = thierd.Websockify(thierd.CodedProtocol);
//const Protocol = thierd.WebsocketProtocol;
const Result = EchoServer.Result;
const EchoServer = thierd.Server(Protocol, Message, 256, 32);
const Handle = EchoServer.Handle;
const Message = struct {
    bytes: [128]u8,

    fn asSlice(msg: *const Message) []const u8 {
        return &msg.bytes;
    }
};

fn handleOpen(_: *EchoServer, handle: Handle, _: Result) void {
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
    try server.listen(8081, 32, &code);
    errdefer { server.halt(); server.deinit(); }

    while (true) {
        try server.poll(
            &server, handleOpen, handleMessage, handleClose, 32, 1000, 10000000
        );
    }
}
