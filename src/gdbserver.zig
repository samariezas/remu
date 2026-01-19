const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn GdbDebugServer(Tword: type) type {
    _ = Tword;
    return struct {
        const Self = @This();

        file: std.fs.File,

        pub fn init(path: []const u8) !Self {
            const file = try std.fs.cwd().openFile(
                path,
                .{ .mode = .read_write },
            );
            return .{
                .file = file,
            };
        }
        
        pub fn poll(self: *Self, allocator: Allocator) void {
            _ = self;
            std.io.poll(
                allocator, @TypeOf(self.file), files: PollFiles(StreamEnum)
            );
        }
    };
}
