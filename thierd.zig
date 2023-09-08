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

const mem = std.mem;
const net = std.net;
const ascii = std.ascii;

const log = std.log.scoped(.simple_game_server);

const fixedBufferStream = std.io.fixedBufferStream;

const crypto = std.crypto;
const AEADAlg = crypto.aead.chacha_poly.XChaCha20Poly1305;
const encrypt = AEADAlg.encrypt;
const decrypt = AEADAlg.decrypt;

const time = std.time;

const s2s = @import("include/s2s.zig");
const monocypher = @import("include/monocypher.zig");

const data_structures = @import("include/data_structures.zig");
const RingArray = data_structures.RingArray;
const ArrayItemPool = data_structures.ArrayItemPool;

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
    comptime header_len: comptime_int,
    comptime message_len: comptime_int
) type {
    return extern struct {
        const Self = @This();

        bytes: [header_len + message_len]u8 = undefined, 
        pos: usize = 0,

        pub fn readSlice(self: *Self) []u8 {
            return self.bytes[self.pos..];
        }

        pub fn increment(self: *Self, n: usize) void {
            self.pos += n;
        }

        pub fn asSlice(self: *Self) []u8 {
            return &self.bytes;
        }

        pub fn header(self: *Self) *[header_len]u8 {
            return self.bytes[0..header_len];
        }

        pub fn body(self: *Self) *[message_len]u8 {
            return self.bytes[header_len..];
        }

        pub fn full(self: *Self) bool {
            return self.pos == self.bytes.len;
        }

        pub fn clear(self: *Self) void {
            self.pos = 0;
        }
    };
}

pub fn CodedProtocol(comptime msize: comptime_int) type {
    return struct {
        const Self = @This();
        const code_len = 16;

        pub const Args = *const [code_len]u8;
        pub const Error = error{WrongCode};
        pub const HandshakeData = struct {
            code: *const [code_len]u8,
            sent: bool
        };
        pub const Result = struct {};

        pub const message_len = msize;
        pub const header_in_len = 0;
        pub const header_out_len = 0;
        pub const handshake_len = code_len;

        pub fn accept(_: *Self, data: *HandshakeData, code: Args) usize {
            data.sent = false;
            data.code = code;
            return code_len;
        }

        pub fn connect(
            _: *Self,
            data: *HandshakeData,
            out_bytes: *[handshake_len]u8,
            code: Args
        ) HandshakeEvent {
            data.code = code;
            data.sent = true;
            @memcpy(out_bytes, data.code);
            return .{ .out_len = code_len, .next_len = code_len, };
        }

        pub fn handshake(
            _: *Self,
            data: *HandshakeData,
            out_bytes: *[handshake_len]u8,
            in_bytes: []const u8
        ) Error!?HandshakeEvent {
            if (!mem.eql(u8, data.code, in_bytes)) {
                return Error.WrongCode;
            }
            if (!data.sent) {
                @memcpy(out_bytes, data.code);
                return .{ .out_len = code_len, .next_len = 0 };
            }
            return .{ .out_len = 0, .next_len = 0 };
        }

        pub fn result(_: *Self, _: *HandshakeData) Result {
            return .{};
        }

        pub fn encode(
            _: *Self,
            _: *[header_out_len]u8,
            _: *[message_len]u8
        ) void {
            return;
        }

        pub fn decode(
            _: *Self,
            _: *const [header_in_len]u8,
            _: *[message_len]u8
        ) Error!void {
            return;
        }
    };
}


