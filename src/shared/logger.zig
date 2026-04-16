//! Logger - Structured logging for knot3bot
//!
//! Features:
//! - Log levels: debug, info, warn, error
//! - Structured output with timestamps
//! - Optional file output
//! - Request/context tracking

const std = @import("std");

pub const LogLevel = enum(u3) {
    debug,
    info,
    warn,
    err, // using 'err' since 'error' is a keyword
};

pub const Logger = struct {
    level: LogLevel,
    file: ?std.fs.File = null,
    arena: std.heap.ArenaAllocator,
    requests: RequestContext = .{},

    pub const RequestContext = struct {
        request_id: ?[]const u8 = null,
        session_id: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, level: LogLevel) Logger {
        return .{
            .level = level,
            .file = null,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn initWithFile(allocator: std.mem.Allocator, level: LogLevel, log_path: []const u8) !Logger {
        var logger = init(allocator, level);
        logger.file = try std.fs.cwd().createFile(log_path, .{ .truncate = true });
        return logger;
    }

    pub fn deinit(self: *Logger) void {
        self.arena.deinit();
        if (self.file) |f| f.close();
    }

    pub fn setRequestContext(self: *Logger, request_id: ?[]const u8, session_id: ?[]const u8) void {
        self.requests = .{ .request_id = request_id, .session_id = session_id };
    }

    pub fn clearContext(self: *Logger) void {
        self.requests = .{};
    }

    pub fn log(self: *Logger, level: LogLevel, comptime format: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.level)) return;

        const timestamp = std.time.timestamp();
        const level_str = switch (level) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };

        var buf: [256]u8 = undefined;
        const time_str = formatTimestamp(timestamp, &buf);

        const allocator = self.arena.allocator();

        // Build structured message
        var msg = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer msg.deinit();

        try msg.writer().print("{s} [{s}] ", .{ time_str, level_str });

        if (self.requests.request_id) |req_id| {
            try msg.writer().print("[req:{s}] ", .{req_id});
        }
        if (self.requests.session_id) |sess_id| {
            try msg.writer().print("[sess:{s}] ", .{sess_id});
        }

        try msg.writer().print(format, args);

        // Output to stderr (default) or file
        const output = try msg.toOwnedSlice();
        if (self.file) |f| {
            f.writeAll(output) catch {};
            f.writeAll("\n") catch {};
        } else {
            std.debug.print("{s}\n", .{output});
        }
    }

    pub fn debug(self: *Logger, comptime format: []const u8, args: anytype) void {
        self.log(.debug, format, args);
    }

    pub fn info(self: *Logger, comptime format: []const u8, args: anytype) void {
        self.log(.info, format, args);
    }

    pub fn warn(self: *Logger, comptime format: []const u8, args: anytype) void {
        self.log(.warn, format, args);
    }

    pub fn err(self: *Logger, comptime format: []const u8, args: anytype) void {
        self.log(.err, format, args);
    }

    fn formatTimestamp(timestamp: i64, buf: *[256]u8) []const u8 {
        const secs: u64 = @intCast(timestamp);
        const dt = std.DateTime{ .timestamp = secs };
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
            dt.year, dt.month.numeric(), dt.day, dt.hour, dt.minute, dt.second,
        }) catch "1970-01-01T00:00:00";
    }
};

/// Global default logger for simple logging without explicit logger
var default_logger: ?*Logger = null;
var default_logger_allocator: std.mem.Allocator = undefined;

pub fn initDefaultLogger(allocator: std.mem.Allocator, level: LogLevel) void {
    default_logger_allocator = allocator;
    default_logger = allocator.create(Logger) catch return;
    default_logger.?.* = Logger.init(allocator, level);
}

pub fn deinitDefaultLogger() void {
    if (default_logger) |l| {
        l.deinit();
        default_logger_allocator.destroy(l);
        default_logger = null;
    }
}

pub fn logDefault(level: LogLevel, comptime format: []const u8, args: anytype) void {
    if (default_logger) |l| {
        l.log(level, format, args);
    }
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    logDefault(.debug, format, args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    logDefault(.info, format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    logDefault(.warn, format, args);
}

pub fn err(comptime format: []const u8, args: anytype) void {
    logDefault(.err, format, args);
}

/// Parse log level from string
pub fn parseLogLevel(s: []const u8) LogLevel {
    if (std.mem.eql(u8, s, "debug")) return .debug;
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "warn")) return .warn;
    if (std.mem.eql(u8, s, "error")) return .err;
    return .info; // default
}
