const std = @import("std");
const posix = std.posix;
const File = std.fs.File;
const Timer = std.time.Timer;
const Allocator = std.mem.Allocator;
const RingBuffer = std.RingBuffer;

const FileReaderProducer = struct {
    const Self = @This();

    file: File,

    fn init(file: File) Self {
        return Self {
            .file = file,
        };
    }
};

pub const BufferedReader = struct {
    const Self = @This();

    const BUFFER_CAPACITY: comptime_int = 4096;

    file: File,
    buffer: RingBuffer,
    allocator: Allocator,

    fn init(allocator: Allocator, file: File) !Self {
        return Self {
            .file = file,
            .buffer = try RingBuffer.init(allocator, BUFFER_CAPACITY),
            .allocator = allocator,
        };
    }

    fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    fn handleIo(self: *Self) !void {
        var syscall_buffer: [BUFFER_CAPACITY]u8 = undefined;
        const max_bytes_to_read = BUFFER_CAPACITY - self.buffer.len();
        if (max_bytes_to_read == 0) return;
        const count_read = try self.file.read(syscall_buffer[0..max_bytes_to_read]);
        self.buffer.writeSliceAssumeCapacity(syscall_buffer[0..count_read]);
    }

    pub fn popByte(self: *Self) ?u8 {
        return self.buffer.read();
    }

    pub fn hasData(self: *const Self) bool {
        return !self.buffer.isEmpty();
    }
};

pub const BufferedWriter = struct {
    const Self = @This();

    const BUFFER_CAPACITY: comptime_int = 4096;

    file: File,
    buffer: std.RingBuffer,
    allocator: Allocator,

    fn init(allocator: Allocator, file: File) !Self {
        return Self {
            .file = file,
            .buffer = try RingBuffer.init(allocator, BUFFER_CAPACITY),
            .allocator = allocator,
        };
    }

    fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    fn handleIo(self: *Self) !void {
        const bytes_count = self.buffer.len();
        if (bytes_count == 0) return;
        var syscall_buffer: [BUFFER_CAPACITY]u8 = undefined;
        self.buffer.readFirstAssumeLength(&syscall_buffer, bytes_count);
        try self.file.writeAll(syscall_buffer[0..bytes_count]);
    }

    pub fn canAcceptByte(self: *const Self) bool {
        return self.buffer.len() < BUFFER_CAPACITY;
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.buffer.len() == 0;
    }

    pub fn pushByte(self: *Self, byte: u8) void {
        if (!self.canAcceptByte()) {
            std.debug.print("W: overwriting a byte because of serial write overflow\n", .{});
        }
        self.buffer.writeAssumeCapacity(byte);
    }
};

const BufferedReaderWriter = struct {
    const Self = @This();

    reader: BufferedReader,
    writer: BufferedWriter,

    fn init(allocator: Allocator, file: File) !Self {
        return .{
            .reader = try BufferedReader.init(allocator, file),
            .writer = try BufferedWriter.init(allocator, file),
        };
    }

    fn deinit(self: *Self) void {
        self.reader.deinit();
        self.writer.deinit();
    }

    fn handleIo(self: *Self) !void {
        try self.reader.handleIo();
        try self.writer.handleIo();
    }
};

pub const IoDevice = enum {
    serial,
    gdb,
};

pub const IoHandler = struct {
    const Self = @This();

    const POLL_FLAGS_TO_CHECK: comptime_int =
        posix.POLL.IN |
        posix.POLL.PRI;

    const TPollFds = std.EnumArray(IoDevice, posix.pollfd);

    const BUDGET_CHEAP = 256;
    const BUDGET_EXPENSIVE = 4096;

    pollfds: TPollFds,

    tick: usize,
    mtime: u64,
    timer: Timer,
    serial_read: ?BufferedReader,
    serial_write: ?BufferedWriter,
    gdb: ?BufferedReaderWriter,

    fn makePollFd(file_opt: ?File) posix.pollfd {
        if (file_opt) |file| { 
            return .{
                .fd = file.handle,
                .events = POLL_FLAGS_TO_CHECK,
                .revents = 0,
            };
        } else {
            return .{
                .fd = -1,
                .events = 0,
                .revents = 0,
            };
        }
    }

    fn makeBuffered(T: anytype, allocator: Allocator, file_opt: ?File) !?T {
        if (file_opt) |file| {
            return try T.init(allocator, file);
        }
        return null;
    }

    pub fn init(
        allocator: Allocator,
        serial_reader: ?File,
        serial_writer: ?File,
        gdb: ?File,
    ) !Self {
        return .{
            .pollfds = TPollFds.init(.{
                .serial = Self.makePollFd(serial_reader),
                .gdb = Self.makePollFd(gdb),
            }),
            .tick = 0,
            .mtime = 0,
            .serial_read = try Self.makeBuffered(BufferedReader, allocator, serial_reader),
            .serial_write = try Self.makeBuffered(BufferedWriter, allocator, serial_writer),
            .gdb = try Self.makeBuffered(BufferedReaderWriter, allocator, gdb),
            .timer = try Timer.start(),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.serial_read) |*b| b.deinit();
        if (self.serial_write) |*b| b.deinit();
        if (self.gdb) |*b| b.deinit();
    }

    fn handleReadIo(self: *Self, comptime device: IoDevice) !void {
        switch (device) {
            .serial => if (self.serial_read) |*serial| try serial.handleIo(),
            .gdb => if (self.gdb) |*gdb| try gdb.reader.handleIo(),
        }
    }

    fn handleWriteIo(self: *Self) !void {
        if (self.serial_write) |*serial| try serial.handleIo();
        if (self.gdb) |*gdb| try gdb.writer.handleIo();
    }

    fn pollExpensiveIoEvents(self: *Self) !void {
        const events_polled = try posix.poll(&self.pollfds.values, 0);
        if (events_polled > 0) {
            inline for (std.meta.fields(IoDevice)) |dev| {
                const device_id: IoDevice = @enumFromInt(dev.value);
                const pollfd = self.pollfds.getPtr(device_id);
                if (pollfd.revents & POLL_FLAGS_TO_CHECK != 0) {
                    try self.handleReadIo(device_id);
                }
            }
        }
        try self.handleWriteIo();
    }

    pub fn updateMtime(self: *Self) void {
        // TODO: un-hardcode frequency
        const freq_hz: comptime_int = 10_000_000;
        const elapsed_ns = @as(u128, self.timer.read());
        self.mtime = @truncate((elapsed_ns * freq_hz) / std.time.ns_per_s);
    }

    fn pollCheapIoEvents(self: *Self) void {
        self.updateMtime();
    }

    pub fn pollIoEvents(self: *Self) !bool {
        self.tick += 1;
        var updated = false;
        if (self.tick % BUDGET_EXPENSIVE == 0) {
            try self.pollExpensiveIoEvents();
            updated = true;
        }
        if (self.tick % BUDGET_CHEAP == 0) {
            self.pollCheapIoEvents();
        }
        return updated;
    }

    pub fn getSerialReader(self: *Self) ?*BufferedReader {
        if (self.serial_read) |*serial_read| {
            return serial_read;
        }
        return null;
    }

    pub fn getSerialWriter(self: *Self) ?*BufferedWriter {
        if (self.serial_write) |*serial_write| {
            return serial_write;
        }
        return null;
    }
};
