//! By convention, root.zig is the root source file when making a library.
//! Re-exports all public modules for convenient access.

const std = @import("std");

// Tools package - vtable-based pluggable tools
pub const tools = @import("tools/root.zig");
pub const Tool = tools.Tool;
pub const ToolSpec = tools.ToolSpec;
pub const ToolResult = tools.ToolResult;
pub const ToolRegistry = tools.ToolRegistry;
pub const ToolEntry = tools.ToolEntry;
pub const factory = @import("tools/factory.zig");
pub const createDefaultRegistry = factory.createDefaultRegistry;
pub const createFullRegistry = factory.createFullRegistry;

// Agent package - ReAct loop and skills
pub const agent = @import("agent/root.zig");
pub const Agent = agent.Agent;
pub const SkillRegistry = agent.SkillRegistry;
pub const Skill = agent.Skill;
pub const createDefaultSystemPrompt = agent.createDefaultSystemPrompt;

// Providers package - AI model providers (OpenAI-compatible)
pub const providers = @import("providers/root.zig");
pub const http_client = providers.openai_compatible;
pub const Provider = providers.Provider;
// Memory package - Session storage backends
pub const memory = @import("memory/root.zig");
pub const Server = @import("server/root.zig").Server;
pub const ServerConfig = @import("server/root.zig").ServerConfig;
pub const AuthConfig = @import("server/root.zig").AuthConfig;

// Shared utilities
pub const shared = @import("shared/root.zig");

// Display
pub const display = @import("display.zig");

// Models
pub const models = @import("models.zig");

// Agent submodules
pub const context_compressor = @import("agent/context_compressor.zig");
pub const trajectory = @import("agent/trajectory.zig");
pub const acp_adapter = @import("adapters/acp_adapter.zig");
pub const ACAdapter = acp_adapter.ACAdapter;
