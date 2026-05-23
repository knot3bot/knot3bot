//! Structured JSON logger — production log aggregation compatible.
//! Wraps std.log with JSON formatting: timestamp, level, request_id, message.

const std = @import("std");

var g_writer: ?std.Io.Writer = null;
var g_mutex: std.Io.Mutex = std.Io.Mutex.init;

pub fn init(writer: std.Io.Writer) void {
    g_writer = writer;
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const writer = g_writer orelse return;
    const io = std.Io.Threaded.global_single_threaded.io();

    g_mutex.lockUncancelable(io);
    defer g_mutex.unlock(io);

    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, format, args) catch return;

    var json_buf: [512]u8 = undefined;
    const now = std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();

    const scope_str = @tagName(scope);
    const level_str = level.asText();

    const line = std.fmt.bufPrint(&json_buf,
        "{{\"ts\":{},\"level\":\"{s}\",\"scope\":\"{s}\",\"msg\":\"",
        .{ now, level_str, scope_str }) catch return;
    _ = writer.write(line) catch return;
    // Escape message for JSON
    for (msg) |c| {
        var esc: [2]u8 = [_]u8{ c, 0 };
        const s: []const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => esc[0..1],
        };
        _ = writer.write(s) catch return;
    }
    _ = writer.write("\"}\n") catch {};
}
