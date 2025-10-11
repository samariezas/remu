const std = @import("std");
const fs = std.fs;
const bindings = @import("libelf_bindings.zig");
const LibElf = bindings.LibElf;
const WordSize = @import("cpu_config.zig").WordSize;

var library_initialized: bool = false;

const ElfLibError = error {
    InitializationFailed,
    NotInitialized,
    ElfReadingFailed,
    UnexpectedType,
    GetProgramHeaderCountFailed,
    GetProgramHeadersFailed,
    FileImageGetFailed,
    ReadingSectionHeaderFailed,
};

pub fn LoadableSegmentIt(comptime c: anytype) type {
    return struct {
        const Self = @This();

        elf_data: []const u8,
        program_headers: []const c.Elf_Phdr,
        current_header_idx: usize,

        fn init(elf_data: []const u8, program_headers: []const c.Elf_Phdr) Self {
            return .{
                .elf_data = elf_data,
                .program_headers = program_headers,
                .current_header_idx = 0,
            };
        }

        pub fn next(self: *Self) ?LoadableSegment(c) {
            while (self.current_header_idx < self.program_headers.len) {
                const header = self.program_headers[self.current_header_idx];
                self.current_header_idx += 1;
                if (header.p_type == c.PT_LOAD) {
                    return .{
                        .data = self.elf_data[header.p_offset..(header.p_offset+header.p_filesz)],
                        .start_address = header.p_vaddr,
                        .padding = header.p_memsz - header.p_filesz,
                    };
                }
            }
            return null;
        }
    };
}

pub fn LoadableSegment(comptime c: anytype) type {
    return struct {
        data: []const u8,
        start_address: c.Tword,
        padding: c.Tword,
    };
}

pub fn Symbol(comptime c: anytype) type {
    return struct {
        name: []const u8,
        address: c.Tword,
        size: c.Tword
    };
}

pub fn SymbolIt(comptime c: anytype) type {
    return struct {
        const Self = @This();
        current_idx: usize,
        symbols: []const c.Elf_Sym,
        string_data: [*c]const u8,

        fn init(elf: *c.Elf) !Self {
            var section: ?*c.Elf_Scn = null;
            var symtab_section_count: usize = 0;
            var return_value: ?Self = null;
            while (true) {
                section = c.elf_nextscn(elf, section);
                if (section == null) { break; }
                const header = c.elf_getshdr(section);
                if (header.*.sh_type == c.SHT_SYMTAB) {
                    symtab_section_count += 1;
                    const count = header.*.sh_size / header.*.sh_entsize;
                    const data = c.elf_getdata(section, null);
                    const string_section = c.elf_getscn(elf, header.*.sh_link);
                    const string_data: [*c]const u8 = @ptrCast(c.elf_getdata(string_section, null).*.d_buf);
                    const symbols_raw: [*c]const c.Elf_Sym = @ptrCast(@alignCast(data.*.d_buf));
                    const symbols = symbols_raw[0..count];
                    return_value = .{
                        .current_idx = 0,
                        .symbols = symbols,
                        .string_data = string_data,
                    };
                }
            }
            if (symtab_section_count != 1) { return error.SymtabSearchFailed; }
            return return_value.?;
        }

        pub fn next(self: *Self) ?Symbol(c) {
            if (self.current_idx < self.symbols.len) {
                const symbol = self.symbols[self.current_idx];
                const name_length = c.strlen(self.string_data + symbol.st_name);
                const name = self.string_data[symbol.st_name..(symbol.st_name+name_length)];
                self.current_idx += 1;
                return .{
                    .name = name,
                    .address = symbol.st_value,
                    .size = symbol.st_size,
                };
            }
            return null;
        }
    };
}

pub fn Elf(comptime wordsize: WordSize) type {
    return struct {
        const c = LibElf(wordsize);
        const Self = @This();

        file: fs.File,
        inner: *c.Elf,

        pub fn deinit(self: *const Self) void {
            const deinit_result = c.elf_end(self.inner);
            std.debug.assert(deinit_result == 0);
            self.file.close();
        }

        pub fn load(file: fs.File) !Self {
            if (!library_initialized) {
                return ElfLibError.NotInitialized;
            }
            const elf_nullable: ?*c.Elf = c.elf_begin(file.handle, c.ELF_C_READ, null);
            if (elf_nullable) |elf| {
                errdefer {
                    const deinit_result = c.elf_end(elf);
                    std.debug.assert(deinit_result == 0);
                }
                if (c.elf_kind(elf) != c.ELF_K_ELF) {
                    return ElfLibError.UnexpectedType;
                }
                return .{
                    .file = file,
                    .inner = elf,
                };
            } else {
                return ElfLibError.ElfReadingFailed;
            }
        }

        fn get_program_headers(self: *const Self) ![]const c.Elf_Phdr {
            var size: usize = 0;
            if (c.elf_getphdrnum(self.inner, &size) < 0) {
                return ElfLibError.GetProgramHeaderCountFailed;
            }
            const headers_nullable = c.elf_getphdr(self.inner);
            if (headers_nullable) |headers| {
                return headers[0..size];
            } else {
                return ElfLibError.GetProgramHeadersFailed;
            }
        }

        fn get_raw_data(self: *const Self) ![]const u8 {
            var size: usize = undefined;
            if (c.elf_rawfile(self.inner, &size)) |data| {
                return data[0..size];
            }
            return ElfLibError.FileImageGetFailed;
        }

        pub fn get_loadable_it(self: *const Self) !LoadableSegmentIt(c) {
            const data = try self.get_raw_data();
            const headers = try self.get_program_headers();
            return LoadableSegmentIt(c).init(data, headers);
        }

        pub fn getSymbols(self: *Self) !SymbolIt(c) {
            return SymbolIt(c).init(self.inner);
        }
    };
}

pub fn init() !void {
    if (!bindings.initializeLibrary()) {
        return ElfLibError.InitializationFailed;
    }
    library_initialized = true;
}

