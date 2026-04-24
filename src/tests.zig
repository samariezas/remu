const std = @import("std");
const cpu = @import("cpu.zig");
const bus = @import("bus.zig");
const libelf = @import("libelf.zig");
const cpu_config = cpu.cpu_config;
const fs = std.fs;
const mem = std.mem;
const posix = std.posix;
const linux = std.os.linux;
const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;
const WordSize = cpu_config.WordSize;
const CpuOptions = cpu_config.CpuOptions;

pub const base32 = CpuOptions.makeBase(WordSize.w32);
pub const base64 = CpuOptions.makeBase(WordSize.w64);

pub const priv64 = base64.withPrivileged();

pub const full64 = base64.withM().withA().withPrivileged();

pub fn findAll(allocator: mem.Allocator, start: []const u8, path: fs.Dir) ![][]const u8 {
    var walker = try path.walk(allocator);
    defer walker.deinit();
    var list = std.ArrayList([]const u8).init(allocator);
    while (try walker.next()) |entry| {
        if (std.mem.startsWith(u8, entry.basename, start) and !std.mem.containsAtLeastScalar(u8, entry.basename, 1, '.')) {
            try list.append(try allocator.dupe(u8, entry.path));
        }
    }
    return try list.toOwnedSlice();
}

pub const Signature = struct {
    signature: []u8,
    inner: []u8,
    allocator: mem.Allocator,

    pub fn deinit(self: *const Signature) void {
        self.allocator.free(self.inner);
    }
};

fn preprocessSignature(allocator: Allocator, raw_signature: []const u8) ![]u8 {
    var lines = ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    var it = std.mem.splitScalar(u8, raw_signature, '\n');
    while (it.next()) |line| {
        try lines.append(line);
    }
    std.mem.reverse([]const u8, lines.items);
    var result = ArrayList(u8).init(allocator);
    var previous_byte: ?u8 = null;
    for (lines.items) |line| {
        for (0..line.len) |i| {
            var c = line[i];
            if (c >= '0' and c <= '9') {
                c -= '0';
            } else if (c >= 'a' and c <= 'f') {
                c -= 'a' - 10;
            } else {
                continue;
            }
            if (previous_byte) |prev| {
                try result.append((prev << 4) | c);
                previous_byte = null;
            } else {
                previous_byte = c;
            }
        }
    }
    std.debug.assert(previous_byte == null);
    std.mem.reverse(u8, result.items);
    return try result.toOwnedSlice();
}

pub const ProcessRunResult = union(enum) {
    Normal: u8,
    Abnormal: void,
};

pub const SpikeRunResults = struct {
    process_result: ProcessRunResult,
    stdout: []u8,
    stderr: []u8,
    signature: []u8,

    pub fn deinit(self: *const SpikeRunResults, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        allocator.free(self.signature);
    }

    pub fn isFailure(self: *const SpikeRunResults) bool {
        if (self.stderr.len != 0) return true;
        switch (self.process_result) {
            .Abnormal => return true,
            .Normal => |d| {
                if (d != 0) return true;
            }
        }
        return false;
    }
};

fn registerFd(epoll_fd: i32, fd: i32, registered_fds: *usize) !void {
    var ev: linux.epoll_event = undefined;
    ev.events = linux.EPOLL.IN;
    ev.data.fd = fd;
    if (linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev) != 0) {
        return error.EPOLLCTL;
    }
    registered_fds.* += 1;
}

