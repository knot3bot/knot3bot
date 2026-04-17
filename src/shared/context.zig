//! Global process context for Zig 0.16.0 migration.
//!
//! In Zig 0.16.0, I/O and environment variables are no longer globally
//! accessible. This module provides a pragmatic migration path by storing
//! the process Init context at startup for use throughout the codebase.
//!
//! TODO: Long-term, pass io/environ explicitly through the call stack.
const std = @import("std");

var g_io: ?std.Io = null;
var g_environ: ?*const std.process.Environ.Map = null;
var g_gpa: ?std.mem.Allocator = null;

pub fn init(io_instance: std.Io, environ_map: *const std.process.Environ.Map, gpa_allocator: std.mem.Allocator) void {
    g_io = io_instance;
    g_environ = environ_map;
    g_gpa = gpa_allocator;
}

pub fn io() std.Io {
    if (g_io) |io_instance| return io_instance;
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn environ() *const std.process.Environ.Map {
    return g_environ.?;
}

pub fn gpa() std.mem.Allocator {
    return g_gpa.?;
}

/// Get environment variable value or null.
pub fn getenv(key: []const u8) ?[]const u8 {
    return g_environ.?.get(key);
}

/// Compatibility helpers for std.fs.cwd() operations migrated to std.Io
pub fn cwdWriteFile(path: []const u8, content: []const u8) !void {
    const io_instance = io();
    return std.Io.Dir.cwd().writeFile(io_instance, .{ .sub_path = path, .data = content });
}

pub fn cwdReadFileAlloc(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const io_instance = io();
    return std.Io.Dir.cwd().readFileAlloc(io_instance, path, allocator, std.Io.Limit.limited(max));
}

pub fn cwdOpenDir(path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    const io_instance = io();
    return std.Io.Dir.cwd().openDir(io_instance, path, options);
}

pub fn cwdMakeDir(path: []const u8) !void {
    const io_instance = io();
    return std.Io.Dir.cwd().createDir(io_instance, path, .default_dir);
}

pub fn cwdMakePath(path: []const u8) !void {
    const io_instance = io();
    return std.Io.Dir.cwd().createDirPath(io_instance, path);
}

pub fn cwdCreateFile(path: []const u8, options: std.Io.Dir.CreateFileOptions) !std.Io.File {
    const io_instance = io();
    return std.Io.Dir.cwd().createFile(io_instance, path, options);
}

pub fn cwdOpenFile(path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    const io_instance = io();
    return std.Io.Dir.cwd().openFile(io_instance, path, options);
}

pub fn cwdDeleteFile(path: []const u8) !void {
    const io_instance = io();
    return std.Io.Dir.cwd().deleteFile(io_instance, path);
}

pub fn cwdDeleteTree(path: []const u8) !void {
    const io_instance = io();
    return std.Io.Dir.cwd().deleteTree(io_instance, path);
}

pub fn cwdAccess(path: []const u8) !void {
    const io_instance = io();
    return std.Io.Dir.cwd().access(io_instance, path, .{});
}

pub fn cwdRename(old_path: []const u8, new_path: []const u8) !void {
    const io_instance = io();
    return std.Io.Dir.cwd().rename(old_path, std.Io.Dir.cwd(), new_path, io_instance);
}

pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

/// Get current Unix timestamp in seconds.
pub fn timestamp() i64 {
    return std.Io.Clock.Timestamp.now(io(), .real).raw.toSeconds();
}

/// Get current Unix timestamp in milliseconds.
pub fn milliTimestamp() i64 {
    return std.Io.Clock.Timestamp.now(io(), .real).raw.toMilliseconds();
}
