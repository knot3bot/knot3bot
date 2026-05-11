//! Tool factory - create tool instances aligned with hermes-agent
//! Following NullClaw's factory pattern

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolRegistry = root.ToolRegistry;

/// Register all core tools (shared by both registries)
fn addCoreTools(registry: *ToolRegistry, allocator: std.mem.Allocator, workspace_dir: []const u8) !void {
    // Shell
    { const t = try allocator.create(root.shell.ShellTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    // File ops
    { const t = try allocator.create(root.file_ops.FileReadTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.file_ops.FileWriteTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.file_ops.ListDirectoryTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.file_ops.GrepTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.file_ops.GlobTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    // Misc
    { const t = try allocator.create(root.misc.TodoTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.misc.CalculatorTool); t.* = .{}; try registry.register(t.tool()); }
    // Network
    { const t = try allocator.create(root.git.GitTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.cron.CronTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.http_request.HttpRequestTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.web_fetch.WebFetchTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.web_search.WebSearchTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.web_search.WebExtractTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.browser.BrowserTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.spawn.SpawnTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
}

/// Register extended tools (available in both default and full)
fn addExtendedTools(registry: *ToolRegistry, allocator: std.mem.Allocator, workspace_dir: []const u8) !void {
    { const t = try allocator.create(root.task_planner.TaskPlannerTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.diff_tool.DiffTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.approval.ApprovalTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.url_safety.UrlSafetyTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.session_search.SessionSearchTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.homeassistant_tool.HomeAssistantTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.image_generation.ImageGenerationTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.send_message_tool.SendMessageTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.transcription_tools.TranscriptionTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.tts_tool.TtsTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.vision_tools.VisionTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.vision_tools.ScreenCaptureTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.clarify_tool.ClarifyTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.env_passthrough.EnvPassthroughTool); t.* = .{}; try registry.register(t.tool()); }
}

/// Create default tool registry (30 tools)
pub fn createDefaultRegistry(allocator: std.mem.Allocator, workspace_dir: []const u8) !ToolRegistry {
    var registry = ToolRegistry.init(allocator);
    errdefer registry.deinit();
    try addCoreTools(&registry, allocator, workspace_dir);
    try addExtendedTools(&registry, allocator, workspace_dir);
    return registry;
}

/// Create full tool registry (50+ tools, including hermes-agent self-evolution)
pub fn createFullRegistry(allocator: std.mem.Allocator, workspace_dir: []const u8) !ToolRegistry {
    var registry = ToolRegistry.init(allocator);
    errdefer registry.deinit();

    try addCoreTools(&registry, allocator, workspace_dir);
    try addExtendedTools(&registry, allocator, workspace_dir);

    // Self-evolution / skills
    { const t = try allocator.create(root.skills.SkillsListTool); t.* = .{ .skills_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.skills.SkillViewTool); t.* = .{ .skills_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.skills.SkillManagerTool); t.* = .{ .skills_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.skills.SkillRunTool); t.* = .{ .skills_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.skill_self_improve_tool.SkillSelfImproveTool); t.* = .{ .skills_dir = workspace_dir, .memory_dir = workspace_dir }; try registry.register(t.tool()); }

    // Delegate / checkpoint
    { const t = try allocator.create(root.delegate.DelegateTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.delegate.DelegateResultTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }
    { const t = try allocator.create(root.checkpoint.CheckpointManagerTool); t.* = .{ .workspace_dir = workspace_dir }; try registry.register(t.tool()); }

    // Security
    { const t = try allocator.create(root.todo.TodoTool); t.* = root.todo.TodoTool.init(allocator); errdefer t.deinit(allocator); try registry.register(t.tool()); }
    { const t = try allocator.create(root.interrupt.InterruptTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.credential_files.CredentialFilesTool); t.* = .{}; try registry.register(t.tool()); }

    // MCP / Process / Code
    { const t = try allocator.create(root.mcp_tool.MCPTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.mcp_tool.MCPListServersTool); t.* = .{}; try registry.register(t.tool()); }
    { const t = try allocator.create(root.process_registry.ProcessRegistryTool); t.* = try root.process_registry.ProcessRegistryTool.init(allocator); errdefer t.deinit(); try registry.register(t.tool()); }
    { const t = try allocator.create(root.code_execution_tool.CodeExecutionTool); t.* = .{}; try registry.register(t.tool()); }

    // Memory
    { const t = try allocator.create(root.memory_tool.MemoryTool); t.* = try root.memory_tool.MemoryTool.init(allocator); errdefer t.deinit(); try registry.register(t.tool()); }

    return registry;
}
