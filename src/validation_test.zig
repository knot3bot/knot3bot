const std = @import("std");
const validation = @import("validation.zig");

test "validatePath - accepts valid relative paths" {
    try validation.validatePath("file.txt");
    try validation.validatePath("path/to/file.txt");
    try validation.validatePath("./file.txt");
    try validation.validatePath("subdir/file");
}

test "validatePath - rejects path traversal" {
    try std.testing.expectError(error.PathTraversal, validation.validatePath("../etc/passwd"));
    try std.testing.expectError(error.PathTraversal, validation.validatePath("foo/../../bar"));
    try std.testing.expectError(error.PathTraversal, validation.validatePath("..\\windows\\system32"));
}

test "validatePath - rejects absolute paths" {
    try std.testing.expectError(error.PathTraversal, validation.validatePath("/etc/passwd"));
    try std.testing.expectError(error.PathTraversal, validation.validatePath("/absolute/path"));
}

test "validatePath - rejects null bytes" {
    try std.testing.expectError(error.InvalidPath, validation.validatePath("file\x00.txt"));
    try std.testing.expectError(error.InvalidPath, validation.validatePath("path\x00"));
}

test "validateUrl - accepts valid HTTPS URLs" {
    try validation.validateUrl("https://example.com");
    try validation.validateUrl("https://api.openai.com/v1/chat");
    try validation.validateUrl("https://github.com/user/repo");
    try validation.validateUrl("https://httpbin.org/get");
}

test "validateUrl - rejects localhost variants" {
    try std.testing.expectError(error.BlockedHost, validation.validateUrl("http://localhost:8080"));
    try std.testing.expectError(error.BlockedHost, validation.validateUrl("http://127.0.0.1:3000"));
    try std.testing.expectError(error.BlockedHost, validation.validateUrl("http://0.0.0.0/api"));
    try std.testing.expectError(error.BlockedHost, validation.validateUrl("http://[::1]/endpoint"));
}

test "validateUrl - rejects private IP ranges" {
    try std.testing.expectError(error.BlockedHost, validation.validateUrl("http://10.0.0.1/api"));
    try std.testing.expectError(error.BlockedHost, validation.validateUrl("http://192.168.1.1/secret"));
    try std.testing.expectError(error.BlockedHost, validation.validateUrl("http://192.168.0.256/api"));
}

test "validateUrl - rejects file:// scheme" {
    try std.testing.expectError(error.BlockedUrlScheme, validation.validateUrl("file:///etc/passwd"));
    try std.testing.expectError(error.BlockedUrlScheme, validation.validateUrl("file://localhost/c:/windows"));
}

test "validateUrl - rejects null bytes" {
    try std.testing.expectError(error.InvalidUrl, validation.validateUrl("https://example.com\x00.txt"));
}
