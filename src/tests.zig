const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const ArrayList = std.ArrayList;

const BIN_SUFFIX = ".bin";
const MAX_SIGNATURE_SIZE = 1024*1024*1024;

pub fn findAll(allocator: mem.Allocator, start: []const u8, path: fs.Dir) ![][]const u8 {
    var walker = try path.walk(allocator);
    defer walker.deinit();
    var list = std.ArrayList([]const u8).init(allocator);
    while (try walker.next()) |entry| {
        if (std.mem.startsWith(u8, entry.basename, start) and std.mem.endsWith(u8, entry.basename, BIN_SUFFIX)) {
            try list.append(try allocator.dupe(u8, entry.path));
        }
    }
    return try list.toOwnedSlice();
}

pub const Signature = struct {
    signature: []u8,
    inner: []u8,
    allocator: mem.Allocator,

    pub fn deinit(self: *const Signature) void {
        self.allocator.free(self.inner);
    }
};

pub fn loadSignature(allocator: mem.Allocator, image_name: []const u8, path: fs.Dir) !?[]u8 {
    std.debug.assert(std.mem.endsWith(u8, image_name, BIN_SUFFIX));
    const signature_name = try std.fmt.allocPrint(allocator, "{s}.sig", .{image_name[0..image_name.len - BIN_SUFFIX.len]});
    defer allocator.free(signature_name);
    path.access(signature_name, fs.File.OpenFlags { .mode = fs.File.OpenMode.read_only, }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const data = try path.readFileAlloc(allocator, signature_name, MAX_SIGNATURE_SIZE);
    defer allocator.free(data);
    var lines = ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        try lines.append(line);
    }
    std.mem.reverse([]const u8, lines.items);
    var result = ArrayList(u8).init(allocator);
    var previous_byte: ?u8 = null;
    for (lines.items) |line| {
        for (0..line.len) |i| {
            var c = line[i];
            if (c >= '0' and c <= '9') {
                c -= '0';
            } else if (c >= 'a' and c <= 'f') {
                c -= 'a' - 10;
            } else {
                continue;
            }
            if (previous_byte) |prev| {
                try result.append((prev << 4) | c);
                previous_byte = null;
            } else {
                previous_byte = c;
            }
        }
    }
    std.debug.assert(previous_byte == null);
    std.mem.reverse(u8, result.items);
    return try result.toOwnedSlice();
}
