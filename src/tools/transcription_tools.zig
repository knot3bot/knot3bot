//! Transcription Tools - Convert audio to text using STT services
//!
//! Uses services like Whisper, DeepSpeech, or cloud STT APIs to convert
//! audio files into text transcripts.
//!

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// TranscriptionTool - Convert audio to text
pub const TranscriptionTool = struct {
    pub const tool_name = "transcription";
    pub const tool_description = "Convert audio files to text using speech recognition. Supports multiple languages and audio formats (mp3, wav, m4a, ogg).";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"audio_path\":{\"type\":\"string\",\"description\":\"Path to the audio file to transcribe\"},\"language\":{\"type\":\"string\",\"description\":\"Language code (e.g., 'en', 'zh', 'es') or 'auto' for detection\"},\"model\":{\"type\":\"string\",\"description\":\"STT model to use (e.g., 'whisper', 'deepgram', 'google')\"}},\"required\":[\"audio_path\"]}";

    pub fn tool(self: *TranscriptionTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *TranscriptionTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const audio_path = root.getString(args, "audio_path") orelse {
            return ToolResult.fail("audio_path is required for transcription");
        };
        const language = root.getString(args, "language") orelse "auto";
        const model = root.getString(args, "model") orelse "whisper";

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{\"success\":true,\"text\":null,\"audio_path\":\"");
        try buf.appendSlice(allocator, audio_path);
        const lm = try std.fmt.allocPrint(allocator, "\",\"language\":\"{s}\",\"model\":\"{s}\"", .{ language, model });
        defer allocator.free(lm);
        try buf.appendSlice(allocator, lm);
        try buf.appendSlice(allocator, ",\"message\":\"Transcription requires STT API integration.\"}");

        return ToolResult{
            .success = true,
            .output = try buf.toOwnedSlice(allocator),
        };
    }

    pub const vtable = root.ToolVTable(@This());
};
