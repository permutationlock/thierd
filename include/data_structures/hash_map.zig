const std = @import("std");
const ArrayItemPool = @import("item_pool.zig").ArrayItemPool;
const ListItemPool = @import("item_pool.zig").ListItemPool;
const IndexType = @import("item_pool.zig").IndexType;

pub fn HashMap(
    comptime K: type,
    comptime V: type,
    comptime equals: fn (K, K) callconv(.Inline) bool,
    comptime hashFn: fn (K) u64,
    comptime max_keys: comptime_int,
    comptime num_buckets: comptime_int
) type {
    return GenericHashMap(
        ArrayItemPool, K, V, equals, hashFn, max_keys, num_buckets
    );
}

pub fn ListHashMap(
    comptime K: type,
    comptime V: type,
    comptime equals: fn (K, K) callconv(.Inline) bool,
    comptime hashFn: fn (K) u64,
    comptime max_keys: comptime_int,
    comptime num_buckets: comptime_int
) type {
    return GenericHashMap(
        ListItemPool, K, V, equals, hashFn, max_keys, num_buckets
    );
}

pub fn GenericHashMap(
    comptime IP: fn (type, comptime_int) type,
    comptime K: type,
    comptime V: type,
    comptime equals: fn (K, K) callconv(.Inline) bool,
    comptime hashFn: fn (K) u64,
    comptime max_keys: comptime_int,
    comptime num_buckets: comptime_int
) type {
    return struct {
        const Self = @This();

        pub const Key = K;
        pub const Value = V;
        pub const Index = IndexType(max_keys);
        const Node = struct {
            next: ?Index,
            fingerprint: u8,
            key: K,
            value: V,
        };
        pub const NodePool = IP(Node, max_keys);
        pub const Error = NodePool.Error;

        node_pool: NodePool,
        buckets: [num_buckets]?Index = [1]?Index{null} ** num_buckets,
        len: usize = 0,

        pub fn new() Self {
            return .{
                .node_pool = NodePool.new(),
            };
        }

        pub fn init(self: *Self) void {
            self.node_pool.init();
            var i: usize = 0;
            while (i < self.buckets.len) {
                self.buckets[i] = null;
                i += 1;
            }
            self.len = 0;
        }

        pub fn get(self: *Self, key: Key) ?Value {
            const key_hash = hashFn(key);
            const bucket_index = key_hash % num_buckets;
            const fingerprint: u8 = @truncate(key_hash >> (64 - 8));
            if (self.buckets[bucket_index] == null) {
                return null;
            }

            var node = self.node_pool.get(self.buckets[bucket_index].?).?;
            if (node.fingerprint == fingerprint) {
                if (equals(node.key, key)) {
                    return node.value;
                }
            }
            while (node.next) |nindex| {
                node = self.node_pool.get(nindex).?;
                if (node.fingerprint == fingerprint) {
                    if (equals(node.key, key)) {
                        return node.value;
                    }
                }
            }

            return null;
        }

        pub fn put(self: *Self, key: Key, value: Value) Error!void {
            const key_hash = hashFn(key);
            const bucket_index = key_hash % num_buckets;
            const fingerprint: u8 = @truncate(key_hash >> (64 - 8));
            if (self.buckets[bucket_index] == null) {
                const index = try self.node_pool.create(
                    Node{
                        .next = null,
                        .fingerprint = fingerprint,
                        .key = key,
                        .value = value
                    }
                );
                self.len += 1;
                self.buckets[bucket_index] = index;
                return;
            }

            var node = self.node_pool.get(self.buckets[bucket_index].?).?;
            if (node.fingerprint == fingerprint) {
                if (equals(node.key, key)) {
                    node.value = value;
                    return;
                }
            }
            while (node.next) |nindex| {
                node = self.node_pool.get(nindex).?;
                if (node.fingerprint == fingerprint) {
                    if (equals(node.key, key)) {
                        node.value = value;
                        return;
                    }
                }
            }

            const index = try self.node_pool.create(
                Node{
                    .next = null,
                    .fingerprint = fingerprint,
                    .key = key,
                    .value = value
                }
            );
            self.len += 1;
            node.next = index;
        }

        pub fn putAssumeCapacity(self: *Self, key: Key, value: Value) void {
            self.put(key, value) catch unreachable;
        }

        pub fn remove(self: *Self, key: Key) void {
            const key_hash = hashFn(key);
            const bucket_index = key_hash % num_buckets;
            const fingerprint: u8 = @truncate(key_hash >> (64 - 8));
            if (self.buckets[bucket_index] == null) {
                return;
            }

            var index = self.buckets[bucket_index].?;
            var node: *Node = self.node_pool.get(index).?;
            if (node.fingerprint == fingerprint) {
                if (equals(node.key, key)) {
                    self.buckets[bucket_index] = node.next;
                    self.node_pool.destroy(index);
                    self.len -= 1;
                    return;
                }
            }
            while (node.next != null) {
                const nindex = node.next.?;
                const next_node = self.node_pool.get(nindex).?;
                if (node.fingerprint == fingerprint) {
                    if (equals(node.key, key)) {
                        node.next = next_node.next;
                        self.node_pool.destroy(nindex);
                        self.len -= 1;
                        return;
                    }
                }
                node = next_node;
            }
        }
    };
}


