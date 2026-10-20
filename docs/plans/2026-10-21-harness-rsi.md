# Harness² RSI（k=1）Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在不改 LLM 权重的前提下，给 knot3bot 加上可快照、可回滚的任务层脚手架对比改进（Propose-Probe-Compose，k=1），并把跨任务赢过的补丁记入 SQLite，供下次同标签任务当先验。

**Architecture:** Harness 是一份有界结构体（提示段落、工具顺序、重试次数、完成清单），不是自由文本。Probe 通过可注入的 `TaskExecutor` 跑基线加 2 个候选，单元测试不打网络。对比评价只做轨迹成对偏好。基线打不赢就保持原版本。`SkillSelfImprove` 继续只提供失败工具线索，不再假装能生成 skill 正文。默认关闭，`AgentConfig.enable_harness_rsi = true` 才进入循环，且 probe 期间不读 prompt cache。

**Tech Stack:** Zig 0.17、现有 `ToolRegistry` / `TrajectoryRecorder` / `SkillSelfImprove` / SQLite（`src/memory/sqlite_impl.zig`）。不新增依赖。

**不做:** k≥3 默认、元 harness 自动改写、shell 沙箱重写、权重训练、把仓库里所有既有测试一次性挂进 `zig build test`。

---

## 数据契约

```zig
pub const Harness = struct {
    version: u32,
    parent: ?u32,
    prompt_section: []const u8, // ≤ 512 字节
    tool_order: []const []const u8, // 名字必须属于当前注册表
    max_retries: u8, // 0..2
    checklist: []const u8, // ≤ 512 字节
};

pub const HarnessPatch = struct {
    prompt_append: []const u8, // ≤ 200 字节，空切片表示不改
    retry_delta: i8, // -1、0 或 +1
    checklist_append: []const u8, // ≤ 200 字节
};

pub const TrajectorySummary = struct {
    harness_version: u32,
    task_tag: []const u8,
    final_answer: []const u8,
    tool_names: []const []const u8,
    tool_success: []const bool,
    error_count: u32,
};

pub const PairPreference = enum { left, right, tie };
```

Probe 期间 `PromptCache.get` 不得被调用。空实现工具不得出现在发给模型的工具列表里。

---

### Task 1: 空工具不再向模型报成功

**Files:**
- Modify: `src/tools/homeassistant_tool.zig`
- Modify: `src/tools/image_generation.zig`
- Modify: `src/tools/tts_tool.zig`
- Modify: `src/tools/send_message_tool.zig`
- Modify: `src/tools/factory.zig`（`addExtendedTools`，约 39–43 行）
- Test: `src/tools/stub_honesty_test.zig`
- Modify: `build.zig` 的 `test` 文件列表（约 185–193 行）

**Step 1: Write the failing test**

`src/tools/stub_honesty_test.zig`：对上述四个工具各调一次 `execute`，断言 `result.success == false`，且 `error_msg` 非空。再调用 `factory.createDefaultRegistry`（以 `factory.zig` 里实际导出的构造函数名为准），断言注册表里没有 `homeassistant`、`image_generation`、`send_message`、`tts`。

不要改 `src/tui/vaxis_tui.zig` 和 `src/cli.zig` 里的 `send_message` 动作枚举，那是 UI 事件，不是这个工具。

**Step 2: Run test to verify it fails**

Run: `zig test src/tools/stub_honesty_test.zig`

Expected: FAIL。当前 `execute` 返回 `.success = true`，且 `factory.zig` 会注册这四个工具。

**Step 3: Write minimal implementation**

四个 `execute` 在读完必填参数后直接 `return ToolResult.fail("not_available")`，不再拼接 `"success":true`。从 `addExtendedTools` 删掉这四次 `registry.register`。`transcription_tools.zig` 与 `vision_tools.zig` 若同样在无外部调用时返回 `success = true`，按同一规则移出默认注册表并返回 `not_available`。`mcp_tool.zig` 已经返回失败，保留注册，供后续真接入。

