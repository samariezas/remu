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

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const raw_stdout_writer = std.io.getStdOut().writer().any();
    var buffered_writer = std.io.bufferedWriter(raw_stdout_writer);
    // const stdout_writer = buffered_writer.writer().any();
    defer {
        buffered_writer.flush() catch @panic("Cannot flush stdout");
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            @panic("memory leak detected");
        }
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // const arena_allocator = arena.allocator();
    var args = std.process.args();
    std.debug.assert(args.skip());
    const run_type = args.next() orelse @panic("Missing run type argument");
    // if (std.mem.eql(u8, run_type, "remu")) {
    //     const image = args.next() orelse @panic("Missing image argument");
    //     std.debug.assert(!args.skip());
    //     const result = try tests.runRemuAndCollectSerial(tests.full64, allocator, image, null, "./gdb.sock");
    //     defer result.deinit(allocator);
    //     try stdout_writer.print("Signature: {s}\n",
    //         .{std.fmt.fmtSliceHexLower(result.signature)});
    //     try stdout_writer.print("Serial output:\n--------\n{s}--------\n",
    //         .{result.serial_output});
    //     try stdout_writer.print("Exit code: {any}\n", .{result.failure_code});
    //     if (result.failure_code) |_| {
    //         return 1;
    //     }
    // } else if (std.mem.eql(u8, run_type, "binary")) {
    if (std.mem.eql(u8, run_type, "binary")) {
        const opensbi_path = args.next() orelse @panic("Missing opensbi argument");
        const dtb_path = args.next() orelse @panic("Missing dtb argument");
        const kernel_path = args.next() orelse @panic("Missing kernel argument");
        const initrd_path = args.next() orelse @panic("Missing initrd argument");
        const gdb_socket = args.next();
        std.debug.assert(!args.skip());
        const result = try tests.runRemuBinary(
            tests.full64,
            allocator,
            opensbi_path,
            dtb_path,
            kernel_path,
            initrd_path,
            null,
            std.io.getStdIn(),
            std.io.getStdOut(),
            gdb_socket
        );
        defer result.deinit(allocator);
    // } else if (std.mem.eql(u8, run_type, "single")) {
    //     const image = args.next() orelse @panic("Missing image argument");
    //     std.debug.assert(!args.skip());
    //     const result = try tests.runSingle(tests.full64, allocator, image, null);
    //     defer result.deinit(allocator);
    //     switch (result) {
    //         .Discrepancy => |d| {
    //             try stdout_writer.writeAll("Discrepancy detected!\n");
    //             try stdout_writer.print("REMU   exit code: {any}\n", .{d.remu_results.failure_code});
    //             try stdout_writer.print("Golden exit code: {any}\n", .{d.spike_results.process_result});
    //             try stdout_writer.print("REMU   signature: {s}\n",
    //                 .{std.fmt.fmtSliceHexLower(d.remu_results.signature)});
    //             try stdout_writer.print("Golden signature: {s}\n",
    //                 .{std.fmt.fmtSliceHexLower(d.spike_results.signature)});
    //             try stdout_writer.print("REMU   serial:\n--------\n{s}--------\n", .{d.remu_results.serial_output});
    //             try stdout_writer.print("Golden serial:\n--------\n{s}--------\n", .{d.spike_results.stdout});
    //             try stdout_writer.writeAll("Diff:\n");
    //             try buffered_writer.flush();
    //             try tests.printDiff(allocator, d.remu_results.serial_output, d.spike_results.stdout);
    //             return 1;
    //         },
    //         .NoDiscrepancy => |d| {
    //             try stdout_writer.writeAll("No discrepancy\n");
    //             try stdout_writer.print("Signature: {s}\n",
    //                 .{std.fmt.fmtSliceHexLower(d.signature)});
    //             try stdout_writer.print("Serial output:\n--------\n{s}--------\n",
    //                 .{d.serial_output});
    //         },
    //     }
    // } else if (std.mem.eql(u8, run_type, "multi")) {
    //     const start = args.next() orelse @panic("Missing start of name argument");
    //     const path = args.next() orelse @panic("Missing path argument");
    //     std.debug.assert(!args.skip());
    //     const results = [_]tests.TestSuiteResult {
    //         try tests.runMulti(tests.full64, allocator, arena_allocator, start, path, raw_stdout_writer),
    //     };
    //     try tests.printResults(&results, raw_stdout_writer);
    // } else if (std.mem.eql(u8, run_type, "full")) {
    //     std.debug.assert(false);
    //     // const path = args.next() orelse @panic("Missing path argument");
    //     // std.debug.assert(!args.skip());
    //     // try tests.runMultipleSuites(allocator, arena_allocator, path, raw_stdout_writer);
    // } else if (std.mem.eql(u8, run_type, "spike")) {
    //     const image = args.next() orelse @panic("Missing image argument");
    //     std.debug.assert(!args.skip());
    //     const result = try tests.runSpike(allocator, .w64, image);
    //     defer result.deinit(allocator);
    //     try stdout_writer.print("Stdout:\n--------\n{s}--------\n",
    //         .{result.stdout});
    //     try stdout_writer.print("Stderr:\n--------\n{s}--------\n",
    //         .{result.stderr});
    //     try stdout_writer.print("Signature: {s}\n",
    //         .{std.fmt.fmtSliceHexLower(result.signature)});
    //     try stdout_writer.print("Exit code: {any}\n",
    //         .{result.process_result});
    //     switch (result.process_result) {
    //         .Abnormal => return 1,
    //         .Normal => |exitcode| {
    //             if (exitcode != 0) {
    //                 return exitcode;
    //             }
    //         },
    //     }
    } else {
        @panic("Unknown run type");
    }
    return 0;
}
