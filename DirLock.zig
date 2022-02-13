const DirLock = @This();
const std = @import("std");

fd: std.os.fd_t,

pub fn init(dir: std.fs.Dir, lock_filename: []const u8) !DirLock {
    const fd = try std.os.openat(dir.fd, lock_filename, std.os.O.CREAT | std.os.O.RDONLY, 0o664);
    errdefer std.os.close(fd);
    try std.os.flock(fd, std.os.LOCK.EX);
    return DirLock{ .fd = fd };
}
pub fn deinit(self: DirLock) void {
    // TODO: I don't think I need to call std.os.flock(self.fd, std.os.LUCK.UN)
    std.os.close(self.fd);
}
