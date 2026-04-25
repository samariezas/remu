const std = @import("std");
const privilege = @import("privilege.zig");
const Allocator = std.mem.Allocator;
const LittleEndian = std.builtin.Endian.little;
const AnyWriter = std.io.AnyWriter;
const PrivilegeLevel = privilege.PrivilegeLevel;
const SppPrivilegeLevel = privilege.SppPrivilegeLevel;

pub const TranslationReason = enum {
    Read,
    Write,
    Execute
};

pub const BusError = error {
    AlignmentFault,
    AccessFault,
    PageFault
};

pub const TranslationError = error {
    CannotReadPageTableEntry,
    CannotWritePageTableEntry,
    InvalidPTE,
    TranslationTooDeep,
    DisallowedOperation,
    MisalignedSuperpage,
    NonCanonicalVirtualAddress,
};

const INTERRUPT_COUNT: comptime_int = 1;
const CONTEXT_COUNT: comptime_int = 2;
const SERIAL_INTERRUPT_ID: comptime_int = 1;

const PlicContext = struct {
    interrupt_claimed: bool,
    priority_threshold: u32,
    interrupts_enabled: [INTERRUPT_COUNT]bool,
};

const InterruptConfig = struct {
    priority: u32,
    pending: bool,
};

const PlicState = struct {
    _interrupts: [INTERRUPT_COUNT]InterruptConfig,
    _contexts: [CONTEXT_COUNT]PlicContext,

    fn getInterrupt(self: *PlicState, idx: usize) ?*InterruptConfig {
        if (idx > 0 and idx <= self._interrupts.len) {
            return &self._interrupts[idx - 1];
        }
        return null;
    }

    fn getContext(self: *PlicState, idx: usize) ?*PlicContext {
        if (idx < self._contexts.len) {
            return &self._contexts[idx];
        }
        return null;
    }

    fn getInterruptPriority(self: *PlicState, idx: usize) u32 {
        if (self.getInterrupt(idx)) |interrupt| {
            return interrupt.*.priority;
        }
        return 0;
    }

    fn setInterruptPriority(self: *PlicState, idx: usize, priority: u32) void {
        if (self.getInterrupt(idx)) |interrupt| {
            interrupt.*.priority = priority;
        }
    }

    pub fn setInterruptPending(self: *PlicState, idx: usize) void {
        if (self.getInterrupt(idx)) |interrupt| {
            interrupt.*.pending = true;
        }
    }

    pub fn clearInterruptPending(self: *PlicState, idx: usize) void {
        if (self.getInterrupt(idx)) |interrupt| {
            interrupt.*.pending = false;
        }
    }

    fn isInterruptPending(self: *PlicState, idx: usize) bool {
        if (self.getInterrupt(idx)) |interrupt| {
            return interrupt.*.pending;
        }
        return false;
    }

    fn getInterruptPendingBits(self: *PlicState, first_idx: usize) u32 {
        var retval: u32 = 0;
        for (0..32) |i| {
            const mask = @as(u32, 1) << @truncate(i);
            if (self.isInterruptPending(first_idx + i)) {
                retval |= mask;
            }
        }
        return retval;
    }

    fn isInterruptEnabled(self: *PlicState, idx: usize, context: usize) bool {
        if (idx == 0) return false;
        if (self.getContext(context)) |ctx| {
            const interrupt_idx = idx - 1;
            if (interrupt_idx < ctx.interrupts_enabled.len) {
                return ctx.interrupts_enabled[interrupt_idx];
            }
        }
        return false;
    }

    fn setInterruptEnabled(self: *PlicState, idx: usize, context: usize, enabled: bool) void {
        if (idx == 0) return;
        if (self.getContext(context)) |ctx| {
            const interrupt_idx = idx - 1;
            if (interrupt_idx < ctx.interrupts_enabled.len) {
                ctx.interrupts_enabled[interrupt_idx] = enabled;
            }
        }
    }

    fn getInterruptEnableBits(self: *PlicState, first_idx: usize, context: usize) u32 {
        var retval: u32 = 0;
        for (0..32) |i| {
            const mask = @as(u32, 1) << @truncate(i);
            if (self.isInterruptEnabled(first_idx + i, context)) {
                retval |= mask;
            }
        }
        return retval;
    }

    fn setInterruptEnableBits(self: *PlicState, first_idx: usize, context: usize, bits: u32) void {
        for (0..32) |i| {
            const mask = @as(u32, 1) << @truncate(i);
            self.setInterruptEnabled(first_idx + i, context, (bits & mask) != 0);
        }
    }

    fn getPriorityThreshold(self: *PlicState, context: usize) u32 {
        if (self.getContext(context)) |ctx| {
            return ctx.*.priority_threshold;
        }
        return 0;
    }

    fn setPriorityThreshold(self: *PlicState, context: usize, threshold: u32) void {
        if (self.getContext(context)) |ctx| {
            ctx.*.priority_threshold = threshold;
        }
    }

    fn getClaim(self: *PlicState, context: usize) u32 {
        if (context >= self._contexts.len) return 0;
        if (self.getContext(context)) |ctx| {
            var interrupt_to_claim: ?struct {
                priority: u32,
                index: u32
            } = null;
            for (ctx.*.interrupts_enabled, 0..) |enabled, i| {
                const interrupt_idx: u32 = @truncate(i + 1);
                if (!enabled) continue;
                if (self.getInterrupt(interrupt_idx)) |interrupt| {
                    if (!interrupt.pending) continue;
                    if (interrupt.priority <= ctx.priority_threshold) continue;
                    var replace = false;
                    if (interrupt_to_claim) |current_best| {
                        if (interrupt.priority > current_best.priority) {
                            replace = true;
                        }
                    } else {
                        replace = true;
                    }
                    if (replace) {
                        interrupt_to_claim = .{
                            .priority = interrupt.priority,
                            .index = interrupt_idx,
                        };
                    }
                }
            }
            if (interrupt_to_claim) |claimed| {
                self.getInterrupt(claimed.index).?.pending = false;
                ctx.interrupt_claimed = true;
                return claimed.index;
            }
        }
        return 0;
    }

    fn setComplete(self: *PlicState, context: usize, id: usize) void {
        if (self.getContext(context)) |ctx| {
            if (id == 0) return;
            if (self.isInterruptEnabled(id, context)) {
                ctx.interrupt_claimed = false;
            }
        }
    }

    pub fn shouldTrap(self: *PlicState, context: usize) bool {
        if (self.getContext(context)) |ctx| {
            for (self._interrupts, 0..) |interrupt, i| {
                if (ctx.interrupts_enabled[i] and
                    interrupt.pending and
                    interrupt.priority > ctx.priority_threshold) {
                    return true;
                }
            }
        }
        return false;
    }

    fn getWord(self: *PlicState, offset: u32) BusError!u32 {
        const address_class = PlicAddressClass.classifyAddress(offset);
        std.debug.print("Reading PLIC address with offset: {x}\n", .{offset});
        switch (address_class) {
            .Misaligned => return BusError.AlignmentFault,
            .Reserved => return BusError.AccessFault,

            .InterruptPriority => |*class|
                return self.getInterruptPriority(class.source),

            .InterruptPending => |*class|
                return self.getInterruptPendingBits(class.first_source),

            .EnableBits => |*class|
                return self.getInterruptEnableBits(class.first_source, class.context),

            .PriorityThreshold => |*class|
                return self.getPriorityThreshold(class.context),

            .ClaimComplete => |*class|
                return self.getClaim(class.context),
        }
    }

    fn writeWord(self: *PlicState, offset: u32, word: u32) BusError!void {
        const address_class = PlicAddressClass.classifyAddress(offset);
        std.debug.print("Writing PLIC address with offset: {x}\n", .{offset});
        switch (address_class) {
            .Misaligned => return BusError.AlignmentFault,
            .Reserved => return BusError.AccessFault,

            .InterruptPriority => |*class|
                self.setInterruptPriority(class.source, word),

            .InterruptPending =>
                return BusError.AccessFault,

            .EnableBits => |*class|
                self.setInterruptEnableBits(class.first_source, class.context, word),

            .PriorityThreshold => |*class|
                return self.setPriorityThreshold(class.context, word),

            .ClaimComplete => |*class|
                return self.setComplete(class.context, word),
        }
    }
};

