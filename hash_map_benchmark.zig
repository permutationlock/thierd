const std = @import("std");
const heap = std.heap;

const timeFn = @import("include/timing.zig").timeFn;

const data_structures = @import("include/data_structures.zig");
const ListHashMap = data_structures.ListHashMap;
const OpenHashMap = data_structures.OpenHashMap;
const TrieHashMap = data_structures.TrieHashMap;

const Key = [8]u8;
const Data = [32]u8;

fn equals(k1: Key, k2: Key) callconv(.Inline) bool {
    return std.mem.eql(u8, &k1, &k2);
}

fn hash(key: Key) u64 {
    return std.hash.Wyhash.hash(0, &key);
}

const num_inserts = 1024*1024;
const ListMap = ListHashMap(
    Key, Data, equals, hash, num_inserts, 4 * num_inserts
);
const OpenMap = OpenHashMap(Key, Data, equals, hash, num_inserts);
const TrieMap = TrieHashMap(Key, Data, equals, hash, num_inserts, 2);
const StdMap = std.hash_map.AutoHashMap(Key, Data);

const Times = struct {
    lookup: f64,
    insert_delete: f64,
};

fn testMap(comptime M: type, map: *M, keys: []Key, rkeys: []Key) !Times {
    const data = [4]u8{1, 2, 3, 4} ** (@sizeOf(Data) / 4);
    const Funcs = struct {
        fn lookup(m: *M, ks: []Key) ?Data {
            const Static = struct {
                var i: usize = 0;
            };
            Static.i = (Static.i + 113) % ks.len;
            return m.get(ks[Static.i]);
        }

        fn insertDelete(m: *M, ks: []Key, d: Data, rks: []Key) void {
            for (ks) |k| {
                m.putAssumeCapacity(k, d);
            }
            for (rks) |rk| {
                _ = m.remove(rk);
            }
        }
    };

    const insert_delete =  try timeFn(
        std.os.CLOCK.PROCESS_CPUTIME_ID,
        @TypeOf(Funcs.insertDelete),
        Funcs.insertDelete,
        .{ map, keys, data, rkeys }
    ) / @as(f64, @floatFromInt(keys.len));

    for (keys) |key| {
        map.putAssumeCapacity(key, data);
    }

    const lookup = try timeFn(
        std.os.CLOCK.PROCESS_CPUTIME_ID,
        @TypeOf(Funcs.lookup),
        Funcs.lookup,
        .{ map, keys }
    );

    for (keys) |key| {
        _ = map.remove(key);
    }

    return .{ .lookup = lookup, .insert_delete = insert_delete };
}

pub fn main() !void {
    const stdout = std.io.getStdOut();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const nkeys = num_inserts;
    var keys = try allocator.create([nkeys]Key);
    for (keys) |*k| {
        try std.os.getrandom(std.mem.asBytes(k));
    }
    var rkeys = try allocator.create([nkeys]Key);
    var i: usize = 0;
    while (i < keys.len){
        rkeys[i] = keys[i];
        i += 1;
    }
    var is = std.rand.Isaac64.init(0);
    is.random().shuffle(Key, rkeys);

    var list_map = try allocator.create(ListMap);
    list_map.init();
    const list_times = try testMap(ListMap, list_map, keys, rkeys);
    try stdout.writer().print(
        "list map:\n\tlookup: {}ns\n\tinsert_delete: {}ns\n",
        .{ list_times.lookup, list_times.insert_delete }
    );

    var open_map = try allocator.create(OpenMap);
    open_map.init();
    const open_times = try testMap(OpenMap, open_map, keys, rkeys);
    try stdout.writer().print(
        "open map:\n\tlookup: {}ns\n\tinsert_delete: {}ns\n",
        .{ open_times.lookup, open_times.insert_delete }
    );

    var trie_map = try allocator.create(TrieMap);
    trie_map.init();
    const trie_times = try testMap(TrieMap, trie_map, keys, rkeys);
    try stdout.writer().print(
        "trie map:\n\tlookup: {}ns\n\tinsert_delete: {}ns\n",
        .{ trie_times.lookup, trie_times.insert_delete }
    );

    var std_map = StdMap.init(allocator);
    try std_map.ensureTotalCapacity(num_inserts);
    const std_times = try testMap(StdMap, &std_map, keys, rkeys);
    try stdout.writer().print(
        "std map:\n\tlookup: {}ns\n\tinsert_delete: {}ns\n",
        .{ std_times.lookup, std_times.insert_delete }
    );
}
