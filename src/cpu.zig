const std = @import("std");
const Allocator = std.mem.Allocator;
const LittleEndian = std.builtin.Endian.little;

fn toSigned(comptime T: type) type {
    return std.meta.Int(.signed, @typeInfo(T).int.bits);
}

fn signExtend(comptime T: type, val: anytype) T {
    // TODO: assertions about types
    const SignedOriginalType = toSigned(@TypeOf(val)); //i12
    const SignedExtendedType = toSigned(T);            //i32
    const signed: SignedOriginalType = @bitCast(val);  //bitcast to i12
    const signed_extended: SignedExtendedType = @intCast(signed); //extend to i32
    return @bitCast(signed_extended);                  //return u32
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

fn InstructionDescriptor(comptime Tword: type) type {
    return struct {
        const InstructionHandler = *const fn (*RVCPU(Tword), u32) void;
        const WriterHandler = *const fn (std.io.AnyWriter, u32) anyerror!void;

        opcode: u7,
        id: InstructionID,
        handler: InstructionHandler,
        name: []const u8,
        advance_pc: bool,
        writer_fn: ?WriterHandler,

        const Self = @This();

        fn print(self: *const Self, writer: std.io.AnyWriter, instruction: u32) !void {
            std.debug.assert((instruction & 0x7f) == self.opcode);
            if (self.writer_fn) |writer_fn| {
                try writer.print("{s} ", .{self.name});
                try writer_fn(writer, instruction);
                try writer.writeAll("\n");
            } else {
                try writer.print("{s} ???\n", .{self.name});
            }
        }

        fn makeNone(name: []const u8, opcode: u7, handler: InstructionHandler, writer_fn: ?WriterHandler, advance_pc: bool) Self {
            return .{
                .opcode = opcode,
                .id = InstructionID.none,
                .handler = handler,
                .name = name,
                .advance_pc = advance_pc,
                .writer_fn = writer_fn,
            };
        }

        fn makeF3(name: []const u8, opcode: u7, funct3: u3, handler: InstructionHandler, writer_fn: ?WriterHandler, advance_pc: bool) Self {
            return .{
                .opcode = opcode,
                .id = InstructionID { .funct_3 = .{ .funct3 = funct3 } },
                .handler = handler,
                .name = name,
                .advance_pc = advance_pc,
                .writer_fn = writer_fn,
            };
        }

        fn makeF37(name: []const u8, opcode: u7, funct3: u3, funct7: u7, handler: InstructionHandler, writer_fn: ?WriterHandler, advance_pc: bool) Self {
            return .{
                .opcode = opcode,
                .id = InstructionID { .funct_3_7 = .{ .funct3 = funct3, .funct7 = funct7 } },
                .handler = handler,
                .name = name,
                .advance_pc = advance_pc,
                .writer_fn = writer_fn,
            };
        }
    };
}

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

    fn write(writer: std.io.AnyWriter, instruction: u32) anyerror!void {
        const decoded: @This() = @bitCast(instruction);
        try writer.print("x{}, x{}, x{}", .{decoded.rd, decoded.rs1, decoded.rs2});
    }
};

const ITypeInstruction = packed struct {
    opcode: u7,   
    rd: u5,
    funct3: u3,
    rs1: u5,
    imm: u12,

    fn write(writer: std.io.AnyWriter, instruction: u32) anyerror!void {
        const decoded: @This() = @bitCast(instruction);
        try writer.print("x{}, x{}, {}", .{decoded.rd, decoded.rs1, decoded.imm});
    }
};

const STypeInstruction = packed struct {
    opcode: u7,
    imm1: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    imm2: u7,

    fn getImm(self: *const STypeInstruction) u12 {
        const imm1: u12 = @intCast(self.imm1);
        const imm2: u12 = @intCast(self.imm2);
        return imm1 | (imm2 << 5);
    }

    fn write(writer: std.io.AnyWriter, instruction: u32) anyerror!void {
        const decoded: @This() = @bitCast(instruction);
        const signed: i12 = @bitCast(decoded.getImm());
        try writer.print("x{}, {}(x{})", .{decoded.rs2, signed, decoded.rs1});
    }
};

const UTypeInstruction = packed struct {
    opcode: u7,
    rd: u5,
    imm: u20,

    fn write(writer: std.io.AnyWriter, instruction: u32) anyerror!void {
        const decoded: @This() = @bitCast(instruction);
        try writer.print("x{}, 0x{x}", .{decoded.rd, decoded.imm});
    }
};

