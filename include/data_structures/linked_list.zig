const std = @import("std");

pub fn DoublyLinkedList(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            prev: ?*Node = null,
            next: ?*Node = null,
            data: T,
        };

        first: ?*Node = null,
        last: ?*Node = null,
        len: usize = 0,

        pub fn clear(self: *Self) void {
            self.first = null;
            self.last = null;
            self.len = 0;
        }

        pub fn insert_after(self: *Self, node: *Node, new_node: *Node) void {
            if (node.next) |next| {
                next.prev = new_node;
            } else {
                self.last = new_node;
            }

            new_node.next = node.next;
            new_node.prev = node;
            node.next = new_node;

            self.len += 1;
        }

        pub fn insert_before(self: *Self, node: *Node, new_node: *Node) void {
            if (node.prev) |prev| {
                prev.next = new_node;
            } else {
                self.first = new_node;
            }

            new_node.next = node;
            new_node.prev = node.prev;
            node.prev = new_node;

            self.len += 1;
        }

        pub fn append(self: *Self, node: *Node) void {
            if (self.last) |last| {
                self.insert_after(last, node);
            } else {
                self.first = node;
                self.last = node;
                self.len = 1;
            }
        }

        pub fn prepend(self: *Self, node: *Node) void {
            if (self.first) |first| {
                self.insert_before(first, node);
            } else {
                self.first = node;
                self.last = node;
                self.len = 1;
            }
        }

        pub fn remove(self: *Self, node: *Node) void {
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.first = node.next;
            }
            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.last = node.prev;
            }
            self.len -= 1;
        }

        pub fn get_first(self: *Self) ?*Node {
            return self.first;
        }

        pub fn get_last(self: *Self) ?*Node {
            return self.last;
        }
    };
}

const testing = std.testing;
const expectEqual = testing.expectEqual;

test "linked list append and remove" {
    const List = LinkedList(usize);
    var list = List{};
    var node = List.Node{
        .data = 17,
    };
    list.append(&node);
    try expectEqual(@as(usize, 17), list.get_last().?.data);
    try expectEqual(@as(usize, 1), list.len);
    list.remove(&node);
    try expectEqual(@as(usize, 0), list.len);
}