const PlicAddressClass = union(enum) {
    Misaligned,
    Reserved,

    // priority for a source
    InterruptPriority: struct {
        source: u32,
    },

    // Pending bits [32*i; 32*(i+1))
    InterruptPending: struct {
        first_source: u32,
    },

    // Interrupt enable bits for specific context
    // and sources [32*i; 32*(i+1))
    EnableBits: struct {
        context: u32,
        first_source: u32,
    },

    // Priority threshold for a specific context
    PriorityThreshold: struct {
        context: u32,
    },

    // Claim/Complete for a specific context
    ClaimComplete: struct {
        context: u32,
    },

    fn classifyAddress(offset: u32) PlicAddressClass {
        if (offset % 4 != 0) {
            return .Misaligned;
        }
        if (offset >= 0x4 and offset <= 0xffc) {
            return .{
                .InterruptPriority = .{
                    .source = @divExact(offset, 4),
                }
            };
        }
        if (offset >= 0x1000 and offset <= 0x107c) {
            return .{
                .InterruptPending = .{
                    .first_source = (offset - 0x1000) * 8,
                }
            };
        }
        if (offset >= 0x2000 and offset <= 0x1f1ffc) {
            const entry_num = @divExact(offset - 0x2000, 4);
            const context = entry_num / 32;
            const first_source = (entry_num % 32) * 32;
            return .{
                .EnableBits = .{
                    .context = context,
                    .first_source = first_source,
                }
            };
        }
        if (offset >= 0x200000 and offset <= 0x3fff004) {
            const context = (offset - 0x200000) / 0x1000;
            switch (offset % 0x1000) {
                0 => return .{ .PriorityThreshold = .{ .context = context, } },
                4 => return .{ .ClaimComplete = .{ .context = context, } },
                else => {},
            }
        }
        return .Reserved;
    }
};