const JTypeInstruction = packed struct {
    opcode: u7,
    rd: u5,
    imm1: u8,
    imm2: u1,
    imm3: u10,
    imm4: u1,

    fn getImm(self: *const JTypeInstruction, Tword: type) Tword {
        const imm1: u21 = @intCast(self.imm1);
        const imm2: u21 = @intCast(self.imm2);
        const imm3: u21 = @intCast(self.imm3);
        const imm4: u21 = @intCast(self.imm3);
        const retval = (
            (imm1 << 12) |       
            (imm2 << 11) |
            (imm3 << 1)  |
            (imm4 << 20)
        );
        return signExtend(Tword, retval);
    }

    fn write(writer: std.io.AnyWriter, instruction: u32) anyerror!void {
        const decoded: @This() = @bitCast(instruction);
        const sign = (if (decoded.getSign()) "+" else "-");
        _ = writer;
        _ = sign;
        // try w iter.print("{s}0x{x:0>8}", .{sign, decoded.getImm()});
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

    fn getImm(self: *const BTypeInstruction, Tword: type) Tword {
        const imm1: u13 = @intCast(self.imm1);
        const imm2: u13 = @intCast(self.imm2);
        const imm3: u13 = @intCast(self.imm3);
        const imm4: u13 = @intCast(self.imm4);
        const retval = (
            (imm1 << 11) |
            (imm2 << 1) |
            (imm3 << 5) |
            (imm4 << 12)
        );
        return signExtend(Tword, retval);
    }
};

pub fn TestResult(comptime Tword: type) type {
    return struct {
        const Self = @This();

        a0: Tword,
        signature_address: ?struct {
            start: Tword,
            length: Tword,
        },

        pub fn is_success(self: *const Self) bool {
            return self.a0 == 0;
        }
    };
}

pub fn RVCPU(comptime Tword: type) type {
    return struct {
        allocator: Allocator,
        registers: [32]Tword,
        pc: Tword,
        bus: Bus(Tword),
        test_result: ?TestResult(Tword),
        writer: std.io.AnyWriter,

        const Self = @This();

        const Instr = InstructionDescriptor(Tword);

        const instructions = [_]Instr {
            Instr.makeF37("ADD", 0b0110011, 0, 0, handleAdd, RTypeInstruction.write, true),
            Instr.makeNone("JAL", 0b1101111, handleJump, null, false),
            Instr.makeF3("JALR", 0b1100111, 0, handleJalr, null, false),
            Instr.makeF3("ADDI", 0b0010011, 0, handleAddImmediate, ITypeInstruction.write, true),
            Instr.makeF3("BNE", 0b1100011, 1, handleBne, null, false),
            Instr.makeF3("BEQ", 0b1100011, 0, handleBeq, null, false),
            Instr.makeNone("LUI", 0b0110111, handleLui, UTypeInstruction.write, true),
            Instr.makeF3("SLLI", 0b0010011, 1, handleSlli, null, true),
            Instr.makeF3("SRAI", 0b0010011, 5, handleSrai, null, true),
            Instr.makeF3("BLT", 0b1100011, 4, handleBlt, null, false),
            Instr.makeF3("BGE", 0b1100011, 5, handleBge, null, false),
            Instr.makeF3("BLTU", 0b1100011, 6, handleBltu, null, false),
            Instr.makeF3("BGEU", 0b1100011, 7, handleBgeu, null, false),
            Instr.makeF3("ECALL", 0b1110011, 0, handleEcall, null, false),
            Instr.makeNone("AUIPC", 0b0010111, handleAuipc, null, true),
            Instr.makeF37("SUB", 0b0110011, 0, 0x20, handleSub, RTypeInstruction.write, true),
            Instr.makeF3("SB", 0b0100011, 0, handleSb, STypeInstruction.write, true),
            Instr.makeF3("SH", 0b0100011, 1, handleSh, STypeInstruction.write, true),
            Instr.makeF3("SW", 0b0100011, 2, handleSw, STypeInstruction.write, true),
            Instr.makeF3("LB", 0b0000011, 0, handleLb, ITypeInstruction.write, true),
            Instr.makeF3("LH", 0b0000011, 1, handleLh, ITypeInstruction.write, true),
            Instr.makeF3("LW", 0b0000011, 2, handleLw, ITypeInstruction.write, true),
            Instr.makeF3("LBU", 0b0000011, 4, handleLbu, ITypeInstruction.write, true),
            Instr.makeF3("LHU", 0b0000011, 5, handleLhu, ITypeInstruction.write, true),
            Instr.makeF37("AND", 0b0110011, 7, 0, handleAnd, RTypeInstruction.write, true),
            Instr.makeF37("OR", 0b0110011, 6, 0, handleOr, RTypeInstruction.write, true),
            Instr.makeF37("XOR", 0b0110011, 4, 0, handleXor, RTypeInstruction.write, true),
            Instr.makeF3("ANDI", 0b0010011, 7, handleAndi, ITypeInstruction.write, true),
            Instr.makeF3("ORI", 0b0010011, 6, handleOri, null, true),
            Instr.makeF3("XORI", 0b0010011, 4, handleXori, RTypeInstruction.write, true),
            Instr.makeF37("SLL", 0b0110011, 1, 0, handleSll, null, true),
            Instr.makeF37("SRL", 0b0110011, 5, 0, handleSrl, null, true),
            Instr.makeF37("SRA", 0b0110011, 5, 0x20, handleSra, null, true),
            Instr.makeF37("SLT", 0b0110011, 2, 0, handleSlt, null, true),
            Instr.makeF37("SLTU", 0b0110011, 3, 0, handleSltu, null, true),
            Instr.makeF3("SLTI", 0b0010011, 2, handleSlti, null, true),
            Instr.makeF3("SLTIU", 0b0010011, 3, handleSltiu, null, true),
            Instr.makeF3("FENCE", 0b0001111, 0, handleNop, null, true),
            Instr.makeF3("FENCE.I", 0b0001111, 1, handleNop, null, true),
        };

        fn getRegister(self: *Self, id: usize) Tword {
            return self.registers[id];
        }

        fn setRegister(self: *Self, id: usize, val: Tword) void {
            if (id != 0) {
                self.registers[id] = val;
            }
        }

        fn matches(id: InstructionIdentifiers, instruction: *const Instr) bool {
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

        fn writeRegisters(self: *Self, writer: std.io.AnyWriter, width: usize) !void {
            for (0..self.registers.len) |i| {
                var buffer: [16]u8 = undefined;
                const sep = if ((i + 1) % width == 0) "\n" else " ";
                const register_name = try std.fmt.bufPrint(&buffer, "x{}", .{i});
                try writer.print("{s: >3}={x:0>8}{s}", .{register_name, self.registers[i], sep});
            }
        }

        pub fn tick(self: *Self) !void {
            std.debug.assert(!self.isHalted());
            std.debug.assert(self.registers[0] == 0);
            const instruction = try self.getNextInstruction();
            const instruction_id: InstructionIdentifiers = @bitCast(instruction);
            try self.writer.print("Instruction: PC=0x{x:0>8} Instr=0x{x:0>8}\n", .{self.pc, instruction});
            try self.writer.print("Opcode=0b{b:0>7}; funct3=0x{X} funct7=0x{X}\n", .{instruction_id.opcode, instruction_id.funct3, instruction_id.funct7});
            for (instructions) |i| {
                if (matches(instruction_id, &i)) {
                    try i.print(self.writer, instruction);
                    i.handler(self, instruction);
                    try self.writeRegisters(self.writer, 4);
                    if (i.advance_pc) {
                        self.pc += 4;
                    }
                    try self.writer.writeAll("\n");
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
                self.getRegister(parsed.rs1) +% self.getRegister(parsed.rs2)
            );
        }

        fn handleSub(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) -% self.getRegister(parsed.rs2)
            );
        }

        fn handleAddImmediate(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_signed = signExtend(Tword, parsed.imm);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) +% imm_signed
            );
        }

        fn handleJump(self: *Self, instruction: u32) void {
            const parsed: JTypeInstruction = @bitCast(instruction);
            self.setRegister(parsed.rd, self.pc + 4);
            const imm = parsed.getImm(Tword);
            self.pc +%= imm;
        }

        fn handleJalr(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const new_pc = self.getRegister(parsed.rs1) +% signExtend(Tword, parsed.imm);
            self.setRegister(parsed.rd, self.pc + 4);
            self.pc = new_pc;
        }

        fn handleBlt(self: *Self, instruction: u32) void {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm(Tword);
            const reg1: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const reg2: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs2));
            if (reg1 < reg2) {
                self.pc +%= imm;
            } else {
                self.pc +%= 4;
            }
        }

        fn handleBge(self: *Self, instruction: u32) void {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm(Tword);
            const reg1: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const reg2: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs2));
            if (reg1 >= reg2) {
                self.pc +%= imm;
            } else {
                self.pc +%= 4;
            }
        }

        fn handleBltu(self: *Self, instruction: u32) void {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm(Tword);
            if (self.getRegister(parsed.rs1) < self.getRegister(parsed.rs2)) {
                self.pc +%= imm;
            } else {
                self.pc +%= 4;
            }
        }

        fn handleBgeu(self: *Self, instruction: u32) void {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm(Tword);
            if (self.getRegister(parsed.rs1) >= self.getRegister(parsed.rs2)) {
                self.pc +%= imm;
            } else {
                self.pc +%= 4;
            }
        }

        fn handleLui(self: *Self, instruction: u32) void {
            const parsed: UTypeInstruction = @bitCast(instruction);
            const imm: Tword = @intCast(parsed.imm);
            self.setRegister(
                parsed.rd,
                imm << 12
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

        fn handleSrai(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_split: packed struct {
                shift_len: u5,
                id: u7,
            } = @bitCast(parsed.imm);
            const src = self.getRegister(parsed.rs1);
            var result: Tword = undefined;
            if (imm_split.id == 0x20) { // shift arithmetic
                const signed: toSigned(Tword) = @bitCast(src);
                const shifted = signed >> imm_split.shift_len;
                result = @bitCast(shifted);
            } else if (imm_split.id == 0x00) { // shift logical
                result = src >> imm_split.shift_len;
            } else unreachable;
            self.setRegister(parsed.rd, result);
        }

        fn handleBne(self: *Self, instruction: u32) void {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm(Tword);
            if (self.getRegister(parsed.rs1) != self.getRegister(parsed.rs2)) {
                self.pc +%= imm;
            } else {
                self.pc += 4;
            }
        }

        fn handleBeq(self: *Self, instruction: u32) void {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm(Tword);
            if (self.getRegister(parsed.rs1) == self.getRegister(parsed.rs2)) {
                self.pc +%= imm;
            } else {
                self.pc += 4;
            }
        }

        fn handleEcall(self: *Self, instruction: u32) void {
            _ = instruction;
            std.debug.assert(!self.isHalted());
            const memory_start = self.getRegister(11);
            const memory_end = self.getRegister(12);
            self.test_result = TestResult(Tword) {
                .a0 = self.getRegister(10),
                .signature_address = if (memory_start == memory_end) null else .{
                    .start = memory_start,
                    .length = memory_end - memory_start,
                },
            };
        }

        fn handleAndi(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) & signExtend(Tword, parsed.imm)
            );
        }

        fn handleOri(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) | signExtend(Tword, parsed.imm)
            );
        }

        fn handleXori(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) ^ signExtend(Tword, parsed.imm)
            );
        }

        fn handleAuipc(self: *Self, instruction: u32) void {
            const parsed: UTypeInstruction = @bitCast(instruction);
            const imm_word: Tword = @intCast(parsed.imm);
            self.setRegister(
                parsed.rd,
                self.pc +% (imm_word << 12)
            );
        }

        fn genericStoreHandler(self: *Self, T: type, instruction: u32) void {
            const bitcnt = @typeInfo(T).int.bits;
            const parsed: STypeInstruction = @bitCast(instruction);
            const imm_extended = signExtend(Tword, parsed.getImm());
            const address = self.getRegister(parsed.rs1) +% imm_extended;
            var to_write: [@typeInfo(Tword).int.bits/8]u8 = undefined;
            std.mem.writeInt(Tword, &to_write, self.getRegister(parsed.rs2), LittleEndian);
            // TODO: proper errors
            self.bus.writeMemory(address, to_write[0..(bitcnt/8)]) catch @panic("Cannot write");
        }

        fn genericLoadHandler(self: *Self, T: type, instruction: u32, comptime sign_extend: bool) void {
            const bitcnt = @typeInfo(T).int.bits;
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_extended = signExtend(Tword, parsed.imm);
            const address = self.getRegister(parsed.rs1) +% imm_extended;
            var bytes_read: [bitcnt/8]u8 = undefined;
            // TODO: proper errors
            self.bus.readMemory(address, &bytes_read) catch @panic("Cannot write");
            const read_memory: T = std.mem.readInt(T, &bytes_read, LittleEndian);
            const result: Tword = if (sign_extend) signExtend(Tword, read_memory) else @intCast(read_memory);
            self.setRegister(parsed.rd, result);
        }

        fn handleSb(self: *Self, instruction: u32) void {
            self.genericStoreHandler(u8, instruction);
        }

        fn handleSh(self: *Self, instruction: u32) void {
            self.genericStoreHandler(u16, instruction);
        }

        fn handleSw(self: *Self, instruction: u32) void {
            self.genericStoreHandler(u32, instruction);
        }

        fn handleLb(self: *Self, instruction: u32) void {
            self.genericLoadHandler(u8, instruction, true);
        }

        fn handleLh(self: *Self, instruction: u32) void {
            self.genericLoadHandler(u16, instruction, true);
        }

        fn handleLw(self: *Self, instruction: u32) void {
            self.genericLoadHandler(u32, instruction, true);
        }

        fn handleLbu(self: *Self, instruction: u32) void {
            self.genericLoadHandler(u8, instruction, false);
        }

        fn handleLhu(self: *Self, instruction: u32) void {
            self.genericLoadHandler(u16, instruction, false);
        }

        fn handleAnd(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) & self.getRegister(parsed.rs2)
            );
        }

        fn handleOr(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) | self.getRegister(parsed.rs2)
            );
        }

        fn handleXor(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) ^ self.getRegister(parsed.rs2)
            );
        }

        fn handleSll(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: u5 = @intCast(self.getRegister(parsed.rs2) & 0x1f);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) << shift_len
            );
        }

        fn handleSrl(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: u5 = @intCast(self.getRegister(parsed.rs2) & 0x1f);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) >> shift_len
            );
        }

        fn handleSra(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: u5 = @intCast(self.getRegister(parsed.rs2) & 0x1f);
            const src_signed: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const result_signed = src_signed >> shift_len;
            self.setRegister(
                parsed.rd,
                @bitCast(result_signed)
            );
        }

        fn handleSlt(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const rs1: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const rs2: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                if (rs1 < rs2) 1 else 0
            );
        }

        fn handleSltu(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const rs1 = self.getRegister(parsed.rs1);
            const rs2 = self.getRegister(parsed.rs2);
            self.setRegister(
                parsed.rd,
                if (rs1 < rs2) 1 else 0
            );
        }

        fn handleSlti(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const rs1: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const imm: toSigned(Tword) = @bitCast(signExtend(Tword, parsed.imm));
            self.setRegister(
                parsed.rd,
                if (rs1 < imm) 1 else 0
            );
        }

        fn handleSltiu(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const rs1 = self.getRegister(parsed.rs1);
            const imm: Tword = @bitCast(signExtend(Tword, parsed.imm));
            self.setRegister(
                parsed.rd,
                if (rs1 < imm) 1 else 0
            );
        }

        fn handleNop(_: *Self, _: u32) void { }

        pub fn loadBinary(self: *Self, entrypoint: Tword, buffer: []u8) !void {
            try self.bus.writeMemory(entrypoint, buffer);
        }

        pub fn init(allocator: Allocator, memory_start: Tword, memory_length: Tword, writer: std.io.AnyWriter) !RVCPU(Tword) {
            return .{
                .allocator = allocator,
                .registers = std.mem.zeroes([32]Tword),
                .pc = memory_start,
                .bus = try Bus(Tword).init(allocator, memory_start, memory_length),
                .test_result = null,
                .writer = writer,
            };
        }

        pub fn deinit(self: *Self) void {
            self.bus.deinit(self.allocator);
        }

        pub fn isHalted(self: *Self) bool {
            return self.test_result != null;
        }

        pub fn getSignature(self: *Self, allocator: Allocator) ![]u8 {
            std.debug.assert(self.isHalted());
            const signature = self.test_result.?.signature_address.?;
            const buffer: []u8 = try allocator.alloc(u8, @intCast(signature.length));
            try self.bus.readMemory(signature.start, buffer);
            return buffer;
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
