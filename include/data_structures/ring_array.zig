const std = @import("std");

const Error = error{OutOfSpace};

pub fn RingArray(comptime T: type, comptime size: comptime_int) type {
    return struct {
        const Self = @This();

        len: usize = 0,
        front: usize = 0,
        back: usize = 0,
        items: [size]T = undefined,

        pub fn init(self: *Self) void {
            self.front = 0;
            self.back = 0;
            self.len = 0;
        }

        pub fn push_back(self: *Self, item: T) !void {
            if (self.len >= size) {
                return Error.OutOfSpace;
            }

            self.items[self.back] = item;
            self.back = (self.back + 1) % size;
            self.len += 1;
        }

        pub fn push_back_raw(self: *Self, item: T) void {
            self.items[self.back] = item;
            self.back = (self.back + 1) % size;
            self.len += 1;
        }

        pub fn push_front(self: *Self, item: T) !void {
            if (self.len >= size) {
                return Error.OutOfSpace;
            }

            self.front = (self.front + size - 1) % size;
            self.len += 1;
            self.items[self.front] = item;
        }

        pub fn push_front_raw(self: *Self, item: T) void {
            self.front = (self.front + size - 1) % size;
            self.len += 1;
            self.items[self.front] = item;
        }

        pub fn pop_back(self: *Self) ?T {
            if (self.len == 0) {
                return null;
            }

            self.back = (self.back + size - 1) % size;
            self.len -= 1;
            return self.items[self.back];
        }

        pub fn pop_front(self: *Self) ?T {
            if (self.len == 0) {
                return null;
            }

            const old_front: usize = self.front;
            self.front = (self.front + 1) % size;
            self.len -= 1;
            return self.items[old_front];
        }

        pub fn get_back(self: *Self) ?*T {
            if (self.len == 0) {
                return null;
            }

            return &self.items[
                (self.back + size - 1) % size
            ];
        }

        pub fn get_front(self: *Self) ?*T {
            if (self.len == 0) {
                return null;
            }

            return &self.items[self.front];
        }

        pub fn available(self: *const Self) usize {
            return size - self.len;
        }

        pub fn get_items(self: *Self) *[size]T {
            return &self.items;
        }
    };
}

const testing = std.testing;
const expectEqual = testing.expectEqual;

test "ring array push_back pop_back" {
    const TwoIntRA = RingArray(u32, 2);
    var ring_array = TwoIntRA{};
    try expectEqual(@as(usize, 0), ring_array.len);
    try ring_array.push_back(3);
    try expectEqual(@as(usize, 1), ring_array.len);
    {
        const item = ring_array.get_front();
        try expectEqual(@as(u32, 3), item.?.*);
    }
    {
        const item = ring_array.pop_back();
        try expectEqual(@as(u32, 3), item.?);
    }
    try expectEqual(@as(usize, 0), ring_array.len);
}

test "ring array push_front pop_front" {
    const TwoIntRA = RingArray(u32, 2);
    var ring_array = TwoIntRA{};
    try expectEqual(@as(usize, 0), ring_array.len);
    try ring_array.push_front(3);
    try expectEqual(@as(usize, 1), ring_array.len);
    {
        const item = ring_array.get_front();
        try expectEqual(@as(u32, 3), item.?.*);
    }
    {
        const item = ring_array.pop_front();
        try expectEqual(@as(u32, 3), item.?);
    }
    try expectEqual(@as(usize, 0), ring_array.len);
}
