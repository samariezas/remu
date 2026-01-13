const std = @import("std");
const privilege = @import("privilege.zig");
const Allocator = std.mem.Allocator;
const LittleEndian = std.builtin.Endian.little;
const AnyWriter = std.io.AnyWriter;
const PrivilegeLevel = privilege.PrivilegeLevel;
const SppPrivilegeLevel = privilege.SppPrivilegeLevel;

const TranslationReason = enum {
    Read,
    Write,
    Execute
};

pub const BusError = error {
    AlignmentFault,
    AccessFault,
    PageFault
};

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

        fn readMemory(self: *const Self, offset: Tword, dest: []u8) BusError!void {
            const length: Tword = @intCast(dest.len);
            if (offset + length >= self.length) {
                return error.AlignmentFault;
            }
            switch (self.vtag) {
                .memory => |*m| {
                    const s_offset: usize = @intCast(offset);
                    @memcpy(dest, m.data[s_offset..(s_offset+dest.len)]);
                },
                .serial => return error.AccessFault,
            }
        }

        fn writeMemory(self: *Self, offset: Tword, src: []const u8) BusError!void {
            const length: Tword = @intCast(src.len);
            if (offset + length > self.length) {
                return error.AlignmentFault;
            }
            switch (self.vtag) {
                .memory => |*m| {
                    const s_offset: usize = @intCast(offset);
                    @memcpy(m.data[s_offset..(s_offset+src.len)], src);
                },
                .serial => |*s| {
                    if (offset == 0) {
                        const written = s.writer.write(&[_]u8{src[0]}) catch @panic("Serial device write failed");
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

        // TODO: do in a better way (i.e. allow reading from multiple devices for a single read)
        fn findDevice(self: *const Self, address: Tword) ?*BusDevice(Tword) {
            for (self.devices) |*dev| {
                if (address >= dev.start_address and address < dev.start_address + dev.length) {
                    return dev;
                }
            }
            return null;
        }

        pub fn readMemory(self: *const Self, address: Tword, dest: []u8) BusError!void {
            if (self.findDevice(address)) |dev| {
                try dev.readMemory(address - dev.start_address, dest);
            } else {
                return error.AccessFault;
            }
        }

        pub fn readWord(self: *Self, address: Tword) BusError!Tword {
            var bytes: [@sizeOf(Tword)]u8 = undefined;
            try self.readMemory(address, &bytes);
            return std.mem.readInt(Tword, &bytes, LittleEndian);
        }

        pub fn writeMemory(self: *Self, address: Tword, src: []const u8) BusError!void {
            // TODO: do in a better way
            if (self.findDevice(address)) |dev| {
                try dev.writeMemory(address - dev.start_address, src);
            } else {
                return error.AccessFault;
            }
        }

        fn writeWord(self: *Self, address: Tword, word: Tword) BusError!void {
            var bytes: [@sizeOf(Tword)]u8 = undefined;
            std.mem.writeInt(Tword, &bytes, word, LittleEndian);
            try self.writeMemory(address, &bytes);
        }
    };
}

const MemoryTranslationPermissions = struct {
    read: bool,
    write: bool,
    execute: bool,

    fn makeEmpty() MemoryTranslationPermissions {
        return .{
            .read = false,
            .write = false,
            .execute = false,
        };
    }
};

pub fn Paging(Tword: type) type {
    return struct {
        const LEVELS: Tword = 3;
        const PAGESIZE: Tword = 4096;
        const PTESIZE: Tword = @sizeOf(Paging(Tword).PageTableEntry);
        const VirtualAddress = packed struct {
            const Self = @This();

            page_offset: u12,
            vpn0: u9,
            vpn1: u9,
            vpn2: u9,
            padding: u25,

            fn getVpnSmall(self: *const Self, i: usize) u9 {
                switch (i) {
                    0 => return self.vpn0,
                    1 => return self.vpn1,
                    2 => return self.vpn2,
                    else => unreachable,
                }
            }

            fn getVpn(self: *const Self, i: usize) Tword {
                return @intCast(self.getVpnSmall(i));
            }
        };

        const PhysicalPPN = packed struct {
            ppn0: u9,
            ppn1: u9,
            ppn2: u26,

            fn setIdx(self: *PhysicalPPN, idx: usize, val: u9) void {
                switch (idx) {
                    0 => self.ppn0 = val,
                    1 => self.ppn1 = val,
                    else => unreachable,
                }
            }

            fn getIdx(self: PhysicalPPN, i: usize) Tword {
                switch (i) {
                    0 => return @intCast(self.ppn0),
                    1 => return @intCast(self.ppn1),
                    2 => return @intCast(self.ppn2),
                    else => unreachable,
                }
            }

            fn getFull(self: PhysicalPPN) u44 {
                return @bitCast(self);
            }

            fn fromInt(val: u44) PhysicalPPN {
                return @bitCast(val);
            }
        };

        const PhysicalAddress = packed struct {
            const Self = @This();
             
            page_offset: u12,
            ppn: PhysicalPPN,
            padding: u8,

            fn getFull(self: *const Self) u64 {
                return @bitCast(self.*);
            }

            // fn getPpn(self: *const Self, i: isize) Tword {
            //     switch (i) {
            //         0 => return @bitCast(self.ppn0),
            //         1 => return @bitCast(self.ppn1),
            //         2 => return @bitCast(self.ppn2),
            //         else => unreachable,
            //     }
            // }
        };

        const PageTableEntry = packed struct {
            const Self = @This();

            v: u1,
            r: u1,
            w: u1,
            x: u1,
            u: u1,
            g: u1,
            a: u1,
            d: u1,
            rsw: u2,
            ppn: PhysicalPPN,
            reserved: u7,
            pbmt: u2,
            n: u1,

            // fn getPpn(self: *const Self, i: isize) Tword {
            //     switch (i) {
            //         0 => return @bitCast(self.ppn0),
            //         1 => return @bitCast(self.ppn1),
            //         2 => return @bitCast(self.ppn2),
            //         else => unreachable,
            //     }
            // }

            fn make(ppn: PhysicalPPN, permissions: MemoryTranslationPermissions) Self {
                return .{
                    .v = 1,
                    .r = @intFromBool(permissions.read),
                    .w = @intFromBool(permissions.write),
                    .x = @intFromBool(permissions.execute),
                    .u = 0,
                    .g = 0,
                    .a = 0,
                    .d = 0,
                    .rsw = 0,
                    .ppn = ppn,
                    .reserved = 0,
                    .pbmt = 0,
                    .n = 0
                };
            }

            fn isValid(self: *Self) bool {
                // TODO: do proper validity check
                return self.r != 0 or self.w != 0 or self.x != 0;
            }
        };

        fn translateAddress(
            bus: *Bus(Tword),
            va: VirtualAddress,
            ppn: u44,
            translation_reason: TranslationReason
        ) !Tword {
            var a: Tword = @as(Tword, ppn) * @as(Tword, PAGESIZE);
            var i: usize = LEVELS - 1;
            var pte: PageTableEntry = undefined;
            var pa = std.mem.zeroes(PhysicalAddress);
            while (true) {
                var buffer: [@sizeOf(PageTableEntry)]u8 = undefined;
                const address_to_read = a + va.getVpn(i) * @sizeOf(PageTableEntry);
                bus.readMemory(
                    address_to_read,
                    &buffer
                ) catch return error.CannotReadPageTableEntry;
                // TODO: should raise correct errors
                // ) catch |err| {
                    // switch (err) {
                    //     error.OutOfBounds => unreachable,
                    //     error.BusDeviceNotFound => unreachable,
                    //     error.CannotReadSerialBlock => unreachable,
                    // }
                // };
                pte = std.mem.littleToNative(PageTableEntry, @bitCast(buffer));
                // TODO: check reserved bits in PTE
                if (pte.v == 0 // pte is invalid
                    or (pte.r == 0 and pte.w == 1)) // reserved for future use
                {
                    return error.InvalidPTE;
                }
                if (pte.r == 1 or pte.x == 1) {
                    break;
                }
                if (i == 0) return error.TranslationTooDeep;
                i -= 1;
                a = pte.ppn.getFull() * PAGESIZE;
            }
            switch (translation_reason) {
                .Read => {
                    if (pte.r == 0) {
                        return error.DisallowedOperation;
                    }
                },
                .Write => {
                    if (pte.w == 0) {
                        return error.DisallowedOperation;
                    }
                },
                .Execute => {
                    if (pte.x == 0) {
                        return error.DisallowedOperation;
                    }
                }
            }
            // TODO: check for misaligned superpages
            // TODO: handle priv levels
            // TODO: step 9
            pa.page_offset = va.page_offset;
            var new_ppn = pte.ppn;
            for (0..i) |j| {
                if (pte.ppn.getIdx(j) != 0) return error.MisalignedSuperpage;
                new_ppn.setIdx(j, va.getVpnSmall(j));
            }
            pa.ppn = new_ppn;
            return @bitCast(pa);
        }
    };
}

const DebugAllocator = std.heap.DebugAllocator(.{});
const testing = std.testing;
fn TestEnvironment(Tword: type) type {
    return struct {
        const Self = @This();
        const BusDeviceCfg = BusDeviceConfig(Tword);

        pub const MEMORY_LENGTH: Tword = 0x1_0000;
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
        error.AlignmentFault
    );
}

test "bus32 write across devices" {
    try test_write_across_devices(u32);
}

test "bus64 write across devices" {
    try test_write_across_devices(u64);
}

fn mapPage(
    bus: *Bus(u64),
    permissions: MemoryTranslationPermissions,
    satp: u64,
    virtual_address: u64,
    physical_addresses: []const Paging(u64).PhysicalPPN
) !void {
    const paging = Paging(u64);
    const virt: paging.VirtualAddress = @bitCast(virtual_address);
    std.debug.assert(virt.padding == 0);
    var a = satp * paging.PAGESIZE;
    for (physical_addresses, 0..) |phys, i| {
        const final = physical_addresses.len <= (i + 1);
        const pte_address = a + virt.getVpn(paging.LEVELS - 1 - i) * paging.PTESIZE;
        a = phys.getFull() * paging.PAGESIZE;
        var currently_written: paging.PageTableEntry = undefined;
        try bus.readMemory(pte_address, std.mem.asBytes(&currently_written));
        currently_written = std.mem.littleToNative(paging.PageTableEntry, currently_written);
        if (currently_written.isValid()) {
            return error.OverridingPaging;
        }
        const perm = if (final) permissions else MemoryTranslationPermissions.makeEmpty();
        const new_pte = std.mem.nativeToLittle(
            paging.PageTableEntry,
            paging.PageTableEntry.make(phys, perm)
        );
        try bus.writeMemory(pte_address, std.mem.asBytes(std.mem.asBytes(&new_pte)));
    }
}

fn basic_translation_test(
    Tword: type,
    reason: TranslationReason,
    permissions: MemoryTranslationPermissions
) !Tword {
    const Tenv = TestEnvironment(Tword);
    var env = try Tenv.init();
    defer env.deinit() catch unreachable;
    const paging = Paging(Tword);
    var bus = try env.makeBasicBus();
    defer bus.deinit(env.allocator);

    const first_page: u44 = Tenv.MEMORY_START >> 12;
    const virtual_address = paging.VirtualAddress {
        .page_offset = 0x123,
        .vpn0 = 30,
        .vpn1 = 20,
        .vpn2 = 10,
        .padding = 0,
    };

    try mapPage(&bus, permissions, first_page, @bitCast(virtual_address), &[_]paging.PhysicalPPN {
        paging.PhysicalPPN.fromInt(first_page + 1),
        paging.PhysicalPPN.fromInt(first_page + 2),
        paging.PhysicalPPN.fromInt(first_page + 0x15),
    });
    return paging.translateAddress(
        &bus,
        virtual_address,
        first_page,
        reason
    );
}

test "bus64 translation" {
    const expected_address: u64 = (0x8015 << 12) + 0x123;
    const tests = [_]MemoryTranslationPermissions{
        .{ .read = true, .write = true, .execute = true, },
        .{ .read = true, .write = true, .execute = false, },
        .{ .read = true, .write = false, .execute = true, },
        .{ .read = true, .write = false, .execute = false, }
    };
    for (tests) |test_| {
        const translated_address = basic_translation_test(
            u64, .Read, test_
        );
        try testing.expectEqual(
            expected_address,
            translated_address
        );
    }
}

test "bus64 translation with incorrect permissions" {
    for ([_]MemoryTranslationPermissions{
        .{ .read = true, .write = false, .execute = true, },
        .{ .read = true, .write = false, .execute = false, }
    }) |test_| {
        const translated_address = basic_translation_test(
            u64, .Write, test_
        );
        try testing.expectEqual(
            error.DisallowedOperation,
            translated_address
        );
    }
    for ([_]MemoryTranslationPermissions{
        .{ .read = true, .write = true, .execute = false, },
        .{ .read = true, .write = false, .execute = false, }
    }) |test_| {
        const translated_address = basic_translation_test(
            u64, .Execute, test_
        );
        try testing.expectEqual(
            error.DisallowedOperation,
            translated_address
        );
    }
}

test "bus64 translation invalid PTE states" {
    // TODO
}

test "bus64 translation wrong access type" {
    const translated_address = basic_translation_test(
        u64,
        .Write,
        .{ .read = true, .write = false, .execute = true, }
    );
    try testing.expectEqual(
        translated_address,
        error.DisallowedOperation
    );
}

test "bus64 superpages" {
    const Tword = u64;
    const Tenv = TestEnvironment(Tword);
    var env = try Tenv.init();
    defer env.deinit() catch unreachable;
    const paging = Paging(Tword);
    var bus = try env.makeBasicBus();
    defer bus.deinit(env.allocator);

    const first_page: u44 = Tenv.MEMORY_START >> 12;
    const virtual_address = paging.VirtualAddress {
        .page_offset = 0x123,
        .vpn0 = 0x30,
        .vpn1 = 0x20,
        .vpn2 = 0x10,
        .padding = 0,
    };

    const permissions = MemoryTranslationPermissions {
        .read = true,
        .execute = true,
        .write = true,
    };
    try mapPage(&bus, permissions, first_page, @bitCast(virtual_address), &[_]paging.PhysicalPPN {
        paging.PhysicalPPN.fromInt(first_page + 1),
        paging.PhysicalPPN.fromInt(first_page + 0x400),
    });
    try testing.expectEqual(
        paging.translateAddress(
            &bus,
            virtual_address,
            first_page,
            .Read
        ),
        ((first_page + 0x400) << 12) + 0x30123
    );
}

test "bus64 superpages 2" {
    const Tword = u64;
    const Tenv = TestEnvironment(Tword);
    var env = try Tenv.init();
    defer env.deinit() catch unreachable;
    const paging = Paging(Tword);
    var bus = try env.makeBasicBus();
    defer bus.deinit(env.allocator);

    const first_page: u44 = Tenv.MEMORY_START >> 12;
    const virtual_address = paging.VirtualAddress {
        .page_offset = 0x123,
        .vpn0 = 0x30,
        .vpn1 = 0x20,
        .vpn2 = 0x10,
        .padding = 0,
    };
    const expected_phys_address = paging.PhysicalAddress {
        .padding = 0,
        .ppn = paging.PhysicalPPN {
            .ppn0 = 0x30,
            .ppn1 = 0x20,
            .ppn2 = 0xdead,
        },
        .page_offset = 0x123,
    };

    const permissions = MemoryTranslationPermissions {
        .read = true,
        .execute = true,
        .write = true,
    };
    try mapPage(&bus, permissions, first_page, @bitCast(virtual_address), &[_]paging.PhysicalPPN {
        paging.PhysicalPPN {
            .ppn0 = 0,
            .ppn1 = 0,
            .ppn2 = 0xdead
        },
    });
    const resulting_address = paging.translateAddress(
        &bus,
        virtual_address,
        first_page,
        .Read
    );
    try testing.expectEqual(
        expected_phys_address.getFull(),
        resulting_address
    );
}
