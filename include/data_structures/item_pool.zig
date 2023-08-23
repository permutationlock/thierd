const std = @import("std");
const log2 = std.math.log2;

const ring_array = @import("ring_array.zig");
const RingArray = ring_array.RingArray;

pub fn IndexType(comptime size: comptime_int) type {
    var bits = log2(size);

    return switch (bits) {
        0...7 => u8,
        8...15 => u16,
        16...23 => u24,
        24...31 => u32,
        32...47 => u48,
        else => usize,
    };
}

pub fn ArrayItemPool(comptime T: type, comptime size: comptime_int) type {
    return struct {
        const Self = @This();

        pub const Error = error{ OutOfSpace };
        pub const Index = IndexType(size);
        pub const Item = T;

        const FreeList = RingArray(Index, size);

        const Iterator = struct {
            item_pool: *Self,
            index: Index = 0,

            pub const Pair = struct {
                index: Index,
                item: *Item,
            };

            pub fn nextItem(it: *Iterator) ?*Item {
                return (it.next() orelse return null).item;
            }

            pub fn nextIndex(it: *Iterator) ?Index {
                return (it.next() orelse return null).index;
            }

            pub fn next(it: *Iterator) ?Pair { 
                var maybe_item: ?Item = null;
                while (it.index < size and maybe_item == null) {
                    maybe_item = it.item_pool.items[it.index];
                    it.index += 1;
                }
                return .{
                    .index = it.index - 1,
                    .item = &(maybe_item orelse return null),
                };
            }
        };

        items: [size]?Item = [1]?Item{ null } ** size,
        free_list: FreeList = FreeList{},

        pub fn new() Self {
            var self = Self{};
            self.init();

            return self;
        }

        pub fn init(self: *Self) void {
            self.free_list.init();

            var i: Index = 0;
            for (&self.items) |*item| {
                item.* = null;
                self.free_list.push_back_raw(i);
                i += 1;
            }
        }

        pub fn create(self: *Self, item: Item) Error!Index {
            const index = self.free_list.pop_front() orelse return Error.OutOfSpace;
            self.items[index] = item;
            return index;
        }

        pub fn destroy(self: *Self, index: Index) void {
            if (self.items[index] == null) {
                return;
            }

            self.items[index] = null;
            self.free_list.push_front_raw(index);
        }

        pub fn get(self: *Self, index: Index) ?*Item {
            return &(self.items[index] orelse return null);
        }

        pub fn iterator(self: *Self) Iterator {
            return .{
                .item_pool = self,
            };
        }
    };
}

