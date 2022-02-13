const std = @import("std");

pub fn String(comptime capacity: usize) type {
    return struct {
        buf: [capacity]u8,
        len: usize,
        pub fn initFmt(comptime fmt: []const u8, args: anytype) error{NoSpaceLeft}!@This() {
            var result: @This() = undefined;
            result.len = (try std.fmt.bufPrint(&result.buf, fmt, args)).len;
            return result;
        }
        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0 .. self.len];
        }
    };
}
