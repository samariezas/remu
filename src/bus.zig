const std = @import("std");
const Allocator = std.mem.Allocator;
const LittleEndian = std.builtin.Endian.little;
const AnyWriter = std.io.AnyWriter;

fn BusDevice(comptime Tword: type) type {
    return struct {
        start_address: Tword,
        length: Tword,
        vtag: union(enum) {
            memory: struct {
                allocator: Allocator,
                data: []u8,
            },
            serial: struct {
                writer: AnyWriter,
            },
        },

        const Self = @This();

        fn initMemory(allocator: Allocator, memory_start: Tword, memory_length: Tword) !Self {
            const memory = try allocator.alloc(u8, memory_length);
            @memset(memory, 0xa1); // TODO: hide under some "debug" flag
            return .{
                .start_address = memory_start,
                .length = memory_length,
                .vtag = .{ .memory = .{
                    .allocator = allocator,
                    .data = memory,
                }},
            };
        }

        fn initSerial(start_address: Tword, writer: AnyWriter) Self {
            const retval = Self {
                .start_address = start_address,
                .length = 0x1000,
                .vtag = .{ .serial = .{
                    .writer = writer,
                }},
            };
            return retval;
        }
        
        fn deinit(self: *Self) void {
            switch (self.vtag) {
                .memory => |*m| { m.*.allocator.free(m.*.data); },
                .serial => { },
            }
        }

        fn readMemory(self: *Self, offset: Tword, dest: []u8) !void {
            const length: Tword = @intCast(dest.len);
            if (offset + length >= self.length) {
                return error.OutOfBounds;
            }
            switch (self.vtag) {
                .memory => |*m| {
                    const s_offset: usize = @intCast(offset);
                    @memcpy(dest, m.data[s_offset..(s_offset+dest.len)]);
                },
                .serial => return error.CannotReadSerialBlock,
            }
        }

        fn writeMemory(self: *Self, offset: Tword, src: []const u8) !void {
            const length: Tword = @intCast(src.len);
            if (offset + length > self.length) {
                return error.OutOfBounds;
            }
            switch (self.vtag) {
                .memory => |*m| {
                    const s_offset: usize = @intCast(offset);
                    @memcpy(m.data[s_offset..(s_offset+src.len)], src);
                },
                .serial => |*s| {
                    if (offset == 0) {
                        const written = s.writer.write(&[_]u8{src[0]}) catch unreachable;
                        std.debug.assert(written == 1);
                    }
                },
            }
        }
    };
}

pub fn BusDeviceConfig(Tword: type) type {
    return union(enum) {
        const Self = @This();
        memory: struct {
            start: Tword,
            length: Tword,
        },
        serial: struct {
            start: Tword,
            output_device: AnyWriter,
        },

        pub fn makeMemory(address_start: Tword, length: Tword) Self {
            return .{ .memory = .{
                .start = address_start,
                .length = length,
            }};
        }

        pub fn makeSerial(address_start: Tword, output_device: AnyWriter) Self {
            return .{ .serial = .{
                .start = address_start,
                .output_device = output_device,
            }};
        }
        
        fn buildDevice(self: *const Self, allocator: Allocator) !BusDevice(Tword) {
            return switch (self.*) {
                .memory => |*m| try BusDevice(Tword).initMemory(allocator, m.start, m.length),
                .serial => |*s| BusDevice(Tword).initSerial(s.start, s.output_device),
            };
        }
    };
}

pub fn Bus(Tword: type) type {
    return struct {
        const DeviceArray = []BusDevice(Tword);

        devices: DeviceArray,

        const Self = @This();

        pub fn init(allocator: Allocator, device_configs: []const BusDeviceConfig(Tword)) !Self {
            var devices = try std.ArrayList(BusDevice(Tword)).initCapacity(allocator, device_configs.len);
            errdefer {
                for (devices.items) |*dev| {
                    dev.deinit();
                }
                devices.deinit();
            }
            for (device_configs) |cfg| {
                devices.appendAssumeCapacity(try cfg.buildDevice(allocator));
            }
            std.debug.assert(devices.items.len == devices.allocatedSlice().len);
            return .{
                .devices = devices.allocatedSlice(),
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.devices) |*dev| {
                dev.deinit();
            }
            allocator.free(self.devices);
        }

        fn getMemorySlice(self: *Self, address: Tword, length: Tword) ![]u8 {
            if (address < self.memory_start) {
                return error.OutOfBounds;
            }
            const start = address - self.memory_start;
            const end = start + length;
            if (end >= self.memory.len) {
                return error.OutOfBounds;
            }
            return self.memory[start..end];
        }

        // TODO: do in a better way (i.e. allow reading from multiple devices for a single read)
        fn findDevice(self: *Self, address: Tword) ?*BusDevice(Tword) {
            for (self.devices) |*dev| {
                if (address >= dev.start_address and address < dev.start_address + dev.length) {
                    return dev;
                }
            }
            return null;
        }

        pub fn readMemory(self: *Self, address: Tword, dest: []u8) !void {
            if (self.findDevice(address)) |dev| {
                try dev.readMemory(address - dev.start_address, dest);
            } else {
                return error.BusDeviceNotFound;
            }
        }

        pub fn readWord(self: *Self, address: Tword) !Tword {
            var bytes: [@sizeOf(Tword)]u8 = undefined;
            try self.readMemory(address, &bytes);
            return std.mem.readInt(Tword, &bytes, LittleEndian);
        }

        pub fn writeMemory(self: *Self, address: Tword, src: []const u8) !void {
            // TODO: do in a better way
            if (self.findDevice(address)) |dev| {
                try dev.writeMemory(address - dev.start_address, src);
            } else {
                return error.BusDeviceNotFound;
            }
        }

        fn writeWord(self: *Self, address: Tword, word: Tword) !void {
            var bytes: [@sizeOf(Tword)]u8 = undefined;
            std.mem.writeInt(Tword, &bytes, word, LittleEndian);
            try self.writeMemory(address, &bytes);
        }
    };
}

