const std = @import("std");
const c = @import("c");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const RegNode = struct {
    state: u64,
    amplitude_r: f32,
    amplitude_i: f32,
};

fn QpuContext(Tword: type) type {
    _ = Tword;
    return struct {
        const Self = @This();

        registers: ArrayList(c.quantum_reg),

        fn init(allocator: Allocator) Self {
            return Self {
                .registers = ArrayList(c.quantum_reg).init(allocator),
            };
        }

        fn deinit(self: *const Self) void {
            for (self.registers.items) |*reg| {
                c.quantum_delete_qureg(reg);
            }
            self.registers.deinit();
        }

        fn getRegister(self: *Self, idx: u64) !*c.quantum_reg {
            if (idx == 0) return error.RegisterNotFound;
            const idx_dec = idx - 1;
            if (idx_dec < self.registers.items.len) {
                return &self.registers.items[idx_dec];
            }
            return error.RegisterNotFound;
        }

        // quantum_bmeasure
        // quantum_delete_qureg
        // quantum_getwidth
        // quantum_new_qureg
        // quantum_prob
        // quantum_toffoli

        fn createRegister(self: *Self, initval: u64, width: u64) usize {
            const idx = self.registers.items.len;
            self.registers.append(c.quantum_new_qureg(initval, @intCast(width)))
                catch @panic("OOM");
            return idx;
        }

        fn cnot(self: *Self, control: u64, target: u64, reg_idx: u64) !void {
            const reg = try self.getRegister(reg_idx);
            c.quantum_cnot(@intCast(control), @intCast(target), reg);
        }

        fn toffoli(self: *Self, control1: u64, control2: u64, target: u64, reg_idx: u64) !void {
            const reg = try self.getRegister(reg_idx);
            c.quantum_toffoli(@intCast(control1), @intCast(control2), @intCast(target), reg);
        }

        fn sigmaX(self: *Self, target: u64, reg_idx: u64) !void {
            const reg = try self.getRegister(reg_idx);
            c.quantum_sigma_x(@intCast(target), reg);
        }

        fn sigmaY(self: *Self, target: u64, reg_idx: u64) !void {
            const reg = try self.getRegister(reg_idx);
            c.quantum_sigma_y(@intCast(target), reg);
        }

        fn sigmaZ(self: *Self, target: u64, reg_idx: u64) !void {
            const reg = try self.getRegister(reg_idx);
            c.quantum_sigma_z(@intCast(target), reg);
        }

        fn hadamard(self: *Self, target: u64, reg_idx: u64) !void {
            const reg = try self.getRegister(reg_idx);
            c.quantum_hadamard(@intCast(target), reg);
        }

        fn bmeasure(self: *Self, pos: u64, reg_idx: u64) !u64 {
            const reg = try self.getRegister(reg_idx);
            return @intCast(c.quantum_bmeasure(@intCast(pos), reg));
        }

        fn getRegisterWidth(self: *Self, reg_idx: u64) !u64 {
            const reg = try self.getRegister(reg_idx);
            return @intCast(reg.width);
        }

        fn setRegisterWidth(self: *Self, reg_idx: u64, value: u64) !void {
            const reg = try self.getRegister(reg_idx);
            reg.width = @intCast(value);
        }

        fn getRegNode(self: *Self, reg_idx: u64, idx: u64) !RegNode {
            const reg = try self.getRegister(reg_idx);
            var retval: RegNode = undefined;
            c.quantum_get_reg_node(reg, @intCast(idx), &retval.state, &retval.amplitude_r, &retval.amplitude_i);
            return retval;
        }

        fn getRegSize(self: *Self, reg_idx: u64) !u64 {
            const reg = try self.getRegister(reg_idx);
            return @intCast(reg.size);
        }
    };
}