test "PLIC address classification" {
    try testing.expectEqual(
        PlicAddressClass { .InterruptPriority = .{ .source = 1, }, },
        PlicAddressClass.classifyAddress(0x4)
    );
    try testing.expectEqual(
        PlicAddressClass { .InterruptPriority = .{ .source = 1023, }, },
        PlicAddressClass.classifyAddress(0xffc)
    );
    try testing.expectEqual(
        PlicAddressClass { .InterruptPending = .{ .first_source = 0, }, },
        PlicAddressClass.classifyAddress(0x1000)
    );
    try testing.expectEqual(
        PlicAddressClass { .InterruptPending = .{ .first_source = 992, }, },
        PlicAddressClass.classifyAddress(0x107c)
    );
    try testing.expectEqual(
        PlicAddressClass { .EnableBits = .{
            .context = 0,
            .first_source = 0,
        }},
        PlicAddressClass.classifyAddress(0x2000)
    );
    try testing.expectEqual(
        PlicAddressClass { .EnableBits = .{
            .context = 0,
            .first_source = 32,
        }},
        PlicAddressClass.classifyAddress(0x2004)
    );
    try testing.expectEqual(
        PlicAddressClass { .EnableBits = .{
            .context = 1,
            .first_source = 0,
        }},
        PlicAddressClass.classifyAddress(0x2080)
    );
    try testing.expectEqual(
        PlicAddressClass { .EnableBits = .{
            .context = 1,
            .first_source = 32,
        }},
        PlicAddressClass.classifyAddress(0x2084)
    );
    try testing.expectEqual(
        PlicAddressClass { .EnableBits = .{
            .context = 15871,
            .first_source = 992,
        }},
        PlicAddressClass.classifyAddress(0x1f1ffc)
    );
    try testing.expectEqual(
        .Reserved,
        PlicAddressClass.classifyAddress(0x1ffffc)
    );
    try testing.expectEqual(
        PlicAddressClass { .PriorityThreshold = .{
            .context = 0,
        }},
        PlicAddressClass.classifyAddress(0x200000)
    );
    try testing.expectEqual(
        PlicAddressClass { .ClaimComplete = .{
            .context = 0,
        }},
        PlicAddressClass.classifyAddress(0x200004)
    );
    try testing.expectEqual(
        .Reserved,
        PlicAddressClass.classifyAddress(0x200008)
    );
    try testing.expectEqual(
        PlicAddressClass { .PriorityThreshold = .{
            .context = 1,
        }},
        PlicAddressClass.classifyAddress(0x201000)
    );
    try testing.expectEqual(
        PlicAddressClass { .ClaimComplete = .{
            .context = 1,
        }},
        PlicAddressClass.classifyAddress(0x201004)
    );
    try testing.expectEqual(
        PlicAddressClass { .PriorityThreshold = .{
            .context = 1,
        }},
        PlicAddressClass.classifyAddress(0x201000)
    );
    try testing.expectEqual(
        PlicAddressClass { .ClaimComplete = .{
            .context = 1,
        }},
        PlicAddressClass.classifyAddress(0x201004)
    );
    try testing.expectEqual(
        PlicAddressClass { .PriorityThreshold = .{
            .context = 15871,
        }},
        PlicAddressClass.classifyAddress(0x3FFF000)
    );
    try testing.expectEqual(
        PlicAddressClass { .ClaimComplete = .{
            .context = 15871,
        }},
        PlicAddressClass.classifyAddress(0x3FFF004)
    );
}

