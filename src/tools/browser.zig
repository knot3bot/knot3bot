//! Browser tool - Web browser automation
//!
//! Provides browser automation capabilities for web interaction.
//! Uses osascript on macOS for Safari/Chrome control.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;
const shared = @import("../shared/root.zig");
const validation = @import("../validation.zig");

pub const BrowserTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "browser";
    pub const tool_description = "Control web browser - navigate, screenshot, click elements, fill forms";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"description\":\"Browser operation: navigate, screenshot, click, fill, back, forward, refresh, url, title\"},\"url\":{\"type\":\"string\",\"description\":\"URL for navigate operation\"},\"selector\":{\"type\":\"string\",\"description\":\"CSS selector for click/fill operations\"},\"value\":{\"type\":\"string\",\"description\":\"Value to fill in form fields\"}},\"required\":[\"operation\"]}";

    pub fn tool(self: *BrowserTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_self: *BrowserTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        _ = _self;
        const operation = getString(args, "operation") orelse return ToolResult.fail("operation required");

        if (std.mem.eql(u8, operation, "navigate")) {
            const url = getString(args, "url") orelse return ToolResult.fail("url required for navigate");
            return browserNavigate(allocator, url);
        } else if (std.mem.eql(u8, operation, "screenshot")) {
            return browserScreenshot(allocator);
        } else if (std.mem.eql(u8, operation, "url")) {
            return browserUrl(allocator);
        } else if (std.mem.eql(u8, operation, "title")) {
            return browserTitle(allocator);
        } else if (std.mem.eql(u8, operation, "back")) {
            return browserBack();
        } else if (std.mem.eql(u8, operation, "forward")) {
            return browserForward();
        } else if (std.mem.eql(u8, operation, "refresh")) {
            return browserRefresh();
        } else if (std.mem.eql(u8, operation, "click")) {
            const selector = getString(args, "selector") orelse return ToolResult.fail("selector required for click");
            return browserClick(allocator, selector);
        } else if (std.mem.eql(u8, operation, "fill")) {
            const selector = getString(args, "selector") orelse return ToolResult.fail("selector required for fill");
            const value = getString(args, "value") orelse return ToolResult.fail("value required for fill");
            return browserFill(allocator, selector, value);
        } else {
            return ToolResult.fail("Invalid operation. Use: navigate, screenshot, click, fill, back, forward, refresh, url, title");
        }
    }

    fn browserNavigate(allocator: std.mem.Allocator, url: []const u8) !ToolResult {
        validation.validateUrl(url) catch {
            return ToolResult.fail("Invalid or blocked URL (SSRF protection)");
        };

        const script = try std.fmt.allocPrint(allocator, "osascript -e 'tell application \"Safari\" to open location \"{s}\"'", .{url});
        defer allocator.free(script);

        var child = std.process.spawn(shared.context.io(), .{
            .argv = &[_][]const u8{ "sh", "-c", script },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            return ToolResult.fail("Failed to launch browser. Is osascript available?");
        };

        _ = child.wait(shared.context.io()) catch {};

        const response = try std.fmt.allocPrint(allocator, "Navigated to {s}", .{url});
        return ToolResult.ok(response);
    }

    fn browserScreenshot(allocator: std.mem.Allocator) !ToolResult {
        const screenshot_path = "/tmp/knot3bot_screenshot.png";

        var child = std.process.spawn(shared.context.io(), .{
            .argv = &[_][]const u8{ "screencapture", "-x", screenshot_path },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            return ToolResult.fail("Failed to capture screenshot");
        };

        _ = child.wait(shared.context.io()) catch {};

        return ToolResult.ok(try std.fmt.allocPrint(allocator, "Screenshot saved to {s}", .{screenshot_path}));
    }

    fn browserUrl(allocator: std.mem.Allocator) !ToolResult {
        const result = std.process.run(allocator, shared.context.io(), .{
            .argv = &[_][]const u8{ "osascript", "-e", "tell application \"Safari\" to return URL of current tab of front window" },
        }) catch {
            return ToolResult.fail("Failed to get URL");
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const url = std.mem.trim(u8, result.stdout, " \n\r");
        return ToolResult.ok(try allocator.dupe(u8, url));
    }

    fn browserTitle(allocator: std.mem.Allocator) !ToolResult {
        const result = std.process.run(allocator, shared.context.io(), .{
            .argv = &[_][]const u8{ "osascript", "-e", "tell application \"Safari\" to return name of current tab of front window" },
        }) catch {
            return ToolResult.fail("Failed to get title");
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const title = std.mem.trim(u8, result.stdout, " \n\r");
        return ToolResult.ok(try allocator.dupe(u8, title));
    }

    fn browserBack() !ToolResult {
        var child = std.process.spawn(shared.context.io(), .{
            .argv = &[_][]const u8{ "osascript", "-e", "tell application \"Safari\" to tell front window to go back" },
        }) catch {
            return ToolResult.fail("Failed to go back");
        };
        _ = child.wait(shared.context.io()) catch {};
        return ToolResult.ok("Navigated back");
    }

    fn browserForward() !ToolResult {
        var child = std.process.spawn(shared.context.io(), .{
            .argv = &[_][]const u8{ "osascript", "-e", "tell application \"Safari\" to tell front window to go forward" },
        }) catch {
            return ToolResult.fail("Failed to go forward");
        };
        _ = child.wait(shared.context.io()) catch {};
        return ToolResult.ok("Navigated forward");
    }

    fn browserRefresh() !ToolResult {
        var child = std.process.spawn(shared.context.io(), .{
            .argv = &[_][]const u8{ "osascript", "-e", "tell application \"Safari\" to tell front window to do JavaScript \"location.reload()\"" },
        }) catch {
            return ToolResult.fail("Failed to refresh");
        };
        _ = child.wait(shared.context.io()) catch {};
        return ToolResult.ok("Page refreshed");
    }

    fn browserClick(allocator: std.mem.Allocator, selector: []const u8) !ToolResult {
        const script = try std.fmt.allocPrint(allocator, "osascript -e 'tell application \"Safari\" to do JavaScript \"document.querySelector('{s}').click()\" in front window'", .{selector});
        defer allocator.free(script);

        var child = std.process.spawn(shared.context.io(), .{
            .argv = &[_][]const u8{ "sh", "-c", script },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            return ToolResult.fail("Failed to click element");
        };

        _ = child.wait(shared.context.io()) catch {};

        return ToolResult.ok(try std.fmt.allocPrint(allocator, "Clicked element: {s}", .{selector}));
    }

    fn browserFill(allocator: std.mem.Allocator, selector: []const u8, value: []const u8) !ToolResult {
        const script = try std.fmt.allocPrint(allocator, "osascript -e 'tell application \"Safari\" to do JavaScript \"document.querySelector('{s}').value='{s}'\" in front window'", .{ selector, value });
        defer allocator.free(script);

        var child = std.process.spawn(shared.context.io(), .{
            .argv = &[_][]const u8{ "sh", "-c", script },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            return ToolResult.fail("Failed to fill element");
        };

        _ = child.wait(shared.context.io()) catch {};

        return ToolResult.ok(try std.fmt.allocPrint(allocator, "Filled element: {s} = {s}", .{ selector, value }));
    }

    pub const vtable = root.ToolVTable(@This());
};