**Step 4: Run test to verify it passes**

Run: `zig test src/tools/stub_honesty_test.zig`

Expected: PASS

把该文件加入 `build.zig` 的 test 列表。

**Step 5: Commit**

```bash
git add src/tools/homeassistant_tool.zig src/tools/image_generation.zig \
  src/tools/tts_tool.zig src/tools/send_message_tool.zig \
  src/tools/factory.zig src/tools/stub_honesty_test.zig build.zig
git commit -m "fix: stop advertising unimplemented tools as successful"
```

---

### Task 2: Harness 结构、补丁应用与快照

**Files:**
- Create: `src/agent/harness.zig`
- Test: 同文件底部 `test` 块
- Modify: `build.zig` test 列表

**Step 1: Write the failing test**

```zig
test "applyPatch clamps retries and rejects overlong prompt" {
    const base = Harness{
        .version = 1,
        .parent = null,
        .prompt_section = "be careful",
        .tool_order = &.{},
        .max_retries = 1,
        .checklist = "",
    };
    const patch = HarnessPatch{
        .prompt_append = " verify tool output",
        .retry_delta = 5, // 必须被夹到上限，不能变成 6
        .checklist_append = "check",
    };
    const next = try applyPatch(std.testing.allocator, base, patch);
    defer freeHarness(std.testing.allocator, next);
    try std.testing.expectEqual(@as(u32, 2), next.version);
    try std.testing.expectEqual(@as(?u32, 1), next.parent);
    try std.testing.expect(next.max_retries <= 2);
    try std.testing.expect(std.mem.indexOf(u8, next.prompt_section, "verify tool output") != null);
}

test "snapshot roundtrip preserves parent" {
    // saveSnapshot / loadSnapshot 用内存目录或 ArrayList 字节，不依赖磁盘布局之外的字段
}
```

**Step 2: Run test to verify it fails**

Run: `zig test src/agent/harness.zig --test-filter "applyPatch"`

Expected: FAIL，`Harness` 未定义。

**Step 3: Write minimal implementation**

`applyPatch` 分配新的 `Harness`：`version = base.version + 1`，`parent = base.version`。`max_retries` 先按 `i8` 相加再夹到 `0..2`。拼接后的 `prompt_section` 与 `checklist` 超过 512 字节则返回 `error.HarnessTooLarge`，不截断后假装成功。`tool_order` 原样复制，本任务不改工具顺序。

`saveSnapshot(allocator, dir_writer 或 []u8 sink, harness)` 写成一行 JSON。`loadSnapshot` 解析回结构体。快照文本里要有 `version` 和 `parent`，供回滚查找。

**Step 4: Run test to verify it passes**

Run: `zig test src/agent/harness.zig`

Expected: PASS。把该文件加入 `build.zig` test 列表。

**Step 5: Commit**

```bash
git add src/agent/harness.zig build.zig
git commit -m "feat: add bounded harness snapshots"
```

---

### Task 3: 确定性 Propose

**Files:**
- Create: `src/agent/harness_propose.zig`
- Modify: `src/agent/skill_self_improve.zig`（只读已有 `getFailingTools`，不改其写入逻辑）
- Test: `src/agent/harness_propose.zig`

Propose 在这一版不调用模型。输入是当前 `Harness` 加上失败工具名列表，输出恰好 2 个 `HarnessPatch`。

**Step 1: Write the failing test**

```zig
test "propose emits two bounded patches from failing tools" {
    const patches = try propose(std.testing.allocator, baseHarness(), &.{ "shell" });
    defer freePatches(std.testing.allocator, patches);
    try std.testing.expectEqual(@as(usize, 2), patches.len);
    try std.testing.expect(patches[0].retry_delta == 1 or patches[0].retry_delta == 0 or patches[0].retry_delta == -1);
    try std.testing.expect(std.mem.indexOf(u8, patches[0].checklist_append, "shell") != null);
    try std.testing.expect(patches[0].prompt_append.len <= 200);
}
```