pub fn TrieHashMap(
    comptime K: type,
    comptime V: type,
    comptime equals: fn (K, K) callconv(.Inline) bool,
    comptime hashFn: fn (K) u64,
    comptime max_keys: comptime_int,
    comptime log2_children: comptime_int
) type {
    return GenericTrieHashMap(
        ArrayItemPool, K, V, equals, hashFn, max_keys, log2_children
    );
}

pub fn ListTrieHashMap(
    comptime K: type,
    comptime V: type,
    comptime equals: fn (K, K) callconv(.Inline) bool,
    comptime hashFn: fn (K) u64,
    comptime max_keys: comptime_int,
    comptime log2_children: comptime_int
) type {
    return GenericTrieHashMap(
        ListItemPool, K, V, equals, hashFn, max_keys, log2_children
    );
}

pub fn GenericTrieHashMap(
    comptime IP: fn (type, comptime_int) type,
    comptime K: type,
    comptime V: type,
    comptime equals: fn (K, K) callconv(.Inline) bool,
    comptime hashFn: fn (K) u64,
    comptime max_keys: comptime_int,
    comptime log2_children: comptime_int
) type {
    return struct {
        const Self = @This();

        pub const Key = K;
        pub const Value = V;
        pub const Index = IndexType(max_keys);

        const nchildren = std.math.pow(usize, 2, log2_children);
        const Node = struct {
            children: [nchildren]?Index = [1]?Index{null} ** nchildren,
            key: K,
            value: V,
        };
        pub const NodePool = IP(Node, max_keys);
        pub const Error = NodePool.Error;

        node_pool: NodePool,
        base: ?Index = null,
        len: usize = 0,

        pub fn new() Self {
            return .{
                .node_pool = NodePool.new(),
            };
        }

        pub fn init(self: *Self) void {
            self.node_pool.init();
            self.base = null;
            self.len = 0;
        }

        pub fn get(self: *Self, key: Key) ?Value {
            var key_hash = hashFn(key);
            var maybe_index = self.base;
            while (maybe_index) |index| {
                var node = self.node_pool.get(index).?;
                if (equals(node.key, key)) {
                    return node.value;
                }
                maybe_index = node.children[key_hash >> (64 - log2_children)];
                key_hash = key_hash << log2_children;
            }
            return null;
        }

        pub fn put(self: *Self, key: Key, value: Value) Error!void {
            var key_hash = hashFn(key);

            var index = &self.base;
            while (index.*) |id| {
                var node = self.node_pool.get(id).?;
                if (equals(node.key, key)) {
                    node.value = value;
                    return;
                }
                index = &node.children[key_hash >> (64 - log2_children)];
                key_hash = key_hash << log2_children;
            }
            index.* = try self.node_pool.create(
                Node{
                    .key = key,
                    .value = value,
                }
            );
            self.len += 1;
        }

        pub fn putAssumeCapacity(self: *Self, key: Key, value: Value) void {
            self.put(key, value) catch unreachable;
        }

        pub fn remove(self: *Self, key: Key) void {
            var key_hash = hashFn(key);

            var index = &self.base;
            while (index.*) |id| {
                var node = self.node_pool.get(id).?;
                //if (node.fingerprint == fingerprint) {
                if (equals(node.key, key)) {
                    var leaf_index = index;
                    var is_leaf = false;
                    while (!is_leaf) {
                        var leaf_node = self.node_pool.get(leaf_index.*.?).?;
                        is_leaf = true;
                        for (&leaf_node.children) |*child_index| {
                            if (child_index.* != null) {
                                leaf_index = child_index;
                                is_leaf = false;
                                break;
                            }
                        }
                    }
                    if (leaf_index.* != index.*) {
                        var leaf_node = self.node_pool.get(leaf_index.*.?).?;
                        node.key = leaf_node.key;
                        node.value = leaf_node.value;
                    }
                    self.node_pool.destroy(leaf_index.*.?);
                    leaf_index.* = null;
                    self.len -= 1;
                    return;
                }
                index = &node.children[key_hash >> (64 - log2_children)];
                key_hash = key_hash << log2_children;
            }
        }
    };
}

