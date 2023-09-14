const std = @import("std");
const thierd = @import("thierd");
const log = std.log.scoped(.echo_server);

const Message = @import("message.zig").Message;

const Protocol = thierd.AEProtocol;
const EchoServer = thierd.Server(Protocol, Message, 768, 32);
const Result = EchoServer.Result;
const Handle = EchoServer.Handle;
const KeyPair = std.crypto.sign.Ed25519.KeyPair;

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
    var server = EchoServer.new();
    const key_pair = try KeyPair.create(null);
    try server.listen(8081, 32, &key_pair);
    errdefer { server.halt(); server.deinit(); }

    while (true) {
        try server.poll(
            &server, handleOpen, handleMessage, handleClose, 32, 1000, 1000
        );
    }
}
