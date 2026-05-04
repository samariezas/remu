const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

fn QpuContext(Tword: type) type {
    _ = Tword;
    return struct {
        const Self = @This();

        allocator: Allocator,
        register_id: usize,

        fn init(allocator: Allocator) Self {
            return Self {
                .allocator = allocator,
                .register_id = 0,
            };
        }

        fn deinit(self: *const Self) void {
            _ = self;
        }

        fn createRegister(self: *Self) usize {
            const retval = self.register_id;
            self.register_id += 1;
            return retval;
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

        fn deinit(self: *Self) void {
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

        fn getContext(self: *Self, idx_tw: Tword) ?*QpuCtx {
            if (twordToIdx(idx_tw)) |idx| {
                if (idx >= self.contexts.items.len) {
                    return null;
                }
                if (self.contexts.items[idx]) |*ctx| {
                    return ctx;
                }
            }
            return null;
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

        pub fn newRegister(self: *Self, ctx_tw: Tword) !Tword {
            if (self.getContext(ctx_tw)) |ctx| {
                return idxToTword(ctx.createRegister());
            }
            return error.ContextNotFound;
        }
    };
}
