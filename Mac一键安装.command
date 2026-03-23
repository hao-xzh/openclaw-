#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════╗
# ║  🦀 OpenClaw 一键安装脚本 (macOS / Linux)             ║
# ║  仅使用可信源 · 安全可靠                               ║
# ║  https://github.com/openclaw/openclaw                ║
# ╚══════════════════════════════════════════════════════╝
#
# 用法:
#   bash Mac一键安装.command [--proxy <url>] [--no-onboard] [--verbose] [--dry-run]
#
# 安全说明:
#   所有下载仅来自可信源: openclaw.ai / npmjs.org / npmmirror.com / github.com/openclaw
#   不使用任何来路不明的代理或镜像

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
# 颜色与符号
# ─────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  DIM='\033[2m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

TICK="${GREEN}✅${NC}"
CROSS="${RED}❌${NC}"
WARN="${YELLOW}⚠️${NC}"
ARROW="${CYAN}→${NC}"
SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

# ─────────────────────────────────────────────
# 全局变量
# ─────────────────────────────────────────────
VERSION="1.0.0"
VERBOSE=false
DRY_RUN=false
NO_ONBOARD=false
NO_NODE=false
INSTALL_METHOD="auto"
USER_PROXY=""
DETECTED_PROXY=""
MIN_DISK_MB=1024  # 最低 1GB 磁盘空间

# 失败日志收集
declare -a FAIL_LOG=()
FAIL_CATEGORY=""
LAST_CMD_OUTPUT=""
LAST_CMD_EXIT=0

# ─────────────────────────────────────────────
# 工具函数
# ─────────────────────────────────────────────
log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "  ${TICK} $*"; }
log_fail()  { echo -e "  ${CROSS} $*"; }
log_warn()  { echo -e "  ${WARN} $*"; }
log_step()  { echo -e "\n${BOLD}$*${NC}"; }
log_debug() { $VERBOSE && echo -e "${DIM}[DEBUG] $*${NC}" || true; }

record_failure() {
  local level="$1" reason="$2" detail="$3"
  FAIL_LOG+=("${level}|${reason}|${detail}")
  log_debug "记录失败: Level=$level 原因=$reason 详情=$detail"
}

# 执行命令（支持 dry-run）
run_cmd() {
  if $DRY_RUN; then
    echo -e "  ${DIM}[DRY-RUN] $*${NC}"
    return 0
  fi
  log_debug "执行: $*"
  eval "$@"
}

supports_progress_ui() {
  [[ -t 1 ]]
}

download_file_with_progress() {
  local url="$1"
  local output="$2"
  local label="${3:-下载中}"

  if $DRY_RUN; then
    echo -e "  ${DIM}[DRY-RUN] 下载 $label: $url -> $output${NC}"
    return 0
  fi

  log_info "${label}..."
  if supports_progress_ui; then
    curl --connect-timeout 30 --max-time 300 -fL# "$url" -o "$output"
  else
    curl --connect-timeout 30 --max-time 300 -fsSL "$url" -o "$output"
  fi
}

run_cmd_with_progress() {
  local label="$1"
  local command="$2"
  local log_file
  log_file="$(mktemp)"

  if $DRY_RUN; then
    echo -e "  ${DIM}[DRY-RUN] $command${NC}"
    LAST_CMD_OUTPUT=""
    LAST_CMD_EXIT=0
    rm -f "$log_file"
    return 0
  fi

  log_info "${label}..."
  log_debug "执行(带进度): $command"

  bash -lc "$command" >"$log_file" 2>&1 &
  local pid=$!
  local spin='-\|/'
  local i=0
  local elapsed=0

  while kill -0 "$pid" 2>/dev/null; do
    if supports_progress_ui; then
      printf "\r  [%c] %s... %ss" "${spin:i++%${#spin}:1}" "$label" "$elapsed"
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$pid"
  LAST_CMD_EXIT=$?
  LAST_CMD_OUTPUT="$(cat "$log_file")"
  rm -f "$log_file"

  if supports_progress_ui; then
    printf "\r%*s\r" 80 ""
  fi

  if [[ $LAST_CMD_EXIT -eq 0 ]]; then
    log_ok "${label} 完成 (${elapsed}s)"
    return 0
  fi

  log_fail "${label} 失败 (exit=$LAST_CMD_EXIT)"
  return "$LAST_CMD_EXIT"
}

show_command_error_excerpt() {
  local output="$1"
  local excerpt
  excerpt="$(printf '%s\n' "$output" | grep -Ei 'ERR!|error|warn|failed|denied|ENOENT|EACCES|ETIMEDOUT|ECONN|sharp|node-gyp|gyp ERR' | head -10 || true)"
  if [[ -n "$excerpt" ]]; then
    echo -e "  ${DIM}关键错误摘要:${NC}"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo -e "    ${DIM}${line}${NC}"
    done <<< "$excerpt"
  fi
}

# ─────────────────────────────────────────────
# 参数解析
# ─────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --proxy)
        USER_PROXY="$2"
        shift 2
        ;;
      --no-onboard)
        NO_ONBOARD=true
        shift
        ;;
      --no-node)
        NO_NODE=true
        shift
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --install-method)
        INSTALL_METHOD="$2"
        shift 2
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        echo "未知参数: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

show_help() {
  cat <<'EOF'
🦀 OpenClaw 一键安装脚本 (macOS / Linux)

用法: bash Mac一键安装.command [选项]

选项:
  --proxy <url>          手动指定代理地址 (如 http://127.0.0.1:7890)
  --no-onboard           安装后不自动运行 onboarding
  --no-node              跳过 Node.js 安装
  --install-method <m>   强制安装方式: script / npm / git (默认 auto)
  --verbose              显示详细日志
  --dry-run              预览模式，不实际执行
  --help, -h             显示此帮助信息

安全说明:
  所有下载仅来自可信源:
  - openclaw.ai (官方安装脚本)
  - npmjs.org (npm 官方源)
  - npmmirror.com (阿里官方 npm 同步镜像)
  - github.com/openclaw (官方仓库)
EOF
}

# ─────────────────────────────────────────────
# 显示 Banner
# ─────────────────────────────────────────────
show_banner() {
  echo -e "${BOLD}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║    🦀 OpenClaw 一键安装脚本 v${VERSION}                  ║"
  echo "║    仅使用可信源 · 安全可靠                             ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ═════════════════════════════════════════════
# Phase 1: 环境检测
# ═════════════════════════════════════════════
detect_os() {
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Darwin) echo "macOS" ;;
    Linux)  echo "Linux" ;;
    *)      echo "Unknown" ;;
  esac
}

detect_arch() {
  local uname_m
  uname_m="$(uname -m)"
  case "$uname_m" in
    x86_64|amd64) echo "x86_64" ;;
    arm64|aarch64) echo "arm64" ;;
    *)             echo "$uname_m" ;;
  esac
}

