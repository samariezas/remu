const std = @import("std");
const Allocator = std.mem.Allocator;
const LittleEndian = std.builtin.Endian.little;

fn toSigned(comptime T: type) type {
    if (T == u32) { return i32; }
    else if (T == u64) { return i64; }
    else { @panic("Wrong value"); }
}

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
            const length: Tword = @intCast(dest.len);
            @memcpy(dest, try self.getMemorySlice(address, length));
        }

        fn readWord(self: *Self, address: Tword) !Tword {
            var bytes: [@sizeOf(Tword)]u8 = undefined;
            try self.readMemory(address, &bytes);
            return std.mem.readInt(Tword, &bytes, LittleEndian);
        }

        fn writeMemory(self: *Self, address: Tword, src: []const u8) !void {
            const length: Tword = @intCast(src.len);
            @memcpy(try self.getMemorySlice(address, length), src);
        }

        fn writeWord(self: *Self, address: Tword, word: Tword) !void {
            var bytes: [@sizeOf(Tword)]u8 = undefined;
            std.mem.writeInt(Tword, &bytes, word, LittleEndian);
            try self.writeMemory(address, &bytes);
        }
    };
}

const InstructionID = union(enum) {
    none,
    funct_3: struct { funct3: u3 },
    funct_3_7: struct { funct3: u3, funct7: u7 },
};

const Instruction = struct {
    opcode: u7,
    id: InstructionID,

    fn makeNone(opcode: u7) Instruction {
        return .{
            .opcode = opcode,
            .id = InstructionID.none,
        };
    }

    fn makeF3(opcode: u7, funct3: u3) Instruction {
        return .{
            .opcode = opcode,
            .id = InstructionID { .funct_3 = .{ .funct3 = funct3 } },
        };
    }

    fn makeF37(opcode: u7, funct3: u3, funct7: u7) Instruction {
        return .{
            .opcode = opcode,
            .id = InstructionID { .funct_3_7 = .{ .funct3 = funct3, .funct7 = funct7 } },
        };
    }
};

pub const InstructionIdentifiers = packed struct {
    opcode: u7,
    unused1: u5,
    funct3: u3,
    unused2: u10,
    funct7: u7,
};

pub const RTypeInstruction = packed struct {
    opcode: u7,   
    rd: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    funct7: u7,
};

const ITypeInstruction = packed struct {
    opcode: u7,   
    rd: u5,
    funct3: u3,
    rs1: u5,
    imm: u12,
};

const STypeInstruction = packed struct {
    opcode: u7,
    imm1: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    imm2: u7,

    fn getImm(self: *const STypeInstruction) u12 {
        return self.imm1 | (self.imm2 >> 5);
    }
};

const UTypeInstruction = packed struct {
    opcode: u7,
    rd: u5,
    imm: u20,
};

const JTypeInstruction = packed struct {
    opcode: u7,
    rd: u5,
    imm1: u8,
    imm2: u1,
    imm3: u10,
    imm4: u1,

    fn getSign(self: *const JTypeInstruction) bool {
        return self.imm4 == 1;
    }

    fn getImm(self: *const JTypeInstruction) u21 {
        const imm1: u21 = @intCast(self.imm1);
        const imm2: u21 = @intCast(self.imm2);
        const imm3: u21 = @intCast(self.imm3);
        return (
            (imm1 << 12) |       
            (imm2 << 11) |
            (imm3 << 1)
        );
    }
};

const BTypeInstruction = packed struct {
    opcode: u7,
    imm1: u1,
    imm2: u4,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    imm3: u6,
    imm4: u1,

    fn getImm(self: *const BTypeInstruction) u13 {
        const imm1: u13 = @intCast(self.imm1);
        const imm2: u13 = @intCast(self.imm2);
        const imm3: u13 = @intCast(self.imm3);
        const imm4: u13 = @intCast(self.imm4);
        // std.debug.print("Imms parts: {} {} {} {}\n", .{imm1, imm2, imm3, imm4});
        return (
            (imm1 << 11) |
            (imm2 << 1) |
            (imm3 << 5) |
            (imm4 << 12)
        );
    }
};