pub fn WebsocketProtocol(comptime msize: comptime_int) type {
    if (msize > 65535) {
        @compileError("message size is way too big, what are you doing?!");
    }
    return struct {
        const Self = @This();
        const server_response = "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: ";
        const buffer_len = @max(
            server_response.len + 32,
            message_len - @sizeOf(HandshakeData)
        );

        pub const message_len = msize;
        pub const header_in_len = if (message_len <= 125) 6 else 8;
        pub const header_out_len = if (message_len <= 125) 2 else 4;
        pub const handshake_len = buffer_len;

        pub const Result = void;
        pub const HandshakeData = struct {
            headers_found: u16,
            key: [24]u8,
        };
        pub const Args = void;
        pub const Error = error{
            InvalidHeader,
            InvalidUpgrade,
            InvalidConnection,
            InvalidLineBreak,
            InvalidVersion,
            InvalidRequest,
            InvalidKey,
            MissingLine,
            FrameLengthInvalid,
            FrameLengthTooLong,
            NotMasked,
            ReservedBitSet,
            OpcodeNotBinary,
            MultiFrameMessage
        };

        pub fn accept(_: *Self, data: *HandshakeData, _: Args) usize {
            data.headers_found = 0;
            return handshake_len;
        }

        pub fn connect(
            _: *Self, _: *HandshakeData, _: *[handshake_len]u8, _: Args
        ) HandshakeEvent {
            unreachable;
        }

        fn toLower(str: []u8) []u8 {
            for (str, 0..) |c, i| {
                str[i] = ascii.toLower(c);
            }
            return str;
        }

        pub fn handshake(
            _: *Self,
            data: *HandshakeData,
            out_bytes: *[handshake_len]u8,
            in_bytes: [] u8
        ) Error!?HandshakeEvent {
            var start: usize = 0;
            var done = false;
            while (mem.indexOfScalar(u8, in_bytes[start..], '\r')) |end| {
                var line = in_bytes[start..(start + end)];
                if (line.len == 0) {
                    done = true;
                    break;
                }
                if (data.headers_found == 0) {
                    if (!ascii.endsWithIgnoreCase(line, "http/1.1")) {
                        return Error.InvalidRequest;
                    }
                    data.headers_found |= 1;
                } else {
                    const separator = mem.indexOfScalar(u8, line, ':')
                        orelse return Error.InvalidHeader;
                    const name = mem.trim(
                        u8,
                        toLower(line[0..separator]),
                        &ascii.whitespace
                    );
                    const value = mem.trim(
                        u8,
                        line[(separator + 1)..],
                        &ascii.whitespace
                    );
                    if (mem.eql(u8, "upgrade", name)) {
                        if (!ascii.eqlIgnoreCase("websocket", value)) {
                            return Error.InvalidUpgrade;
                        }
                        data.headers_found |= 16;
                    } else if (mem.eql(u8, "sec-websocket-version", name)) {
                        if (!mem.eql(u8, "13", value)) {
                            return Error.InvalidVersion;
                        }
                        data.headers_found |= 2;
                    } else if (mem.eql(u8, "connection", name)) {
                        if (ascii.indexOfIgnoreCase(value, "upgrade") == null) {
                            return Error.InvalidConnection;
                        }
                        data.headers_found |= 4;
                    } else if (mem.eql(u8, "sec-websocket-key", name)) {
                        if (value.len != 24) {
                            return Error.InvalidKey;
                        }
                        @memcpy(&data.key, value);
                        data.headers_found |= 8;
                    }
                }
                start += end + 2;
                if (start > in_bytes.len) {
                    return Error.InvalidLineBreak;
                }
            }

            if (done) {
                if (data.headers_found != 31) {
                    return Error.MissingLine;
                }
                var stream = fixedBufferStream(out_bytes);
                var writer = stream.writer();
                writer.writeAll(server_response) catch unreachable;
                var key_str: [28]u8 = undefined;
                {
                    var hash: [20]u8 = undefined;
                    var hasher = std.crypto.hash.Sha1.init(.{});
                    hasher.update(&data.key);
                    hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
                    hasher.final(&hash);
                    _ = std.base64.standard.Encoder.encode(&key_str, &hash);
                }
                writer.writeAll(&key_str) catch unreachable;
                writer.writeAll("\r\n\r\n") catch unreachable;
                return .{
                    .out_len = stream.pos,
                    .next_len = 0,
                };
            }
            if (start == 0) {
                if (in_bytes.len == handshake_len) {
                    return .{
                        .out_len = 0,
                        .next_len = handshake_len,
                    };
                }
                return null;
            }
            return .{
                .out_len = 0,
                .next_len = handshake_len,
                .rem_len = out_bytes.len - start,
            };
        }

        pub fn encode(
            _: *Self,
            header: *[header_out_len]u8,
            _: *[message_len]u8
        ) void {
            header[0] = 128 | 2;
            if (message_len < 126) {
                header[1] = @intCast(message_len & 0xff);
            } else {
                header[1] = 126;
                header[2] = @intCast((message_len >> 8) & 0xff);
                header[3] = @intCast(message_len & 0xff);
            }
            return;
        }

        pub fn decode(
            _: *Self,
            header: *const [header_in_len]u8,
            in_bytes: *[message_len]u8
        ) Error!void {
            const fin = header[0] & 128 != 0;
            if (!fin) {
                return Error.MultiFrameMessage;
            }
            if (header[0] & 112 != 0) {
                return Error.ReservedBitSet;
            }
            const opcode = header[0] & 15;
            if (opcode != 2) {
                return Error.OpcodeNotBinary;
            }
            const masked = header[1] & 128 != 0;
            if (!masked) {
                return Error.NotMasked;
            }
            var payload_len: usize = @intCast(header[1] & 127);
            if (payload_len == 126) {
                if (message_len < 126) {
                    return Error.FrameLengthInvalid;
                }
                payload_len = @intCast(header[3]);
                payload_len += @as(usize, @intCast(header[2])) << 8;
            } if (payload_len == 127) {
                return Error.FrameLengthTooLong;
            }
            // maybe SIMD this?
            const mask = header[(header_in_len - 4)..];
            for (in_bytes, 0..) |_, i| {
                in_bytes[i] = in_bytes[i] ^ mask[i % 4];
            }
            return;
        }

        pub fn result(_: *Self, _: *HandshakeData) Result { return {}; }
    };
}