// TODO: check for failed spawn
pub fn runSpike(
    allocator: Allocator,
    word_size: WordSize,
    image: []const u8
) !SpikeRunResults {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const isa: [:0]const u8 = switch (word_size) {
        .w32 => "--isa=rv32gc_ziccid_zfh_zicboz_svnapot_zicntr_zba_zbb_zbc_zbs",
        .w64 => "--isa=rv64gch_ziccid_zfh_zicboz_svnapot_zicntr_zba_zbb_zbc_zbs",
    };
    const epoll_fd: posix.fd_t = @intCast(linux.epoll_create());
    const stdout_read_fd, const stdout_write_fd = try posix.pipe();
    const stderr_read_fd, const stderr_write_fd = try posix.pipe();
    const signature_read_fd, const signature_write_fd = try posix.pipe();
    defer {
        posix.close(stdout_read_fd);
        posix.close(stderr_read_fd);
        posix.close(signature_read_fd);
        posix.close(epoll_fd);
    }
    const signature = try std.fmt.allocPrintZ(
        arena_allocator,
        "+signature=/proc/self/fd/{}",
        .{signature_write_fd}
    );
    const environment = try std.process.createEnvironFromExisting(
        arena_allocator,
        std.c.environ,
        .{},
    );
    const child_arguments = [_:null]?[*:0]const u8 {
        "spike",
        isa,
        "--misaligned",
        signature,
        try arena_allocator.dupeZ(u8, image),
    };
    const child_pid = try std.posix.fork();
    if (child_pid == 0) {
        posix.close(stdout_read_fd);
        posix.close(stderr_read_fd);
        posix.close(signature_read_fd);
        try posix.dup2(stdout_write_fd, std.c.STDOUT_FILENO);
        try posix.dup2(stderr_write_fd, std.c.STDERR_FILENO);
        std.posix.execvpeZ("spike", &child_arguments, environment) catch unreachable;
        @panic("exec failed");
    }
    posix.close(stdout_write_fd);
    posix.close(stderr_write_fd);
    posix.close(signature_write_fd);
    var registered_fds: usize = 0;
    var epoll_events: [3]linux.epoll_event = undefined;
    try registerFd(epoll_fd, stdout_read_fd, &registered_fds);
    try registerFd(epoll_fd, stderr_read_fd, &registered_fds);
    try registerFd(epoll_fd, signature_read_fd, &registered_fds);
    var collected_stdout = std.ArrayList(u8).init(arena_allocator);
    var collected_stderr = std.ArrayList(u8).init(arena_allocator);
    var collected_signature = std.ArrayList(u8).init(arena_allocator);
    defer {
        collected_stdout.deinit();
        collected_stderr.deinit();
        collected_signature.deinit();
    }
    while (registered_fds > 0) {
        const nfds = linux.epoll_wait(epoll_fd, &epoll_events, epoll_events.len, -1);
        if (nfds == std.math.maxInt(@TypeOf(nfds))) {
            @panic("epoll error");
        }
        for (epoll_events[0..nfds]) |event| {
            if ((event.events & linux.EPOLL.IN) != 0) {
                var buffer: [4096]u8 = undefined;
                const bytes_read = try posix.read(event.data.fd, &buffer);
                if (event.data.fd == stdout_read_fd) {
                    try collected_stdout.appendSlice(buffer[0..bytes_read]);
                } else if (event.data.fd == stderr_read_fd) {
                    try collected_stderr.appendSlice(buffer[0..bytes_read]);
                } else if (event.data.fd == signature_read_fd) {
                    try collected_signature.appendSlice(buffer[0..bytes_read]);
                } else {
                    @panic("Unknown file descriptor");
                }
            } else if ((event.events & linux.EPOLL.HUP) != 0) {
                const errno = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_DEL, event.data.fd, null);
                if (errno == std.math.maxInt(@TypeOf(errno))) {
                    @panic("EPOLL_CTL_DEL failed");
                }
                registered_fds -= 1;
            } else {
                @panic("Unknown event");
            }
        }
    }
    const wait_result = posix.waitpid(child_pid, 0);
    std.debug.assert(wait_result.pid == child_pid);
    const process_result = if (posix.W.IFEXITED(wait_result.status))
        ProcessRunResult{.Normal = posix.W.EXITSTATUS(wait_result.status)}
    else
        ProcessRunResult{.Abnormal = {}};
    return .{
        .process_result = process_result,
        .stdout = try allocator.dupe(u8, collected_stdout.items),
        .stderr = try allocator.dupe(u8, collected_stderr.items),
        .signature = try preprocessSignature(allocator, collected_signature.items),
    };
}

const RemuRunResult = struct {
    failure_code: ?u64,
    signature: []u8,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.signature);
    }
};

