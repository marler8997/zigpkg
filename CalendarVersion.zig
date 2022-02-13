const CalendarVersion = @This();

const std = @import("std");
const String = @import("string.zig").String;

year: u16,
month: u4,
day: u6,
pub fn parse(s: []const u8) !CalendarVersion {
    const parts = blk: {
        var result: [3][]const u8 = undefined;
        var it = std.mem.tokenize(u8, s, "_");
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            result[i] = it.next() orelse
                return error.NotEnoughUnderscores;
        }
        if (it.next()) |_| return error.TooManyUnderscores;
        break :blk result;
    };
    const values = .{
        .year = std.fmt.parseInt(u16, parts[0], 10) catch return error.InvalidYear,
        .month = std.fmt.parseInt(u16, parts[1], 10) catch return error.InvalidMonth,
        .day = std.fmt.parseInt(u16, parts[2], 10) catch return error.InvalidDay,
    };
    if (values.month < 0 or values.month > 12) return error.MonthOutOfRange;
    if (values.day < 0 or values.day > 31) return error.DayOutOfRange;
    return CalendarVersion{
        .year = values.year,
        .month = @intCast(u4, values.month),
        .day = @intCast(u6, values.day),
    };
}
pub fn max(self: CalendarVersion, other: CalendarVersion) CalendarVersion {
    if (self.year > other.year) return self;
    if (other.year > self.year) return other;
    if (self.month > other.month) return self;
    if (other.month > self.month) return other;
    return if (self.day > other.day) self else other;
}
pub fn allocToString(self: CalendarVersion, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{}", .{self});
}
pub fn format(
    self: CalendarVersion,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) @TypeOf(writer).Error!void {
    _ = fmt;
    _ = options;
    try std.fmt.format(writer, "{d}_{d}_{d}", .{ self.year, self.month, self.day });
}

pub const max_year_str = 8; // up to year 99999999 I guess?
pub const max_month_str = 2;
pub const max_day_str = 2;
pub const max_str = max_year_str + 1 + max_month_str + 1 + max_day_str;

pub fn asString(self: CalendarVersion) String(max_str) {
    return String(max_str).initFmt("{}", .{self}) catch unreachable;
}
