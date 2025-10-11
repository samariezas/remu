const std = @import("std");
const fs = std.fs;
const c = @import("c");

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

// TODO: section -> segment
pub const LoadableSectionIt = struct {
    elf_data: []const u8,
    program_headers: []const c.Elf64_Phdr,
    current_header_idx: usize,

    fn init(elf_data: []const u8, program_headers: []const c.Elf64_Phdr) LoadableSectionIt {
        return .{
            .elf_data = elf_data,
            .program_headers = program_headers,
            .current_header_idx = 0,
        };
    }

    pub fn next(self: *LoadableSectionIt) ?LoadableSection {
        while (self.current_header_idx < self.program_headers.len) {
            const header = self.program_headers[self.current_header_idx];
            self.current_header_idx += 1;
            if (header.p_type == c.PT_LOAD) {
                std.debug.print("\nSection offset: {x}\n", .{header.p_offset});
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

pub const LoadableSection = struct {
    data: []const u8,
    start_address: u64,
    padding: u64,
};

pub const Elf = struct {
    file: fs.File,
    inner: *c.Elf,

    pub fn deinit(self: *const Elf) void {
        const deinit_result = c.elf_end(self.inner);
        std.debug.assert(deinit_result == 0);
        self.file.close();
    }

    pub fn load(file: fs.File) !Elf {
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

    fn get_program_headers(self: *const Elf) ![]const c.Elf64_Phdr {
        var size: usize = 0;
        if (c.elf_getphdrnum(self.inner, &size) < 0) {
            return ElfLibError.GetProgramHeaderCountFailed;
        }
        const headers_nullable = c.elf64_getphdr(self.inner);
        if (headers_nullable) |headers| {
            return headers[0..size];
        } else {
            return ElfLibError.GetProgramHeadersFailed;
        }
    }

    fn get_raw_data(self: *const Elf) ![]const u8 {
        var size: usize = undefined;
        if (c.elf_rawfile(self.inner, &size)) |data| {
            return data[0..size];
        }
        return ElfLibError.FileImageGetFailed;
    }

    pub fn get_loadable_it(self: *const Elf) !LoadableSectionIt {
        const data = try self.get_raw_data();
        const headers = try self.get_program_headers();
        return LoadableSectionIt.init(data, headers);
    }

    pub fn print_symbols(self: *const Elf) !void {
        var section: ?*c.Elf_Scn = null;
        while (true) {
            section = c.elf_nextscn(self.inner, section);
            if (section == null) { break; }
            const header = c.elf64_getshdr(section);
            if (header.*.sh_type == c.SHT_SYMTAB) {
                const data = c.elf_getdata(section, null);
                const count = header.*.sh_size / header.*.sh_entsize;
                const string_section = c.elf_getscn(self.inner, header.*.sh_link);
                const string_data: [*c]const u8 = @ptrCast(c.elf_getdata(string_section, null).*.d_buf);
                const symbols_raw: [*c]const c.Elf64_Sym = @ptrCast(@alignCast(data.*.d_buf));
                const symbols = symbols_raw[0..count];
                std.debug.print("\nSymbol count: {}\n", .{count});
                for (symbols, 0..) |symbol, i| {
                    const name_length = c.strlen(string_data + symbol.st_name);
                    const name = string_data[symbol.st_name..(symbol.st_name+name_length)];
                    if (name_length > 0) {
                        std.debug.print("{}: {s}\n", .{i+1, name});
                    }
                }
            }
        }
    }
};

pub fn init() !void {
    if (c.elf_version(c.EV_CURRENT) == c.EV_NONE) {
        return ElfLibError.InitializationFailed;
    }
    library_initialized = true;
}