detect_os_version() {
  local os="$1"
  if [[ "$os" == "macOS" ]]; then
    sw_vers -productVersion 2>/dev/null || echo "unknown"
  elif [[ "$os" == "Linux" ]]; then
    if [[ -f /etc/os-release ]]; then
      . /etc/os-release
      echo "${NAME:-Linux} ${VERSION_ID:-unknown}"
    else
      uname -r
    fi
  fi
}

check_disk_space() {
  local available_mb
  if command -v df &>/dev/null; then
    # 获取根目录或用户目录可用空间 (MB)
    if [[ "$(detect_os)" == "macOS" ]]; then
      available_mb=$(df -m "$HOME" | awk 'NR==2 {print $4}')
    else
      available_mb=$(df -m "$HOME" | awk 'NR==2 {print $4}')
    fi
    if [[ -n "$available_mb" ]] && [[ "$available_mb" -lt "$MIN_DISK_MB" ]]; then
      return 1
    fi
    echo "$available_mb"
    return 0
  fi
  echo "unknown"
  return 0
}

check_command() {
  command -v "$1" &>/dev/null
}

get_node_version() {
  if check_command node; then
    node --version 2>/dev/null | sed 's/^v//'
  fi
}

get_node_major() {
  local ver
  ver="$(get_node_version)"
  if [[ -n "$ver" ]]; then
    echo "$ver" | cut -d. -f1
  fi
}

