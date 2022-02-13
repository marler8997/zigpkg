const PkgVars = @This();

const builtin = @import("builtin");
const std = @import("std");

customversion: ?[]const u8,

pub fn deinit(self: PkgVars, allocator: std.mem.Allocator) void {
    if (self.customversion) |v| allocator.free(v);
}

pub fn resolve(self: PkgVars, name: []const u8) error{UndefinedVariable,NoCustomVersion}![]const u8 {
    if (std.mem.eql(u8, "BUILD_HOST_ZIG_BINARY_PLATFORM", name))
        return build_host_os ++ "-" ++ build_host_arch;
    if (std.mem.eql(u8, "BUILD_HOST_ZIG_ARCHIVE_EXT", name))
        return build_host_archive_ext;
    if (std.mem.eql(u8, "CUSTOM_VERSION", name))
        return if (self.customversion) |v| v else error.NoCustomVersion;
    return error.UndefinedVariable;
}

const build_host_arch = switch(builtin.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    .riscv64 => "riscv64",
    else => @compileError("Unsupported CPU Architecture"),
};
const build_host_os = switch(builtin.os.tag) {
    .windows => "windows",
    .linux => "linux",
    .macos => "macos",
    else => @compileError("Unsupported OS"),
};
const build_host_archive_ext = switch (builtin.os.tag) {
    .windows => ".zip",
    else => ".tar.xz",
};
