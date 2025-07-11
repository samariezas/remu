const std = @import("std");
const cpu = @import("cpu.zig");

const Tword: type = u32;
pub fn main() !void {
    var args = std.process.args();

    std.debug.assert(args.skip());
    const image = args.next() orelse @panic("Missing image argument");
    std.debug.assert(!args.skip());

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            @panic("memory leak detected");
        }
    }

    const entrypoint: Tword = 0x0800_0000;
    const memory_size: Tword = 1024*1024;
    var rvcpu = try cpu.RVCPU(Tword).init(allocator, entrypoint, memory_size);
    defer rvcpu.deinit();

    const buffer = try allocator.alloc(u8, @intCast(memory_size));
    defer allocator.free(buffer);

    const cwd = std.fs.cwd();
    const file_read = try cwd.readFile(image, buffer);
    
    if (file_read.len >= buffer.len) {
        @panic("Buffer too small");
    }

    try rvcpu.loadBinary(entrypoint, file_read);

    while (true) {
        try rvcpu.tick();
    }
}
