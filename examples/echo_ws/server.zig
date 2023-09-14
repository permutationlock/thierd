const std = @import("std");
const thierd = @import("thierd");
const log = std.log.scoped(.echo_server);

const Message = @import("message.zig").Message;

const KeyPair = std.crypto.sign.Ed25519.KeyPair;
const Args = Protocol.Args;
const Protocol = thierd.UniversalServerProtocol(thierd.AEProtocol);
//const Protocol = thierd.WebsocketProtocol;
const Result = EchoServer.Result;
const EchoServer = thierd.Server(Protocol, Message, 768, 32);
const Handle = EchoServer.Handle;
var key_pair: KeyPair = undefined;

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
    key_pair = try KeyPair.create(null);
    var server = EchoServer.new();
    try server.listen(8081, 32, &key_pair);
    errdefer { server.halt(); server.deinit(); }

    while (true) {
        try server.poll(
            &server, handleOpen, handleMessage, handleClose, 32, 1000, 10000000
        );
    }
}
