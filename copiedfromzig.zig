const std = @import("std");
const fs = std.fs;
const process = std.process;
const Allocator = std.mem.Allocator;

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    process.exit(1);
}

pub const Directory = struct {
    /// This field is redundant for operations that can act on the open directory handle
    /// directly, but it is needed when passing the directory to a child process.
    /// `null` means cwd.
    path: ?[]const u8,
    handle: std.fs.Dir,

    pub fn join(self: Directory, allocator: Allocator, paths: []const []const u8) ![]u8 {
        if (self.path) |p| {
            // TODO clean way to do this with only 1 allocation
            const part2 = try std.fs.path.join(allocator, paths);
            defer allocator.free(part2);
            return std.fs.path.join(allocator, &[_][]const u8{ p, part2 });
        } else {
            return std.fs.path.join(allocator, paths);
        }
    }

    pub fn joinZ(self: Directory, allocator: Allocator, paths: []const []const u8) ![:0]u8 {
        if (self.path) |p| {
            // TODO clean way to do this with only 1 allocation
            const part2 = try std.fs.path.join(allocator, paths);
            defer allocator.free(part2);
            return std.fs.path.joinZ(allocator, &[_][]const u8{ p, part2 });
        } else {
            return std.fs.path.joinZ(allocator, paths);
        }
    }

    /// Whether or not the handle should be closed, or the path should be freed
    /// is determined by usage, however this function is provided for convenience
    /// if it happens to be what the caller needs.
    pub fn closeAndFree(self: *Directory, gpa: Allocator) void {
        self.handle.close();
        if (self.path) |p| gpa.free(p);
        self.* = undefined;
    }
};

pub fn findBuildDir(allocator: std.mem.Allocator, build_file: ?[]const u8) !Directory {
    // copied this from zig/src/main.zig
    var cleanup_build_dir: ?fs.Dir = null;
    defer if (cleanup_build_dir) |*dir| dir.close();

    const build_zig_basename = if (build_file) |bf| fs.path.basename(bf) else "build.zig";
    const cwd_path = try std.process.getCwdAlloc(allocator);
    if (build_file) |bf| {
        if (fs.path.dirname(bf)) |dirname| {
            const dir = fs.cwd().openDir(dirname, .{}) catch |err| {
                fatal("unable to open directory to build file from argument 'build-file', '{s}': {s}", .{ dirname, @errorName(err) });
            };
            cleanup_build_dir = dir;
            return Directory{ .path = dirname, .handle = dir };
        }

        return Directory{ .path = null, .handle = fs.cwd() };
    }
    // Search up parent directories until we find build.zig.
    var dirname: []const u8 = cwd_path;
    while (true) {
        const joined_path = try fs.path.join(allocator, &[_][]const u8{ dirname, build_zig_basename });
        if (fs.cwd().access(joined_path, .{})) |_| {
            const dir = fs.cwd().openDir(dirname, .{}) catch |err| {
                fatal("unable to open directory while searching for build.zig file, '{s}': {s}", .{ dirname, @errorName(err) });
            };
            return Directory{ .path = dirname, .handle = dir };
        } else |err| switch (err) {
            error.FileNotFound => {
                dirname = fs.path.dirname(dirname) orelse {
                    std.log.info("{s}", .{
                        \\Initialize a 'build.zig' template file with `zig init-lib` or `zig init-exe`,
                        \\or see `zig --help` for more options.
                    });
                    fatal("No 'build.zig' file found, in the current directory or any parent directories.", .{});
                };
                continue;
            },
            else => |e| return e,
        }
    }
}
