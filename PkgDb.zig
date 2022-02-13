const PkgDb = @This();

const builtin = @import("builtin");
const std = @import("std");
const ziget = @import("ziget");
const Allocator = std.mem.Allocator;
const copiedfromzig = @import("copiedfromzig.zig");
const Directory = copiedfromzig.Directory;
const CalendarVersion = @import("CalendarVersion.zig");
const common = @import("common.zig");
const buildplatform = @import("buildplatform.zig");
const hostsmod = @import("hosts.zig");
const PkgVars = @import("PkgVars.zig");
const String = @import("string.zig").String;
const DirLock = @import("DirLock.zig");
const fetchmod = @import("fetch.zig");

const Host = hostsmod.Host;

allocator: Allocator,
build_dir: Directory,

const db_dir_name = "zig-cache" ++ std.fs.path.sep_str ++ "pkg-db";

pub fn fetch(build_dir: std.fs.Dir) !void {
    // for now we'll just clone the repo locally
    if (build_dir.access(db_dir_name, .{})) {
        std.log.info("database '{s}' is already fetched", .{db_dir_name});
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    // TODO: clone into zig-cache/tmp instead
    // TODO: use lock file
    std.log.info("cloning '{s}'...", .{db_dir_name});
    const cloning = db_dir_name ++ ".cloning";
    try build_dir.deleteTree(cloning);
    try common.run(&[_][]const u8{ "git", "clone", "https://github.com/marler8997/zig-pkg-db", cloning });
    try build_dir.rename(cloning, db_dir_name);
}

pub fn open(allocator: Allocator, build_dir: Directory) !PkgDb {
    return PkgDb{
        .allocator = allocator,
        .build_dir = build_dir,
    };
}
pub fn close(self: PkgDb) void {
    _ = self;
}

pub fn openPkg(self: *const PkgDb, name: []const u8, namespace: []const u8) !Pkg {
    const pkg_path = try getPkgPath(name, namespace);
    const pkg_dir = self.build_dir.handle.openIterableDir(pkg_path.slice(), .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("package {s}/{s} does not exist", .{name, namespace});
            return error.PkgNotFound;
        },
        else => |e| return e,
    };
    errdefer common.closeDir(pkg_dir);
    return Pkg{
        .db = self,
        .name = name,
        .namespace = namespace,
        .dir = pkg_dir,
    };
}

fn getPkgPath(name: []const u8, namespace: []const u8) error{NameTooLong}!String(std.fs.MAX_PATH_BYTES) {
    const fmt = db_dir_name ++ std.fs.path.sep_str ++ "{s}" ++ std.fs.path.sep_str ++ "{s}";
    return String(std.fs.MAX_PATH_BYTES).initFmt(fmt, .{name, namespace}) catch |err| switch (err) {
        error.NoSpaceLeft => {
            std.log.err("pkg name/namespace too long '{s}/{s}'", .{name, namespace});
            return error.NameTooLong;
        },
    };
}


pub const Dep = struct {
    name: []const u8,
    namespace: []const u8,
    version: CalendarVersion,
    pub fn deinit(self: Dep, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.namespace);
    }
    pub fn format(
        self: Dep,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;
        try std.fmt.format(writer, "{s}/{s}/{s}", .{self.name, self.namespace, self.version});
    }
};

