const std = @import("std");

fn buildC(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const c_translate = b.addTranslateC(.{
        .link_libc = false,
        .target = target,
        .optimize = optimize,
        .root_source_file = b.addWriteFiles().add( "libelf_binding.h",
            \\#include <string.h>
            \\#include <libelf.h>
        ),
    });
    const nix_cflags: []const u8 = std.process.getEnvVarOwned(b.allocator, "NIX_CFLAGS_COMPILE") catch "";
    const nix_cflags_trimmed: []const u8 = std.mem.trim(u8, nix_cflags, " \n\t");
    var it = std.mem.tokenizeScalar(u8, nix_cflags_trimmed, ' ');
    var is_isystem: bool = false;
    while (it.next()) |arg| {
        if (is_isystem) {
            is_isystem = false;
            c_translate.addSystemIncludePath(.{ .cwd_relative = arg });
        } else {
            if (std.mem.eql(u8, arg, "-isystem")) {
                is_isystem = true;
            }
        }
    }
    return c_translate.createModule();
}

fn buildRemuStep(b: *std.Build, root_module: *std.Build.Module, use_llvm: bool) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "bemu",
        .root_module = root_module,
        .link_libc = true,
        .use_llvm = use_llvm,
    });
    exe.linkSystemLibrary("elf");
    exe.linkSystemLibrary("c");
    return exe;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "use_llvm", "Force use llvm or not") orelse true;

    const c = buildC(b, target, optimize);
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{.name = "c", .module = c },
        },
    });

    const exe = buildRemuStep(b, root_module, use_llvm);
    b.installArtifact(exe);

    const check_step = b.step("check", "Check if remu compiles");
    const exe_check = buildRemuStep(b, root_module, false);
    check_step.dependOn(&exe_check.step);
}
