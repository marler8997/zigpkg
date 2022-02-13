const std = @import("std");
const PkgVars = @import("PkgVars.zig");

pub const Host = union(enum) {
    archive: Archive,
    git: Git,

    pub const Archive = struct {
        url: []const u8,
    };
    pub const Git = struct {
        url: []const u8,
        branch: ?[]const u8,
    };

    pub fn deinit(self: Host, allocator: std.mem.Allocator) void {
        switch (self) {
            .archive => |archive| {
                allocator.free(archive.url);
            },
            .git => |git| {
                allocator.free(git.url);
                if (git.branch) |b|
                    allocator.free(b);
            },
        }
    }
};


pub const ParseErrorHandler = struct {
    on_error: fn (self: *ParseErrorHandler, line: u32, msg: []const u8) void,
    pub fn onError(self: *ParseErrorHandler, line: u32, comptime fmt: []const u8, args: anytype) error{ReportedParseError} {
        var buf: [400]u8 = undefined;
        if (std.fmt.bufPrint(&buf, fmt, args)) |msg| {
            self.on_error(self, line, msg);
        } else |err| switch (err) {
            error.NoSpaceLeft => {
                self.on_error(self, line, "formatted error message too long, fmt string is: " ++ fmt);
            },
        }
        return error.ReportedParseError;
    }
};
pub fn parse(allocator: std.mem.Allocator, text: []const u8, pkg_vars: PkgVars, error_handler: *ParseErrorHandler) ![]Host {
    var hosts = std.ArrayListUnmanaged(Host){ };
    errdefer {
        for (hosts.items) |host| {
            host.deinit(allocator);
        }
        hosts.deinit(allocator);
    }

    var line_it = std.mem.split(u8, text, "\n");
    var line_number: u32 = 0;
    while (line_it.next()) |line| {
        line_number += 1;
        var token_it = std.mem.tokenize(u8, line, " ");
        const host_type_str = token_it.next() orelse continue;
        if (std.mem.eql(u8, host_type_str, "archive")) {
            var url_raw = token_it.next() orelse
                return error_handler.onError(line_number, "missing URL for archive host", .{});
            const url = try processString(allocator, url_raw, pkg_vars, line_number, error_handler);
            errdefer allocator.free(url);

            if (token_it.next()) |_|
                return error_handler.onError(line_number, "too many values for 'archive' host", .{});

            try hosts.append(allocator, Host{ .archive = .{
                .url = url,
            }});
        } else if (std.mem.eql(u8, host_type_str, "git")) {
            var url_raw = token_it.next() orelse
                return error_handler.onError(line_number, "missing URL for git host", .{});
            const url = try processString(allocator, url_raw, pkg_vars, line_number, error_handler);
            errdefer allocator.free(url);

            var branch: ?[]const u8 = null;
            while (true) {
                var option_str = token_it.next() orelse break;
                std.debug.panic("todo: parse option '{s}'", .{option_str});
            }

            try hosts.append(allocator, Host{ .git = .{
                .url = url,
                .branch = branch,
            }});
        } else {
            return error_handler.onError(line_number, "unknown host type '{s}'", .{host_type_str});
        }
    }
    return hosts.toOwnedSlice(allocator);
}

fn processString(
    allocator: std.mem.Allocator,
    str: []const u8,
    pkg_vars: PkgVars,
    line_number: u32,
    error_handler: *ParseErrorHandler,
) error{OutOfMemory,ReportedParseError}![]u8 {
    var result = std.ArrayListUnmanaged(u8) { };

    var save: usize = 0;
    while (true) {
        const dollar_index = std.mem.indexOfScalarPos(u8, str, save, '$') orelse break;
        try result.appendSlice(allocator, str[save..dollar_index]);
        if (dollar_index + 1 >= str.len)
            return error_handler.onError(line_number, "value cannot end with '$' character", .{});
        switch (str[dollar_index + 1]) {
            '$' => {
                try result.append(allocator, '$');
                save = dollar_index + 2;
            },
            '{' => {
                const end = std.mem.indexOfScalarPos(u8, str, dollar_index + 2, '}') orelse
                    return error_handler.onError(line_number, "missing closing }}", .{});
                const name = str[dollar_index+2 .. end];
                const resolved = pkg_vars.resolve(name) catch |err| switch (err) {
                    error.UndefinedVariable =>
                        return error_handler.onError(line_number, "undefined variable ${{{s}}}", .{name}),
                    error.NoCustomVersion =>
                        return error_handler.onError(line_number, "cannot resolve ${{CUSTOM_VERSION}}, this package/version combination has no customversion", .{}),
                };
                try result.appendSlice(allocator, resolved);
                save = end + 1;
            },
            else => return error_handler.onError(
                line_number,
                "unexpected sequence: ${}",
                .{std.zig.fmtEscapes(str[dollar_index+1..dollar_index+2])}),
        }
    }

    try result.appendSlice(allocator, str[save..]);
    return result.toOwnedSlice(allocator);
}
