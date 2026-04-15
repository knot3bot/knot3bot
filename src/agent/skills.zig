const std = @import("std");

/// Skill definition - a reusable prompt template or procedure
pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    /// Prompt template that gets injected when skill is activated
    prompt_template: []const u8,
    /// Optional associated scripts for automation
    scripts: []const SkillScript = &[_]SkillScript{},
    /// Whether this skill should auto-activate for certain patterns
    auto_activate: bool = false,
    /// Pattern that triggers auto-activation (regex-like)
    trigger_pattern: ?[]const u8 = null,
};

/// A script associated with a skill
pub const SkillScript = struct {
    name: []const u8,
    description: []const u8,
    /// Script content or path
    content: []const u8,
    /// Interpreter to use (e.g., "python3", "bash")
    interpreter: []const u8 = "bash",
};

/// Result of loading a skill
pub const SkillLoadResult = struct {
    success: bool,
    skill: ?Skill = null,
    error_message: ?[]const u8 = null,
};

/// Registry for managing skills
pub const SkillRegistry = struct {
    allocator: std.mem.Allocator,
    skills: std.StringArrayHashMap(Skill),

    /// Initialize skill registry
    pub fn init(allocator: std.mem.Allocator) SkillRegistry {
        return .{
            .allocator = allocator,
            .skills = std.StringArrayHashMap(Skill).init(allocator),
        };
    }

    /// Deinitialize and free memory
    pub fn deinit(self: *SkillRegistry) void {
        var it = self.skills.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            const skill = entry.value_ptr.*;
            self.allocator.free(skill.name);
            self.allocator.free(skill.description);
            self.allocator.free(skill.prompt_template);
            for (skill.scripts) |script| {
                self.allocator.free(script.name);
                self.allocator.free(script.description);
                self.allocator.free(script.content);
                self.allocator.free(script.interpreter);
            }
            self.allocator.free(skill.scripts);
        }
        self.skills.deinit();
    }

    /// Register a skill
    pub fn register(self: *SkillRegistry, skill: Skill) !void {
        const name_copy = try self.allocator.dupe(u8, skill.name);
        errdefer self.allocator.free(name_copy);
        try self.skills.put(name_copy, skill);
    }

    /// Get a skill by name
    pub fn get(self: *const SkillRegistry, name: []const u8) ?Skill {
        return self.skills.get(name);
    }

    /// List all skill names
    pub fn list(self: *SkillRegistry) []const []const u8 {
        return self.skills.keys();
    }

    /// Check if skill exists
    pub fn exists(self: *const SkillRegistry, name: []const u8) bool {
        return self.skills.contains(name);
    }

    /// Load skill by name and return its prompt
    pub fn loadSkillPrompt(self: *const SkillRegistry, name: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        const skill = self.get(name) orelse return null;
        return try allocator.dupe(u8, skill.prompt_template);
    }

    /// Find skills matching a query (simple substring match)
    pub fn findSkills(self: *const SkillRegistry, query: []const u8) []const Skill {
        var results = std.array_list.AlignedManaged(Skill, null).init(self.allocator);
        defer results.deinit();

        var it = self.skills.iterator();
        while (it.next()) |entry| {
            const skill = entry.value_ptr.*;
            if (std.ascii.indexOfIgnoreCase(skill.name, query) != null or
                std.ascii.indexOfIgnoreCase(skill.description, query) != null)
            {
                results.append(skill) catch continue;
            }
        }
        return results.toOwnedSlice();
    }
};

/// Create the default built-in skills
pub fn createDefaultSkills(allocator: std.mem.Allocator) !SkillRegistry {
    var registry = SkillRegistry.init(allocator);
    errdefer registry.deinit();

    // Plan skill - helps structure thinking before execution
    try registry.register(.{
        .name = "plan",
        .description = "Create a structured plan before executing tasks",
        .prompt_template = "Before executing this task, first create a clear plan using the following structure:\n\n## Plan\n1. **Understand Goal**: What is the end result we want?\n2. **Identify Steps**: What are the concrete steps to get there?\n3. **Anticipate Issues**: What could go wrong?\n4. **Define Success**: How do we know when it's done?\n\nWork through each section before taking any action.",
        .auto_activate = true,
        .trigger_pattern = "plan",
    });

    // Debug skill - systematic debugging approach
    try registry.register(.{
        .name = "debug",
        .description = "Systematic debugging methodology",
        .prompt_template = "Follow this debugging methodology:\n\n## Debug Process\n1. **Reproduce**: Can you consistently reproduce the issue?\n2. **Isolate**: What is the minimal case that triggers it?\n3. **Hypothesize**: What do you think is causing it?\n4. **Test**: Verify or refute your hypothesis\n5. **Fix**: Implement and verify the solution\n\nReport your findings at each step.",
        .auto_activate = false,
    });

    // Research skill - information gathering approach
    try registry.register(.{
        .name = "research",
        .description = "Thorough research before making decisions",
        .prompt_template = "Before making recommendations, research the following:\n\n## Research Checklist\n- [ ] What are the existing solutions/approaches?\n- [ ] What are the trade-offs of each approach?\n- [ ] What does the ecosystem support?\n- [ ] What are the failure modes?\n- [ ] What is the simplest solution that could work?\n\nPresent your findings before making recommendations.",
        .auto_activate = false,
    });

    // Review skill - code/task review approach
    try registry.register(.{
        .name = "review",
        .description = "Thorough review before finalizing",
        .prompt_template = "Before finalizing, review:\n\n## Review Checklist\n- [ ] Does it solve the actual problem?\n- [ ] Are there edge cases not handled?\n- [ ] Is the code/effect easy to understand?\n- [ ] Could it break anything existing?\n- [ ] Is there a simpler approach?\n\nMake any necessary improvements before completing.",
        .auto_activate = false,
    });

    // Shell safety skill - cautious shell command execution
    try registry.register(.{
        .name = "shell-safety",
        .description = "Safe shell command execution practices",
        .prompt_template = "When executing shell commands:\n\n## Shell Safety Rules\n1. **Confirm destructive commands** (rm, DROP, etc.) before executing\n2. **Use dry-run flags** when available\n3. **Prefer read-only operations** when possible\n4. **Verify paths** before destructive operations\n5. **Check disk space** before large operations\n\nAlways report what a command will do before doing it.",
        .auto_activate = false,
    });

    return registry;
}
