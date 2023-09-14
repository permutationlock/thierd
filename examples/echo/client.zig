const std = @import("std");
const thierd = @import("thierd");
const log = std.log.scoped(.echo_client);

const Message = @import("message.zig").Message;

const Protocol = thierd.CodedProtocol;
const Client = thierd.Client(Protocol, Message);

const EchoClient = struct {
    client: Client,
    ready: bool,

    fn handleOpen(self: *EchoClient, _: Client.Result) void {
        log.info("opened", .{});
        self.ready = true;
    }

    fn handleClose(self: *EchoClient) void {
        log.info("closed", .{});
        self.ready = false;
    }

    fn handleMessage(_: *EchoClient, msg: Message) void {
        log.info("sent: {s}", .{ msg.asSlice() });
    }

    fn connect(
        self: *EchoClient, ip: []const u8, port: u16, code: *const [16]u8
    ) !void {
        return self.client.connect(ip, port, code);
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
    const code = [_]u8{0xf, 0x0, 0x0, 0xd, 0xb, 0xe, 0xe, 0xf} ** 2;
    var client = EchoClient{ .client = Client.new(), .ready = false };
    try client.connect("127.0.0.1", 8081, &code);

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
