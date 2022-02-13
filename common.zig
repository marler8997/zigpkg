const std = @import("std");

pub fn pathExists(dir: std.fs.Dir, path: []const u8) !bool {
    dir.access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

pub fn closeDir(dir: anytype) void {
    if (@TypeOf(dir) != std.fs.Dir and @TypeOf(dir) != std.fs.IterableDir)
        @compileError("expected 'std.fs.Dir' or 'std.fs.IterableDir' but got '" ++ @typeName(@TypeOf(dir)) ++ "'");
    var mut = dir;
    mut.close();
}

pub fn run(argv: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    std.log.info("running '{s}' command...", .{argv[0]});
    var child = std.ChildProcess.init(argv, arena.allocator());
    try child.spawn();
    const result = try child.wait();
    switch (result) {
        .Exited => |code| {
            if (code != 0) {
                std.log.err("{s} exited with code {}", .{ argv[0], code });
                std.os.exit(code);
            }
        },
        else => |e| {
            std.log.err("{s} exited with {}", .{ argv[0], e });
            std.os.exit(0xff);
        },
    }
}
