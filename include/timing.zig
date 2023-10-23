const std = @import("std");
const ArgsTuple = std.meta.ArgsTuple;

pub fn timeFn(
    clock_id: i32,
    comptime Fn: type,
    function: Fn,
    args: ArgsTuple(Fn)
) !f64 {
    var nruns: u64 = 1;
    var delta: u64 = 0;
    while (delta < 1000 * 1000 * 1000) {
        nruns *= 2;
        var last: std.os.timespec = undefined;
        std.os.clock_gettime(clock_id, &last) catch unreachable;
        var i: u32 = 0;
        while (i < nruns) {
            switch (@typeInfo(@typeInfo(Fn).Fn.return_type.?)) {
                .ErrorUnion => {
                    _ = @call(.never_inline, function, args) catch |err| {
                        std.debug.panic(
                            "error while timing {s}",
                            .{@errorName(err)}
                        );
                    };
                },
                .Void => @call(.never_inline, function, args),
                else => _ = @call(.never_inline, function, args),
            }
            i += 1;
        }

        {
            var current: std.os.timespec = undefined;
            std.os.clock_gettime(clock_id, &current) catch unreachable;
            const seconds = @as(
                u64,
                @intCast(current.tv_sec - last.tv_sec)
            );
            const elapsed = (seconds * 1000 * 1000 * 1000)
                + @as(u32, @intCast(current.tv_nsec))
                - @as(u32, @intCast(last.tv_nsec));
            delta = elapsed;
        }
    }
    return @as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(nruns));
}
