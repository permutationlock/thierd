const std = @import("std");

const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;

const Allocator = std.mem.Allocator;

const os = std.os;
const AF = os.AF;
const SOCK = os.SOCK;
const IPPROTO = os.IPPROTO;
const TCP = os.TCP;
const SO = os.SO;
const SOL = os.SOL;
const EPOLL = os.linux.EPOLL;

const net = std.net;
const log = std.log.scoped(.simple_game_server);

const fixedBufferStream = std.io.fixedBufferStream;
const asBytes = std.mem.asBytes;

const s2s = @import("include/s2s.zig");
const monocypher = @import("include/monocypher.zig");

const data_structures = @import("include/data_structures.zig");
const ArrayItemPool = data_structures.ArrayItemPool;

const RingBufferStream = @import("include/ring_buffer_stream.zig")
    .RingBufferStream;

pub const Secret = [64]u8;
pub const Key = [32]u8;

pub const Identity = struct {
    secret: Secret,
    public: Key,

    pub fn generate(seed: *[32]u8) Identity {
        var identity: Identity = undefined;
        monocypher.eddsa_key_pair(&identity.secret, &identity.public, seed);
        return identity;
    }
};

fn HandshakeBuffer(comptime max_size: comptime_int) type {
    return struct {
        const Self = @This();

        bytes: [max_size]u8 = undefined,
        pos: usize = 0,
        len: usize = 0,

        pub fn readSlice(self: *Self) []u8 {
            return self.bytes[self.pos..self.len];
        }

        pub fn increment(self: *Self, n: usize) void {
            self.pos += n;
        }

        pub fn resize(self: *Self, len: usize) void {
            self.pos = 0;
            self.len = len;
        }

        pub fn asSlice(self: *Self) []u8 {
            return self.bytes[0..self.pos];
        }
    };
}

fn ProtocolBuffer(
    comptime Message: type,
    comptime header_len: comptime_int,
    comptime body_len: comptime_int
) type {
    return extern struct {
        const Self = @This();
        const size = @max(@sizeOf(Message), header_len + body_len);
        const body_pos = size - body_len;
        const header_pos = body_pos - header_len;

        bytes: [size]u8 = undefined, 
        pos: usize = header_pos,

        pub fn readSlice(self: *Self) []u8 {
            return self.bytes[self.pos..];
        }

        pub fn increment(self: *Self, n: usize) void {
            self.pos += n;
        }

        pub fn asSlice(self: *Self) []u8 {
            return self.bytes[header_pos..];
        }

        pub fn headerSlice(self: *Self) []u8 {
            return self.asSlice()[0..header_len];
        }

        pub fn bodySlice(self: *Self) []u8 {
            return self.asSlice()[header_len..];
        }

        pub fn message(self: *Self) *Message {
            return @ptrCast(self);
        }

        pub fn full(self: *Self) bool {
            return self.pos == size;
        }

        pub fn clear(self: *Self) void {
            self.pos = header_pos;
        }
    };
}

pub fn CodedProtocol(comptime code: []const u8) type {
    return struct {
        const Self = @This();
        const max_handshake_len = code.len;

        pub const Args = void;
        pub const Error = error{BadCode};

        sent: bool,

        pub fn new(_: Args) Self {
            return .{ .sent = false };
        }

        pub fn headerLen() usize {
            return 0;
        }

        pub fn maxHandshakeLen() usize {
            return max_handshake_len;
        }

        pub fn init(_: Args) Self {
            return .{};
        }

        pub fn accept(_: *Self) usize {
            return max_handshake_len;
        }

        pub fn connect(self: *Self, out_bytes: []u8) HandshakeEvent {
            @memcpy(out_bytes[0..max_handshake_len], code);
            self.sent = true;
            return .{
                .out_len = max_handshake_len,
                .next_len = max_handshake_len,
            };
        }

        pub fn handshake(
            self: *Self,
            out_bytes: []u8,
            in_bytes: []const u8
        ) Error!?HandshakeEvent {
            if (in_bytes.len < max_handshake_len) {
                return null;
            }
            if (std.mem.eql(u8, in_bytes, code)) {
                var out_len: usize = 0;
                if (!self.sent) {
                    @memcpy(out_bytes[0..max_handshake_len], code);
                    self.sent = true;
                    out_len = max_handshake_len;
                }
                return .{ .out_len = out_len, .next_len = 0, };
            }
            return Error.BadCode;
        }

        pub fn encode(_: *Self, _: []u8, _: []u8) void {
            return;
        }

        pub fn decode(_: *Self, _: []const u8, _:[]u8) !void {
            return;
        }
    };
}

