const std = @import("std");
const builtin = @import("builtin");

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
const POLL = os.POLL;
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
        pos: u16 = 0,
        len: u16 = 0,

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

pub fn Websockify(comptime Protocol: type) type {
    return struct {
        const Self = @This();

        pub const Args = Protocol.Args;
        pub const Result = Protocol.Result;
        pub const Error = WebsocketProtocol.Error || Protocol.Error;
        const ActiveHandshake = enum {
            websocket,
            protocol
        };

        pub const HandshakeData = union(ActiveHandshake) {
            websocket: struct {
                args: Args,
                data: WebsocketProtocol.HandshakeData,
            },
            protocol: Protocol.HandshakeData,
        };
        pub const min_handshake_space = @max(
            WebsocketProtocol.min_handshake_space,
            8 + Protocol.min_handshake_space
        );

        pub fn headerOutLen(msize: usize) usize {
            return WebsocketProtocol.headerOutLen(
                msize + Protocol.headerOutLen(msize)
            ) + Protocol.headerOutLen(msize);
        }
        pub fn headerInLen(msize: usize) usize {
            return WebsocketProtocol.headerInLen(
                msize + Protocol.headerInLen(msize)
            ) + Protocol.headerInLen(msize);
        }

        websocket: WebsocketProtocol = .{},
        protocol: Protocol = .{},

        pub fn accept(
            self: *Self,
            data: *HandshakeData,
            args: Args
        ) usize {
            data.* = .{
                .websocket = .{
                    .args = args,
                    .data = undefined,
                },
            };
            return self.websocket.accept(
                &data.websocket.data, .{}
            );
        }

        pub fn connect(
            self: *Self,
            data: *HandshakeData,
            out_bytes: []u8,
            args: Args
        ) HandshakeEvent {
            data.* = .{
                .websocket = .{
                    .args = args,
                    .data = undefined,
                },
            };
            return self.websocket.connect(
                &data.websocket.data, out_bytes, .{}
            );
        }

        pub fn handshake(
            self: *Self,
            union_data: *HandshakeData,
            out_bytes: []u8,
            in_bytes: []u8
        ) Error!?HandshakeEvent {
            switch (union_data.*) {
                .websocket => |*ws_data| {
                    var data = &ws_data.data;
                    const maybe_event = try self.websocket.handshake(
                        data, out_bytes, in_bytes
                    );
                    if (maybe_event) |event| {
                        if (event.next_len == 0) {
                            var args = ws_data.args;
                            const ws_header = WebsocketProtocol.header_out_len;
                            union_data.* = .{ .protocol = undefined, };
                            if (event.out_len == 0) {
                                var sevent = self.protocol.connect(
                                    &union_data.protocol,
                                    out_bytes[ws_header..],
                                    args
                                );
                                sevent.next_len += ws_header;
                                sevent.out_len += ws_header;
                                self.websocket.encode(
                                    out_bytes[0..sevent.out_len]
                                );
                                return sevent;
                            } else {
                                const len = self.protocol.accept(
                                    &union_data.protocol,
                                    args
                                );
                                return .{
                                    .out_len = event.out_len,
                                    .next_len = len + ws_header,
                                };
                            }
                        }
                    }
                    return maybe_event;
                },
                .protocol => |*data| {
                    try self.websocket.decode(in_bytes);
                    const hi_len = WebsocketProtocol.headerInLen(
                        in_bytes.len - 6
                    );
                    const ho_len = WebsocketProtocol.headerOutLen(
                        Protocol.handshakeLen(out_bytes.len - 4)
                    );
                    var out_sub = out_bytes[ho_len..];
                    var in_sub = in_bytes[hi_len..];
                    var maybe_event = try self.protocol.handshake(
                        data, out_sub, in_sub
                    );
                    if (maybe_event) |*event| {
                        if (event.out_len > 0) {
                            const real_ho_len = WebsocketProtocol.headerOutLen(
                                event.out_len
                            );
                            if (ho_len != real_ho_len) {
                                std.mem.copyForward(
                                    u8,
                                    out_bytes[real_ho_len..][0..event.out_len],
                                    out_sub
                                );
                            }
                            event.out_len += real_ho_len;
                            self.websocket.encode(
                                out_bytes[0..event.out_len]
                            );
                        }
                        if (event.next_len > 0) {
                            event.next_len += WebsocketProtocol.headerInLen(
                                event.next_len
                            );
                        } if (event.rem_len > 0) { unreachable; }
                    } else {
                        self.websocket.decode(in_bytes) catch unreachable;
                    }
                    return maybe_event;
                },
            }
            unreachable;
        }

        pub fn result(self: *Self, data: *HandshakeData) Result {
            return self.protocol.result(&data.protocol);
        }

        pub fn encode(self: *Self, bytes: []u8) void {
            const header_len = WebsocketProtocol.headerOutLen(bytes.len - 2);
            self.protocol.encode(bytes[header_len..]);
            self.websocket.encode(bytes);
        }

        pub fn decode(self: *Self, bytes: []u8) Error!void {
            const header_len = WebsocketProtocol.headerInLen(bytes.len - 6);
            try self.websocket.decode(bytes);
            try self.protocol.decode(bytes[header_len..]);
        }
    };
}

