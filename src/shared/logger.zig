//! Logging utilities for knot3bot.
//!
//! knot3bot uses Zig's built-in std.log system for all logging:
//! - CLI mode: logs go to stderr (via std.debug.print for user output)
//! - Server mode: std.log.* calls go to stderr, captured by Docker log driver
//!
//! For production deployments, log aggregation is handled at the container
//! orchestration level (Docker, Kubernetes, systemd, etc.) rather than
//! through application-level file output.

const std = @import("std");

pub const LogLevel = enum(u3) {
    debug,
    info,
    warn,
    err,

    pub fn fromString(s: []const u8) LogLevel {
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "error")) return .err;
        return .info;
    }
};