pub fn AEProtocol(comptime msize: comptime_int) type {
    return struct {
        const Self = @This();

        const X25519 = crypto.dh.X25519;
        const Ed25519 = crypto.sign.Ed25519;
        const Blake2b256 = crypto.hash.blake2.Blake2b256;
        const shared_length = 32;
        const nonce_length = 32;
        const signature_length = Ed25519.Signature.encoded_length;
        const public_length = Ed25519.PublicKey.encoded_length;

        pub const Args = *const Ed25519.KeyPair;
        pub const Error = error{HandshakeFailed, MessageCorrupted};
        pub const HandshakeData = extern struct {
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

        const Header = extern struct {
            nonce: [24]u8,
            mac: [16]u8,
        };
        const header_len = @sizeOf(Header);

        pub const message_len = msize;
        pub const header_in_len = header_len;
        pub const header_out_len = header_len;
        pub const handshake_len = @max(
            msgSize(.keys), msgSize(.signature)
        );

        shared_key: [shared_length]u8 = undefined,

        pub fn accept(self: *Self, data: *HandshakeData, args: Args) usize {
            crypto.random.bytes(&data.accept_nonce);
            var done = false;
            while (!done) {
                crypto.random.bytes(&self.shared_key);
                data.accept_dh = X25519.recoverPublicKey(self.shared_key)
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
            self: *Self,
            data: *HandshakeData,
            out_bytes: *[handshake_len]u8,
            args: Args
        ) HandshakeEvent {
            crypto.random.bytes(&data.connect_nonce);
            var done = false;
            while (!done) {
                crypto.random.bytes(&self.shared_key);
                data.connect_dh = X25519.recoverPublicKey(self.shared_key)
                    catch continue;
                done = true;
            }

            var out_message: *Msg(.keys) = @ptrCast(out_bytes);
            out_message.connecting.nonce = data.connect_nonce;
            out_message.connecting.key = data.connect_dh;

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
            out_bytes: *[handshake_len]u8,
            in_bytes: []const u8
        ) Error!?HandshakeEvent {
            if (in_bytes.len != msgSize(data.state.awaiting)) {
                return Error.HandshakeFailed;
            }
            switch (data.state.awaiting) {
                .none => unreachable,
                .keys => {
                    const in_message: *const Msg(.keys) = @ptrCast(in_bytes);
                    if (data.state.accepting) {
                        data.connect_nonce = in_message.connecting.nonce;
                        data.connect_dh = in_message.connecting.key;
                    } else {
                        data.accept_nonce = in_message.accepting.nonce;
                        data.accept_dh = in_message.accepting.key;
                    }
                    data.state.awaiting = .signature;
                },
                .signature => {
                    const in_message: *const Msg(.signature) = 
                        @ptrCast(in_bytes);

                    var key_msg: *Msg(.keys) = @ptrCast(&data.connect_dh);
                    var dh_foreign = &data.accept_dh;
                    if (data.state.accepting) {
                        key_msg = @ptrCast(&data.accept_nonce);
                        dh_foreign = &data.connect_dh;
                    }

                    Ed25519.Signature.fromBytes(
                        in_message.signature
                    ).verify(
                        mem.asBytes(key_msg),
                        Ed25519.PublicKey.fromBytes(in_message.key)
                            catch return Error.HandshakeFailed
                    ) catch return Error.HandshakeFailed;

                    data.foreign_eddsa = in_message.key;
                    self.shared_key = X25519.scalarmult(
                        self.shared_key, dh_foreign.*
                    ) catch return Error.HandshakeFailed;
                    Blake2b256.hash(
                        &self.shared_key,
                        &self.shared_key,
                        .{ 
                            .key = @as(*const [64]u8, @ptrCast(&data.accept_dh))
                        }
                    );

                    data.state.awaiting = .none;
                },
            }

            const sent = data.state.sending;
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
                    var msg: *Msg(.keys) = @ptrCast(&data.accept_nonce);
                    if (data.state.accepting) {
                        msg = @ptrCast(&data.connect_dh);
                    }
                    out_message.signature = (
                        data.local_eddsa.sign(mem.asBytes(msg), null)
                        catch return Error.HandshakeFailed
                    ).toBytes();
                    out_message.key = data.local_eddsa.public_key.toBytes();
                    data.state.sending = .none;
                },
            }

            return .{
                .out_len = msgSize(sent),
                .next_len = msgSize(data.state.awaiting),
            };
        }

        pub fn result(_: *Self, data: *HandshakeData) Result {
            return data.foreign_eddsa;
        }

        pub fn encode(
            self: *Self,
            header_bytes: *[header_len]u8,
            body_bytes: *[message_len]u8
        ) void {
            var header: *Header = @ptrCast(header_bytes); 
            crypto.random.bytes(&header.nonce);
            encrypt(
                body_bytes,
                &header.mac,
                body_bytes,
                &[_]u8{},
                header.nonce,
                self.shared_key
            );
            return;
        }

        pub fn decode(
            self: *Self,
            header_bytes: *const [header_len]u8,
            body_bytes: *[message_len]u8
        ) Error!void {
            const header: *const Header = @ptrCast(header_bytes); 
            decrypt(
                body_bytes,
                body_bytes,
                header.mac,
                &[_]u8{},
                header.nonce,
                self.shared_key
            ) catch return Error.MessageCorrupted;
            return;
        }
    };
}

