const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");
const Pkg = std.build.Pkg;

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const iguana_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/iguanaTLS",
        .branch = null,
        .sha = "a689192106291237573fb8a348cc5ff7ccd8110c",
    });
    const ziget_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/ziget",
        .branch = null,
        .sha = "116486f06e82aa7de9895e9145a22b384e029e5f",
    });

    {
        const exe = b.addExecutable("zigpkg", "zigpkg.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();

        exe.step.dependOn(&iguana_repo.step);
        exe.step.dependOn(&ziget_repo.step);
        const ziget_repo_path = ziget_repo.getPath(&exe.step);
        exe.addPackage(Pkg{
            .name = "ziget",
            .source = .{ .path = b.pathJoin(&.{ziget_repo_path, "ziget.zig"}) },
            .dependencies = &[_]Pkg {
                Pkg{
                    .name = "ssl",
                    .source = .{ .path = b.pathJoin(&.{ziget_repo_path, "iguana", "ssl.zig"}) },
                    .dependencies = &[_]Pkg {
                        .{ .name = "iguana", .source = .{ .path = b.pathJoin(&.{iguana_repo.getPath(&exe.step), "src", "main.zig"})} },
                    },
                },
            },
        });

        const run_cmd = exe.run();
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
}