pub fn runRemu(
    comptime opt: CpuOptions,
    allocator: Allocator,
    image: []const u8,
    debug_writer: ?std.io.AnyWriter,
    serial_writer: std.io.AnyWriter,
    debugger_filepath: ?[]const u8,
) !RemuRunResult {
    const f = try std.fs.cwd().openFile(
        image, .{ .mode = .read_only }
    );
    defer f.close();
    var elf_file = try libelf.Elf(opt.word_size).load(f);
    const signature_info = try elf_file.getSymbolsMultiple(
        &[_][:0]const u8{"begin_signature", "end_signature", "tohost"}
    ) orelse @panic("Failed reading signature data");
    const cpu_type = cpu.RVCPU(opt);
    const memory_start: cpu_type.Tword = 0x8000_0000;
    const memory_size: cpu_type.Tword = 1024*1024*256;
    var rvcpu = try cpu_type.init(
        allocator,
        elf_file.getEntrypoint(),
        memory_start,
        memory_size,
        debug_writer,
        .{ 
            .signature_start = signature_info.begin_signature.address,
            .signature_end = signature_info.end_signature.address,
            .tohost_address = signature_info.tohost.address,
        },
        serial_writer,
        debugger_filepath,
    );
    defer rvcpu.deinit();
    var it = try elf_file.get_loadable_it();
    while (it.next()) |segment| {
        try rvcpu.loadData(segment.start_address, segment.data);
        const offset: cpu_type.Tword = @intCast(segment.data.len);
        try rvcpu.loadZeroes(segment.start_address + offset, segment.padding);
    }
    while (!rvcpu.isHalted()) {
        try rvcpu.tick();
    }
    const signature = try rvcpu.getSignature(allocator);
    const failure_code = rvcpu.getTestFailureCode();
    const failure_code_u64: ?u64 = if (failure_code) |code| @intCast(code) else null;
    return .{
        .failure_code = failure_code_u64,
        .signature = signature,
    };
}

fn alignOnPage(T: type, i: *T) void {
    const page_size: T = 4096;
    const alignment_mask: T = page_size - 1;
    const new_value: T = (
        (i.* + page_size) & (~alignment_mask)
    );
    i.* = new_value;
}

fn loadImage(
    comptime opt: CpuOptions,
    allocator: Allocator,
    rvcpu: *cpu.RVCPU(opt),
    image: []const u8,
    current_location: opt.getTword(),
) !opt.getTword() {
    const MAX_FILESIZE = 32*1024*1024;
    const Tword = opt.getTword();
    const image_data = try std.fs.cwd().readFileAlloc(
        allocator, image, MAX_FILESIZE
    );
    defer allocator.free(image_data);
    try rvcpu.loadData(current_location, image_data);
    var end_address = current_location + image_data.len;
    alignOnPage(Tword, &end_address);
    return end_address;
}

// TODO: read OpenSBI as ELF
pub fn runRemuBinary(
    comptime opt: CpuOptions,
    allocator: Allocator,
    opensbi_path: []const u8,
    dtb_path: []const u8,
    kernel_path: []const u8,
    initrd_path: []const u8,
    debug_writer: ?std.io.AnyWriter,
    serial_writer: std.io.AnyWriter,
    gdb_socket_path: ?[]const u8,
) !RemuRunResult {
    const cpu_type = cpu.RVCPU(opt);
    const Tword = cpu_type.Tword;
    const FwDynamicInfo = packed struct {
        magic: Tword = 0x4942534f,
        version: Tword = 2,
        next_addr: Tword,
        next_mode: Tword,
        options: Tword,
        boot_hart: Tword,
    };

    const opensbi_start     = 0x8000_0000;
    const kernel_start      = 0x9000_0000;
    const initrd_start      = 0xa000_0000;
    const dtb_start         = 0xb000_0000;
    const BusCfg = bus.BusDeviceConfig(Tword);
    const cpu_bus = try bus.Bus(Tword).init(
        allocator,
        &[_]BusCfg {
            BusCfg.makeMemory(opensbi_start,    64*1024*1024),  // 64M  for OpenSBI
            BusCfg.makeMemory(kernel_start,     512*1024*1024), // 512M for Linux
            BusCfg.makeMemory(initrd_start,     64*1024*1024),  // 64M  for initrd
            BusCfg.makeMemory(dtb_start,        8*1024*1024),   // 8M   for DTB, FwDynamicInfo
            BusCfg.makeSerial(0x1000_0000, serial_writer),
            BusCfg.makeClint(0x200_0000),
            BusCfg.makePlic(0xc00_0000),
        },
    );

    var rvcpu = try cpu_type.initWithBus(
        allocator,
        opensbi_start,
        cpu_bus,
        debug_writer,
        null,
        gdb_socket_path,
    );
    defer rvcpu.deinit();

    _ = try loadImage(opt, allocator, &rvcpu, opensbi_path, opensbi_start);
    _ = try loadImage(opt, allocator, &rvcpu, initrd_path, initrd_start);
    const dtb_end = try loadImage(opt, allocator, &rvcpu, dtb_path, dtb_start);
    const fwinfo_start = dtb_end + 4096;
    _ = try loadImage(opt, allocator, &rvcpu, kernel_path, kernel_start);
    const next_boot_info = FwDynamicInfo {
        .next_mode = @intCast(cpu.privilege.PrivilegeLevel.Supervisor.getEncoding()),
        .options = 0,
        .next_addr = kernel_start,
        .boot_hart = 0,
    };
    try rvcpu.loadData(fwinfo_start, std.mem.asBytes(&next_boot_info));
    rvcpu.setRegister(11, dtb_start);
    rvcpu.setRegister(12, fwinfo_start);

    while (!rvcpu.isHalted()) {
        try rvcpu.tick();
    }
    const signature = try rvcpu.getSignature(allocator);
    const failure_code = rvcpu.getTestFailureCode();
    const failure_code_u64: ?u64 = if (failure_code) |code| @intCast(code) else null;
    return .{
        .failure_code = failure_code_u64,
        .signature = signature,
    };
}

