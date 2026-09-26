# knot3bot 架构设计

> 面向开发者的架构说明。项目概览见 `README.md`，HTTP API 细节见 `docs/api.md`。

## 总览

knot3bot 是一个用 Zig 编写的高性能 AI coding agent，产物为单一二进制（`zig-out/bin/knot3bot`），链接系统 `libsqlite3` 做会话存储，其余全部纯 Zig 实现（JSON、HTTP、SSE）。三种运行形态：

1. **CLI 交互模式**（默认）——REPL + 斜杠命令 + setup 向导
2. **服务端模式**（`--server`）——OpenAI 兼容 REST API + Dashboard
3. **ACP 模式**（`--acp`）——IDE 集成：stdio 上的 JSON-RPC（initialize / session/new / session/prompt 最小子集）

## 模块地图

```
src/
├── main.zig            # CLI 入口：参数解析、setup 向导、模式分发
├── agent/
│   ├── agent.zig       # ReAct 循环（流式/非流式）、UsageStats/TokenBudget
│   ├── context_compressor.zig  # 上下文压缩：prune 工具结果 → 边界对齐 → LLM 摘要
│   ├── trajectory.zig  # JSONL 审计轨迹落盘（completed/failed 双文件）
│   ├── skills.zig      # 内置技能（plan/debug/research/review/shell-safety）+ 安全级别
│   ├── credential_pool.zig     # 多 key 轮换（*_API_KEY, *_API_KEY_2..5）
│   ├── prompt_cache.zig        # 前缀 prompt 缓存
│   └── skill_self_improve.zig  # 技能自改进（工具调用模式统计）
├── providers/
│   ├── openai_compatible.zig   # 8 家 OpenAI 兼容 provider 的统一客户端（SSE/tool calling）
│   ├── anthropic.zig           # Anthropic 专用客户端
│   └── root.zig                # Provider 枚举：10 家，含 -plan 变体
├── tools/              # 44 个工具（factory.zig 默认注册表 / full 注册表）
├── server/
│   ├── http_server.zig # HTTP 服务：路由、SSE、auth、静态 dashboard、健康检查
│   ├── rate_limiter.zig        # 按 key 令牌桶 + 突发 + 空闲清理
│   └── circuit_breaker.zig     # 三态熔断，防 provider 级联故障
├── memory/
│   ├── memory.zig      # MemorySystem（内存后端）+ MemoryBackend 分发
│   ├── sqlite_impl.zig # SQLite 后端：FTS5 全文检索 + 排序
│   ├── sqlite_stub.zig # 禁用 SQLite 时的编译期桩（-Denable-sqlite=false）
│   └── manager.zig     # ManagerMemoryBackend 适配层
├── gateway/            # 多平台消息路由（已实现：cli、http）
├── tui/                # libvaxis 终端 UI（交互模式）
├── adapters/           # ACP 适配器（实验性，未接线）
├── shared/             # JSON 工具、日志器、io/context 全局
├── skills/             # 11 个技能包（SKILL.md）
├── option-skills/      # 4 个可选技能包
└── tests.zig           # 统一测试根：全部 356 个测试编进一个二进制
```

## 服务端请求流程

```
curl → tcp accept → handleConnection
  → 解析请求行/头（request_id 生成、security headers）
  → auth（Bearer 常量时间比较）→ rate_limiter.check → circuit_breaker
  → 路由:
     /v1/chat/completions → Agent ReAct 循环 → LLM(SSE) → 工具调用 → 响应
     /v1/models           → 模型注册表
     /health /ready       → 立即返回（provider 连通性检查在后台线程）
     /metrics             → Prometheus 文本格式
     /dashboard /api/*    → 静态 HTML + 状态 JSON
```

## 关键设计决策

- **内存管理**：请求级 ArenaAllocator，长生命周期 GeneralPurposeAllocator/SafeAllocator。工具结果的内存所有权归调用方——`ToolRegistry.call` 会把工具返回值按字节拷出（工具可能返回指向已解析 JSON 参数的借用切片）。
- **FFI**：Zig 0.17 移除了 `@cImport`，SQLite 头通过 `b.addTranslateC` 生成 `sqlite3_c` 模块；`enable-sqlite` 编译选项在真实现（`sqlite_impl.zig`）与桩（`sqlite_stub.zig`）之间编译期切换。
- **工具注册**：`factory.zig` 显式构造 + `toolVTable(T)` comptime 生成 vtable（静态分发，无运行时注册开销）。
- **依赖**：`build.zig.zon` 声明 vaxis（git 依赖）与 sqlite3（路径依赖 vendor/sqlite3）；vaxis 的传递依赖 uucode/zigimg 拉取进 `zig-pkg/` 并为当前工具链打了补丁。websocket/wasm3 已移除（从未接线）。
- **工具链**：Zig 0.17.0-dev 快照（Homebrew）。依赖包内对扁平化 `@typeInfo` API 的兼容层见 `zig-pkg/uucode-*/src/config.zig` 的 `structFields/enumFields` shim。

## 测试

- 入口：`zig build test`（`--summary all` 看分套明细）。全部测试在 `src/tests.zig` 下列出；**新增跨目录 import 的测试文件必须加进去**，否则不会被编译（单文件 `zig test` 只对 import 不出自身目录的文件有效）。
- 集成测试用每测试一个 ArenaAllocator 包住 registry/memory 流量，保证泄漏检测干净。
- 测试中 `std.log.err` 会让 build step 失败（0.17 行为）——已优雅处理的路径用 warn。

## 已知边界（诚实清单）

- `mcp` / `mcp_list_servers` 工具是占位（返回说明文案，需要异步基础设施）
- `process_registry` 的 spawn、`session_search`、`vision`/`screen_capture` 部分逻辑为占位
- `memory.openviking` 后端枚举值未实现（返回 `error.NotImplemented`）
- gateway 仅实现 cli/http 两个平台
- ACP 适配器实现的是最小子集（无 session/update 流式通知、无 fs/tool 桥接）
- 真实 LLM API 的端到端行为需要有效 key 验证，仓库测试全部使用 mock/fake key
