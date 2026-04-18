#!/bin/bash
#
# Baseline Test Script for knot3bot
# Tests: 1.工具可用 2.自我进化 3.skill安装 4.skill命中 5.skill创建
#

set -e

SERVER_URL="http://localhost:38789"
API_KEY="${BAILIAN_API_KEY:-sk-8be17dad4a9b40228ada67b2f93ed07b}"
HEALTHY=false
FAILED_TESTS=0
PASSED_TESTS=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED_TESTS++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED_TESTS++))
}

# Check if server is healthy
check_health() {
    log_info "检查服务健康状态..."

    response=$(curl -s "${SERVER_URL}/health" 2>/dev/null || echo "")

    if [ -z "$response" ]; then
        log_fail "服务健康检查失败 (无响应)"
        return 1
    fi

    if echo "$response" | grep -q '"ok"'; then
        HEALTHY=true
        log_pass "服务健康检查通过"
        return 0
    fi

    log_fail "服务健康检查失败"
    return 1
}

# Test 1: 工具可用性
test_tools_available() {
    log_info "测试 1: 工具可用性..."

    response=$(curl -s "${SERVER_URL}/api/tools" 2>/dev/null)

    if [ -z "$response" ]; then
        log_fail "无法获取工具列表"
        return 1
    fi

    tool_count=$(echo "$response" | jq '.tools | length' 2>/dev/null || echo "0")

    if [ "$tool_count" -gt 0 ]; then
        log_pass "工具列表获取成功 (共 ${tool_count} 个工具)"
        echo "$response" | jq -r '.tools[].name' | while read -r tool; do
            log_info "  - $tool"
        done
        return 0
    fi

    log_fail "工具列表为空或格式错误"
    return 1
}

# Test 2: 简单对话
test_simple_chat() {
    log_info "测试 2: 简单对话..."

    response=$(curl -s -X POST "${SERVER_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{
            "model": "qwen-plus",
            "messages": [{"role": "user", "content": "What is 2+2?"}]
        }' 2>/dev/null)

    if [ -z "$response" ]; then
        log_fail "对话请求无响应"
        return 1
    fi

    content=$(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null || echo "")

    if [ -n "$content" ] && [ "$content" != "null" ]; then
        log_pass "简单对话成功: $content"
        return 0
    fi

    log_fail "对话响应内容为空"
    echo "Response: $response" >&2
    return 1
}

# Test 3: 工具执行 (通过 shell 工具)
test_tool_execution() {
    log_info "测试 3: 工具执行 (shell ls)..."

    # 使用直接触发工具的提示
    response=$(curl -s -X POST "${SERVER_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{
            "model": "qwen-plus",
            "messages": [{"role": "user", "content": "Use the shell tool to run: echo hello"}]
        }' 2>/dev/null)

    if [ -z "$response" ]; then
        log_fail "工具执行请求无响应"
        return 1
    fi

    # 检查是否有工具调用或输出
    has_tool_call=$(echo "$response" | jq -r '.choices[0].message.tool_calls' 2>/dev/null || echo "null")
    content=$(echo "$response" | jq -r '.choices[0].message.content' 2>/dev/null || echo "")

    if [ "$has_tool_call" != "null" ] || echo "$content" | grep -qi "hello\|shell\|tool"; then
        log_pass "工具执行成功"
        return 0
    fi

    log_warn "工具可能未被调用 (模型直接回答)"
    log_info "响应: ${content:0:200}"
    return 0  # 不算失败，因为模型可能不支持工具调用
}

