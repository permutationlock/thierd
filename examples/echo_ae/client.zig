const std = @import("std");
const thierd = @import("thierd");
const log = std.log.scoped(.echo_client);

const Message = @import("message.zig").Message;

const Protocol = thierd.AEProtocol;
const Client = thierd.Client(Protocol, Message, Message);
const Result = Client.Result;
const KeyPair = std.crypto.sign.Ed25519.KeyPair;

const EchoClient = struct {
    client: Client,
    ready: bool,

    fn handleOpen(self: *EchoClient, _: Result) void {
        log.info("connection opened", .{});
        self.ready = true;
    }

    fn handleClose(self: *EchoClient) void {
        log.info("connection closed", .{});
        self.ready = false;
    }

    fn handleMessage(_: *EchoClient, msg: Message) void {
        log.info("received: {s}", .{ msg.asSlice() });
    }

    fn connect(
        self: *EchoClient, ip: []const u8, port: u16, key_pair: *const KeyPair
    ) !void {
        return self.client.connect(ip, port, null, key_pair);
    }

    fn send(self: *EchoClient, msg: Message) !void {
        if (!self.ready) {
            return;
        }
        log.info("sending: {s}", .{ msg.asSlice() });
        try self.client.send(msg);
    }

    fn poll(self: *EchoClient, wait_ms: i32) !void {
        return self.client.poll(
            self, handleOpen, handleMessage, handleClose, wait_ms
        );
    }
};

pub fn main() !void {
    var client = EchoClient{ .client = Client.new(), .ready = false };
    const key_pair = try KeyPair.create(null);
    try client.connect("127.0.0.1", 8081, &key_pair);

    const str = "Hello from the client!";
    var msg: Message = .{
        .len = 0,
        .bytes = undefined,
    };
    @memcpy(msg.bytes[0..str.len], "Hello from the client!");
    msg.len = str.len;
    var last = std.time.Instant.now() catch unreachable;
    while (true) {
        try client.poll(@truncate(1000));

        var current = std.time.Instant.now() catch unreachable;
        const time_step: i64 = @intCast(current.since(last) / 1000000);
        if (time_step >= 1000) {
            try client.send(msg);
            last = current;
        }
    }
}
