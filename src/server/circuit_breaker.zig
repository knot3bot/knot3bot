//! Circuit breaker for LLM provider calls
//! Prevents cascading failures by opening after N consecutive failures
//! and half-opening after a recovery timeout

const std = @import("std");

pub const CircuitState = enum { closed, open, half_open };

pub const CircuitBreakerConfig = struct {
    /// Number of consecutive failures before opening (default: 5)
    failure_threshold: u32 = 5,
    /// Time in seconds before attempting half-open (default: 30)
    recovery_timeout_secs: u32 = 30,
    /// Number of successful calls in half-open to close (default: 2)
    success_threshold: u32 = 2,
};

pub const CircuitBreaker = struct {
    config: CircuitBreakerConfig,
    state: CircuitState = .closed,
    failure_count: u32 = 0,
    success_count: u32 = 0,
    last_failure_time: i64 = 0,
    total_trips: u64 = 0,

    pub fn init(config: CircuitBreakerConfig) CircuitBreaker {
        return .{
            .config = config,
        };
    }

    /// Check if a request is allowed. Returns false if circuit is open.
    pub fn allowRequest(self: *CircuitBreaker) bool {
        switch (self.state) {
            .closed => return true,
            .open => {
                const now = std.time.timestamp();
                const elapsed = now - self.last_failure_time;
                if (elapsed >= @as(i64, self.config.recovery_timeout_secs)) {
                    self.state = .half_open;
                    self.success_count = 0;
                    return true;
                }
                return false;
            },
            .half_open => return true,
        }
    }

    /// Record a successful call
    pub fn recordSuccess(self: *CircuitBreaker) void {
        switch (self.state) {
            .closed => {
                self.failure_count = 0;
            },
            .half_open => {
                self.success_count += 1;
                if (self.success_count >= self.config.success_threshold) {
                    self.state = .closed;
                    self.failure_count = 0;
                    self.success_count = 0;
                }
            },
            .open => {},
        }
    }

    /// Record a failed call
    pub fn recordFailure(self: *CircuitBreaker) void {
        switch (self.state) {
            .closed => {
                self.failure_count += 1;
                if (self.failure_count >= self.config.failure_threshold) {
                    self.state = .open;
                    self.last_failure_time = std.time.timestamp();
                    self.total_trips += 1;
                }
            },
            .half_open => {
                self.state = .open;
                self.last_failure_time = std.time.timestamp();
                self.total_trips += 1;
            },
            .open => {},
        }
    }

    /// Get current state
    pub fn getState(self: *CircuitBreaker) CircuitState {
        return self.state;
    }

    /// Get remaining seconds until half-open (0 if not open)
    pub fn remainingTimeout(self: *CircuitBreaker) u32 {
        if (self.state != .open) return 0;
        const now = std.time.timestamp();
        const elapsed = now - self.last_failure_time;
        if (elapsed >= @as(i64, self.config.recovery_timeout_secs)) return 0;
        return @as(u32, @intCast(@as(i64, self.config.recovery_timeout_secs) - elapsed));
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CircuitBreaker stays closed on success" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 3 });
    try std.testing.expect(cb.getState() == .closed);
    try std.testing.expect(cb.allowRequest());

    cb.recordSuccess();
    try std.testing.expect(cb.getState() == .closed);
    try std.testing.expect(cb.failure_count == 0);
}

test "CircuitBreaker opens after threshold failures" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 3 });

    cb.recordFailure();
    try std.testing.expect(cb.getState() == .closed);

    cb.recordFailure();
    try std.testing.expect(cb.getState() == .closed);

    cb.recordFailure();
    try std.testing.expect(cb.getState() == .open);
    try std.testing.expect(cb.total_trips == 1);
}

test "CircuitBreaker rejects requests when open" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 1, .recovery_timeout_secs = 300 });

    cb.recordFailure();
    try std.testing.expect(cb.getState() == .open);
    try std.testing.expect(!cb.allowRequest());
    try std.testing.expect(cb.remainingTimeout() > 0);
}

test "CircuitBreaker transitions to half-open after timeout" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 1, .recovery_timeout_secs = 0 });

    cb.recordFailure();
    try std.testing.expect(cb.getState() == .open);

    // With 0 timeout, should transition immediately
    try std.testing.expect(cb.allowRequest());
    try std.testing.expect(cb.getState() == .half_open);
}

test "CircuitBreaker closes after success threshold in half-open" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 1, .success_threshold = 2, .recovery_timeout_secs = 0 });

    cb.recordFailure();
    try std.testing.expect(cb.getState() == .open);

    // Transition to half-open
    _ = cb.allowRequest();
    try std.testing.expect(cb.getState() == .half_open);

    cb.recordSuccess();
    try std.testing.expect(cb.getState() == .half_open);

    cb.recordSuccess();
    try std.testing.expect(cb.getState() == .closed);
}

test "CircuitBreaker reopens on failure during half-open" {
    var cb = CircuitBreaker.init(.{ .failure_threshold = 1, .recovery_timeout_secs = 0 });

    cb.recordFailure();
    _ = cb.allowRequest();
    try std.testing.expect(cb.getState() == .half_open);

    cb.recordFailure();
    try std.testing.expect(cb.getState() == .open);
    try std.testing.expect(cb.total_trips == 2);
}
