const std = @import("std");
const cpu = @import("cpu.zig");
const tests = @import("tests.zig");
const CpuOptions = cpu.CpuOptions;
const WordSize = cpu.WordSize;
const linux = std.os.linux;

const base32 = CpuOptions.makeBase(WordSize.w32);
const base64 = CpuOptions.makeBase(WordSize.w64);

fn writeNull(_: *const anyopaque, bytes: []const u8) anyerror!usize {
    return bytes.len;
}

const null_writer = std.io.AnyWriter {
    .context = undefined,
    .writeFn = writeNull,
};

pub fn runSingle(
    comptime opt: CpuOptions,
    allocator: std.mem.Allocator,
    image: []const u8,
    working_directory: std.fs.Dir,
    writer: std.io.AnyWriter
) !void {
    const cpu_type = cpu.RVCPU(opt);
    const entrypoint: cpu_type.Tword = 0x8000_0000;
    const memory_size: cpu_type.Tword = 1024*1024;
    var rvcpu = try cpu_type.init(allocator, entrypoint, memory_size, writer);
    defer rvcpu.deinit();

    const buffer = try allocator.alloc(u8, @intCast(memory_size));
    defer allocator.free(buffer);

    const file_read = try working_directory.readFile(image, buffer);
    
    if (file_read.len >= buffer.len) {
        @panic("Buffer too small");
    }

    try rvcpu.loadBinary(entrypoint, file_read);

    while (!rvcpu.isHalted()) {
        try rvcpu.tick();
    }

    if (rvcpu.getTestFailureCode()) |code| {
        std.debug.print("Failed test with code {}\n", .{code});
        return error.TestFailed;
    }

    if (try tests.loadSignature(allocator, image, working_directory)) |signature| {
        defer allocator.free(signature);
        const our_signature = try rvcpu.getSignature(allocator);
        defer allocator.free(our_signature);
        if (!std.mem.eql(u8, signature, our_signature)) {
            std.debug.print("Our    signature: {s}\n", .{std.fmt.fmtSliceHexLower(our_signature)});
            std.debug.print("Golden signature: {s}\n", .{std.fmt.fmtSliceHexLower(signature)});
            return error.SignatureMismatch;
        } else {
            std.debug.print("Signatures match\n", .{});
        }
    } else {
        std.debug.print("No signature needed\n", .{});
    }
}

fn stringCmp(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

const TestSuiteResult = struct {
    total_tests: usize,
    failed_tests: [][]const u8,
};

fn printResults(
    results: []const TestSuiteResult,
    writer: std.io.AnyWriter,
) !void {
    var failed_tests: usize = 0;
    var total_tests: usize = 0;
    for (results) |r| {
        total_tests += r.total_tests;
        failed_tests += r.failed_tests.len;
    }
    if (failed_tests != 0) {
        try writer.print("------------------------------\nFailed tests:\n", .{});
        for (results) |r| {
            std.mem.sort([]const u8, r.failed_tests, {}, stringCmp);
            for (r.failed_tests) |i| {
                try writer.print("{s}\n", .{i});
            }
        }
        try writer.print("------------------------------\n", .{});
    }
    try writer.print("Test summary: {}/{}\n", .{(total_tests - failed_tests), total_tests});

    if (failed_tests != 0) {
        return error.TestFailed;
    }
}

fn runMulti(
    comptime opt: CpuOptions,
    allocator: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
    start: []const u8,
    path: []const u8,
    writer: std.io.AnyWriter
) !TestSuiteResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const cwd = std.fs.cwd();
    const dest_dir = try cwd.openDir(path, .{ .iterate = true });
    const items = try tests.findAll(arena_allocator, start, dest_dir);

    var total_tests: usize = 0;
    var passed_tests: usize = 0;

    var failed_tests = std.ArrayList([]const u8).init(arena_allocator);
    for (items) |i| {
        try writer.print("Running {s}\n", .{i});
        const pid = linux.fork();
        if (pid == 0) {
            const rl = linux.rlimit {
                .cur = 1,
                .max = 1,
            };
            std.debug.assert(linux.setrlimit(linux.rlimit_resource.CPU, &rl) == 0);

            try runSingle(opt, allocator, i, dest_dir, null_writer);
            std.process.exit(0);
        } else {
            var status: u32 = 0;
            std.debug.assert(linux.waitpid(@intCast(pid), &status, 0) == pid);
            const success = linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0;
            try writer.print("t={s}, success={}\n", .{i, success});
            if (success) {
                passed_tests += 1;
            } else {
                try failed_tests.append(i);
            }
        }
        total_tests += 1;
    }
    var result = TestSuiteResult {
        .total_tests = total_tests,
        .failed_tests = try result_allocator.alloc([]const u8, failed_tests.items.len),
    };
    for (failed_tests.items, 0..) |t, i| {
        result.failed_tests[i] = try result_allocator.dupe(u8, t);
    }
    return result;
}

pub fn runMultipleSuites(
    allocator: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
    path: []const u8,
    writer: std.io.AnyWriter
) !void {
    const results = [_]TestSuiteResult {
        try runMulti(base32, allocator, result_allocator, "rv32ui-p", path, writer),
        try runMulti(base64, allocator, result_allocator, "rv64ui-p", path, writer),
        try runMulti(base32.withM(), allocator, result_allocator, "rv32um-p", path, writer),
        try runMulti(base64.withM(), allocator, result_allocator, "rv64um-p", path, writer),
    };
    try printResults(&results, writer);
}

pub fn main() !void {
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
    const arena_allocator = arena.allocator();

    var args = std.process.args();
    std.debug.assert(args.skip());
    const run_type = args.next() orelse @panic("Missing run type argument");
    const stdout_writer = std.io.getStdOut().writer().any();
    if (std.mem.eql(u8, run_type, "single")) {
        const image = args.next() orelse @panic("Missing image argument");
        std.debug.assert(!args.skip());
        try runSingle(base32.withM(), allocator, image, std.fs.cwd(), stdout_writer);
    } else if (std.mem.eql(u8, run_type, "multi")) {
        const start = args.next() orelse @panic("Missing start of name argument");
        const path = args.next() orelse @panic("Missing path argument");
        std.debug.assert(!args.skip());
        const results = [_]TestSuiteResult {
            try runMulti(base64, allocator, arena_allocator, start, path, stdout_writer),
        };
        try printResults(&results, stdout_writer);
    } else if (std.mem.eql(u8, run_type, "full")) {
        const path = args.next() orelse @panic("Missing path argument");
        std.debug.assert(!args.skip());
        try runMultipleSuites(allocator, arena_allocator, path, stdout_writer);
    } else {
        @panic("Unknown run type");
    }
}
