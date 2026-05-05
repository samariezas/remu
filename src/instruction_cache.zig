const std = @import("std");
const PrivilegeLevel = @import("privilege.zig").PrivilegeLevel;
const Allocator = std.mem.Allocator;
const AutoHashMap = std.hash_map.AutoHashMap;

const INSTRUCTION_ALIGN: comptime_int = 4;

pub fn ICache(Tword: type, Thandler: type) type {
    return struct {
        const Self = @This();

        pub const CachedInstruction = struct {
            instruction: u32,
            handler: *const Thandler,
        };

        const CacheEntry = struct {
            generation: u64,
            data: CachedInstruction,
        };

        const MissedCacheHandle = struct { generation: u64, dest: *CacheEntry };

        const CacheLookupResult = union(enum) {
            Hit: CachedInstruction,
            Miss: MissedCacheHandle,
        };

        const TMap = AutoHashMap(Tword, CacheEntry);

        generation: u64,
        cache: TMap,

        pub fn init(allocator: Allocator, _: usize) !Self {
            return .{
                .generation = 1,
                .cache = TMap.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.cache.deinit();
        }

        pub fn updateGeneration(self: *Self) void {
            self.generation += 1;
        }

        pub fn cacheLookup(self: *Self, address: Tword) !CacheLookupResult {
            std.debug.assert((address % INSTRUCTION_ALIGN) == 0);
            const index: Tword = address / INSTRUCTION_ALIGN;
            const hashmap_result = try self.cache.getOrPut(index);
            if (hashmap_result.found_existing and hashmap_result.value_ptr.generation == self.generation) {
                return CacheLookupResult {
                    .Hit = hashmap_result.value_ptr.data,
                };
            }
            hashmap_result.value_ptr.generation = 0;
            return CacheLookupResult {
                .Miss = .{ 
                    .generation = self.generation,
                    .dest = hashmap_result.value_ptr
                },
            };
        }

        pub fn updateCache(handle: MissedCacheHandle, instruction: u32, handler: *const Thandler) CachedInstruction {
            handle.dest.generation = handle.generation;
            handle.dest.data = .{
                .instruction = instruction,
                .handler = handler,
            };
            return handle.dest.data;
        }
    };
}

pub fn ArrICache(Tword: type, Thandler: type) type {
    return struct {
        const Self = @This();

        pub const CachedInstruction = struct {
            instruction: u32,
            handler: *const Thandler,
        };

        const CacheEntry = struct {
            generation: u64,
            privilege: PrivilegeLevel,
            address: Tword,
            data: CachedInstruction,
        };

        const MissedCacheHandle = struct { generation: u64, dest: *CacheEntry };

        const CacheLookupResult = union(enum) {
            Hit: CachedInstruction,
            Miss: MissedCacheHandle,
        };

        const TMap = std.hash_map.AutoHashMap(Tword, CacheEntry);

        generation: u64,
        cache: []CacheEntry,
        allocator: Allocator,

        pub fn init(allocator: Allocator, capacity: usize) !Self {
            const result = Self {
                .generation = 1,
                .cache = try allocator.alloc(CacheEntry, capacity),
                .allocator = allocator,
            };
            for (result.cache) |*i| {
                i.generation = 0;
            }
            return result;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.cache);
        }

        pub fn updateGeneration(self: *Self) void {
            self.generation += 1;
        }

        fn findCacheEntry(self: *Self, address: Tword) *CacheEntry {
            std.debug.assert((address % INSTRUCTION_ALIGN) == 0);
            const index: usize = @intCast((address / INSTRUCTION_ALIGN) % self.cache.len);
            return &self.cache[index];
        }

        pub fn cacheLookup(self: *Self, address: Tword, privilege: PrivilegeLevel) !CacheLookupResult {
            const hashmap_result = self.findCacheEntry(address);
            if (hashmap_result.generation == self.generation and
                hashmap_result.address == address and
                hashmap_result.privilege == privilege) {
                return CacheLookupResult {
                    .Hit = hashmap_result.data,
                };
            }
            hashmap_result.generation = 0;
            hashmap_result.privilege = privilege;
            hashmap_result.address = address;
            return CacheLookupResult {
                .Miss = .{ 
                    .generation = self.generation,
                    .dest = hashmap_result
                },
            };
        }

        pub fn updateCache(handle: MissedCacheHandle, instruction: u32, handler: *const Thandler) CachedInstruction {
            handle.dest.generation = handle.generation;
            handle.dest.data = .{
                .instruction = instruction,
                .handler = handler,
            };
            return handle.dest.data;
        }
    };
}
