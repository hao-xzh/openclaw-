#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════╗
# ║  🤖 OpenClaw × DeepSeek 一键接入脚本                  ║
# ║  自动配置 OpenClaw 使用 DeepSeek AI                   ║
# ╚══════════════════════════════════════════════════════╝
#
# 用法: bash Mac一键接入DeepSeek.command
# 前提: OpenClaw 已安装

set -euo pipefail

OPENCLAW_PAUSE_ON_EXIT=false
if [[ "${OPENCLAW_SKIP_PAUSE:-0}" != "1" ]]; then
  OPENCLAW_PAUSE_ON_EXIT=true
fi

pause_before_exit() {
  local exit_code=$?
  if [[ "$OPENCLAW_PAUSE_ON_EXIT" == true ]] && [[ -t 0 ]]; then
    echo ""
    echo "=================================================="
    if [[ "$exit_code" -eq 0 ]]; then
      echo "脚本执行完毕，按回车键关闭窗口..."
    else
      echo "脚本已退出（错误码: $exit_code），按回车键关闭窗口..."
    fi
    read -r
  fi
  return "$exit_code"
}

trap pause_before_exit EXIT

# ─────────────────────────────────────────────
# 颜色
# ─────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
  BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m'
  DIM='\033[2m' NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

log_ok()   { echo -e "  ${GREEN}✅${NC} $*"; }
log_fail() { echo -e "  ${RED}❌${NC} $*"; }
log_warn() { echo -e "  ${YELLOW}⚠️${NC}  $*"; }
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }

# ─────────────────────────────────────────────
# DeepSeek 模型配置
# ─────────────────────────────────────────────
DEEPSEEK_BASE_URL="https://api.deepseek.com/v1"
DEEPSEEK_MODELS=(
  "deepseek-chat:DeepSeek V3:false:text:64000:8192"
  "deepseek-reasoner:DeepSeek R1:true:text:64000:8192"
)

# OpenClaw 配置文件路径
CONFIG_DIR="$HOME/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"

# ─────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────
show_banner() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  🤖 OpenClaw × DeepSeek 一键接入                     ║"
  echo "║  自动配置 DeepSeek AI 为 OpenClaw 的模型提供商        ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ─────────────────────────────────────────────
# 前置检查
# ─────────────────────────────────────────────
check_prerequisites() {
  echo -e "\n${BOLD}[1/4] 🔍 前置检查...${NC}"

  # 检查 OpenClaw
  if ! command -v openclaw &>/dev/null; then
    log_fail "OpenClaw 未安装"
    echo ""
    echo -e "  ${CYAN}→${NC} 请先运行安装脚本: bash Mac一键安装.command"
    exit 1
  fi
  local oc_ver
  oc_ver="$(openclaw --version 2>/dev/null || echo 'unknown')"
  log_ok "OpenClaw 已安装 ($oc_ver)"

  # 检查 node (需要用 node 处理 JSON)
  if ! command -v node &>/dev/null; then
    log_fail "Node.js 未安装（配置需要）"
    exit 1
  fi
  log_ok "Node.js $(node --version 2>/dev/null)"

  # 检查配置目录
  if [[ ! -d "$CONFIG_DIR" ]]; then
    log_warn "~/.openclaw 目录不存在，将自动创建"
    mkdir -p "$CONFIG_DIR"
  fi
  log_ok "配置目录: $CONFIG_DIR"
}

# ─────────────────────────────────────────────
# 获取 API Key
# ─────────────────────────────────────────────
get_api_key() {
  echo -e "\n${BOLD}[2/4] 🔑 输入 DeepSeek API Key...${NC}"
  echo ""
  echo -e "  ${DIM}获取 API Key: https://platform.deepseek.com/api_keys${NC}"
  echo ""

  local api_key=""
  while [[ -z "$api_key" ]]; do
    read -rsp "  请输入 DeepSeek API Key (sk-...): " api_key
    echo ""
    if [[ -z "$api_key" ]]; then
      log_warn "API Key 不能为空，请重新输入"
    elif [[ ! "$api_key" =~ ^sk- ]]; then
      log_warn "API Key 格式不正确 (应以 sk- 开头)，是否继续？(y/N)"
      read -r confirm
      if [[ "${confirm,,}" != "y" ]]; then
        api_key=""
      fi
    fi
  done

  DEEPSEEK_API_KEY="$api_key"
  log_ok "API Key 已接收 (${api_key:0:6}...${api_key: -4})"
}

# ─────────────────────────────────────────────
# 选择默认模型
# ─────────────────────────────────────────────
select_model() {
  echo -e "\n${BOLD}[3/4] 🧠 选择默认模型...${NC}"
  echo ""
  echo -e "  ${BOLD}1)${NC} deepseek-chat   ${DIM}— DeepSeek V3 (通用对话，速度快)${NC}"
  echo -e "  ${BOLD}2)${NC} deepseek-reasoner ${DIM}— DeepSeek R1 (深度推理，更强)${NC}"
  echo ""

  local choice=""
  while [[ "$choice" != "1" && "$choice" != "2" ]]; do
    read -rp "  请选择 [1/2] (默认 1): " choice
    choice="${choice:-1}"
  done

  if [[ "$choice" == "1" ]]; then
    DEFAULT_MODEL="deepseek/deepseek-chat"
    DEFAULT_MODEL_NAME="DeepSeek V3"
  else
    DEFAULT_MODEL="deepseek/deepseek-reasoner"
    DEFAULT_MODEL_NAME="DeepSeek R1"
  fi

  log_ok "默认模型: $DEFAULT_MODEL ($DEFAULT_MODEL_NAME)"
}

