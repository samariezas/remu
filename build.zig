const std = @import("std");
const ArrayList = std.ArrayList;
const Build = std.Build;
const Module = Build.Module;
const Compile = Build.Step.Compile;
const ResolvedTarget = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;

const CacheType = enum {
    None,
    HashMap,
    Array,
};

fn getSystemIncludes(b: *Build) ![][]const u8 {
    var retval = ArrayList([]const u8).init(b.allocator);
    const nix_cflags: []const u8 = std.process.getEnvVarOwned(b.allocator, "NIX_CFLAGS_COMPILE") catch "";
    defer b.allocator.free(nix_cflags);
    const nix_cflags_trimmed: []const u8 = std.mem.trim(u8, nix_cflags, " \n\t");
    var it = std.mem.tokenizeScalar(u8, nix_cflags_trimmed, ' ');
    var is_isystem: bool = false;
    while (it.next()) |arg| {
        if (is_isystem) {
            is_isystem = false;
            try retval.append(try b.allocator.dupe(u8, arg));
        } else {
            if (std.mem.eql(u8, arg, "-isystem")) {
                is_isystem = true;
            }
        }
    }
    return retval.toOwnedSlice();
}

fn buildC(b: *Build, target: ResolvedTarget, optimize: OptimizeMode, system_includes: [][]const u8) *Module {
    const c_translate = b.addTranslateC(.{
        .link_libc = false,
        .target = target,
        .optimize = optimize,
        .root_source_file = b.addWriteFiles().add("libelf_binding.h",
            \\#include <string.h>
            \\#include <libelf.h>
        ),
    });
    for (system_includes) |include| {
        c_translate.addSystemIncludePath(.{ .cwd_relative = include });
    }
    return c_translate.createModule();
}

fn buildLibfdt(b: *Build, target: ResolvedTarget, use_llvm: bool, system_includes: [][]const u8) struct { *Compile, *Module } {
    const optimize = OptimizeMode.ReleaseFast;
    const root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "libfdt",
        .root_module = root_module,
        .use_llvm = use_llvm,
    });
    lib.addCSourceFiles(.{
        .files = &[_][]const u8 {
            "dtc/libfdt/fdt.c",
            "dtc/libfdt/fdt_ro.c",
            "dtc/libfdt/fdt_wip.c",
        },
        .language = .c,
    });
    const c_translate = b.addTranslateC(.{
        .link_libc = false,
        .target = target,
        .optimize = optimize,
        .root_source_file = b.addWriteFiles().add("libfdt_binding.h",
            \\#include <libfdt.h>
        ),
    });
    for (system_includes) |include| {
        lib.addSystemIncludePath(.{ .cwd_relative = include });
        c_translate.addSystemIncludePath(.{ .cwd_relative = include });
    }
    return .{ lib, c_translate.createModule() };
}

fn buildRemuStep(b: *Build, root_module: *Module, libfdt: *Compile, use_llvm: bool, cache_strategy: CacheType, cache_size: usize) *Compile {
    const exe = b.addExecutable(.{
        .name = "remu",
        .root_module = root_module,
        .link_libc = true,
        .use_llvm = use_llvm,
    });
    const options = b.addOptions();
    options.addOption(CacheType, "cache_strategy", cache_strategy);
    options.addOption(usize, "cache_size", cache_size);
    exe.root_module.addOptions("config", options);
    exe.linkSystemLibrary("elf");
    exe.linkSystemLibrary("c");
    exe.linkLibrary(libfdt);
    return exe;
}

pub fn build(b: *Build) !void {
    const system_includes = try getSystemIncludes(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "use_llvm", "Force use llvm or not") orelse true;

    const c = buildC(b, target, optimize, system_includes);
    const libfdt, const c_libfdt = buildLibfdt(b, target, use_llvm, system_includes);
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{.name = "c", .module = c },
            .{.name = "c_libfdt", .module = c_libfdt },
        },
    });

    const cache_strategy = b.option(CacheType, "cache_strategy", "Instruction cache strategy") orelse CacheType.Array;
    const cache_size = b.option(usize, "cache_size", "Instruction cache size") orelse 1048573;

    const root_tests_module = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = buildRemuStep(b, root_module, libfdt, use_llvm, cache_strategy, cache_size);
    b.installArtifact(exe);

    const check_step = b.step("check", "Check if remu compiles");
    const exe_check = buildRemuStep(b, root_module, libfdt, false, cache_strategy, cache_size);
    const tests = b.addTest(.{
        .root_module = root_tests_module,
        .use_llvm = false
    });

    check_step.dependOn(&exe_check.step);
    check_step.dependOn(&tests.step);

    const test_step = b.step("test", "Run tests");
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
