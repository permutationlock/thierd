const std = @import("std");
const thierd = @import("thierd.zig");
const ds = @import("include/data_structures.zig");
const IndexType = ds.IndexType;
const ArrayItemPool = ds.ArrayItemPool;
const HashMap = ds.ListHashMap;

pub const ServerMessageType = enum {
    login,
    join,
    game,
    leave,
    logout
};
pub fn ServerMessage(comptime Player: type, comptime Message: type) type {
    return union(ServerMessageType) {
        login: Player,
        join: Message,
        game: Message,
        leave: Player,
        logout: struct {},
    };
}
pub const ClientMessageType = enum {
    list,
    join,
    game,
    leave,
    logout
};
pub fn ClientMessage(comptime Message: type) type {
    return union(ServerMessageType) {
        join: struct {},
        game: Message,
        leave: struct {},
        logout: struct {},
    };
}


pub fn GameServer(
    comptime Protocol: type,
    comptime Player: type,
    comptime Game: type,
    comptime max_sessions: comptime_int,
    comptime max_rooms: comptime_int
) type {
    if (@sizeOf(Protocol.Result) == 0) {
        @compileError("game server requires an authenticated protocol");
    }
    return struct {
        const Self = @This();
        const OutMessage = ServerMessage(Game.ServerMessage);
        const InMessage = ClientMessage(Game.ClientMessage);

        const PlayerID = struct {
            room: RoomID,
            index: IndexType(Game.max_players),
        };
        const PlayerKey = Protocol.Result;

        const Session = struct {
            key: PlayerKey,
            handle: ?ConnectionHandle,
            id: ?PlayerID,
            player: Player,
        };
        const SessionID = IndexType(max_sessions);
        const SessionPool = ArrayItemPool(Session, max_sessions);
        const SessionMap = HashMap(PlayerKey, SessionID);

        const Room = struct {
            game: Game,
            sessions: [Game.max_players]?SessionID,
            player_count: usize,
        };
        const RoomPool = ArrayItemPool(Room, max_rooms);
        const RoomID = IndexType(max_rooms);

        const MessageServer = thierd.Server(
            Protocol,
            InMessage,
            OutMessage,
            max_sessions,
            32
        );
        const ConnectionHandle = MessageServer.ConnectionHandle;

        room_pool: RoomPool,
        session_map: SessionMap,
        session_pool: SessionPool,
        connections: [max_sessions]SessionID,
        message_server: MessageServer,
    };
}