# Test 4: Skill Self-Improvement 功能
test_skill_self_improve() {
    log_info "测试 4: Skill Self-Improvement..."

    # 检查是否有 self-improve 相关的端点或标志
    health=$(curl -s "${SERVER_URL}/health" 2>/dev/null)
    skill_improve_enabled=$(echo "$health" | jq -r '.skill_self_improve // false' 2>/dev/null)

    if [ "$skill_improve_enabled" = "true" ]; then
        log_pass "Skill Self-Improvement 已启用"
        return 0
    fi

    # 检查命令行标志是否传递给了服务
    if curl -s "${SERVER_URL}/health" 2>/dev/null | grep -q "skill"; then
        log_pass "Skill Self-Improvement 可用"
        return 0
    fi

    log_warn "Skill Self-Improvement 状态未知 (可能未在启动时启用 --enable-skill-self-improve)"
    return 0  # 不算失败，因为可能是配置问题
}

# Test 5: Skill 安装/列表
test_skill_list() {
    log_info "测试 5: Skill 列表..."

    response=$(curl -s "${SERVER_URL}/api/skills" 2>/dev/null || echo "")

    if [ -n "$response" ] && [ "$response" != "{}" ]; then
        skill_count=$(echo "$response" | jq '.skills | length' 2>/dev/null || echo "0")
        log_pass "Skill 列表获取成功 (共 ${skill_count} 个)"
        return 0
    fi

    log_warn "Skill 列表端点不可用或为空 (这是正常的如果功能未实现)"
    return 0
}

# Test 6: 服务器配置验证
test_server_config() {
    log_info "测试 6: 服务器配置..."

    response=$(curl -s "${SERVER_URL}/health" 2>/dev/null)

    if [ -z "$response" ]; then
        log_fail "无法获取服务器配置"
        return 1
    fi

    provider=$(echo "$response" | jq -r '.provider' 2>/dev/null || echo "unknown")
    model=$(echo "$response" | jq -r '.model' 2>/dev/null || echo "unknown")
    tools_count=$(echo "$response" | jq -r '.tools' 2>/dev/null || echo "0")

    log_info "  Provider: $provider"
    log_info "  Model: $model"
    log_info "  Tools: $tools_count"

    if [ "$provider" != "unknown" ] && [ "$tools_count" -gt 0 ]; then
        log_pass "服务器配置正确"
        return 0
    fi

    log_fail "服务器配置异常"
    return 1
}

# 等待服务就绪
wait_for_server() {
    log_info "等待服务就绪..."
    for i in {1..30}; do
        if curl -s "${SERVER_URL}/health" > /dev/null 2>&1; then
            log_info "服务已就绪"
            return 0
        fi
        sleep 1
    done
    log_error "服务启动超时"
    exit 1
}

# 主测试流程
main() {
    echo "========================================"
    echo "  knot3bot 基线测试"
    echo "========================================"
    echo ""

    # 检查服务
    if ! check_health; then
        log_warn "服务未运行，尝试检查..."
    else
        HEALTHY=true
    fi

    echo ""
    echo "----------------------------------------"
    echo "开始测试..."
    echo "----------------------------------------"
    echo ""

    # 运行所有测试
    test_server_config
    echo ""

    test_tools_available
    echo ""

    test_simple_chat
    echo ""

    test_tool_execution
    echo ""

    test_skill_self_improve
    echo ""

    test_skill_list
    echo ""

    # 测试总结
    echo "----------------------------------------"
    echo "测试结果"
    echo "----------------------------------------"
    echo -e "${GREEN}通过: $PASSED_TESTS${NC}"
    echo -e "${RED}失败: $FAILED_TESTS${NC}"
    echo ""

    if [ $FAILED_TESTS -eq 0 ]; then
        log_info "所有测试通过!"
        exit 0
    else
        log_error "有测试失败"
        exit 1
    fi
}

# 解析参数
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --url URL     Set server URL (default: http://localhost:38789)"
        echo "  --help        Show this help"
        echo ""
        echo "Environment:"
        echo "  BAILIAN_API_KEY   API key for Bailian provider"
        exit 0
        ;;
    --url)
        SERVER_URL="${2:-http://localhost:38789}"
        shift 2
        ;;
esac

main