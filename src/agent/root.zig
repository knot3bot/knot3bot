//! Agent package - ReAct agent loop and skill management
//!
//! Contains the core ReAct agent implementation and skill registry.

pub const Agent = @import("agent.zig");
pub const createDefaultSystemPrompt = @import("agent.zig").createDefaultSystemPrompt;
pub const AgentError = @import("agent.zig").AgentError;
pub const Role = @import("agent.zig").Role;

// Skills
pub const Skill = @import("skills.zig").Skill;
pub const SkillRegistry = @import("skills.zig").SkillRegistry;
pub const SkillScript = @import("skills.zig").SkillScript;
pub const SkillLoadResult = @import("skills.zig").SkillLoadResult;