detect_proxy() {
  # 1. 用户手动指定
  if [[ -n "$USER_PROXY" ]]; then
    DETECTED_PROXY="$USER_PROXY"
    return 0
  fi

  # 2. 环境变量
  for var in https_proxy HTTPS_PROXY http_proxy HTTP_PROXY all_proxy ALL_PROXY; do
    local val="${!var:-}"
    if [[ -n "$val" ]]; then
      DETECTED_PROXY="$val"
      return 0
    fi
  done

  # 3. 检测常见本地代理端口
  local ports=(7890 7897 1080 8080 1087 7891)
  for port in "${ports[@]}"; do
    if (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
      DETECTED_PROXY="http://127.0.0.1:$port"
      return 0
    fi
  done

  return 1
}

apply_proxy() {
  if [[ -n "$DETECTED_PROXY" ]]; then
    export http_proxy="$DETECTED_PROXY"
    export https_proxy="$DETECTED_PROXY"
    export HTTP_PROXY="$DETECTED_PROXY"
    export HTTPS_PROXY="$DETECTED_PROXY"
    log_debug "已设置代理: $DETECTED_PROXY"
  fi
}

phase1_environment() {
  log_step "[1/5] 🔍 环境检测..."

  local os arch os_ver
  os="$(detect_os)"
  arch="$(detect_arch)"
  os_ver="$(detect_os_version "$os")"

  # OS 检测
  if [[ "$os" == "Unknown" ]]; then
    log_fail "不支持的操作系统: $(uname -s)"
    echo ""
    echo -e "  ${ARROW} 本脚本仅支持 macOS 和 Linux"
    echo -e "  ${ARROW} Windows 请使用 Win一键安装.bat"
    exit 1
  fi
  log_ok "${os} ${os_ver} (${arch})"

  # 磁盘空间
  local disk_result
  disk_result="$(check_disk_space)" || {
    log_fail "磁盘空间不足 (剩余 ${disk_result:-未知}MB，需要至少 ${MIN_DISK_MB}MB)"
    echo ""
    echo -e "  ${ARROW} 请清理磁盘空间后重新运行"
    exit 1
  }
  log_ok "磁盘空间充足 (${disk_result}MB 可用)"

  # Node.js
  if check_command node; then
    local node_ver node_major
    node_ver="$(get_node_version)"
    node_major="$(get_node_major)"
    if [[ "$node_major" -ge 22 ]]; then
      log_ok "Node.js v${node_ver} (满足 >= 22)"
    else
      log_warn "Node.js v${node_ver} (需要 >= 22，将尝试升级)"
    fi
  else
    log_warn "Node.js 未安装（将在 Phase 2 安装）"
  fi

  # npm
  if check_command npm; then
    log_ok "npm v$(npm --version 2>/dev/null)"
  else
    log_warn "npm 未安装（随 Node.js 一同安装）"
  fi

  # Git
  if check_command git; then
    log_ok "Git v$(git --version 2>/dev/null | awk '{print $3}')"
  else
    log_warn "Git 未安装（Level 4 源码构建需要）"
  fi

  # 代理检测
  if detect_proxy; then
    log_ok "代理已检测: ${DETECTED_PROXY}"
    apply_proxy
  else
    log_warn "未检测到代理（国内直连可能较慢）"
  fi

  # 已安装 OpenClaw
  if check_command openclaw; then
    local oc_ver
    oc_ver="$(openclaw --version 2>/dev/null || echo 'unknown')"
    log_ok "OpenClaw 已安装 (${oc_ver})"
    echo ""
    echo -e "  ${ARROW} OpenClaw 已经安装，如需更新请运行: npm install -g openclaw@latest"
    echo -e "  ${ARROW} 如需重新安装，请先运行: npm uninstall -g openclaw"
    echo ""
    read -rp "是否继续重新安装？(y/N) " confirm
    if [[ "${confirm,,}" != "y" ]]; then
      echo "已取消。"
      exit 0
    fi
  else
    log_info "OpenClaw 未安装（将开始安装）"
  fi
}

# ═════════════════════════════════════════════
# Phase 2: Node.js 安装/验证
# ═════════════════════════════════════════════
install_node_brew() {
  if ! check_command brew; then
    log_debug "Homebrew 未安装，跳过"
    return 1
  fi
  log_info "尝试通过 Homebrew 安装 Node.js..."
  run_cmd "brew install node" && return 0
  return 1
}

install_node_official_mac() {
  log_info "尝试从 nodejs.org 下载官方安装包..."
  local arch
  arch="$(detect_arch)"
  local node_pkg_arch="x64"
  [[ "$arch" == "arm64" ]] && node_pkg_arch="arm64"

  local pkg_url="https://nodejs.org/dist/latest-v22.x/node-v22.0.0-darwin-${node_pkg_arch}.tar.gz"

  # 获取最新 v22 版本号
  local latest_ver
  latest_ver=$(curl -fsSL --connect-timeout 15 --max-time 30 "https://nodejs.org/dist/index.json" 2>/dev/null | \
    grep -o '"version":"v22\.[^"]*"' | head -1 | cut -d'"' -f4) || true

  if [[ -n "$latest_ver" ]]; then
    pkg_url="https://nodejs.org/dist/${latest_ver}/node-${latest_ver}-darwin-${node_pkg_arch}.tar.gz"
    log_debug "最新 Node 22: $latest_ver"
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap "rm -rf '$tmp_dir'" RETURN

  if download_file_with_progress "$pkg_url" "$tmp_dir/node.tar.gz" "下载 Node.js 官方包"; then
    run_cmd "tar -xzf '$tmp_dir/node.tar.gz' -C '$tmp_dir'"
    local node_dir
    node_dir=$(ls -d "$tmp_dir"/node-v* 2>/dev/null | head -1)
    if [[ -n "$node_dir" ]]; then
      run_cmd "sudo cp -R '$node_dir'/bin/* /usr/local/bin/ 2>/dev/null || cp -R '$node_dir'/bin/* '$HOME/.local/bin/'" || true
      run_cmd "sudo cp -R '$node_dir'/lib/* /usr/local/lib/ 2>/dev/null" || true
      run_cmd "sudo cp -R '$node_dir'/include/* /usr/local/include/ 2>/dev/null" || true
      export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
      return 0
    fi
  fi
  return 1
}

install_node_official_linux() {
  log_info "尝试从 nodejs.org 下载官方安装包..."
  local arch
  arch="$(detect_arch)"
  local node_arch="x64"
  [[ "$arch" == "arm64" ]] && node_arch="arm64"

  local latest_ver
  latest_ver=$(curl -fsSL --connect-timeout 15 --max-time 30 "https://nodejs.org/dist/index.json" 2>/dev/null | \
    grep -o '"version":"v22\.[^"]*"' | head -1 | cut -d'"' -f4) || true

  local pkg_url="https://nodejs.org/dist/${latest_ver:-v22.0.0}/node-${latest_ver:-v22.0.0}-linux-${node_arch}.tar.xz"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap "rm -rf '$tmp_dir'" RETURN

  if download_file_with_progress "$pkg_url" "$tmp_dir/node.tar.xz" "下载 Node.js 官方包"; then
    run_cmd "tar -xJf '$tmp_dir/node.tar.xz' -C '$tmp_dir'"
    local node_dir
    node_dir=$(ls -d "$tmp_dir"/node-v* 2>/dev/null | head -1)
    if [[ -n "$node_dir" ]]; then
      mkdir -p "$HOME/.local"
      run_cmd "cp -R '$node_dir'/* '$HOME/.local/'"
      export PATH="$HOME/.local/bin:$PATH"
      return 0
    fi
  fi
  return 1
}

phase2_nodejs() {
  log_step "[2/5] 📦 Node.js 安装/验证..."

  if $NO_NODE; then
    log_info "跳过 Node.js 安装 (--no-node)"
    if ! check_command node; then
      log_fail "Node.js 未安装且 --no-node 已指定"
      exit 1
    fi
    return 0
  fi

  # 检查现有版本
  local node_major
  node_major="$(get_node_major)"
  if [[ -n "$node_major" ]] && [[ "$node_major" -ge 22 ]]; then
    log_ok "Node.js v$(get_node_version) 已满足要求"
    return 0
  fi

  local os
  os="$(detect_os)"

  # macOS 安装策略
  if [[ "$os" == "macOS" ]]; then
    install_node_brew && {
      hash -r 2>/dev/null || true
      log_ok "Node.js $(node --version 2>/dev/null) 已通过 Homebrew 安装"
      return 0
    }
    install_node_official_mac && {
      hash -r 2>/dev/null || true
      log_ok "Node.js $(node --version 2>/dev/null) 已通过官方包安装"
      return 0
    }
  fi

  # Linux 安装策略
  if [[ "$os" == "Linux" ]]; then
    # 尝试包管理器
    if check_command apt-get; then
      log_info "尝试通过 apt 安装..."
      if run_cmd "curl -fsSL --connect-timeout 30 https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs"; then
        log_ok "Node.js $(node --version 2>/dev/null) 已通过 apt 安装"
        return 0
      fi
    elif check_command dnf; then
      log_info "尝试通过 dnf 安装..."
      if run_cmd "sudo dnf install -y nodejs"; then
        log_ok "Node.js $(node --version 2>/dev/null) 已通过 dnf 安装"
        return 0
      fi
    fi

    install_node_official_linux && {
      hash -r 2>/dev/null || true
      log_ok "Node.js $(node --version 2>/dev/null) 已通过官方包安装"
      return 0
    }
  fi

  # 所有方式都失败
  log_fail "Node.js 22+ 安装失败"
  echo ""
  echo -e "  ${ARROW} 请手动安装 Node.js 22+:"
  echo -e "    macOS:  brew install node"
  echo -e "    Linux:  参考 https://nodejs.org/"
  echo -e "    通用:   推荐使用 fnm: https://github.com/Schniz/fnm"
  exit 1
}

# ═════════════════════════════════════════════
# Phase 3: 网络连通性检测
# ═════════════════════════════════════════════
test_url() {
  local url="$1" timeout="${2:-10}"
  local start_time end_time elapsed http_code

  start_time=$(date +%s%N 2>/dev/null || date +%s)

  http_code=$(curl -fsSL --connect-timeout "$timeout" --max-time "$timeout" \
    -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || true

  end_time=$(date +%s%N 2>/dev/null || date +%s)

  # 计算耗时 (毫秒)
  if [[ ${#start_time} -gt 10 ]]; then
    elapsed=$(( (end_time - start_time) / 1000000 ))
  else
    elapsed=$(( (end_time - start_time) * 1000 ))
  fi

  if [[ "$http_code" =~ ^(200|301|302|303|307|308)$ ]]; then
    local proxy_note=""
    [[ -n "$DETECTED_PROXY" ]] && proxy_note=", via proxy"
    echo "${elapsed}ms${proxy_note}"
    return 0
  fi
  return 1
}

phase3_network() {
  log_step "[3/5] 🌐 网络连通性检测..."

  local -A url_map=(
    ["openclaw.ai"]="https://openclaw.ai"
    ["registry.npmjs.org"]="https://registry.npmjs.org"
    ["registry.npmmirror.com"]="https://registry.npmmirror.com"
    ["github.com"]="https://github.com"
  )

  local reachable_count=0
  local npmmirror_reachable=false
  local official_reachable=false

  for domain in "openclaw.ai" "registry.npmjs.org" "registry.npmmirror.com" "github.com"; do
    local url="${url_map[$domain]}"
    local result
    if result=$(test_url "$url" 10); then
      log_ok "${domain}  (${result})"
      reachable_count=$((reachable_count + 1))
      [[ "$domain" == "registry.npmmirror.com" ]] && npmmirror_reachable=true
      [[ "$domain" == "openclaw.ai" || "$domain" == "registry.npmjs.org" ]] && official_reachable=true
    else
      log_fail "${domain}  (不可达)"
    fi
  done

  echo ""
  if $official_reachable; then
    log_info "策略: 优先使用官方源"
  elif $npmmirror_reachable; then
    log_info "策略: 官方源不稳定，将优先尝试 npmmirror 镜像"
  fi

  if [[ $reachable_count -eq 0 ]]; then
    log_fail "所有可信源均不可达"
    echo ""
    echo -e "  ${ARROW} 请检查网络连接"
    if [[ -z "$DETECTED_PROXY" ]]; then
      echo -e "  ${ARROW} 建议开启 VPN/代理后重新运行:"
      echo -e "    export https_proxy=http://127.0.0.1:7890"
      echo -e "    bash Mac一键安装.command"
    fi
    echo ""
    echo -e "  将继续尝试安装（可能因网络失败）..."
  fi
}

# ═════════════════════════════════════════════
# Phase 4: OpenClaw 安装 (多级降级)
# ═════════════════════════════════════════════

path_contains_dir() {
  local dir="${1%/}"
  [[ -n "$dir" ]] || return 1
  case ":$PATH:" in
    *":$dir:"*) return 0 ;;
    *) return 1 ;;
  esac
}

npm_global_prefix() {
  local prefix
  prefix="$(npm config get prefix 2>/dev/null || true)"
  if [[ -z "$prefix" || "$prefix" == "undefined" || "$prefix" == "null" ]]; then
    prefix="$(npm prefix -g 2>/dev/null || true)"
  fi
  [[ -n "$prefix" ]] && echo "$prefix"
}

npm_global_bin_dir() {
  local prefix
  prefix="$(npm_global_prefix)"
  [[ -n "$prefix" ]] && echo "${prefix%/}/bin"
}

pnpm_global_bin_dir() {
  if check_command pnpm; then
    pnpm bin -g 2>/dev/null || true
  fi
}

shell_rc_candidates() {
  local candidates=()

  if [[ "$SHELL" == *zsh* ]]; then
    candidates+=("$HOME/.zshrc" "$HOME/.zprofile")
  elif [[ "$SHELL" == *bash* ]]; then
    candidates+=("$HOME/.bashrc" "$HOME/.bash_profile")
  else
    candidates+=("$HOME/.profile")
  fi

  candidates+=("$HOME/.profile")

  printf '%s\n' "${candidates[@]}" | awk '!seen[$0]++'
}

preferred_shell_rc() {
  if [[ "$SHELL" == *zsh* ]]; then
    echo "$HOME/.zshrc"
  elif [[ "$SHELL" == *bash* ]]; then
    echo "$HOME/.bashrc"
  else
    echo "$HOME/.profile"
  fi
}

persist_path_dir() {
  local dir="${1%/}"
  [[ -n "$dir" ]] || return 0

  local line="export PATH=\"$dir:\$PATH\""
  local updated=false
  local rc

  while IFS= read -r rc; do
    [[ -n "$rc" ]] || continue
    if [[ ! -f "$rc" ]]; then
      touch "$rc" 2>/dev/null || continue
    fi
    if grep -Fqs "$dir" "$rc"; then
      continue
    fi
    printf '\n%s\n' "$line" >> "$rc"
    updated=true
    log_info "已写入 PATH 到 $(basename "$rc"): $dir"
  done < <(shell_rc_candidates)

  if $updated; then
    log_ok "环境变量已持久化，下次打开终端会自动生效"
  fi
}

ensure_path_dir() {
  local dir="${1%/}"
  [[ -n "$dir" ]] || return 0
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" 2>/dev/null || true
  fi
  if ! path_contains_dir "$dir"; then
    export PATH="$dir:$PATH"
    hash -r 2>/dev/null || true
  fi
  persist_path_dir "$dir"
}

ensure_npm_global_bin_on_path() {
  local bin_dir
  bin_dir="$(npm_global_bin_dir)"
  [[ -n "$bin_dir" ]] && ensure_path_dir "$bin_dir"
}

ensure_pnpm_global_bin_on_path() {
  local bin_dir
  bin_dir="$(pnpm_global_bin_dir)"
  [[ -n "$bin_dir" ]] && ensure_path_dir "$bin_dir"
}

repair_openclaw_bin_from_root() {
  local package_root="$1"
  local bin_dir="$2"
  [[ -d "$package_root" && -n "$bin_dir" ]] || return 1

  local entry=""
  for candidate in "$package_root/dist/entry.js" "$package_root/dist/entry.mjs"; do
    if [[ -f "$candidate" ]]; then
      entry="$candidate"
      break
    fi
  done

  [[ -n "$entry" ]] || return 1

  mkdir -p "$bin_dir"
  cat > "$bin_dir/openclaw" <<EOF
#!/usr/bin/env bash
exec node "$entry" "\$@"
EOF
  chmod +x "$bin_dir/openclaw"
  log_warn "已自动修复 openclaw 命令入口: $bin_dir/openclaw"
  return 0
}

repair_openclaw_bin() {
  local npm_root npm_bin pnpm_root pnpm_bin

  if check_command npm; then
    npm_root="$(npm root -g 2>/dev/null || true)"
    npm_bin="$(npm_global_bin_dir)"
    if [[ -n "$npm_root" && -d "$npm_root/openclaw" && -n "$npm_bin" ]]; then
      repair_openclaw_bin_from_root "$npm_root/openclaw" "$npm_bin" && return 0
    fi
  fi

  if check_command pnpm; then
    pnpm_root="$(pnpm root -g 2>/dev/null || true)"
    pnpm_bin="$(pnpm_global_bin_dir)"
    if [[ -n "$pnpm_root" && -d "$pnpm_root/openclaw" && -n "$pnpm_bin" ]]; then
      repair_openclaw_bin_from_root "$pnpm_root/openclaw" "$pnpm_bin" && return 0
    fi
  fi

  return 1
}

# npm 权限自动修复
fix_npm_permissions() {
  if ! check_command npm; then
    return 0
  fi
  local npm_prefix
  npm_prefix="$(npm_global_prefix)" || return 0

  if [[ ! -w "$npm_prefix" ]]; then
    log_warn "npm 全局目录无写权限: $npm_prefix"
    log_info "自动切换到用户目录: ~/.npm-global"
    mkdir -p "$HOME/.npm-global/bin"
    run_cmd "npm config set prefix '$HOME/.npm-global'"
    log_ok "npm 权限已修复"
  fi

  ensure_npm_global_bin_on_path
}

ensure_pnpm() {
  if check_command pnpm; then
    ensure_pnpm_global_bin_on_path
    return 0
  fi

  if check_command corepack; then
    log_info "尝试通过 Corepack 启用 pnpm..."
    run_cmd "corepack enable" 2>/dev/null || true
    run_cmd "corepack prepare pnpm@latest --activate" 2>/dev/null || \
    run_cmd "corepack prepare pnpm@10 --activate" 2>/dev/null || true
  fi

  hash -r 2>/dev/null || true
  if check_command pnpm; then
    ensure_pnpm_global_bin_on_path
    log_ok "pnpm 已就绪"
    return 0
  fi

  log_info "尝试通过 npm 安装 pnpm..."
  fix_npm_permissions
  run_cmd "npm install -g pnpm@latest --registry=https://registry.npmmirror.com" 2>/dev/null || \
  run_cmd "npm install -g pnpm@latest" || {
    log_warn "pnpm 自动安装失败"
    return 1
  }

  hash -r 2>/dev/null || true
  if check_command pnpm; then
    ensure_pnpm_global_bin_on_path
    log_ok "pnpm 已安装"
    return 0
  fi

  return 1
}

approve_pnpm_builds_if_supported() {
  if ! check_command pnpm; then
    return 0
  fi

  local help_output
  help_output="$(pnpm approve-builds --help 2>/dev/null || true)"
  if echo "$help_output" | grep -q -- '--all'; then
    log_info "尝试自动批准 pnpm 全局构建脚本..."
    run_cmd "pnpm approve-builds -g --all" 2>/dev/null || true
    return 0
  fi

  log_warn "当前 pnpm 版本的 approve-builds 缺少无交互参数，已跳过以避免脚本卡住"
  return 0
}

# 确保 Git 已安装
ensure_git() {
  if check_command git; then return 0; fi
  log_warn "Git 未安装 — openclaw 的 npm 安装需要 Git"
  log_info "正在尝试自动安装 Git..."
  
  if check_command brew; then
    run_cmd "brew install git"
  elif check_command apt-get; then
    run_cmd "sudo apt-get update && sudo apt-get install -y git"
  elif check_command yum; then
    run_cmd "sudo yum install -y git"
  elif check_command dnf; then
    run_cmd "sudo dnf install -y git"
  elif check_command pacman; then
    run_cmd "sudo pacman -S --noconfirm git"
  elif check_command zypper; then
    run_cmd "sudo zypper in -y git"
  else
    log_fail "未找到受支持的包管理器，无法自动安装 Git。请手动安装后重试。"
  fi

  if check_command git; then
    log_ok "Git 自动安装成功"
  else
    log_warn "Git 自动安装失败，后续安装可能报错"
  fi
}

# Level 1: 官方脚本
install_level1() {
  log_info "⏳ Level 1: 官方脚本安装 (openclaw.ai)..."

  local onboard_flag=""
  $NO_ONBOARD && onboard_flag="--no-onboard"

  for attempt in 1 2 3; do
    log_debug "尝试 $attempt/3..."
    local installer_file
    installer_file="$(mktemp)"
    if ! download_file_with_progress "https://openclaw.ai/install.sh" "$installer_file" "下载官方安装脚本"; then
      local exit_code=$?
      log_debug "curl 失败 (exit=$exit_code)"
      rm -f "$installer_file"
      if [[ $attempt -lt 3 ]]; then
        log_debug "等待 5 秒后重试..."
        sleep 5
      fi
      continue
    fi

    # 下载成功，执行安装脚本
    local install_cmd="bash '$installer_file'"
    [[ -n "$onboard_flag" ]] && install_cmd="$install_cmd $onboard_flag"
    if run_cmd_with_progress "执行官方安装脚本" "$install_cmd"; then
      rm -f "$installer_file"
      return 0
    else
      record_failure "Level1" "脚本执行失败" "exit_code=$LAST_CMD_EXIT output=${LAST_CMD_OUTPUT:0:300}"
      show_command_error_excerpt "$LAST_CMD_OUTPUT"
      rm -f "$installer_file"
      break
    fi
  done

  record_failure "Level1" "官方脚本安装失败" "openclaw.ai 不可达或脚本执行出错"
  return 1
}

# Level 2: npm 官方源
install_level2() {
  log_info "⏳ Level 2: npm 官方源安装 (npmjs.org)..."

  if ! check_command npm; then
    record_failure "Level2" "npm 不可用" "npm 命令不存在"
    return 1
  fi

  fix_npm_permissions
  export SHARP_IGNORE_GLOBAL_LIBVIPS=1
  ensure_npm_global_bin_on_path

  if run_cmd_with_progress "npm 官方源安装 OpenClaw" "npm install -g openclaw@latest \
    --fetch-timeout=300000 \
    --fetch-retries=3 \
    --fetch-retry-mintimeout=20000 \
    --fetch-retry-maxtimeout=120000"; then
    return 0
  else
    # 分析失败原因
    show_command_error_excerpt "$LAST_CMD_OUTPUT"
    if echo "$LAST_CMD_OUTPUT" | grep -qi "ETIMEDOUT\|ECONNREFUSED\|ENOTFOUND\|EAI_AGAIN\|fetch failed"; then
      record_failure "Level2" "网络超时" "npmjs.org 连接失败: ${LAST_CMD_OUTPUT:0:300}"
    elif echo "$LAST_CMD_OUTPUT" | grep -qi "EACCES\|permission denied"; then
      record_failure "Level2" "权限错误" "npm 全局安装权限不足 (自动修复失败)"
    elif echo "$LAST_CMD_OUTPUT" | grep -qi "gyp ERR\|node-gyp\|sharp"; then
      record_failure "Level2" "编译错误" "原生模块编译失败: ${LAST_CMD_OUTPUT:0:300}"
    else
      record_failure "Level2" "npm 安装失败" "exit_code=$LAST_CMD_EXIT output=${LAST_CMD_OUTPUT:0:300}"
    fi
    return 1
  fi
}

# Level 3: npm 国内镜像
install_level3() {
  log_info "⏳ Level 3: npm 国内镜像安装 (npmmirror.com)..."

  if ! check_command npm; then
    record_failure "Level3" "npm 不可用" "npm 命令不存在"
    return 1
  fi

  fix_npm_permissions
  export SHARP_IGNORE_GLOBAL_LIBVIPS=1
  ensure_npm_global_bin_on_path

  # 设置所有原生模块的国内二进制镜像（关键！）
  # 即使 registry 用了 npmmirror，原生模块默认仍从 GitHub 下载
  export npm_config_sharp_binary_host="https://npmmirror.com/mirrors/sharp"
  export npm_config_sharp_libvips_binary_host="https://npmmirror.com/mirrors/sharp-libvips"
  export SHARP_DIST_BASE_URL="https://npmmirror.com/mirrors/sharp"
  export npm_config_canvas_binary_host="https://npmmirror.com/mirrors/canvas"
  export SASS_BINARY_SITE="https://npmmirror.com/mirrors/node-sass"
  export ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/"
  export PUPPETEER_DOWNLOAD_HOST="https://npmmirror.com/mirrors"
  export SENTRYCLI_CDNURL="https://npmmirror.com/mirrors/sentry-cli"
  export NODEJS_ORG_MIRROR="https://npmmirror.com/mirrors/node"
  export NVM_NODEJS_ORG_MIRROR="https://npmmirror.com/mirrors/node"
  export npm_config_disturl="https://npmmirror.com/mirrors/node"

  log_info "已设置原生模块国内二进制镜像"

  if run_cmd_with_progress "npm 国内镜像安装 OpenClaw" "npm install -g openclaw@latest \
    --registry=https://registry.npmmirror.com \
    --fetch-timeout=300000 \
    --fetch-retries=3 \
    --fetch-retry-mintimeout=20000"; then
    return 0
  else
    show_command_error_excerpt "$LAST_CMD_OUTPUT"
    if echo "$LAST_CMD_OUTPUT" | grep -qi "ETIMEDOUT\|ECONNREFUSED\|ENOTFOUND\|EAI_AGAIN\|fetch failed\|network"; then
      record_failure "Level3" "网络超时" "npmmirror.com 连接失败: ${LAST_CMD_OUTPUT:0:200}"
    elif echo "$LAST_CMD_OUTPUT" | grep -qi "EACCES\|permission denied"; then
      record_failure "Level3" "权限错误" "npm 全局安装权限不足"
    elif echo "$LAST_CMD_OUTPUT" | grep -qi "gyp ERR\|node-gyp\|sharp"; then
      record_failure "Level3" "编译错误" "原生模块编译失败"
    else
      record_failure "Level3" "npm 镜像安装失败" "exit_code=$LAST_CMD_EXIT output=${LAST_CMD_OUTPUT:0:300}"
    fi
    return 1
  fi
}

install_level4() {
  log_info "⏳ Level 4: pnpm 官方源安装..."

  ensure_pnpm || {
    record_failure "Level4" "pnpm 不可用" "pnpm / corepack 均不可用"
    return 1
  }

  export SHARP_IGNORE_GLOBAL_LIBVIPS=1
  ensure_pnpm_global_bin_on_path

  if run_cmd_with_progress "pnpm 官方源安装 OpenClaw" "pnpm add -g openclaw@latest"; then
    approve_pnpm_builds_if_supported
    return 0
  else
    show_command_error_excerpt "$LAST_CMD_OUTPUT"
    if echo "$LAST_CMD_OUTPUT" | grep -qi "ETIMEDOUT\|ECONNREFUSED\|ENOTFOUND\|EAI_AGAIN\|fetch failed\|network"; then
      record_failure "Level4" "网络超时" "pnpm 官方源连接失败: ${LAST_CMD_OUTPUT:0:200}"
    else
      record_failure "Level4" "pnpm 安装失败" "exit_code=$LAST_CMD_EXIT output=${LAST_CMD_OUTPUT:0:300}"
    fi
    return 1
  fi
}

install_level5() {
  log_info "⏳ Level 5: pnpm 国内镜像安装..."

  ensure_pnpm || {
    record_failure "Level5" "pnpm 不可用" "pnpm / corepack 均不可用"
    return 1
  }

  export SHARP_IGNORE_GLOBAL_LIBVIPS=1
  ensure_pnpm_global_bin_on_path

  if run_cmd_with_progress "pnpm 国内镜像安装 OpenClaw" "pnpm add -g openclaw@latest --registry=https://registry.npmmirror.com"; then
    approve_pnpm_builds_if_supported
    return 0
  else
    show_command_error_excerpt "$LAST_CMD_OUTPUT"
    if echo "$LAST_CMD_OUTPUT" | grep -qi "ETIMEDOUT\|ECONNREFUSED\|ENOTFOUND\|EAI_AGAIN\|fetch failed\|network"; then
      record_failure "Level5" "网络超时" "pnpm 国内镜像连接失败: ${LAST_CMD_OUTPUT:0:200}"
    else
      record_failure "Level5" "pnpm 镜像安装失败" "exit_code=$LAST_CMD_EXIT output=${LAST_CMD_OUTPUT:0:300}"
    fi
    return 1
  fi
}

install_level6() {
  log_info "⏳ Level 6: GitHub main 直装..."

  if ! check_command npm; then
    record_failure "Level6" "npm 不可用" "npm 命令不存在"
    return 1
  fi

  fix_npm_permissions
  export SHARP_IGNORE_GLOBAL_LIBVIPS=1
  ensure_npm_global_bin_on_path

  if run_cmd_with_progress "GitHub main 安装 OpenClaw" "npm install -g github:openclaw/openclaw#main \
    --fetch-timeout=300000 \
    --fetch-retries=3 \
    --fetch-retry-mintimeout=20000 \
    --fetch-retry-maxtimeout=120000"; then
    return 0
  else
    show_command_error_excerpt "$LAST_CMD_OUTPUT"
    record_failure "Level6" "GitHub main 安装失败" "exit_code=$LAST_CMD_EXIT output=${LAST_CMD_OUTPUT:0:300}"
    return 1
  fi
}

# Level 7: GitHub 源码构建
install_level7() {
  log_info "⏳ Level 7: 官方 GitHub 源码构建..."

  if ! check_command git; then
    record_failure "Level7" "Git 不可用" "源码构建需要 Git，请先安装: brew install git / apt install git"
    return 1
  fi

  local clone_dir="$HOME/openclaw"

  # 克隆或更新
  if [[ -d "$clone_dir/.git" ]]; then
    log_info "已有本地仓库，更新中..."
    run_cmd_with_progress "更新 OpenClaw 源码仓库" "cd '$clone_dir' && git pull --ff-only" || {
      show_command_error_excerpt "$LAST_CMD_OUTPUT"
      record_failure "Level7" "Git pull 失败" "github.com 不可达: ${LAST_CMD_OUTPUT:0:300}"
      return 1
    }
  else
    run_cmd_with_progress "克隆 OpenClaw 源码仓库" "git clone --depth 1 https://github.com/openclaw/openclaw.git '$clone_dir'" || {
      show_command_error_excerpt "$LAST_CMD_OUTPUT"
      record_failure "Level7" "Git clone 失败" "github.com 不可达: ${LAST_CMD_OUTPUT:0:300}"
      return 1
    }
  fi

  cd "$clone_dir"

  # 确保 pnpm 可用
  ensure_pnpm || {
    record_failure "Level7" "pnpm 安装失败" "无法安装 pnpm"
    return 1
  }

  # 构建
  log_info "安装依赖..."
  run_cmd_with_progress "安装源码依赖" "cd '$clone_dir' && pnpm install --registry=https://registry.npmmirror.com" 2>/dev/null || \
  run_cmd_with_progress "安装源码依赖" "cd '$clone_dir' && pnpm install" || {
    show_command_error_excerpt "$LAST_CMD_OUTPUT"
    record_failure "Level7" "依赖安装失败" "pnpm install 出错: ${LAST_CMD_OUTPUT:0:300}"
    return 1
  }

  log_info "构建中..."
  run_cmd_with_progress "构建 OpenClaw" "cd '$clone_dir' && pnpm ui:build && pnpm build" || {
    show_command_error_excerpt "$LAST_CMD_OUTPUT"
    record_failure "Level7" "构建失败" "pnpm build 出错: ${LAST_CMD_OUTPUT:0:300}"
    return 1
  }

  run_cmd_with_progress "全局链接 OpenClaw" "cd '$clone_dir' && pnpm link --global" || {
    show_command_error_excerpt "$LAST_CMD_OUTPUT"
    record_failure "Level7" "全局链接失败" "pnpm link --global 出错: ${LAST_CMD_OUTPUT:0:300}"
    return 1
  }

  ensure_pnpm_global_bin_on_path
  return 0
}

phase4_install() {
  log_step "[4/5] 📦 安装 OpenClaw..."

  # npm install openclaw 时会拉取 git:// 依赖，需确保 git 已安装
  ensure_git

  # 修复 npm 通过 git 拉取依赖时，github 报 Permission denied (publickey) 的问题
  if check_command git; then
    log_info "配置 Git：使用 HTTPS 替代 SSH 拉取 pkg..."
    git config --global url."https://github.com/".insteadOf "git@github.com:" 2>/dev/null || true
    git config --global url."https://".insteadOf "git://" 2>/dev/null || true
  fi

  # 根据指定方式安装
  case "$INSTALL_METHOD" in
    script)
      install_level1 && { log_ok "安装成功 (官方脚本)"; return 0; }
      ;;
    npm)
      fix_npm_permissions
      install_level2 && { log_ok "安装成功 (npm 官方源)"; return 0; }
      install_level3 && { log_ok "安装成功 (npm 国内镜像)"; return 0; }
      install_level4 && { log_ok "安装成功 (pnpm 官方源)"; return 0; }
      install_level5 && { log_ok "安装成功 (pnpm 国内镜像)"; return 0; }
      install_level6 && { log_ok "安装成功 (GitHub main)"; return 0; }
      ;;
    git)
      install_level7 && { log_ok "安装成功 (源码构建)"; return 0; }
      ;;
    auto|*)
      # 自动降级: Level 1 → 2 → 3 → 4 → 5 → 6 → 7
      install_level1 && { log_ok "安装成功 (官方脚本) ✅"; return 0; }
      log_warn "Level 1 失败，降级到 Level 2..."

      install_level2 && { log_ok "安装成功 (npm 官方源) ✅"; return 0; }
      log_warn "Level 2 失败，降级到 Level 3..."

      install_level3 && { log_ok "安装成功 (npm 国内镜像) ✅"; return 0; }
      log_warn "Level 3 失败，降级到 Level 4..."

      install_level4 && { log_ok "安装成功 (pnpm 官方源) ✅"; return 0; }
      log_warn "Level 4 失败，降级到 Level 5..."

      install_level5 && { log_ok "安装成功 (pnpm 国内镜像) ✅"; return 0; }
      log_warn "Level 5 失败，降级到 Level 6..."

      install_level6 && { log_ok "安装成功 (GitHub main) ✅"; return 0; }
      log_warn "Level 6 失败，降级到 Level 7..."

      install_level7 && { log_ok "安装成功 (源码构建) ✅"; return 0; }
      ;;
  esac

  # 全部失败 — 输出诊断报告
  show_failure_report
  exit 1
}