pub fn Qpu(Tword: type) type {
    return struct {
        const Self = @This();
        const QpuCtx = QpuContext(Tword);

        allocator: Allocator,
        contexts: ArrayList(?QpuCtx),

        pub fn init(allocator: Allocator) Self {
            return Self {
                .allocator = allocator,
                .contexts = ArrayList(?QpuCtx).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.contexts.items) |*ctx| {
                if (ctx.*) |*ctx_unwrapped| {
                    ctx_unwrapped.deinit();
                }
            }
            self.contexts.deinit();
        }

        fn idxToTword(idx: usize) Tword {
            return @truncate(idx + 1);
        }

        fn twordToIdx(tw: Tword) ?usize {
            if (tw == 0) return null;
            return @truncate(tw - 1);
        }

        fn findEmptyQpuLocation(self: *Self) ?struct { usize, *?QpuCtx } {
            for (self.contexts.items, 0..) |*ctx, idx| {
                if (ctx.* == null) {
                    return .{ idx, ctx };
                }
            }
            return null;
        }

        fn getContext(self: *Self, idx_tw: Tword) !*QpuCtx {
            if (twordToIdx(idx_tw)) |idx| {
                if (idx >= self.contexts.items.len) {
                    return error.ContextNotFound;
                }
                if (self.contexts.items[idx]) |*ctx| {
                    return ctx;
                }
            }
            return error.ContextNotFound;
        }

        pub fn allocateContext(self: *Self) Tword {
            if (self.findEmptyQpuLocation()) |empty_ctx| {
                const idx, const ctx = empty_ctx;
                ctx.* = QpuCtx.init(self.allocator);
                return idxToTword(idx);
            }
            const retval = idxToTword(self.contexts.items.len);
            self.contexts.append(QpuCtx.init(self.allocator))
                catch @panic("OOM");
            return retval;
        }

        pub fn freeContext(self: *Self, idx_tw: Tword) !void {
            if (twordToIdx(idx_tw)) |idx| {
                if (idx >= self.contexts.items.len) {
                    return error.ContextNotPresent;
                }
                const ctx_opt = &self.contexts.items[idx];
                if (ctx_opt.*) |*ctx| {
                    ctx.deinit();
                    ctx_opt.* = null;
                } else {
                    return error.ContextNotPresent;
                }
            } else {
                return error.InvalidContextId;
            }
        }

        pub fn newRegister(self: *Self, ctx_tw: Tword, initval: u64, width: u64) !Tword {
            const ctx = try self.getContext(ctx_tw);
            const new_register_handle = ctx.createRegister(initval, width);
            return idxToTword(new_register_handle);
        }

        pub fn cnot(self: *Self, ctx_tw: Tword, control: Tword, target: Tword, register: Tword) !void {
            const ctx = try self.getContext(ctx_tw);
            try ctx.cnot(control, target, register);
        }

        pub fn toffoli(self: *Self, ctx_tw: Tword, control1: Tword, control2: Tword, target: Tword, register: Tword) !void {
            const ctx = try self.getContext(ctx_tw);
            try ctx.toffoli(control1, control2, target, register);
        }

        pub fn sigmaX(self: *Self, ctx_tw: Tword, target: Tword, register: Tword) !void {
            const ctx = try self.getContext(ctx_tw);
            try ctx.sigmaX(target, register);
        }

        pub fn sigmaY(self: *Self, ctx_tw: Tword, target: Tword, register: Tword) !void {
            const ctx = try self.getContext(ctx_tw);
            try ctx.sigmaY(target, register);
        }

        pub fn sigmaZ(self: *Self, ctx_tw: Tword, target: Tword, register: Tword) !void {
            const ctx = try self.getContext(ctx_tw);
            try ctx.sigmaZ(target, register);
        }

        pub fn hadamard(self: *Self, ctx_tw: Tword, target: Tword, register: Tword) !void {
            const ctx = try self.getContext(ctx_tw);
            try ctx.hadamard(target, register);
        }

        pub fn bmeasure(self: *Self, ctx_tw: Tword, pos: Tword, register: Tword) !Tword {
            const ctx = try self.getContext(ctx_tw);
            return ctx.bmeasure(pos, register);
        }

        pub fn getwidth(n: u64) u64 {
            return @intCast(c.quantum_getwidth(@intCast(n)));
        }

        pub fn getProb(real: f32, imaginary: f32) f32 {
            return c.quantum_prob_wrap(real, imaginary);
        }

        pub fn getRegWidth(self: *Self, ctx_tw: Tword, register: Tword) !u64 {
            const ctx = try self.getContext(ctx_tw);
            return ctx.getRegisterWidth(register);
        }

        pub fn setRegWidth(self: *Self, ctx_tw: Tword, register: Tword, value: Tword) !void {
            const ctx = try self.getContext(ctx_tw);
            try ctx.setRegisterWidth(register, value);
        }

        pub fn getRegNode(self: *Self, ctx_tw: Tword, register: Tword, idx: Tword) !RegNode {
            const ctx = try self.getContext(ctx_tw);
            return ctx.getRegNode(register, idx);
        }

        pub fn getRegSize(self: *Self, ctx_tw: Tword, register: Tword) !u64 {
            const ctx = try self.getContext(ctx_tw);
            return ctx.getRegSize(register);
        }
    };
}