pub const Pkg = struct {
    db: *const PkgDb,
    name: []const u8,
    namespace: []const u8,
    dir: std.fs.IterableDir,

    pub fn close(self: Pkg) void {
        common.closeDir(self.dir);
    }

    pub fn openVersion(self: *const Pkg, version: CalendarVersion) !PkgVersion {
        const version_str = version.asString();
        const dir = self.dir.dir.openIterableDir(version_str.slice(), .{}) catch |err| switch (err) {
            error.FileNotFound => return error.PkgVersionNotFound,
            else => |e| return e,
        };
        return PkgVersion{
            .pkg = self,
            .dir = dir,
            .version = version,
        };
    }

    // TODO: should we provide a version iterator instead?
    pub fn getLatestVersion(self: Pkg) !CalendarVersion {
        var it = self.dir.iterate();

        var latest_version: ?CalendarVersion = null;
        while (try it.next()) |entry| {
            if (entry.name[0] > '9' or entry.name[0] < '0')
                continue;
            const version = CalendarVersion.parse(entry.name) catch |err| {
                std.log.err("package '{s}/{s}' is corrupt, invalid version '{s}' ({s})", .{ self.name, self.namespace, entry.name, @errorName(err) });
                return error.PkgDbCorrupt;
            };
            if (latest_version) |latest| {
                latest_version = latest.max(version);
            } else {
                latest_version = version;
            }
        }
        if (latest_version) |v| return v;
        std.log.err("package '{s}/{s}' is corrupt, has no versions", .{ self.name, self.namespace });
        return error.PkgDbCorrupt;
    }

    fn readFile(self: Pkg, allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ db_dir_name, self.name, self.namespace, name });
        defer allocator.free(path);
        var file = try self.db.build_dir.handle.openFile(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    }

    fn readHostsFile(self: Pkg, allocator: std.mem.Allocator) ![]const u8 {
        return self.readFile(allocator, "hosts") catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err("pkg '{s}/{s}' is corrupt, it has no 'hosts' file", .{self.name, self.namespace});
                return error.PkgDbCorrupt;
            },
            else => |e| return e,
        };
    }

    fn getPath(self: Pkg) error{NameTooLong}!String(std.fs.MAX_PATH_BYTES) {
        return String(std.fs.MAX_PATH_BYTES).initFmt("{s}{s}{s}{1s}{s}", .{
            db_dir_name,
            std.fs.path.sep_str,
            self.name,
            self.namespace,
        }) catch |err| switch (err) {
            error.NoSpaceLeft => {
                std.log.err("pkg directory path too long '{s}{s}{s}{1s}{s}'", .{
                    db_dir_name,
                    std.fs.path.sep_str,
                    self.name,
                    self.namespace,
                });
                return error.NameTooLong;
            },
        };
    }
    fn getVersionPath(self: Pkg, version: CalendarVersion) error{NameTooLong}!String(std.fs.MAX_PATH_BYTES) {
        const version_str = version.asString();
        return String(std.fs.MAX_PATH_BYTES).initFmt("{s}{s}{s}{1s}{s}{1s}{s}", .{
            db_dir_name,
            std.fs.path.sep_str,
            self.name,
            self.namespace,
            version_str,
        }) catch |err| switch (err) {
            error.NoSpaceLeft => {
                std.log.err("pkg directory path too long '{s}{s}{s}{1s}{s}{1s}{s}'", .{
                    db_dir_name,
                    std.fs.path.sep_str,
                    self.name,
                    self.namespace,
                    version_str,
                });
                return error.NameTooLong;
            },
        };
    }

    const ParseErrorHandler = struct {
        base: hostsmod.ParseErrorHandler = .{ .on_error = on_error },
        pkg: *const Pkg,
        fn on_error(base: *hostsmod.ParseErrorHandler, line: u32, msg: []const u8) void {
            const self = @fieldParentPtr(@This(), "base", base);
            std.log.err("pkg '{s}/{s}' is corrupt, hosts files line {d}: {s}", .{
                self.pkg.name,
                self.pkg.namespace,
                line,
                msg,
            });
        }
    };

    pub fn readHosts(self: Pkg, allocator: std.mem.Allocator, pkg_vars: PkgVars) ![]Host {
        const hosts_content = try self.readHostsFile(allocator);
        defer allocator.free(hosts_content);

        var error_handler = ParseErrorHandler{ .pkg = &self };
        return hostsmod.parse(allocator, hosts_content, pkg_vars, &error_handler.base) catch |err| switch (err) {
            error.ReportedParseError => return error.PkgDbCorrupt,
            else => |e| return e,
        };
    }

    pub fn getDeps(self: Pkg, version: CalendarVersion) !DepsFromDb {
        const platform_str = buildplatform.getStr() catch std.os.exit(0xff);

        const version_str = version.asString();

        const depfile_path = try std.fs.path.join(self.db.allocator, &[_][]const u8{ db_dir_name, self.name, self.namespace, version_str.slice(), "platform", platform_str });
        defer self.db.allocator.free(depfile_path);

        var deps_al = std.ArrayListUnmanaged(Dep){};
        errdefer {
            for (deps_al.items) |dep| {
                dep.deinit(self.db.allocator);
            }
            deps_al.deinit(self.db.allocator);
        }

        const deps_content = blk: {
            // TODO: if open fails, report a nice error saying which part of the
            //       path is missing
            var deps_file = try self.db.openFile(.platform_dep, depfile_path, .{});
            defer deps_file.close();
            break :blk try deps_file.readToEndAlloc(self.db.allocator, std.math.maxInt(usize));
        };
        errdefer self.db.allocator.free(deps_content);
        return try DepsFromDb.init(self.db.allocator, deps_content);
    }
    pub fn format(
        self: Pkg,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;
        try std.fmt.format(writer, "{s}/{s}", .{self.name, self.namespace});
    }
};

