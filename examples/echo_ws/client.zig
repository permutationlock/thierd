const std = @import("std");
const builtin = @import("builtin");
const thierd = @import("thierd");
const log = std.log.scoped(.echo_ws_client);

const Message = @import("message.zig").Message;

const KeyPair = std.crypto.sign.Ed25519.KeyPair;
const Protocol = thierd.UniversalClientProtocol(thierd.AEProtocol);
const Args = Protocol.Args;
const Result = Protocol.Result;
const Client = thierd.Client(Protocol, Message, Message);

const EchoClient = struct {
    client: Client,
    ready: bool,

    fn handleOpen(self: *EchoClient, _: Result) void {
        log.info("opened", .{});
        self.ready = true;
    }

    fn handleClose(self: *EchoClient) void {
        log.info("closed", .{});
        self.ready = false;
    }

    fn handleMessage(_: *EchoClient, msg: Message) void {
        log.info("received: {s}", .{ msg.asSlice() });
    }

    fn connect(
        self: *EchoClient, ip: []const u8, port: u16, args: Args
    ) !void {
        return self.client.connect(ip, port, null, args);
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

    fn close(self: *EchoClient) void {
        self.client.close();
    }
};

var client = EchoClient{ .client = Client.new(), .ready = false };
var last: std.time.Instant = undefined;
var hello_msg: Message = .{
    .len = 0,
    .bytes = undefined,
};
var key_pair: KeyPair = undefined;

fn update() callconv(.C) void {
    client.poll(1000) catch |err| {
        log.err("poll error: {}", .{err});
        client.close();
        if (builtin.os.tag == .emscripten) {
            std.os.emscripten.emscripten_force_exit(127);
        } else {
            std.os.exit(127);
        }
    };
    var current = std.time.Instant.now() catch unreachable;
    const time_step: i64 = @intCast(current.since(last) / 1000000);
    if (time_step >= 1000) {
        last = current;
        client.send(hello_msg) catch |err| {
            log.err("send error: {}", .{err});
            client.close();
            if (builtin.os.tag == .emscripten) {
                std.os.emscripten.emscripten_force_exit(127);
            } else {
                std.os.exit(127);
            }
        };
    }
}

pub fn main() !void {
    log.info("connecting", .{});
    key_pair = try KeyPair.create(null);
    try client.connect("127.0.0.1", 8081, &key_pair);

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
