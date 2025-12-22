pub const PrivilegeLevel = enum {
    User,
    Supervisor,
    Machine,

    pub fn getEncoding(self: PrivilegeLevel) u2 {
        switch (self) {
            .User => return 0,
            .Supervisor => return 1,
            .Machine => return 3,
        }
    }

    pub fn fromEncoding(encoding: u2) ?PrivilegeLevel {
        switch (encoding) {
            0 => return .User,
            1 => return .Supervisor,
            3 => return .Machine,
            else => return null,
        }
    }
};

pub const SppPrivilegeLevel = enum {
    User,
    Supervisor,

    pub fn getEncoding(self: SppPrivilegeLevel) u1 {
        switch (self) {
            .User => return 0,
            .Supervisor => return 1,
        }
    }

    pub fn fromEncoding(encoding: u1) SppPrivilegeLevel {
        switch (encoding) {
            0 => return .User,
            1 => return .Supervisor,
        }
    }

    pub fn toRegular(self: SppPrivilegeLevel) PrivilegeLevel {
        return switch (self) {
            .User => PrivilegeLevel.User,
            .Supervisor => PrivilegeLevel.Supervisor,
        };
    }
};

