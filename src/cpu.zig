const std = @import("std");
const bus = @import("bus.zig");
const io = @import("io.zig");
const qpu = @import("qpu.zig");
const instruction_cache = @import("instruction_cache.zig");
const IoHandler = io.IoHandler;
pub const privilege = @import("privilege.zig");
pub const cpu_config = @import("cpu_config.zig");
const gdb_server = @import("gdb_server.zig");
const Bus = bus.Bus;
const BusDeviceConfig = bus.BusDeviceConfig;
const Allocator = std.mem.Allocator;
const LittleEndian = std.builtin.Endian.little;
const PrivilegeLevel = privilege.PrivilegeLevel;
const SppPrivilegeLevel = privilege.SppPrivilegeLevel;

fn toSigned(comptime T: type) type {
    return std.meta.Int(.signed, @typeInfo(T).int.bits);
}

fn toUnsigned(comptime T: type) type {
    return std.meta.Int(.unsigned, @typeInfo(T).int.bits);
}

fn subtractBits(T: type, bit_count: usize) type {
    return std.meta.Int(.unsigned, @typeInfo(T).int.bits - bit_count);
}

fn isAligned(Tword: type, Talign: type, addr: Tword) bool {
    const alignment_byte_count = @divExact(@typeInfo(Talign).int.bits, 8);
    return (addr % alignment_byte_count) == 0;
}

test "alignment u32" {
    const BASE_ADDR = 0x1000;
    try std.testing.expect(isAligned(u64, u32, BASE_ADDR));
    inline for (1..4) |i| {
        try std.testing.expect(!isAligned(u64, u32, BASE_ADDR + i));
    }
    try std.testing.expect(isAligned(u64, u32, BASE_ADDR + 4));
}

test "alignment u64" {
    const BASE_ADDR = 0x1000;
    try std.testing.expect(isAligned(u64, u64, BASE_ADDR));
    inline for (1..8) |i| {
        try std.testing.expect(!isAligned(u64, u64, BASE_ADDR + i));
    }
    try std.testing.expect(isAligned(u64, u64, BASE_ADDR + 8));
}

fn signExtend(comptime T: type, val: anytype) T {
    // TODO: assertions about types
    const SignedOriginalType = toSigned(@TypeOf(val)); //i12
    const SignedExtendedType = toSigned(T);            //i32
    const signed: SignedOriginalType = @bitCast(val);  //bitcast to i12
    const signed_extended: SignedExtendedType = @intCast(signed); //extend to i32
    return @bitCast(signed_extended);                  //return u32
}

const InstructionID = union(enum) {
    none,
    funct_3: struct { funct3: u3 },
    funct_3_7: struct { funct3: u3, funct7: u7 },
    funct_3_6: struct { funct3: u3, funct6: u6 },
    funct_3_5: struct { funct3: u3, funct5: u5 },
    direct_match: u32,
};

