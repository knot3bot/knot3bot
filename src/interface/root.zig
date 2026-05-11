//! Interface module — CLI, Gateway, ACP adapter.
//! Re-exports for the new directory structure.

pub const cli = @import("../cli.zig");
pub const display = @import("../display.zig");
pub const gateway = @import("../gateway/root.zig");
pub const acp_adapter = @import("../adapters/acp_adapter.zig");
