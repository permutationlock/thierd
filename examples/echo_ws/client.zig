const std = @import("std");
const builtin = @import("builtin");
const thierd = @import("thierd");
const log = std.log.scoped(.echo_client);

const Protocol = thierd.CodedProtocol;
const Client = thierd.Client(Protocol, Message);
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
        self: *EchoClient, ip: []const u8, port: u16, args: *const [16]u8
    ) !void {
        return self.client.connect(ip, port, args);
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

const code = [_]u8{0xf, 0x0, 0x0, 0xd, 0xb, 0xe, 0xe, 0xf} ** 2;
var client = EchoClient{ .client = Client.new(), .ready = false };
var last: std.time.Instant = undefined;
var hello_msg: Message = .{
    .len = 0,
    .bytes = undefined,
};

fn update() callconv(.C) void {
    log.info("polling", .{});
    client.poll(1000) catch |err| {
        log.err("poll error: {}", .{err});
    };
    var current = std.time.Instant.now() catch unreachable;
    const time_step: i64 = @intCast(current.since(last) / 1000000);
    if (time_step >= 1000) {
        last = current;
        client.send(hello_msg) catch |err| {
            log.err("send error: {}", .{err});
        };
    }
}

pub fn main() !void {
    log.info("connecting", .{});
    try client.connect("127.0.0.1", 8081, &code);

    const str = "Hello from the client!";
    @memcpy(hello_msg.bytes[0..str.len], str);
    hello_msg.len = str.len;
    
    last = std.time.Instant.now() catch unreachable;

    if (builtin.os.tag == .emscripten) {
        std.os.emscripten.emscripten_set_main_loop(update, 0, 1);
        return;
    }
    while (true) {
        update();
    }
}
