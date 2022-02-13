const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const copiedfromzig = @import("copiedfromzig.zig");
const Directory = copiedfromzig.Directory;
const PkgDb = @import("PkgDb.zig");
const common = @import("common.zig");

var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const global_allocator = arena_instance.allocator();

pub fn main() anyerror!void {
    // assume we are building for now
    try cmdBuild();
}

fn cmdBuild() !void {
    // find build.zig
    const build_dir = try copiedfromzig.findBuildDir(global_allocator, null);
    defer common.closeDir(build_dir.handle);
    if (build_dir.path) |p| {
        std.log.info("build_dir='{s}'", .{p});
    } else {
        std.log.info("build_dir=null", .{});
    }

    const zig_cache_dir = blk: {
        break :blk build_dir.handle.openDir("zig-cache", .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try build_dir.handle.makeDir("zig-cache");
                break :blk try std.fs.cwd().openDir("zig-cache", .{});
            },
            else => |e| return e,
        };
    };
    defer common.closeDir(zig_cache_dir);

    try PkgDb.fetch(build_dir.handle);

    // TODO: build the build.zig files together so we can get the packages that we need to request
    // Fow now we'll just assume we need all the dependencies
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const pkg_db = try PkgDb.open(arena.allocator(), build_dir);
        defer pkg_db.close();
        //try resolveDeps(pkg_db, "iguanaTLS", "marler");
        try resolveDeps(pkg_db, "ziget", "marler");
    }
}

fn resolveDeps(pkg_db: PkgDb, pkg_name: []const u8, pkg_namespace: []const u8) !void {
    std.log.info("resolveDeps for {s}/{s}", .{pkg_name, pkg_namespace});
    const deps = blk: {
        const pkg = try pkg_db.openPkg(pkg_name, pkg_namespace);
        defer pkg.close();

        const ver = try pkg.getLatestVersion();
        std.log.info("latest version of {s}/{s} is {}", .{pkg_name, pkg_namespace, ver});

        break :blk try pkg.getDeps(ver);
    };
    defer deps.deinit(pkg_db.allocator);

    var it = deps.iterator();
    while (it.next()) |dep| {
        try pkg_db.resolveDep(dep);
    }
}
