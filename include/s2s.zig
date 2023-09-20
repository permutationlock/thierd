// Copyright (c) 2022 Felix "xq" Queißner
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE
// OR OTHER DEALINGS IN THE SOFTWARE.

const std = @import("std");
const testing = std.testing;

pub fn serialize(stream: anytype, comptime T: type, value: T) @TypeOf(stream).Error!void {
    try serializeRecursive(stream, T, @as(T, value)); // use @as() to coerce to non-tuple type
}

pub fn deserialize(stream: anytype, comptime T: type) (@TypeOf(stream).Error || error{ UnexpectedData, EndOfStream })!T {
    var result: T = undefined;
    try recursiveDeserialize(stream, T, &result);
    return result;
}

fn serializeRecursive(stream: anytype, comptime T: type, value: T) @TypeOf(stream).Error!void {
    switch (@typeInfo(T)) {
        // Primitive types:
        .Void => {}, // no data
        .Bool => try stream.writeByte(@intFromBool(value)),
        .Float => switch (T) {
            f16 => try stream.writeIntLittle(u16, @as(u16, @bitCast(value))),
            f32 => try stream.writeIntLittle(u32, @as(u32, @bitCast(value))),
            f64 => try stream.writeIntLittle(u64, @as(u64, @bitCast(value))),
            f80 => try stream.writeIntLittle(u80, @as(u80, @bitCast(value))),
            f128 => try stream.writeIntLittle(u128, @as(u128, @bitCast(value))),
            else => unreachable,
        },

        .Int => {
            if (T == usize) {
                try stream.writeIntLittle(u64, value);
            } else {
                try stream.writeIntLittle(T, value);
            }
        },
        .Array => |arr| {
            if (arr.child == u8) {
                try stream.writeAll(&value);
            } else {
                for (value) |item| {
                    try serializeRecursive(stream, arr.child, item);
                }
            }
            if (arr.sentinel != null) @compileError("Sentinels are not supported yet!");
        },
        .Struct => |str| {
            // we can safely ignore the struct layout here as we will serialize the data by field order,
            // instead of memory representation

            inline for (str.fields) |fld| {
                try serializeRecursive(stream, fld.type, @field(value, fld.name));
            }
        },
        .Optional => |opt| {
            if (value) |item| {
                try stream.writeIntLittle(u8, 1);
                try serializeRecursive(stream, opt.child, item);
            } else {
                try stream.writeIntLittle(u8, 0);
            }
        },
        .ErrorUnion => |eu| {
            if (value) |item| {
                try stream.writeIntLittle(u8, 1);
                try serializeRecursive(stream, eu.payload, item);
            } else |item| {
                try stream.writeIntLittle(u8, 0);
                try serializeRecursive(stream, eu.error_set, item);
            }
        },
        .ErrorSet => {
            // Error unions are serialized by "index of sorted name", so we
            // hash all names in the right order
            const names = comptime getSortedErrorNames(T);

            const index: u16 = for (names, 0..) |name, i| {
                if (std.mem.eql(u8, name, @errorName(value)))
                    break @intCast(i);
            } else unreachable;

            try stream.writeIntLittle(u16, index);
        },
        .Enum => |list| {
            const Tag = if (list.tag_type == usize) u64 else list.tag_type;
            try stream.writeIntLittle(Tag, @intFromEnum(value));
        },
        .Union => |un| {
            const Tag = un.tag_type orelse @compileError("Untagged unions are not supported!");

            const active_tag = std.meta.activeTag(value);

            try serializeRecursive(stream, Tag, active_tag);

            inline for (std.meta.fields(T)) |fld| {
                if (@field(Tag, fld.name) == active_tag) {
                    try serializeRecursive(stream, fld.type, @field(value, fld.name));
                }
            }
        },
        .Vector => |vec| {
            var array: [vec.len]vec.child = value;
            try serializeRecursive(stream, @TypeOf(array), array);
        },
        else => unreachable,
    }
}

fn readIntLittleAny(stream: anytype, comptime T: type) !T {
    const BiggerInt = std.meta.Int(@typeInfo(T).Int.signedness, 8 * @as(usize, ((@bitSizeOf(T) + 7)) / 8));
    return @truncate(try stream.readIntLittle(BiggerInt));
}

