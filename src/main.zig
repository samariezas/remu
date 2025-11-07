const std = @import("std");
const cpu = @import("cpu.zig");
const cpu_config = cpu.cpu_config;
const tests = @import("tests.zig");
const CpuOptions = cpu_config.CpuOptions;
const WordSize = cpu_config.WordSize;
const linux = std.os.linux;
const posix = std.posix;
const process = std.process;
const Allocator = std.mem.Allocator;

const base32 = CpuOptions.makeBase(WordSize.w32);
const base64 = CpuOptions.makeBase(WordSize.w64);

const priv64 = base64.withM().withPrivileged();

fn printBinary(data: []const u8, offset: u64) void {
    var i: usize = 0;
    while (i < data.len) {
        if (i % 0x10 == 0) {
            std.debug.print("\n{x:0>8} ", .{ offset + i });
        }
        std.debug.print("{x:0>2}", .{ data[i] });
        if (i % 4 == 3) { std.debug.print(" ", .{}); }
        i += 1;
    }
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            @panic("memory leak detected");
        }
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var args = std.process.args();
    std.debug.assert(args.skip());
    const run_type = args.next() orelse @panic("Missing run type argument");
    const raw_stdout_writer = std.io.getStdOut().writer().any();
    var buffered_writer = std.io.bufferedWriter(raw_stdout_writer);
    defer buffered_writer.flush() catch unreachable;
    const stdout_writer = buffered_writer.writer().any();
    if (std.mem.eql(u8, run_type, "remu")) {
        const image = args.next() orelse @panic("Missing image argument");
        std.debug.assert(!args.skip());
        const result = try tests.runRemuAndCollectSerial(priv64, allocator, image, stdout_writer);
        defer result.deinit(allocator);
        try stdout_writer.print("Signature: {s}\n", .{result.signature});
        try stdout_writer.print("Serial output:\n--------\n{s}--------\n",
            .{result.serial_output});
        try stdout_writer.print("Exit code: {any}\n", .{result.failure_code});
        if (result.failure_code) |exit_code| {
            std.debug.assert(exit_code != 0 and exit_code < 256);
            return @truncate(exit_code);
        }
    } else if (std.mem.eql(u8, run_type, "single")) {
        const image = args.next() orelse @panic("Missing image argument");
        std.debug.assert(!args.skip());
        const result = try tests.runSingle(priv64, allocator, image, tests.null_writer);
        defer result.deinit(allocator);
        switch (result) {
            .Discrepancy => |d| {
                try stdout_writer.writeAll("Test failed\n");
                try stdout_writer.print("REMU   exit code: {any}\n", .{d.remu_results.failure_code});
                try stdout_writer.print("Golden exit code: {any}\n", .{d.spike_results.process_result});
                try stdout_writer.print("REMU   signature: {s}\n",
                    .{std.fmt.fmtSliceHexLower(d.remu_results.signature)});
                try stdout_writer.print("Golden signature: {s}\n",
                    .{std.fmt.fmtSliceHexLower(d.spike_results.signature)});
                try stdout_writer.print("REMU   serial: {s}\n", .{d.remu_results.serial_output});
                try stdout_writer.print("Golden serial: {s}\n", .{d.spike_results.stdout});
                return 1;
            },
            .NoDiscrepancy => |d| {
                try stdout_writer.writeAll("No discrepancy\n");
                try stdout_writer.print("Signature: {s}\n",
                    .{std.fmt.fmtSliceHexLower(d.signature)});
                try stdout_writer.print("Serial output:\n--------\n{s}--------\n",
                    .{d.serial_output});
            },
        }
    // } else if (std.mem.eql(u8, run_type, "multi")) {
    //     const start = args.next() orelse @panic("Missing start of name argument");
    //     const path = args.next() orelse @panic("Missing path argument");
    //     std.debug.assert(!args.skip());
    //     const results = [_]TestSuiteResult {
    //         try runMulti(base64, allocator, arena_allocator, start, path, stdout_writer),
    //     };
    //     try printResults(&results, stdout_writer);
    // } else if (std.mem.eql(u8, run_type, "full")) {
    //     const path = args.next() orelse @panic("Missing path argument");
    //     std.debug.assert(!args.skip());
    //     try runMultipleSuites(allocator, arena_allocator, path, stdout_writer);
    } else if (std.mem.eql(u8, run_type, "spike")) {
        const image = args.next() orelse @panic("Missing image argument");
        std.debug.assert(!args.skip());
        const result = try tests.runSpike(allocator, .w64, image);
        defer result.deinit(allocator);
        try stdout_writer.print("Stdout:\n--------\n{s}--------\n",
            .{result.stdout});
        try stdout_writer.print("Stderr:\n--------\n{s}--------\n",
            .{result.stderr});
        try stdout_writer.print("Signature: {s}\n",
            .{std.fmt.fmtSliceHexLower(result.signature)});
        try stdout_writer.print("Exit code: {any}\n",
            .{result.process_result});
        switch (result.process_result) {
            .Abnormal => return 1,
            .Normal => |exitcode| {
                if (exitcode != 0) {
                    return exitcode;
                }
            },
        }
    } else {
        @panic("Unknown run type");
    }
    return 0;
}
