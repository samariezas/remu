pub const WordSize = enum {
    w32,
    w64,

    pub fn getTword(comptime self: WordSize) type {
        return switch (self) {
            .w32 => u32,
            .w64 => u64,
        };
    }
};

pub const CpuOptions = struct {
    const Self = @This();

    word_size: WordSize,
    m_extension: bool,
    a_extension: bool,
    qpu_extension: bool,
    privileged: bool,

    pub fn makeBase(word_size: WordSize) CpuOptions {
        return .{
            .word_size = word_size,
            .m_extension = false,
            .a_extension = false,
            .qpu_extension = false,
            .privileged = false,
        };
    }

    pub fn withM(self: Self) Self {
        var new = self;
        new.m_extension = true;
        return new;
    }

    pub fn withA(self: Self) Self {
        var new = self;
        new.a_extension = true;
        return new;
    }

    pub fn withQpu(self: Self) Self {
        var new = self;
        new.qpu_extension = true;
        return new;
    }

    pub fn withPrivileged(self: Self) Self {
        var new = self;
        new.privileged = true;
        return new;
    }

    pub fn getTword(comptime self: Self) type {
        return self.word_size.getTword();
    }
};
