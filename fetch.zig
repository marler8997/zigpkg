const builtin = @import("builtin");
const std = @import("std");
const ziget = @import("ziget");

const String = @import("string.zig").String;
const common = @import("common.zig");
const DirLock = @import("DirLock.zig");

fn ignoreHttpCallback(request: []const u8) void { _ = request; }

const PathString = String(std.fs.MAX_PATH_BYTES);

fn getCachePath() error{HomeEnvNotSet,HomeEnvTooLong}!PathString {
    if (builtin.os.tag == .windows)
        @panic("getCachePath not implemented on Windows");
    const home = std.os.getenv("HOME") orelse {
        std.log.err("HOME environment variable not set", .{});
        return error.HomeEnvNotSet;
    };
    return PathString.initFmt(
        "{s}" ++ std.fs.path.sep_str ++ ".cache" ++ std.fs.path.sep_str ++ "zigpkg", .{home}
    ) catch |err| switch (err) {
        error.NoSpaceLeft => return error.HomeEnvTooLong,
    };
}

fn openCacheDir() !std.fs.Dir {
    const path = try getCachePath();
    try std.fs.cwd().makePath(path.slice());
    return std.fs.cwd().openDir(path.slice(), .{});
}

fn downloadArchive(allocator: std.mem.Allocator, url: []const u8) !bool {
    const cache_dir = try openCacheDir();
    defer common.closeDir(cache_dir);

    const basename = std.fs.path.basenamePosix(url);

    var lock_name = try PathString.initFmt("{s}.lock", .{basename});
    const archive_lock = try DirLock.init(cache_dir, lock_name.slice());
    defer archive_lock.deinit();

    const already_downloaded = try common.pathExists(cache_dir, basename);

    if (!already_downloaded) {
        var tmp_name = try PathString.initFmt("{s}.downloading", .{basename});
        cache_dir.deleteFile(tmp_name.slice()) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };

        {
            var archive_file = try cache_dir.createFile(tmp_name.slice(), .{});
            defer archive_file.close();
            var download_options = ziget.request.DownloadOptions{
                .flags = 0,
                .allocator = allocator,
                .maxRedirects = 10,
                .forwardBufferSize = 4096,
                .maxHttpResponseHeaders = 8192,
                .onHttpRequest = ignoreHttpCallback,
                .onHttpResponse = ignoreHttpCallback,
            };
            var dowload_state = ziget.request.DownloadState.init();
            try ziget.request.download(
                ziget.url.parseUrl(url) catch unreachable,
                // TODO: use a buffered writer???
                archive_file.writer(),
                download_options,
                &dowload_state,
            );
        }
        try cache_dir.rename(tmp_name.slice(), basename);
    }
    // TODO: will deleting this file here cause any race condition?
    try cache_dir.deleteFile(lock_name.slice());
    return !already_downloaded;
}

pub fn installDepArchive(
    allocator: std.mem.Allocator,
    dep_dir: std.fs.Dir,
    installing_name: []const u8,
    url: []const u8,
) !void {
    if (try downloadArchive(allocator, url)) {
        std.log.info("downloaded {s}", .{url});
    } else {
        std.log.info("already downloaded {s}", .{url});
    }

    const basename = std.fs.path.basenamePosix(url);
    const download_path = blk: {
        const cache_path = try getCachePath();
        break :blk try PathString.initFmt("{s}" ++ std.fs.path.sep_str ++ "{s}", .{cache_path.slice(), basename});
    };
    const install_path = blk: {
        var install_dir_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const install_dir_path = try dep_dir.realpath(".", &install_dir_path_buf);
        break :blk try PathString.initFmt("{s}" ++ std.fs.path.sep_str ++ "{s}", .{install_dir_path, installing_name});
    };
    
    try dep_dir.makeDir(installing_name);

    std.log.info("tar extracting '{s}' to '{s}'...", .{download_path.slice(), install_path.slice()});
    var child = std.ChildProcess.init(
        &[_][]const u8 { "tar", "xf", download_path.slice(), "-C", install_path.slice()},
        allocator,
    );
    try child.spawn();
    if (switch (try child.wait()) {
        .Exited => |code| code != 0,
        else => true,
    }) {
        std.log.err("tar failed to extract archive '{s}'", .{basename});
        return error.ExtractArchiveFailed;
    }
}
