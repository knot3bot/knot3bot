//! Rate limiter and circuit breaker tests
const std = @import("std");
const RateLimiter = @import("rate_limiter.zig").RateLimiter;
const RateLimitConfig = @import("rate_limiter.zig").RateLimitConfig;
const PerKeyLimit = @import("rate_limiter.zig").PerKeyLimit;
const CircuitBreaker = @import("circuit_breaker.zig").CircuitBreaker;
const CircuitBreakerConfig = @import("circuit_breaker.zig").CircuitBreakerConfig;
const CircuitState = @import("circuit_breaker.zig").CircuitState;

// ============================================================================
// Additional RateLimiter Tests
// ============================================================================

test "RateLimiter remaining() returns correct count" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, .{
        .max_requests = 100,
        .window_ms = 1000,
        .burst_size = 5,
    });
    defer limiter.deinit();

    const ip = "10.0.0.1";

    // Initially should have burst_size tokens
    try std.testing.expectEqual(@as(u32, 5), limiter.remaining(ip));

    // Consume 2 tokens
    _ = limiter.check(ip);
    _ = limiter.check(ip);
    try std.testing.expectEqual(@as(u32, 3), limiter.remaining(ip));

    // Consume remaining
    _ = limiter.check(ip);
    _ = limiter.check(ip);
    try std.testing.expectEqual(@as(u32, 0), limiter.remaining(ip));

    // When exhausted, remaining should stay at 0
    _ = limiter.check(ip);
    try std.testing.expectEqual(@as(u32, 0), limiter.remaining(ip));
}

test "RateLimiter default config" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, .{});
    defer limiter.deinit();

    const ip = "10.0.0.1";

    // Default burst_size is 10
    try std.testing.expectEqual(@as(u32, 10), limiter.remaining(ip));

    // Consume all
    for (0..10) |_| {
        _ = limiter.check(ip);
    }

    // Should be exhausted
    try std.testing.expect(!limiter.check(ip));
}

test "RateLimiter custom limits override defaults" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, .{
        .max_requests = 10,
        .window_ms = 1000,
        .burst_size = 5,
    });
    defer limiter.deinit();

    // Set a higher burst limit
    try limiter.setKeyLimit("tier1", .{
        .max_requests = 50,
        .window_ms = 1000,
        .burst_size = 20,
    });

    // tier1 should have 20 burst
    try std.testing.expectEqual(@as(u32, 20), limiter.remaining("tier1"));

    // regular should have default 5 burst
    try std.testing.expectEqual(@as(u32, 5), limiter.remaining("regular"));
}

test "RateLimiter multiple update custom limit" {
    const allocator = std.testing.allocator;
    var limiter = RateLimiter.init(allocator, .{
        .max_requests = 10,
        .window_ms = 1000,
        .burst_size = 5,
    });
    defer limiter.deinit();

    // Set initial limit
    try limiter.setKeyLimit("key1", .{
        .max_requests = 100,
        .window_ms = 1000,
        .burst_size = 50,
    });

    // Update to different limit
    try limiter.setKeyLimit("key1", .{
        .max_requests = 200,
        .window_ms = 1000,
        .burst_size = 100,
    });

    // Should use the new limit
    try std.testing.expectEqual(@as(u32, 100), limiter.remaining("key1"));
}

// ============================================================================
// Additional CircuitBreaker Tests
// ============================================================================

test "CircuitBreaker total_trips increments correctly" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 1 });

    try std.testing.expectEqual(@as(u64, 0), cb.total_trips);

    // First failure - trip 1
    cb.recordFailure();
    try std.testing.expectEqual(@as(u64, 1), cb.total_trips);

    // Reset and trip again via half-open
    cb = CircuitBreaker.init(.{ .failure_threshold = 1, .recovery_timeout_secs = 0 });
    cb.recordFailure();
    _ = cb.allowRequest(); // Go to half-open
    cb.recordFailure();
    try std.testing.expectEqual(@as(u64, 2), cb.total_trips);
}

test "CircuitBreaker remainingTimeout when not open" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 5 });

    // When closed, timeout should be 0
    try std.testing.expectEqual(@as(u32, 0), cb.remainingTimeout());

    // When half-open, timeout should be 0
    cb.state = .half_open;
    try std.testing.expectEqual(@as(u32, 0), cb.remainingTimeout());
}

test "CircuitBreaker config defaults" {
    const cb = CircuitBreaker.init(.{});

    try std.testing.expectEqual(@as(u32, 5), cb.config.failure_threshold);
    try std.testing.expectEqual(@as(u32, 30), cb.config.recovery_timeout_secs);
    try std.testing.expectEqual(@as(u32, 2), cb.config.success_threshold);
}

test "CircuitBreaker multiple success resets failure count" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 3 });

    // Add some failures
    cb.recordFailure();
    cb.recordFailure();
    try std.testing.expect(cb.failure_count == 2);

    // Success should reset
    cb.recordSuccess();
    try std.testing.expect(cb.failure_count == 0);

    // Need 3 more failures to trip
    cb.recordFailure();
    cb.recordFailure();
    try std.testing.expect(cb.getState() == .closed);

    cb.recordFailure();
    try std.testing.expect(cb.getState() == .open);
}

test "CircuitBreaker open state ignores further failures" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 1 });

    // Trip the breaker
    cb.recordFailure();
    try std.testing.expect(cb.getState() == .open);
    try std.testing.expectEqual(@as(u64, 1), cb.total_trips);

    // Further failures should not increment total_trips again
    cb.recordFailure();
    cb.recordFailure();
    cb.recordFailure();
    try std.testing.expectEqual(@as(u64, 1), cb.total_trips);
}

test "CircuitBreaker half-open ignores success in closed/open" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 1 });

    // In closed state, success_count should not matter
    cb.state = .closed;
    cb.recordSuccess();
    // Should not affect state
    try std.testing.expect(cb.getState() == .closed);

    // In half-open, success_count should close circuit
    cb.state = .half_open;
    cb.recordSuccess();
    cb.recordSuccess(); // 2 successes to close
    try std.testing.expect(cb.getState() == .closed);
}

test "CircuitBreaker recovery_timeout exact match" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 1, .recovery_timeout_secs = 1 });

    cb.recordFailure();
    try std.testing.expect(cb.getState() == .open);

    // Wait would be needed in real scenario
    // With 0 elapsed, should not transition
    try std.testing.expect(!cb.allowRequest());
}
