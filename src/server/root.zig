//! Server package - HTTP API server with OpenAI-compatible endpoints

pub const Server = @import("http_server.zig").Server;
pub const AuthConfig = @import("http_server.zig").AuthConfig;
pub const ServerConfig = @import("http_server.zig").ServerConfig;