pub fn ListItemPool(comptime T: type, comptime size: comptime_int) type {
    return struct {
        const Self = @This();

        pub const Index = IndexType(size);
        pub const Error = NodePool.Error;
        pub const Item = T;

        pub const Node = struct {
            data: Item,
            prev: ?Index = null,
            next: ?Index = null,
        };
        const NodePool = ArrayItemPool(Node, size);

        const Iterator = struct {
            sub_it: NodePool.Iterator,

            pub const Pair = struct {
                index: Index,
                item: *Item,
            };

            pub fn nextItem(it: *Iterator) ?*Item {
                var maybe_node = it.sub_it.nextItem();
                if (maybe_node) |node| {
                    return &node.data;
                }
                return null;
            }

            pub fn nextIndex(it: *Iterator) ?Index {
                return it.sub_it.nextIndex();
            }

            pub fn next(it: *Iterator) ?Pair {
                const maybe_pair = it.sub_it.next();
                if (maybe_pair) |pair| {
                    return .{
                        .index = pair.index,
                        .item = &pair.item.data,
                    };
                }

                return null;
            }
        };

        node_pool: NodePool,
        first: ?Index = null,
        last: ?Index = null,
        len: usize = 0,

        pub fn new() Self {
            return .{
                .node_pool = NodePool.new(),
            };
        }

        pub fn init(self: *Self) void {
            self.node_pool.init();
            self.first = null;
            self.last = null;
            self.len = 0;
        }

        pub fn create(self: *Self, data: Item) Error!Index {
            var index = try self.node_pool.create(Node{ .data = data });
            self.appendNode(index);

            return index;
        }

        pub fn destroy(self: *Self, index: Index) void {
            self.removeNode(index);
            self.node_pool.destroy(index);
        }

        pub fn get(self: *Self, index: Index) ?*Item {
            if (self.node_pool.items[index] == null) {
                return null;
            }

            return &self.node_pool.items[index].?.data;
        }

        pub fn iterator(self: *Self) Iterator {
            return .{
                .sub_it = self.node_pool.iterator(),
            };
        }

        pub fn moveToBack(self: *Self, index: Index) void {
            self.removeNode(index);
            self.appendNode(index);
        }

        pub fn front(self: *Self) ?*Item {
            if (self.first) |first| {
                return &self.node_pool.items[first].?.data;
            }
            return null;
        }

        pub fn back(self: *Self) ?*Item {
            if (self.last) |last| {
                return &self.node_pool.items[last].?.data;
            }
            return null;
        }

        fn appendNode(self: *Self, index: Index) void {
            if (self.last) |last| {
                self.insertAfter(last, index);
            } else {
                self.first = index;
                self.last = index;
                self.len = 1;
            }
        }

        fn insertAfter(self: *Self, index: Index, new_index: Index) void {
            var node = &self.node_pool.items[index].?;
            var new_node = &self.node_pool.items[new_index].?;

            if (node.next) |next| {
                self.node_pool.items[next].?.prev = new_index;
            } else {
                self.last = new_index;
            }

            new_node.next = node.next;
            new_node.prev = index;
            node.next = new_index;

            self.len += 1;
        }

        fn insertBefore(self: *Self, index: Index, new_index: Index) void {
            var node = &self.node_pool.items[index].?;
            var new_node = &self.node_pool.items[new_index].?;

            if (node.prev) |prev| {
                self.node_pool.items[prev].?.next = new_index;
            } else {
                self.first = new_index;
            }

            new_node.next = index;
            new_node.prev = node.prev;
            node.prev = new_index;

            self.len += 1;
        }

        fn removeNode(self: *Self, index: Index) void {
            var node = &(self.node_pool.items[index] orelse return);
            if (node.prev) |prev| {
                self.node_pool.items[prev].?.next = node.next;
            } else {
                self.first = node.next;
            }
            if (node.next) |next| {
                self.node_pool.items[next].?.prev = node.prev;
            } else {
                self.last = node.prev;
            }
            self.len -= 1;
        }
    };
}

const testing = std.testing;
const expectEqual = testing.expectEqual;

test "array item pool create and destroy" {
    const Item: type = struct {
        id: u32,
        data: [4]u32,
    };
    const ItemPool = ArrayItemPool(Item, 64);
    var item_pool = ItemPool.new();
    var index = try item_pool.create(Item{ .id = 13, .data = [_]u32{ 1, 2, 3, 7 } });
    try expectEqual(@as(u32, 13), item_pool.get(index).?.*.id);
    item_pool.destroy(index);
    try expectEqual(@as(?*Item, null), item_pool.get(index));
}

test "list create and destroy" {
    const Item: type = struct {
        id: u32,
        data: [4]u32,
    };
    const ItemPool = ListItemPool(Item, 64);
    var item_pool = ItemPool.new();
    var index = try item_pool.create(
        Item{ .id = 13, .data = [_]u32{ 1, 2, 3, 7 } }
    );
    try expectEqual(@as(u32, 13), item_pool.get(index).?.*.id);
    _ = try item_pool.create(
        Item{ .id = 7, .data = [_]u32{ 7, 4, 2, 0 } }
    );
    var oldest_index = item_pool.first.?;
    try expectEqual(index, oldest_index);
}