pub const HandshakeEvent = struct {
    out_len: usize,
    next_len: usize,
    rem_len: usize = 0,
};

pub fn Connection(
    comptime Protocol: type,
) type {
    return struct {
        const Self = @This();
        const header_in_len = Protocol.header_in_len;
        const header_out_len = Protocol.header_out_len;
        const message_len = Protocol.message_len;
        const InMessageBuffer = ProtocolBuffer(header_in_len, message_len);
        const OutMessageBuffer = ProtocolBuffer(header_out_len, message_len);
        const handshake_len = Protocol.handshake_len;
        const HandshakeData = Protocol.HandshakeData;
        const Result = Protocol.Result;

        pub const Message = [message_len]u8;
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
                buffer: HandshakeBuffer(handshake_len),
                data: HandshakeData,
            },
            open: InMessageBuffer,
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
            var out_bytes: [handshake_len]u8 = undefined;
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

        pub fn send(self: *Self, message: *const Message) SendError!void {
            switch (self.buffer) {
                .init => return SendError.NotReady,
                .open => {},
                .closed => return SendError.Closed,
            }

            var buffer = OutMessageBuffer{};
            @memcpy(buffer.body(), message);
            self.protocol.encode(buffer.header(), buffer.body());
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
                    var out_bytes: [handshake_len]u8 = undefined;
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
                                    in_bytes[0..event.rem_len],
                                    in_bytes[(in_bytes.len - event.rem_len)..]
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
                            buffer.header(),
                            buffer.body()
                        );
                        return .{
                            .message = buffer.body(),
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
    };
}