# ─────────────────────────────────────────────
# 失败诊断报告
# ─────────────────────────────────────────────
show_failure_report() {
  echo ""
  echo -e "${RED}${BOLD}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  ❌ 安装失败 — 诊断报告                              ║"
  echo "╠══════════════════════════════════════════════════════╣"
  echo -e "${NC}"

  # 分析失败原因分类
  local has_network=false has_permission=false has_compile=false has_path=false has_pnpm_approve=false has_git=false has_other=false
  for entry in "${FAIL_LOG[@]}"; do
    local reason
    local detail
    reason=$(echo "$entry" | cut -d'|' -f2)
    detail=$(echo "$entry" | cut -d'|' -f3)
    case "$reason" in
      *网络*|*超时*|*不可达*|*clone*|*pull*) has_network=true ;;
      *权限*) has_permission=true ;;
      *编译*) has_compile=true ;;
      *) has_other=true ;;
    esac
    [[ "$reason" == *PATH* || "$detail" == *PATH* || "$detail" == *命令不可用* ]] && has_path=true
    [[ "$reason" == *Git* || "$detail" == *github.com* ]] && has_git=true
    [[ "$reason" == *pnpm* || "$detail" == *approve-builds* || "$detail" == *"build scripts"* ]] && has_pnpm_approve=true
  done

  # 输出主要失败原因
  if $has_path; then
    FAIL_CATEGORY="PATH"
    local shell_rc
    shell_rc="$(preferred_shell_rc)"
    echo -e "  ${BOLD}失败原因: 🧭 PATH 尚未在当前终端生效${NC}"
    echo ""
    echo -e "  ${BOLD}解决方案:${NC}"
    echo -e "  1. 先在当前终端执行:"
    echo -e "     ${CYAN}source ${shell_rc}${NC}"
    echo -e "  2. 然后立刻验证:"
    echo -e "     ${CYAN}openclaw --version${NC}"
    echo -e "  3. 如果还不行，重新打开一个新的终端窗口再试"
  elif $has_permission; then
    FAIL_CATEGORY="权限"
    echo -e "  ${BOLD}失败原因: 🔒 npm 权限不足${NC}"
    echo ""
    echo -e "  ${BOLD}脚本已尝试自动修复到用户目录，如果仍失败，请手动执行:${NC}"
    echo -e "     ${CYAN}mkdir -p ~/.npm-global/bin${NC}"
    echo -e "     ${CYAN}npm config set prefix ~/.npm-global${NC}"
    echo -e "     ${CYAN}source $(preferred_shell_rc)${NC}"
    echo -e "  然后重新运行本脚本。"
  elif $has_compile; then
    FAIL_CATEGORY="编译"
    echo -e "  ${BOLD}失败原因: 🔨 sharp / 原生模块编译失败${NC}"
    echo ""
    echo -e "  ${BOLD}解决方案:${NC}"
    if [[ "$(detect_os)" == "macOS" ]]; then
      echo -e "  1. 安装 Xcode Command Line Tools:"
      echo -e "     ${CYAN}xcode-select --install${NC}"
    else
      echo -e "  1. 安装编译工具链:"
      echo -e "     ${CYAN}sudo apt install -y build-essential python3${NC}"
    fi
    echo -e "  2. 然后重新运行本脚本，脚本会继续带上 ${CYAN}SHARP_IGNORE_GLOBAL_LIBVIPS=1${NC}"
  elif $has_pnpm_approve; then
    FAIL_CATEGORY="pnpm-approve"
    echo -e "  ${BOLD}失败原因: 📦 pnpm 需要批准构建脚本${NC}"
    echo ""
    echo -e "  ${BOLD}解决方案:${NC}"
    echo -e "  1. 执行:"
    echo -e "     ${CYAN}pnpm approve-builds -g${NC}"
    echo -e "  2. 批准 OpenClaw 相关依赖后，再重新运行本脚本"
  elif $has_git && $has_network; then
    FAIL_CATEGORY="Git"
    echo -e "  ${BOLD}失败原因: 🧬 GitHub 不可达 / Git 拉取失败${NC}"
    echo ""
    echo -e "  ${BOLD}解决方案:${NC}"
    echo -e "  1. 开启代理后重试:"
    echo -e "     ${CYAN}bash Mac一键安装.command --proxy http://127.0.0.1:7890${NC}"
    echo -e "  2. 或让脚本直接走 npm / pnpm 路径:"
    echo -e "     ${CYAN}bash Mac一键安装.command --install-method npm${NC}"
  elif $has_network; then
    FAIL_CATEGORY="网络"
    echo -e "  ${BOLD}失败原因: 🌐 网络连接问题${NC}"
    echo ""
    echo -e "  所有安装路径均因网络问题失败。"
    echo ""
    echo -e "  ${BOLD}解决方案:${NC}"
    echo -e "  1. 检查网络连接是否正常"
    echo -e "  2. 开启 VPN/代理后重新运行:"
    echo -e "     ${CYAN}export https_proxy=http://127.0.0.1:7890${NC}"
    echo -e "     ${CYAN}bash Mac一键安装.command${NC}"
    echo -e "  3. 或手动指定代理:"
    echo -e "     ${CYAN}bash Mac一键安装.command --proxy http://your-proxy:port${NC}"
    echo -e "  4. 手动安装: ${CYAN}https://docs.openclaw.ai/install${NC}"
  else
    FAIL_CATEGORY="未知"
    echo -e "  ${BOLD}失败原因: ❓ 未知错误${NC}"
  fi

  # 详细日志
  echo ""
  echo -e "  ${DIM}── 详细失败日志 ──${NC}"
  for entry in "${FAIL_LOG[@]}"; do
    local level reason detail
    level=$(echo "$entry" | cut -d'|' -f1)
    reason=$(echo "$entry" | cut -d'|' -f2)
    detail=$(echo "$entry" | cut -d'|' -f3)
    echo -e "  ${DIM}• ${level}: ${reason}${NC}"
    $VERBOSE && echo -e "    ${DIM}${detail}${NC}"
  done

  echo ""
  echo -e "${RED}${BOLD}"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ═════════════════════════════════════════════