无失败工具时，两个补丁仍然合法：一个 `retry_delta = 0` 且 checklist 为空，另一个只追加固定短句 `"restate the user goal before the final answer"`。禁止返回 0 个或 3 个以上补丁。

**Step 2: Run test to verify it fails**

Run: `zig test src/agent/harness_propose.zig`

Expected: FAIL，`propose` 未定义。

**Step 3: Write minimal implementation**

`propose(allocator, harness, failing_tools)`：

- 候选 A：`retry_delta = 1`，`checklist_append` 为 `"verify output of "` 加上第一个失败工具名（无失败工具则为空）。
- 候选 B：`retry_delta = 0`，`prompt_append` 为固定短句，`checklist_append` 为空。

补丁字节超限返回 `error.PatchTooLarge`。不读取环境，不调用 curl。

**Step 4: Run test to verify it passes**

Run: `zig test src/agent/harness_propose.zig`

Expected: PASS。加入 `build.zig` test 列表。

**Step 5: Commit**

```bash
git add src/agent/harness_propose.zig build.zig
git commit -m "feat: propose two bounded harness patches"
```

---

### Task 4: Probe 执行器与 cache 隔离

**Files:**
- Create: `src/agent/harness_probe.zig`
- Modify: `src/agent/agent.zig` 的 `runWithSteps`（约 367 行 cache 读取处）仅增加一个 `bypass_prompt_cache: bool` 字段，默认 `false`
- Test: `src/agent/harness_probe.zig`

**Step 1: Write the failing test**

```zig
test "probe runs baseline plus two candidates and skips cache" {
    var calls: usize = 0;
    var saw_cache = false;
    const exec = struct {
        fn run(allocator: std.mem.Allocator, h: Harness, task: []const u8, ctx: *anyopaque) anyerror!TrajectorySummary {
            _ = allocator;
            _ = task;
            const box: *ProbeBox = @ptrCast(@alignCast(ctx));
            box.calls += 1;
            if (box.cache_hit) return error.CacheUsed;
            return .{
                .harness_version = h.version,
                .task_tag = "code",
                .final_answer = "ok",
                .tool_names = &.{},
                .tool_success = &.{},
                .error_count = 0,
            };
        }
    }.run;
    const out = try probe(std.testing.allocator, base, patches, "code", "fix the test", exec, &box);
    try std.testing.expectEqual(@as(usize, 3), out.summaries.len);
    try std.testing.expect(!saw_cache);
}
```

`probe` 的第一次调用必须使用未打补丁的基线，后两次使用 `applyPatch` 的结果。任一 executor 返回错误时，已分配的 summary 要释放，并向上返回该错误。

**Step 2: Run test to verify it fails**

Run: `zig test src/agent/harness_probe.zig`

Expected: FAIL。

**Step 3: Write minimal implementation**

```zig
pub const TaskExecutor = *const fn (
    allocator: std.mem.Allocator,
    harness: Harness,
    task: []const u8,
    ctx: *anyopaque,
) anyerror!TrajectorySummary;

pub fn probe(...) ![]TrajectorySummary
```

真实接入留到 Task 7。本任务的 executor 由调用方传入。在 `Agent` 上增加 `bypass_prompt_cache`。`runWithSteps` 里现有的 `if (self.prompt_cache)` 改为 `if (self.prompt_cache != null and !self.bypass_prompt_cache)`。probe 用的执行器在调用 `runWithSteps` 前把该字段设为 `true`，返回前设回 `false`（Task 7 再接）。

**Step 4: Run test to verify it passes**

Run: `zig test src/agent/harness_probe.zig`

Expected: PASS。加入 `build.zig` test 列表。

**Step 5: Commit**

```bash
git add src/agent/harness_probe.zig src/agent/agent.zig build.zig
git commit -m "feat: probe harness variants without prompt cache"
```

