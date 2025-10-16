const c = @import("c");
const cpu_config = @import("cpu_config.zig");
const WordSize = cpu_config.WordSize;

pub fn initializeLibrary() bool {
    return c.elf_version(c.EV_CURRENT) != c.EV_NONE;
}

pub fn LibElfInterface(comptime wordsize: WordSize) type {
    const use_64bit = wordsize == .w64;

    return struct {
        Tword: type,

        strlen: @TypeOf(c.strlen),

        ELF_C_READ: @TypeOf(c.ELF_C_READ),
        ELF_K_ELF: @TypeOf(c.ELF_K_ELF),
        PT_LOAD: @TypeOf(c.PT_LOAD),
        SHT_SYMTAB: @TypeOf(c.SHT_SYMTAB),

        Elf: type,
        Elf_Scn: type,
        elf_begin: @TypeOf(c.elf_begin),
        elf_end: @TypeOf(c.elf_end),
        elf_getdata: @TypeOf(c.elf_getdata),
        elf_getphdrnum: @TypeOf(c.elf_getphdrnum),
        elf_getscn: @TypeOf(c.elf_getscn),
        elf_kind: @TypeOf(c.elf_kind),
        elf_nextscn: @TypeOf(c.elf_nextscn),
        elf_rawfile: @TypeOf(c.elf_rawfile),
        elf_version: @TypeOf(c.elf_version),

        Elf_Phdr: type,
        Elf_Ehdr: type,
        Elf_Sym: type,
        elf_getphdr: (if (use_64bit) @TypeOf(c.elf64_getphdr) else @TypeOf(c.elf32_getphdr)),
        elf_getshdr: (if (use_64bit) @TypeOf(c.elf64_getshdr) else @TypeOf(c.elf32_getshdr)),
        elf_getehdr: (if (use_64bit) @TypeOf(c.elf64_getehdr) else @TypeOf(c.elf32_getehdr)),
    };
}

pub fn LibElf(comptime wordsize: WordSize) LibElfInterface(wordsize) {
    const use_64bit = wordsize == .w64;

    return .{
        .Tword = wordsize.getTword(),

        .strlen = c.strlen,

        .ELF_C_READ = c.ELF_C_READ,
        .ELF_K_ELF = c.ELF_K_ELF,
        .PT_LOAD = c.PT_LOAD,
        .SHT_SYMTAB = c.SHT_SYMTAB,

        .Elf = c.Elf,
        .Elf_Scn = c.Elf_Scn,
        .elf_begin = c.elf_begin,
        .elf_end = c.elf_end,
        .elf_getdata = c.elf_getdata,
        .elf_getphdrnum = c.elf_getphdrnum,
        .elf_getscn = c.elf_getscn,
        .elf_kind = c.elf_kind,
        .elf_nextscn = c.elf_nextscn,
        .elf_rawfile = c.elf_rawfile,
        .elf_version = c.elf_version,

        .Elf_Phdr = if (use_64bit) c.Elf64_Phdr else c.Elf32_Phdr,
        .Elf_Ehdr = if (use_64bit) c.Elf64_Ehdr else c.Elf32_Ehdr,
        .Elf_Sym = if (use_64bit) c.Elf64_Sym else c.Elf32_Sym,
        .elf_getphdr = if (use_64bit) c.elf64_getphdr else c.elf32_getphdr,
        .elf_getshdr = if (use_64bit) c.elf64_getshdr else c.elf32_getshdr,
        .elf_getehdr = if (use_64bit) c.elf64_getehdr else c.elf32_getehdr,
    };
}
