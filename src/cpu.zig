const std = @import("std");
const Allocator = std.mem.Allocator;
const LittleEndian = std.builtin.Endian.little;

fn toSigned(comptime T: type) type {
    return std.meta.Int(.signed, @typeInfo(T).int.bits);
}

fn toUnsigned(comptime T: type) type {
    return std.meta.Int(.unsigned, @typeInfo(T).int.bits);
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
    funct_3_6: struct { funct3: u3, funct6: u6 },
};

fn InstructionDescriptor(comptime opt: CpuOptions) type {
    return struct {
        const Tcpu = RVCPU(opt);
        const Tword = Tcpu.Tword;
        const InstructionHandler = *const fn (*Tcpu, u32) void;
        const WriterHandler = *const fn (std.io.AnyWriter, u32, Tword) anyerror!void;

        opcode: u7,
        id: InstructionID,
        handler: InstructionHandler,
        name: []const u8,
        advance_pc: bool,
        writer_fn: ?WriterHandler,

        const Self = @This();

        fn print(self: *const Self, writer: std.io.AnyWriter, instruction: u32, pc: Tword) !void {
            std.debug.assert((instruction & 0x7f) == self.opcode);
            if (self.writer_fn) |writer_fn| {
                try writer.print("{s} ", .{self.name});
                try writer_fn(writer, instruction, pc);
                try writer.writeAll("\n");
            } else {
                try writer.print("{s} ???\n", .{self.name});
            }
        }

        fn makeNone(name: []const u8, opcode: u7, handler: InstructionHandler, writer_fn: ?WriterHandler) Self {
            return .{
                .opcode = opcode,
                .id = InstructionID.none,
                .handler = handler,
                .name = name,
                .advance_pc = true,
                .writer_fn = writer_fn,
            };
        }

        fn makeF3(name: []const u8, opcode: u7, funct3: u3, handler: InstructionHandler, writer_fn: ?WriterHandler) Self {
            return .{
                .opcode = opcode,
                .id = InstructionID { .funct_3 = .{ .funct3 = funct3 } },
                .handler = handler,
                .name = name,
                .advance_pc = true,
                .writer_fn = writer_fn,
            };
        }

        fn makeF37(name: []const u8, opcode: u7, funct3: u3, funct7: u7, handler: InstructionHandler, writer_fn: ?WriterHandler) Self {
            return .{
                .opcode = opcode,
                .id = InstructionID { .funct_3_7 = .{ .funct3 = funct3, .funct7 = funct7 } },
                .handler = handler,
                .name = name,
                .advance_pc = true,
                .writer_fn = writer_fn,
            };
        }

        fn makeF36(name: []const u8, opcode: u7, funct3: u3, funct6: u6, handler: InstructionHandler, writer_fn: ?WriterHandler) Self {
            return .{
                .opcode = opcode,
                .id = InstructionID { .funct_3_6 = .{ .funct3 = funct3, .funct6 = funct6 } },
                .handler = handler,
                .name = name,
                .advance_pc = true,
                .writer_fn = writer_fn,
            };
        }

        fn noJump(self: Self) Self {
            var new = self;
            new.advance_pc = false;
            return new;
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

    fn makeWriter(Tword: type) type{
        return struct {
            fn write(writer: std.io.AnyWriter, instruction: u32, _: Tword) anyerror!void {
                const decoded: RTypeInstruction = @bitCast(instruction);
                try writer.print("x{}, x{}, x{}", .{decoded.rd, decoded.rs1, decoded.rs2});
            }
        };
    }
};

const ITypeInstruction = packed struct {
    opcode: u7,   
    rd: u5,
    funct3: u3,
    rs1: u5,
    imm: u12,

    fn makeWriter(Tword: type) type{
        return struct {
            fn write(writer: std.io.AnyWriter, instruction: u32, _: Tword) anyerror!void {
                const decoded: ITypeInstruction = @bitCast(instruction);
                try writer.print("x{}, x{}, {}", .{decoded.rd, decoded.rs1, decoded.imm});
            }

            fn writeLoad(writer: std.io.AnyWriter, instruction: u32, _: Tword) anyerror!void {
                const decoded: ITypeInstruction = @bitCast(instruction);
                const signed: i12 = @bitCast(decoded.imm);
                try writer.print("x{}, {}(x{})", .{decoded.rd, signed, decoded.rs1});
            }
        };
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

    fn makeWriter(Tword: type) type{
        return struct {
            fn write(writer: std.io.AnyWriter, instruction: u32, _: Tword) anyerror!void {
                const decoded: STypeInstruction = @bitCast(instruction);
                const signed: i12 = @bitCast(decoded.getImm());
                try writer.print("x{}, {}(x{})", .{decoded.rs2, signed, decoded.rs1});
            }
        };
    }
};

const UTypeInstruction = packed struct {
    opcode: u7,
    rd: u5,
    imm: u20,

    fn makeWriter(Tword: type) type{
        return struct {
            fn write(writer: std.io.AnyWriter, instruction: u32, _: Tword) anyerror!void {
                const decoded: UTypeInstruction = @bitCast(instruction);
                try writer.print("x{}, 0x{x}", .{decoded.rd, decoded.imm});
            }
        };
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

    fn makeWriter(Tword: type) type {
        return struct {
            fn write(writer: std.io.AnyWriter, instruction: u32, pc: Tword) anyerror!void {
                const decoded: JTypeInstruction = @bitCast(instruction);
                const resulting_pc = pc +% decoded.getImm(Tword);
                try writer.print("0x{x}", .{resulting_pc});
            }
        };
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

    fn makeWriter(Tword: type) type {
        return struct {
            fn write(writer: std.io.AnyWriter, instruction: u32, pc: Tword) anyerror!void {
                const decoded: BTypeInstruction = @bitCast(instruction);
                const resulting_pc = pc +% decoded.getImm(Tword);
                try writer.print("x{}, x{}, 0x{x}", .{decoded.rs1, decoded.rs2, resulting_pc});
            }
        };
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

pub const WordSize = enum {
    w32,
    w64,
};

pub const CpuOptions = struct {
    const Self = @This();

    word_size: WordSize,
    m_extension: bool,

    pub fn makeBase(word_size: WordSize) CpuOptions {
        return .{
            .word_size = word_size,
            .m_extension = false,
        };
    }

    pub fn withM(self: Self) Self {
        var new = self;
        new.m_extension = true;
        return new;
    }
};

pub fn RVCPU(comptime opt: CpuOptions) type {
    return struct {
        const Self = @This();
        pub const Tword = switch (opt.word_size) {
            .w32 => u32,
            .w64 => u64,
        };

        allocator: Allocator,
        registers: [32]Tword,
        pc: Tword,
        bus: Bus(Tword),
        test_result: ?TestResult(Tword),
        writer: std.io.AnyWriter,

        const Instr = InstructionDescriptor(opt);

        fn shiftLen() type {
            switch (opt.word_size) {
                .w32 => return u5,
                .w64 => return u6,
            }
        }

        const Tshamt32 = packed struct {
            shift_len: u5,
            id: u7,
        };

        const Tshamt64 = packed struct {
            shift_len: u6,
            id: u6,
        };

        const Tshamt = switch (opt.word_size) {
            .w32 => Tshamt32,
            .w64 => Tshamt64,
        };

        const RWriter = RTypeInstruction.makeWriter(Tword).write;
        const IWriter = ITypeInstruction.makeWriter(Tword).write;
        const ILoadWriter = ITypeInstruction.makeWriter(Tword).writeLoad;
        const SWriter = STypeInstruction.makeWriter(Tword).write;
        const BWriter = BTypeInstruction.makeWriter(Tword).write;
        const UWriter = UTypeInstruction.makeWriter(Tword).write;
        const JWriter = JTypeInstruction.makeWriter(Tword).write;

        const instructions = [_]Instr {
            // R-type arithmetic/logic
            Instr.makeF37("ADD",  0b0110011, 0,    0, handleAdd,  RWriter),
            Instr.makeF37("SUB",  0b0110011, 0, 0x20, handleSub,  RWriter),
            Instr.makeF37("XOR",  0b0110011, 4,    0, handleXor,  RWriter),
            Instr.makeF37("OR",   0b0110011, 6,    0, handleOr,   RWriter),
            Instr.makeF37("AND",  0b0110011, 7,    0, handleAnd,  RWriter),
            Instr.makeF37("SLL",  0b0110011, 1,    0, handleSll,  RWriter),
            Instr.makeF37("SRL",  0b0110011, 5,    0, handleSrl,  RWriter),
            Instr.makeF37("SRA",  0b0110011, 5, 0x20, handleSra,  RWriter),
            Instr.makeF37("SLT",  0b0110011, 2,    0, handleSlt,  RWriter),
            Instr.makeF37("SLTU", 0b0110011, 3,    0, handleSltu, RWriter),

            // I-type arithmetic/logic
            Instr.makeF3("ADDI",   0b0010011, 0,       handleAddi,  IWriter),
            Instr.makeF3("XORI",   0b0010011, 4,       handleXori,  IWriter),
            Instr.makeF3("ORI",    0b0010011, 6,       handleOri,   IWriter),
            Instr.makeF3("ANDI",   0b0010011, 7,       handleAndi,  IWriter),
            Instr.makeF3("SLTI",   0b0010011, 2,       handleSlti,  IWriter),
            Instr.makeF3("SLTIU",  0b0010011, 3,       handleSltiu, IWriter),

            // I-type loads
            Instr.makeF3("LB",  0b0000011, 0, handleLb,  ILoadWriter),
            Instr.makeF3("LH",  0b0000011, 1, handleLh,  ILoadWriter),
            Instr.makeF3("LW",  0b0000011, 2, handleLw,  ILoadWriter),
            Instr.makeF3("LBU", 0b0000011, 4, handleLbu, ILoadWriter),
            Instr.makeF3("LHU", 0b0000011, 5, handleLhu, ILoadWriter),

            // S-type stores
            Instr.makeF3("SB", 0b0100011, 0, handleSb, SWriter),
            Instr.makeF3("SH", 0b0100011, 1, handleSh, SWriter),
            Instr.makeF3("SW", 0b0100011, 2, handleSw, SWriter),

            // B-type branches
            Instr.makeF3("BEQ",  0b1100011, 0, handleBeq,  BWriter).noJump(),
            Instr.makeF3("BNE",  0b1100011, 1, handleBne,  BWriter).noJump(),
            Instr.makeF3("BLT",  0b1100011, 4, handleBlt,  BWriter).noJump(),
            Instr.makeF3("BGE",  0b1100011, 5, handleBge,  BWriter).noJump(),
            Instr.makeF3("BLTU", 0b1100011, 6, handleBltu, BWriter).noJump(),
            Instr.makeF3("BGEU", 0b1100011, 7, handleBgeu, BWriter).noJump(),

            // Jumps
            Instr.makeNone("JAL", 0b1101111, handleJal, JWriter).noJump(),
            Instr.makeF3("JALR", 0b1100111, 0, handleJalr, JWriter).noJump(),

            // U-type loads
            Instr.makeNone("LUI",   0b0110111, handleLui,   UWriter),
            Instr.makeNone("AUIPC", 0b0010111, handleAuipc, UWriter),

            // Misc
            Instr.makeF3("ECALL",   0b1110011, 0, handleEcall, null).noJump(),
            Instr.makeF3("FENCE",   0b0001111, 0, handleNop,   null),
            Instr.makeF3("FENCE.I", 0b0001111, 1, handleNop,   null),
        } ++ 
            (if (opt.word_size == .w64) [_]Instr {
                Instr.makeF3("LWU",  0b0000011, 6,    handleLwu,  null),
                Instr.makeF3("LD",   0b0000011, 3,    handleLd,  null),
                Instr.makeF3("SD",   0b0100011, 3,    handleSd,  null),

                Instr.makeF36("SLLI",  0b0010011, 1, 0,    handleSlli,  IWriter),
                Instr.makeF36("SRLI",  0b0010011, 5, 0,    handleSrli,  IWriter),
                Instr.makeF36("SRAI",  0b0010011, 5, 0x10, handleSrai,  IWriter),

                Instr.makeF3("ADDIW",  0b0011011, 0,       handleAddiw, null),
                Instr.makeF37("SLLIW", 0b0011011, 1, 0,    handleSlliw, null),
                Instr.makeF37("SRLIW", 0b0011011, 5, 0,    handleSrliw, null),
                Instr.makeF37("SRAIW", 0b0011011, 5, 0x20, handleSraiw, null),

                Instr.makeF37("ADDW",  0b0111011, 0, 0,    handleAddw, null),
                Instr.makeF37("SUBW",  0b0111011, 0, 0x20, handleSubw, null),
                Instr.makeF37("SLLW",  0b0111011, 1, 0,    handleSllw, null),
                Instr.makeF37("SRLW",  0b0111011, 5, 0,    handleSrlw, null),
                Instr.makeF37("SRAW",  0b0111011, 5, 0x20, handleSraw, null),
            } else [_]Instr {}) ++
            (if (opt.word_size == .w32) [_]Instr {
                Instr.makeF37("SLLI",  0b0010011, 1, 0,    handleSlli,  IWriter),
                Instr.makeF37("SRLI",  0b0010011, 5, 0,    handleSrli,  IWriter),
                Instr.makeF37("SRAI",  0b0010011, 5, 0x20, handleSrai,  IWriter),
            } else [_]Instr {}) ++
            (if (opt.m_extension) [_]Instr {
                Instr.makeF37("MUL",   0b0110011, 0, 1,    handleMul,   RWriter),
                Instr.makeF37("MULH",  0b0110011, 1, 1,    handleMulh,  RWriter),
                Instr.makeF37("MULHSU",0b0110011, 2, 1,    handleMulhsu,RWriter),
                Instr.makeF37("MULHU", 0b0110011, 3, 1,    handleMulhu, RWriter),
                Instr.makeF37("DIV",   0b0110011, 4, 1,    handleDiv,   RWriter),
                Instr.makeF37("DIVU",  0b0110011, 5, 1,    handleDivu,  RWriter),
                Instr.makeF37("REM",   0b0110011, 6, 1,    handleRem,   RWriter),
                Instr.makeF37("REMU",  0b0110011, 7, 1,    handleRemu,  RWriter),
            } else [_]Instr {}) ++
            (if (opt.word_size == .w64 and opt.m_extension) [_]Instr {
                Instr.makeF37("MULW",  0b0111011, 0, 1,    handleMulw,  RWriter),
                Instr.makeF37("DIVW",  0b0111011, 4, 1,    handleDivw,  RWriter),
                Instr.makeF37("DIVUW", 0b0111011, 5, 1,    handleDivuw, RWriter),
                Instr.makeF37("REMW",  0b0111011, 6, 1,    handleRemw,  RWriter),
                Instr.makeF37("REMUW", 0b0111011, 7, 1,    handleRemuw, RWriter),
            } else [_]Instr {});

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
                .funct_3_6 => |*v| return v.funct3 == id.funct3 and v.funct6 == (id.funct7 >> 1),
            }
            return false;
        }

        fn writeRegisters(self: *Self, writer: std.io.AnyWriter, width: usize) !void {
            for (0..self.registers.len) |i| {
                var buffer: [16]u8 = undefined;
                const sep = if ((i + 1) % width == 0) "\n" else " ";
                const register_name = try std.fmt.bufPrint(&buffer, "x{}", .{i});
                const fmt_string = switch (opt.word_size) {
                    .w32 => "{s: >3}={x:0>8}{s}",
                    .w64 => "{s: >3}={x:0>16}{s}",
                };
                try writer.print(fmt_string, .{register_name, self.registers[i], sep});
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
                    try i.print(self.writer, instruction, self.pc);
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


        pub fn loadBinary(self: *Self, entrypoint: Tword, buffer: []u8) !void {
            try self.bus.writeMemory(entrypoint, buffer);
        }

        pub fn init(allocator: Allocator, memory_start: Tword, memory_length: Tword, writer: std.io.AnyWriter) !RVCPU(opt) {
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

        pub fn getTestFailureCode(self: *Self) ?Tword {
            std.debug.assert(self.test_result != null);
            if (self.test_result.?.is_success()) {
                return null;
            } else {
                return self.test_result.?.a0;
            }
        }

        pub fn getSignature(self: *Self, allocator: Allocator) ![]u8 {
            std.debug.assert(self.isHalted());
            const signature = self.test_result.?.signature_address.?;
            const buffer: []u8 = try allocator.alloc(u8, @intCast(signature.length));
            try self.bus.readMemory(signature.start, buffer);
            return buffer;
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

        fn handleXor(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) ^ self.getRegister(parsed.rs2)
            );
        }

        fn handleOr(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) | self.getRegister(parsed.rs2)
            );
        }

        fn handleAnd(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) & self.getRegister(parsed.rs2)
            );
        }

        fn handleSll(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: shiftLen() = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) << shift_len
            );
        }

        fn handleSrl(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: shiftLen() = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) >> shift_len
            );
        }

        fn handleSra(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: shiftLen() = @truncate(self.getRegister(parsed.rs2));
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

        fn handleAddi(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_signed = signExtend(Tword, parsed.imm);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) +% imm_signed
            );
        }

        fn handleXori(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) ^ signExtend(Tword, parsed.imm)
            );
        }

        fn handleOri(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) | signExtend(Tword, parsed.imm)
            );
        }

        fn handleAndi(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) & signExtend(Tword, parsed.imm)
            );
        }

        fn handleSlli(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_split: Tshamt = @bitCast(parsed.imm);
            self.setRegister(
                parsed.rd,
                (self.getRegister(parsed.rs1) << imm_split.shift_len)
            );
        }

        fn handleSrli(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_split: Tshamt = @bitCast(parsed.imm);
            self.setRegister(
                parsed.rd,
                (self.getRegister(parsed.rs1) >> imm_split.shift_len)
            );
        }

        fn handleSrai(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_split: Tshamt = @bitCast(parsed.imm);
            const signed_src: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const shifted = signed_src >> imm_split.shift_len;
            const result: Tword = @bitCast(shifted);
            self.setRegister(parsed.rd, result);
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

        fn handleAddiw(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const added: Tword = self.getRegister(parsed.rs1) +% signExtend(Tword, parsed.imm);
            const truncated: u32 = @truncate(added);
            self.setRegister(
                parsed.rd,
                signExtend(Tword, truncated)
            );
        }

        fn handleSlliw(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_split: Tshamt32 = @bitCast(parsed.imm);
            const truncated: u32 = @truncate(self.getRegister(parsed.rs1));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, truncated << imm_split.shift_len)
            );
        }

        fn handleSrliw(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_split: Tshamt32 = @bitCast(parsed.imm);
            const truncated: u32 = @truncate(self.getRegister(parsed.rs1));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, truncated >> imm_split.shift_len)
            );
        }

        fn handleSraiw(self: *Self, instruction: u32) void {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_split: Tshamt32 = @bitCast(parsed.imm);
            const truncated: u32 = @truncate(self.getRegister(parsed.rs1));
            const signed_src: i32 = @bitCast(truncated);
            const shifted = signed_src >> imm_split.shift_len;
            const result: u32 = @bitCast(shifted);
            self.setRegister(
                parsed.rd,
                signExtend(Tword, result)
            );
        }

        fn handleAddw(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a: u32 = @truncate(self.getRegister(parsed.rs1));
            const b: u32 = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, a +% b)
            );
        }

        fn handleSubw(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a: u32 = @truncate(self.getRegister(parsed.rs1));
            const b: u32 = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, a -% b)
            );
        }

        fn handleSllw(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: u5 = @truncate(self.getRegister(parsed.rs2));
            const truncated: u32 = @truncate(self.getRegister(parsed.rs1));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, truncated << shift_len)
            );
        }

        fn handleSrlw(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: u5 = @truncate(self.getRegister(parsed.rs2));
            const truncated: u32 = @truncate(self.getRegister(parsed.rs1));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, truncated >> shift_len)
            );
        }

        fn handleSraw(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: u5 = @truncate(self.getRegister(parsed.rs2));
            const truncated: u32 = @truncate(self.getRegister(parsed.rs1));
            const truncated_signed: i32 = @bitCast(truncated);
            const result_signed = truncated_signed >> shift_len;
            self.setRegister(
                parsed.rd,
                signExtend(Tword, result_signed)
            );
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

        fn handleLb(self: *Self, instruction: u32) void {
            self.genericLoadHandler(u8, instruction, true);
        }

        fn handleLh(self: *Self, instruction: u32) void {
            self.genericLoadHandler(u16, instruction, true);
        }

        fn handleLw(self: *Self, instruction: u32) void {
            self.genericLoadHandler(u32, instruction, true);
        }

        fn handleLd(self: *Self, instruction: u32) void {
            self.genericLoadHandler(u64, instruction, true);
        }

        fn handleLbu(self: *Self, instruction: u32) void {
            self.genericLoadHandler(u8, instruction, false);
        }

        fn handleLhu(self: *Self, instruction: u32) void {
            self.genericLoadHandler(u16, instruction, false);
        }

        fn handleLwu(self: *Self, instruction: u32) void {
            self.genericLoadHandler(u32, instruction, false);
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

        fn handleSb(self: *Self, instruction: u32) void {
            self.genericStoreHandler(u8, instruction);
        }

        fn handleSh(self: *Self, instruction: u32) void {
            self.genericStoreHandler(u16, instruction);
        }

        fn handleSw(self: *Self, instruction: u32) void {
            self.genericStoreHandler(u32, instruction);
        }

        fn handleSd(self: *Self, instruction: u32) void {
            self.genericStoreHandler(u64, instruction);
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

        fn handleBne(self: *Self, instruction: u32) void {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm(Tword);
            if (self.getRegister(parsed.rs1) != self.getRegister(parsed.rs2)) {
                self.pc +%= imm;
            } else {
                self.pc += 4;
            }
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

        fn handleJal(self: *Self, instruction: u32) void {
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

        fn handleLui(self: *Self, instruction: u32) void {
            const parsed: UTypeInstruction = @bitCast(instruction);
            const imm: u32 = @intCast(parsed.imm);
            self.setRegister(
                parsed.rd,
                signExtend(Tword, imm << 12),
            );
        }

        fn handleAuipc(self: *Self, instruction: u32) void {
            const parsed: UTypeInstruction = @bitCast(instruction);
            const imm = @as(u32, parsed.imm) << 12;
            self.setRegister(
                parsed.rd,
                self.pc +% signExtend(Tword, imm),
            );
        }

        fn handleEcall(self: *Self, instruction: u32) void {
            _ = instruction;
            std.debug.assert(!self.isHalted());
            const memory_start = self.getRegister(11);
            const memory_end = self.getRegister(12);
            self.test_result = TestResult(Tword) {
                .a0 = self.getRegister(10),
                .signature_address = null,
            };
            if (self.test_result.?.is_success()) {
                self.test_result.?.signature_address = if (memory_start == memory_end) null else .{
                    .start = memory_start,
                    .length = memory_end - memory_start,
                };
            }
        }

        fn handleMul(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) *% self.getRegister(parsed.rs2)
            );
        }

        fn handleMulh(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const bit_count = @typeInfo(Tword).int.bits;
            const Tdoubleword = std.meta.Int(.signed, bit_count*2);
            const a = signExtend(Tdoubleword, self.getRegister(parsed.rs1));
            const b = signExtend(Tdoubleword, self.getRegister(parsed.rs2));
            const result_unsigned: toUnsigned(Tdoubleword) = @bitCast(a *% b);
            self.setRegister(
                parsed.rd,
                @truncate(result_unsigned >> bit_count)
            );
        }

        fn handleMulhsu(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const bit_count = @typeInfo(Tword).int.bits;
            const Tdoubleword = std.meta.Int(.unsigned, bit_count*2);
            const sign_bit = (self.getRegister(parsed.rs1) >> (bit_count - 1)) != 0;
            const a_word: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const a: Tdoubleword = @intCast(@abs(a_word));
            const b: Tdoubleword = @intCast(self.getRegister(parsed.rs2));
            var result: toSigned(Tdoubleword) = @bitCast(a *% b);
            if (sign_bit) result = -result;
            result = result >> bit_count;
            const result_unsigned: toUnsigned(Tdoubleword) = @bitCast(result);
            self.setRegister(
                parsed.rd,
                @truncate(result_unsigned)
            );
        }

        fn handleMulhu(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const bit_count = @typeInfo(Tword).int.bits;
            const Tdoubleword = std.meta.Int(.unsigned, bit_count*2);
            const a = @as(Tdoubleword, self.getRegister(parsed.rs1));
            const b = @as(Tdoubleword, self.getRegister(parsed.rs2));
            const result: Tword = @truncate((a *% b) >> bit_count);
            self.setRegister(
                parsed.rd,
                result
            );
        }

        fn handleDiv(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const b: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs2));
            const result = div: {
                if (b == 0) { break :div -1; }
                else if (a == std.math.minInt(toSigned(Tword)) and b == -1) { break :div a; }
                else { break :div @divTrunc(a, b); }
            };
            self.setRegister(
                parsed.rd,
                @bitCast(result)
            );
        }
        
        fn handleDivu(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a = self.getRegister(parsed.rs1);
            const b = self.getRegister(parsed.rs2);
            self.setRegister(
                parsed.rd,
                if (b == 0) std.math.maxInt(Tword) else a / b
            );
        }

        fn handleRem(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const b: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs2));
            const result = div: {
                if (b == 0) { break :div a; }
                else if (a == std.math.minInt(toSigned(Tword)) and b == -1) { break :div 0; }
                else { break :div @rem(a, b); }
            };
            self.setRegister(
                parsed.rd,
                @bitCast(result)
            );
        }

        fn handleRemu(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a = self.getRegister(parsed.rs1);
            const b = self.getRegister(parsed.rs2);
            self.setRegister(
                parsed.rd,
                if (b == 0) a else a % b
            );
        }

        fn handleMulw(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a: u32 = @truncate(self.getRegister(parsed.rs1));
            const b: u32 = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, a *% b)
            );
        }
        
        fn handleDivw(self: *Self, instruction: u32) void {
            // TODO: refactor DIV and DIVW into one function, same for REM
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a_unsigned: u32 = @truncate(self.getRegister(parsed.rs1));
            const b_unsigned: u32 = @truncate(self.getRegister(parsed.rs2));
            const a: i32 = @bitCast(a_unsigned);
            const b: i32 = @bitCast(b_unsigned);
            const result = div: {
                if (b == 0) { break :div -1; }
                else if (a == std.math.minInt(i32) and b == -1) { break :div a; }
                else { break :div @divTrunc(a, b); }
            };
            self.setRegister(
                parsed.rd,
                signExtend(Tword, result)
            );
        }

        fn handleDivuw(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a: u32 = @truncate(self.getRegister(parsed.rs1));
            const b: u32 = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                if (b == 0) std.math.maxInt(Tword) else signExtend(Tword, a / b)
            );
        }

        fn handleRemw(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a_unsigned: u32 = @truncate(self.getRegister(parsed.rs1));
            const b_unsigned: u32 = @truncate(self.getRegister(parsed.rs2));
            const a: i32 = @bitCast(a_unsigned);
            const b: i32 = @bitCast(b_unsigned);
            const result = div: {
                if (b == 0) { break :div a; }
                else if (a == std.math.minInt(i32) and b == -1) { break :div 0; }
                else { break :div @rem(a, b); }
            };
            self.setRegister(
                parsed.rd,
                signExtend(Tword, result)
            );
        }

        fn handleRemuw(self: *Self, instruction: u32) void {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a: u32 = @truncate(self.getRegister(parsed.rs1));
            const b: u32 = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, if (b == 0) a else a % b)
            );
        }

        fn handleNop(_: *Self, _: u32) void { }
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
