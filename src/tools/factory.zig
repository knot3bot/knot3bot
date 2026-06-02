//! Tool factory - create tool instances aligned with hermes-agent
//! Following NullClaw's factory pattern

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolRegistry = root.ToolRegistry;

/// Register all core tools (shared by both registries)
fn addCoreTools(registry: *ToolRegistry, allocator: std.mem.Allocator, workspace_dir: []const u8) !void {
    // Shell
    { const t = try allocator.create(root.shell.ShellTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    // File ops
    { const t = try allocator.create(root.file_ops.FileReadTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.file_ops.FileWriteTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.file_ops.ListDirectoryTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.file_ops.GrepTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.file_ops.GlobTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    // Misc (note: todo tool is registered separately with full init/deinit)
    { const t = try allocator.create(root.misc.CalculatorTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    // Network
    { const t = try allocator.create(root.git.GitTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.cron.CronTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.http_request.HttpRequestTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.web_fetch.WebFetchTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.web_search.WebSearchTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.web_search.WebExtractTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.browser.BrowserTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.spawn.SpawnTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
}

/// Register extended tools (available in both default and full)
fn addExtendedTools(registry: *ToolRegistry, allocator: std.mem.Allocator, workspace_dir: []const u8) !void {
    { const t = try allocator.create(root.task_planner.TaskPlannerTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.diff_tool.DiffTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.approval.ApprovalTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.url_safety.UrlSafetyTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.session_search.SessionSearchTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.homeassistant_tool.HomeAssistantTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.image_generation.ImageGenerationTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.send_message_tool.SendMessageTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.transcription_tools.TranscriptionTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.tts_tool.TtsTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.vision_tools.VisionTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.vision_tools.ScreenCaptureTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.clarify_tool.ClarifyTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.env_passthrough.EnvPassthroughTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
}

/// Create default tool registry (40 tools)
pub fn createDefaultRegistry(allocator: std.mem.Allocator, workspace_dir: []const u8) !ToolRegistry {
    var registry = try ToolRegistry.init(allocator);
    errdefer registry.deinit();
    try addCoreTools(&registry, allocator, workspace_dir);
    try addExtendedTools(&registry, allocator, workspace_dir);
    { const t = try allocator.create(root.interrupt.InterruptTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.todo.TodoTool); errdefer allocator.destroy(t); t.* = root.todo.TodoTool.init(allocator); errdefer t.deinit(allocator); try registry.register(t.tool()); }
    { const t = try allocator.create(root.mcp_tool.MCPTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.mcp_tool.MCPListServersTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    // checkpoint + delegate
    { const t = try allocator.create(root.checkpoint.CheckpointManagerTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.delegate.DelegateTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.delegate.DelegateResultTool); errdefer allocator.destroy(t); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    // Self-evolution / memory / sandbox
    { const t = try allocator.create(root.skill_self_improve_tool.SkillSelfImproveTool); errdefer allocator.destroy(t); t.* = .{ .skills_dir = workspace_dir, .memory_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.credential_files.CredentialFilesTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.code_execution_tool.CodeExecutionTool); errdefer allocator.destroy(t); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.memory_tool.MemoryTool); errdefer allocator.destroy(t); t.* = try root.memory_tool.MemoryTool.init(allocator); errdefer t.deinit(); try registry.register(t.tool()); }
    // Skills management
    { const t = try allocator.create(root.skills.SkillsListTool); errdefer allocator.destroy(t); t.* = .{ .skills_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.skills.SkillViewTool); errdefer allocator.destroy(t); t.* = .{ .skills_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.skills.SkillManagerTool); errdefer allocator.destroy(t); t.* = .{ .skills_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.skills.SkillRunTool); errdefer allocator.destroy(t); t.* = .{ .skills_dir = workspace_dir }; try registry.register(t.tool()); }
    return registry;
}

/// Create full tool registry (48 tools, including process registry)
pub fn createFullRegistry(allocator: std.mem.Allocator, workspace_dir: []const u8) !ToolRegistry {
    var registry = try createDefaultRegistry(allocator, workspace_dir);
    errdefer registry.deinit();

    // Process registry (background process management)
    { const t = try allocator.create(root.process_registry.ProcessRegistryTool); errdefer allocator.destroy(t); t.* = try root.process_registry.ProcessRegistryTool.init(allocator); errdefer t.deinit(); try registry.register(t.tool()); }

    return registry;
}
