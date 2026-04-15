//! URL safety checking to prevent SSRF attacks
//! Blocks requests to private/internal network addresses

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// Check if a URL is safe (not pointing to private/internal addresses)
pub fn isSafeUrl(url: []const u8) bool {
    // Parse URL to extract hostname
    const hostname = extractHostname(url) orelse return false;

    // Check blocked hostnames
    if (isBlockedHostname(hostname)) return false;

    // Check if hostname is localhost or similar
    if (isLocalhost(hostname)) return false;

    // Try to resolve and check IP
    return checkResolvedIp(hostname);
}

/// Extract hostname from URL
fn extractHostname(url: []const u8) ?[]const u8 {
    // Simple URL parsing - find host after :// and before : or /
    const proto_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const host_start = proto_end + 3;

    var host_end = url.len;
    for (url[host_start..], 0..) |c, i| {
        if (c == ':' or c == '/' or c == '?' or c == '#') {
            host_end = host_start + i;
            break;
        }
    }

    const hostname = url[host_start..host_end];
    if (hostname.len == 0) return null;

    // Remove brackets from IPv6 addresses
    if (hostname[0] == '[') {
        if (std.mem.indexOf(u8, hostname, "]")) |end| {
            return hostname[1..end];
        }
    }

    return hostname;
}

/// Check if hostname is in the blocked list
fn isBlockedHostname(hostname: []const u8) bool {
    const lower = toLower(hostname);
    defer std.heap.page_allocator.free(lower);

    const blocked = &[_][]const u8{
        "metadata.google.internal",
        "metadata.goog",
        "169.254.169.254", // AWS metadata
        "metadata.aws.internal",
    };

    for (blocked) |blocked_host| {
        if (std.mem.eql(u8, lower, blocked_host)) return true;
    }

    return false;
}

/// Check if hostname refers to localhost
fn isLocalhost(hostname: []const u8) bool {
    const lower = toLower(hostname);
    defer std.heap.page_allocator.free(lower);

    const localhosts = &[_][]const u8{
        "localhost",
        "127.0.0.1",
        "0.0.0.0",
        "::1",
        "[::1]",
    };

    for (localhosts) |lh| {
        if (std.mem.eql(u8, lower, lh)) return true;
    }

    return false;
}

/// Check resolved IP against private ranges
fn checkResolvedIp(hostname: []const u8) bool {
    // For now, do simple pattern matching on the hostname
    // A full implementation would use DNS resolution

    // Check if it's an IP address directly
    if (isPrivateIp(hostname)) return false;

    // Check hostname patterns that might resolve to private IPs
    const lower = toLower(hostname);
    defer std.heap.page_allocator.free(lower);

    // Internal network hostnames
    if (std.mem.indexOf(u8, lower, "internal") != null) return false;
    if (std.mem.indexOf(u8, lower, "localhost") != null) return false;
    if (std.mem.indexOf(u8, lower, "metadata") != null) return false;

    return true;
}

/// Check if an IP address is in private ranges
fn isPrivateIp(ip: []const u8) bool {
    // Try to parse as IPv4
    if (std.net.Address.parseIp4(ip, 0)) |_| {
        return isPrivateIpv4(ip);
    } else |_| {
        // Not an IPv4 address, might be IPv6 or hostname
        return false;
    }
}

/// Check IPv4 address against private ranges
fn isPrivateIpv4(ip: []const u8) bool {
    // Simple parsing - check first octet
    const parts = std.mem.split(u8, ip, ".");
    var octets: [4]u32 = .{ 0, 0, 0, 0 };
    var idx: usize = 0;

    while (parts.next()) |part| {
        if (idx >= 4) return false;
        octets[idx] = std.fmt.parseInt(u32, part, 10) catch return false;
        idx += 1;
    }

    // 127.0.0.0/8 - loopback
    if (octets[0] == 127) return true;

    // 10.0.0.0/8 - private
    if (octets[0] == 10) return true;

    // 172.16.0.0/12 - private
    if (octets[0] == 172 and octets[1] >= 16 and octets[1] <= 31) return true;

    // 192.168.0.0/16 - private
    if (octets[0] == 192 and octets[1] == 168) return true;

    // 169.254.0.0/16 - link-local
    if (octets[0] == 169 and octets[1] == 254) return true;

    // 100.64.0.0/10 - CGNAT
    if (octets[0] == 100 and octets[1] >= 64 and octets[1] <= 127) return true;

    // 0.0.0.0 - unspecified
    if (octets[0] == 0 and octets[1] == 0 and octets[2] == 0 and octets[3] == 0) return true;

    return false;
}

/// Convert string to lowercase
fn toLower(s: []const u8) []u8 {
    var result = std.heap.page_allocator.alloc(u8, s.len) catch return s;
    for (s, 0..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return result;
}

/// UrlSafetyTool - Tool for checking URL safety
pub const UrlSafetyTool = struct {
    pub const tool_name = "url_safety";
    pub const tool_description = "Check if a URL is safe (not pointing to private/internal network addresses)";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"The URL to check for safety\"}},\"required\":[\"url\"]}";

    pub fn tool(self: *UrlSafetyTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *UrlSafetyTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const url = root.getString(args, "url") orelse {
            return ToolResult.fail("url is required");
        };

        const safe = isSafeUrl(url);

        // Build JSON response
        var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
        errdefer buf.deinit();
        const w = buf.writer();

        try w.writeAll("{\"safe\":");
        if (safe) {
            try w.writeAll("true");
        } else {
            try w.writeAll("false");
        }
        try w.writeAll(",\"url\":");
        try w.print("\"{s}\"", .{url});
        try w.writeAll("}");

        return ToolResult{
            .success = true,
            .output = try buf.toOwnedSlice(allocator),
        };
    }

    pub const vtable = root.ToolVTable(@This());
};