const CollectedRemuRunResult = struct {
    failure_code: ?u64,
    signature: []u8,
    serial_output: []u8,

    pub fn deinit(self: @This(), allocator: Allocator) void {
        allocator.free(self.signature);
        allocator.free(self.serial_output);
    }

    fn isFailure(self: @This()) bool {
        if (self.failure_code != null) return true;
        return false;
    }
};

pub fn runRemuAndCollectSerial(
    comptime opt: CpuOptions,
    allocator: Allocator,
    image: []const u8,
    debug_writer: ?std.io.AnyWriter,
    debugger_filepath: ?[]const u8,
) !CollectedRemuRunResult {
    var serial_output = std.ArrayList(u8).init(allocator);
    defer serial_output.deinit();
    const serial_writer = serial_output.writer().any();
    const remu_result = try runRemu(opt, allocator, image, debug_writer, serial_writer, debugger_filepath);
    return .{
        .failure_code = remu_result.failure_code,
        .signature = remu_result.signature,
        .serial_output = try serial_output.toOwnedSlice(),
    };
}

fn stringCmp(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

pub const TestSuiteResult = struct {
    total_tests: usize,
    failed_tests: [][]const u8,
};

pub fn printResults(
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

const RunDiscrepancy = union(enum) {
    NoDiscrepancy: struct {
        signature: []u8,
        serial_output: []u8,
    },
    Discrepancy: struct {
        spike_results: SpikeRunResults,
        remu_results: CollectedRemuRunResult,
    },

    fn init(allocator: Allocator, spike_results: SpikeRunResults, remu_results: CollectedRemuRunResult) RunDiscrepancy {
        const signatures_match: bool = std.mem.eql(u8, spike_results.signature, remu_results.signature);
        const serial_outputs_match: bool = std.mem.eql(u8, spike_results.stdout, remu_results.serial_output);
        if (spike_results.isFailure() or remu_results.isFailure() or !signatures_match or !serial_outputs_match) {
            return RunDiscrepancy {
                .Discrepancy = .{
                    .spike_results = spike_results,
                    .remu_results = remu_results,
                }
            };
        }
        spike_results.deinit(allocator);
        return RunDiscrepancy {
            .NoDiscrepancy = .{
                .signature = remu_results.signature,
                .serial_output = remu_results.serial_output,
            }
        };
    }

    pub fn deinit(self: RunDiscrepancy, allocator: Allocator) void {
        switch(self) {
            .NoDiscrepancy => |d| {
                allocator.free(d.signature);
                allocator.free(d.serial_output);
            },
            .Discrepancy => |d| {
                d.spike_results.deinit(allocator);
                d.remu_results.deinit(allocator);
            },
        }
    }
};

pub fn runSingle(
    comptime opt: CpuOptions,
    allocator: Allocator,
    image: []const u8,
    debug_writer: ?std.io.AnyWriter,
) !RunDiscrepancy {
    const spike_result = try runSpike(allocator, opt.word_size, image);
    errdefer spike_result.deinit(allocator);
    const remu_result = try runRemuAndCollectSerial(opt, allocator, image, debug_writer, null);
    return RunDiscrepancy.init(allocator, spike_result, remu_result);
}

pub fn printDiff(
    allocator: Allocator,
    str1: []const u8,
    str2: []const u8
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    const str1_read_fd, const str1_write_fd = try posix.pipe2(std.os.linux.O { .NONBLOCK = true });
    const str2_read_fd, const str2_write_fd = try posix.pipe2(std.os.linux.O { .NONBLOCK = true });
    errdefer {
        posix.close(str1_read_fd);
        posix.close(str1_write_fd);
        posix.close(str2_read_fd);
        posix.close(str2_write_fd);
    }
    const str1_arg = try std.fmt.allocPrintZ(arena_allocator, "/proc/self/fd/{}", .{str1_read_fd});
    const str2_arg = try std.fmt.allocPrintZ(arena_allocator, "/proc/self/fd/{}", .{str2_read_fd});
    const environment = try std.process.createEnvironFromExisting(
        arena_allocator,
        std.c.environ,
        .{},
    );
    const child_arguments = [_:null]?[*:0]const u8 {
        "diff",
        str1_arg,
        str2_arg
    };
    const child_pid = try posix.fork();
    if (child_pid == 0) {
        posix.close(str1_write_fd);   
        posix.close(str2_write_fd);   
        posix.execvpeZ(
            "diff",
            &child_arguments,
            environment
        ) catch unreachable;
    }
    posix.close(str1_read_fd);
    posix.close(str2_read_fd);
    var str1_cpy = str1;
    var str2_cpy = str2;
    while (str1_cpy.len > 0 and str2_cpy.len > 0) {
        const str1_cpy_write_count = @min(str1_cpy.len, 4096);
        const str1_cpy_wrote = posix.write(str1_write_fd, str1_cpy[0..str1_cpy_write_count]) catch |err| switch(err) {
            error.WouldBlock => 0,
            else => return err,
        };
        str1_cpy = str1_cpy[str1_cpy_wrote..];
        const str2_cpy_write_count = @min(str2_cpy.len, 4096);
        const str2_cpy_wrote = posix.write(str2_write_fd, str2_cpy[0..str2_cpy_write_count]) catch |err| switch(err) {
            error.WouldBlock => 0,
            else => return err,
        };
        str2_cpy = str2_cpy[str2_cpy_wrote..];
    }
    posix.close(str1_write_fd);
    posix.close(str2_write_fd);
    _ = posix.waitpid(child_pid, 0);
}

pub fn runMulti(
    comptime opt: CpuOptions,
    allocator: Allocator,
    result_allocator: Allocator,
    start: []const u8,
    path: []const u8,
    writer: std.io.AnyWriter
) !TestSuiteResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const cwd = std.fs.cwd();
    const dest_dir = try cwd.openDir(path, .{ .iterate = true });
    const items = try findAll(arena_allocator, start, dest_dir);

    var total_tests: usize = 0;
    var passed_tests: usize = 0;

    var failed_tests = std.ArrayList([]const u8).init(arena_allocator);
    for (items) |i| {
        const image_path = try std.fs.path.join(
            allocator,
            &[_][]const u8 { path, i }
        );
        defer allocator.free(image_path);
        try writer.print("Running {s}\n", .{i});
        const spike_result = try runSpike(allocator, opt.word_size, image_path);
        defer spike_result.deinit(allocator);
        if (spike_result.isFailure()) {
            @panic("Running spike failed!");
        }
        const pid = linux.fork();
        if (pid == 0) {
            const rl = linux.rlimit {
                .cur = 1,
                .max = 1,
            };
            std.debug.assert(linux.setrlimit(linux.rlimit_resource.CPU, &rl) == 0);

            const remu_result = try runRemuAndCollectSerial(opt, allocator, image_path, null, null);
            const run_result = RunDiscrepancy.init(allocator, spike_result, remu_result);
            const process_exit_code: u8 = switch (run_result) {
                .Discrepancy => 1,
                .NoDiscrepancy => 0,
            };
            std.process.exit(process_exit_code);
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
    allocator: Allocator,
    result_allocator: Allocator,
    path: []const u8,
    writer: std.io.AnyWriter
) !void {
    const results = [_]TestSuiteResult {
        // TODO: bring back 32bit
        // try runMulti(priv32, allocator, result_allocator, "rv32ui-p", path, writer),
        try runMulti(priv64, allocator, result_allocator, "rv64ui-p", path, writer),
        // try runMulti(priv32.withM(), allocator, result_allocator, "rv32um-p", path, writer),
        try runMulti(priv64.withM(), allocator, result_allocator, "rv64um-p", path, writer),
        // try runMulti(priv32.withA(), allocator, result_allocator, "rv64um-p", path, writer),
        try runMulti(priv64.withA(), allocator, result_allocator, "rv64ua-p", path, writer),
    };
    try printResults(&results, writer);
}
