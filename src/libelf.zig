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

pub const LoadableSection = struct {
    data: []u8,
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

    pub fn get_program_headers(self: *const Elf) ![]const c.Elf64_Phdr {
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

    pub fn get_loadable_section(self: *const Elf, section: *const c.Elf64_Phdr) !?LoadableSection {
        if (section.p_type != c.PT_LOAD) return null;
        std.debug.assert(section.p_memsz >= section.p_filesz);
        if (c.elf_rawfile(self.inner, null)) |data| {
            return .{
                .data = data[section.p_offset..(section.p_offset+section.p_filesz)],
                .start_address = section.p_vaddr,
                .padding = section.p_memsz - section.p_filesz,
            };
        } else {
            return ElfLibError.FileImageGetFailed;
        }
    }
};

// pub fn is_program_header_loadable(header: *const c.Elf64_Phdr) bool {
//     return header.p_type == c.PT_LOAD;
// }

pub fn init() !void {
    if (c.elf_version(c.EV_CURRENT) == c.EV_NONE) {
        return ElfLibError.InitializationFailed;
    }
    library_initialized = true;
}

