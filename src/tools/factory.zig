//! Tool factory - create tool instances aligned with hermes-agent
//! Following NullClaw's factory pattern
//!
const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolRegistry = root.ToolRegistry;

/// Create default tool registry (hermes-agent compatible interface)
pub fn createDefaultRegistry(allocator: std.mem.Allocator, workspace_dir: []const u8) !ToolRegistry {
    var registry = ToolRegistry.init(allocator);
    errdefer registry.deinit();

    // Core shell tool
    {
        const st = try allocator.create(root.shell.ShellTool);
        st.* = .{ .workspace_dir = workspace_dir };
        try registry.register(st.tool());
    }

    // File operations
    {
        const frt = try allocator.create(root.file_ops.FileReadTool);
        frt.* = .{ .workspace_dir = workspace_dir };
        try registry.register(frt.tool());
    }
    {
        const fwt = try allocator.create(root.file_ops.FileWriteTool);
        fwt.* = .{ .workspace_dir = workspace_dir };
        try registry.register(fwt.tool());
    }
    {
        const ldt = try allocator.create(root.file_ops.ListDirectoryTool);
        ldt.* = .{ .workspace_dir = workspace_dir };
        try registry.register(ldt.tool());
    }
    {
        const gt = try allocator.create(root.file_ops.GrepTool);
        gt.* = .{ .workspace_dir = workspace_dir };
        try registry.register(gt.tool());
    }
    {
        const glt = try allocator.create(root.file_ops.GlobTool);
        glt.* = .{ .workspace_dir = workspace_dir };
        try registry.register(glt.tool());
    }

    // Misc tools
    {
        const tt = try allocator.create(root.misc.TodoTool);
        tt.* = .{};
        try registry.register(tt.tool());
    }
    {
        const ct = try allocator.create(root.misc.CalculatorTool);
        ct.* = .{};
        try registry.register(ct.tool());
    }

    // Network tools
    {
        const git_tool = try allocator.create(root.git.GitTool);
        git_tool.* = .{ .workspace_dir = workspace_dir };
        try registry.register(git_tool.tool());
    }
    {
        const cr = try allocator.create(root.cron.CronTool);
        cr.* = .{ .workspace_dir = workspace_dir };
        try registry.register(cr.tool());
    }
    {
        const ht = try allocator.create(root.http_request.HttpRequestTool);
        ht.* = .{ .workspace_dir = workspace_dir };
        try registry.register(ht.tool());
    }
    {
        const wf = try allocator.create(root.web_fetch.WebFetchTool);
        wf.* = .{ .workspace_dir = workspace_dir };
        try registry.register(wf.tool());
    }
    {
        const ws = try allocator.create(root.web_search.WebSearchTool);
        ws.* = .{};
        try registry.register(ws.tool());
    }
    {
        const we = try allocator.create(root.web_search.WebExtractTool);
        we.* = .{};
        try registry.register(we.tool());
    }
    {
        const br = try allocator.create(root.browser.BrowserTool);
        br.* = .{ .workspace_dir = workspace_dir };
        try registry.register(br.tool());
    }
    {
        const sp = try allocator.create(root.spawn.SpawnTool);
        sp.* = .{ .workspace_dir = workspace_dir };
        try registry.register(sp.tool());
    }

    return registry;
}