const SerialDevice = struct {
    writer: AnyWriter,
    rx_fifo: [16]u8,
    rx_head: u8,
    rx_len: u8,

    ier: u8, // Interrupt Enable Register
    iir: u8, // Interrupt Identification Register (read-only view)
    lcr: u8, // Line Control Register
    mcr: u8, // Modem Control Register
    lsr: u8, // Line Status Register
    scr: u8, // Scratch Register
    dll: u8, // Divisor latch low
    dlm: u8, // Divisor latch high

    const LCR_DLAB: u8 = 0x80;
    const IER_ERBFI: u8 = 0x01;
    const IER_ETBEI: u8 = 0x02;
    const IIR_NO_INTERRUPT_PENDING: u8 = 0x01;
    const IIR_THRE: u8 = 0x02;
    const IIR_RDA: u8 = 0x04;
    const IIR_CTYPE_16550A: u8 = 0xC0;
    const LSR_DR: u8 = 0x01;
    const LSR_THRE: u8 = 0x20;
    const LSR_TEMT: u8 = 0x40;

    fn init(writer: AnyWriter) SerialDevice {
        return .{
            .writer = writer,
            .rx_fifo = undefined,
            .rx_head = 0,
            .rx_len = 0,
            .ier = 0,
            .iir = IIR_NO_INTERRUPT_PENDING | IIR_CTYPE_16550A,
            .lcr = 0,
            .mcr = 0,
            .lsr = LSR_THRE | LSR_TEMT,
            .scr = 0,
            .dll = 0,
            .dlm = 0,
        };
    }

    fn dlab(self: *const SerialDevice) bool {
        return (self.lcr & LCR_DLAB) != 0;
    }

    pub fn hasRx(self: *const SerialDevice) bool {
        return self.rx_len != 0;
    }

    fn pushRxByte(self: *SerialDevice, byte: u8) void {
        if (self.rx_len == self.rx_fifo.len) {
            // Drop the oldest byte when the tiny FIFO overflows.
            // TODO: this needs to be done way better though
            self.rx_head = @intCast((@as(usize, self.rx_head) + 1) % self.rx_fifo.len);
            self.rx_len -= 1;
            std.debug.print("W: dropped a RX byte!\n", .{});
        }

        self.rx_fifo[(@as(usize, self.rx_head) + @as(usize, self.rx_len)) % self.rx_fifo.len] = byte;
        self.rx_len += 1;
        self.lsr |= LSR_DR;
    }

    fn popRxByte(self: *SerialDevice) u8 {
        if (self.rx_len == 0) return 0;

        const byte = self.rx_fifo[self.rx_head];
        self.rx_head = @intCast((@as(usize, self.rx_head) + 1) % self.rx_fifo.len);
        self.rx_len -= 1;

        if (self.rx_len == 0) self.lsr &= ~LSR_DR;
        return byte;
    }

    fn updateInterrupts(self: *SerialDevice, plic: ?*PlicState) void {
        var pending = false;

        if ((self.ier & IER_ERBFI) != 0 and self.hasRx()) {
            self.iir = IIR_RDA | IIR_CTYPE_16550A;
            pending = true;
        } else if ((self.ier & IER_ETBEI) != 0 and
            (self.lsr & LSR_THRE) != 0)
        {
            self.iir = IIR_THRE | IIR_CTYPE_16550A;
            pending = true;
        } else {
            self.iir = IIR_NO_INTERRUPT_PENDING | IIR_CTYPE_16550A;
        }

        if (plic) |p| {
            if (pending) {
                p.setInterruptPending(SERIAL_INTERRUPT_ID);
            } else {
                p.clearInterruptPending(SERIAL_INTERRUPT_ID);
            }
        }
    }
};

