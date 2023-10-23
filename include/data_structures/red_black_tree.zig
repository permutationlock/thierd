const std = @import("std");

pub fn LeftLeaningRBT(comptime K: type, comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Key = K;
        pub const Value = T;

        pub const Color = bool;
        pub const Red = true;
        pub const Black = false;

        pub const Node = struct {
            left: ?*Node = null,
            right: ?*Node = null,
            color: Color = Red,
            key: Key,
            value: Value,

            pub fn init(key: Key, value: Value) Node {
                return Node{
                    .key = key,
                    .value = value,
                };
            }
        };

        root: ?*Node = null,
        len: usize = 0,

        pub fn clear(self: *Self) void {
            self.root = null;
            self.len = 0;
        }

        pub fn find(self: *Self, key: Key) ?*Node {
            var maybe_node: ?*Node = self.root;
            while (maybe_node) |node| {
                if (key == node.key) {
                    break;
                } else if (key < node.key) {
                    maybe_node = node.left;
                } else {
                    maybe_node = node.right;
                }
            }

            return maybe_node;
        }

        pub fn insert(self: *Self, node: *Node) void {
            self.root = insert_recursive(self.root, node);
            self.len += 1;
        }

        pub fn insert_recursive(maybe_node: ?*Node, new_node: *Node) *Node {
            if (maybe_node) |*node_ptr| {
                var node = node_ptr.*;
                if (new_node.key < node.key) {
                    node.left = insert_recursive(node.left, new_node);
                } else if (new_node.key > node.key) {
                    node.right = insert_recursive(node.right, new_node);
                }
                return balance(node);
            }

            return new_node;
        }

        pub fn balance(cnode: *Node) *Node {
            var node: *Node = cnode;
            if (is_red(node.right)) {
                node = rotate_left(node);
            }

            if (is_red(node.left)) {
                if (is_red(node.left.?.left)) {
                    node = rotate_right(node);
                }
            }

            if (is_red(node.left) and is_red(node.right)) {
                flip_colors(node);
            }

            return node;
        }

        pub fn is_red(maybe_node: ?*Node) bool {
            if (maybe_node) |node| {
                return node.color == Red;
            }

            return false;
        }

        pub fn rotate_left(node: *Node) *Node {
            var right_child: *Node = node.right.?;
            node.right = right_child.left;
            right_child.left = node;
            right_child.color = node.color;
            node.color = Red;

            return right_child;
        }

        pub fn rotate_right(node: *Node) *Node {
            var left_child: *Node = node.left.?;
            node.left = left_child.right;
            left_child.right = node;
            left_child.color = node.color;
            node.color = Red;

            return left_child;
        }

        pub fn flip_colors(node: *Node) void {
            node.color = !node.color;
            node.left.?.color = !node.left.?.color;
            node.right.?.color = !node.right.?.color;
        }
    };
}

const testing = std.testing;
const expectEqual = testing.expectEqual;

test "left leaning RBT insert" {
    const IntRBT = LeftLeaningRBT(u32, u32);
    const Node = IntRBT.Node;
    var rbt = IntRBT{};
    var nodes: [5]Node = [5]Node{ Node.init(17, 1), Node.init(5, 12), Node.init(7, 3), Node.init(83, 2), Node.init(3, 73) };

    for (&nodes) |*node| {
        rbt.insert(node);
    }

    try expectEqual(@as(usize, 5), rbt.len);
    var node_five = rbt.find(5).?;
    try expectEqual(@as(u32, 12), node_five.value);
}