pub const AEProtocol = struct {
    const Self = @This();

    const DHData = extern union {
        message: extern struct {
            accept: [64]u8,
            connect: [64]u8,
        },
        keys: extern struct {
            anonce: [32]u8,
            akey: [32]u8,
            ckey: [32]u8,
            cnonce: [32]u8,
        },
    };

    pub const Args = *Identity;
    pub const Error = error{BadCode};
    pub const HandshakeData = extern struct {
        dh_skey: [32]u8,
        dh: DHData,
        dsa_foreign: [32]u8,
        dsa_identity: *Identity,
        state: State,
    };
    pub const Result = [32]u8,

    const MessageState = enum(u8) {
        none,
        keys,
        signature
    };

    const State = struct {
        sending: MsgState,
        awaiting: MsgState,
        accepting: bool,
    };

    fn msgSize(msg_state: MessageState) usize {
        inline switch (msg_state) {
            .none => return 0,
            .keys => return 64,
            .signature => return 96,
        }
        unreachable;
    }

    shared_key: [32]u8 = undefined,

    pub const header_len = 40;
    pub const max_handshake_len: comptime_int = @sizeOf(Message(.signature));

    pub fn accept(_: *Self, data: *HandshakeData, identity: Args) usize {
        os.getrandom(@as(*[64]u8, @ptrCast(&data.dh_skey))) catch unreachable;
        monocypher.x25519_public_key(&data.dh.keys.akey, &data.dh_skey);
        data.dsa_identity = identity;
        data.state = .{ .sending = keys, .awaiting = .keys, .accepting = true };
        return 64;
    }

    pub fn connect(
        self: *Self,
        data: *HanshakeData,
        args: Args,
        out_bytes: []u8
    ) HandshakeEvent {
        os.getrandom(@as(*[64]u8, @ptrCast(&data.dh_skey))) catch unreachable;
        @memcpy(&data.dh.keys.cnonce, &data.dh.keys.anonce);
        monocypher.x25519_public_key(&data.dh.keys.ckey, &data.dh_skey);
        @memcpy(out_bytes[0..64], &data.keys.message.connect);
        data.state = .{
            .sending = .signature, .awaiting = .keys, .accepting = false
        };
        return .{
            .out_len = 64,
            .next_len = 64,
        };
    }

    pub fn handshake(
        self: *Self,
        data: *HandshakeData,
        out_bytes: []u8,
        in_bytes: []const u8
    ) Error!?HandshakeEvent {
        switch (data.state.awaiting) {
            .none => {},
            .keys => {
                if (in_bytes.len != 64) { return Error.HandshakeFailed; }
                if (data.state.accepting) {
                    @memcpy(&data.dh.message.connect, in_bytes);
                } else {
                    @memcpy(&data.dh.message.accept, in_bytes);
                }
                data.state.awaiting = .signature;
            },
            .signature => {
                if (in_bytes.len != 96) { return Error.HandshakeFailed; }
                var msg = &data.dh.message.connect;
                var dh_foreign = &data.dh.keys.ckey;
                if (data.state.accepting) {
                    msg = &data.dh.message.accept;
                    dh_foreign = &data.dh.keys.akey;
                }
                const valid = monocypter.eddsa_check(
                    in_bytes[0..64],
                    in_bytes[64..96],
                    msg
                );
                if (!valid) { return Error.HandshakeFailed; }
                @memcpy(&data.dsa_foreign, in_bytes[64..96]);
                monocypher.x25519(
                    &data.dh.keys.cnonce,
                    &data.dh_skey,
                    &dh_foreign
                );
                monocypher.blake2b(
                    &self.shared_key,
                    @as(*[96]u8, @ptrCast(&data.dh.keys.akey))
                );
                data.state.awaiting = .none;
            },
        }
        switch (data.state.sending) {
            .none => return.{
                .out_len = 0,
                .next_len = msgSize(data.state.awaiting)
            },
            .keys => {
                @memcpy(out_bytes[0..64], &data.dh.message.accepting);
                data.state.sending = .signature;
                return .{
                    .out_len = msgSize(.keys),
                    .next_len = msgSize(data.state.awaiting)
                };
            },
            .signature => {
                var msg = &data.dh.message.accept;
                if (data.state.accepting) {
                    msg = &data.dh.message.connect;
                }
                monocypter.eddsa_sign(
                    out_bytes[0..64],
                    &data.identity.secret,
                    msg
                );
                data.state.sending = .none;
                return .{
                    .out_len = msgSize(.signature),
                    .next_len = msgSize(data.state.awaiting)
                };
            },
        }
    }

    pub fn result(self: *Self, data: *HandshakeData) ?Result {
        return data.dsa_foreign;
    }

    pub fn encode(_: *Self, _: []u8, _: []u8) void {
        return;
    }

    pub fn decode(_: *Self, _: []const u8, _:[]u8) !void {
        return;
    }
};