fn recursiveDeserialize(stream: anytype, comptime T: type, target: *T) (@TypeOf(stream).Error || error{ UnexpectedData, EndOfStream })!void {
    switch (@typeInfo(T)) {
        // Primitive types:
        .Void => target.* = {},
        .Bool => target.* = (try stream.readByte()) != 0,
        .Float => target.* = @bitCast(switch (T) {
            f16 => try stream.readIntLittle(u16),
            f32 => try stream.readIntLittle(u32),
            f64 => try stream.readIntLittle(u64),
            f80 => try stream.readIntLittle(u80),
            f128 => try stream.readIntLittle(u128),
            else => unreachable,
        }),

        .Int => target.* = if (T == usize)
            std.math.cast(usize, try stream.readIntLittle(u64)) orelse return error.UnexpectedData
        else
            try readIntLittleAny(stream, T),

        .Array => |arr| {
            if (arr.child == u8) {
                try stream.readNoEof(target);
            } else {
                for (target.*) |*item| {
                    try recursiveDeserialize(stream, arr.child, item);
                }
            }
        },
        .Struct => |str| {
            // we can safely ignore the struct layout here as we will serialize the data by field order,
            // instead of memory representation

            inline for (str.fields) |fld| {
                try recursiveDeserialize(stream, fld.type, &@field(target.*, fld.name));
            }
        },
        .Optional => |opt| {
            const is_set = try stream.readIntLittle(u8);

            if (is_set != 0) {
                target.* = @as(opt.child, undefined);
                try recursiveDeserialize(stream, opt.child, &target.*.?);
            } else {
                target.* = null;
            }
        },
        .ErrorUnion => |eu| {
            const is_value = try stream.readIntLittle(u8);
            if (is_value != 0) {
                var value: eu.payload = undefined;
                try recursiveDeserialize(stream, eu.payload, &value);
                target.* = value;
            } else {
                var err: eu.error_set = undefined;
                try recursiveDeserialize(stream, eu.error_set, &err);
                target.* = err;
            }
        },
        .ErrorSet => {
            // Error unions are serialized by "index of sorted name", so we
            // hash all names in the right order
            const names = comptime getSortedErrorNames(T);
            const index = try stream.readIntLittle(u16);

            inline for (names, 0..) |name, i| {
                if (i == index) {
                    target.* = @field(T, name);
                    return;
                }
            }
            return error.UnexpectedData;
        },
        .Enum => |list| {
            const Tag = if (list.tag_type == usize) u64 else list.tag_type;
            const tag_value = try readIntLittleAny(stream, Tag);
            if (list.is_exhaustive) {
                target.* = std.meta.intToEnum(T, tag_value) catch return error.UnexpectedData;
            } else {
                target.* = @enumFromInt(tag_value);
            }
        },
        .Union => |un| {
            const Tag = un.tag_type orelse @compileError("Untagged unions are not supported!");

            var active_tag: Tag = undefined;
            try recursiveDeserialize(stream, Tag, &active_tag);

            inline for (std.meta.fields(T)) |fld| {
                if (@field(Tag, fld.name) == active_tag) {
                    var union_value: fld.type = undefined;
                    try recursiveDeserialize(stream, fld.type, &union_value);
                    target.* = @unionInit(T, fld.name, union_value);
                    return;
                }
            }

            return error.UnexpectedData;
        },
        .Vector => |vec| {
            var array: [vec.len]vec.child = undefined;
            try recursiveDeserialize(stream, @TypeOf(array), &array);
            target.* = array;
        },

        else => unreachable,
    }
}

fn getSortedErrorNames(comptime T: type) []const []const u8 {
    comptime {
        const error_set = @typeInfo(T).ErrorSet orelse @compileError("Cannot serialize anyerror");

        var sorted_names: [error_set.len][]const u8 = undefined;
        for (error_set, 0..) |err, i| {
            sorted_names[i] = err.name;
        }

        std.mem.sort([]const u8, &sorted_names, {}, struct {
            fn order(ctx: void, lhs: []const u8, rhs: []const u8) bool {
                _ = ctx;
                return (std.mem.order(u8, lhs, rhs) == .lt);
            }
        }.order);
        return &sorted_names;
    }
}

