const config = @import("config");

const impl = if (config.enable_sqlite) @import("sqlite_impl.zig") else @import("sqlite_stub.zig");

pub const SqlError = impl.SqlError;
pub const SqliteMemorySystem = impl.SqliteMemorySystem;
