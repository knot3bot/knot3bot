//! Memory package - Session storage backends
//!
//! Provides in-memory and SQLite backends for session storage.

pub const MemorySystem = @import("../memory.zig").MemorySystem;
pub const MemoryBackend = @import("../memory.zig").MemoryBackend;

// SQLite backend (when available)
pub const SqliteMemorySystem = @import("sqlite.zig").SqliteMemorySystem;

pub const MemoryManager = @import("manager.zig").MemoryManager;
pub const ManagerMemoryBackend = @import("manager.zig").MemoryBackend;