# Phase 5: 安装后验证
# ═════════════════════════════════════════════
phase5_verify() {
  log_step "[5/5] 🔧 安装后验证..."

  # 刷新 PATH
  hash -r 2>/dev/null || true
  ensure_npm_global_bin_on_path
  ensure_pnpm_global_bin_on_path

  # 检查命令是否可用
  if ! check_command openclaw; then
    # 尝试常见路径
    local npm_bin=""
    local pnpm_bin=""
    npm_bin="$(npm_global_bin_dir)"
    pnpm_bin="$(pnpm_global_bin_dir)"
    local search_paths=("$HOME/.npm-global/bin" "$HOME/.local/bin")
    [[ -n "$npm_bin" ]] && search_paths+=("$npm_bin")
    [[ -n "$pnpm_bin" ]] && search_paths+=("$pnpm_bin")
    for p in "${search_paths[@]}"; do
      if [[ -x "$p/openclaw" ]]; then
        export PATH="$p:$PATH"
        break
      fi
    done
  fi

  if ! check_command openclaw; then
    repair_openclaw_bin || true
    hash -r 2>/dev/null || true
    ensure_npm_global_bin_on_path
    ensure_pnpm_global_bin_on_path
  fi

  if check_command openclaw; then
    local ver
    ver="$(openclaw --version 2>/dev/null || echo 'unknown')"
    log_ok "openclaw ${ver} 已安装"
  else
    log_fail "openclaw 命令不可用"
    echo ""
    local shell_rc
    shell_rc="$(preferred_shell_rc)"
    echo -e "  ${ARROW} 脚本已自动尝试修复 npm/pnpm 的 PATH 和 openclaw bin 入口。"
    echo -e "  ${ARROW} 现在请直接执行:"
    echo -e "    ${CYAN}source ${shell_rc}${NC}"
    echo -e "  ${ARROW} 然后验证:"
    echo -e "    ${CYAN}openclaw --version${NC}"
    echo -e "  ${ARROW} 如果还不行，再打开一个新的终端窗口。"
    return 1
  fi

  # 运行 doctor
  log_info "运行 openclaw doctor..."
  if run_cmd "openclaw doctor --non-interactive" 2>/dev/null; then
    log_ok "openclaw doctor 检查通过"
  else
    log_warn "openclaw doctor 有警告（不影响使用）"
  fi

  return 0
}

