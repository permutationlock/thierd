const std = @import("std");

const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;

fn RingBufferStream(comptime Buffer: type) type {
    return struct {
        const Self = @This();

        buffer: Buffer,
        front: usize,
        back: usize,
        len: usize,

        pub const ReadError = error{};
        pub const WriteError = error{NoSpaceLeft};

        pub const Reader = std.io.Reader(*Self, error{}, read);
        pub const Writer = std.io.Writer(*Self, error{}, write);

        pub fn read(self: *Self, dest: []u8) ReadError!usize {
            const total_size = @min(dest.len, self.len);
            const end1 = @min(self.buffer.len, self.front + total_size);
            const size1 = end1 - self.front;
            @memcpy(dest[0..size1], self.buffer[self.front..end1]);
            self.len -= size1;
            self.front = end1 % self.buffer.len;

            const size2 = total_size - size1;
            const end2 = self.front + size2;
            @memcpy(dest[size1..total_size], self.buffer[self.front..end2]);
            self.len -= size2;
            self.front = end2;
            return total_size;
        }

        pub fn write(self: *Self, src: []const u8) WriteError!usize {
            const total_size = @min(src.len, self.buffer.len - self.len);
            if (total_size == 0) {
                return WriteError.NoSpaceLeft;
            }
            const end1 = @min(self.buffer.len, self.back + total_size);
            const size1 = end1 - self.back;
            @memcpy(self.buffer[self.back..end1], src[0..size1]);
            self.len += size1;
            self.back = end1 % self.buffer.len;

            const size2 = total_size - size1;
            const end2 = self.back + size2;
            @memcpy(self.buffer[self.back..end2], src[size1..total_size]);
            self.len += size2;
            self.back = end2;
            return total_size;
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }
    };
}

test "ring buffer stream read and write" {
    var buffer: [40]u8 = undefined;
    var stream = RingBufferStream([40]u8){
        .buffer = buffer, .front = 0, .back = 0, .len = 0,
    };
    const my_data: [32]u8 = [4]u8{1, 2, 3, 4}
        ++ ([4]u8{5, 6, 5, 6} ** 6)
        ++ [4]u8{7, 8, 9, 0};
    {
        const len = try stream.write(&my_data);
        try expectEqual(len, 32);
    }
    {
        var read_data: [32]u8 = undefined;
        const len = try stream.read(&read_data);
        try expectEqual(len, 32);
        try expectEqualSlices(u8, &read_data, &my_data);
    }
    {
        const len = try stream.write(&my_data);
        try expectEqual(len, 32);
    }
    {
        var read_data: [32]u8 = undefined;
        const len = try stream.read(&read_data);
        try expectEqual(len, 32);
        try expectEqualSlices(u8, &read_data, &my_data);
    }
    {
        const len = try stream.write(&my_data);
        try expectEqual(len, 32);
    }
    {
        var read_data: [32]u8 = undefined;
        const len = try stream.read(&read_data);
        try expectEqual(len, 32);
        try expectEqualSlices(u8, &read_data, &my_data);
    }
    {
        const len = try stream.write(&my_data);
        try expectEqual(len, 32);
    }
    {
        var read_data: [32]u8 = undefined;
        const len = try stream.read(&read_data);
        try expectEqual(len, 32);
        try expectEqualSlices(u8, &read_data, &my_data);
    }
}