const DebugAllocator = std.heap.DebugAllocator(.{});
const testing = std.testing;
fn TestEnvironment(Tword: type) type {
    return struct {
        const Self = @This();
        const BusDeviceCfg = BusDeviceConfig(Tword);

        pub const MEMORY_LENGTH: Tword = 0x4000;
        pub const MEMORY_START: Tword = 0x0800_0000;
        pub const SERIAL_START: Tword = 0x1000_0000;

        allocator: Allocator,
        serial_output: std.ArrayList(u8),

        fn init() !Self {
            const allocator = std.testing.allocator;
            return .{
                .allocator = allocator,
                .serial_output = std.ArrayList(u8).init(allocator),
            };
        }

        fn deinit(self: *Self) !void {
            self.serial_output.deinit();
            try testing.expectEqual(self.serial_output.items.len, 0);
        }

        fn getSerial(self: *Self) ![]u8 {
            return self.serial_output.toOwnedSlice();
        }

        fn makeBus(self: *Self, bus_config: []const BusDeviceCfg) !Bus(Tword) {
            return try Bus(Tword).init(self.allocator, bus_config);
        }

        fn makeBasicBus(self: *Self) !Bus(Tword) {
            return try self.makeBus(&[_]BusDeviceCfg {
                BusDeviceCfg.makeMemory(MEMORY_START, MEMORY_LENGTH),
            });
        }

        fn makeSerialBus(self: *Self) !Bus(Tword) {
            return try self.makeBus(&[_]BusDeviceCfg {
                BusDeviceCfg.makeMemory(MEMORY_START, MEMORY_LENGTH),
                BusDeviceCfg.makeSerial(SERIAL_START, self.serial_output.writer().any()),
            });
        }

        fn makeBusWithTwoMemoryDevices(self: *Self) !Bus(Tword) {
            return try self.makeBus(&[_]BusDeviceCfg {
                BusDeviceCfg.makeMemory(MEMORY_START, MEMORY_LENGTH),
                BusDeviceCfg.makeMemory(MEMORY_START + MEMORY_LENGTH, MEMORY_LENGTH),
            });
        }
    };
}

const to_write = [4]u8 { 0x69, 0x13, 0x37, 0x42 };

fn test_read_write(Tword: type) !void {
    const Tenv = TestEnvironment(Tword);
    var env = try Tenv.init();
    defer env.deinit() catch unreachable;
    var bus = try env.makeBasicBus();
    defer bus.deinit(env.allocator);

    var readback: [to_write.len]u8 = undefined;

    try bus.readMemory(Tenv.MEMORY_START, &readback);
    try testing.expect(!std.mem.eql(u8, &readback, &to_write));
    try bus.writeMemory(Tenv.MEMORY_START, &to_write);
    try bus.readMemory(Tenv.MEMORY_START, &readback);
    try testing.expect(std.mem.eql(u8, &readback, &to_write));
}

test "basic bus32 read/write" {
    try test_read_write(u32);
}

test "basic bus64 read/write" {
    try test_read_write(u64);
}

fn test_serial_device(Tword: type) !void {
    const Tenv = TestEnvironment(Tword);
    var env = try Tenv.init();
    defer env.deinit() catch unreachable;
    var bus = try env.makeSerialBus();
    defer bus.deinit(env.allocator);
    for (to_write) |byte| {
        try bus.writeMemory(Tenv.SERIAL_START, &[1]u8 { byte });
    }
    const result = try env.getSerial();
    defer env.allocator.free(result);
    try testing.expectEqualSlices(u8, result, &to_write);
}

test "bus32 serial device" {
    try test_serial_device(u32);
}

test "bus64 serial device" {
    try test_serial_device(u64);
}

fn test_write_end_of_device(Tword: type) !void {
    const Tenv = TestEnvironment(Tword);
    var env = try Tenv.init();
    defer env.deinit() catch unreachable;
    var bus = try env.makeBasicBus();
    defer bus.deinit(env.allocator);
    try bus.writeMemory(Tenv.MEMORY_START + Tenv.MEMORY_LENGTH - to_write.len, &to_write);
}

test "bus32 write to end of device" {
    try test_write_end_of_device(u32);
}

test "bus64 write to end of device" {
    try test_write_end_of_device(u64);
}

fn test_write_across_devices(Tword: type) !void {
    // For now, writes across devices should fail
    const Tenv = TestEnvironment(Tword);
    var env = try Tenv.init();
    defer env.deinit() catch unreachable;
    var bus = try env.makeBusWithTwoMemoryDevices();
    defer bus.deinit(env.allocator);
    try testing.expectEqual(
        bus.writeMemory(Tenv.MEMORY_START + Tenv.MEMORY_LENGTH - to_write.len + 1, &to_write),
        error.OutOfBounds
    );
}

test "bus32 write across devices" {
    try test_write_across_devices(u32);
}

test "bus64 write across devices" {
    try test_write_across_devices(u64);
}