pub fn OpenHashMap(
    comptime K: type,
    comptime V: type,
    comptime equalsFn: fn (K, K) callconv(.Inline) bool,
    comptime hashFn: fn (K) u64,
    comptime max_keys: comptime_int,
) type {
    return struct {
        const Self = @This();

        pub const num_buckets = (max_keys * 4) / 3;
        pub const Key = K;
        pub const Value = V;
        pub const Error = error{OutOfSpace};

        const Metadata = packed struct {
            const FingerPrint = u7;

            const free: FingerPrint = 0;
            const tombstone: FingerPrint = 1;

            fingerprint: FingerPrint = free,
            used: u1 = 0,

            const slot_free: u8 = @bitCast(Metadata{ .fingerprint = free });
            const slot_tombstone: u8 = @bitCast(Metadata{ .fingerprint = tombstone });

            pub fn isUsed(self: Metadata) bool {
                return self.used == 1;
            }

            pub fn isTombstone(self: Metadata) bool {
                const slot: u8 = @bitCast(self);
                return slot_tombstone == slot;
            }

            pub fn isFree(self: Metadata) bool {
                const slot: u8 = @bitCast(self);
                return slot_free == slot;
            }

            pub fn takeFingerprint(key_hash: u64) FingerPrint {
                return @truncate(key_hash >> (64 - 7));
            }

            pub fn fill(self: *Metadata, fp: FingerPrint) void {
                self.used = 1;
                self.fingerprint = fp;
            }

            pub fn remove(self: *Metadata) void {
                self.used = 0;
                self.fingerprint = tombstone;
            }
        };

        const Node = struct {
            data: Metadata,
            key: K,
            value: V,

            const empty = Node{
                .data = .{
                    .used = 0,
                    .fingerprint = 0,
                },
                .key = undefined,
                .value = undefined,
            };
        };

        buckets: [num_buckets]Node = [1]Node{Node.empty} ** num_buckets,
        len: usize = 0,

        pub fn new() Self {
            return .{};
        }

        pub fn init(self: *Self) void {
            var i: usize = 0;
            while (i < num_buckets) {
                self.buckets[i] = Node.empty;
                i += 1;
            }
            self.len = 0;
        }

        pub fn get(self: *Self, key: Key) ?Value {
            const key_hash = hashFn(key);
            const fingerprint: u7 = Metadata.takeFingerprint(key_hash);
            const index: usize = key_hash % num_buckets;
            var count: usize = 0;
            while (count < num_buckets) {
                const node = &self.buckets[(index + count) % num_buckets];
                if (node.data.isUsed()) {
                    if (node.data.fingerprint == fingerprint) {
                        if (equalsFn(node.key, key)) {
                            return node.value;
                        }
                    }
                } else if (node.data.isFree()) {
                    return null;
                }
                count += 1;
            }
            return null;
        }

        pub fn putAssumeCapacity(self: *Self, key: Key, value: Value) void {
            const key_hash = hashFn(key);
            const fingerprint: u7 = Metadata.takeFingerprint(key_hash);
            const index: usize = key_hash % num_buckets;
            var count: usize = 0;
            while (count < num_buckets) {
                const node = &self.buckets[(index + count) % num_buckets];
                if (node.data.isUsed()) {
                    if (node.data.fingerprint == fingerprint) {
                        if (equalsFn(node.key, key)) {
                            node.value = value;
                            return;
                        }
                    }
                } else {
                    self.len += 1;
                    node.* = .{
                        .data = .{
                            .fingerprint = fingerprint,
                            .used = 1,
                        },
                        .key = key,
                        .value = value,
                    };
                    return;
                }
                count += 1;
            }
        }

        pub fn put(self: *Self, key: Key, value: Value) Error!void {
            if (self.len >= max_keys) {
                return Error.OutOfSpace;
            }
            self.putAssumeCapacity(key, value);
        }

        pub fn remove(self: *Self, key: Key) void {
            const key_hash = hashFn(key);
            const fingerprint: u7 = Metadata.takeFingerprint(key_hash);
            const index: usize = key_hash % num_buckets;
            var count: usize = 0;
            while (count < num_buckets) {
                const node = &self.buckets[(index + count) % num_buckets];
                if (node.data.isUsed()) {
                    if (node.data.fingerprint == fingerprint) {
                        if (equalsFn(node.key, key)) {
                            node.data = .{
                                .fingerprint = Metadata.tombstone,
                                .used = 0,
                            };
                            self.len -= 1;
                            return;
                        }
                    }
                } else if (node.data.isFree()) {
                    return;
                }
                count += 1;
            }
        }
    };
}