pub const PkgVersion = struct {
    pkg: *const Pkg,
    version: CalendarVersion,
    dir: std.fs.IterableDir,

    pub fn close(self: PkgVersion) void {
        common.closeDir(self.dir);
    }

    pub fn getVars(self: PkgVersion, allocator: std.mem.Allocator) !PkgVars {
        const customversion = try self.readCustomVersion(allocator);
        errdefer allocator.free(customversion);
        return PkgVars{
            .customversion = customversion,
        };
    }

    fn readCustomVersion(self: PkgVersion, allocator: std.mem.Allocator) !?[]const u8 {
        var file = self.dir.dir.openFile("customversion", .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| return e,
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        errdefer allocator.free(content);
        {
            const trimmed = std.mem.trimRight(u8, content, " \r\n");
            if (trimmed.len != content.len) {
                std.log.err("'{}' is corrupt, contains whitespace", .{self});
                return error.PkgDbCorrupt;
            }
        }
        return content;
    }

    fn readGitSha(self: PkgVersion) !?[40]u8 {
        var file = self.dir.dir.openFile("gitsha", .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| return e,
        };
        defer file.close();

        var content: [40]u8 = undefined;
        {
            const len = try file.readAll(&content);
            if (len < 40) {
                std.log.err("'{}' is corrupt, gitsha is {} characters (must be exactly 40)", .{self, len});
                return error.PkgDbCorrupt;
            }
        }
        {
            var extra: [1]u8 = undefined;
            const len = try file.readAll(&extra);
            if (len > 0) {
                std.log.err("'{}' is corrupt, gitsha is longer than 40 characters", .{self});
                return error.PkgDbCorrupt;
            }
        }
        for (content) |c| {
            if (!std.ascii.isXDigit(c)) {
                std.log.err("'{}' is corrupt, gitsha contains non-hex characters", .{self});
                return error.PkgDbCorrupt;
            }
        }
        return content;
    }

    pub fn format(
        self: PkgVersion,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;
        try std.fmt.format(writer, "{}/{}", .{self.pkg.*, self.version});
    }
};


const FileKind = enum {
    platform_dep,
};
fn openFile(self: PkgDb, kind: FileKind, path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
    return self.build_dir.handle.openFile(path, flags) catch |err| switch (err) {
        error.FileNotFound => {
            // TODO: walk up the directory tree to find out what's wrong
            //       use 'kind' to determine what being looked for
            std.log.info("{s} file '{s}' not found", .{ @tagName(kind), path });
            std.os.exit(0xff);
        },
        else => |e| return e,
    };
}

const ParsedDep = struct {
    slash_off: u16,
    space_off: u16,
    version: CalendarVersion,

    pub fn init(line: []const u8) !ParsedDep {
        std.debug.assert(line.len <= std.math.maxInt(u16));
        const space_off = std.mem.indexOfScalar(u8, line, ' ') orelse
            return error.MissingSpace;
        const slash_off = std.mem.indexOfScalar(u8, line[0..space_off], '/') orelse
            return error.MissingSlash;
        {
            const name = line[0..slash_off];
            if (name.len == 0)
                return error.EmptyPkgName;
            if (badPkgNameIndex(name)) |_|
                return error.InvalidPkgName;
        }
        {
            const ns = line[slash_off + 1 .. space_off];
            if (ns.len == 0)
                return error.EmptyPkgNamespace;
            if (badPkgNameIndex(ns)) |_|
                return error.InvalidPkgNamespace;
        }
        return ParsedDep{
            .slash_off = @intCast(u16, slash_off),
            .space_off = @intCast(u16, space_off),
            .version = try CalendarVersion.parse(line[space_off + 1 ..]),
        };
    }
};

fn badPkgNameIndex(s: []const u8) ?usize {
    for (s) |c, i| {
        if (c >= 'a') {
            if (c > 'z') return i;
        } else if (c >= 'A') {
            if (c > 'Z' and c != '_') return i;
        } else if (c != '-')
            return i;
    }
    return null;
}

const ParsedDepLine = struct {
    str: []const u8,
    parsed: ParsedDep,
};
const DepsFromDb = struct {
    file_content: []const u8,
    deps: []ParsedDepLine,

    pub fn init(allocator: Allocator, file_content: []const u8) !DepsFromDb {
        var it = std.mem.tokenize(u8, file_content, "\n");

        var deps = std.ArrayListUnmanaged(ParsedDepLine){};
        defer deps.deinit(allocator);

        while (it.next()) |line| {
            if (line.len > std.math.maxInt(u16)) {
                // TODO: include the package info like name/namespace/etc
                std.log.err("invalid package dep file, line too long {}", .{line.len});
                return error.PkgDbCorrupt;
            }
            //std.log.info("line '{s}'", .{line});
            const parsed = ParsedDep.init(line) catch |err| {
                // TODO: include the package info in error message
                std.log.err("invalid line in package dep file '{s}': {s}", .{ line, @errorName(err) });
                return error.PkgDbCorrupt;
            };
            //std.log.info("    parsed {}", .{parsed});
            try deps.append(allocator, ParsedDepLine{
                .str = line,
                .parsed = parsed,
            });
        }
        return DepsFromDb{
            .file_content = file_content,
            .deps = deps.toOwnedSlice(allocator),
        };
    }
    pub fn deinit(self: DepsFromDb, allocator: Allocator) void {
        allocator.free(self.deps);
        allocator.free(self.file_content);
    }

    const Iterator = struct {
        deps_file: *const DepsFromDb,
        next_index: usize,
        pub fn next(self: *Iterator) ?Dep {
            if (self.next_index == self.deps_file.deps.len)
                return null;
            const dep = &self.deps_file.deps[self.next_index];
            self.next_index += 1;
            return Dep{
                .name = dep.str[0..dep.parsed.slash_off],
                .namespace = dep.str[dep.parsed.slash_off + 1 .. dep.parsed.space_off],
                .version = dep.parsed.version,
            };
        }
    };
    pub fn iterator(self: *const DepsFromDb) Iterator {
        return Iterator{ .deps_file = self, .next_index = 0 };
    }
};

pub fn resolveDep(self: PkgDb, dep: Dep) !void {
    // for now just put all the dependencies in the 'example-deps' subdirectory
    try self.build_dir.handle.makePath("example-deps");
    const dep_dir = try self.build_dir.handle.openDir("example-deps", .{});
    defer common.closeDir(dep_dir);

    const dep_dir_lock = try DirLock.init(dep_dir, ".lock");
    defer dep_dir_lock.deinit();

    // NOTE: for now we'll just download the dependency to dep/NAME, we won't worry about
    //       having to support multiple versions etc
    // TODO: maybe use a dep/status file that provides the current status
    //       of each dependency?

    if (try common.pathExists(dep_dir, dep.name)) {
        std.log.info("dependency '{s}' already exists", .{dep.name});
        std.log.warn("TODO: verify dependency version/etc", .{});
        return;
    }

    const installing_name = try std.mem.concat(self.allocator, u8, &.{dep.name, ".installing"});
    defer self.allocator.free(installing_name);

    try dep_dir.deleteTree(installing_name);
    try self.installDep(dep, dep_dir, installing_name);
    try dep_dir.rename(installing_name, dep.name);
}

fn installDep(self: PkgDb, dep: Dep, dep_dir: std.fs.Dir, installing_name: []const u8) !void {
    const pkg = try self.openPkg(dep.name, dep.namespace);
    defer pkg.close();

    const pkg_ver = try pkg.openVersion(dep.version);
    defer pkg_ver.close();

    const pkg_vars = try pkg_ver.getVars(self.allocator);
    defer pkg_vars.deinit(self.allocator);
    const hosts = try pkg.readHosts(self.allocator, pkg_vars);
    defer {
        for (hosts) |host| {
            host.deinit(self.allocator);
        }
        self.allocator.free(hosts);
    }
    if (hosts.len == 0) {
        std.log.err("package {s}/{s} is corrupt, it has no hosts", .{dep.name, dep.namespace});
        return error.PkgDbCorrupt;
    }

    var git_host_count: usize = 0;
    var git_sha_cached: union(enum) {
        unknown: void,
        no: void,
        yes: [40]u8,
    } = .unknown;
    for (hosts) |host| {
        switch (host) {
            .archive => |archive| {
                try fetchmod.installDepArchive(self.allocator, dep_dir, installing_name, archive.url);
                return;
            },
            .git => |git| {
                git_host_count += 1;
                switch (git_sha_cached) {
                    .unknown => if (try pkg_ver.readGitSha()) |sha| {
                        git_sha_cached = .{ .yes = sha };
                    } else {
                        git_sha_cached = .no;
                    },
                    .no, .yes => {},
                }
                const sha = switch (git_sha_cached) {
                    .unknown => unreachable,
                    .no => continue,
                    .yes => |sha| sha,
                };
                try installDepGit(self.allocator, dep_dir, installing_name, git.url, &sha, git.branch);
                return;
            },
        }
    }

    if (git_host_count == hosts.len) {
        switch (git_sha_cached) {
            .unknown => unreachable,
            .no => {
                std.log.err("package {} is corrupt, it only has git hosts but no gitsha", .{dep});
                return error.PkgDbCorrupt;
            },
            .yes => {},
        }
    }

    std.log.err("failed to install package {} from any of its {} hosts", .{dep, hosts.len});
    return error.DepInstallFailed;
}

const PathString = String(std.fs.MAX_PATH_BYTES);

fn installDepGit(
    allocator: std.mem.Allocator,
    dep_dir: std.fs.Dir,
    installing_name: []const u8,
    url: []const u8,
    sha: *const [40]u8,
    opt_branch: ?[]const u8,
) !void {
    const install_path = blk: {
        var install_dir_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const install_dir_path = try dep_dir.realpath(".", &install_dir_path_buf);
        break :blk try PathString.initFmt("{s}" ++ std.fs.path.sep_str ++ "{s}", .{install_dir_path, installing_name});
    };

    var url_with_proto = try std.mem.concat(allocator, u8, &[_][]const u8{ "https://", url });
    defer allocator.free(url_with_proto);

    {
        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();
        try args.append("git");
        try args.append("clone");
        try args.append(url_with_proto);
        try args.append(install_path.slice());
        if (opt_branch) |branch| {
            try args.append("-b");
            try args.append(branch);
        }
        var child = std.ChildProcess.init(args.items, allocator);
        try child.spawn();
        if (switch (try child.wait()) {
            .Exited => |code| code != 0,
            else => true,
        }) {
            std.log.err("git clone failed", .{});
            return error.GitCloneFailed;
        }
    }

    {
        var child = std.ChildProcess.init(&[_][]const u8{
            "git",
            "-C",
            install_path.slice(),
            "checkout",
            sha,
            "-b",
            "fordep",
            }, allocator);
        try child.spawn();
        if (switch (try child.wait()) {
            .Exited => |code| code != 0,
            else => true,
        }) {
            std.log.err("git checkout failed", .{});
            return error.GitCloneFailed;
        }
    }
}
