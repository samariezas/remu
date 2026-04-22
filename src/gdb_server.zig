const std = @import("std");
const Allocator = std.mem.Allocator;
const CpuOptions = @import("cpu_config.zig").CpuOptions;
const RVCPU = @import("cpu.zig").RVCPU;
const Paging = @import("bus.zig").Paging;

pub const CpuState = enum {
    Paused,
    SingleTick,
    Running,
};

const Packet = struct {
    packet_end: usize,
    dropped: []const u8,
    payload: []const u8,
    checksum: []const u8,
};

const RxBuffer = struct {
    buffer: std.ArrayList(u8),

    fn init(allocator: Allocator) RxBuffer {
        return .{
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    fn deinit(self: *RxBuffer) void {
        self.buffer.deinit();
    }
    
    fn consume(self: *RxBuffer, slice: []const u8) !void {
        try self.buffer.appendSlice(slice);
    }

    fn findPacket(self: *const RxBuffer) ?Packet {
        const buffer = self.buffer.items;
        // std.debug.print("Have data: {} {s}\n", .{buffer.len, buffer});
        const start_symbol = std.mem.indexOfScalar(u8, buffer, '$');
        if (start_symbol) |start| {
            const end_symbol = std.mem.indexOfScalar(u8, buffer, '#');
            if (end_symbol) |end| {
                const checksum_end = end + 3;
                if (checksum_end <= buffer.len) {
                    const dropped_data = buffer[0..start];
                    const packet_field = buffer[(start+1)..end];
                    const checksum_field = buffer[(end+1)..checksum_end];
                    return .{
                        .packet_end = checksum_end,
                        .dropped = dropped_data,
                        .payload = packet_field,
                        .checksum = checksum_field,
                    };
                }
            }
        }
        return null;
    }

    fn shrink(self: *RxBuffer, packet: *const Packet) void {
        const new_size = self.buffer.items.len - packet.packet_end;
        std.mem.copyForwards(u8,
            self.buffer.items[0..new_size],
            self.buffer.items[packet.packet_end..self.buffer.items.len]
        );
        self.buffer.shrinkRetainingCapacity(new_size);
    }

    fn clear(self: *RxBuffer) void {
        self.buffer.clearRetainingCapacity();
    }
};

test "rx buffer" {
    const allocator = std.testing.allocator;
    var buffer = RxBuffer.init(allocator);
    defer buffer.deinit();
    const src_data = "+$foo#a";
    try buffer.consume(src_data);
    try std.testing.expectEqual(null, buffer.findPacket());
    try buffer.consume("b");
    const expected_packet = Packet {
        .packet_end = src_data.len + 1,
        .dropped = "+",
        .checksum = "ab",
        .payload = "foo",
    };
    try std.testing.expectEqualDeep(
        expected_packet, buffer.findPacket()
    );
    buffer.shrink(&buffer.findPacket().?);
    try std.testing.expectEqual(0, buffer.buffer.items.len);
    try buffer.consume(src_data);
    try buffer.consume("bbazbarboo");
    try std.testing.expectEqualDeep(
        expected_packet, buffer.findPacket()
    );
    buffer.shrink(&buffer.findPacket().?);
    try std.testing.expectEqualDeep("bazbarboo", buffer.buffer.items);
}

test "rx without leading" {
    const allocator = std.testing.allocator;
    var buffer = RxBuffer.init(allocator);
    defer buffer.deinit();
    const src_data = "$aboba#0";
    try buffer.consume(src_data);
    try std.testing.expectEqual(null, buffer.findPacket());
    try buffer.consume("1");
    const expected_packet = Packet {
        .packet_end = src_data.len + 1,
        .dropped = "",
        .checksum = "01",
        .payload = "aboba",
    };
    try std.testing.expectEqualDeep(
        expected_packet, buffer.findPacket()
    );
    buffer.shrink(&buffer.findPacket().?);
    try std.testing.expectEqual(0, buffer.buffer.items.len);
    try buffer.consume(src_data);
    try buffer.consume("1foobarbaz");
    try std.testing.expectEqualDeep(
        expected_packet, buffer.findPacket()
    );
    buffer.shrink(&buffer.findPacket().?);
    try std.testing.expectEqualDeep("foobarbaz", buffer.buffer.items);
}

pub const CsrNameValuePair = struct{ name: []const u8, value: u64 };
pub fn DebugInterface(opt: CpuOptions) type {
    const Tword = opt.getTword();
    return struct {
        const Self = @This();

        readRegisters: *const fn(*const RVCPU(opt)) [32]Tword,
        getPc: *const fn(*const RVCPU(opt)) Tword,
        readMemory: *const fn(*RVCPU(opt), Tword, []u8) Tword,
        getCsrs: *const fn(*const RVCPU(opt), Allocator) []CsrNameValuePair,
        getPPN: *const fn(*const RVCPU(opt)) u44,
        getPTEs: *const fn(*RVCPU(opt), Allocator, ppn: u44) ?[]struct {usize, Paging(Tword).PageTableEntry},
        translateAddress: *const fn(*RVCPU(opt), virtual_address: Tword) ?Tword,
    };
}

pub fn GdbDebugServer(opt: CpuOptions) type {
    const Tword = opt.getTword();
    const PollStreams = enum {
        GdbConnection,
    };

    return struct {
        const Self = @This();

        allocator: Allocator,
        rx_buffer: RxBuffer,
        breakpoints: std.ArrayList(Tword),
        socket_path: []const u8,
        socket_fd: std.posix.socket_t,
        client: std.fs.File,
        poller: std.io.Poller(PollStreams),
        cpu_state: CpuState,
        debug_interface: DebugInterface(opt),

        pub fn init(allocator: Allocator, path: []const u8, debug_interface: DebugInterface(opt)) !Self {
            const socket_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
            var sockaddr: std.posix.sockaddr.un = .{ .path = undefined, };
            @memcpy(sockaddr.path[0..(path.len)], path);
            sockaddr.path[path.len] = 0;
            sockaddr.family = std.posix.AF.UNIX;
            try std.posix.bind(socket_fd, @ptrCast(&sockaddr), @sizeOf(@TypeOf(sockaddr)));
            try std.posix.listen(socket_fd, 1);
            std.debug.print("Waiting for connection...\n", .{});
            const client_fd = try std.posix.accept(socket_fd, null, null, std.posix.SOCK.NONBLOCK);
            std.debug.print("Debugger connected\n", .{});
            const client = std.fs.File {
                .handle = client_fd,
            };
            return .{
                .allocator = allocator,
                .rx_buffer = RxBuffer.init(allocator),
                .breakpoints = std.ArrayList(Tword).init(allocator),
                .socket_path = try allocator.dupe(u8, path),
                .socket_fd = socket_fd,
                .client = client,
                .poller = std.io.poll(
                    allocator,
                    PollStreams,
                    .{ .GdbConnection = client, },
                ),
                .cpu_state = .Paused,
                .debug_interface = debug_interface,
            };
        }

        pub fn deinit(self: *Self) void {
            self.rx_buffer.deinit();
            self.breakpoints.deinit();
            self.allocator.deinit(self.socket_path);
            std.posix.close(self.socket_fd);
            self.client.close();
            self.poller.deinit();
        }

        pub fn poll(self: *Self, cpu: *RVCPU(opt)) !bool {
            return switch (try self.pollInner(cpu)) {
                .SingleTick,
                .Running => true,

                .Paused => false,
            };
        }

        fn pollInner(self: *Self, cpu: *RVCPU(opt)) !CpuState {
            switch (self.cpu_state) {
                .SingleTick => {
                    self.cpu_state = .Paused;
                    return .SingleTick;
                },
                .Running => {
                    const pc = self.debug_interface.getPc(cpu);
                    if (std.mem.indexOfScalar(Tword, self.breakpoints.items, pc) != null) {
                        self.cpu_state = .Paused;
                        try self.sendResponse("S05");
                    }
                },
                .Paused => { },
            }
            var buffer: [1024]u8 = undefined;
            const buffer_read = self.client.read(&buffer) catch |err| switch (err) {
                error.WouldBlock => return self.cpu_state,
                else => return err,
            };
            if (buffer_read == 0) return self.cpu_state;
            try self.rx_buffer.consume(buffer[0..buffer_read]);
            if (self.rx_buffer.findPacket()) |packet| {
                try self.handlePacket(&packet, cpu);
                self.rx_buffer.shrink(&packet);
            }
            // std.debug.print("W: Trying CTRL-C: {any}\n", .{self.rx_buffer.buffer.items});
            if (std.mem.indexOfScalar(u8, self.rx_buffer.buffer.items, 0x3) != null) {
                // std.debug.print("W: received CTRL-C\n", .{});
                self.cpu_state = .Paused;
                self.rx_buffer.clear();
                try self.sendResponse("S05");
            }
            return self.cpu_state;
        }

        fn printHex(out: *std.ArrayList(u8), comptime format_str: []const u8, args: anytype) void {
            var formatted_str_buffer: [256]u8 = undefined;
            var hex_str_buffer: [512]u8 = undefined;
            const formatted_str = std.fmt.bufPrint(&formatted_str_buffer, format_str, args)
                catch @panic("Did not fit into buffer");
            const hex_str = std.fmt.bufPrint(&hex_str_buffer, "{s}", .{std.fmt.fmtSliceHexUpper(formatted_str)})
                catch @panic("Did not fit into buffer");
            out.*.appendSlice(hex_str)
                catch @panic("buy more ram");
        }

        // TODO: verify checksums
        // TODO: holy shit...
        fn handlePacket(self: *Self, packet: *const Packet, cpu: *RVCPU(opt)) !void {
            if (packet.dropped.len != 0) std.debug.print("W: dropped {} bytes of data: {s}\n", .{packet.dropped.len, packet.dropped});

            // const arena = std.heap.ArenaAllocator.init(self.allocator);
            // defer arena.deinit();
            // const allocator = arena.allocator();

            std.debug.print("Packet: {s}\n", .{packet.payload});
            if (std.mem.startsWith(u8, packet.payload, "qSupported")) {
                try self.sendResponse("PacketSize=4000;swbreak-;hwbreak+;vContSupported");
            } else if (std.mem.startsWith(u8, packet.payload, "vCont?")) {
                try self.sendResponse("vCont;cs");
            } else if (std.mem.startsWith(u8, packet.payload, "Z0")) {
                try self.sendResponse("E.not supported");
            } else if (std.mem.startsWith(u8, packet.payload, "?")) {
                try self.sendResponse("S05");
            } else if (std.mem.startsWith(u8, packet.payload, "vCont")) {
                const action = packet.payload[5];
                switch (action) {
                    'c' => self.cpu_state = .Running,
                    's' => self.cpu_state = .SingleTick,
                    else => try self.sendUnknown(packet),
                }
            } else if (std.mem.eql(u8, packet.payload, "c")) {
                self.cpu_state = .Running;
                try self.sendResponse("OK");
            } else if (std.mem.startsWith(u8, packet.payload, "g")) {
                try self.transmitRegisters(cpu);
            } else if (std.mem.startsWith(u8, packet.payload, "m")) {
                var it = std.mem.splitScalar(u8, packet.payload, ',');
                const addr_str = it.next() orelse @panic("Missing address field");
                const length_str = it.next() orelse @panic("Missing length field");
                std.debug.assert(it.next() == null);
                const addr = std.fmt.parseInt(Tword, addr_str[1..], 16) catch @panic("Cannot parse hex int");
                const length = std.fmt.parseInt(Tword, length_str, 16) catch @panic("Cannot parse hex int");
                try self.transmitMemory(addr, length, cpu);
            } else if (std.mem.startsWith(u8, packet.payload, "Z1") or std.mem.startsWith(u8, packet.payload, "z1")) {
                var it = std.mem.splitScalar(u8, packet.payload, ',');
                const head = it.next() orelse @panic("Missing packet head");
                const addr_str = it.next() orelse @panic("Missing address field");
                const length_str = it.next() orelse @panic("Missing length field");
                std.debug.assert(it.next() == null);
                const addr = std.fmt.parseInt(Tword, addr_str, 16) catch @panic("Cannot parse hex int");
                _ = std.fmt.parseInt(Tword, length_str, 16) catch @panic("Cannot parse hex int");
                // std.debug.assert(length == 4);
                if (std.mem.eql(u8, head, "Z1")) {
                    try self.appendBreakpoint(addr);
                } else {
                    self.removeBreakpoint(addr);
                }
                try self.sendResponse("OK");
            } else if (std.mem.startsWith(u8, packet.payload, "qRcmd")) {
                const custom_payload_hex = packet.payload[6..];
                var custom_payload = try self.allocator.alloc(u8, @divExact(custom_payload_hex.len, 2));
                defer self.allocator.free(custom_payload);
                for (0..custom_payload.len) |i| {
                    custom_payload[i] = try std.fmt.parseInt(u8, custom_payload_hex[(2*i)..(2*(i+1))], 16);
                }
                var write_buffer = std.ArrayList(u8).init(self.allocator);
                defer write_buffer.deinit();
                if (std.mem.eql(u8, custom_payload, "csrs")) {
                    const csrs = self.debug_interface.getCsrs(cpu, self.allocator);
                    defer self.allocator.free(csrs);
                    for (csrs) |csr| {
                        printHex(&write_buffer, "{s}: {x}\n", .{csr.name, csr.value});
                    }
                } else if (std.mem.startsWith(u8, custom_payload, "mempages")) {
                    var space_it = std.mem.splitScalar(u8, custom_payload, ' ');
                    _ = space_it.next();
                    const ppn_: ?u44 = if (space_it.next()) |ppn_str|
                        std.fmt.parseInt(u44, ppn_str, 16) catch null
                        else self.debug_interface.getPPN(cpu);

                    if (ppn_) |ppn| {
                        printHex(&write_buffer, "PTEs @{x}:\n", .{ppn});
                        const mem_map = self.debug_interface.getPTEs(cpu, self.allocator, ppn);
                        if (mem_map) |mmap| {
                            defer self.allocator.free(mmap);
                            for (mmap) |mm| {
                                const index, const pte = mm;
                                printHex(&write_buffer, "{x:0<3}: {x} r{s}w{s}x{s}", .{
                                    index,
                                    @as(u44, @bitCast(pte.ppn)),
                                    if (pte.r != 0) "+" else "-",
                                    if (pte.w != 0) "+" else "-",
                                    if (pte.x != 0) "+" else "-",
                                });
                                if (pte.r != 0 or pte.w != 0 or pte.x != 0) printHex(&write_buffer, " {any}", .{pte});
                                printHex(&write_buffer, "\n", .{});
                            }
                        } else {
                            printHex(&write_buffer, "Cannot get memory map\n", .{});
                        }
                    } else {
                        printHex(&write_buffer, "Cannot print out \n", .{});
                    }
                } else if (std.mem.eql(u8, custom_payload, "step")) {
                    self.cpu_state = .SingleTick;
                    printHex(&write_buffer, "Doing single tick\n", .{});
                } else if (std.mem.startsWith(u8, custom_payload, "translate")) {
                    var space_it = std.mem.splitScalar(u8, custom_payload, ' ');
                    _ = space_it.next();
                    if (space_it.next()) |virtual_address| {
                        if (std.fmt.parseInt(Tword, virtual_address, 16) catch null) |parsed| {
                            if (self.debug_interface.translateAddress(cpu, parsed)) |translated| {
                                printHex(&write_buffer, "Translated address: {x}\n", .{translated});
                            } else {
                                printHex(&write_buffer, "Cannot translate: {x}\n", .{parsed});
                            }
                        } else {
                            printHex(&write_buffer, "Cannot parse address: {s}\n", .{virtual_address});
                        }
                    } else {
                        printHex(&write_buffer, "No address provided\n", .{});
                    }
                } else {
                    printHex(&write_buffer, "Unknown command `{s}`\n", .{custom_payload});
                }
                try self.sendResponse(write_buffer.items);
            } else {
                try self.sendUnknown(packet);
            }
        }

        fn appendBreakpoint(self: *Self, addr: Tword) !void {
            try self.breakpoints.append(addr);
        }

        fn removeBreakpoint(self: *Self, addr: Tword) void {
            while (std.mem.indexOfScalar(Tword, self.breakpoints.items, addr)) |idx| {
                _ = self.breakpoints.swapRemove(idx);
            }
        }

        fn transmitRegisters(self: *Self, cpu: *RVCPU(opt)) !void {
            const registers = self.debug_interface.readRegisters(cpu);
            const pc = self.debug_interface.getPc(cpu);
            var buffer: [(@sizeOf(@TypeOf(registers))+@sizeOf(@TypeOf(pc)))*2]u8 = undefined;
            const result = std.fmt.bufPrint(&buffer, "{s}{s}", .{
                std.fmt.fmtSliceHexLower(std.mem.sliceAsBytes(&registers)),
                std.fmt.fmtSliceHexLower(std.mem.asBytes(&pc)),
            }) catch @panic("Buffer too small!");
            try self.sendResponse(result);
        }

        fn transmitMemory(self: *Self, addr: Tword, length: Tword, cpu: *RVCPU(opt)) !void {
            std.debug.print("Reading: {x} bytes @{x}\n", .{length, addr});
            const buffer = try self.allocator.alloc(u8, length);
            const output_buffer = try self.allocator.alloc(u8, length*2);
            defer {
                self.allocator.free(buffer);
                self.allocator.free(output_buffer);
            }
            const memory_read = self.debug_interface.readMemory(cpu, addr, buffer);
            const result = std.fmt.bufPrint(output_buffer, "{s}", .{std.fmt.fmtSliceHexLower(buffer[0..memory_read])})
                catch @panic("Failed formatting memory read buffer");
            try self.sendResponse(result);
        }

        fn sendUnknown(self: *Self, packet: *const Packet) !void {
            std.debug.print("W: unknown packet {s}\n", .{packet.payload});
            return self.sendResponse("");
        }

        fn sendResponse(self: *Self, response: []const u8) !void {
            var checksum: u8 = 0;
            for (response) |char| {
                checksum +%= char;
            }
            // std.debug.print("Sending response: {s}\n", .{response});
            const client_writer = self.client.writer();
            var buffered_writer_outer = std.io.bufferedWriter(client_writer);
            var buffered_writer = buffered_writer_outer.writer();
            try buffered_writer.writeAll("+$");
            try buffered_writer.writeAll(response);
            try buffered_writer.writeAll("#");
            try buffered_writer.print("{s}", .{std.fmt.fmtSliceHexLower(&[_]u8{ checksum })});
            try buffered_writer_outer.flush();
        }
    };
}
