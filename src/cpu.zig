const std = @import("std");
const Allocator = std.mem.Allocator;

fn Bus(comptime Tword: type) type {
    return struct {
        memory_start: Tword,
        memory: []u8,

        const Self = @This();

        pub fn init(allocator: Allocator, memory_start: Tword, memory_length: Tword) !Self {
            return .{
                .memory_start = memory_start,
                .memory = try allocator.alloc(u8, memory_length),
            };
        }

        fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.memory);
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

        fn readMemory(self: *Self, address: Tword, dest: []u8) !void {
            @memcpy(dest, try self.getMemorySlice(address, dest.len));
        }

        fn readWord(self: *Self, address: Tword) !Tword {
            var bytes: [@sizeOf(Tword)]u8 = undefined;
            try self.readMemory(address, &bytes);
            return std.mem.readInt(Tword, &bytes, std.builtin.Endian.little);
        }

        fn writeMemory(self: *Self, address: Tword, src: []const u8) !void {
            @memcpy(try self.getMemorySlice(address, src.len), src);
        }

        fn writeWord(self: *Self, address: Tword, word: Tword) !void {
            var bytes: [@sizeOf(Tword)]u8 = undefined;
            std.mem.writeInt(Tword, &bytes, word, std.builtin.Endian.little);
            try self.writeMemory(address, &bytes);
        }
    };
}

fn RVCPU(comptime Tword: type) type {
    return struct {
        allocator: Allocator,
        registers: [32]Tword,
        pc: Tword,
        bus: Bus(Tword),

        const Self = @This();

        fn init(allocator: Allocator, memory_start: Tword, memory_length: Tword) !RVCPU(Tword) {
            return .{
                .allocator = allocator,
                .registers = undefined,
                .pc = 0,
                .bus = try Bus(Tword).init(allocator, memory_start, memory_length),
            };
        }

        fn deinit(self: *Self) void {
            self.bus.deinit(self.allocator);
        }
    };
}

const rv64 = RVCPU(u64);

test "ram reading" {
    const allocator = std.testing.allocator;
    const start: u64 = 0x0800_0000;
    const length: u64 = 0x0001_0000;
    var bus = try Bus(u64).init(allocator, start, length);
    defer bus.deinit(allocator);
    @memcpy(bus.memory[10..18], &[8]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 });
    const word = try bus.readWord(0x0800_000a);
    try std.testing.expectEqual(0xf0debc9a78563412, word);
    try bus.writeWord(0x0800_0a00, 0x1234);
    var buffer: [8]u8 = undefined;
    @memcpy(&buffer, bus.memory[0xa00..0xa08]);
    try std.testing.expectEqualSlices(u8, &[8]u8{ 0x34, 0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, &buffer);
}