const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;

fn hash32(key: u32) u64 {
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
}
fn equals32(k1: u32, k2: u32) callconv(.Inline) bool {
    return k1 == k2;
}

fn testHashMap(comptime Map: type) !void {
    var map = Map.new();

    try map.put(7, true);
    try map.put(13, false);
 
    try expectEqual(map.get(7).?, true);
    try expectEqual(map.get(13).?, false);
    try expectEqual(map.get(8), null);

    try map.put(11, false);
    try map.put(3, false);
    var should_err = map.put(1113, false);

    try expectError(Map.Error.OutOfSpace, should_err);

    map.remove(7);
    try expectEqual(map.get(7), null);
}

test "hash map add, get, and remove" {
    try testHashMap(HashMap(u32, bool, equals32, hash32, 4, 2));
    try testHashMap(ListHashMap(u32, bool, equals32, hash32, 4, 2));
    try testHashMap(OpenHashMap(u32, bool, equals32, hash32, 4));
    try testHashMap(TrieHashMap(u32, bool, equals32, hash32, 4, 1));
}

fn equalsKey(k1: [32]u8, k2: [32]u8) callconv(.Inline) bool {
    return std.mem.eql(u8, &k1, &k2);
}

fn hashKey(key: [32]u8) u64 {
    return std.hash.Wyhash.hash(0, &key);
}

const Data = struct {
    data: [256]u8,
};

fn printSize(comptime Map: type) !void {
    try std.io.getStdOut().writer().print("\n{}\n", .{Map});
//    try std.io.getStdOut().writer().print("\tindex: {}\n", .{@sizeOf(Map.Index)});
//    try std.io.getStdOut().writer().print("\tnode: {}\n", .{@sizeOf(Map.Node)});
//    try std.io.getStdOut().writer().print("\tnode pool: {}\n", .{@sizeOf(Map.NodePool)});
    try std.io.getStdOut().writer().print("\ttotal: {}\n", .{@sizeOf(Map)});
}

test "size check" { 
    try printSize(HashMap([32]u8, Data, equalsKey, hashKey, 65534, 4096));
    try printSize(ListHashMap([32]u8, Data, equalsKey, hashKey, 65534, 4096));
    try printSize(OpenHashMap([32]u8, Data, equalsKey, hashKey, 65534));
    try printSize(TrieHashMap([32]u8, Data, equalsKey, hashKey, 65534, 2));
}
