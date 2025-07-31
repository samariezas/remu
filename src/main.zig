const std = @import("std");
const cpu = @import("cpu.zig");
const tests = @import("tests.zig");
const linux = std.os.linux;

const Tword: type = u32;

pub fn runSingle(allocator: std.mem.Allocator, image: []const u8) !void {
    const entrypoint: Tword = 0x0800_0000;
    const memory_size: Tword = 1024*1024;
    var rvcpu = try cpu.RVCPU(Tword).init(allocator, entrypoint, memory_size);
    defer rvcpu.deinit();

    const buffer = try allocator.alloc(u8, @intCast(memory_size));
    defer allocator.free(buffer);

    const cwd = std.fs.cwd();
    const file_read = try cwd.readFile(image, buffer);
    
    if (file_read.len >= buffer.len) {
        @panic("Buffer too small");
    }

    try rvcpu.loadBinary(entrypoint, file_read);

    while (!rvcpu.isHalted()) {
        try rvcpu.tick();
    }

    // TODO: refactor out cwd
    if (try tests.loadSignature(allocator, image, cwd)) |signature| {
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

fn runMulti(allocator: std.mem.Allocator, start: []const u8, path: []const u8) !void {
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
        const pid = linux.fork();
        if (pid == 0) {
            const rl = linux.rlimit {
                .cur = 1,
                .max = 1,
            };
            std.debug.assert(linux.setrlimit(linux.rlimit_resource.CPU, &rl) == 0);

            const null_file = try std.fs.openFileAbsolute("/dev/null", std.fs.File.OpenFlags { .mode = .write_only });
            
            const entrypoint: Tword = 0x0800_0000;
            const memory_size: Tword = 1024*1024;
            var rvcpu = try cpu.RVCPU(Tword).init(allocator, entrypoint, memory_size);
            defer rvcpu.deinit();

            const buffer = try allocator.alloc(u8, @intCast(memory_size));
            defer allocator.free(buffer);

            const file_read = try dest_dir.readFile(i, buffer);
            
            if (file_read.len >= buffer.len) {
                @panic("Buffer too small");
            }

            try rvcpu.loadBinary(entrypoint, file_read);

            try std.posix.dup2(null_file.handle, std.io.getStdOut().handle);
            try std.posix.dup2(null_file.handle, std.io.getStdErr().handle);
            while (!rvcpu.isHalted()) {
                try rvcpu.tick();
            }

            if (try tests.loadSignature(allocator, i, dest_dir)) |signature| {
                defer allocator.free(signature);
                // defer signature.deinit();
            }
        } else {
            var status: u32 = 0;
            std.debug.assert(linux.waitpid(@intCast(pid), &status, 0) == pid);
            const exit_status = linux.W.EXITSTATUS(status);
            std.debug.print("t={s}, stat={}\n", .{i, exit_status});
            if (exit_status == 0) {
                passed_tests += 1;
            } else {
                try failed_tests.append(i);
            }
        }
        total_tests += 1;
    }

    if (failed_tests.items.len != 0) {
        std.debug.print("------------------------------\nFailed tests:\n", .{});
        std.mem.sort([]const u8, failed_tests.items, {}, stringCmp);
        for (failed_tests.items) |i| {
            std.debug.print("{s}\n", .{i});
        }
        std.debug.print("------------------------------\n", .{});
    }
    std.debug.print("Test summary: {}/{}\n", .{passed_tests, total_tests});

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
    if (std.mem.eql(u8, run_type, "single")) {
        const image = args.next() orelse @panic("Missing image argument");
        std.debug.assert(!args.skip());
        try runSingle(allocator, image);
    } else if (std.mem.eql(u8, run_type, "multi")) {
        const start = args.next() orelse @panic("Missing start of name argument");
        const path = args.next() orelse @panic("Missing path argument");
        std.debug.assert(!args.skip());
        try runMulti(allocator, start, path);
    } else {
        @panic("Unknown run type");
    }
}
