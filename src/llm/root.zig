//! LLM module — unified interface for AI model providers.
//! Re-exports from providers/ for the new directory structure.

pub const openai_compatible = @import("../providers/openai_compatible.zig");
pub const Provider = openai_compatible.Provider;
pub const LLMClient = openai_compatible.LLMClient;

pub const anthropic = @import("../providers/anthropic.zig");
pub const AnthropicClient = anthropic.AnthropicClient;