pub fn Server(
    comptime P: fn (comptime_int) type,
    comptime Message: type,
    comptime max_conns: comptime_int,
    comptime max_active_handshakes: comptime_int
) type {
    return struct {
        const Self = @This();
        const Error = error{
            AlreadyListening,
            NotListening,
            InvalidHandle,
            HandshakeQueueFull
        };
        const message_len = s2s.serializedSize(Message);
        const Protocol = P(message_len);
        const Conn = Connection(Protocol);
        const ConnectionPool = ArrayItemPool(Conn, max_conns);
        const HandshakeTimer = struct {
            handle: Handle,
            instant: time.Instant,
        };

        pub const Args = Protocol.Args;
        pub const Result = Protocol.Result;
        pub const Handle = ConnectionPool.Index;

        epoll_fd: os.fd_t,
        listening: ?struct {
            socket: os.socket_t,
            args: Args,
        },
        handshakes: [max_active_handshakes]?HandshakeTimer,
        connection_pool: ConnectionPool,

        pub fn new() Self {
            const efd = os.epoll_create1(0) catch unreachable;
            return .{
                .epoll_fd = efd,
                .listening = null,
                .handshakes = [1]?HandshakeTimer{null} ** max_active_handshakes,
                .connection_pool = ConnectionPool.new(),
            };
        }

        pub fn init(self: *Self) void {
            self.epoll_fd = os.epoll_create1(0) catch unreachable;
            self.listening = null;
            self.handshakes = [1]?HandshakeTimer{null} ** max_active_handshakes;
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
                    ls, SOL.SOCKET, SO.REUSEADDR, mem.asBytes(&option)
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
            var hs_index: ?usize = null;
            for (self.handshakes, 0..) |maybe_hs, i| {
                if (maybe_hs == null) {
                    hs_index = i;
                    break;
                }
            }
            if (hs_index == null) {
                return Error.HandshakeQueueFull;
            }

            var handle = try self.connection_pool.create(
                Conn.accept(csocket, self.listening.?.args)
            );
            self.handshakes[hs_index.?] = .{
                .handle = handle,
                .instant = time.Instant.now() catch unreachable,
            };
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
                var bytes: [message_len]u8 = undefined;
                var stream = fixedBufferStream(&bytes);
                s2s.serialize(stream.writer(), Message, message)
                    catch unreachable;
                return connection.send(&bytes);
            }
            return Error.InvalidHandle;
        }

        pub fn close(self: *Self, handle: Handle) void {
            if (self.connection_pool.get(handle)) |connection| {
                connection.close();
                self.connection_pool.destroy(handle);
            }
        }

        fn closeHandshake(self: *Self, handle: Handle) void {
            for (self.handshakes, 0..) |maybe_hs, i| {
                if (maybe_hs) |hs| {
                    if (hs.handle == handle) {
                        self.handshakes[i] = null;
                        return;
                    }
                }
            }
        }

        pub fn poll(
            self: *Self,
            ctx: anytype,
            comptime handleOpen: fn (@TypeOf(ctx), Handle, Result) void,
            comptime handleMessage: fn (@TypeOf(ctx), Handle, Message) void,
            comptime handleClose: fn (@TypeOf(ctx), Handle) void,
            comptime max_events: comptime_int,
            wait_ms: i32,
            timeout_ms: u64
        ) !void {
            var epoll_events: [max_events]os.linux.epoll_event = undefined;
            const n = os.epoll_wait(
                self.epoll_fd,
                &epoll_events,
                wait_ms
            );
            for (epoll_events[0..n]) |e| {
                if (e.data.fd == -1) {
                    self.accept() catch |err| {
                        log.err("accept error: {}", .{err});
                    };
                    continue;
                }
                const handle: Handle = @truncate(
                    @as(u32, @intCast(e.data.fd))
                );
                const connection = self.connection_pool.get(handle).?;
                const maybe_event = connection.recv();
                if (maybe_event) |event| switch(event) {
                    .none => {
                        log.info("connnection {} event: none", .{handle});
                    },
                    .open => |result| {
                        log.info("connnection {} event: open", .{handle});
                        self.closeHandshake(handle);
                        handleOpen(ctx, handle, result);
                    },
                    .message => |bytes| {
                        var stream = fixedBufferStream(bytes);
                        const message = s2s.deserialize(
                            stream.reader(), Message
                        ) catch |err| {
                            log.err(
                                "connection {} deserialize failure: {}",
                                .{handle, err}
                            );
                            continue;
                        };
                        log.info("connnection {} event: message", .{handle});
                        handleMessage(ctx, handle, message);
                    },
                    .close => {
                        log.info("connnection {} event: close", .{handle});
                        handleClose(ctx, handle);
                        self.connection_pool.destroy(handle);
                    },
                    .fail => {
                        log.info("connnection {} event: fail", .{handle});
                        self.closeHandshake(handle);
                        self.connection_pool.destroy(handle);
                    },
                } else |err| {
                    log.err(
                        "connection {} recv error: {}",
                        .{handle, err}
                    );
                }
            }

            const now = time.Instant.now() catch unreachable;
            for (self.handshakes, 0..) |maybe_hs, i| {
                if (maybe_hs) |hs| {
                    if (now.since(hs.instant) >= timeout_ms * 1000000) {
                        log.info("connnection {} event: timeout", .{hs.handle});
                        self.close(hs.handle);
                        self.handshakes[i] = null;
                    }
                }
            }
        }
    };
}
