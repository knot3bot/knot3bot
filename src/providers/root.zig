//! Providers package - AI model providers
//!
//! Supports OpenAI-compatible APIs via the OpenAICompatible client.

pub const openai_compatible = @import("openai_compatible.zig");
pub const Provider = openai_compatible.Provider;
pub const ChatMessage = openai_compatible.ChatMessage;
pub const ChatRequest = openai_compatible.ChatRequest;
pub const ChatResponse = openai_compatible.ChatResponse;
pub const ToolDef = openai_compatible.ToolDef;
pub const FunctionDef = openai_compatible.FunctionDef;
pub const LLMClient = openai_compatible.LLMClient;
pub const anthropic = @import("anthropic.zig");