pub const HandshakeEvent = struct {
    out_len: usize,
    next_len: usize,
};

pub fn Connection(
    comptime Protocol: type,
    comptime Message: type
) type {
    return struct {
        const Self = @This();
        const header_len = Protocol.headerLen();
        const message_len = s2s.serializedSize(Message);
        const MessageBuffer = ProtocolBuffer(Message, header_len, message_len);
        const max_handshake_len = Protocol.maxHandshakeLen();
        const HandshakeData = Protocol.HandshakeData;

        pub const Error = error{Closed};
        pub const SendError = Error || error{NotReady};
        pub const RecvError = Error || error{Corrupted} || Protocol.Error;

        pub const EventType = enum {
            none,
            open,
            message,
            close,
            fail
        };
        pub const Event = union(EventType) {
            none: void,
            open: *Protocol,
            message: *Message,
            close: *Protocol,
            fail: void,
        };

        pub const State = enum {
            init,
            open,
            closed
        };

        fd: os.socket_t,
        buffer: union(State) {
            init: struct {
                buffer: HandshakeBuffer(max_handshake_len),
                data: HandshakeData,
            },
            open: MessageBuffer,
            closed: void
        },
        protocol: Protocol,

        pub fn accept(
            fd: os.socket_t,
            args: Protocol.Args
        ) Self {
            var self = Self{
                .fd = fd,
                .protocol = Protocol.new(args),
                .buffer = .{ .init = undefined, },
            };
            const next_len = self.protocol.accept(&self.buffer.init.data);
            if (next_len > 0) {
                self.buffer.init.resize(next_len);
            } else {
                self.buffer = .{ .open = .{} };
            }
            return self;
        }

        pub fn connect(
            fd: os.socket_t,
            args: Protocol.Args
        ) Error!Self {
            var self = Self{
                .fd = fd,
                .protocol = Protocol.new(args),
                .buffer = .{ .init = .{ .buffer = .{}, .data = undefined }, },
            };
            var out_bytes: [max_handshake_len]u8 = undefined;
            const event: HandshakeEvent = self.protocol.connect(
                &out_bytes, &self.buffer.data
            );
            if (event.out_len > 0) {
                try self.sendBytes(out_bytes[0..event.out_len]);
            }
            if (event.next_len > 0) {
                self.buffer.init.buffer.resize(event.next_len);
            } else {
                self.buffer = .{ .open = .{}, };
            }
            return self;
        }

        fn sendBytes(self: *Self, bytes: []u8) Error!void {
            const len = os.send(self.fd, bytes, 0)
                catch { self.close(); return Error.Closed; };
            if (len < bytes.len) {
                self.close();
                return Error.Closed;
            }
        }

        pub fn send(self: *Self, message: Message) SendError!void {
            switch (self.buffer) {
                .init => return SendError.NotReady,
                .open => {},
                .closed => return SendError.Closed,
            }

            var buffer = MessageBuffer{};
            {
                var stream = fixedBufferStream(buffer.bodySlice());
                s2s.serialize(stream.writer(), Message, message)
                    catch unreachable;
            }
            self.protocol.encode(buffer.headerSlice(), buffer.bodySlice());
            try self.sendBytes(buffer.asSlice());
        }

        fn readBytes(self: *Self, bytes: []u8) Error!usize {
            const len = os.recv(
                self.fd,
                bytes,
                0
            ) catch {
                self.close();
                return Error.Closed;
            };
            if (len == 0) {
                self.close();
                return Error.Closed;
            }
            return len;
        }

        pub fn recv(self: *Self) RecvError!Event {
            switch (self.buffer) {
                .init => |*p| {
                    const in_len = self.readBytes(p.buffer.readSlice())
                        catch return .{ .fail = {}, };
                    p.buffer.increment(in_len);
                    var out_bytes: [max_handshake_len]u8 = undefined;
                    const maybe_event = try self.protocol.handshake(
                        &out_bytes, p.buffer.asSlice(), &p.data
                    );
                    if (maybe_event) |event| {
                        if (event.out_len > 0) {
                            self.sendBytes(out_bytes[0..event.out_len]) catch {
                                return .{ .fail = {}, };
                            };
                        }
                        if (event.next_len > 0) {
                            p.buffer.resize(event.next_len);
                        } else {
                            self.buffer = .{ .open = .{}, };
                            return .{ .open = &self.protocol, };
                        }
                    }
                },
                .open => |*buffer| {
                    if (buffer.full()) { buffer.clear(); }
                    const len = self.readBytes(buffer.readSlice())
                        catch return .{ .close = &self.protocol, };
                    buffer.increment(len);
                    if (buffer.full()) {
                        try self.protocol.decode(
                            buffer.headerSlice(),
                            buffer.bodySlice()
                        );
                        var stream = fixedBufferStream(buffer.bodySlice());
                        buffer.message().* = s2s.deserialize(
                            stream.reader(), Message
                        ) catch return RecvError.Corrupted;
                        return .{
                            .message = buffer.message(),
                        };
                    }
                },
                .closed => return RecvError.Closed,
            }
            return .{ .none = {}, };
        }

        pub fn close(self: *Self) void {
            if (self.buffer != .closed) {
                self.buffer = .{ .closed = {} };
                os.close(self.fd);
            }
        }

        pub fn state(self: *Self) State {
            return self.buffer;
        }

        pub fn getProtocol(self: *Self) *Protocol {
            return &self.protocol;
        }
    };
}