---

### Task 5: 成对偏好、Compose 与回滚

**Files:**
- Create: `src/agent/harness_compose.zig`
- Test: 同文件

**Step 1: Write the failing test**

三条用例：

1. 候选 A 对基线的偏好是 `right`（右为候选）且 A 对 B 也赢：返回 A 的 harness，`parent` 指向基线 version。
2. 两个候选对基线都是 `tie` 或基线赢：返回基线的克隆，version 不变。
3. 评价函数返回错误：`compose` 返回该错误，且不分配新快照。

评价函数签名：

```zig
pub const Judge = *const fn (
    allocator: std.mem.Allocator,
    task: []const u8,
    left: TrajectorySummary,
    right: TrajectorySummary,
    ctx: *anyopaque,
) anyerror!PairPreference;
```

测试里的 judge 按 `error_count` 较小者获胜，相等则 `tie`。不调用模型。

**Step 2: Run test to verify it fails**

Run: `zig test src/agent/harness_compose.zig`

Expected: FAIL。

**Step 3: Write minimal implementation**

比较顺序固定：基线 vs 候选 0，基线 vs 候选 1，若两者都胜过基线再比较候选 0 vs 候选 1。只有唯一胜者才替换。平局保留基线。

`rollback(snapshots, current) ?Harness` 返回 `parent` 对应的那一份。`parent == null` 时返回 `null`。

**Step 4: Run test to verify it passes**

Run: `zig test src/agent/harness_compose.zig`

Expected: PASS。加入 `build.zig` test 列表。

**Step 5: Commit**

```bash
git add src/agent/harness_compose.zig build.zig
git commit -m "feat: compose harness from pairwise preferences"
```

---

### Task 6: 元记忆只记赢过的补丁

**Files:**
- Create: `src/agent/harness_memory.zig`
- Modify: `src/memory/sqlite_impl.zig` 的建表段（约 55 行附近）仅当该模块已经是记忆库的唯一建表入口时；否则 `harness_memory.zig` 自己 `CREATE TABLE IF NOT EXISTS`，避免改会话表语义
- Test: `src/agent/harness_memory.zig`

表：

```sql
CREATE TABLE IF NOT EXISTS harness_patterns (
  task_tag TEXT NOT NULL,
  patch_json TEXT NOT NULL,
  wins INTEGER NOT NULL,
  losses INTEGER NOT NULL,
  PRIMARY KEY (task_tag, patch_json)
);
```

**Step 1: Write the failing test**

用临时文件路径打开 SQLite（测试结束删除文件）。`recordWin("code", patch)` 两次后 `lookup("code")` 返回该补丁且 `wins == 2`。`lookup("office")` 返回空。败绩 `recordLoss` 不改变 `lookup` 作为 Propose 先验返回的内容：先验只返回 `wins > losses` 的行。

**Step 2: Run test to verify it fails**

Run: `zig test src/agent/harness_memory.zig`

Expected: FAIL。若本机构建未打开 SQLite，测试开头 `if (!@import("config").enable_sqlite) return;`，与仓库现有 SQLite 测试的跳过方式保持一致。

**Step 3: Write minimal implementation**

`lookup` 只按 `task_tag` 精确匹配，不做向量或模糊搜索。`patch_json` 用 Task 2 的快照字段子集。单标签最多返回 2 条，按 `wins - losses` 降序。

**Step 4: Run test to verify it passes**

Run: `zig test src/agent/harness_memory.zig`

Expected: PASS。加入 `build.zig` test 列表。

**Step 5: Commit**

```bash
git add src/agent/harness_memory.zig build.zig
git commit -m "feat: store winning harness patches by task tag"
```

---

### Task 7: 接到 Agent，默认关闭

**Files:**
- Modify: `src/agent/agent.zig` 的 `AgentConfig`（约 194 行）与 `runWithSteps`（约 351 行）
- Create: `src/agent/harness_session.zig`
- Test: `src/agent/harness_session.zig`