const ClintState = struct {
    const Self = @This();

    timer: std.time.Timer,
    mtimecmp: u64,

    fn init() !Self {
        return .{
            .timer = try std.time.Timer.start(),
            .mtimecmp = 0,
        };
    }

    pub fn getMtime(self: *Self) u64 {
        // TODO: un-hardcode frequency
        const freq_hz: comptime_int = 10_000_000;
        const elapsed_ns = @as(u128, self.timer.read());
        return @truncate((elapsed_ns * freq_hz) / std.time.ns_per_s);
    }

    pub fn getMtimecmp(self: *Self) u64 {
        return self.mtimecmp;
    }

    pub fn shouldInterrupt(self: *Self) bool {
        return self.getMtime() > self.mtimecmp;
    }
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
            serial: SerialDevice,
            plic: PlicState,
            clint: ClintState,
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
                .vtag = .{ .serial = SerialDevice.init(writer) },
            };
            return retval;
        }

        fn initClint(start_address: Tword) Self {
            const retval = Self {
                .start_address = start_address,
                .length = 0x1_0000,
                .vtag = .{ .clint = ClintState.init() catch @panic("Cannot init CLINT"), },
            };
            return retval;
        }

        fn initPlic(start_address: Tword) Self {
            const retval = Self {
                .start_address = start_address,
                .length = 0x1000000,
                .vtag = .{ .plic = .{
                    ._interrupts = .{
                        .{
                            .priority = 0,
                            .pending = false,
                        },
                    },
                    ._contexts = .{
                        .{
                            .interrupt_claimed = false,
                            .priority_threshold = 0,
                            .interrupts_enabled = .{false} ** INTERRUPT_COUNT,
                        },
                        .{
                            .interrupt_claimed = false,
                            .priority_threshold = 0,
                            .interrupts_enabled = .{false} ** INTERRUPT_COUNT,
                        },
                    },
                }, },
            };
            return retval;
        }
        
        fn deinit(self: *Self) void {
            switch (self.vtag) {
                .memory => |*m| { m.*.allocator.free(m.*.data); },
                .serial => { },
                .plic => { },
                .clint => { },
            }
        }

        fn readMemory(self: *Self, offset: Tword, dest: []u8) BusError!void {
            const length: Tword = @intCast(dest.len);
            if (offset + length >= self.length) {
                return error.AlignmentFault;
            }
            switch (self.vtag) {
                .memory => |*m| {
                    const s_offset: usize = @intCast(offset);
                    @memcpy(dest, m.data[s_offset..(s_offset+dest.len)]);
                },
                .serial => |*s| {
                    for (0..dest.len) |i| {
                        const byte_offset = offset + i;
                        switch (byte_offset) {
                            0 => dest[i] = if (s.dlab()) s.dll else s.popRxByte(), // DLL or RBR
                            1 => dest[i] = if (s.dlab()) s.dlm else s.ier, // DLM or IER
                            2 => dest[i] = s.iir, // IIR
                            3 => dest[i] = s.lcr, // LCR
                            4 => dest[i] = s.mcr, // MCR
                            5 => dest[i] = s.lsr, // LSR
                            7 => dest[i] = s.scr, // SCR
                            else => dest[i] = 0,
                        }
                    }
                },
                .plic => |*plic| {
                    if (dest.len != 4) return BusError.AlignmentFault;
                    const word = std.mem.littleToNative(
                        u32, try plic.getWord(@truncate(offset))
                    );
                    @memcpy(dest, std.mem.asBytes(&word));
                },
                .clint => |*clint| {
                    if (offset == 0x0 and dest.len == 4) {
                        const retval: u32 = 0;
                        @memcpy(dest, std.mem.asBytes(&retval));
                    } else if (offset == 0x4000 and dest.len == 8) {
                        const retval: u64 = clint.mtimecmp;
                        @memcpy(dest, std.mem.asBytes(&retval));
                    } else if (offset == 0xbff8 and dest.len == 8) {
                        const retval: u64 = clint.getMtime();
                        @memcpy(dest, std.mem.asBytes(&retval));
                    } else {
                        std.debug.print("W: access fault on CLINT\n", .{});
                        return error.AccessFault;
                    }
                },
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
                    for (src, 0..) |byte, i| {
                        const byte_offset = offset + i;
                        switch (byte_offset) {
                            0 => {
                                if (s.dlab()) {
                                    s.dll = byte;
                                } else {
                                    // THR write: transmitter becomes busy, then immediately
                                    // completes in this minimal model.
                                    s.lsr &= ~(SerialDevice.LSR_THRE | SerialDevice.LSR_TEMT);
                                    const written = s.writer.write(&[_]u8{byte}) catch @panic("Serial device write failed");
                                    std.debug.assert(written == 1);
                                    s.lsr |= SerialDevice.LSR_THRE | SerialDevice.LSR_TEMT;
                                }
                            },
                            1 => {
                                if (s.dlab()) {
                                    s.dlm = byte;
                                } else {
                                    // Keep only RX and THRE enable bits in this minimal model.
                                    s.ier = byte & (SerialDevice.IER_ERBFI | SerialDevice.IER_ETBEI);
                                }
                            },
                            2 => {
                                // FCR write: accept and ignore for now.
                            },
                            3 => s.lcr = byte,
                            4 => s.mcr = byte,
                            7 => s.scr = byte,
                            else => { },
                        }
                    }
                },
                // TODO: implement
                .plic => |*plic| {
                    if (src.len != 4) return BusError.AlignmentFault;
                    const word = std.mem.littleToNative(
                        u32, std.mem.bytesAsValue(u32, src).*
                    );
                    try plic.writeWord(@truncate(offset), word);
                },
                .clint => |*clint| {
                    if (offset == 0x0 and src.len == 4) {
                        std.debug.print("W: writing CLINT offset 0\n", .{});
                    } else if (offset == 0x4000 and src.len == 8) {
                        clint.mtimecmp = std.mem.readInt(u64, @ptrCast(src), .little);
                    } else if (offset == 0xbff8 and src.len == 8) {
                        // not implemented...
                        std.debug.assert(false);
                    } else {
                        std.debug.print("W: access fault on CLINT\n", .{});
                        return error.AccessFault;
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
        plic: struct {
            start: Tword
        },
        clint: struct {
            start: Tword
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

        pub fn makePlic(address_start: Tword) Self {
            return .{ .plic = .{
                .start = address_start,
            }};
        }

        pub fn makeClint(address_start: Tword) Self {
            return .{ .clint = .{
                .start = address_start,
            }};
        }
        
        fn buildDevice(self: *const Self, allocator: Allocator) !BusDevice(Tword) {
            return switch (self.*) {
                .memory => |*m| try BusDevice(Tword).initMemory(allocator, m.start, m.length),
                .serial => |*s| BusDevice(Tword).initSerial(s.start, s.output_device),
                .plic => |*p| BusDevice(Tword).initPlic(p.start),
                .clint => |*p| BusDevice(Tword).initClint(p.start),
            };
        }
    };
}

pub fn Bus(Tword: type) type {
    return struct {
        const DeviceArray = []BusDevice(Tword);

        devices: DeviceArray,

        const Self = @This();

        // TODO: assert there is no overlap
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

        // TODO: refactor so that bus reading is const
        // but now i cannot, as the PLIC belongs to the bus
        pub fn readMemory(self: *Self, address: Tword, dest: []u8) BusError!void {
            if (self.findDevice(address)) |dev| {
                try dev.readMemory(address - dev.start_address, dest);
                switch (dev.vtag) {
                    .serial => |*serial| {
                        serial.updateInterrupts(self.findPlic());
                    },
                    else => { },
                }
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
                switch (dev.vtag) {
                    .serial => |*serial| serial.updateInterrupts(self.findPlic()),
                    else => { },
                }
            } else {
                return error.AccessFault;
            }
        }

        fn writeWord(self: *Self, address: Tword, word: Tword) BusError!void {
            var bytes: [@sizeOf(Tword)]u8 = undefined;
            std.mem.writeInt(Tword, &bytes, word, LittleEndian);
            try self.writeMemory(address, &bytes);
        }

        pub fn findSerialDevice(self: *Self) ?*SerialDevice {
            for (self.devices) |*dev| {
                switch (dev.*.vtag) {
                    .serial => |*ser| return ser,
                    else => { },
                }
            }
            return null;
        }

        pub fn serialInputEmpty(self: *Self) bool {
            if (self.findSerialDevice()) |serial| {
                return serial.hasRx();
            }
            return false;
        }

        pub fn pushSerialInput(self: *Self, bytes: []const u8) void {
            if (self.findSerialDevice()) |serial| {
                for (bytes) |byte| serial.pushRxByte(byte);
                serial.updateInterrupts(self.findPlic());
            }
        }

        pub fn findClint(self: *Self) ?*ClintState {
            for (self.devices) |*dev| {
                switch (dev.*.vtag) {
                    .clint => |*clint| return clint,
                    else => { },
                }
            }
            return null;
        }

        pub fn findPlic(self: *Self) ?*PlicState {
            for (self.devices) |*dev| {
                switch (dev.*.vtag) {
                    .plic => |*plic| return plic,
                    else => { },
                }
            }
            return null;
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

        pub const AccessContext = struct {
            privilege: PrivilegeLevel,
            sum: bool,
            mxr: bool,
        };

        const VirtualAddress = packed struct {
            const Self = @This();

            page_offset: u12,
            vpn0: u9,
            vpn1: u9,
            vpn2: u9,
            padding: u25,

            fn isCanonical(self: *const Self) bool {
                const raw: u64 = @bitCast(self.*);
                const sign = (raw >> 38) & 1;
                const upper = raw >> 39;
                return if (sign == 0) upper == 0 else upper == ((@as(u64, 1) << 25) - 1);
            }

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

        pub const PageTableEntry = packed struct {
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

             fn isValid(self: *const Self) bool {
                return self.v != 0 and !(self.r == 0 and self.w == 1);
            }

            fn isLeaf(self: *const Self) bool {
                return self.r != 0 or self.x != 0;
            }

            fn hasReservedBitsSet(self: *const Self) bool {
                // This emulator does not implement Svnapot/Svpbmt/Svrsw60t59b yet.
                return self.n != 0 or self.pbmt != 0 or self.reserved != 0;
            }
        };

        pub fn getPageTableEntries(
            allocator: Allocator,
            bus: *Bus(Tword),
            ppn: u44,
        ) ![]struct {usize, PageTableEntry} {
            var buffer: [@sizeOf(PageTableEntry)]u8 = undefined;
            var result = std.ArrayList(struct {usize, PageTableEntry}).init(allocator);
            const ppn_tword = @as(Tword, ppn) * @as(Tword, PAGESIZE);
            for (0..(PAGESIZE/@sizeOf(PageTableEntry))) |i| {
                const addr = ppn_tword + i * @sizeOf(PageTableEntry);
                try bus.readMemory(
                    addr, &buffer
                );
                const pte = std.mem.littleToNative(PageTableEntry, @bitCast(buffer));
                // std.debug.print("Reading at 0x{x}: {any}\n", .{addr, pte});
                if (pte.v != 0) {
                    try result.append(.{i, pte});
                }
            }
            return result.toOwnedSlice();
        }

        pub fn translateAddress(
            bus: *Bus(Tword),
            va: VirtualAddress,
            ppn: u44,
            translation_reason: TranslationReason,
            access_ctx: AccessContext,
        ) TranslationError!Tword {
            if (!va.isCanonical()) return error.NonCanonicalVirtualAddress;

            var a: Tword = @as(Tword, ppn) * @as(Tword, PAGESIZE);
            var i: usize = LEVELS - 1;
            var pte: PageTableEntry = undefined;
            var pa = std.mem.zeroes(PhysicalAddress);
            var pte_addr: Tword = undefined;
            while (true) {
                var buffer: [@sizeOf(PageTableEntry)]u8 = undefined;
                const address_to_read = a + va.getVpn(i) * @sizeOf(PageTableEntry);
                pte_addr = address_to_read;
                bus.readMemory(
                    address_to_read,
                    &buffer
                ) catch return error.CannotReadPageTableEntry;
                pte = std.mem.littleToNative(PageTableEntry, @bitCast(buffer));
                if (!pte.isValid() or pte.hasReservedBitsSet()) {
                    return error.InvalidPTE;
                }
                if (pte.isLeaf()) {
                    break;
                }
                if (i == 0) return error.TranslationTooDeep;
                i -= 1;
                a = pte.ppn.getFull() * PAGESIZE;
            }

            const is_user_page = pte.u != 0;
            switch (access_ctx.privilege) {
                .User => if (!is_user_page) return error.DisallowedOperation,
                .Supervisor => {
                    if (is_user_page and translation_reason == .Execute) return error.DisallowedOperation;
                    if (is_user_page and !access_ctx.sum) return error.DisallowedOperation;
                },
                .Machine => {},
            }

            switch (translation_reason) {
                .Read => {
                    if (pte.r == 0 and !(access_ctx.mxr and pte.x != 0)) {
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

            if (pte.a == 0 or (translation_reason == .Write and pte.d == 0)) {
                pte.a = 1;
                if (translation_reason == .Write) pte.d = 1;
                var updated: [@sizeOf(PageTableEntry)]u8 = undefined;
                std.mem.writeInt(u64, &updated, @bitCast(pte), .little);
                bus.writeMemory(pte_addr, &updated) catch return error.CannotWritePageTableEntry;
            }

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