pub fn Server(
    comptime Protocol: type,
    comptime Message: type,
    comptime max_conns: comptime_int
) type {
    return struct {
        const Self = @This();
        const Error = error{AlreadyListening, NotListening, InvalidHandle};
        const Conn = Connection(Protocol, Message);
        const ConnectionPool = ArrayItemPool(
            Connection(Protocol, Message),
            max_conns
        );

        pub const Args = Protocol.Args;
        pub const Handle = ConnectionPool.Index;

        epoll_fd: os.fd_t,
        listening: ?struct {
            socket: os.socket_t,
            args: Args,
        },
        connection_pool: ConnectionPool,

        pub fn new() Self {
            const efd = os.epoll_create1(0) catch unreachable;
            return .{
                .epoll_fd = efd,
                .listening = null,
                .connection_pool = ConnectionPool.new(),
            };
        }

        pub fn init(self: *Self) void {
            self.epoll_fd = os.epoll_create1(0) catch unreachable;
            self.listening = null;
            self.connection_pool.init();
        }

        pub fn deinit(self: *Self) void {
            self.halt();
            os.close(self.epoll_fd);
        }

        pub fn halt(self: *Self) void {
            if (self.listening) |listening| {
                var citer = self.connection_pool.iterator();
                while (citer.nextIndex()) |handle| {
                    self.close(handle);
                }
                os.close(listening.socket);
                self.listening = null;
            }
        }

        pub fn listen(self: *Self, port: u16, backlog: u32, args: Args) !void {
            if (self.listening != null) {
                return Error.AlreadyListening;
            }
            var addr = (net.Ip4Address.parse("0.0.0.0", port)
                catch unreachable).sa;
            const ls = try os.socket(AF.INET, SOCK.STREAM, 0);
            errdefer os.close(ls);
            {
                const option: i32 = 1;
                try os.setsockopt(
                    ls, SOL.SOCKET, SO.REUSEADDR, asBytes(&option)
                );
            }
            try os.bind(ls, @ptrCast(&addr), @sizeOf(os.sockaddr));
            try os.listen(ls, @truncate(backlog));

            self.registerEvent(ls, -1);

            self.listening = .{
                .socket = ls,
                .args = args,
            };
        }

        fn registerEvent(self: *Self, fd: os.fd_t, handle: i32) void {
            var event = os.linux.epoll_event{
                .data = .{ .fd = handle },
                .events = EPOLL.IN,
            };
            os.epoll_ctl(
                self.epoll_fd,
                EPOLL.CTL_ADD,
                fd,
                &event
            ) catch unreachable;
        }

        fn accept(self: *Self) !void {
            if (self.listening == null) {
                return Error.NotListening;
            }
            var dest: os.sockaddr = undefined;
            var socksize: os.socklen_t = 0;
            var csocket: os.fd_t = try os.accept(
                self.listening.?.socket,
                &dest,
                &socksize,
                0
            );
            errdefer os.closeSocket(csocket);

            var handle = try self.connection_pool.create(
                Conn.accept(csocket, self.listening.?.args)
            );
            self.registerEvent(csocket, @intCast(handle));
        }

        pub fn connect(self: *Self, ip: []const u8, port: u16, args: Args) !void {
            const addr = (try std.net.Ip4Address.parse(ip, port)).sa;
            var csocket = try os.socket(
                AF.INET,
                SOCK.STREAM,
                0
            );
            errdefer os.closeSocket(csocket);

            try os.connect(
                csocket,
                @ptrCast(&addr),
                @sizeOf(os.sockaddr.in)
            );

            const handle = try self.connection_pool.create(
                try Conn.connect(csocket, args)
            );
            self.registerEvent(csocket, @intCast(handle));
        }

        pub fn send(self: *Self, handle: Handle, message: Message) !void {
            if (self.connection_pool.get(handle)) |connection| {
                return connection.send(message);
            }
            return Error.InvalidHandle;
        }

        pub fn close(self: *Self, handle: Handle) void {
            if (self.connection_pool.get(handle)) |connection| {
                connection.close();
                self.connection_pool.destroy(handle);
            }
        }

        pub fn poll(
            self: *Self,
            ctx: anytype,
            comptime handleOpen: fn (@TypeOf(ctx), Handle, *Protocol) void,
            comptime handleMessage: fn (@TypeOf(ctx), Handle, *Message) void,
            comptime handleClose: fn (@TypeOf(ctx), Handle, *Protocol) void,
            comptime max_events: comptime_int,
            wait_ms: i32
        ) !void {
            var epoll_events: [max_events]os.linux.epoll_event = undefined;
            const n = os.epoll_wait(self.epoll_fd, &epoll_events, wait_ms);
            for (epoll_events[0..n]) |e| {
                const fd: i32 = e.data.fd;
                if (fd == -1) {
                    self.accept() catch |err| {
                        log.err("accept error: {}", .{err});
                    };
                    continue;
                }
                const handle: Handle = @truncate(
                    @as(u32, @intCast(fd))
                );
                const connection = self.connection_pool.get(handle).?;
                const maybe_event = connection.recv();
                if (maybe_event) |event| switch(event) {
                    .none => {
                        log.info("EVENT: none", .{});
                    },
                    .open => |protocol| {
                        log.info("EVENT: open", .{});
                        handleOpen(ctx, handle, protocol);
                    },
                    .message => |message| {
                        log.info("EVENT: message", .{});
                        handleMessage(ctx, handle, message);
                    },
                    .close => |protocol| {
                        log.info("EVENT: close", .{});
                        handleClose(ctx, handle, protocol);
                        self.connection_pool.destroy(handle);
                    },
                    .fail => {
                        log.info("EVENT: fail", .{});
                        self.connection_pool.destroy(handle);
                    },
                } else |err| {
                    log.err(
                        "connection {} recv error: {}",
                        .{handle, err}
                    );
                }
            }
        }
    };
}
