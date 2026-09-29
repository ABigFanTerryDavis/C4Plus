const std = @import("std");

fn addTool(
    b: *std.Build,
    name: []const u8,
    version: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const opts = b.addOptions();
    opts.addOption([]const u8, "exe_name", name);
    opts.addOption([]const u8, "exe_version", version);
    const emit_mod = b.createModule(.{
        .root_source_file = b.path("src/emit.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui.zig"),
        .target = target,
        .optimize = optimize,
    });
    const proc_mod = b.createModule(.{
        .root_source_file = b.path("src/proc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = opts.createModule() },
                .{ .name = "emit", .module = emit_mod },
                .{ .name = "gui", .module = gui_mod },
                .{ .name = "proc", .module = proc_mod },
            },
        }),
    });
    b.installArtifact(exe);
    if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("user32", .{});
        exe.root_module.linkSystemLibrary("gdi32", .{});
        exe.root_module.linkSystemLibrary("comdlg32", .{});
    }
    return exe;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = "0.3.9";

    const c4c = addTool(b, "c4c", version, target, optimize);
    _ = addTool(b, "c4pp", version, target, optimize);

    const run_cmd = b.addRunArtifact(c4c);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run c4c");
    run_step.dependOn(&run_cmd.step);
}
