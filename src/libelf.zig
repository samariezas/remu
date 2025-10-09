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
};

pub const LoadableSectionIt = struct {
    elf_data: [*c]const u8,
    program_headers: []const c.Elf64_Phdr,
    current_header_idx: usize,

    fn init(elf_data: [*c]const u8, program_headers: []const c.Elf64_Phdr) LoadableSectionIt {
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

    fn get_raw_data(self: *const Elf) ![*c]u8 {
        if (c.elf_rawfile(self.inner, null)) |data| {
            return data;
        }
        return ElfLibError.FileImageGetFailed;
    }

    pub fn get_loadable_it(self: *const Elf) !LoadableSectionIt {
        const data = try self.get_raw_data();
        const headers = try self.get_program_headers();
        return LoadableSectionIt.init(data, headers);
    }
};

pub fn init() !void {
    if (c.elf_version(c.EV_CURRENT) == c.EV_NONE) {
        return ElfLibError.InitializationFailed;
    }
    library_initialized = true;
}

