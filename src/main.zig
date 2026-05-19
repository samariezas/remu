const std = @import("std");
const cpu = @import("cpu.zig");
const cpu_config = cpu.cpu_config;
const tests = @import("tests.zig");
const File = std.fs.File;
const CpuOptions = cpu_config.CpuOptions;
const WordSize = cpu_config.WordSize;
const linux = std.os.linux;
const posix = std.posix;
const process = std.process;
const Allocator = std.mem.Allocator;

pub fn enableRawMode(file: File) !std.posix.termios {
    const orig = try std.posix.tcgetattr(file.handle);
    var raw = orig;

    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;

    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;

    raw.cflag.CSIZE = .CS8;

    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try std.posix.tcsetattr(file.handle, .NOW, raw);
    return orig;
}

pub fn restore(file: File, orig: std.posix.termios) void {
    std.posix.tcsetattr(file.handle, .NOW, orig) catch @panic("Failed resetting terminal");
}

pub fn printUsage(writer: anytype, prog_name: []const u8) void {
    writer.print("Usage: {s} <OpenSBI fw_dynamic.bin path> <DTB path> <kernel path> <initrd path> [GDB socket path]\n",
        .{prog_name}) catch @panic("std i/o failure");
}

pub fn printMissingArg(writer: anytype, prog_name: []const u8, arg_name: []const u8) void {
    writer.print("Error: missing {s} argument\n", .{arg_name})
        catch @panic("std i/o failure");
    printUsage(writer, prog_name);
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const stderr_writer = std.io.getStdErr().writer();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            @panic("memory leak detected");
        }
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var args = std.process.args();
    const prog_name = args.next() orelse @panic("Missing program name");
    const opensbi_path = args.next() orelse
        { printMissingArg(stderr_writer, prog_name, "OpenSBI"); return 1; };
    const dtb_path = args.next() orelse
        { printMissingArg(stderr_writer, prog_name, "DTB"); return 1; };
    const kernel_path = args.next() orelse
        { printMissingArg(stderr_writer, prog_name, "kernel"); return 1; };
    const initrd_path = args.next() orelse
        { printMissingArg(stderr_writer, prog_name, "initrd"); return 1; };
    const gdb_socket = args.next();
    if (args.skip()) {
        stderr_writer.print("Too many arguments.\n", .{})
            catch @panic("std i/o failure");
        printUsage(stderr_writer, prog_name);
        return 1;
    }
    const stdin = std.io.getStdIn();
    const old_terminal_settings = try enableRawMode(stdin);
    defer restore(stdin, old_terminal_settings);
    try tests.runRemuBinary(
        tests.full64,
        allocator,
        opensbi_path,
        dtb_path,
        kernel_path,
        initrd_path,
        null,
        stdin,
        std.io.getStdOut(),
        gdb_socket
    );
    return 0;
}