`AgentConfig` 增加：

```zig
enable_harness_rsi: bool = false,
harness_task_tag: []const u8 = "general",
harness_rsi_k: u8 = 1,
```

`harness_rsi_k` 大于 1 时本版仍只跑一轮（k=1）。字段留下，避免以后改配置名。

**Step 1: Write the failing test**

脚本化 executor 与 judge：

- 基线 `error_count = 2`
- 带 checklist 的候选 `error_count = 0`
- 另一个候选 `error_count = 2`

`runSession` 应返回胜出 harness 的 version = 基线 + 1，并调用 `recordWin` 一次。`enable_harness_rsi = false` 的对照用例调用次数为 1（只跑原任务，不 probe）。

**Step 2: Run test to verify it fails**

Run: `zig test src/agent/harness_session.zig`

Expected: FAIL。

**Step 3: Write minimal implementation**

`runSession` 顺序：

1. `lookup(task_tag)` 取出最多 2 条先验补丁。有先验时，两个 Propose 名额里第一个改为该先验，第二个仍用 Task 3 的确定性候选。
2. `probe` 三次，executor 的 ctx 里带 `bypass_prompt_cache = true`。
3. `compose`。胜出且 version 增加时 `recordWin`，否则 `recordLoss` 记两个候选。
4. 用胜出 harness 再执行一次正式任务（这次允许写 prompt cache）。返回这次的结果。

正式执行时把 `prompt_section` 追加到系统提示末尾，`checklist` 追加在其后，标题行固定为 `Harness checklist:`。`max_retries` 传给现有 `executeToolWithError`：仅当工具返回失败且重试次数未用尽时再调一次。不要重试成功的调用。

`runWithSteps` 在 `enable_harness_rsi` 为 false 时保持现有路径，包括 prompt cache。

从 `SkillSelfImprove.getFailingTools` 取失败工具名喂给 `propose`。不要调用 `generateSkillContent`。

**Step 4: Run test to verify it passes**

Run: `zig test src/agent/harness_session.zig && zig build test`

Expected: 新测试 PASS，既有 `zig build test` 仍 PASS。

**Step 5: Commit**

```bash
git add src/agent/harness_session.zig src/agent/agent.zig build.zig
git commit -m "feat: run one-step harness comparison before the task"
```

---

### Task 8: 文档与开关

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/configuration.md`

写明：

- 开关 `enable_harness_rsi`，默认关。
- k 固定为 1，每任务额外 3 次执行（2 个 probe + 1 次正式），再加上可能的基线 probe，合计 probe 3 次后还有 1 次正式运行。
- 对比变差时 version 不变。
- 元记忆只按 `task_tag` 精确复用 `wins > losses` 的补丁。
- 未接入 API 的工具不在默认注册表中。

不写论文复述。这一任务没有行为测试。`zig build test` 仍应通过。

```bash
git add docs/architecture.md docs/configuration.md
git commit -m "docs: describe harness rsi defaults and rollback"
```

---

## 验收

- `zig build test` 包含 `stub_honesty_test.zig`、`harness.zig`、`harness_propose.zig`、`harness_probe.zig`、`harness_compose.zig`、`harness_memory.zig`、`harness_session.zig`，且全部通过。
- 默认配置下 `runWithSteps` 的控制流与改动前一致（cache、迭代、工具消息仍在）。
- 打开 RSI 后，同一次任务的 probe 不会命中 prompt cache。
- 候选打不赢基线时，落盘的 harness version 不变。
- `homeassistant`、`image_generation`、`tts`、`send_message` 不在默认工具列表中，直接 `execute` 得到 `success = false`。

## 之后才做

模型驱动的 Propose / Judge（仍输出 `HarnessPatch` 与 `PairPreference`，超界补丁丢弃）、k 曲线、按任务嵌入做路由、shell 改为 argv 沙箱。这些都不进入本计划的提交。
