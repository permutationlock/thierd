const std = @import("std");
const thierd = @import("thierd");
const log = std.log.scoped(.echo_client);

const Protocol = thierd.CodedProtocol;
const Client = thierd.Server(Protocol, Message, 1, 1);
const Handle = Client.Handle;
const Message = struct {
    len: u32,
    bytes: [64]u8,
    placholder: u8 = 0x77,

    fn asSlice(msg: *const Message) []const u8 {
        return msg.bytes[0..@min(msg.len, 64)];
    }
};

const EchoClient = struct {
    client: Client,
    handle: ?Handle,

    fn handleOpen(self: *EchoClient, handle: Handle, _: Client.Result) void {
        log.info("connection {} opened", .{ handle });
        self.handle = handle;
    }

    fn handleClose(self: *EchoClient, handle: Handle) void {
        log.info("connection {} closed", .{ handle });
        self.handle = null;
    }

    fn handleMessage(_: *EchoClient, handle: Handle, msg: Message) void {
        log.info("connection {} sent: {s}", .{ handle, msg.asSlice() });
    }

    fn connect(
        self: *EchoClient, ip: []const u8, port: u16, code: *const [16]u8
    ) !void {
        return self.client.connect(ip, port, code);
    }

    fn send(self: *EchoClient, msg: Message) !void {
        if (self.handle) |handle| {
            log.info("sending: {s}", .{ msg.asSlice() });
            try self.client.send(handle, msg);
        }
    }

    fn poll(self: *EchoClient, wait_ms: i32) !void {
        return self.client.poll(
            self, handleOpen, handleMessage, handleClose, 6, wait_ms, 1000
        );
    }
};

pub fn main() !void {
    const code = [_]u8{0xf, 0x0, 0x0, 0xd, 0xb, 0xe, 0xe, 0xf} ** 2;
    var client = EchoClient{ .client = Client.new(), .handle = null };
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
