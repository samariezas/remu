const std = @import("std");
const cpu = @import("cpu.zig");
const tests = @import("tests.zig");
const linux = std.os.linux;

const Tword: type = u32;

fn writeNull(_: *const anyopaque, bytes: []const u8) anyerror!usize {
    return bytes.len;
}

const null_writer = std.io.AnyWriter {
    .context = undefined,
    .writeFn = writeNull,
};

pub fn runSingle(allocator: std.mem.Allocator, image: []const u8, working_directory: std.fs.Dir, writer: std.io.AnyWriter) !void {
    const entrypoint: Tword = 0x0800_0000;
    const memory_size: Tword = 1024*1024;
    var rvcpu = try cpu.RVCPU(Tword).init(allocator, entrypoint, memory_size, writer);
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

fn runMulti(allocator: std.mem.Allocator, start: []const u8, path: []const u8, writer: std.io.AnyWriter) !void {
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

            try runSingle(allocator, i, dest_dir, null_writer);
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

    if (failed_tests.items.len != 0) {
        try writer.print("------------------------------\nFailed tests:\n", .{});
        std.mem.sort([]const u8, failed_tests.items, {}, stringCmp);
        for (failed_tests.items) |i| {
            try writer.print("{s}\n", .{i});
        }
        try writer.print("------------------------------\n", .{});
    }
    try writer.print("Test summary: {}/{}\n", .{passed_tests, total_tests});

    if (passed_tests != total_tests) {
        return error.TestFailed;
    }
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

    var args = std.process.args();
    std.debug.assert(args.skip());
    const run_type = args.next() orelse @panic("Missing run type argument");
    const stdout_writer = std.io.getStdOut().writer().any();
    if (std.mem.eql(u8, run_type, "single")) {
        const image = args.next() orelse @panic("Missing image argument");
        std.debug.assert(!args.skip());
        try runSingle(allocator, image, std.fs.cwd(), stdout_writer);
    } else if (std.mem.eql(u8, run_type, "multi")) {
        const start = args.next() orelse @panic("Missing start of name argument");
        const path = args.next() orelse @panic("Missing path argument");
        std.debug.assert(!args.skip());
        try runMulti(allocator, start, path, stdout_writer);
    } else {
        @panic("Unknown run type");
    }
}
