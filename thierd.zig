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

const crypto = std.crypto;

const s2s = @import("include/s2s.zig");
const monocypher = @import("include/monocypher.zig");

const data_structures = @import("include/data_structures.zig");
const ArrayItemPool = data_structures.ArrayItemPool;

const RingBufferStream = @import("include/ring_buffer_stream.zig")
    .RingBufferStream;

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
            self.len = len;
        }

        pub fn seek(self: *Self, pos: usize) void {
            self.pos = pos;
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
            return self.asSlice()[header_pos..body_pos];
        }

        pub fn bodySlice(self: *Self) []u8 {
            return self.asSlice()[body_pos..];
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

        pub const header_len = 0;
        pub const max_handshake_len = code.len;

        pub const Result = void;
        pub const HandshakeData = struct {
            sent: bool,
        };
        pub const Args = void;
        pub const Error = error{BadCode};

        pub fn accept(_: *Self, data: *HandshakeData, _: Args) usize {
            data.sent = false;
            return max_handshake_len;
        }

        pub fn connect(
            _: *Self, data: *HandshakeData, out_bytes: []u8, _: Args 
        ) HandshakeEvent {
            @memcpy(out_bytes[0..max_handshake_len], code);
            data.sent = true;
            return .{
                .out_len = max_handshake_len,
                .next_len = max_handshake_len,
            };
        }

        pub fn handshake(
            _: *Self,
            data: *HandshakeData,
            out_bytes: []u8,
            in_bytes: []const u8
        ) Error!?HandshakeEvent {
            if (in_bytes.len < max_handshake_len) {
                return null;
            }
            if (std.mem.eql(u8, in_bytes, code)) {
                var out_len: usize = 0;
                if (!data.sent) {
                    @memcpy(out_bytes[0..max_handshake_len], code);
                    data.sent = true;
                    out_len = max_handshake_len;
                }
                return .{
                    .out_len = out_len,
                    .next_len = 0,
                };
            }
            return Error.BadCode;
        }

        pub fn result(_: *Self, _: *HandshakeData) Result {
            return {};
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

    const X25519 = crypto.dh.X25519;
    const Ed25519 = crypto.sign.Ed25519;
    const Blake2b256 = crypto.hash.blake2.Blake2b256;
    const shared_length = 32;
    const nonce_length = 32;
    const signature_length = Ed25519.Signature.encoded_length;
    const public_length = Ed25519.PublicKey.encoded_length;

    pub const Args = *const Ed25519.KeyPair;
    pub const Error = error{HandshakeFailed};
    pub const HandshakeData = extern struct {
        dh_secret: [X25519.secret_length]u8,
        accept_nonce: [nonce_length]u8,
        accept_dh: [X25519.public_length]u8,
        connect_dh: [X25519.public_length]u8,
        connect_nonce: [nonce_length]u8,
        foreign_eddsa: [public_length]u8,
        local_eddsa: *const Ed25519.KeyPair,
        state: State,
    };
    pub const Result = [public_length]u8;

    const MessageState = enum(u8) {
        none,
        keys,
        signature
    };

    const State = extern struct {
        sending: MessageState,
        awaiting: MessageState,
        accepting: bool,
    };

    fn msgSize(msg_state: MessageState) usize {
        inline for (std.meta.fields(MessageState)) |fld| {
            if (@field(MessageState, fld.name) == msg_state) {
                return @sizeOf(Msg(@field(MessageState, fld.name)));
            }
        }
        unreachable;
    }
    fn Msg(comptime msg_state: MessageState) type {
        switch (msg_state) {
            .none => return struct {},
            .keys => return extern union {
                accepting: extern struct {
                    nonce: [nonce_length]u8 align(1),
                    key: [X25519.public_length]u8 align(1),
                },
                connecting: extern struct {
                    key: [X25519.public_length]u8 align(1),
                    nonce: [nonce_length]u8 align(1),
                },
            },
            .signature => return extern struct {
                signature: [signature_length]u8 align(1),
                key: [public_length]u8 align(1),
            },
        }
        unreachable;
    }

    pub const header_len = 40;
    pub const max_handshake_len: comptime_int = @max(
        msgSize(.keys), msgSize(.signature)
    );

    shared_key: [shared_length]u8 = undefined,

    pub fn accept(_: *Self, data: *HandshakeData, args: Args) usize {
        crypto.random.bytes(&data.accept_nonce);
        var done = false;
        while (!done) {
            crypto.random.bytes(&data.dh_secret);
            data.accept_dh = X25519.recoverPublicKey(data.dh_secret)
                catch continue;
            done = true;
        }
        data.local_eddsa = args;
        data.state = .{
            .sending = .keys, .awaiting = .keys, .accepting = true
        };
        return msgSize(.keys);
    }

    pub fn connect(
        _: *Self,
        data: *HandshakeData,
        out_bytes: []u8,
        args: Args
    ) HandshakeEvent {
        crypto.random.bytes(&data.connect_nonce);
        var done = false;
        while (!done) {
            crypto.random.bytes(&data.dh_secret);
            data.connect_dh = X25519.recoverPublicKey(data.dh_secret)
                catch continue;
            done = true;
        }

        out_bytes[0..X25519.public_length].* = data.connect_dh;
        out_bytes[X25519.public_length..][0..nonce_length].*
            = data.connect_nonce;

        data.local_eddsa = args;
        data.state = .{
            .sending = .signature, .awaiting = .keys, .accepting = false
        };
        return .{
            .out_len = msgSize(.keys),
            .next_len = msgSize(.keys),
        };
    }

    pub fn handshake(
        self: *Self,
        data: *HandshakeData,
        out_bytes: []u8,
        in_bytes: []const u8
    ) Error!?HandshakeEvent {
        var sending = data.state.sending;
        switch (data.state.awaiting) {
            .none => unreachable,
            .keys => {
                if (in_bytes.len != @sizeOf(Msg(.keys))) {
                    return Error.HandshakeFailed;
                }
                const in_message: *const Msg(.keys) = @ptrCast(in_bytes);
                if (data.state.accepting) {
                    data.accept_nonce = in_message.accepting.nonce;
                    data.accept_dh = in_message.accepting.key;
                } else {
                    data.connect_nonce = in_message.connecting.nonce;
                    data.connect_dh = in_message.connecting.key;
                }
                data.state.awaiting = .signature;
            },
            .signature => {
                if (in_bytes.len != @sizeOf(Msg(.keys))) {
                    return Error.HandshakeFailed;
                }
                const in_message: *const Msg(.signature) = @ptrCast(in_bytes);

                var key_msg: *Msg(.signature) = @ptrCast(&data.connect_nonce);
                var dh_foreign = &data.connect_dh;
                if (data.state.accepting) {
                    key_msg = @ptrCast(&data.accept_dh);
                    dh_foreign = &data.accept_dh;
                }

                Ed25519.Signature.fromBytes(
                    in_message.signature
                ).verify(
                    std.mem.asBytes(key_msg),
                    Ed25519.PublicKey.fromBytes(in_message.key)
                        catch return Error.HandshakeFailed
                ) catch return Error.HandshakeFailed;

                data.foreign_eddsa = in_message.key;
                self.shared_key = X25519.scalarmult(data.dh_secret, dh_foreign.*)
                    catch return Error.HandshakeFailed;
                Blake2b256.hash(
                    &self.shared_key,
                    &self.shared_key,
                    .{ .key = @as(*const [64]u8, @ptrCast(&data.accept_dh)) }
                );

                data.state.awaiting = .none;
            },
        }
        switch (data.state.sending) {
            .none => {},
            .keys => {
                var out_message: *Msg(.keys) = @ptrCast(out_bytes);
                out_message.accepting.nonce = data.accept_nonce;
                out_message.accepting.key = data.accept_dh;
                data.state.sending = .signature;
            },
            .signature => {
                var out_message: *Msg(.signature) = @ptrCast(out_bytes);
                var msg: *Msg(.keys) = @ptrCast(&data.connect_nonce);
                if (data.state.accepting) {
                    msg = @ptrCast(&data.accept_dh);
                }
                out_message.signature = (
                    data.local_eddsa.sign(std.mem.asBytes(msg), null)
                    catch return Error.HandshakeFailed
                ).toBytes();
                data.state.sending = .none;
            },
        }

        return .{
            .out_len = msgSize(sending),
            .next_len = msgSize(data.state.awaiting),
        };
    }

    pub fn result(_: *Self, data: *HandshakeData) Result {
        return data.foreign_eddsa;
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
    rem_len: usize = 0,
};

pub fn Connection(
    comptime Protocol: type,
    comptime Message: type
) type {
    return struct {
        const Self = @This();
        const header_len = Protocol.header_len;
        const message_len = s2s.serializedSize(Message);
        const MessageBuffer = ProtocolBuffer(Message, header_len, message_len);
        const max_handshake_len = Protocol.max_handshake_len;
        const HandshakeData = Protocol.HandshakeData;
        const Result = Protocol.Result;

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
            open: Result,
            message: *Message,
            close: void,
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
                .protocol = .{},
                .buffer = .{ .init = undefined, },
            };
            const next_len = self.protocol.accept(&self.buffer.init.data, args);
            if (next_len > 0) {
                self.buffer.init.buffer.resize(next_len);
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
                .protocol = .{},
                .buffer = .{ .init = .{ .buffer = .{}, .data = undefined }, },
            };
            var out_bytes: [max_handshake_len]u8 = undefined;
            const event: HandshakeEvent = self.protocol.connect(
                &self.buffer.init.data, &out_bytes, args
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
                    var in_bytes = p.buffer.asSlice();
                    const maybe_event = try self.protocol.handshake(
                        &p.data, &out_bytes, in_bytes
                    );
                    if (maybe_event) |event| {
                        if (event.out_len > 0) {
                            self.sendBytes(out_bytes[0..event.out_len]) catch {
                                return .{ .fail = {}, };
                            };
                        }
                        if (event.next_len > 0) {
                            if (event.rem_len > 0) {
                                std.mem.copyForwards(
                                    u8,
                                    in_bytes[(in_bytes.len - event.rem_len)..],
                                    in_bytes[0..event.rem_len]
                                );
                            }
                            p.buffer.resize(event.next_len);
                            p.buffer.seek(event.rem_len);
                        } else {
                            self.buffer = .{ .open = .{}, };
                            return .{
                                .open = self.protocol.result(&p.data),
                            };
                        }
                    }
                },
                .open => |*buffer| {
                    if (buffer.full()) { buffer.clear(); }
                    const len = self.readBytes(buffer.readSlice())
                        catch return .{ .close = {} };
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
        pub const Result = Protocol.Result;
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
            comptime handleOpen: fn (@TypeOf(ctx), Handle, Result) void,
            comptime handleMessage: fn (@TypeOf(ctx), Handle, *Message) void,
            comptime handleClose: fn (@TypeOf(ctx), Handle) void,
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
                    .open => |result| {
                        log.info("EVENT: open", .{});
                        handleOpen(ctx, handle, result);
                    },
                    .message => |message| {
                        log.info("EVENT: message", .{});
                        handleMessage(ctx, handle, message);
                    },
                    .close => {
                        log.info("EVENT: close", .{});
                        handleClose(ctx, handle);
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