pub fn RVCPU(comptime Tword: type) type {
    return struct {
        allocator: Allocator,
        registers: [32]Tword,
        pc: Tword,
        bus: Bus(Tword),

        const Self = @This();

        const InstructionHandler = fn (*Self, u32) void;

        const instructions = [_]struct{Instruction, *const InstructionHandler, bool} {
            .{Instruction.makeF37(0b0110011, 0, 0), handleAdd, true},
            .{Instruction.makeNone(0b1101111), handleJump, false},
            .{Instruction.makeF3(0b0010011, 0), handleAddImmediate, true},
            .{Instruction.makeF3(0b1100011, 1), handleBne, false},
            .{Instruction.makeF3(0b1100011, 0), handleBeq, false},
            // .{Instruction.makeNone(0b0010111), handleAuipc, true},
            // .{Instruction.makeF3(0b1110011, 2), handleCsrrs, true},
            // .{Instruction.makeF3(0b1110011, 1), handleCsrrw, true},
            // .{Instruction.makeF3(0b1110011, 5), handleCsrrwi, true},
            .{Instruction.makeNone(0b0110111), handleLui, true},
            .{Instruction.makeF3(0b0010011, 1), handleSlli, true},
            .{Instruction.makeF3(0b1100011, 4), handleBlt, false},
            .{Instruction.makeF3(0b1110011, 0), handleEcall, false},
            .{Instruction.makeF3(0b0010011, 6), handleOri, true},
        };

        fn getRegister(self: *Self, id: usize) Tword {
            return self.registers[id];
        }

        fn setRegister(self: *Self, id: usize, val: Tword) void {
            if (id != 0) {
                self.registers[id] = val;
            }
        }

        fn matches(id: InstructionIdentifiers, instruction: Instruction) bool {
            if (id.opcode != instruction.opcode) {
                return false;
            }
            switch (instruction.id) {
                .none => return true,
                .funct_3 => |*v| return v.funct3 == id.funct3,
                .funct_3_7 => |*v| return v.funct3 == id.funct3 and v.funct7 == id.funct7,
            }
            return false;
        }

        pub fn tick(self: *Self) !void {
            std.debug.assert(self.registers[0] == 0);
            const instruction = try self.getNextInstruction();
            const instruction_id: InstructionIdentifiers = @bitCast(instruction);
            std.debug.print("Instruction: PC=0x{X:0>8} Instr=0x{X:0>8}\n", .{self.pc, instruction});
            std.debug.print("Opcode=0b{b:0>7}; funct3=0x{X} funct7=0x{X}\n", .{instruction_id.opcode, instruction_id.funct3, instruction_id.funct7});
            for (instructions) |i| {
                if (matches(instruction_id, i[0])) {
                    i[1](self, instruction);
                    if (i[2]) {
                        self.pc += 4;
                    }
                    return;
                }
            }
            return error.UnknownInstruction;
        }

        fn getNextInstruction(self: *Self) !u32 {
            var bytes: [4]u8 = undefined;
            try self.bus.readMemory(self.pc, &bytes);
            return std.mem.readInt(u32, &bytes, LittleEndian);
        }

        fn handleAdd(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) + self.getRegister(parsed.rs2)
            );
        }

        fn handleAddImmediate(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) + parsed.imm
            );
        }

        fn handleJump(self: *Self, instruction: u32) void {
            const parsed: JTypeInstruction = @bitCast(instruction);
            self.setRegister(parsed.rd, self.pc + 4);
            const imm = parsed.getImm();
            if (parsed.getSign()) {
                self.pc -%= imm;
            } else {
                self.pc +%= imm;
            }
        }

        fn handleCsrrs(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            if (parsed.rs1 == 0 and parsed.imm == 0xf14) {
                self.setRegister(parsed.rd, 0);
            } else {
                std.debug.print("sveiki: 0x{X} 0x{X}\n", .{parsed.rs1, parsed.imm});
                @panic("loool");
            }
        }

        fn handleBlt(self: *Self, instruction: u32) void {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm();
            const reg1: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const reg2: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs2));
            std.debug.print("Imm: {}\n", .{imm});
            if (reg1 < reg2) {
                self.pc += imm;
            } else {
                self.pc += 4;
            }
        }

        fn handleAuipc(self: *Self, instruction: u32) void {
            const parsed: UTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.pc + (parsed.imm << 12)
            );
        }

        fn handleCsrrw(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            _ = self;
            std.debug.print("CSRRW values: {} {} 0x{X}\n", .{parsed.rd, parsed.rs1, parsed.imm});
            std.debug.assert(parsed.rd == 0);
            const allowed_imms = [_]u12{
                0x305,
                0x3b0,
                0x3a0,
                0x341
            };
            std.debug.assert(std.mem.containsAtLeastScalar(u12, &allowed_imms, 1, parsed.imm));
            std.debug.print("Skipping write to vector\n", .{});
        }

        fn handleCsrrwi(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            _ = self;
            std.debug.print("CSRRWI values: {} {} 0x{X}\n", .{parsed.rd, parsed.rs1, parsed.imm});
            std.debug.assert(parsed.rd == 0);
            const allowed_imms = [_]u12{
                0x180,
                0x744,
                0x304,
                0x302,
                0x303,
                0x300,
            };
            std.debug.assert(std.mem.containsAtLeastScalar(u12, &allowed_imms, 1, parsed.imm));
            std.debug.print("Skipping write to vector\n", .{});
        }

        fn handleLui(self: *Self, instruction: u32) void {
            const parsed: UTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                parsed.imm << 12
            );
        }

        fn handleSlli(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_split: packed struct {
                shift_len: u5,
                id: u7,
            } = @bitCast(parsed.imm);
            std.debug.assert(imm_split.id == 0);
            self.setRegister(
                parsed.rd,
                (self.getRegister(parsed.rs1) << imm_split.shift_len)
            );
        }

        fn handleBne(self: *Self, instruction: u32) void {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm();
            if (self.getRegister(parsed.rs1) != self.getRegister(parsed.rs2)) {
                self.pc += imm;
            } else {
                self.pc += 4;
            }
        }

        fn handleBeq(self: *Self, instruction: u32) void {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm();
            if (self.getRegister(parsed.rs1) == self.getRegister(parsed.rs2)) {
                self.pc += imm;
            } else {
                self.pc += 4;
            }
        }

        fn handleEcall(self: *Self, instruction: u32) void {
            _ = instruction;
            const a0_val = self.getRegister(10);
            if (a0_val != 0) {
                std.debug.print("Failed testcase #{}\n", .{a0_val / 2});
                std.process.exit(1);
            } else {
                std.debug.print("all gucci\n", .{});
                std.process.exit(0);
            }
        }

        fn handleOri(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) | parsed.imm
            );
        }

        pub fn loadBinary(self: *Self, entrypoint: Tword, buffer: []u8) !void {
            try self.bus.writeMemory(entrypoint, buffer);
        }

        pub fn init(allocator: Allocator, memory_start: Tword, memory_length: Tword) !RVCPU(Tword) {
            return .{
                .allocator = allocator,
                .registers = std.mem.zeroes([32]Tword),
                .pc = memory_start,
                .bus = try Bus(Tword).init(allocator, memory_start, memory_length),
            };
        }

        pub fn deinit(self: *Self) void {
            self.bus.deinit(self.allocator);
        }
    };
}

