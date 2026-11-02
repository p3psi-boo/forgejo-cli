const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = "0.8.0-dev";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "name", "forgejo-cli");
    options.addOption([]const u8, "repository", "https://codeberg.org/forgejo-contrib/forgejo-cli/");
    options.addOption([]const u8, "build_type", b.option([]const u8, "build-type", "Build type label") orelse "from source");

    const args_dep = b.dependency("args", .{
        .target = target,
        .optimize = optimize,
    });
    const known_folders_dep = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    });
    const fluent_dep = b.dependency("fluent", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "fj",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const ftl = b.createModule(.{
        .root_source_file = b.path("localization/embed.zig"),
    });

    exe.root_module.addOptions("build_options", options);
    exe.root_module.addImport("args", args_dep.module("args"));
    exe.root_module.addImport("known-folders", known_folders_dep.module("known-folders"));
    exe.root_module.addImport("fluent", fluent_dep.module("fluent"));
    exe.root_module.addImport("ftl", ftl);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run fj");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
