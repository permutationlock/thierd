pub const Message = struct {
    len: u32,
    bytes: [384]u8,
    placholder: u8 = 0x77,

    pub fn asSlice(msg: *const Message) []const u8 {
        return msg.bytes[0..@min(msg.len, 64)];
    }
};