/// Create all tools registry including hermes-agent self-evolution tools
pub fn createFullRegistry(allocator: std.mem.Allocator, workspace_dir: []const u8) !ToolRegistry {
    var registry = ToolRegistry.init(allocator);
    errdefer registry.deinit();

    // Core shell tool
    {
        const st = try allocator.create(root.shell.ShellTool);
        st.* = .{ .workspace_dir = workspace_dir };
        try registry.register(st.tool());
    }

    // File operations
    {
        const frt = try allocator.create(root.file_ops.FileReadTool);
        frt.* = .{ .workspace_dir = workspace_dir };
        try registry.register(frt.tool());
    }
    {
        const fwt = try allocator.create(root.file_ops.FileWriteTool);
        fwt.* = .{ .workspace_dir = workspace_dir };
        try registry.register(fwt.tool());
    }
    {
        const ldt = try allocator.create(root.file_ops.ListDirectoryTool);
        ldt.* = .{ .workspace_dir = workspace_dir };
        try registry.register(ldt.tool());
    }
    {
        const gt = try allocator.create(root.file_ops.GrepTool);
        gt.* = .{ .workspace_dir = workspace_dir };
        try registry.register(gt.tool());
    }
    {
        const glt = try allocator.create(root.file_ops.GlobTool);
        glt.* = .{ .workspace_dir = workspace_dir };
        try registry.register(glt.tool());
    }

    // Misc tools
    {
        const tt = try allocator.create(root.misc.TodoTool);
        tt.* = .{};
        try registry.register(tt.tool());
    }
    {
        const ct = try allocator.create(root.misc.CalculatorTool);
        ct.* = .{};
        try registry.register(ct.tool());
    }

    // Network tools
    {
        const git_tool = try allocator.create(root.git.GitTool);
        git_tool.* = .{ .workspace_dir = workspace_dir };
        try registry.register(git_tool.tool());
    }
    {
        const cr = try allocator.create(root.cron.CronTool);
        cr.* = .{ .workspace_dir = workspace_dir };
        try registry.register(cr.tool());
    }
    {
        const ht = try allocator.create(root.http_request.HttpRequestTool);
        ht.* = .{ .workspace_dir = workspace_dir };
        try registry.register(ht.tool());
    }
    {
        const wf = try allocator.create(root.web_fetch.WebFetchTool);
        wf.* = .{ .workspace_dir = workspace_dir };
        try registry.register(wf.tool());
    }
    {
        const ws = try allocator.create(root.web_search.WebSearchTool);
        ws.* = .{ .workspace_dir = workspace_dir };
        try registry.register(ws.tool());
    }
    {
        const br = try allocator.create(root.browser.BrowserTool);
        br.* = .{ .workspace_dir = workspace_dir };
        try registry.register(br.tool());
    }
    {
        const sp = try allocator.create(root.spawn.SpawnTool);
        sp.* = .{ .workspace_dir = workspace_dir };
        try registry.register(sp.tool());
    }

    // hermes-agent self-evolution tools
    {
        const slt = try allocator.create(root.skills.SkillsListTool);
        slt.* = .{ .skills_dir = workspace_dir };
        try registry.register(slt.tool());
    }
    {
        const svt = try allocator.create(root.skills.SkillViewTool);
        svt.* = .{ .skills_dir = workspace_dir };
        try registry.register(svt.tool());
    }
    {
        const smt = try allocator.create(root.skills.SkillManagerTool);
        smt.* = .{ .skills_dir = workspace_dir };
        try registry.register(smt.tool());
    }
    {
        const srt = try allocator.create(root.skills.SkillRunTool);
        srt.* = .{ .skills_dir = workspace_dir };
        try registry.register(srt.tool());
    }
    {
        // Self-improvement tool
        const ssit = try allocator.create(root.skill_self_improve_tool.SkillSelfImproveTool);
        ssit.* = .{ .skills_dir = workspace_dir, .memory_dir = workspace_dir };
        try registry.register(ssit.tool());
    }
    {
        const dt = try allocator.create(root.delegate.DelegateTool);
        dt.* = .{ .workspace_dir = workspace_dir };
        try registry.register(dt.tool());
    }
    {
        const drt = try allocator.create(root.delegate.DelegateResultTool);
        drt.* = .{ .workspace_dir = workspace_dir };
        try registry.register(drt.tool());
    }
    {
        const cpt = try allocator.create(root.checkpoint.CheckpointManagerTool);
        cpt.* = .{ .workspace_dir = workspace_dir };
        try registry.register(cpt.tool());
    }

    // Security tools
    {
        const approval_tool = try allocator.create(root.approval.ApprovalTool);
        approval_tool.* = .{};
        try registry.register(approval_tool.tool());
    }
    {
        const url_safety_tool = try allocator.create(root.url_safety.UrlSafetyTool);
        url_safety_tool.* = .{};
        try registry.register(url_safety_tool.tool());
    }
    {
        const todo_tool = try allocator.create(root.todo.TodoTool);
        todo_tool.* = root.todo.TodoTool.init(allocator);
        errdefer todo_tool.deinit(allocator);
        try registry.register(todo_tool.tool());
    }
    {
        const interrupt_tool = try allocator.create(root.interrupt.InterruptTool);
        interrupt_tool.* = .{};
        try registry.register(interrupt_tool.tool());
    }
    {
        const env_pt = try allocator.create(root.env_passthrough.EnvPassthroughTool);
        env_pt.* = .{};
        try registry.register(env_pt.tool());
    }
    {
        const cred_tool = try allocator.create(root.credential_files.CredentialFilesTool);
        cred_tool.* = .{};
        try registry.register(cred_tool.tool());
    }
    {
        const session_tool = try allocator.create(root.session_search.SessionSearchTool);
        session_tool.* = .{};
        try registry.register(session_tool.tool());
    }
    {
        const vision_tool = try allocator.create(root.vision_tools.VisionTool);
        vision_tool.* = .{};
        try registry.register(vision_tool.tool());
    }
    {
        const img_tool = try allocator.create(root.image_generation.ImageGenerationTool);
        img_tool.* = .{};
        try registry.register(img_tool.tool());
    }
    {
        const screen_tool = try allocator.create(root.vision_tools.ScreenCaptureTool);
        screen_tool.* = .{};
        try registry.register(screen_tool.tool());
    }
    {
        const tts_tool_inst = try allocator.create(root.tts_tool.TtsTool);
        tts_tool_inst.* = .{};
        try registry.register(tts_tool_inst.tool());
    }
    {
        const trans_tool = try allocator.create(root.transcription_tools.TranscriptionTool);
        trans_tool.* = .{};
        try registry.register(trans_tool.tool());
    }
    {
        const msg_tool = try allocator.create(root.send_message_tool.SendMessageTool);
        msg_tool.* = .{};
        try registry.register(msg_tool.tool());
    }
    {
        const ha_tool = try allocator.create(root.homeassistant_tool.HomeAssistantTool);
        ha_tool.* = .{};
        try registry.register(ha_tool.tool());
    }
    {
        const mem_tool = try allocator.create(root.memory_tool.MemoryTool);
        mem_tool.* = try root.memory_tool.MemoryTool.init(allocator);
        errdefer mem_tool.deinit();
        try registry.register(mem_tool.tool());
    }
    {
        const clar_tool = try allocator.create(root.clarify_tool.ClarifyTool);
        clar_tool.* = .{};
        try registry.register(clar_tool.tool());
    }
    {
        const mcp_t = try allocator.create(root.mcp_tool.MCPTool);
        mcp_t.* = .{};
        try registry.register(mcp_t.tool());
    }
    {
        const mcp_list = try allocator.create(root.mcp_tool.MCPListServersTool);
        mcp_list.* = .{};
        try registry.register(mcp_list.tool());
    }
    {
        const proc_reg = try allocator.create(root.process_registry.ProcessRegistryTool);
        proc_reg.* = try root.process_registry.ProcessRegistryTool.init(allocator);
        errdefer proc_reg.deinit();
        try registry.register(proc_reg.tool());
    }
    {
        const code_exec = try allocator.create(root.code_execution_tool.CodeExecutionTool);
        code_exec.* = .{};
        try registry.register(code_exec.tool());
    }

    return registry;
}
