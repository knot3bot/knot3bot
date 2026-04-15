//! Tools module — vtable-based pluggable tool system for LLM function calling.
//!
//! Architecture follows NullClaw's vtable pattern:
//! - Tool vtable interface with ptr: *anyopaque + vtable
//! - Each tool implements: execute, name, description, parametersJson
//! - Comptime ToolVTable helper generates vtable from struct type
//!
//! hermes-agent alignment: includes self-evolution tools (SkillsGuard, Delegate, Checkpoint)
//!
const std = @import("std");

// ── Core types ─────────────────────────────────────────────────────────────────

/// Result of a tool execution.
pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    error_msg: ?[]const u8 = null,

    pub fn ok(output: []const u8) ToolResult {
        return .{ .success = true, .output = output };
    }

    pub fn fail(err: []const u8) ToolResult {
        return .{ .success = false, .output = "", .error_msg = err };
    }
};

/// Description of a tool for LLM function calling schema
pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

/// JSON arg extraction helpers
pub const JsonObjectMap = std.json.ObjectMap;
pub const JsonValue = std.json.Value;

pub fn getString(args: JsonObjectMap, key: []const u8) ?[]const u8 {
    const val = args.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub fn getBool(args: JsonObjectMap, key: []const u8) ?bool {
    const val = args.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

pub fn getInt(args: JsonObjectMap, key: []const u8) ?i64 {
    const val = args.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

pub fn getValue(args: JsonObjectMap, key: []const u8) ?JsonValue {
    return args.get(key);
}

pub fn getStringArray(args: JsonObjectMap, key: []const u8) ?[]const JsonValue {
    const val = args.get(key) orelse return null;
    return switch (val) {
        .array => |a| a.items,
        else => null,
    };
}

// ── Tool vtable interface ───────────────────────────────────────────────────────

/// Tool vtable — implement for any capability.
/// Uses Zig's type-erased interface pattern (NullClaw's pattern).
pub const Tool = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!ToolResult,
        name: *const fn (ptr: *anyopaque) []const u8,
        description: *const fn (ptr: *anyopaque) []const u8,
        parameters_json: *const fn (ptr: *anyopaque) []const u8,
        deinit: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void = null,
    };

    pub fn execute(self: Tool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        return self.vtable.execute(self.ptr, allocator, args);
    }

    pub fn name(self: Tool) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn description(self: Tool) []const u8 {
        return self.vtable.description(self.ptr);
    }

    pub fn parametersJson(self: Tool) []const u8 {
        return self.vtable.parameters_json(self.ptr);
    }

    pub fn spec(self: Tool) ToolSpec {
        return .{
            .name = self.name(),
            .description = self.description(),
            .parameters_json = self.parametersJson(),
        };
    }

    pub fn deinit(self: Tool, allocator: std.mem.Allocator) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self.ptr, allocator);
        }
    }
};

// ── ToolVTable comptime helper ──────────────────────────────────────────────────

/// Comptime helper to generate Tool.VTable from a tool struct type.
pub fn ToolVTable(comptime T: type) Tool.VTable {
    return .{
        .execute = &struct {
            fn f(ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!ToolResult {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.execute(allocator, args);
            }
        }.f,
        .name = &struct {
            fn f(_: *anyopaque) []const u8 {
                return T.tool_name;
            }
        }.f,
        .description = &struct {
            fn f(_: *anyopaque) []const u8 {
                return T.tool_description;
            }
        }.f,
        .parameters_json = &struct {
            fn f(_: *anyopaque) []const u8 {
                return T.tool_params;
            }
        }.f,
        .deinit = &struct {
            fn f(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                allocator.destroy(self);
            }
        }.f,
    };
}

/// Helper to create a Tool from a heap-allocated tool struct
pub fn toolVTable(comptime T: type, ptr: *T) Tool {
    return .{ .ptr = @ptrCast(ptr), .vtable = &ToolVTable(T) };
}

// ── Tool implementations ────────────────────────────────────────────────────────

pub const shell = @import("shell.zig");
pub const file_ops = @import("file_ops.zig");
pub const skills = @import("skills.zig");
pub const delegate = @import("delegate.zig");
pub const checkpoint = @import("checkpoint.zig");
pub const browser = @import("browser.zig");
pub const misc = @import("misc.zig");
pub const git = @import("git.zig");
pub const cron = @import("cron.zig");
pub const http_request = @import("http_request.zig");
pub const web_fetch = @import("web_fetch.zig");
pub const web_search = @import("web_search.zig");
pub const spawn = @import("spawn.zig");
pub const approval = @import("approval.zig");
pub const url_safety = @import("url_safety.zig");
pub const todo = @import("todo.zig");
pub const interrupt = @import("interrupt.zig");
pub const env_passthrough = @import("env_passthrough.zig");
pub const credential_files = @import("credential_files.zig");
pub const session_search = @import("session_search.zig");
pub const vision_tools = @import("vision_tools.zig");
pub const image_generation = @import("image_generation.zig");
pub const tts_tool = @import("tts_tool.zig");
pub const transcription_tools = @import("transcription_tools.zig");
pub const send_message_tool = @import("send_message_tool.zig");
pub const homeassistant_tool = @import("homeassistant_tool.zig");
pub const memory_tool = @import("memory_tool.zig");
pub const clarify_tool = @import("clarify_tool.zig");
pub const mcp_tool = @import("mcp_tool.zig");
pub const process_registry = @import("process_registry.zig");
pub const code_execution_tool = @import("code_execution_tool.zig");


// ── Tool Registry ─────────────────────────────────────────────────────────────

pub const ToolEntry = struct {
    spec: ToolSpec,
    tool: Tool,
};

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.AlignedManaged(ToolEntry, null),

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .allocator = allocator,
            .entries = std.array_list.AlignedManaged(ToolEntry, null).initCapacity(allocator, 16) catch unreachable,
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        for (self.entries.items) |entry| {
            entry.tool.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    pub fn count(self: *const ToolRegistry) usize {
        return self.entries.items.len;
    }

    pub fn list(self: *const ToolRegistry) []const ToolEntry {
        return self.entries.items;
    }

    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        try self.entries.append(.{ .spec = tool.spec(), .tool = tool });
    }

    pub fn getToolDefs(self: *const ToolRegistry, allocator: std.mem.Allocator) ![]ToolDef {
        const http_client = @import("../providers/root.zig").openai_compatible;
        var defs = std.array_list.AlignedManaged(http_client.ToolDef, null).initCapacity(allocator, self.entries.items.len);
        for (self.entries.items) |entry| {
            const def = http_client.ToolDef{
                .type = "function",
                .function = .{
                    .name = entry.spec.name,
                    .description = entry.spec.description,
                    .parameters = try allocator.dupe(u8, entry.spec.parameters_json),
                },
            };
            try defs.append(def);
        }
        return try defs.toOwnedSlice(allocator);
    }
    pub fn call(self: *const ToolRegistry, allocator: std.mem.Allocator, name: []const u8, args: []const u8) !ToolResult {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.spec.name, name)) {
                const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args, .{});
                defer parsed.deinit();
                const obj = parsed.value.object;
                return entry.tool.execute(allocator, obj);
            }
        }
        return ToolResult.fail("Unknown tool");
    }
};

// ── ToolDef for OpenAI compatibility ────────────────────────────────────────────

const ToolDef = @import("../providers/root.zig").openai_compatible.ToolDef;
