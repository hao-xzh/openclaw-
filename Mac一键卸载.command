#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════╗
# ║  🗑️  OpenClaw 一键卸载脚本 (macOS / Linux)           ║
# ║  卸载 OpenClaw 及相关环境                             ║
# ╚══════════════════════════════════════════════════════╝

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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_ok()   { echo -e "  ${GREEN}✅ $1${NC}"; }
log_fail() { echo -e "  ${RED}❌ $1${NC}"; }
log_warn() { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }

echo ""
echo -e "${RED}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║  🗑️  OpenClaw 一键卸载脚本                           ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${YELLOW}${BOLD}即将卸载以下内容:${NC}"
echo ""
echo "  1. OpenClaw CLI 和 Gateway 服务"
echo "  2. OpenClaw 配置和数据 (~/.openclaw)"
echo "  3. npm 全局环境 (~/.npm-global) [如果由安装脚本创建]"
echo ""

# 检查是否要卸载 Node.js
UNINSTALL_NODE=false
UNINSTALL_GIT=false

read -rp "是否同时卸载 Node.js？(y/N) " ans
[[ "${ans,,}" == "y" ]] && UNINSTALL_NODE=true

read -rp "是否同时卸载 Git？(y/N) " ans
[[ "${ans,,}" == "y" ]] && UNINSTALL_GIT=true

echo ""
echo -e "${RED}${BOLD}⚠️  此操作不可逆！${NC}"
read -rp "确认卸载？(输入 YES 确认) " confirm
if [[ "$confirm" != "YES" ]]; then
  echo "已取消。"
  exit 0
fi

echo ""
log_info "开始卸载..."

# ─────────────────────────────────────────────
# 1. 停止 Gateway 服务
# ─────────────────────────────────────────────
log_info "停止 OpenClaw Gateway..."

if command -v openclaw &>/dev/null; then
  log_info "调用官方卸载命令..."
  openclaw uninstall --all --yes --non-interactive 2>/dev/null || true
  log_ok "官方卸载命令已执行"

  openclaw gateway stop 2>/dev/null || true
  openclaw gateway uninstall 2>/dev/null || true
  log_ok "Gateway 已停止"
else
  log_warn "openclaw 命令不存在，尝试手动清理服务..."
fi

# macOS launchd
if [[ "$(uname)" == "Darwin" ]]; then
  launchctl bootout "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || true
  rm -f ~/Library/LaunchAgents/ai.openclaw.gateway.plist 2>/dev/null || true
  # 兼容旧版
  launchctl bootout "gui/$(id -u)/com.openclaw.gateway" 2>/dev/null || true
  rm -f ~/Library/LaunchAgents/com.openclaw.* 2>/dev/null || true
  log_ok "macOS 服务已清理"
fi

# Linux systemd
if command -v systemctl &>/dev/null; then
  systemctl --user disable --now openclaw-gateway.service 2>/dev/null || true
  rm -f ~/.config/systemd/user/openclaw-gateway.service 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  log_ok "Linux 服务已清理"
fi

# ─────────────────────────────────────────────
# 2. 卸载 OpenClaw CLI
# ─────────────────────────────────────────────
log_info "卸载 OpenClaw CLI..."

if command -v npm &>/dev/null; then
  npm rm -g openclaw 2>/dev/null || true
  log_ok "npm 全局包已移除"
fi

if command -v pnpm &>/dev/null; then
  pnpm remove -g openclaw 2>/dev/null || true
fi

# 源码安装的情况
if [[ -d "$HOME/openclaw" ]]; then
  log_info "发现源码目录 ~/openclaw"
  read -rp "  是否删除源码目录？(y/N) " ans
  if [[ "${ans,,}" == "y" ]]; then
    rm -rf "$HOME/openclaw"
    log_ok "源码目录已删除"
  fi
fi

# ─────────────────────────────────────────────
# 3. 删除配置和数据
# ─────────────────────────────────────────────
log_info "删除 OpenClaw 配置和数据..."

rm -rf ~/.openclaw 2>/dev/null || true
log_ok "~/.openclaw 已删除"

# 清理可能的 profile 目录
for d in ~/.openclaw-*; do
  if [[ -d "$d" ]]; then
    rm -rf "$d"
    log_ok "$d 已删除"
  fi
done

# macOS App
if [[ -d "/Applications/OpenClaw.app" ]]; then
  rm -rf "/Applications/OpenClaw.app"
  log_ok "OpenClaw.app 已删除"
fi

# ─────────────────────────────────────────────
# 4. 清理 npm 全局目录（安装脚本创建的）
# ─────────────────────────────────────────────
if [[ -d "$HOME/.npm-global" ]]; then
  log_info "删除安装脚本创建的 npm 全局目录..."
  rm -rf "$HOME/.npm-global"
  npm config delete prefix 2>/dev/null || true
  log_ok "~/.npm-global 已删除"
fi

# ─────────────────────────────────────────────
# 5. 卸载 Node.js（可选）
# ─────────────────────────────────────────────
if $UNINSTALL_NODE; then
  log_info "卸载 Node.js..."
  if [[ "$(uname)" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      brew uninstall node 2>/dev/null || true
      brew uninstall node@22 2>/dev/null || true
      log_ok "Node.js 已通过 Homebrew 卸载"
    fi
    # 手动安装的
    sudo rm -rf /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx 2>/dev/null || true
    sudo rm -rf /usr/local/lib/node_modules 2>/dev/null || true
  else
    # Linux
    if command -v apt-get &>/dev/null; then
      sudo apt-get remove -y nodejs 2>/dev/null || true
      sudo apt-get autoremove -y 2>/dev/null || true
      log_ok "Node.js 已通过 apt 卸载"
    elif command -v dnf &>/dev/null; then
      sudo dnf remove -y nodejs 2>/dev/null || true
      log_ok "Node.js 已通过 dnf 卸载"
    fi
    rm -rf "$HOME/.local/bin/node" "$HOME/.local/bin/npm" "$HOME/.local/bin/npx" 2>/dev/null || true
  fi
  # 清理 npm 缓存
  rm -rf "$HOME/.npm" 2>/dev/null || true
  log_ok "npm 缓存已清理"
fi

# ─────────────────────────────────────────────
# 6. 卸载 Git（可选）
# ─────────────────────────────────────────────
if $UNINSTALL_GIT; then
  log_info "卸载 Git..."
  if [[ "$(uname)" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      brew uninstall git 2>/dev/null || true
      log_ok "Git 已通过 Homebrew 卸载"
    fi
  else
    if command -v apt-get &>/dev/null; then
      sudo apt-get remove -y git 2>/dev/null || true
      log_ok "Git 已通过 apt 卸载"
    elif command -v dnf &>/dev/null; then
      sudo dnf remove -y git 2>/dev/null || true
      log_ok "Git 已通过 dnf 卸载"
    fi
  fi
fi

# ─────────────────────────────────────────────
# 完成
# ─────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅ 卸载完成！                                      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo "已卸载:"
echo "  • OpenClaw CLI 和 Gateway"
echo "  • OpenClaw 配置 (~/.openclaw)"
$UNINSTALL_NODE && echo "  • Node.js 和 npm"
$UNINSTALL_GIT && echo "  • Git"
echo ""
echo -e "${YELLOW}提示: 请重新打开终端使 PATH 变更生效。${NC}"
echo ""
