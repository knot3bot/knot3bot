//! Vision Tools - Image analysis using vision-capable LLMs
//!
//! Provides tools for analyzing images with multimodal language models.
//! Supports analyzing screenshots, uploaded images, and URL-fetched images.
//!

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// VisionTool - Analyze images using vision-capable LLM
pub const VisionTool = struct {
    pub const tool_name = "vision";
    pub const tool_description = "Analyze images using vision-capable language models. Can analyze screenshots, uploaded images, or images from URLs. Ask specific questions about what you see.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"image_url\":{\"type\":\"string\",\"description\":\"URL of the image to analyze\"},\"image_path\":{\"type\":\"string\",\"description\":\"Local path to an image file\"},\"prompt\":{\"type\":\"string\",\"description\":\"Question or instruction about the image\"}},\"required\":[\"prompt\"]}";

    pub fn tool(self: *VisionTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *VisionTool, _: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const image_url = root.getString(args, "image_url");
        const image_path = root.getString(args, "image_path");
        _ = root.getString(args, "prompt") orelse {
            return ToolResult.fail("prompt is required for vision analysis");
        };

        if (image_url == null and image_path == null) {
            return ToolResult.fail("Either image_url or image_path is required");
        }
        return ToolResult.fail("not_available");
    }

    pub const vtable = root.ToolVTable(@This());
};

/// ScreenCaptureTool - Capture and analyze screen content
pub const ScreenCaptureTool = struct {
    pub const tool_name = "screen_capture";
    pub const tool_description = "Capture the screen or a specific window and analyze its contents using vision.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"prompt\":{\"type\":\"string\",\"description\":\"Question or instruction about the screen capture\"},\"region\":{\"type\":\"string\",\"description\":\"Screen region to capture\"}},\"required\":[\"prompt\"]}";

    pub fn tool(self: *ScreenCaptureTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *ScreenCaptureTool, _: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        _ = root.getString(args, "prompt") orelse {
            return ToolResult.fail("prompt is required for screen capture analysis");
        };
        return ToolResult.fail("not_available");
    }

    pub const vtable = root.ToolVTable(@This());
};