const rv32 = RVCPU(u32);
const rv64 = RVCPU(u64);

test "64bit bus operations" {
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

test "32bit bus operations" {
    const allocator = std.testing.allocator;
    const start: u32 = 0x0800_0000;
    const length: u32 = 0x0001_0000;
    var bus = try Bus(u32).init(allocator, start, length);
    defer bus.deinit(allocator);
    @memcpy(bus.memory[10..14], &[4]u8{ 0x12, 0x34, 0x56, 0x78 });
    const word = try bus.readWord(0x0800_000a);
    try std.testing.expectEqual(0x78563412, word);
    try bus.writeWord(0x0800_0a00, 0x1234);
    var buffer: [4]u8 = undefined;
    @memcpy(&buffer, bus.memory[0xa00..0xa04]);
    try std.testing.expectEqualSlices(u8, &[4]u8{ 0x34, 0x12, 0x00, 0x00 }, &buffer);
}

test "instruction decode" {
    const instr: u32 = 0x00c58733;
    const decoded: RTypeInstruction = @bitCast(instr);
    try std.testing.expectEqual(0b0110011, decoded.opcode);
    try std.testing.expectEqual(0, decoded.funct3);
    try std.testing.expectEqual(0, decoded.funct7);
    try std.testing.expectEqual(11, decoded.rs1);
    try std.testing.expectEqual(12, decoded.rs2);
    try std.testing.expectEqual(14, decoded.rd);
}

test "add tick" {
    const allocator = std.testing.allocator;
    var cpu = try rv32.init(allocator, 0x0800_0000, 0x0001_0000);
    defer cpu.deinit();
    // add a1,a1,a2
    try cpu.bus.writeMemory(0x0800_0000, &[4]u8{ 0xb3, 0x85, 0xc5, 0x00 });
    cpu.pc = 0x0800_0000;
    for (0..32) |i| {
        cpu.registers[i] = @intCast(i);
    }
    try cpu.tick();
    try std.testing.expectEqual(23, cpu.registers[11]);
    try std.testing.expectEqual(0x0800_0004, cpu.pc);
}
