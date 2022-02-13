const builtin = @import("builtin");
const std = @import("std");

pub const BuildHostOs = enum {
    linux,
    macos,
    windows,
    freebsd,
};
pub const BuildHostArch = enum {
    x86_64,
    aarch64,
};

pub const maybe_os: ?BuildHostOs = switch (builtin.os.tag) {
    .linux => .linux,
    .macos => .macos,
    .windows => .windows,
    .freebsd => .freebsd,
    // TODO: what other OS's can zig-prebuilt run on? freestanding?
    //.freestanding
    else => null,
};
pub const maybe_arch: ?BuildHostArch = switch (builtin.cpu.arch) {
    .x86_64 => .x86_64,
    .aarch64 => .aarch64,
    else => null,
};
pub fn osArchComboIsSupported(os: BuildHostOs, arch: BuildHostArch) bool {
    return switch (os) {
        .linux => switch (arch) {
            .x86_64 => true,
            .aarch64 => true,
        },
        .macos => switch (arch) {
            .x86_64 => true,
            .aarch64 => true,
        },
        .windows => switch (arch) {
            .x86_64 => true,
            else => false,
        },
        .freebsd => switch (arch) {
            .x86_64 => true,
            else => false,
        },
    };
}
const supported = if (maybe_os) |os| (if (maybe_arch) |arch| osArchComboIsSupported(os, arch) else false) else false;

pub fn getStr() error{UnsupportedBuildHost}![]const u8 {
    const os = maybe_os orelse {
        std.log.err("unsupported OS '{s}'", .{builtin.os.tag});
        return error.UnsupportedBuildHost;
    };
    const arch = maybe_arch orelse {
        std.log.err("unsupported arch '{s}'", .{builtin.cpu.arch});
        return error.UnsupportedBuildHost;
    };
    const str = @tagName(os) ++ "-" ++ @tagName(arch);
    if (!supported) {
        std.log.err("unsupported OS-arch combo '{s}'", .{str});
        return error.UnsupportedBuildHost;
    }
    return str;
}
