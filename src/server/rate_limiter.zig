//! Rate limiting middleware for API endpoints
//! Implements token bucket algorithm for request rate limiting with per-key support

const std = @import("std");

pub const RateLimitConfig = struct {
    max_requests: u32 = 100,
    window_ms: u32 = 60000,
    burst_size: u32 = 10,
};

/// Per-key rate limit configuration
pub const PerKeyLimit = struct {
    max_requests: u32,
    window_ms: u32,
    burst_size: u32,

    pub fn default() PerKeyLimit {
        return .{
            .max_requests = 100,
            .window_ms = 60000,
            .burst_size = 10,
        };
    }
};

const ClientBucket = struct {
    tokens: f64,
    last_update: i64,
};

pub const RateLimiter = struct {
    config: RateLimitConfig,
    /// Per-key custom limits (API key hash -> limit config)
    key_limits: std.StringHashMap(PerKeyLimit),
    /// Client buckets (key identifier -> bucket)
    clients: std.StringHashMap(ClientBucket),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: RateLimitConfig) RateLimiter {
        return .{
            .config = config,
            .key_limits = std.StringHashMap(PerKeyLimit).init(allocator),
            .clients = std.StringHashMap(ClientBucket).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.clients.deinit();

        var key_it = self.key_limits.iterator();
        while (key_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.key_limits.deinit();
    }

    /// Set a custom rate limit for a specific key
    pub fn setKeyLimit(self: *RateLimiter, key: []const u8, limit: PerKeyLimit) !void {
        const existing = self.key_limits.get(key);
        if (existing) |_| {
            self.key_limits.put(key, limit) catch return;
        } else {
            const duped_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(duped_key);
            try self.key_limits.put(duped_key, limit);
        }
    }

    /// Get the effective limit for a key (custom or default)
    fn getEffectiveLimit(self: *RateLimiter, key: []const u8) PerKeyLimit {
        if (self.key_limits.get(key)) |custom| {
            return custom;
        }
        return PerKeyLimit{
            .max_requests = self.config.max_requests,
            .window_ms = self.config.window_ms,
            .burst_size = self.config.burst_size,
        };
    }

    /// Check if request is allowed for the given identifier
    /// Uses API key if provided, otherwise falls back to IP
    pub fn check(self: *RateLimiter, identifier: []const u8) bool {
        const now = std.time.timestamp() * std.time.ms_per_s;
        const effective_limit = self.getEffectiveLimit(identifier);
        const bucket = self.getOrCreateBucket(identifier, now, effective_limit);

        if (bucket.tokens >= 1.0) {
            const new_bucket = ClientBucket{
                .tokens = bucket.tokens - 1.0,
                .last_update = now,
            };
            if (self.clients.get(identifier)) |_| {
                self.clients.put(identifier, new_bucket) catch return true;
            } else {
                const key = self.allocator.dupe(u8, identifier) catch return true;
                self.clients.put(key, new_bucket) catch {
                    self.allocator.free(key);
                    return true;
                };
            }
            return true;
        }

        if (self.clients.get(identifier)) |_| {
            self.clients.put(identifier, bucket) catch {};
        } else {
            const key = self.allocator.dupe(u8, identifier) catch return false;
            self.clients.put(key, bucket) catch {
                self.allocator.free(key);
                return false;
            };
        }
        return false;
    }

    fn getOrCreateBucket(self: *RateLimiter, identifier: []const u8, now: i64, limit: PerKeyLimit) ClientBucket {
        if (self.clients.get(identifier)) |existing| {
            const elapsed = @as(f64, @floatFromInt(now - existing.last_update));
            const tokens_to_add = elapsed * @as(f64, @floatFromInt(limit.max_requests)) / @as(f64, @floatFromInt(limit.window_ms));
            const new_tokens = @min(@as(f64, @floatFromInt(limit.burst_size)), existing.tokens + tokens_to_add);
            return ClientBucket{ .tokens = new_tokens, .last_update = now };
        }
        return ClientBucket{
            .tokens = @as(f64, @floatFromInt(limit.burst_size)),
            .last_update = now,
        };
    }

    /// Get remaining tokens for an identifier
    pub fn remaining(self: *RateLimiter, identifier: []const u8) u32 {
        const effective_limit = self.getEffectiveLimit(identifier);
        if (self.clients.get(identifier)) |bucket| {
            return @as(u32, @intFromFloat(@max(0, bucket.tokens)));
        }
        return effective_limit.burst_size;
    }

    /// Record a request for metrics (track usage by key)
    pub fn recordUsage(self: *RateLimiter, identifier: []const u8) void {
        _ = self;
        _ = identifier;
        // Future: track per-key usage for metrics
    }
};

test "RateLimiter basic functionality" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, .{
        .max_requests = 10,
        .window_ms = 1000,
        .burst_size = 5,
    });
    defer limiter.deinit();

    const ip = "192.168.1.1";
    var allowed: u32 = 0;
    for (0..5) |_| {
        if (limiter.check(ip)) allowed += 1;
    }
    try std.testing.expectEqual(@as(u32, 5), allowed);
    try std.testing.expect(!limiter.check(ip));
}

test "RateLimiter different identifiers independent" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, .{
        .max_requests = 10,
        .window_ms = 1000,
        .burst_size = 2,
    });
    defer limiter.deinit();

    _ = limiter.check("192.168.1.1");
    _ = limiter.check("192.168.1.1");
    try std.testing.expect(limiter.check("192.168.1.2"));
    try std.testing.expect(limiter.check("192.168.1.2"));
}

test "RateLimiter per-key custom limits" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, .{
        .max_requests = 10,
        .window_ms = 1000,
        .burst_size = 2,
    });
    defer limiter.deinit();

    // Set custom limit for premium key
    try limiter.setKeyLimit("premium-key", .{
        .max_requests = 100,
        .window_ms = 1000,
        .burst_size = 50,
    });

    // Premium key should have higher limit
    var premium_allowed: u32 = 0;
    for (0..50) |_| {
        if (limiter.check("premium-key")) premium_allowed += 1;
    }
    try std.testing.expectEqual(@as(u32, 50), premium_allowed);

    // Regular key should still have low limit
    var regular_allowed: u32 = 0;
    for (0..3) |_| {
        if (limiter.check("regular-key")) regular_allowed += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), regular_allowed);
}