# ─────────────────────────────────────────────
# 写入配置
# ─────────────────────────────────────────────
write_config() {
  echo -e "\n${BOLD}[4/4] ⚙️  写入配置...${NC}"

  # 备份现有配置
  if [[ -f "$CONFIG_FILE" ]]; then
    local backup="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$backup"
    log_ok "已备份现有配置 → $(basename "$backup")"
  fi

  # 使用 node 来安全地读取/合并 JSON5 配置
  node -e "
const fs = require('fs');
const path = require('path');

const configPath = '${CONFIG_FILE}';
let config = {};

// 读取现有配置
if (fs.existsSync(configPath)) {
  try {
    const content = fs.readFileSync(configPath, 'utf-8');
    // 简单处理 JSON5 (去掉注释和尾逗号)
    const cleaned = content
      .replace(/\/\/.*$/gm, '')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/,\s*([}\]])/g, '\$1');
    if (cleaned.trim()) {
      config = JSON.parse(cleaned);
    }
  } catch (e) {
    console.error('  ⚠️  现有配置解析失败，将创建新配置');
    config = {};
  }
}

// 确保嵌套结构存在
if (!config.env) config.env = {};
if (!config.agents) config.agents = {};
if (!config.agents.defaults) config.agents.defaults = {};
if (!config.agents.defaults.model) config.agents.defaults.model = {};
if (!config.agents.defaults.models) config.agents.defaults.models = {};
if (!config.models) config.models = {};
if (!config.models.providers) config.models.providers = {};

// 1. 设置 DEEPSEEK_API_KEY 环境变量
config.env.DEEPSEEK_API_KEY = '${DEEPSEEK_API_KEY}';

// 2. 设置默认模型
config.agents.defaults.model.primary = '${DEFAULT_MODEL}';

// 3. 添加模型别名
config.agents.defaults.models['deepseek/deepseek-chat'] = { alias: 'DeepSeek V3' };
config.agents.defaults.models['deepseek/deepseek-reasoner'] = { alias: 'DeepSeek R1' };

// 4. 如果没有 fallbacks，或 fallbacks 中没有 DeepSeek，添加另一个作为 fallback
if (!config.agents.defaults.model.fallbacks) {
  config.agents.defaults.model.fallbacks = [];
}
const fallbackModel = '${DEFAULT_MODEL}' === 'deepseek/deepseek-chat' 
  ? 'deepseek/deepseek-reasoner' 
  : 'deepseek/deepseek-chat';
if (!config.agents.defaults.model.fallbacks.includes(fallbackModel)) {
  config.agents.defaults.model.fallbacks.push(fallbackModel);
}

// 5. 配置 DeepSeek 自定义 Provider
config.models.mode = 'merge';
config.models.providers.deepseek = {
  baseUrl: '${DEEPSEEK_BASE_URL}',
  apiKey: '\${DEEPSEEK_API_KEY}',
  api: 'openai-completions',
  models: [
    {
      id: 'deepseek-chat',
      name: 'DeepSeek V3',
      reasoning: false,
      input: ['text'],
      cost: { input: 0.27, output: 1.10, cacheRead: 0.07, cacheWrite: 0.27 },
      contextWindow: 64000,
      maxTokens: 8192,
    },
    {
      id: 'deepseek-reasoner',
      name: 'DeepSeek R1',
      reasoning: true,
      input: ['text'],
      cost: { input: 0.55, output: 2.19, cacheRead: 0.14, cacheWrite: 0.55 },
      contextWindow: 64000,
      maxTokens: 8192,
    },
  ],
};

// 写入配置
fs.writeFileSync(configPath, JSON.stringify(config, null, 2), 'utf-8');
console.log('  ✅ 配置已写入: ${CONFIG_FILE}');
" 2>&1

  if [[ $? -ne 0 ]]; then
    log_fail "配置写入失败"
    exit 1
  fi
}

# ─────────────────────────────────────────────
# 验证
# ─────────────────────────────────────────────
verify() {
  echo ""

  # 验证 API Key 可用性
  log_info "验证 DeepSeek API 连通性..."
  local response
  response=$(curl -fsSL --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"deepseek-chat","messages":[{"role":"user","content":"Hi"}],"max_tokens":5}' \
    "${DEEPSEEK_BASE_URL}/chat/completions" 2>&1) || true

  if echo "$response" | grep -qi '"choices"'; then
    log_ok "DeepSeek API 连通验证通过"
  elif echo "$response" | grep -qi '"error"'; then
    local error_msg
    error_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
    log_warn "API 返回错误: ${error_msg:-未知}"
    echo -e "  ${CYAN}→${NC} 请检查 API Key 是否正确、余额是否充足"
  else
    log_warn "API 连通验证跳过（网络问题，不影响配置）"
  fi

  # 显示配置摘要
  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  🎉 DeepSeek 接入完成！                              ║"
  echo "╠══════════════════════════════════════════════════════╣"
  echo -e "║                                                      ║"
  echo -e "║  默认模型: ${DEFAULT_MODEL}             ║"
  echo -e "║  API 端点: api.deepseek.com                          ║"
  echo -e "║  配置文件: ~/.openclaw/openclaw.json                  ║"
  echo "║                                                      ║"
  echo "║  可用模型:                                            ║"
  echo "║  • deepseek/deepseek-chat    (DeepSeek V3, 通用)     ║"
  echo "║  • deepseek/deepseek-reasoner (DeepSeek R1, 推理)    ║"
  echo "║                                                      ║"
  echo "║  下一步:                                              ║"
  echo "║  1. 重启 Gateway:  openclaw gateway restart           ║"
  echo "║  2. 打开控制台:    openclaw dashboard                 ║"
  echo "║  3. 切换模型:      在聊天中输入 /model                ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ─────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────
main() {
  show_banner
  check_prerequisites
  get_api_key
  select_model
  write_config
  verify
}

main "$@"
