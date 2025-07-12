const std = @import("std");
const fs = std.fs;
const mem = std.mem;

pub fn findAll(allocator: mem.Allocator, start: []const u8, path: fs.Dir) ![][]const u8 {
    var walker = try path.walk(allocator);
    defer walker.deinit();
    var list = std.ArrayList([]const u8).init(allocator);
    while (try walker.next()) |entry| {
        if (std.mem.startsWith(u8, entry.basename, start) and std.mem.endsWith(u8, entry.basename, ".bin")) {
            try list.append(try allocator.dupe(u8, entry.path));
        }
    }
    return try list.toOwnedSlice();
}