fn testSerialize(comptime T: type, value: T) !void {
    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    try serialize(data.writer(), T, value);
}

test "serialize basics" {
    try testSerialize(void, {});
    try testSerialize(bool, false);
    try testSerialize(bool, true);
    try testSerialize(u1, 0);
    try testSerialize(u1, 1);
    try testSerialize(u8, 0xFF);
    try testSerialize(u32, 0xDEADBEEF);
    try testSerialize(usize, 0xDEADBEEF);

    try testSerialize(f16, std.math.pi);
    try testSerialize(f32, std.math.pi);
    try testSerialize(f64, std.math.pi);
    try testSerialize(f80, std.math.pi);
    try testSerialize(f128, std.math.pi);

    try testSerialize(enum { a, b, c }, .a);
    try testSerialize(enum { a, b, c }, .b);
    try testSerialize(enum { a, b, c }, .c);

    try testSerialize(enum(u8) { a, b, c }, .a);
    try testSerialize(enum(u8) { a, b, c }, .b);
    try testSerialize(enum(u8) { a, b, c }, .c);

    try testSerialize(enum(isize) { a, b, c }, .a);
    try testSerialize(enum(isize) { a, b, c }, .b);
    try testSerialize(enum(isize) { a, b, c }, .c);

    try testSerialize(enum(usize) { a, b, c }, .a);
    try testSerialize(enum(usize) { a, b, c }, .b);
    try testSerialize(enum(usize) { a, b, c }, .c);

    const TestEnum = enum(u8) { a, b, c, _ };
    try testSerialize(TestEnum, .a);
    try testSerialize(TestEnum, .b);
    try testSerialize(TestEnum, .c);
    try testSerialize(TestEnum, @as(TestEnum, @enumFromInt(0xB1)));

    try testSerialize(struct { val: error{ Foo, Bar } }, .{ .val = error.Foo });
    try testSerialize(struct { val: error{ Bar, Foo } }, .{ .val = error.Bar });

    try testSerialize(struct { val: error{ Bar, Foo }!u32 }, .{ .val = error.Bar });
    try testSerialize(struct { val: error{ Bar, Foo }!u32 }, .{ .val = 0xFF });

    try testSerialize(union(enum) { a: f32, b: u32 }, .{ .a = 1.5 });
    try testSerialize(union(enum) { a: f32, b: u32 }, .{ .b = 2.0 });

    try testSerialize(?u32, null);
    try testSerialize(?u32, 143);
}


pub fn serializedSize(comptime T: type) usize {
    switch (@typeInfo(T)) {
        .Void => return 0,
        .Bool, .Float, .Int => return @sizeOf(T),
        .Array => |arr| {
            return serializedSize(arr.child) * arr.len;
        },
        .Struct => |str| {
            var sum: usize = 0;
            inline for (str.fields) |fld| {
                sum += serializedSize(fld.type);
            }
            return sum;
        },
        .Optional => |opt| {
            return 1 + serializedSize(opt.child);
        },
        .ErrorUnion => |eu| {
            return 1 + @max(
                serializedSize(eu.payload),
                serializedSize(eu.error_set)
            );
        },
        .ErrorSet => return @sizeOf(u16),
        .Enum => |list| {
            return @sizeOf(list.tag_type);
        },
        .Union => |un| {
            var max: usize = 0;
            inline for (std.meta.fields(T)) |fld| {
                max = @max(max, serializedSize(fld.type));
            }
            return max + @sizeOf(
                un.tag_type
                    orelse @compileError("Untagged unions are not supported!")
            );
        },
        .Vector => |vec| {
            return vec.len * serializedSize(vec.child);
        },

        else => unreachable,
    }
}


test "serialized size" {
    const Point = struct { x: f64, y: f32 };
    const size = comptime serializedSize(Point);
    try testing.expectEqual(12, size);
    try testing.expectEqual(16, @sizeOf(Point));
}