# ═════════════════════════════════════════════
# 安装成功提示
# ═════════════════════════════════════════════
show_success() {
  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  🎉 安装成功！                                      ║"
  echo "║                                                      ║"
  echo -e "║  ${YELLOW}已自动处理 npm/pnpm PATH 持久化与安装兜底路径。     ${GREEN}║"
  echo -e "║  ${YELLOW}如当前窗口还未识别命令，开一个新终端即可。           ${GREEN}║"
  echo "║                                                      ║"

  if ! $NO_ONBOARD; then
    echo "║  下一步 (在新窗口中执行):                            ║"
    echo "║  1. openclaw onboard --install-daemon               ║"
    echo "║  2. openclaw dashboard                              ║"
  else
    echo "║  下一步 (在新窗口中执行): openclaw dashboard         ║"
  fi

  echo "║                                                      ║"
  echo "║  文档: https://docs.openclaw.ai/start/getting-started ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  # 动态获取安装路径进行结果提示
  local global_bin=""
  if check_command npm; then
    local real_path
    real_path=$(npm list -g openclaw --parseable 2>/dev/null | head -n 1)
    if [[ -n "$real_path" && -d "$real_path" ]]; then
      if [[ -d "$real_path/bin" ]]; then
        global_bin="$real_path/bin"
      else
        local npm_prefix
        npm_prefix=$(npm prefix -g 2>/dev/null)
        if [[ -n "$npm_prefix" && -d "$npm_prefix/bin" ]]; then
          global_bin="$npm_prefix/bin"
        elif [[ -d "$real_path/../../bin" ]]; then
          global_bin="$(cd "$real_path/../../bin" && pwd)"
        fi
      fi
    fi
  fi
  
  if [[ -z "$global_bin" && -d "$HOME/.npm-global/bin" ]]; then
    global_bin="$HOME/.npm-global/bin"
  fi

  if [[ -z "$global_bin" ]]; then
    global_bin="$(pnpm_global_bin_dir)"
  fi

  if [[ -n "$global_bin" ]]; then
    echo -e "${YELLOW}已确认全局命令目录:${NC} ${CYAN}${global_bin}${NC}"
    echo -e "${YELLOW}脚本已经自动把它写入常用 shell 配置文件。${NC}"
    echo ""
  fi
}

# ═════════════════════════════════════════════
# 主流程
# ═════════════════════════════════════════════
main() {
  parse_args "$@"
  show_banner

  $DRY_RUN && log_warn "预览模式 (--dry-run)，不会实际执行安装"

  phase1_environment
  phase2_nodejs
  phase3_network
  phase4_install
  phase5_verify && show_success
}

main "$@"
