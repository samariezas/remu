const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const c = c_translate.createModule();

    const exe = b.addExecutable(.{
        .name = "bemu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{.name = "c", .module = c },
            },
        }),
        .link_libc = true,
    });

    exe.linkSystemLibrary("elf");
    exe.linkSystemLibrary("c");

    b.installArtifact(exe);
}