fn InstructionDescriptor(comptime opt: cpu_config.CpuOptions) type {
    return struct {
        const Tcpu = RVCPU(opt);
        const Tword = Tcpu.Tword;
        const InstructionHandler = *const fn (*Tcpu, u32) ?ExecutionError(Tword);
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

        fn makeF35(name: []const u8, opcode: u7, funct3: u3, funct5: u5, handler: InstructionHandler, writer_fn: ?WriterHandler) Self {
            return .{
                .opcode = opcode,
                .id = InstructionID { .funct_3_5 = .{ .funct3 = funct3, .funct5 = funct5 } },
                .handler = handler,
                .name = name,
                .advance_pc = true,
                .writer_fn = writer_fn,
            };
        }

        fn makeDirect(name: []const u8, instruction: u32, handler: InstructionHandler, writer_fn: ?WriterHandler) Self {
            return .{
                .opcode = instruction & 0x7f,
                .id = InstructionID { .direct_match = instruction },
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

    fn makeCsrWriter(Tword: type) type {
        return struct {
            fn write(writer: std.io.AnyWriter, instruction: u32, _: Tword) anyerror!void {
                const decoded: ITypeInstruction = @bitCast(instruction);
                try writer.print("x{}, 0x{x}, x{}", .{decoded.rd, decoded.imm, decoded.rs1});
            }

            fn writeImm(writer: std.io.AnyWriter, instruction: u32, _: Tword) anyerror!void {
                const decoded: ITypeInstruction = @bitCast(instruction);
                try writer.print("x{}, 0x{x}, 0x{x}", .{decoded.rd, decoded.imm, decoded.rs1});
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
        // TODO: THIS WAS NOT CAUGHT BY THE TEST SUITE
        // const imm4: u21 = @intCast(self.imm3);
        const imm4: u21 = @intCast(self.imm4);
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

        pub fn is_success(self: *const Self) bool {
            return self.a0 == 0;
        }
    };
}

const TrapMode = enum {
    Direct,
    Vectored,

    fn getEncoding(self: TrapMode) u2 {
        switch (self) {
            .Direct => return 0,
            .Vectored => return 0,
        }
    }

    fn fromEncoding(encoding: u2) ?TrapMode {
        switch (encoding) {
            0 => return .Direct,
            1 => return .Vectored,
            else => return null,
        }
    }
};

fn ExecutionError(Tword: type) type {
    return union(enum) {
        InstructionAddressMisaligned: Tword,
        InstructionAccessFault: Tword,
        IllegalInstruction: Tword,
        Breakpoint: Tword,
        LoadAddressMisaligned: Tword,
        LoadAccessFault: Tword,
        StoreAddressMisaligned: Tword,
        StoreAccessFault: Tword,
        EcallFromU,
        EcallFromS,
        EcallFromM,
        InstructionPageFault: Tword,
        LoadPageFault: Tword,
        StorePageFault: Tword,
        DoubleTrap,

        fn getCode(self: ExecutionError(Tword)) Tword {
            return switch (self) {
                .InstructionAddressMisaligned => 0,
                .InstructionAccessFault => 1,
                .IllegalInstruction => 2,
                .Breakpoint => 3,
                .LoadAddressMisaligned => 4,
                .LoadAccessFault => 5,
                .StoreAddressMisaligned => 6,
                .StoreAccessFault => 7,
                .EcallFromU => 8,
                .EcallFromS => 9,
                .EcallFromM => 11,
                .InstructionPageFault => 12,
                .LoadPageFault => 13,
                .StorePageFault => 15,
                .DoubleTrap => 16,
            };
        }

        fn getVal(self: ExecutionError(Tword)) ?Tword {
            return switch (self) {
                .EcallFromU,
                .EcallFromS,
                .EcallFromM,
                .DoubleTrap
                    => null,

                .InstructionAddressMisaligned,
                .InstructionAccessFault,
                .IllegalInstruction,
                .Breakpoint,
                .LoadAddressMisaligned,
                .LoadAccessFault,
                .StoreAddressMisaligned,
                .StoreAccessFault,
                .InstructionPageFault,
                .LoadPageFault,
                .StorePageFault
                    => |*v| v.*,
            };
        }
    };
}

const DebugPrintError = error { WriteFailed };

pub fn RVCPU(comptime opt: cpu_config.CpuOptions) type {
    const SignatureInfo = struct {
        signature_start: opt.getTword(),
        signature_end: opt.getTword(),
        tohost_address: opt.getTword()
    };

    const MemoryReservation = struct {
        address: opt.getTword(),
        length: opt.getTword(),
    };

    return struct {
        const Self = @This();
        pub const Tword = opt.getTword();
        const TError = ExecutionError(Tword);
        const Instr = InstructionDescriptor(opt);

        // const TICache = instruction_cache.ICache(Tword, Instr);
        const TICache = instruction_cache.ArrICache(Tword, Instr);

        const InterruptCause = enum(u5) {
            supervisor_software = 1,
            machine_software = 3,
            supervisor_timer = 5,
            machine_timer = 7,
            supervisor_external = 9,
            machine_external = 11,
            local_counter_overflow = 13,
        };

        const PendingInterrupt = struct {
            target: PrivilegeLevel,
            cause: InterruptCause,
        };

        allocator: Allocator,
        registers: [32]Tword,
        pc: Tword,
        _bus: Bus(Tword),
        test_result: ?TestResult(Tword),
        debug_writer: ?std.io.AnyWriter,
        // TODO: refactor everything used for testing (signatures, tohost, results)
        signature_info: ?SignatureInfo,

        m_trap_handler_address: Tword,
        m_trap_mode: TrapMode,
        s_trap_handler_address: Tword,
        s_trap_mode: TrapMode,
        mepc: Tword,
        mcause: Tword,
        mtval: Tword,
        sepc: Tword,
        scause: Tword,
        stval: Tword,
        current_privilege_level: PrivilegeLevel,
        mpp: PrivilegeLevel,
        spp: SppPrivilegeLevel,
        mstatus_mie: bool,
        sstatus_sie: bool,
        mpie: bool,
        spie: bool,
        mstatus_sum: bool,
        mstatus_mxr: bool,
        
        medeleg: Tword,
        mideleg: Tword,
        mie_bits: Tword,
        mip_bits: Tword,
        mcounteren: Tword,
        scounteren: Tword,
        mscratch: Tword,
        sscratch: Tword,

        memory_reservation: ?MemoryReservation,
        gdb_connection: ?gdb_server.GdbDebugServer(opt),
        
        paging_enabled: bool,
        asid: u16,
        ppn: u44,

        qpu_ctx: Tword,
        qpu: qpu.Qpu(Tword),

        instruction_cache: TICache,

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

        const CSRWriter = ITypeInstruction.makeCsrWriter(Tword).write;
        const CSRIWriter = ITypeInstruction.makeCsrWriter(Tword).writeImm;

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
            Instr.makeDirect("ECALL", 0x73,         handleEcall, null).noJump(),
            Instr.makeDirect("EBREAK",0x100073,     handleEbreak, null).noJump(),
            Instr.makeF3("FENCE",   0b0001111, 0,   handleNop,   null),
            Instr.makeF3("FENCE.I", 0b0001111, 1,   handleFenceI,   null),
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
            } else [_]Instr {}) ++
            (if (opt.privileged) [_]Instr {
                Instr.makeF3("CSRRW", 0b1110011, 1,  handleCsrrw, CSRWriter),
                Instr.makeF3("CSRRS", 0b1110011, 2,  handleCsrrs, CSRWriter),
                Instr.makeF3("CSRRC", 0b1110011, 3,  handleCsrrc, CSRWriter),
                Instr.makeF3("CSRRWI", 0b1110011, 5, handleCsrrwi, CSRIWriter),
                Instr.makeF3("CSRRSI", 0b1110011, 6, handleCsrrsi, CSRIWriter),
                Instr.makeF3("CSRRCI", 0b1110011, 7, handleCsrrci, CSRIWriter),
                Instr.makeF3("CSRR_DEBUG", 0b1110011, 4, handleCsrr_debug, null),
                
                // TODO: do properly
                Instr.makeDirect("WFI", 0x10500073, handleNop, null),

                // TODO: hide under some "debug" flag
                Instr.makeF37("GETPRIV", 0b0001011, 0, 0x78, handleGetpriv, null),

                Instr.makeDirect("MRET", 0x30200073, handleMret, null).noJump(),
                Instr.makeDirect("SRET", 0x10200073, handleSret, null).noJump(),

                Instr.makeF37("SFENCE.VMA", 0b1110011, 0, 9, handleFenceI, null),
            } else [_]Instr {}) ++
            (if (opt.a_extension) [_]Instr {
                Instr.makeF35("AMOSWAP.W", 0b0101111, 0b010, 0b00001,  handleAmoswapW,  null),
                Instr.makeF35("AMOADD.W",  0b0101111, 0b010, 0b00000,  handleAmoaddW,   null),
                Instr.makeF35("AMOXOR.W",  0b0101111, 0b010, 0b00100,  handleAmoxorW,   null),
                Instr.makeF35("AMOAND.W",  0b0101111, 0b010, 0b01100,  handleAmoandW,   null),
                Instr.makeF35("AMOOR.W",   0b0101111, 0b010, 0b01000,  handleAmoorW,    null),
                Instr.makeF35("AMOMIN.W",  0b0101111, 0b010, 0b10000,  handleAmominW,   null),
                Instr.makeF35("AMOMAX.W",  0b0101111, 0b010, 0b10100,  handleAmomaxW,   null),
                Instr.makeF35("AMOMINU.W", 0b0101111, 0b010, 0b11000,  handleAmominuW,  null),
                Instr.makeF35("AMOMAXU.W", 0b0101111, 0b010, 0b11100,  handleAmomaxuW,  null),

                Instr.makeF35("AMOSWAP.D", 0b0101111, 0b011, 0b00001,  handleAmoswapD,  null),
                Instr.makeF35("AMOADD.D",  0b0101111, 0b011, 0b00000,  handleAmoaddD,   null),
                Instr.makeF35("AMOXOR.D",  0b0101111, 0b011, 0b00100,  handleAmoxorD,   null),
                Instr.makeF35("AMOAND.D",  0b0101111, 0b011, 0b01100,  handleAmoandD,   null),
                Instr.makeF35("AMOOR.D",   0b0101111, 0b011, 0b01000,  handleAmoorD,    null),
                Instr.makeF35("AMOMIN.D",  0b0101111, 0b011, 0b10000,  handleAmominD,   null),
                Instr.makeF35("AMOMAX.D",  0b0101111, 0b011, 0b10100,  handleAmomaxD,   null),
                Instr.makeF35("AMOMINU.D", 0b0101111, 0b011, 0b11000,  handleAmominuD,  null),
                Instr.makeF35("AMOMAXU.D", 0b0101111, 0b011, 0b11100,  handleAmomaxuD,  null),

                Instr.makeF35("LR.W",      0b0101111, 0b010, 0b00010,  handleLrW,  null),
                Instr.makeF35("SC.W",      0b0101111, 0b010, 0b00011,  handleScW,  null),
                Instr.makeF35("LR.D",      0b0101111, 0b011, 0b00010,  handleLrD,  null),
                Instr.makeF35("SC.D",      0b0101111, 0b011, 0b00011,  handleScD,  null),
            } else [_]Instr {}) ++
            (if (opt.qpu_extension) [_]Instr {
                Instr.makeF37("Q.NEWCTX",   0b0101011, 1, 0x01, handleQpuNewContext, null),
                Instr.makeF37("Q.FREECTX",  0b0101011, 1, 0x02, handleQpuFreeContext, null),
                Instr.makeF37("Q.CLONECTX", 0b0101011, 1, 0x03, handleQpuCloneContext, null),

                Instr.makeF37("Q.NEWREG",   0b0101011, 1, 0x10, handleQpuNewRegister, null),
                Instr.makeF37("Q.CNOT",     0b0101011, 1, 0x11, handleQpuCnot, null),
                Instr.makeF37("Q.TOFFOLI",  0b0101011, 1, 0x12, handleQpuToffoli, null),
                Instr.makeF37("Q.SIGMAX",   0b0101011, 1, 0x13, handleQpuSigmaX, null),
                Instr.makeF37("Q.SIGMAY",   0b0101011, 1, 0x14, handleQpuSigmaY, null),
                Instr.makeF37("Q.SIGMAZ",   0b0101011, 1, 0x15, handleQpuSigmaZ, null),
                Instr.makeF37("Q.HADAMARD", 0b0101011, 1, 0x16, handleQpuHadamard, null),
                Instr.makeF37("Q.BMEASURE", 0b0101011, 1, 0x17, handleQpuBmeasure, null),
                Instr.makeF37("Q.GETWIDTH", 0b0101011, 1, 0x18, handleQpuGetwidth, null),
                Instr.makeF37("Q.PROB",     0b0101011, 1, 0x19, handleQpuProb, null),
                Instr.makeF37("Q.GREGWIDTH",0b0101011, 1, 0x20, handleQpuGetRegWidth, null),
                Instr.makeF37("Q.SREGWIDTH",0b0101011, 1, 0x21, handleQpuSetRegWidth, null),
                Instr.makeF37("Q.GETREGNODE",0b0101011, 1, 0x22, handleQpuGetRegNode, null),
                Instr.makeF37("Q.GETREGSIZE",0b0101011, 1, 0x23, handleQpuGetRegSize, null),
            });

        fn lessThan(_: void, a: Instr, b: Instr) bool {
            return a.opcode < b.opcode;
        }

        pub fn sortByOpcode(
            comptime N: usize,
            input: [N]Instr,
        ) [N]InstructionDescriptor(opt) {
            @setEvalBranchQuota(10000);
            var out = input;
            std.sort.pdq(Instr, out[0..], {}, lessThan);
            return out;
        }

        pub fn groupByOpcode(
            comptime N: usize,
            sorted: [N]Instr,
        ) [128][]const Instr {
            var result: [128][]const Instr = undefined;

            var pos: usize = 0;
            var opcode: usize = 0;

            while (opcode < 128) : (opcode += 1) {
                const start = pos;
                while (pos < sorted.len and sorted[pos].opcode == opcode) : (pos += 1) {}
                result[opcode] = sorted[start..pos];
            }

            return result;
        }
            
        const sorted_instructions = sortByOpcode(instructions.len, instructions);
        const grouped_instructions = groupByOpcode(sorted_instructions.len, sorted_instructions);

        const Tcsrid: type = u12;
        const CsrWriteHandler = *const fn (*Self, Tword) void;
        const CsrReadHandler = *const fn (*Self) Tword;
        const CsrMapEntry = struct {
            name: []const u8,
            id: Tcsrid,
            write_handler: ?CsrWriteHandler,
            read_handler: CsrReadHandler,

            fn new(name: []const u8, id: Tcsrid, write_handler: ?CsrWriteHandler, read_handler: CsrReadHandler) CsrMapEntry {
                return .{
                    .name = name,
                    .id = id,
                    .write_handler = write_handler,
                    .read_handler = read_handler,
                };
            }
        };

        const TrapVectorCSR = packed struct {
            mode: u2,
            base: subtractBits(Tword, 2),

            fn getBase(self: TrapVectorCSR) Tword {
                const base_extended: Tword = @intCast(self.base);
                return base_extended << 2;
            }

            fn getMode(self: TrapVectorCSR) ?TrapMode {
                return TrapMode.fromEncoding(self.mode);
            }

            fn handleWrite(trap_mode: *TrapMode, trap_handler_address: *Tword, value: Tword) void {
                const parsed: TrapVectorCSR = @bitCast(value);
                if (parsed.getMode()) |mode| {
                    trap_mode.* = mode;
                }
                trap_handler_address.* = parsed.getBase();
            }

            fn handleRead(trap_mode: *const TrapMode, trap_handler_address: *const Tword) Tword {
                const retval = TrapVectorCSR {
                    .mode = trap_mode.*.getEncoding(),
                    .base = @truncate(trap_handler_address.* >> 2),
                };
                return @bitCast(retval);
            }

            fn handleWriteM(cpu: *Self, value: Tword) void {
                TrapVectorCSR.handleWrite(&cpu.m_trap_mode, &cpu.m_trap_handler_address, value);
            }

            fn handleWriteS(cpu: *Self, value: Tword) void {
                TrapVectorCSR.handleWrite(&cpu.s_trap_mode, &cpu.s_trap_handler_address, value);
            }

            fn handleReadM(cpu: *const Self) Tword {
                return TrapVectorCSR.handleRead(&cpu.m_trap_mode, &cpu.m_trap_handler_address);
            }

            fn handleReadS(cpu: *const Self) Tword {
                return TrapVectorCSR.handleRead(&cpu.s_trap_mode, &cpu.s_trap_handler_address);
            }
        };

        const MStatusCSR = packed struct {
            wpri1: u1,
            sie: u1,
            wpri2: u1,
            mie: u1,
            wpri3: u1,
            spie: u1,
            ube: u1,
            mpie: u1,
            spp: u1,
            vs: u2,
            mpp: u2,
            fs: u2,
            xs: u2,
            mprv: u1,
            sum: u1,
            mxr: u1,
            tvm: u1,
            tw: u1,
            tsr: u1,
            spelp: u1,
            sdt: u1,
            wpri4: u7,
            uxl: u2,
            sxl: u2,
            sbe: u1,
            mbe: u1,
            gva: u1,
            mpv: u1,
            wpri5: u1,
            mpelp: u1,
            mdt: u1,
            wpri6: u20,
            sd: u1,

            fn handleWrite(cpu: *Self, value: Tword) void {
                const new_mstatus: MStatusCSR = @bitCast(value);
                cpu.spp = SppPrivilegeLevel.fromEncoding(new_mstatus.spp);
                if (PrivilegeLevel.fromEncoding(new_mstatus.mpp)) |new_mpp| {
                    cpu.mpp = new_mpp;
                }
                cpu.sstatus_sie = new_mstatus.sie != 0;
                cpu.mstatus_mie = new_mstatus.mie != 0;
                cpu.spie = new_mstatus.spie != 0;
                cpu.mpie = new_mstatus.mpie != 0;
            }

            fn handleRead(cpu: *const Self) Tword {
                comptime if (@bitSizeOf(MStatusCSR) != @bitSizeOf(Tword)) {
                    @compileError("MStatusCSR mismatch");
                };
                const retval = MStatusCSR {
                    .wpri1 = 0,
                    .wpri2 = 0,
                    .wpri3 = 0,
                    .wpri4 = 0,
                    .wpri5 = 0,
                    .wpri6 = 0,

                    .sie = @intFromBool(cpu.sstatus_sie),
                    .mie = @intFromBool(cpu.mstatus_mie),
                    .spie = @intFromBool(cpu.spie),
                    .ube = 0, // u-mode memory fetch endianness
                    .mpie = @intFromBool(cpu.mpie),
                    .spp = cpu.spp.getEncoding(),
                    .vs = 0,
                    .mpp = cpu.mpp.getEncoding(),
                    .fs = 0,
                    .xs = 0,
                    .mprv = 0, // TODO: implement!
                    .sum = @intFromBool(cpu.mstatus_sum),
                    .mxr = @intFromBool(cpu.mstatus_mxr),
                    .tvm = 0, // TODO: implement! satp CSR
                    .tw = 0, // TODO: implement! WFI
                    .tsr = 0, // TODO: implement, SRET for S-mode
                    .spelp = 0, // TODO: wtf is this?
                    .sdt = 0, // TODO: double trap
                    .uxl = 2,   // 64bit in u-mode
                    .sxl = 2,   // 64bit in s-mode
                    .sbe = 0, // s-mode memory fetch endianness
                    .mbe = 0, // s-mode memory fetch endianness
                    .gva = 0, // TODO: implement! paging traps
                    .mpv = 0,
                    .mpelp = 0, // something with ELP?
                    .mdt = 0, // TODO: implement? double traps
                    .sd = 0, // fs, vs and xs
                };
                const retval_word: Tword = @bitCast(retval);
                return retval_word;
            }
        };

        const SStatusCSR = packed struct {
            wpri1: u1,
            sie: u1,
            wpri2: u3,
            spie: u1,
            ube: u1,
            wpri3: u1,
            spp: u1,
            vs: u2,
            wpri4: u2,
            fs: u2,
            xs: u2,
            mprv: u1,
            sum: u1,
            mxr: u1,
            wpri5: u3,
            spelp: u1,
            sdt: u1,
            wpri6: u7,
            uxl: u2,
            wpri7: u29,
            sd: u1,

            fn handleWrite(cpu: *Self, value: Tword) void {
                const new_sstatus: SStatusCSR = @bitCast(value);
                cpu.spp = SppPrivilegeLevel.fromEncoding(new_sstatus.spp);
                cpu.sstatus_sie = new_sstatus.sie != 0;
                cpu.spie = new_sstatus.spie != 0;
                cpu.mstatus_sum = new_sstatus.sum != 0;
                cpu.mstatus_mxr = new_sstatus.mxr != 0;
            }

            fn handleRead(cpu: *const Self) Tword {
                comptime if (@bitSizeOf(SStatusCSR) != @bitSizeOf(Tword)) {
                    @compileError("SStatusCSR mismatch");
                };
                const retval = SStatusCSR {
                    .wpri1 = 0,
                    .wpri2 = 0,
                    .wpri3 = 0,
                    .wpri4 = 0,
                    .wpri5 = 0,
                    .wpri6 = 0,
                    .wpri7 = 0,

                    .sie = @intFromBool(cpu.sstatus_sie),
                    .spie = @intFromBool(cpu.spie),
                    .ube = 0, // u-mode memory fetch endianness
                    .spp = cpu.spp.getEncoding(),
                    .vs = 0,
                    .fs = 0,
                    .xs = 0,
                    .mprv = 0, // TODO: implement!
                    .sum = @intFromBool(cpu.mstatus_sum),
                    .mxr = @intFromBool(cpu.mstatus_mxr),
                    .spelp = 0, // TODO: wtf is this?
                    .sdt = 0, // TODO: double trap
                    .uxl = 2,   // 64bit in u-mode
                    .sd = 0, // fs, vs and xs
                };
                const retval_word: Tword = @bitCast(retval);
                return retval_word;
            }
        };

        const SatpCSR = packed struct {
            ppn: u44,
            asid: u16,
            mode: u4,

            fn handleWrite(cpu: *Self, value: Tword) void {
                cpu.instruction_cache.updateGeneration();
                const parsed: SatpCSR = @bitCast(value);
                cpu.ppn = parsed.ppn;
                cpu.asid = parsed.asid;
                switch (parsed.mode) {
                    0 => cpu.paging_enabled = false,  // no paging
                    8 => cpu.paging_enabled = true,   // sv39
                    else => {},
                }
            }

            fn handleRead(cpu: *const Self) Tword {
                const retval = SatpCSR {
                    .ppn = cpu.ppn,
                    .asid = cpu.asid,
                    .mode = if (cpu.paging_enabled) 8 else 0,
                };
                return @bitCast(retval);
            }
        };

        fn handleWriteMepc(cpu: *Self, value: Tword) void { cpu.mepc = value; }
        fn handleReadMepc(cpu: *const Self) Tword { return cpu.mepc; }
        fn handleWriteMcause(cpu: *Self, value: Tword) void { cpu.mcause = value; }
        fn handleReadMcause(cpu: *const Self) Tword { return cpu.mcause; }
        fn handleWriteMtval(cpu: *Self, value: Tword) void { cpu.mtval = value; }
        fn handleReadMtval(cpu: *const Self) Tword { return cpu.mtval; }

        fn handleWriteSepc(cpu: *Self, value: Tword) void { cpu.sepc = value; }
        fn handleReadSepc(cpu: *const Self) Tword { return cpu.sepc; }
        fn handleWriteScause(cpu: *Self, value: Tword) void { cpu.scause = value; }
        fn handleReadScause(cpu: *const Self) Tword { return cpu.scause; }
        fn handleWriteStval(cpu: *Self, value: Tword) void { cpu.stval = value; }
        fn handleReadStval(cpu: *const Self) Tword { return cpu.stval; }

        fn handleWriteMedeleg(cpu: *Self, value: Tword) void { cpu.medeleg = value & 0xfcb7ff; }
        fn handleReadMedeleg(cpu: *const Self) Tword { return cpu.medeleg; }

        fn handleWriteMideleg(cpu: *Self, value: Tword) void { cpu.mideleg = value; }
        fn handleReadMideleg(cpu: *const Self) Tword { return cpu.mideleg; }

        fn handleWriteMie(cpu: *Self, value: Tword) void { cpu.mie_bits = value; }
        fn handleReadMie(cpu: *const Self) Tword { return cpu.mie_bits; }

        fn handleWriteMcounteren(cpu: *Self, value: Tword) void { cpu.mcounteren = value; }
        fn handleReadMcounteren(cpu: *Self) Tword { return cpu.mcounteren; }

        fn handleWriteScounteren(cpu: *Self, value: Tword) void { cpu.scounteren = value; }
        fn handleReadScounteren(cpu: *Self) Tword { return cpu.scounteren; }

        fn handleWriteQpuCtx(cpu: *Self, value: Tword) void { cpu.qpu_ctx = value; }
        fn handleReadQpuCtx(cpu: *Self) Tword { return cpu.qpu_ctx; }

        fn handleWriteMip(cpu: *Self, value: Tword) void {
            const writable_mask =
                (@as(Tword, 1) << @intFromEnum(InterruptCause.supervisor_software)) |
                (@as(Tword, 1) << @intFromEnum(InterruptCause.supervisor_timer)) |
                (@as(Tword, 1) << @intFromEnum(InterruptCause.machine_timer)) |
                (@as(Tword, 1) << @intFromEnum(InterruptCause.machine_software));
            cpu.mip_bits = (cpu.mip_bits & ~writable_mask) | (value & writable_mask);
        }
        fn handleReadMip(cpu: *const Self) Tword { return cpu.mip_bits; }

        fn handleWriteSie(cpu: *Self, value: Tword) void {
            const delegated_mask = cpu.mideleg;
            cpu.mie_bits = (cpu.mie_bits & ~delegated_mask) | (value & delegated_mask);
        }
        fn handleReadSie(cpu: *const Self) Tword {
            return cpu.mie_bits & cpu.mideleg;
        }

        fn handleWriteSip(cpu: *Self, value: Tword) void {
            const writable_mask = (@as(Tword, 1) << @intFromEnum(InterruptCause.supervisor_software));
            cpu.mip_bits = (cpu.mip_bits & ~writable_mask) | (value & writable_mask);
        }
        fn handleReadSip(cpu: *const Self) Tword {
            return cpu.mip_bits & cpu.mideleg;
        }

        fn handleWriteMscratch(cpu: *Self, value: Tword) void { cpu.mscratch = value; }
        fn handleWriteSscratch(cpu: *Self, value: Tword) void { cpu.sscratch = value; }
        fn handleReadMscratch(cpu: *const Self) Tword { return cpu.mscratch; }
        fn handleReadSscratch(cpu: *const Self) Tword { return cpu.sscratch; }

        fn handleReadZero(_: *const Self) Tword { return 0; }
        fn handleWriteStub(cpu: *Self, _: Tword) void {
            cpu.debugPrint("W: Using write stub\n", .{}) catch @panic("Failed debug print");
        }
        fn handleReadStub(cpu: *const Self) Tword {
            cpu.debugPrint("W: Using read stub\n", .{}) catch @panic("Failed debug print");
            return 0;
        }

        fn handleReadTime(cpu: *Self) Tword {
            return @truncate(cpu._bus.getMtime());
        }

        fn handleReadMisa(_: *const Self) Tword {
            const parsed: packed struct {
                a_extension: u1,
                b_extension: u1,
                c_extension: u1,
                d_extension: u1,
                zero1: u1,
                f_extension: u1,
                g_extension: u1,
                h_extension: u1,
                i_extension: u1,
                zero2: u3,
                m_extension: u1,
                zero3: u3,
                q_extension: u1,
                zero4: u1,
                s_mode_support: u1,
                zero5: u1,
                u_mode_support: u1,
                v_extension: u1,
                zero6: u40,
                mxl: u2,
            } = .{
                .a_extension = @intFromBool(opt.a_extension),
                .s_mode_support = @intFromBool(opt.privileged),
                .m_extension = @intFromBool(opt.m_extension),
                .u_mode_support = @intFromBool(opt.privileged),
                .mxl = switch (opt.word_size) {
                    .w32 => 1,
                    .w64 => 2,
                },

                .b_extension = 0,
                .c_extension = 0,
                .d_extension = 0,
                .zero1 = 0,
                .f_extension = 0,
                .g_extension = 0,
                .h_extension = 0,
                .i_extension = 0,
                .zero2 = 0,
                .zero3 = 0,
                .q_extension = 0,
                .zero4 = 0,
                .zero5 = 0,
                .v_extension = 0,
                .zero6 = 0,
            };
            return @bitCast(parsed);
        }

        const csr_map = [_]CsrMapEntry{
            CsrMapEntry.new("mtvec",   0x305, TrapVectorCSR.handleWriteM,   TrapVectorCSR.handleReadM),
            CsrMapEntry.new("mepc",    0x341, handleWriteMepc,              handleReadMepc),
            CsrMapEntry.new("mcause",  0x342, handleWriteMcause,            handleReadMcause),
            CsrMapEntry.new("mstatus", 0x300, MStatusCSR.handleWrite,       MStatusCSR.handleRead),
            CsrMapEntry.new("mtval",   0x343, handleWriteMtval,             handleReadMtval),

            CsrMapEntry.new("stvec",   0x105, TrapVectorCSR.handleWriteS,   TrapVectorCSR.handleReadS),
            CsrMapEntry.new("sepc",    0x141, handleWriteSepc,              handleReadSepc),
            CsrMapEntry.new("scause",  0x142, handleWriteScause,            handleReadScause),
            CsrMapEntry.new("sstatus", 0x100, SStatusCSR.handleWrite,       SStatusCSR.handleRead),
            CsrMapEntry.new("stval",   0x143, handleWriteStval,             handleReadStval),

            CsrMapEntry.new("meledeg", 0x302, handleWriteMedeleg,           handleReadMedeleg),
            CsrMapEntry.new("mscratch",0x340, handleWriteMscratch,          handleReadMscratch),
            CsrMapEntry.new("sscratch",0x140, handleWriteSscratch,          handleReadSscratch),

            CsrMapEntry.new("misa",    0x301, handleWriteStub,              handleReadMisa),
            CsrMapEntry.new("mcounteren",0x306,handleWriteMcounteren,        handleReadMcounteren),
            CsrMapEntry.new("mvendorid",0xf11,null,                         handleReadZero),

            // TODO: replace with non-stubs
            CsrMapEntry.new("mhartid", 0xf14, null,                        handleReadZero),
            CsrMapEntry.new("pmpcfg0", 0x3a0, handleWriteStub,             handleReadStub),
            CsrMapEntry.new("pmpaddr0",0x3b0, handleWriteStub,             handleReadStub),
            CsrMapEntry.new("mie",     0x304, handleWriteMie,              handleReadMie),
            CsrMapEntry.new("sie",     0x104, handleWriteSie,              handleReadSie),
            CsrMapEntry.new("sip",     0x144, handleWriteSip,              handleReadSip),
            CsrMapEntry.new("mip",     0x344, handleWriteMip,              handleReadMip),
            CsrMapEntry.new("mideleg", 0x303, handleWriteMideleg,          handleReadMideleg),
            CsrMapEntry.new("mnstatus",0x744, handleWriteStub,             handleReadStub),
            CsrMapEntry.new("satp",    0x180, SatpCSR.handleWrite,         SatpCSR.handleRead),
            CsrMapEntry.new("marchid", 0xf12, null,                        handleReadStub),
            CsrMapEntry.new("mimpid",  0xf13, null,                        handleReadStub),

            // LINUX stubs
            // TODO: replace with non-stubs
            CsrMapEntry.new("scounteren",0x106, handleWriteScounteren,     handleReadScounteren),
            CsrMapEntry.new("time",      0xc01, null,                      handleReadTime),

            CsrMapEntry.new("qpuctx",    0x9da, handleWriteQpuCtx,         handleReadQpuCtx),
        };

        fn debugPrint(self: *const Self, comptime format: []const u8, args: anytype) DebugPrintError!void {
            if (self.debug_writer) |writer| {
                writer.print(format, args) catch return error.WriteFailed;
            }
        }

        fn getRegister(self: *const Self, id: usize) Tword {
            return self.registers[id];
        }

        pub fn setRegister(self: *Self, id: usize, val: Tword) void {
            if (id != 0) {
                self.registers[id] = val;
            }
        }

        const TranslationResult = union(enum) {
            Ok: Tword,
            Err: TError,
        };

        fn mapTranslationError(address: Tword, err: (bus.TranslationError || bus.BusError), reason: bus.TranslationReason) TError {
            // TODO: check if these exceptions are correct
            switch (err) {
                error.InvalidPTE,
                error.TranslationTooDeep,
                error.DisallowedOperation,
                error.MisalignedSuperpage,
                error.NonCanonicalVirtualAddress,
                error.PageFault,
                    => return switch (reason) {
                        .Read => TError { .LoadPageFault = address, },
                        .Write => TError { .StorePageFault = address, },
                        .Execute => TError { .InstructionPageFault = address, },
                    },

                error.CannotReadPageTableEntry,
                error.CannotWritePageTableEntry,
                error.AccessFault
                    => return switch (reason) {
                        .Read => TError { .LoadAccessFault = address, },
                        .Write => TError { .StoreAccessFault = address, },
                        .Execute => TError { .InstructionAccessFault = address, },
                    },

                error.AlignmentFault
                    => return switch (reason) {
                        .Read => TError { .LoadAddressMisaligned = address, },
                        .Write => TError { .StoreAddressMisaligned = address, },
                        .Execute => TError { .InstructionAddressMisaligned = address, },
                    },
            }
        }

        fn translateAddress(self: *Self, address: Tword, reason: bus.TranslationReason) TranslationResult {
            var translated_address = address;
            if (self.paging_enabled and self.current_privilege_level != .Machine) {
                translated_address = bus.Paging(Tword).translateAddress(
                    &self._bus,
                    @bitCast(address),
                    self.ppn,
                    reason,
                    .{
                        .privilege = self.current_privilege_level,
                        .sum = self.mstatus_sum,
                        .mxr = self.mstatus_mxr,
                    }
                ) catch |err|
                    return .{ .Err = mapTranslationError(address, err, reason), };
            }
            return TranslationResult {
                .Ok = translated_address,
            };
        }

        // TODO: properly handle misaligned memory in here and writeMemory
        // TODO: maybe split out into byte reads/writes
        fn readMemory(self: *Self, address: Tword, dest: []u8, comptime reason: bus.TranslationReason) ?TError {
            switch (reason) {
                .Execute,
                .Read => {},
                .Write => @compileError("Cannot read memory with write reason"),
            }
            switch (self.translateAddress(address, reason)) {
                .Ok => |new_addr| {
                    self._bus.readMemory(new_addr, dest) catch |err|
                        return mapTranslationError(new_addr, err, reason);
                    return null;
                },
                .Err => |e| {
                    return e;
                },
            }
        }

        fn writeMemory(self: *Self, address: Tword, src: []const u8) ?TError {
            switch (self.translateAddress(address, .Write)) {
                .Ok => |new_addr| {
                    self._bus.writeMemory(new_addr, src) catch |err|
                        return mapTranslationError(new_addr, err, .Write);
                    return null;
                },
                .Err => |e| {
                    return e;
                },
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
                .funct_3_5 => |*v| return v.funct3 == id.funct3 and v.funct5 == (id.funct7 >> 2),
                .direct_match => |*v| {
                    const original: u32 = @bitCast(id);
                    return original == v.*;
                },
            }
            return false;
        }

        fn writeRegisters(self: *Self, writer: std.io.AnyWriter, width: usize) !void {
            for (0..self.registers.len) |i| {
                var buffer: [16]u8 = undefined;
                const sep = if ((i + 1) % width == 0) "\n" else " ";
                const register_name = std.fmt.bufPrint(&buffer, "x{}", .{i}) catch @panic("Format failed");
                const fmt_string = switch (opt.word_size) {
                    .w32 => "{s: >3}={x:0>8}{s}",
                    .w64 => "{s: >3}={x:0>16}{s}",
                };
                try writer.print(fmt_string, .{register_name, self.registers[i], sep});
            }
        }

        fn interruptMask(cause: InterruptCause) Tword {
            return @as(Tword, 1) << @intFromEnum(cause);
        }

        fn interruptPending(self: *const Self, cause: InterruptCause) bool {
            return (self.mip_bits & interruptMask(cause)) != 0;
        }

        fn interruptEnabled(self: *const Self, cause: InterruptCause) bool {
            return (self.mie_bits & interruptMask(cause)) != 0;
        }

        fn setInterruptPending(self: *Self, cause: InterruptCause, pending: bool) void {
            const mask = interruptMask(cause);
            if (pending) {
                self.mip_bits |= mask;
            } else {
                self.mip_bits &= ~mask;
            }
        }

        fn isDelegatedToS(self: *const Self, cause: InterruptCause) bool {
            return (self.mideleg & interruptMask(cause)) != 0;
        }

        fn refreshPendingInterrupts(self: *Self) void {
            if (self._bus.findClint()) |clint| {
                self.setInterruptPending(
                    .machine_timer,
                    clint.shouldInterrupt()
                );
            }

            if (self._bus.findPlic()) |plic| {
                self.setInterruptPending(.machine_external, plic.shouldTrap(0));
                self.setInterruptPending(.supervisor_external, plic.shouldTrap(1));
            } else {
                self.setInterruptPending(.machine_external, false);
                self.setInterruptPending(.supervisor_external, false);
            }
        }

        fn interruptCanTrapToM(self: *const Self, cause: InterruptCause) bool {
            return ((self.current_privilege_level == .Machine and self.mstatus_mie) or
                    (self.current_privilege_level != .Machine)) and
                   self.interruptPending(cause) and
                   self.interruptEnabled(cause) and
                   !self.isDelegatedToS(cause);
        }

        fn interruptCanTrapToS(self: *const Self, cause: InterruptCause) bool {
            return ((self.current_privilege_level == .Supervisor and self.sstatus_sie) or
                    (self.current_privilege_level == .User)) and
                   self.isDelegatedToS(cause) and
                   self.interruptPending(cause) and
                   self.interruptEnabled(cause);
        }

        fn selectPendingInterrupt(self: *Self) ?PendingInterrupt {
            // M-mode destination priority
            const m_priority = [_]InterruptCause{
                .machine_external,
                .machine_software,
                .machine_timer,
                .supervisor_external,
                .supervisor_software,
                .supervisor_timer,
                .local_counter_overflow,
            };
            inline for (m_priority) |cause| {
                if (self.interruptCanTrapToM(cause)) {
                    return .{ .target = .Machine, .cause = cause };
                }
            }

            // S-mode destination priority
            const s_priority = [_]InterruptCause{
                .supervisor_external,
                .supervisor_software,
                .supervisor_timer,
                .local_counter_overflow,
            };
            inline for (s_priority) |cause| {
                if (self.interruptCanTrapToS(cause)) {
                    return .{ .target = .Supervisor, .cause = cause };
                }
            }

            return null;
        }

        fn takeInterrupt(self: *Self, irq: PendingInterrupt) void {
            const cause_code: Tword = @intFromEnum(irq.cause);
            const interrupt_bit: Tword = @as(Tword, 1) << (@bitSizeOf(Tword) - 1);
            const xcause: Tword = interrupt_bit | cause_code;

            switch (irq.target) {
                .Machine => {
                    self.mepc = self.pc;
                    self.mcause = xcause;
                    self.mtval = 0;
                    self.pc = switch (self.m_trap_mode) {
                        .Direct => self.m_trap_handler_address,
                        .Vectored => self.m_trap_handler_address + 4 * cause_code,
                    };
                    self.mpie = self.mstatus_mie;
                    self.mstatus_mie = false;
                    self.mpp = self.current_privilege_level;
                    self.current_privilege_level = .Machine;
                },
                .Supervisor => {
                    self.sepc = self.pc;
                    self.scause = xcause;
                    self.stval = 0;
                    self.pc = switch (self.s_trap_mode) {
                        .Direct => self.s_trap_handler_address,
                        .Vectored => self.s_trap_handler_address + 4 * cause_code,
                    };
                    self.spie = self.sstatus_sie;
                    self.sstatus_sie = false;
                    self.spp = switch (self.current_privilege_level) {
                        .Machine => unreachable,
                        .User => .User,
                        .Supervisor => .Supervisor,
                    };
                    self.current_privilege_level = .Supervisor;
                },
                .User => unreachable,
            }
        }

        fn findMatchingInstruction(instruction_id: InstructionIdentifiers) ?*const Instr {
            for (grouped_instructions[instruction_id.opcode]) |*i| {
                if (matches(instruction_id, i)) {
                    return i;
                }
            }
            return null;
        }

        const InstructionHandlerFetchResult = union(enum) {
            Success: TICache.CachedInstruction,
            IllegalInstruction: u32,
            Exception: TError,
        };

        fn getNextInstructionHandlerWithCache(self: *Self) InstructionHandlerFetchResult {
            switch (self.instruction_cache.cacheLookup(self.pc, self.current_privilege_level) catch @panic("OOM")) {
                .Hit => |hit| {
                    return InstructionHandlerFetchResult { .Success = hit, };
                },
                .Miss => |miss| {
                    var instruction: u32 = undefined;
                    if (self.getNextInstruction(&instruction)) |err| {
                        return InstructionHandlerFetchResult { .Exception = err, };
                    }
                    const instruction_id: InstructionIdentifiers = @bitCast(instruction);
                    if (Self.findMatchingInstruction(instruction_id)) |matched| {
                        return InstructionHandlerFetchResult {
                            .Success = TICache.updateCache(miss, instruction, matched),
                        };
                    }
                    return InstructionHandlerFetchResult { .IllegalInstruction = instruction };
                },
            }
        }

        fn getNextInstructionHandlerNoCache(self: *Self) InstructionHandlerFetchResult {
            var instruction: u32 = undefined;
            if (self.getNextInstruction(&instruction)) |err| {
                return InstructionHandlerFetchResult { .Exception = err, };
            }
            const instruction_id: InstructionIdentifiers = @bitCast(instruction);
            if (Self.findMatchingInstruction(instruction_id)) |matched| {
                return InstructionHandlerFetchResult {
                    .Success = .{
                        .instruction = instruction,
                        .handler = matched,
                    },
                };
            }
            return InstructionHandlerFetchResult { .IllegalInstruction = instruction };
        }

        fn getNextInstructionHandler(self: *Self) InstructionHandlerFetchResult {
            return self.getNextInstructionHandlerWithCache();
        }

        fn runHandler(self: *Self, instruction_handle: *const Instr, instruction: u32) ?TError {
            return instruction_handle.handler(self, instruction);
        }

        fn executeInstruction(self: *Self) DebugPrintError!?TError {
            std.debug.assert(!self.isHalted());
            std.debug.assert(self.registers[0] == 0);
            self.refreshPendingInterrupts();
            if (self.selectPendingInterrupt()) |irq| {
                self.takeInterrupt(irq);
                return null;
            }

            switch (self.getNextInstructionHandler()) {
                .Success => |*instruction| {
                    const execution_error = self.runHandler(instruction.handler, instruction.instruction);
                    if (execution_error) |err| {
                        return err;
                    }
                    if (instruction.handler.advance_pc) {
                        self.pc += 4;
                    }
                    return null;
                },
                .IllegalInstruction => |instruction| {
                    return TError { .IllegalInstruction = @intCast(instruction) };
                },
                .Exception => |err| {
                    return err;
                },
            }
        }

        pub fn tick(self: *Self) !void {
            if (self.gdb_connection) |*conn| {
                const continue_running = conn.poll(self) catch @panic("IO error");
                if (!continue_running) {
                    return;
                }
            }
            try self._bus.handleIo();
            const execution_error = try self.executeInstruction();
            if (execution_error) |err| {
                switch (err) {
                    .IllegalInstruction => |*instr| {
                        const instruction: u32 = @truncate(instr.*);
                        const instruction_id: InstructionIdentifiers = @bitCast(instruction);
                        std.debug.print("Illegal instruction, instr={x}, opcode=0x{x}, funct3=0x{x}, funct7=0x{x}\n", .{instr.*, instruction_id.opcode, instruction_id.funct3, instruction_id.funct7});
                    },
                    else => {
                        std.debug.print("Trapping on {any}\n", .{err});
                    },
                }
                self.trap(err);
            }
        }

        fn checkMask(deleg: Tword, interrupt_id: Tword) bool {
            const cause_small: u5 = @truncate(interrupt_id);
            const do_delegation: bool = (deleg >> cause_small) & 1 == 1;
            return do_delegation;
        }

        fn trap_to_mmode(self: *Self, err: TError) void {
            self.mepc = self.pc;
            self.mcause = err.getCode();
            if (err.getVal()) |val| {
                self.mtval = val;
            } else {
                self.mtval = 0;
            }
            // TODO: handle vectored
            std.debug.assert(self.m_trap_mode == .Direct);
            self.pc = self.m_trap_handler_address;
            self.mpie = self.mstatus_mie;
            self.mstatus_mie = false;
            self.mpp = self.current_privilege_level;
            self.current_privilege_level = .Machine;
        }

        fn trap_to_smode(self: *Self, err: TError) void {
            self.sepc = self.pc;
            self.scause = err.getCode();
            if (err.getVal()) |val| {
                self.stval = val;
            } else {
                self.stval = 0;
            }
            // TODO: handle vectored
            std.debug.assert(self.m_trap_mode == .Direct);
            self.pc = self.s_trap_handler_address;
            self.spie = self.sstatus_sie;
            self.sstatus_sie = false;
            self.spp = switch (self.current_privilege_level) {
                .Machine => unreachable,
                .User => SppPrivilegeLevel.User,
                .Supervisor => SppPrivilegeLevel.Supervisor,
            };
            self.current_privilege_level = .Supervisor;
        }

        fn trap(self: *Self, err: TError) void {
            // TODO: use same checkMask function
            const cause_small: u5 = @truncate(err.getCode());
            const do_delegation: bool = (self.medeleg >> cause_small) & 1 == 1;
            if (self.current_privilege_level != .Machine and do_delegation) {
                self.trap_to_smode(err);
            } else {
                self.trap_to_mmode(err);
            }
        }

        fn getNextInstruction(self: *Self, instruction: *u32) ?TError {
            var bytes: [4]u8 = undefined;
            if (self.readMemory(self.pc, &bytes, .Execute)) |err| {
                return err;
            }
            instruction.* = std.mem.readInt(u32, &bytes, LittleEndian);
            return null;
        }

        pub fn loadData(self: *Self, start: Tword, buffer: []const u8) !void {
            if (self.writeMemory(start, buffer) != null) {
                return error.LoadFailed;
            }
        }

        pub fn loadZeroes(self: *Self, start: Tword, count: Tword) !void {
            if (count > 0) {
                var buffer: [1024*1024]u8 = undefined;
                const slice = buffer[0..count];
                @memset(slice, 0);
                if (self.writeMemory(start, slice) != null) {
                    return error.LoadFailed;
                }
            }
        }
        
        fn debugGetRegisters(self: *const Self) [32]Tword {
            var result: [32]Tword = undefined;
            for (0..32) |i| {
                result[i] = self.getRegister(i);
            }
            return result;
        }

        fn debugGetPc(self: *const Self) Tword {
            return self.pc;
        }

        fn debugReadMemory(self: *Self, memory_start: Tword, dest: []u8) Tword {
            for (0..dest.len) |i| {
                var curr_byte: [1]u8 = undefined;
                // TODO: returning a slice would be better
                if (self.readMemory(memory_start + i, &curr_byte, .Read) != null) return i;
                dest[i] = curr_byte[0];
            }
            return dest.len;
        }

        // fn debugGetCSRs(self: *Self, allocator: Allocator) []gdb_server.CsrNameValuePair {
        //     const result = allocator.alloc(gdb_server.CsrNameValuePair, Self.csr_map.len) catch @panic("Failed alloc");
        //     for (0..csr_map.len) |i| {
        //         result[i] = .{
        //             .name = csr_map[i].name,
        //             .value = csr_map[i].read_handler(self),
        //         };
        //     }
        //     return result;
        // }

        fn debugGetPPN(self: *const Self) u44 {
            return self.ppn;
        }

        fn debugGetPTEs(self: *Self, allocator: Allocator, ppn: u44) ?[]struct {usize, bus.Paging(Tword).PageTableEntry} {
            return bus.Paging(Tword).getPageTableEntries(allocator, &self._bus, ppn)
                catch |err| {
                    std.debug.print("Cannot read memory map: {any}", .{err});  
                    return null;
                };
        }

        fn debugTranslateAddress(self: *Self, virtual_address: Tword) ?Tword {
            switch (self.translateAddress(virtual_address, .Read)) {
                .Err => return null,
                .Ok => |r| return r,
            }
        }

        fn makeDebugInterface() gdb_server.DebugInterface(opt) {
            return .{
                .readRegisters = Self.debugGetRegisters,
                .getPc = Self.debugGetPc,
                .readMemory = Self.debugReadMemory,
                // .getCsrs = Self.debugGetCSRs,
                .getPPN = Self.debugGetPPN,
                .getPTEs = Self.debugGetPTEs,
                .translateAddress = Self.debugTranslateAddress,
            };
        }

        pub fn initWithBus(
            allocator: Allocator,
            entrypoint: Tword,
            cpu_bus: Bus(Tword),
            debug_writer: ?std.io.AnyWriter,
            signature_info: ?SignatureInfo,
            debugger_filepath: ?[]const u8,
        ) !RVCPU(opt) {
            const gdb_connection = if (debugger_filepath) |debugger_path|
                try gdb_server.GdbDebugServer(opt).init(
                    allocator,
                    debugger_path,
                    Self.makeDebugInterface()
                ) else null;
            return .{
                .allocator = allocator,
                .registers = std.mem.zeroes([32]Tword),
                .pc = entrypoint,
                ._bus = cpu_bus,
                .test_result = null,
                .debug_writer = debug_writer,
                .signature_info = signature_info,
                .m_trap_handler_address = 0,
                .m_trap_mode = .Direct,
                .s_trap_handler_address = 0,
                .s_trap_mode = .Direct,
                .mepc = 0,
                .mcause = 0,
                .mtval = 0,
                .sepc = 0,
                .scause = 0,
                .stval = 0,
                .current_privilege_level = .Machine,
                .mpp = .User,
                .spp = .User,
                .mstatus_mie = false,
                .sstatus_sie = false,
                .mpie = false,
                .spie = false,
                .mstatus_sum = false,
                .mstatus_mxr = false,
                .medeleg = 0,
                .mideleg = 0,
                .mie_bits = 0,
                .mip_bits = 0,
                .mcounteren = 0b111,
                .scounteren = 0,
                .mscratch = 0,
                .sscratch = 0,
                .memory_reservation = null,
                .gdb_connection = gdb_connection,
                .paging_enabled = false,
                .asid = 0,
                .ppn = 0,
                .qpu_ctx = 0,
                .qpu = qpu.Qpu(Tword).init(allocator),
                .instruction_cache = try TICache.init(allocator, 1048573),
            };
        }

        pub fn deinit(self: *Self) void {
            self._bus.deinit(self.allocator);
            self.instruction_cache.deinit();
            self.qpu.deinit();
        }

        pub fn isHalted(self: *Self) bool {
            if (self.signature_info) |signature_info| {
                const word = self._bus.readWord(signature_info.tohost_address) catch unreachable;
                if (word > 0) {
                    self.test_result = TestResult(Tword) {
                        .a0 = word >> 1,
                    };
                }
            }
            if (self._bus.shouldPoweroff()) return true;
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
            if (self.signature_info) |signature_info| {
                const signature_length = signature_info.signature_end - signature_info.signature_start;
                const buffer: []u8 = try allocator.alloc(u8, @intCast(signature_length));
                try self._bus.readMemory(signature_info.signature_start, buffer);
                return buffer;
            } else {
                return try allocator.alloc(u8, 0);
            }
        }

        pub fn signatureNeeded(self: *Self) bool {
            return self.signature_start != self.signature_end;
        }

        fn findCsr(id: Tcsrid) ?*const CsrMapEntry {
            for (&csr_map) |*csr| {
                if (csr.id == id) {
                    return csr;
                }
            }
            std.debug.print("W: returning zero for {x}\n", .{id});
            return null;
        }

        fn getCsrPrivilegeRequirement(id: Tcsrid) u2 {
            return @truncate((id >> 8) & 0b11);
        }

        fn readCsr(self: *Self, id: Tcsrid) ?Tword {
            if (self.current_privilege_level.getEncoding() < Self.getCsrPrivilegeRequirement(id)) {
                return null;
            }
            if (findCsr(id)) |csr| {
                const csr_read = csr.read_handler(self);
                return csr_read;
            }
            return null;
        }

        fn writeCsr(self: *Self, id: Tcsrid, value: Tword) ?TError {
            if (self.current_privilege_level.getEncoding() < Self.getCsrPrivilegeRequirement(id)) {
                return null;
            }
            if (findCsr(id)) |csr| {
                if (csr.write_handler) |handler| {
                    handler(self, value);
                    return null;
                }
            }
            // TODO: maybe do the proper?
            return TError { .IllegalInstruction = 0, };
        }

        fn handleAdd(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) +% self.getRegister(parsed.rs2)
            );
            return null;
        }

        fn handleSub(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) -% self.getRegister(parsed.rs2)
            );
            return null;
        }

        fn handleXor(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) ^ self.getRegister(parsed.rs2)
            );
            return null;
        }

        fn handleOr(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) | self.getRegister(parsed.rs2)
            );
            return null;
        }

        fn handleAnd(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) & self.getRegister(parsed.rs2)
            );
            return null;
        }

        fn handleSll(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: shiftLen() = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) << shift_len
            );
            return null;
        }

        fn handleSrl(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: shiftLen() = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) >> shift_len
            );
            return null;
        }

        fn handleSra(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: shiftLen() = @truncate(self.getRegister(parsed.rs2));
            const src_signed: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const result_signed = src_signed >> shift_len;
            self.setRegister(
                parsed.rd,
                @bitCast(result_signed)
            );
            return null;
        }

        fn handleSlt(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const rs1: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const rs2: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                if (rs1 < rs2) 1 else 0
            );
            return null;
        }

        fn handleSltu(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const rs1 = self.getRegister(parsed.rs1);
            const rs2 = self.getRegister(parsed.rs2);
            self.setRegister(
                parsed.rd,
                if (rs1 < rs2) 1 else 0
            );
            return null;
        }

        fn handleAddi(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_signed = signExtend(Tword, parsed.imm);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) +% imm_signed
            );
            return null;
        }

        fn handleXori(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) ^ signExtend(Tword, parsed.imm)
            );
            return null;
        }

        fn handleOri(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) | signExtend(Tword, parsed.imm)
            );
            return null;
        }

        fn handleAndi(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) & signExtend(Tword, parsed.imm)
            );
            return null;
        }

        fn handleSlli(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_split: Tshamt = @bitCast(parsed.imm);
            self.setRegister(
                parsed.rd,
                (self.getRegister(parsed.rs1) << imm_split.shift_len)
            );
            return null;
        }

        fn handleSrli(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_split: Tshamt = @bitCast(parsed.imm);
            self.setRegister(
                parsed.rd,
                (self.getRegister(parsed.rs1) >> imm_split.shift_len)
            );
            return null;
        }

        fn handleSrai(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_split: Tshamt = @bitCast(parsed.imm);
            const signed_src: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const shifted = signed_src >> imm_split.shift_len;
            const result: Tword = @bitCast(shifted);
            self.setRegister(parsed.rd, result);
            return null;
        }

        fn handleSlti(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const rs1: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const imm: toSigned(Tword) = @bitCast(signExtend(Tword, parsed.imm));
            self.setRegister(
                parsed.rd,
                if (rs1 < imm) 1 else 0
            );
            return null;
        }

        fn handleSltiu(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const rs1 = self.getRegister(parsed.rs1);
            const imm: Tword = @bitCast(signExtend(Tword, parsed.imm));
            self.setRegister(
                parsed.rd,
                if (rs1 < imm) 1 else 0
            );
            return null;
        }

        fn handleAddiw(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const added: Tword = self.getRegister(parsed.rs1) +% signExtend(Tword, parsed.imm);
            const truncated: u32 = @truncate(added);
            self.setRegister(
                parsed.rd,
                signExtend(Tword, truncated)
            );
            return null;
        }

        fn handleSlliw(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_split: Tshamt32 = @bitCast(parsed.imm);
            const truncated: u32 = @truncate(self.getRegister(parsed.rs1));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, truncated << imm_split.shift_len)
            );
            return null;
        }

        fn handleSrliw(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_split: Tshamt32 = @bitCast(parsed.imm);
            const truncated: u32 = @truncate(self.getRegister(parsed.rs1));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, truncated >> imm_split.shift_len)
            );
            return null;
        }

        fn handleSraiw(self: *Self, instruction: u32) ?TError {
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
            return null;
        }

        fn handleAddw(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a: u32 = @truncate(self.getRegister(parsed.rs1));
            const b: u32 = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, a +% b)
            );
            return null;
        }

        fn handleSubw(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a: u32 = @truncate(self.getRegister(parsed.rs1));
            const b: u32 = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, a -% b)
            );
            return null;
        }

        fn handleSllw(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: u5 = @truncate(self.getRegister(parsed.rs2));
            const truncated: u32 = @truncate(self.getRegister(parsed.rs1));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, truncated << shift_len)
            );
            return null;
        }

        fn handleSrlw(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: u5 = @truncate(self.getRegister(parsed.rs2));
            const truncated: u32 = @truncate(self.getRegister(parsed.rs1));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, truncated >> shift_len)
            );
            return null;
        }

        fn handleSraw(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const shift_len: u5 = @truncate(self.getRegister(parsed.rs2));
            const truncated: u32 = @truncate(self.getRegister(parsed.rs1));
            const truncated_signed: i32 = @bitCast(truncated);
            const result_signed = truncated_signed >> shift_len;
            self.setRegister(
                parsed.rd,
                signExtend(Tword, result_signed)
            );
            return null;
        }

        fn genericLoadHandler(self: *Self, T: type, instruction: u32, comptime sign_extend: bool) ?TError {
            const bitcnt = @typeInfo(T).int.bits;
            const parsed: ITypeInstruction = @bitCast(instruction);
            const imm_extended = signExtend(Tword, parsed.imm);
            const address = self.getRegister(parsed.rs1) +% imm_extended;
            var bytes_read: [bitcnt/8]u8 = undefined;
            if (self.readMemory(address, &bytes_read, .Read)) |err| return err;
            const read_memory: T = std.mem.readInt(T, &bytes_read, LittleEndian);
            const result: Tword = if (sign_extend) signExtend(Tword, read_memory) else @intCast(read_memory);
            self.setRegister(parsed.rd, result);
            return null;
        }

        fn handleLb(self: *Self, instruction: u32) ?TError {
            return self.genericLoadHandler(u8, instruction, true);
        }

        fn handleLh(self: *Self, instruction: u32) ?TError {
            return self.genericLoadHandler(u16, instruction, true);
        }

        fn handleLw(self: *Self, instruction: u32) ?TError {
            return self.genericLoadHandler(u32, instruction, true);
        }

        fn handleLd(self: *Self, instruction: u32) ?TError {
            return self.genericLoadHandler(u64, instruction, true);
        }

        fn handleLbu(self: *Self, instruction: u32) ?TError {
            return self.genericLoadHandler(u8, instruction, false);
        }

        fn handleLhu(self: *Self, instruction: u32) ?TError {
            return self.genericLoadHandler(u16, instruction, false);
        }

        fn handleLwu(self: *Self, instruction: u32) ?TError {
            return self.genericLoadHandler(u32, instruction, false);
        }

        fn genericStoreHandler(self: *Self, T: type, instruction: u32) ?TError {
            const bitcnt = @typeInfo(T).int.bits;
            const parsed: STypeInstruction = @bitCast(instruction);
            const imm_extended = signExtend(Tword, parsed.getImm());
            const address = self.getRegister(parsed.rs1) +% imm_extended;
            var to_write: [@typeInfo(Tword).int.bits/8]u8 = undefined;
            std.mem.writeInt(Tword, &to_write, self.getRegister(parsed.rs2), LittleEndian);
            return self.writeMemory(address, to_write[0..(bitcnt/8)]);
        }

        fn handleSb(self: *Self, instruction: u32) ?TError {
            return self.genericStoreHandler(u8, instruction);
        }

        fn handleSh(self: *Self, instruction: u32) ?TError {
            return self.genericStoreHandler(u16, instruction);
        }

        fn handleSw(self: *Self, instruction: u32) ?TError {
            return self.genericStoreHandler(u32, instruction);
        }

        fn handleSd(self: *Self, instruction: u32) ?TError {
            return self.genericStoreHandler(u64, instruction);
        }

        fn handleBeq(self: *Self, instruction: u32) ?TError {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm(Tword);
            if (self.getRegister(parsed.rs1) == self.getRegister(parsed.rs2)) {
                self.pc +%= imm;
            } else {
                self.pc += 4;
            }
            return null;
        }

        fn handleBne(self: *Self, instruction: u32) ?TError {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm(Tword);
            if (self.getRegister(parsed.rs1) != self.getRegister(parsed.rs2)) {
                self.pc +%= imm;
            } else {
                self.pc += 4;
            }
            return null;
        }

        fn handleBlt(self: *Self, instruction: u32) ?TError {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm(Tword);
            const reg1: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const reg2: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs2));
            if (reg1 < reg2) {
                self.pc +%= imm;
            } else {
                self.pc +%= 4;
            }
            return null;
        }

        fn handleBge(self: *Self, instruction: u32) ?TError {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm(Tword);
            const reg1: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs1));
            const reg2: toSigned(Tword) = @bitCast(self.getRegister(parsed.rs2));
            if (reg1 >= reg2) {
                self.pc +%= imm;
            } else {
                self.pc +%= 4;
            }
            return null;
        }

        fn handleBltu(self: *Self, instruction: u32) ?TError {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm(Tword);
            if (self.getRegister(parsed.rs1) < self.getRegister(parsed.rs2)) {
                self.pc +%= imm;
            } else {
                self.pc +%= 4;
            }
            return null;
        }

        fn handleBgeu(self: *Self, instruction: u32) ?TError {
            const parsed: BTypeInstruction = @bitCast(instruction);
            const imm = parsed.getImm(Tword);
            if (self.getRegister(parsed.rs1) >= self.getRegister(parsed.rs2)) {
                self.pc +%= imm;
            } else {
                self.pc +%= 4;
            }
            return null;
        }

        fn handleJal(self: *Self, instruction: u32) ?TError {
            const parsed: JTypeInstruction = @bitCast(instruction);
            self.setRegister(parsed.rd, self.pc + 4);
            const imm = parsed.getImm(Tword);
            self.pc +%= imm;
            return null;
        }

        fn handleJalr(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const new_pc = self.getRegister(parsed.rs1) +% signExtend(Tword, parsed.imm);
            self.setRegister(parsed.rd, self.pc + 4);
            self.pc = new_pc;
            return null;
        }

        fn handleLui(self: *Self, instruction: u32) ?TError {
            const parsed: UTypeInstruction = @bitCast(instruction);
            const imm: u32 = @intCast(parsed.imm);
            self.setRegister(
                parsed.rd,
                signExtend(Tword, imm << 12),
            );
            return null;
        }

        fn handleAuipc(self: *Self, instruction: u32) ?TError {
            const parsed: UTypeInstruction = @bitCast(instruction);
            const imm = @as(u32, parsed.imm) << 12;
            self.setRegister(
                parsed.rd,
                self.pc +% signExtend(Tword, imm),
            );
            return null;
        }

        fn handleEcall(self: *Self, _: u32) ?TError {
            return switch (self.current_privilege_level) {
                .User => TError.EcallFromU,
                .Supervisor => TError.EcallFromS,
                .Machine => TError.EcallFromM,
            };
        }

        fn handleEbreak(self: *Self, _: u32) ?TError {
            return TError{ .Breakpoint = self.pc };
        }

        fn handleMul(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            self.setRegister(
                parsed.rd,
                self.getRegister(parsed.rs1) *% self.getRegister(parsed.rs2)
            );
            return null;
        }

        fn handleMulh(self: *Self, instruction: u32) ?TError {
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
            return null;
        }

        fn handleMulhsu(self: *Self, instruction: u32) ?TError {
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
            return null;
        }

        fn handleMulhu(self: *Self, instruction: u32) ?TError {
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
            return null;
        }

        fn handleDiv(self: *Self, instruction: u32) ?TError {
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
            return null;
        }
        
        fn handleDivu(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a = self.getRegister(parsed.rs1);
            const b = self.getRegister(parsed.rs2);
            self.setRegister(
                parsed.rd,
                if (b == 0) std.math.maxInt(Tword) else a / b
            );
            return null;
        }

        fn handleRem(self: *Self, instruction: u32) ?TError {
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
            return null;
        }

        fn handleRemu(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a = self.getRegister(parsed.rs1);
            const b = self.getRegister(parsed.rs2);
            self.setRegister(
                parsed.rd,
                if (b == 0) a else a % b
            );
            return null;
        }

        fn handleMulw(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a: u32 = @truncate(self.getRegister(parsed.rs1));
            const b: u32 = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, a *% b)
            );
            return null;
        }
        
        fn handleDivw(self: *Self, instruction: u32) ?TError {
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
            return null;
        }

        fn handleDivuw(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a: u32 = @truncate(self.getRegister(parsed.rs1));
            const b: u32 = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                if (b == 0) std.math.maxInt(Tword) else signExtend(Tword, a / b)
            );
            return null;
        }

        fn handleRemw(self: *Self, instruction: u32) ?TError {
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
            return null;
        }

        fn handleRemuw(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const a: u32 = @truncate(self.getRegister(parsed.rs1));
            const b: u32 = @truncate(self.getRegister(parsed.rs2));
            self.setRegister(
                parsed.rd,
                signExtend(Tword, if (b == 0) a else a % b)
            );
            return null;
        }

        // TODO: check about the side-effects for these
        // TODO: CSR permissions
        // TODO: faults on unknown CSRs
        fn handleCsrrw(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const new_csr = self.getRegister(parsed.rs1);
            if (parsed.rd != 0) {
                const old_csr = self.readCsr(parsed.imm)
                    orelse return TError { .IllegalInstruction = @intCast(instruction), };
                self.setRegister(parsed.rd, old_csr);
            }
            return self.writeCsr(parsed.imm, new_csr);
        }
        
        fn handleCsrr_debug(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            if (parsed.rd != 0) {
                const csr = self.readCsr(parsed.imm)
                    orelse @panic("Debug CSR reading failed!");
                self.setRegister(parsed.rd, csr);
            }
            return null;
        }

        fn handleCsrrs(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const old_csr = self.readCsr(parsed.imm)
                orelse return TError { .IllegalInstruction = @intCast(instruction), };
            const mask = self.getRegister(parsed.rs1);
            self.setRegister(parsed.rd, old_csr);
            if (parsed.rs1 != 0) {
                const new_csr = old_csr | mask;
                return self.writeCsr(parsed.imm, new_csr);
            }
            return null;
        }

        fn handleCsrrc(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const old_csr = self.readCsr(parsed.imm)
                orelse return TError { .IllegalInstruction = @intCast(instruction), };
            const mask = self.getRegister(parsed.rs1);
            self.setRegister(parsed.rd, old_csr);
            if (parsed.rs1 != 0) {
                const new_csr = old_csr & (~mask);
                return self.writeCsr(parsed.imm, new_csr);
            }
            return null;
        }

        fn handleCsrrwi(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            if (parsed.rd != 0) {
                const old_csr = self.readCsr(parsed.imm)
                    orelse return TError { .IllegalInstruction = @intCast(instruction), };
                self.setRegister(parsed.rd, old_csr);
            }
            const imm_extended: Tword = @intCast(parsed.rs1);
            return self.writeCsr(parsed.imm, imm_extended);
        }

        fn handleCsrrsi(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const old_csr = self.readCsr(parsed.imm)
                orelse return TError { .IllegalInstruction = @intCast(instruction), };
            self.setRegister(parsed.rd, old_csr);
            if (parsed.rs1 != 0) {
                const mask: Tword = @intCast(parsed.rs1);
                const new_csr = old_csr | mask;
                return self.writeCsr(parsed.imm, new_csr);
            }
            return null;
        }

        fn handleCsrrci(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            const old_csr = self.readCsr(parsed.imm)
                orelse return TError { .IllegalInstruction = @intCast(instruction), };
            self.setRegister(parsed.rd, old_csr);
            if (parsed.rs1 != 0) {
                const mask: Tword = @intCast(parsed.rs1);
                const new_csr = old_csr & (~mask);
                return self.writeCsr(parsed.imm, new_csr);
            }
            return null;
        }

        fn handleGetpriv(self: *Self, instruction: u32) ?TError {
            const parsed: ITypeInstruction = @bitCast(instruction);
            self.setRegister(parsed.rd, @intCast(self.current_privilege_level.getEncoding()));
            return null;
        }

        fn handleMret(self: *Self, _: u32) ?TError {
            self.mstatus_mie = self.mpie;
            self.pc = self.mepc;
            // TODO: what is mprv?
            // if (self.mpp != .Machine) {
            //     self.mprv = 0;
            // }
            self.current_privilege_level = self.mpp;
            self.mpie = true;
            self.mpp = .User;
            return null;
        }

        fn handleSret(self: *Self, _: u32) ?TError {
            self.sstatus_sie = self.spie;
            self.pc = self.sepc;
            // TODO: is there sprv, like mprv?
            self.current_privilege_level = self.spp.toRegular();
            self.spie = true;
            self.spp = .User;
            return null;
        }

        fn handleGenericAtomicOp(T: type, self: *Self, instruction: u32, operation: anytype) ?TError {
            const num_bytes = @divExact(@typeInfo(T).int.bits, 8);
            var bytes_read: [num_bytes]u8 = undefined;
            const parsed: RTypeInstruction = @bitCast(instruction);
            const address = self.getRegister(parsed.rs1);
            if (self.readMemory(address, &bytes_read, .Read)) |err| return err;
            const old_memory_value: T = std.mem.readInt(T, &bytes_read, .little);
            const truncated: T = @truncate(self.getRegister(parsed.rs2));
            const new_value = operation.f(T, old_memory_value, truncated);
            self.setRegister(parsed.rd, signExtend(Tword, old_memory_value));
            std.mem.writeInt(T, &bytes_read, new_value, .little);
            if (self.writeMemory(address, &bytes_read)) |err| return err;
            return null;
        }

        fn handleAmoswapW(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u32, self, instruction, struct {
                fn f(T: type, _: T, b: T) T {
                    return b;
                }
            });
        }

        fn handleAmoaddW(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u32, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    return a +% b;
                }
            });
        }

        fn handleAmoandW(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u32, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    return a & b;
                }
            });
        }

        fn handleAmoorW(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u32, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    return a | b;
                }
            });
        }

        fn handleAmoxorW(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u32, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    return a ^ b;
                }
            });
        }

        fn handleAmominW(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u32, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    const a_signed: toSigned(T) = @bitCast(a);
                    const b_signed: toSigned(T) = @bitCast(b);
                    if (a_signed < b_signed) { return a; }
                    else { return b; }
                }
            });
        }

        fn handleAmomaxW(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u32, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    const a_signed: toSigned(T) = @bitCast(a);
                    const b_signed: toSigned(T) = @bitCast(b);
                    if (a_signed > b_signed) { return a; }
                    else { return b; }
                }
            });
        }

        fn handleAmominuW(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u32, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    if (a < b) { return a; }
                    else { return b; }
                }
            });
        }

        fn handleAmomaxuW(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u32, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    if (a > b) { return a; }
                    else { return b; }
                }
            });
        }

        fn handleAmoswapD(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u64, self, instruction, struct {
                fn f(T: type, _: T, b: T) T {
                    return b;
                }
            });
        }

        fn handleAmoaddD(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u64, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    return a +% b;
                }
            });
        }

        fn handleAmoandD(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u64, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    return a & b;
                }
            });
        }

        fn handleAmoorD(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u64, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    return a | b;
                }
            });
        }

        fn handleAmoxorD(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u64, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    return a ^ b;
                }
            });
        }

        fn handleAmominD(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u64, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    const a_signed: toSigned(T) = @bitCast(a);
                    const b_signed: toSigned(T) = @bitCast(b);
                    if (a_signed < b_signed) { return a; }
                    else { return b; }
                }
            });
        }

        fn handleAmomaxD(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u64, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    const a_signed: toSigned(T) = @bitCast(a);
                    const b_signed: toSigned(T) = @bitCast(b);
                    if (a_signed > b_signed) { return a; }
                    else { return b; }
                }
            });
        }

        fn handleAmominuD(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u64, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    if (a < b) { return a; }
                    else { return b; }
                }
            });
        }

        fn handleAmomaxuD(self: *Self, instruction: u32) ?TError {
            return Self.handleGenericAtomicOp(u64, self, instruction, struct {
                fn f(T: type, a: T, b: T) T {
                    if (a > b) { return a; }
                    else { return b; }
                }
            });
        }

        fn handleLrGeneric(T: type, self: *Self, instruction: u32) ?TError {
            const byte_count = @divExact(@typeInfo(T).int.bits, 8);
            const parsed: RTypeInstruction = @bitCast(instruction);
            if (parsed.rs2 != 0) {
                return TError { .IllegalInstruction = 0, };
            }
            const address = self.getRegister(parsed.rs1);
            if (!isAligned(Tword, T, address)) {
                return TError { .LoadAddressMisaligned = address, };
            }
            var buffer: [byte_count]u8 = undefined;
            if (self.readMemory(address, &buffer, .Read)) |err| return err;
            self.memory_reservation = MemoryReservation {
                .address = address,
                .length = byte_count,
            };
            self.setRegister(
                parsed.rd,
                signExtend(Tword, std.mem.readInt(T, &buffer, .little))
            );
            return null;
        }

        fn handleScGeneric(T: type, self: *Self, instruction: u32) ?TError {
            const byte_count = @divExact(@typeInfo(T).int.bits, 8);
            const parsed: RTypeInstruction = @bitCast(instruction);
            const address = self.getRegister(parsed.rs1);
            if (!isAligned(Tword, T, address)) {
                return TError { .LoadAddressMisaligned = address, };
            }
            var return_value: Tword = 1;
            if (self.memory_reservation) |reservation| {
                if (
                    reservation.address == address and
                    reservation.length == byte_count
                ) {
                    var buffer: [byte_count]u8 = undefined;
                    const register_value: T = @truncate(self.getRegister(parsed.rs2));
                    std.mem.writeInt(T, &buffer, register_value, .little);
                    return_value = 0;
                    if (self.writeMemory(address, &buffer)) |err| return err;
                }
            }
            self.setRegister(parsed.rd, return_value);
            self.memory_reservation = null;
            return null;
        }

        fn handleLrW(self: *Self, instruction: u32) ?TError {
            return Self.handleLrGeneric(u32, self, instruction);
        }

        fn handleLrD(self: *Self, instruction: u32) ?TError {
            return Self.handleLrGeneric(u64, self, instruction);
        }

        fn handleScW(self: *Self, instruction: u32) ?TError {
            return Self.handleScGeneric(u32, self, instruction);
        }

        fn handleScD(self: *Self, instruction: u32) ?TError {
            return Self.handleScGeneric(u64, self, instruction);
        }

        fn handleFenceI(self: *Self, _: u32) ?TError {
            self.instruction_cache.updateGeneration();
            return null;
        }

        fn handleQpuNewContext(self: *Self, instruction: u32) ?TError {
            if (self.current_privilege_level.getEncoding() <
                PrivilegeLevel.Supervisor.getEncoding())
                    return TError {
                        .IllegalInstruction = instruction,
                    };
            const parsed: RTypeInstruction = @bitCast(instruction);
            const new_context_handle = self.qpu.allocateContext();
            self.setRegister(
                parsed.rd,
                new_context_handle
            );
            return null;
        }

        fn handleQpuFreeContext(self: *Self, instruction: u32) ?TError {
            if (self.current_privilege_level.getEncoding() <
                PrivilegeLevel.Supervisor.getEncoding())
                    return TError {
                        .IllegalInstruction = instruction,
                    };
            const parsed: RTypeInstruction = @bitCast(instruction);
            const context_handle = self.getRegister(parsed.rs1);
            self.qpu.freeContext(context_handle)
                catch |err| {
                    std.debug.print("Failed freeing QPU context: {}\n", .{err});
                    return TError { .IllegalInstruction = instruction };
                };
            return null;
        }

        fn handleQpuCloneContext(self: *Self, instruction: u32) ?TError {
            if (self.current_privilege_level.getEncoding() <
                PrivilegeLevel.Supervisor.getEncoding())
                    return TError {
                        .IllegalInstruction = instruction,
                    };
            //std.debug.print("W: trying to clone context!\n", .{});
            return TError { .IllegalInstruction = instruction };
        }

        fn handleQpuNewRegister(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const initval = self.getRegister(parsed.rs1);
            const width = self.getRegister(parsed.rs2);
            const handle = self.qpu.newRegister(self.qpu_ctx, initval, width)
                catch return TError { .IllegalInstruction = instruction };
            self.setRegister(parsed.rd, handle);
            return null;
        }

        fn handleQpuCnot(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const control = self.getRegister(parsed.rs1);
            const target = self.getRegister(parsed.rs2);
            const register = self.getRegister(parsed.rd);
            //std.debug.print("Applying CNOT, {} {} {}\n", .{control, target, register});
            self.qpu.cnot(self.qpu_ctx, control, target, register)
                catch return TError { .IllegalInstruction = instruction };
            return null;
        }

        fn handleQpuToffoli(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const control1 = self.getRegister(parsed.rs1);
            const control2 = self.getRegister(10);
            const target = self.getRegister(parsed.rs2);
            const register = self.getRegister(parsed.rd);
            //std.debug.print("Applying TOFFOLI, {} {} {} {}\n", .{control1, control2, target, register});
            self.qpu.toffoli(self.qpu_ctx, control1, control2, target, register)
                catch return TError { .IllegalInstruction = instruction };
            return null;
        }

        fn handleQpuSigmaX(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const target = self.getRegister(parsed.rs2);
            const register = self.getRegister(parsed.rd);
            //std.debug.print("Applying sigmax, {} {}\n", .{target, register});
            self.qpu.sigmaX(self.qpu_ctx, target, register)
                catch return TError { .IllegalInstruction = instruction };
            return null;
        }

        fn handleQpuSigmaY(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const target = self.getRegister(parsed.rs2);
            const register = self.getRegister(parsed.rd);
            //std.debug.print("Applying sigmay, {} {}\n", .{target, register});
            self.qpu.sigmaY(self.qpu_ctx, target, register)
                catch return TError { .IllegalInstruction = instruction };
            return null;
        }

        fn handleQpuSigmaZ(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const target = self.getRegister(parsed.rs2);
            const register = self.getRegister(parsed.rd);
            //std.debug.print("Applying sigmaz, {} {}\n", .{target, register});
            self.qpu.sigmaZ(self.qpu_ctx, target, register)
                catch return TError { .IllegalInstruction = instruction };
            return null;
        }

        fn handleQpuHadamard(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const target = self.getRegister(parsed.rs2);
            const register = self.getRegister(parsed.rd);
            //std.debug.print("Applying hadamard, {} {}\n", .{target, register});
            self.qpu.hadamard(self.qpu_ctx, target, register)
                catch return TError { .IllegalInstruction = instruction };
            return null;
        }

        fn handleQpuBmeasure(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const pos = self.getRegister(parsed.rs1);
            const register = self.getRegister(parsed.rs2);
            //std.debug.print("Applying bmeasure, {} {}", .{pos, register});
            const result = self.qpu.bmeasure(self.qpu_ctx, pos, register)
                catch return TError { .IllegalInstruction = instruction };
            //std.debug.print(" result={}\n", .{result});
            self.setRegister(parsed.rd, result);
            return null;
        }

        fn handleQpuGetwidth(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const n = self.getRegister(parsed.rs1);
            const result = qpu.Qpu(Tword).getwidth(n);
            //std.debug.print("Applying getwidth, {} {}\n", .{n, result});
            self.setRegister(parsed.rd, result);
            return null;
        }

        fn handleQpuProb(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const real: u32 = @truncate(self.getRegister(parsed.rs1));
            const imaginary: u32 = @truncate(self.getRegister(parsed.rs2));
            const real_f: f32 = @bitCast(real);
            const imaginary_f: f32 = @bitCast(imaginary);
            const probability: f32 = qpu.Qpu(Tword).getProb(real_f, imaginary_f);
            // std.debug.print("Applying prob, {} {} result={}\n", .{real_f, imaginary_f, probability});
            const probability_int: u32 = @bitCast(probability);
            self.setRegister(parsed.rd, @intCast(probability_int));
            return null;
        }

        fn handleQpuGetRegWidth(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const register = self.getRegister(parsed.rs1);
            //std.debug.print("Applying getregwidth, reg={}, ", .{register});
            const result = self.qpu.getRegWidth(self.qpu_ctx, register)
                catch return TError { .IllegalInstruction = instruction };
            //std.debug.print("retval={}\n", .{result});
            self.setRegister(parsed.rd, result);
            return null;
        }

        fn handleQpuSetRegWidth(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const value = self.getRegister(parsed.rs1);
            const register = self.getRegister(parsed.rd);
            //std.debug.print("Applying setregwidth, reg={} val={}\n", .{register, value});
            self.qpu.setRegWidth(self.qpu_ctx, register, value)
                catch return TError { .IllegalInstruction = instruction };
            return null;
        }

        fn handleQpuGetRegNode(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const register = self.getRegister(11);
            const idx = self.getRegister(12);
            // std.debug.print("Applying getregnode, reg={} idx={}\n", .{register, idx});
            const result = self.qpu.getRegNode(self.qpu_ctx, register, idx)
                catch return TError { .IllegalInstruction = instruction };
            // std.debug.print("result = {}\n", .{result});
            const amplitude_r_int: u32 = @bitCast(result.amplitude_r);
            const amplitude_i_int: u32 = @bitCast(result.amplitude_i);
            self.setRegister(parsed.rd, result.state);
            self.setRegister(parsed.rs1, @intCast(amplitude_r_int));
            self.setRegister(parsed.rs2, @intCast(amplitude_i_int));
            return null;
        }

        fn handleQpuGetRegSize(self: *Self, instruction: u32) ?TError {
            const parsed: RTypeInstruction = @bitCast(instruction);
            const register = self.getRegister(parsed.rs1);
            const result = self.qpu.getRegSize(self.qpu_ctx, register)
                catch return TError { .IllegalInstruction = instruction };
            //std.debug.print("Applying getregsize, reg={}, result={}\n", .{register, result});
            self.setRegister(parsed.rd, result);
            return null;
        }

        fn handleNop(_: *Self, _: u32) ?TError {
            return null;
        }
    };
}
