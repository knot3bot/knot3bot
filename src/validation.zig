const std = @import("std");

/// ValidationError represents input validation failures
pub const ValidationError = error{
    InvalidPath,
    PathTraversal,
    InvalidUrl,
    BlockedUrlScheme,
    BlockedHost,
};

/// Validate a file path to prevent path traversal attacks
/// Returns error if path contains ../ or absolute paths
pub fn validatePath(path: []const u8) ValidationError!void {
    // Reject null bytes (potential injection)
    if (std.mem.indexOfScalar(u8, path, 0)) |_| {
        return error.InvalidPath;
    }

    // Reject obvious path traversal attempts (forward and backslash)
    if (std.mem.indexOf(u8, path, "../") != null or std.mem.indexOf(u8, path, "..\\") != null) {
        return error.PathTraversal;
    }

    // Reject absolute paths (security risk)
    if (path.len > 0 and path[0] == '/') {
        return error.PathTraversal;
    }

}

/// Validate URL to prevent SSRF attacks
/// Blocks: localhost, private IPs, file:// scheme
pub fn validateUrl(url: []const u8) ValidationError!void {
    // Reject null bytes
    if (std.mem.indexOfScalar(u8, url, 0)) |_| {
        return error.InvalidUrl;
    }
    
    // Reject file:// scheme
    if (std.mem.indexOf(u8, url, "file://") != null) {
        return error.BlockedUrlScheme;
    }
    
    // Reject localhost variants
    const hosts_to_block = &[_][]const u8{
        "localhost",
        "127.0.0.1",
        "0.0.0.0",
        "[::1]",
    };
    for (hosts_to_block) |host| {
        if (std.mem.indexOf(u8, url, host) != null) {
            return error.BlockedHost;
        }
    }

    // Reject private IP patterns anywhere in URL
    if (std.mem.indexOf(u8, url, "10.") != null) {
        return error.BlockedHost;
    }
    if (std.mem.indexOf(u8, url, "192.168.") != null) {
        return error.BlockedHost;
    }
    if (std.mem.indexOf(u8, url, "172.16.") != null or std.mem.indexOf(u8, url, "172.17.") != null or
        std.mem.indexOf(u8, url, "172.18.") != null or std.mem.indexOf(u8, url, "172.19.") != null or
        std.mem.indexOf(u8, url, "172.2") != null or std.mem.indexOf(u8, url, "172.30.") != null or
        std.mem.indexOf(u8, url, "172.31.") != null) {
        return error.BlockedHost;
    }

}
