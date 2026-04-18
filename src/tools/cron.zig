//! Cron tool - Schedule and manage periodic tasks
//!
//! Allows scheduling commands to run at specific intervals

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;
const shared = @import("../shared/root.zig");

pub const CronTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "cron";
    pub const tool_description = "Schedule and manage periodic tasks with cron expressions";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"description\":\"Operation: add, list, remove, run\"},\"name\":{\"type\":\"string\",\"description\":\"Name of the cron job\"},\"schedule\":{\"type\":\"string\",\"description\":\"Cron expression (e.g., '*/5 * * * *' for every 5 minutes)\"},\"command\":{\"type\":\"string\",\"description\":\"Command to execute\"},\"job_id\":{\"type\":\"string\",\"description\":\"Job ID for list/remove/run operations\"}},\"required\":[\"operation\"]}";

    pub fn tool(self: *CronTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *CronTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const operation = getString(args, "operation") orelse return ToolResult.fail("operation required");

        if (std.mem.eql(u8, operation, "add")) {
            const name = getString(args, "name") orelse return ToolResult.fail("name required for add");
            const schedule = getString(args, "schedule") orelse return ToolResult.fail("schedule required for add");
            const command = getString(args, "command") orelse return ToolResult.fail("command required for add");

            if (!isScheduleValid(schedule)) {
                return ToolResult.fail("Invalid cron expression");
            }

            return try self.addJob(allocator, name, schedule, command);
        } else if (std.mem.eql(u8, operation, "list")) {
            return self.listJobs(allocator);
        } else if (std.mem.eql(u8, operation, "remove")) {
            const job_id = getString(args, "job_id") orelse return ToolResult.fail("job_id required for remove");
            return self.removeJob(allocator, job_id);
        } else if (std.mem.eql(u8, operation, "run")) {
            const job_id = getString(args, "job_id") orelse return ToolResult.fail("job_id required for run");
            return self.runJob(allocator, job_id);
        }

        return ToolResult.fail("Unknown operation. Use: add, list, remove, run");
    }

    fn isScheduleValid(schedule: []const u8) bool {
        var parts = std.mem.splitSequence(u8, schedule, " ");
        var count: usize = 0;
        while (parts.next()) |part| : (count += 1) {
            if (part.len == 0) return false;
        }
        return count == 5;
    }

    fn addJob(self: *CronTool, allocator: std.mem.Allocator, name: []const u8, schedule: []const u8, command: []const u8) !ToolResult {
        const cron_dir_path = try std.fmt.allocPrint(allocator, "{s}/.knot3bot/cron", .{self.workspace_dir});
        defer allocator.free(cron_dir_path);

        shared.context.cwdMakeDir(cron_dir_path) catch |err| if (err != error.PathAlreadyExists) return err;

        const job_id = try std.fmt.allocPrint(allocator, "{d}", .{shared.context.timestamp()});
        defer allocator.free(job_id);

        const job_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ cron_dir_path, job_id });
        defer allocator.free(job_path);

        var job_file = try shared.context.cwdCreateFile(job_path, .{});
        defer job_file.close(shared.context.io());

        var buf: [1024]u8 = undefined;
        const json_str = try std.fmt.bufPrint(&buf,
            \\{{"id":"{s}","name":"{s}","schedule":"{s}","command":"{s}","created_at":{d}}}
        , .{
            job_id,
            name,
            schedule,
            command,
            shared.context.timestamp(),
        });

        try job_file.writeStreamingAll(shared.context.io(), json_str);

        return ToolResult.ok(try std.fmt.allocPrint(allocator, "Job added: {s} (ID: {s})", .{ name, job_id }));
    }

    fn listJobs(self: *CronTool, allocator: std.mem.Allocator) !ToolResult {
        const cron_dir_path = try std.fmt.allocPrint(allocator, "{s}/.knot3bot/cron", .{self.workspace_dir});
        defer allocator.free(cron_dir_path);

        var dir = shared.context.cwdOpenDir(cron_dir_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return ToolResult.ok("No cron jobs scheduled");
            }
            return err;
        };
        defer dir.close(shared.context.io());

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);
        try result.appendSlice(allocator, "Cron Jobs:\n");

        var it = dir.iterate();
        while (it.next(shared.context.io()) catch null) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".json")) {
                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cron_dir_path, entry.name });
                defer allocator.free(full_path);

                const content = try shared.context.cwdReadFileAlloc(allocator, full_path, 4096);
                defer allocator.free(content);

                try result.appendSlice(allocator, content);
                try result.appendSlice(allocator, "\n");
            }
        }

        return ToolResult.ok(try result.toOwnedSlice(allocator));
    }

    fn removeJob(self: *CronTool, allocator: std.mem.Allocator, job_id: []const u8) !ToolResult {
        const cron_dir_path = try std.fmt.allocPrint(allocator, "{s}/.knot3bot/cron", .{self.workspace_dir});
        defer allocator.free(cron_dir_path);

        const job_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ cron_dir_path, job_id });
        defer allocator.free(job_path);

        shared.context.cwdDeleteFile(job_path) catch |err| {
            if (err == error.FileNotFound) {
                return ToolResult.fail("Job not found");
            }
            return err;
        };

        return ToolResult.ok("Job removed");
    }

    fn runJob(self: *CronTool, allocator: std.mem.Allocator, job_id: []const u8) !ToolResult {
        const cron_dir_path = try std.fmt.allocPrint(allocator, "{s}/.knot3bot/cron", .{self.workspace_dir});
        defer allocator.free(cron_dir_path);

        const job_path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ cron_dir_path, job_id });
        defer allocator.free(job_path);

        const content = shared.context.cwdReadFileAlloc(allocator, job_path, 4096) catch |err| {
            if (err == error.FileNotFound) {
                return ToolResult.fail("Job not found");
            }
            return err;
        };
        defer allocator.free(content);

        const command = parseJsonCommand(content, allocator) catch |parse_err| {
            return ToolResult.fail(try std.fmt.allocPrint(allocator, "Failed to parse job: {}", .{parse_err}));
        };
        defer allocator.free(command);

        const result = std.process.run(allocator, shared.context.io(), .{
            .argv = &[_][]const u8{ "sh", "-c", command },
            .cwd = .{ .path = self.workspace_dir },
        }) catch {
            return ToolResult.fail("Failed to execute command");
        };
        defer allocator.free(result.stderr);

        if (result.stdout.len > 0) {
            return ToolResult.ok(result.stdout);
        }
        allocator.free(result.stdout);
        return ToolResult.ok("Command executed");
    }

    fn parseJsonCommand(content: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const cmd_val = obj.get("command") orelse return error.MissingCommand;
        if (cmd_val != .string) return error.InvalidCommand;
        return try allocator.dupe(u8, cmd_val.string);
    }

    pub const vtable = root.ToolVTable(@This());
};
