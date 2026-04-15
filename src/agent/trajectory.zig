//! Trajectory recorder - Saves agent conversation trajectories to JSONL
//! Aligned with Python Hermes agent/trajectory.py

const std = @import("std");
const agent_module = @import("agent.zig");
const ReActStep = agent_module.ReActStep;
const Message = agent_module.Message;
const Role = agent_module.Role;

pub const TrajectoryRecorder = struct {
    allocator: std.mem.Allocator,
    completed_filename: []const u8 = "trajectory_samples.jsonl",
    failed_filename: []const u8 = "failed_trajectories.jsonl",

    pub fn init(allocator: std.mem.Allocator) TrajectoryRecorder {
        return .{ .allocator = allocator };
    }

    /// Save a trajectory to the appropriate JSONL file
    pub fn save(
        self: *const TrajectoryRecorder,
        model: []const u8,
        completed: bool,
        steps: []const ReActStep,
        messages: []const Message,
    ) !void {
        const filename = if (completed) self.completed_filename else self.failed_filename;

        var json_buf = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer json_buf.deinit();
        const w = json_buf.writer();

        try w.writeAll("{\"conversations\":[");
        for (messages, 0..) |msg, i| {
            if (i > 0) try w.writeAll(",");
            const role_str = switch (msg.role) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
                .tool => "tool",
            };
            try w.print("{{\"role\":\"{s}\",\"content\":\"", .{role_str});
            try writeEscapedJsonString(w, msg.content);
            try w.writeAll("\"}");
        }
        try w.writeAll("],");

        // Timestamp in ISO-8601-ish format
        const ts = std.time.timestamp();
        const seconds = @mod(ts, 60);
        const minutes = @mod(@divTrunc(ts, 60), 60);
        const hours = @mod(@divTrunc(ts, 3600), 24);
        _ = @divTrunc(ts, 86400); // days ignored for simplified date
        // Rough date formatting: 2024-01-01T00:00:00Z (simplified)
        try w.print("\"timestamp\":\"{d}-01-01T{d:0>2}:{d:0>2}:{d:0>2}Z\",", .{ 2024, hours, minutes, seconds });
        try w.print("\"model\":\"{s}\",\"completed\":{s},", .{ model, if (completed) "true" else "false" });

        // Steps array
        try w.writeAll("\"steps\":[");
        for (steps, 0..) |step, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"step\":{d},\"thought\":\"", .{step.step_number});
            try writeEscapedJsonString(w, step.thought);
            try w.writeAll("\"");
            if (step.action) |a| {
                try w.writeAll(",\"action\":\"");
                try writeEscapedJsonString(w, a);
                try w.writeAll("\"");
            }
            if (step.action_input) |ai| {
                try w.writeAll(",\"action_input\":\"");
                try writeEscapedJsonString(w, ai);
                try w.writeAll("\"");
            }
            if (step.observation) |o| {
                try w.writeAll(",\"observation\":\"");
                try writeEscapedJsonString(w, o);
                try w.writeAll("\"");
            }
            if (step.result) |r| {
                try w.writeAll(",\"result\":\"");
                try writeEscapedJsonString(w, r);
                try w.writeAll("\"");
            }
            if (step.error_msg) |e| {
                try w.writeAll(",\"error\":\"");
                try writeEscapedJsonString(w, e);
                try w.writeAll("\"");
            }
            try w.print(",\"duration_ms\":{d}}}", .{step.duration_ms});
        }
        try w.writeAll("]}");

        // Append to file
        var file = try std.fs.cwd().openFile(filename, .{ .mode = .read_write });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(json_buf.items);
        try file.writeAll("\n");
    }
};

fn writeEscapedJsonString(writer: anytype, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c >= 0x20 and c <= 0x7E) {
                    try writer.writeByte(c);
                } else {
                    try writer.print("\\u{X:0>4}", .{c});
                }
            },
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "save trajectory creates file and uses correct filenames" {
    const allocator = std.testing.allocator;
    var recorder = TrajectoryRecorder.init(allocator);
    recorder.completed_filename = "/tmp/test_trajectory_completed.jsonl";
    recorder.failed_filename = "/tmp/test_trajectory_failed.jsonl";

    const messages = &[_]Message{
        .{ .role = .system, .content = "You are helpful" },
        .{ .role = .user, .content = "Hello" },
        .{ .role = .assistant, .content = "Hi!" },
    };
    const steps = &[_]ReActStep{
        .{
            .step_number = 1,
            .thought = "The user said hello",
            .action = null,
            .action_input = null,
            .observation = null,
            .result = "Hi!",
            .error_msg = null,
            .duration_ms = 100,
        },
    };

    // Clean up any existing test files
    std.fs.cwd().deleteFile(recorder.completed_filename) catch {};
    std.fs.cwd().deleteFile(recorder.failed_filename) catch {};

    try recorder.save("gpt-4o", true, steps, messages);
    try recorder.save("gpt-4o", false, steps, messages);

    // Verify files exist
    const completed_stat = try std.fs.cwd().statFile(recorder.completed_filename);
    try std.testing.expect(completed_stat.size > 0);
    const failed_stat = try std.fs.cwd().statFile(recorder.failed_filename);
    try std.testing.expect(failed_stat.size > 0);

    // Clean up
    try std.fs.cwd().deleteFile(recorder.completed_filename);
    try std.fs.cwd().deleteFile(recorder.failed_filename);
}