pub const CodedProtocol = struct {
    const Self = @This();
    const code_len = 16;

    pub const Args = *const [code_len]u8;
    pub const Error = error{WrongCode};
    pub const Result = struct {};
    pub const HandshakeData = struct {
        code: *const [code_len]u8,
        sent: bool
    };
    pub const min_handshake_space = code_len;

    pub fn headerInLen(comptime _: usize) usize { return 0; }
    pub fn headerOutLen(comptime _: usize) usize { return 0; }

    pub fn accept(_: *Self, data: *HandshakeData, code: Args) usize {
        data.sent = false;
        data.code = code;
        return code_len;
    }

    pub fn connect(
        _: *Self,
        data: *HandshakeData,
        out_bytes: []u8,
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
        out_bytes: []u8,
        in_bytes: []u8
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

    pub fn result(_: *Self, _: *HandshakeData) Result { return .{}; }
    pub fn encode(_: *Self, _: []u8) void {}
    pub fn decode(_: *Self, _: []u8) Error!void {}
};

pub const WebsocketProtocol = struct {
    const Self = @This();
    const server_response = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: ";
    pub const min_handshake_space = server_response.len + 32;

    pub fn header_in_len(msize: usize) usize {
        return if (msize <= 125) 6 else 8;
    }
    pub fn header_out_len(msize: usize) usize {
        return if (msize <= 125) 2 else 4;
    }

    pub const Result = struct {};
    pub const HandshakeData = struct {
        headers_found: u16,
        key: [24]u8,
    };
    pub const Args = struct {};
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
        return std.math.maxInt(usize);
    }

    pub fn connect(
        _: *Self, _: *HandshakeData, _: []u8, _: Args
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
        out_bytes: []u8,
        in_bytes: []u8
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
            if (in_bytes.len >= min_handshake_space) {
                return .{
                    .out_len = 0,
                    .next_len = std.math.maxInt(usize),
                };
            }
            return null;
        }
        return .{
            .out_len = 0,
            .next_len = std.math.maxInt(usize),
            .rem_len = out_bytes.len - start,
        };
    }

    pub fn encode(
        _: *Self,
        bytes: []u8,
        header_len: usize
    ) void {
        const message_len = bytes.len - header_len;
        var header = bytes[0..header_len];
        header[0] = 128 | 2;
        if (header_len == 2) {
            header[1] = @intCast(message_len & 0xff);
        } else if (header_len == 4) {
            header[1] = 126;
            header[2] = @intCast((message_len >> 8) & 0xff);
            header[3] = @intCast(message_len & 0xff);
        } else {
            unreachable;
        }
    }

    pub fn decode(
        _: *Self,
        bytes: []u8,
        header_len: usize
    ) Error!void {
        var header = bytes[0..header_len];
        var body = bytes[header_len..];
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
            if (header_len != 8) {
                return Error.FrameLengthInvalid;
            }
            payload_len = @intCast(header[3]);
            payload_len += @as(usize, @intCast(header[2])) << 8;
        } else if (payload_len == 127) {
            return Error.FrameLengthTooLong;
        } else if (header_len != 4) {
            unreachable;
        }
        // maybe SIMD this?
        const mask = header[(header_in_len - 4)..];
        for (body, 0..) |_, i| {
            body[i] = body[i] ^ mask[i % 4];
        }
        return;
    }

    pub fn result(_: *Self, _: *HandshakeData) Result { return .{}; }
};

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

    pub fn headerInLen(_: usize) usize {
        return header_len;
    }
    pub fn headerOutLen(_: usize) usize {
        return header_len;
    }

    pub const min_handshake_space = @max(
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
        out_bytes: []u8,
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
        out_bytes: []u8,
        in_bytes: []u8
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
        bytes: []u8
    ) void {
        var header: *Header = @ptrCast(bytes[0..header_len]); 
        var body = bytes[header_len..];
        crypto.random.bytes(&header.nonce);
        encrypt(
            body,
            &header.mac,
            body,
            &[_]u8{},
            header.nonce,
            self.shared_key
        );
        return;
    }

    pub fn decode(
        self: *Self,
        bytes: []u8
    ) Error!void {
        const header: *const Header = @ptrCast(bytes[0..header_len]); 
        var body = bytes[header_len..];
        decrypt(
            body,
            body,
            header.mac,
            &[_]u8{},
            header.nonce,
            self.shared_key
        ) catch return Error.MessageCorrupted;
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
    comptime message_len: comptime_int
) type {
    return struct {
        const Self = @This();
        const header_in_len = Protocol.headerInLen(message_len);
        const InMessageBuffer = ProtocolBuffer(header_in_len, message_len);
        const HandshakeData = Protocol.HandshakeData;
        const free_space = @sizeOf(InMessageBuffer)
            - @sizeOf(HandshakeData)
            - @sizeOf(HandshakeBuffer(0));
        const Result = Protocol.Result;

        pub const header_len = Protocol.header_out_len(message_len);
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
            message: *[message_len]u8,
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
                buffer: HandshakeBuffer(@max(
                    Protocol.min_handshake_len,
                    free_space - (free_space % @alignOf(HandshakeBuffer(0)))
                )),
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
            var out_bytes: [Protocol.min_handshake_size]u8 = undefined;
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

        pub fn send(
            self: *Self,
            buffer: *[header_len + message_len]u8
        ) SendError!void {
            switch (self.buffer) {
                .init => return SendError.NotReady,
                .open => {},
                .closed => return SendError.Closed,
            }

            self.protocol.encode(&buffer);
            try self.sendBytes(&buffer);
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
                    log.info("recv .init", .{});
                    const in_len = self.readBytes(p.buffer.readSlice())
                        catch return .{ .fail = {}, };
                    p.buffer.increment(in_len);
                    var out_bytes: [Protocol.min_handshake_size]u8 = undefined;
                    var in_bytes = p.buffer.asSlice();
                    const maybe_event = self.protocol.handshake(
                        &p.data, &out_bytes, in_bytes
                    ) catch {
                        self.close();
                        return .{ .fail = {} };
                    };
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
                    log.info("recv .open", .{});
                    if (buffer.full()) { buffer.clear(); }
                    const len = self.readBytes(buffer.readSlice())
                        catch return .{ .close = {} };
                    buffer.increment(len);
                    if (buffer.full()) {
                        try self.protocol.decode(buffer.asSlice());
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
    comptime Protocol: type,
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
        const Conn = Connection(Protocol, message_len);
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
                const header_len = Protocol.header_len;
                var bytes: [header_len + message_len]u8 = undefined;
                var stream = fixedBufferStream(bytes[header_len..]);
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

pub fn Client(
    comptime P: fn (comptime_int) type,
    comptime Message: type,
) type {
    return struct {
        const Self = @This();
        const Error = error{ NotConnected, AlreadyConnected };
        const message_len = s2s.serializedSize(Message);
        const Protocol = P(message_len);
        const Conn = Connection(Protocol);

        pub const Args = Protocol.Args;
        pub const Result = Protocol.Result;
        const State = enum {
            init,
            connecting,
            connected
        };

        poll_list: [1]os.pollfd,
        connection: union(State) {
            init: void,
            connecting: struct {
                socket: os.socket_t,
                args: Args,
            },
            connected: Conn,
        },

        pub fn new() Self {
            return .{
                .poll_list = undefined,
                .connection = .{ .init = {}, },
            };
        }

        pub fn init(self: *Self) void {
            self.connection = .{ .init = {}, };
        }

        pub fn deinit(self: *Self) void {
            self.close();
        }

        pub fn connect(
            self: *Self,
            ip: []const u8,
            port: u16,
            args: Args
        ) !void {
            if (self.connection != .init) {
                return Error.AlreadyConnected;
            }
            const addr = (try std.net.Ip4Address.parse(ip, port)).sa;
            var csocket = try os.socket(
                AF.INET,
                SOCK.STREAM,
                0
            );
            errdefer os.closeSocket(csocket);

            os.connect(
                csocket,
                @ptrCast(&addr),
                @sizeOf(os.sockaddr.in)
            ) catch |err| switch (err) {
                error.WouldBlock => if (builtin.os.tag != .emscripten) {
                    return err;
                },
                else => return err,
            };

            self.poll_list = [1]os.pollfd{
                .{ .fd = csocket, .events = POLL.IN, .revents = 0 }
            };
            if (builtin.os.tag != .emscripten) {
                self.connection = .{
                    .connected = try Conn.connect(csocket, args),
                };
            } else {
                self.connection = .{
                    .connecting = .{
                        .socket = csocket,
                        .args = args,
                    },
                };
            }
        }

        pub fn send(self: *Self, message: Message) !void {
            if (self.connection == .connected) {
                var connection = &self.connection.connected;
                const header_len = Protocol.header_len;
                var bytes: [header_len + message_len]u8 = undefined;
                var stream = fixedBufferStream(bytes[header_len..]);
                s2s.serialize(stream.writer(), Message, message)
                    catch unreachable;
                return connection.send(&bytes);
            }
            return Error.NotConnected;
        }

        pub fn close(self: *Self) void {
            if (self.connection == .connected) {
                var connection = &self.connection.connected;
                connection.close();
                self.connection = .{ .init };
            }
        }

        pub fn poll(
            self: *Self,
            ctx: anytype,
            comptime handleOpen: fn (@TypeOf(ctx), Result) void,
            comptime handleMessage: fn (@TypeOf(ctx), Message) void,
            comptime handleClose: fn (@TypeOf(ctx)) void,
            wait_ms: i32
        ) !void {
            if (self.connection == .init) {
                return Error.NotConnected;
            } else if (builtin.os.tag == .emscripten) {
                if (self.connection == .connecting) {
                    const socket = self.connection.connecting.socket;
                    const args = self.connection.connecting.args;
                    self.poll_list[0].events = POLL.OUT;
                    var n = try std.os.poll(&self.poll_list, wait_ms);
                    if (n > 0) {
                        os.getsockoptError(socket) catch {
                            os.closeSocket(socket);
                            self.connection = .{ .init = {} };
                            return error.ConnectionFailed;
                        };
                        self.connection = .{
                            .connected = try Conn.connect(socket, args),
                        };
                        self.poll_list[0].events = POLL.IN;
                    }
                    return;
                }
            }
            const n = try os.poll(&self.poll_list, wait_ms);
            if (n == 0) {
                return;
            }
            var connection = &self.connection.connected;
            const maybe_event = connection.recv();
            if (maybe_event) |event| switch(event) {
                .none => {
                    log.info("event: none", .{});
                },
                .open => |result| {
                    log.info("event: open", .{});
                    handleOpen(ctx, result);
                },
                .message => |bytes| {
                    var stream = fixedBufferStream(bytes);
                    const message = s2s.deserialize(
                        stream.reader(), Message
                    ) catch |err| {
                        log.err("deserialize failure: {}", .{err});
                        return;
                    };
                    log.info("event: message", .{});
                    handleMessage(ctx, message);
                },
                .close => {
                    log.info("event: close", .{});
                    handleClose(ctx);
                    self.connection = .{ .init = {} };
                },
                .fail => {
                    log.info("event: fail", .{});
                    self.connection = .{ .init = {} };
                },
            } else |err| {
                log.err("recv error: {}", .{err});
            }
        }
    };
}
